// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A performance keeps physical releases and pedal messages separately. Seconds
/// use the same calibrated origin as the onset assessment, never display time.
public struct PianoEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case press, release, sustain }
    public var kind: Kind
    public var seconds: Double
    public var channel: Int
    public var note: Int
    public var value: Int
    public var arrivalTimestamp: Bool
    public init?(_ message: MIDIMessage, seconds: Double, arrivalTimestamp: Bool = false) {
        self.seconds = seconds
        self.arrivalTimestamp = arrivalTimestamp
        switch message {
        case .noteOn(let c, let n, let v):
            kind = v == 0 ? .release : .press
            channel = c
            note = n
            value = v
        case .noteOff(let c, let n):
            kind = .release
            channel = c
            note = n
            value = 0
        case .control(let c, let number, let v) where number == 64 || number == 121:
            kind = .sustain
            channel = c
            note = 0
            value = number == 121 ? 0 : v
        default: return nil
        }
        guard valid else { return nil }
    }
    public var valid: Bool {
        seconds.isFinite && (-7...65).contains(seconds) && (0...15).contains(channel) && (0...127).contains(note)
            && (0...127).contains(value) && (kind != .press || value > 0) && (kind != .release || value == 0)
            && (kind != .sustain || note == 0)
    }
}

public struct PerformedPianoNote: Equatable, Sendable, Identifiable {
    public var id: Int  // Index of the press in the original ordered event stream.
    public var pitch: Int
    public var channel: Int
    public var velocity: Int
    public var start: Double
    public var release: Double?
    public var soundEnd: Double
    public var clipped: Bool
}

public struct PianoRecording: Codable, Equatable, Sendable {
    public var events: [PianoEvent]
    public var end: Double
    public init(events: [PianoEvent], end: Double) {
        // Keep arrival order when timestamps coincide (e.g. release/re-press).
        self.events = events.enumerated().sorted {
            $0.element.seconds == $1.element.seconds ? $0.offset < $1.offset : $0.element.seconds < $1.element.seconds
        }.map(\.element)
        self.end = end
    }
    public var valid: Bool {
        end.isFinite && (0...65).contains(end) && events.count <= 8192
            && events.allSatisfy { $0.valid && $0.seconds <= end }
            && events.map(\.seconds) == events.map(\.seconds).sorted()
    }
    public var start: Double { min(0, events.first { $0.kind == .press }?.seconds ?? 0) }
    public var duration: Double { end - start }
    public var notes: [PerformedPianoNote] {
        guard valid else { return [] }
        var result: [PerformedPianoNote] = []
        var down: [MIDIKey: Int] = [:]
        var ringing = Set<Int>()
        var pedals = Set<Int>()
        for (index, e) in events.enumerated() {
            let key = MIDIKey(channel: e.channel, note: e.note)
            switch e.kind {
            case .press:
                if let old = down[key] {
                    result[old].soundEnd = e.seconds
                    result[old].clipped = true
                    ringing.remove(old)
                }
                // Re-striking a pedal-held pitch ends our inferred old note. Raw
                // messages are still replayed so the sampler handles resonance.
                for old in Array(ringing) where result[old].channel == e.channel && result[old].pitch == e.note {
                    result[old].soundEnd = e.seconds
                    result[old].clipped = false
                    ringing.remove(old)
                }
                down[key] = result.count
                result.append(
                    .init(
                        id: index, pitch: e.note, channel: e.channel, velocity: e.value, start: e.seconds, release: nil,
                        soundEnd: end, clipped: true))
            case .release:
                if let i = down.removeValue(forKey: key) {
                    result[i].release = e.seconds
                    if pedals.contains(e.channel) {
                        ringing.insert(i)
                    } else {
                        result[i].soundEnd = e.seconds
                        result[i].clipped = false
                    }
                }
            case .sustain:
                if e.value >= 64 {
                    pedals.insert(e.channel)
                } else {
                    pedals.remove(e.channel)
                    for i in Array(ringing) where result[i].channel == e.channel {
                        result[i].soundEnd = e.seconds
                        result[i].clipped = false
                        ringing.remove(i)
                    }
                }
            }
        }
        return result
    }
}

public enum PhraseIntention: String, Codable, Sendable { case connectedMelody = "A connected melody" }
public enum PhraseReflection: String, Codable, CaseIterable, Sendable {
    case connected = "It felt connected"
    case uneven = "Some joins stood out"
    case unsure = "I’m still listening"
}

public struct PianoPhraseNote: Codable, Equatable, Sendable {
    public var pitch: Int
    public var beat: Double
    public var duration: Double
    public var detached: Bool
}

