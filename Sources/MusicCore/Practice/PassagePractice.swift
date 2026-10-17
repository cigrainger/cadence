// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public struct ComposeStudySource: Codable, Equatable, Sendable {
    public var scoreID: UUID
    public var instrument: EditorInstrument
    public var tuning: Tuning
    public var capo: Int
    public init(_ score: EditorDocument) {
        scoreID = score.id
        instrument = score.instrument
        tuning = score.tuning
        capo = score.capo
    }
}

public enum ComposePractice {
    /// Practice copies are immutable snapshots. Reopening an identical score reuses its study.
    public static func make(_ score: EditorDocument, from: Int, through: Int) throws -> MusicStudy {
        _ = try score.validated()
        guard from >= 0, through >= from, through < score.barCount, through - from < 16 else {
            throw MusicError.invalid("Choose a passage of 1–16 bars inside this score.")
        }
        guard score.events.contains(where: { !$0.isRest }) else {
            throw MusicError.invalid("Enter a note before creating a practice copy.")
        }
        var study = MusicStudy(
            document: try StudyImport.read(Data(EditorXML.encode(score).utf8)), filename: "Compose practice copy")
        study.sourceEditor = ComposeStudySource(score)
        study.select(from: from, through: through)
        return study
    }
}

public struct PassageScope: Codable, Equatable, Hashable, Sendable {
    public var partID: String
    public var staff: Int?
    public var from: Int
    public var through: Int
    public init(partID: String, staff: Int?, from: Int, through: Int) {
        self.partID = partID
        self.staff = staff
        self.from = from
        self.through = through
    }
    public init(_ study: MusicStudy) {
        partID = study.partID
        staff = study.staff
        from = study.from
        through = study.through
    }
    public func isValid(in document: StudyDocument) -> Bool {
        guard let part = document.parts.first(where: { $0.id == partID }) else { return false }
        return from >= 0 && through >= from && through < part.measures.count && through - from < 16
            && (staff == nil || part.staves.contains(staff!))
    }
}
public struct ComfortableTempo: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var date: Date
    public var bpm: Double
    public init(_ bpm: Double, date: Date = Date()) {
        self.bpm = bpm
        self.date = date
    }
    public var isValid: Bool { bpm.isFinite && (5...450).contains(bpm) && date.timeIntervalSince1970.isFinite }
}
public struct PassageTempoProgress: Codable, Equatable, Sendable {
    public var scope: PassageScope
    public var targetBPM: Double
    public var increment = 5
    public var comfortable: [ComfortableTempo] = []
    public init(study: MusicStudy) {
        scope = PassageScope(study)
        targetBPM = study.document.tempo
    }
    public var bestBPM: Double? { comfortable.map(\.bpm).max() }
    public var reachedTarget: Bool { (bestBPM ?? 0) + 0.001 >= targetBPM }
    public func nextBPM(current: Double, sourceTempo: Double) -> Double {
        min(targetBPM, min(sourceTempo * 1.5, max(sourceTempo * 0.25, current + Double(increment))))
    }
    public mutating func record(_ bpm: Double, date: Date = Date()) throws {
        let mark = ComfortableTempo(bpm, date: date)
        guard mark.isValid else { throw MusicError.invalid("Choose a practice tempo from 5–450 bpm.") }
        comfortable.append(mark)
        if comfortable.count > 200 { comfortable.removeFirst(comfortable.count - 200) }
    }
    public func restored() -> Self? {
        guard targetBPM.isFinite, (5...450).contains(targetBPM) else { return nil }
        var copy = self
        if ![2, 5, 10].contains(increment) { copy.increment = 5 }
        var seen = Set<UUID>()
        copy.comfortable = Array(comfortable.filter { $0.isValid && seen.insert($0.id).inserted }.suffix(200))
        return copy
    }
}
public struct PassagePracticeBook: Codable, Equatable, Sendable {
    public var tempos: [PassageTempoProgress] = []
    public init() {}
    public func progress(for study: MusicStudy) -> PassageTempoProgress {
        tempos.first { $0.scope == PassageScope(study) } ?? PassageTempoProgress(study: study)
    }
    public mutating func set(_ progress: PassageTempoProgress) {
        guard let progress = progress.restored() else { return }
        if let index = tempos.firstIndex(where: { $0.scope == progress.scope }) {
            tempos[index] = progress
        } else {
            tempos.append(progress)
            if tempos.count > 256 { tempos.removeFirst() }
        }
    }
    public func restored(in document: StudyDocument) -> Self {
        var book = Self()
        for entry in tempos.suffix(256) where entry.scope.isValid(in: document) {
            if let progress = entry.restored() { book.set(progress) }
        }
        return book
    }
}