public struct PianoPhrase: Codable, Equatable, Sendable {
    public var plan: TimedPracticePlan
    public var notes: [PianoPhraseNote]
    public var singleVoice: Bool
    public init(piece: LibraryPiece, plan: TimedPracticePlan) throws {
        guard plan.valid, let source = plan.source, RehearsalSource.current(plan, in: piece) else {
            throw MusicError.invalid("Choose a current reviewed piano phrase.")
        }
        let study = try RehearsalSource.whole(piece, partID: source.scope.partID)
        guard Self.isPiano(piece, part: study.part) else {
            throw MusicError.invalid(
                "Piano takes are available for a piano or keyboard part. Choose its notation staff.")
        }
        self.plan = plan
        let written = study.part.sourceNotes(staff: source.scope.staff).filter {
            $0.midi >= 0 && $0.start >= source.startBeat && $0.start < source.startBeat + plan.length
        }
        singleVoice = plan.handStaves == nil && Set(written.map(\.voice)).count == 1
        notes = study.part.soundingNotes(staff: source.scope.staff).filter {
            $0.start >= source.startBeat && $0.start < source.startBeat + plan.length
        }.map {
            .init(
                pitch: $0.midi, beat: $0.start - source.startBeat, duration: $0.duration,
                detached: ($0.performance?.gate ?? 0.9) < 0.8)
        }.sorted { $0.beat == $1.beat ? $0.pitch < $1.pitch : $0.beat < $1.beat }
        if plan.handStaves != nil {
            // Two written unisons describe one physical key; keep the longest written hold.
            notes = notes.reduce(into: [PianoPhraseNote]()) { result, note in
                if let i = result.firstIndex(where: { $0.pitch == note.pitch && abs($0.beat - note.beat) < 0.00001 }) {
                    result[i].duration = max(result[i].duration, note.duration)
                } else {
                    result.append(note)
                }
            }
        }
        guard valid else { throw MusicError.invalid("This staff cannot yet be linked to a recorded piano take.") }
    }
    public static func isPiano(_ piece: LibraryPiece, part: StudyPart) -> Bool {
        switch piece.source {
        case .score(let document): document.instrument == .piano
        case .study:
            part.name.localizedCaseInsensitiveContains("piano")
                || part.name.localizedCaseInsensitiveContains("keyboard")
        }
    }
    public var valid: Bool {
        guard plan.valid, !plan.rhythmOnly, plan.source != nil, (1...256).contains(notes.count) else { return false }
        return notes.allSatisfy {
            (0...127).contains($0.pitch) && $0.beat.isFinite && $0.duration.isFinite && $0.duration > 0 && $0.beat >= 0
                && $0.beat + $0.duration <= plan.length + 0.00001
        } && notes.map(\.beat) == notes.map(\.beat).sorted() && notes.count == plan.targets.count
            && plan.targets.allSatisfy { t in
                notes.filter { $0.pitch == t.pitch && abs($0.beat - t.beat) < 0.00001 }.count == 1
            }
    }
    /// Only adjacent, distinct pitches in a single melodic line. Written rests,
    /// chords, repeated pitches and detached articulation are not legato errors.
    public var joins: [Int] {
        guard valid, singleVoice, notes.count > 1,
            zip(notes, notes.dropFirst()).allSatisfy({ $0.beat + $0.duration <= $1.beat + 0.00001 })
        else { return [] }
        return (0..<(notes.count - 1)).filter { i in
            !notes[i].detached && notes[i].pitch != notes[i + 1].pitch
                && abs(notes[i].beat + notes[i].duration - notes[i + 1].beat) < 0.00001
        }
    }
}

public struct MelodyJoin: Equatable, Sendable, Identifiable {
    public var id: Int
    public var bar: Int
    public var beat: Double
    public var from: Int
    public var to: Int
    /// Positive: physical gap; negative: keys overlapped. No aesthetic grade.
    public var gap: Double
    public var pedalBridged: Bool
}