public enum ScoreKey {
    public static func tonic(fifths: Int, minor: Bool) -> Pitch {
        let roots = [
            Pitch(0, -1), Pitch(4, -1), Pitch(1, -1), Pitch(5, -1), Pitch(2, -1), Pitch(6, -1), Pitch(3), Pitch(0),
            Pitch(4), Pitch(1), Pitch(5), Pitch(2), Pitch(6), Pitch(3, 1), Pitch(0, 1),
        ]
        let root = roots[min(7, max(-7, fifths)) + 7]
        return minor ? Scale.major.notes(root)[5] : root
    }
    public static func tone(midi: Int, pitch: Pitch, tonic: Pitch) -> SingingTone {
        let degree = mod(pitch.letter - tonic.letter, 7) + 1
        let distance =
            Pitch.naturals[pitch.letter] + pitch.accidental - Pitch.naturals[tonic.letter] - tonic.accidental
            + (pitch.letter < tonic.letter ? 12 : 0)
        return SingingTone(midi: midi, pitch: pitch, degree: degree, alteration: distance - Pitch.naturals[degree - 1])
    }
}
public struct SingingVoice: Equatable, Hashable, Identifiable, Sendable {
    public var staff: Int
    public var voice: String
    public var id: String { "\(staff):\(voice)" }
    public var label: String { "Staff \(staff) · voice \(voice)" }
    public static func choices(_ study: MusicStudy) -> [Self] {
        let notes = study.part.sourceNotes(staff: study.staff).filter {
            $0.midi >= 0 && $0.start < study.end && $0.start + $0.duration > study.start
        }
        return Array(Set(notes.map { Self(staff: $0.staff, voice: $0.voice) })).sorted {
            $0.staff == $1.staff
                ? $0.voice.localizedStandardCompare($1.voice) == .orderedAscending : $0.staff < $1.staff
        }
    }
}
public struct PassageSingingNote: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var start: Double
    public var duration: Double
    public var measure: Int
    public var tone: SingingTone
}
public struct PassageMelody: Equatable, Sendable {
    public var notes: [PassageSingingNote]
    public var reducedChords: Bool
    public init(study: MusicStudy, voice: SingingVoice, minorOverride: Bool? = nil) throws {
        let source = study.part.sourceNotes(staff: voice.staff).filter { $0.voice == voice.voice && $0.midi >= 0 }
            .sorted { $0.start == $1.start ? $0.midi > $1.midi : $0.start < $1.start }
        let inPassage = source.filter { $0.start < study.end && $0.start + $0.duration > study.start }
        guard inPassage.allSatisfy({ $0.writtenMidi == nil || mod($0.writtenMidi!) == mod($0.midi) }) else {
            throw MusicError.invalid(
                "For this singing guide, export transposing instruments at concert pitch. Guitar octave notation is supported."
            )
        }
        guard
            minorOverride != nil
                || study.selectedMeasures.allSatisfy({
                    $0.keyMode == nil || ["major", "minor", "ionian", "aeolian"].contains($0.keyMode!)
                })
        else {
            throw MusicError.invalid(
                "This singing guide currently interprets major and minor keys. The source uses another mode; passage playback is still available."
            )
        }
        var chosen: [StudyNote] = []
        reducedChords = false
        for note in source {
            if let last = chosen.last, abs(last.start - note.start) < 0.00001 {
                if note.start >= study.start && note.start < study.end { reducedChords = true }
                continue
            }
            chosen.append(note)
        }
        var merged: [(note: StudyNote, end: Double, tie: Bool)] = []
        for note in chosen {
            if let previous = merged.last, previous.tie, note.tieStop, previous.note.midi == note.midi,
                abs(previous.end - note.start) < 0.00001
            {
                merged[merged.count - 1].end = note.start + note.duration
                merged[merged.count - 1].tie = note.tieStart
            } else {
                merged.append((note, note.start + note.duration, note.tieStart))
            }
        }
        notes = merged.filter { $0.note.start < study.end - 0.00001 && $0.end > study.start + 0.00001 }.map { item in
            let start = max(study.start, item.note.start)
            let bar = study.part.measures.last { $0.start <= start + 0.00001 } ?? study.selectedMeasures[0]
            let minor = minorOverride ?? bar.minor ?? false
            let pitch =
                item.note.writtenPitch.flatMap { $0.pc == mod(item.note.midi) ? $0 : nil }
                ?? Pitch.spelled(item.note.midi, flats: bar.fifths < 0)
            return PassageSingingNote(
                id: item.note.id, start: start, duration: min(study.end, item.end) - start, measure: bar.index,
                tone: ScoreKey.tone(
                    midi: item.note.midi, pitch: pitch, tonic: ScoreKey.tonic(fifths: bar.fifths, minor: minor)))
        }
        guard !notes.isEmpty else {
            throw MusicError.invalid("Choose a staff and voice with pitched notes in this passage.")
        }
    }
    public func audio(tempo: Double, octaves: Int = 0) -> Score {
        let start = notes.first?.start ?? 0
        return Score(
            title: "Singing reference", tempo: tempo,
            notes: notes.map {
                ScoreNote(
                    midi: $0.tone.midi + octaves * 12, start: $0.start - start, duration: $0.duration,
                    spelling: $0.tone.pitch)
            })
    }
}
public enum MelodyEchoResult: Equatable, Sendable {
    case ignored
    case wrong(expected: Int, heard: Int)
    case matched(Int)
    case complete
}
/// Checks an ordered pitch sequence, not its rhythm. Nil releases the held note;
/// repeated pitches need a new held note after a gap, rather than counting twice.
public struct MelodyEchoAttempt: Sendable {
    public private(set) var matched = 0
    public private(set) var offset: Int?
    private var last: Int?
    public init() {}
    public mutating func hear(_ midi: Int?, targets: [Int], matchReference: Bool) -> MelodyEchoResult {
        guard let midi else {
            last = nil
            return .ignored
        }
        guard (0...127).contains(midi), !targets.isEmpty, targets.allSatisfy({ (0...127).contains($0) }),
            matched < targets.count, midi != last
        else { return .ignored }
        last = midi
        if offset == nil {
            let shift = midi - targets[0]
            guard !matchReference || mod(shift) == 0 else { return .wrong(expected: targets[0], heard: midi) }
            offset = shift
        }
        let expected = targets[matched] + offset!
        guard midi == expected else { return .wrong(expected: expected, heard: midi) }
        matched += 1
        return matched == targets.count ? .complete : .matched(matched)
    }
}