public struct PianoTake: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { pass.id }
    public var rehearsalKey: String
    public var phase: RehearsalStage
    public var intention: PhraseIntention?
    public var phrase: PianoPhrase
    public var pass: TimedPracticeResult
    public var recording: PianoRecording
    public var reflection: PhraseReflection?
    public var note: String = ""
    public var listenedAt: Date?
    public init(
        rehearsalKey: String, phase: RehearsalStage, intention: PhraseIntention?, phrase: PianoPhrase,
        pass: TimedPracticeResult, recording: PianoRecording
    ) {
        self.rehearsalKey = rehearsalKey
        self.phase = phase
        self.intention = intention
        self.phrase = phrase
        self.pass = pass
        self.recording = recording
    }
    public var valid: Bool {
        rehearsalKey.hasPrefix("rehearsal:") && rehearsalKey.count <= 100 && phase != .complete && phrase.valid
            && pass.valid && pass.plan == phrase.plan && pass.conditions.input == .midi && recording.valid
            && abs(recording.end - (pass.plan.duration + 0.4)) < 0.00001
            && recording.events.allSatisfy { $0.seconds >= -pass.plan.countIn - 0.5 } && note.count <= 1000
            && (listenedAt.map { $0.timeIntervalSince1970.isFinite && $0 >= pass.date } ?? true)
            && (reflection == nil || listenedAt != nil)
    }
    public func comparable(to other: PianoTake) -> Bool {
        rehearsalKey == other.rehearsalKey && phrase.plan.source == other.phrase.plan.source
            && phrase.notes == other.phrase.notes && pass.conditions.partnerStaff == other.pass.conditions.partnerStaff
            && pass.conditions.flowPulse == other.pass.conditions.flowPulse
    }
    /// Use the same onset alignment as the practice pass. Ambiguous duplicate
    /// pitches/channels cannot provide an articulation diagnosis.
    public var matchedNotes: [(target: TimedTarget, note: PerformedPianoNote)] {
        let played = recording.notes
        return pass.report.notes.compactMap { assessment in
            guard let a = assessment.attack, a.pitch == assessment.target.pitch else { return nil }
            let candidates = played.filter { $0.pitch == a.pitch && abs($0.start - a.seconds) < 0.000001 }
            guard candidates.count == 1 else { return nil }
            return (assessment.target, candidates[0])
        }
    }
    public var joins: [MelodyJoin] {
        guard valid, !recording.events.contains(where: \.arrivalTimestamp) else { return [] }
        let matched = matchedNotes
        let played = recording.notes
        return phrase.joins.compactMap { index in
            let a = phrase.notes[index]
            let b = phrase.notes[index + 1]
            guard
                let first = matched.first(where: {
                    $0.target.pitch == a.pitch && abs($0.target.beat - a.beat) < 0.00001
                }),
                let second = matched.first(where: {
                    $0.target.pitch == b.pitch && abs($0.target.beat - b.beat) < 0.00001
                }),
                let release = first.note.release, second.note.start > first.note.start,
                !played.contains(where: {
                    $0.id != first.note.id && $0.id != second.note.id && $0.start >= first.note.start
                        && $0.start <= second.note.start
                })
            else { return nil }
            let gap = second.note.start - release
            return MelodyJoin(
                id: index, bar: second.target.bar, beat: second.target.beat, from: a.pitch, to: b.pitch, gap: gap,
                pedalBridged: gap > 0 && first.note.soundEnd >= second.note.start && first.note.soundEnd > release)
        }
    }
    /// Interpolate between confidently matched entrances, preserving the take's
    /// pauses and pacing. Unmatched notes are audible but do not invent anchors.
    public func sourceBeat(at seconds: Double) -> Double? {
        guard valid, seconds.isFinite, let source = pass.plan.source else { return nil }
        var anchors: [(time: Double, beat: Double)] = []
        for item in matchedNotes.sorted(by: { $0.target.beat < $1.target.beat }) {
            if let last = anchors.last, item.note.start <= last.time || item.target.beat <= last.beat { continue }
            anchors.append((item.note.start, item.target.beat))
        }
        guard let first = anchors.first, let last = anchors.last else { return nil }
        if seconds <= first.time { return source.startBeat + first.beat }
        if seconds >= last.time {
            let end = max(last.time + 0.001, recording.end)
            return source.startBeat
                + min(
                    pass.plan.length - 0.00001,
                    last.beat + (pass.plan.length - last.beat) * (seconds - last.time) / (end - last.time))
        }
        for (a, b) in zip(anchors, anchors.dropFirst()) where seconds >= a.time && seconds < b.time {
            return source.startBeat + a.beat + (b.beat - a.beat) * (seconds - a.time) / (b.time - a.time)
        }
        return nil
    }
}

public struct PianoTakeBook: Codable, Equatable, Sendable {
    public static let limit = 256
    public static let eventLimit = 250_000
    public var takes: [PianoTake] = []
    public init() {}
    public mutating func append(_ take: PianoTake) throws {
        guard take.valid else {
            throw MusicError.invalid("This piano recording could not be saved. The pass is still here.")
        }
        if let existing = takes.first(where: { $0.id == take.id }) {
            guard existing == take else {
                throw MusicError.invalid("Another recording already uses this take identity. Both have been preserved.")
            }
            return
        }
        guard takes.count < Self.limit else {
            throw MusicError.invalid(
                "Your 256 saved piano takes have been kept. Delete an older take before saving this one.")
        }
        guard takes.reduce(0, { $0 + $1.recording.events.count }) + take.recording.events.count <= Self.eventLimit
        else {
            throw MusicError.invalid(
                "Saved piano recordings have reached the storage limit. Delete an older take before saving this one.")
        }
        takes.append(take)
    }
    public func validated() throws -> Self {
        guard takes.count <= Self.limit, takes.reduce(0, { $0 + $1.recording.events.count }) <= Self.eventLimit,
            takes.allSatisfy(\.valid), Set(takes.map(\.id)).count == takes.count
        else {
            throw MusicError.invalid(
                "The piano takes are damaged or need a newer Cadence. The saved file has been preserved.")
        }
        return self
    }
}
