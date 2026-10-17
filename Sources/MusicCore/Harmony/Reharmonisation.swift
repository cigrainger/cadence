// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum ReharmVersion: String, Codable, CaseIterable, Sendable {
    case original = "Original"
    case substitute = "Tritone substitute"
}
public enum ReharmLayer: String, CaseIterable, Sendable {
    case band = "Bass & guide tones"
    case bass = "Bass"
    case guides = "Guide tones"
    case melody = "With written melody"
}

/// A reviewed, revision-specific study of one substitution. Chord symbols stay
/// structured and the original music remains authoritative.
public struct ReharmSource: Codable, Equatable, Sendable {
    public var pieceID: String
    public var fingerprint: String
    public var title: String
    public var scope: PassageScope
    public var tonic: Pitch
    public var changes: [HarmonyAnchor]
    public var barTicks: [Int]
    public var pair: Int
    public var id: String {
        "reharm:"
            + ScoreRevision.digest(
                "\(pieceID):\(fingerprint):\(scope.partID):\(scope.staff ?? 1):\(scope.from):\(scope.through):\(tonic.name):\(pair)"
            )
    }
    public var dominant: ChordSymbol { changes[pair].symbol }
    public var destination: ChordSymbol { changes[pair + 1].symbol }
    public var substitute: ChordSymbol {
        .init(root: dominant.root!.transposed(semitones: 6, steps: 4), kind: .dominant)
    }
    public var length: Double { Double(barTicks.reduce(0, +)) / 480 }
    public init(piece: LibraryPiece, scope: PassageScope, tonic: Pitch) throws {
        guard scope.from >= 0, scope.through >= scope.from, scope.through < 1000, scope.through - scope.from < 8 else {
            throw MusicError.invalid("Choose 1–8 reviewed bars for this jazz study.")
        }
        let anchors = try HarmonyTheory.anchors(piece: piece, scope: scope)
        let plan = try ChangesSource(piece: piece, from: scope.from, through: scope.through, partID: scope.partID).plan(
            staff: scope.staff ?? 1)
        guard
            let pair = anchors.indices.dropLast().first(where: {
                HarmonyTheory.resolves(anchors[$0].symbol, to: anchors[$0 + 1].symbol)
            })
        else {
            throw MusicError.invalid(
                "Choose a dominant seventh resolving a fifth down, such as G7 → Cmaj7. Add or review the written chord symbols first."
            )
        }
        self.pieceID = piece.id
        fingerprint = piece.fingerprint
        title = piece.title
        self.scope = scope
        self.tonic = tonic
        changes = anchors
        barTicks = plan.barTicks
        self.pair = pair
        guard valid else {
            throw MusicError.invalid(
                "This first guide-tone study needs 2–16 seventh chords with unambiguous thirds and sevenths, in up to eight bars / 48 quarter-note beats. Choose a shorter passage with ordinary chord spellings."
            )
        }
    }
    public var valid: Bool {
        guard !pieceID.isEmpty, pieceID.count <= 100, ScoreRevision.valid(fingerprint), title.count <= 500,
            !scope.partID.isEmpty, scope.partID.count <= 200, (1...16).contains(scope.staff ?? 1),
            (0..<1000).contains(scope.from), (0..<1000).contains(scope.through), scope.through >= scope.from,
            scope.through - scope.from < 8,
            (0..<7).contains(tonic.letter), (-1...1).contains(tonic.accidental),
            barTicks.count == scope.through - scope.from + 1, barTicks.allSatisfy({ (120...7680).contains($0) }),
            length <= 48,
            (2...16).contains(changes.count), (0..<(changes.count - 1)).contains(pair), changes.allSatisfy(\.valid),
            changes.allSatisfy({
                $0.partID == scope.partID && $0.staff == (scope.staff ?? 1) && $0.bar <= scope.through
            }),
            changes[0].bar <= scope.from, changes[0].bar < scope.from || changes[0].tick == 0,
            changes.dropFirst().allSatisfy({ $0.bar >= scope.from }),
            zip(changes, changes.dropFirst()).allSatisfy({ ($0.bar, $0.tick) < ($1.bar, $1.tick) })
        else { return false }
        for c in changes where c.bar >= scope.from { if c.tick >= barTicks[c.bar - scope.from] { return false } }
        guard HarmonyTheory.resolves(dominant, to: destination), substitute.valid else { return false }
        return (changes.map(\.symbol) + [substitute]).allSatisfy { symbol in
            guard let tones = try? ChordRealization(symbol).tones.filter({ $0.degree == 3 || $0.degree == 7 }) else {
                return false
            }
            return tones.count == 2 && Set(tones.map { $0.pitch.pc }).count == 2 && Set(tones.map(\.degree)) == [3, 7]
                && tones.allSatisfy { abs($0.pitch.accidental) <= 2 }
        }
    }
    public func current(in piece: LibraryPiece) -> Bool {
        guard pieceID == piece.id, fingerprint == piece.fingerprint,
            let rebuilt = try? Self(piece: piece, scope: scope, tonic: tonic)
        else { return false }
        var a = self
        var b = rebuilt
        a.title = ""
        b.title = ""
        return a == b
    }
    public func symbol(_ index: Int, version: ReharmVersion) -> ChordSymbol {
        index == pair && version == .substitute ? substitute : changes[index].symbol
    }
    public func beat(_ index: Int) -> Double {
        let anchor = changes[index]
        return anchor.bar < scope.from
            ? 0 : Double(barTicks.prefix(anchor.bar - scope.from).reduce(0, +) + anchor.tick) / 480
    }
    public func guideVoicings(_ version: ReharmVersion) throws -> [[Int]] {
        guard valid else { throw MusicError.invalid("Reopen a valid harmony study.") }
        var route: [[Int]] = []
        for i in changes.indices {
            let target = try ChordRealization(symbol(i, version: version)).target(.guides)
            route.append(target.pianoVoicings(previous: route.last ?? []).first!)
        }
        return route
    }
    /// Identical timing/guide voicings for both versions. Extensions and slash
    /// basses are reduced explicitly; only the selected root changes by a tritone.
    public func accompaniment(_ version: ReharmVersion, layer: ReharmLayer = .band, tempo: Int = 84) throws -> Score {
        guard valid, (60...160).contains(tempo) else { throw MusicError.invalid("Choose a tempo from 60–160 bpm.") }
        let route = try guideVoicings(.original)
        var notes: [ScoreNote] = []
        for i in changes.indices {
            let start = beat(i)
            let end = i + 1 < changes.count ? beat(i + 1) : length
            let duration = max(0.05, end - start - 0.08)
            if layer != .guides {
                let bass =
                    i == pair && version == .substitute
                    ? 37 + destination.root!.pc : 36 + symbol(i, version: version).root!.pc
                notes.append(.init(midi: bass, start: start, duration: duration))
            }
            if layer != .bass { notes += route[i].map { .init(midi: $0, start: start, duration: duration) } }
        }
        return try Score(title: title, tempo: Double(tempo), notes: notes).validated()
    }
    public func writtenMelody(in piece: LibraryPiece) throws -> [ScoreNote] {
        guard current(in: piece) else { throw MusicError.invalid("The original music changed. Start a fresh study.") }
        let study = try RehearsalSource.whole(piece, partID: scope.partID)
        let start = study.part.measures[scope.from].start
        let end = start + length
        var part = study.part
        let voice = part.sourceNotes(staff: scope.staff).map(\.voice).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }.first
        part.notes = part.notes.filter { $0.voice == voice }
        let candidates = part.soundingNotes(staff: scope.staff).filter {
            $0.midi >= 0 && $0.start < end && $0.start + $0.duration > start
        }
        return candidates.map { n in
            .init(
                midi: n.midi, start: max(start, n.start) - start,
                duration: min(end, n.start + n.duration) - max(start, n.start))
        }
    }
    public func alternative(in piece: LibraryPiece) throws -> EditorDocument {
        guard current(in: piece) else { throw MusicError.invalid("The source changed. Start from its current score.") }
        var document: EditorDocument
        switch piece.source {
        case .score(let original): document = original
        case .study(let study): document = try EditorXML.decode(Data(study.document.originalXML.utf8))
        }
        let anchor = changes[pair]
        guard
            let index = document.harmonies.firstIndex(where: {
                $0.bar == anchor.bar && $0.tick == anchor.tick && $0.staff == anchor.staff && $0.symbol == anchor.symbol
            })
        else { throw MusicError.invalid("The selected harmony could not be preserved in Compose.") }
        // A carried chord is replaced at the start of the chosen passage only.
        if anchor.bar < scope.from {
            document.harmonies.append(.init(bar: scope.from, staff: anchor.staff, symbol: substitute))
        } else {
            document.harmonies[index].symbol = substitute
        }
        document.id = UUID()
        document.title = String(("Reharmonised · " + title).prefix(120))
        document.responseSource = nil
        document.triadSource = nil
        document.tensionSource = nil
        document.reharmSource = self
        return try document.validated()
    }
    public static func example() throws -> EditorDocument {
        var doc = try EditorDocument.blank(instrument: .piano, bars: 4, meter: .init(4, 4))
        doc.id = UUID(uuidString: "CADEC035-0000-4000-8000-000000000001")!
        doc.title = "Two routes home · an original jazz example"
        doc.tempo = 84
        doc.harmonies = try ["Dm7", "G7", "Cmaj7"].enumerated().map {
            .init(bar: $0.offset, symbol: try .parse($0.element))
        }
        for i in doc.events.indices {
            let bar = doc.events[i].bar
            if doc.events[i].staff == 1 { doc.events[i].pitches = [.init([65, 65, 64, 71][bar])] }
            // Empty lower staff leaves room for generated accompaniment.
        }
        return try doc.validated()
    }
}

/// A free performance has no target score. Reuse the raw MIDI recording format,
/// while keeping its frozen accompaniment independent of scored piano takes.
public struct ReharmTake: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var sessionID: UUID
    public var source: ReharmSource
    public var version: ReharmVersion
    public var tempo: Int
    public var offsetMS: Int
    public var recording: PianoRecording
    public var date = Date()
    public var listened = false
    public init(
        sessionID: UUID, source: ReharmSource, version: ReharmVersion, tempo: Int, offsetMS: Int,
        recording: PianoRecording
    ) {
        self.sessionID = sessionID
        self.source = source
        self.version = version
        self.tempo = tempo
        self.offsetMS = offsetMS
        self.recording = recording
    }
    public var valid: Bool {
        source.valid && (60...160).contains(tempo) && (-300...300).contains(offsetMS) && recording.valid
            && abs(recording.end - source.length * 60 / Double(tempo)) < 0.00001
            && recording.events.allSatisfy { $0.seconds >= 0 } && !recording.notes.isEmpty
            && date.timeIntervalSince1970.isFinite
    }
    public var observation: String {
        let target = (try? ChordRealization(source.destination).tones.first { $0.degree == 3 }?.pitch.pc) ?? -1
        let arrival = source.beat(source.pair + 1) * 60 / Double(tempo)
        let notes = recording.notes.filter {
            $0.start >= arrival && $0.start < min(recording.end, arrival + 120 / Double(tempo))
        }
        return notes.contains { mod($0.pitch) == target }
            ? "Your phrase includes the destination’s third in its first two beats."
            : "Listen to the arrival: what note did you choose as the destination chord began?"
    }
}

public enum ReharmAction: Equatable, Sendable {
    case heard(Int)
    case reveal
    case hearing(Int)
    case explanation(Int)
    case guides([[Int]])
    case guitarReport
    case creation(String)
    case skip
}
public struct ReharmSession: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var source: ReharmSource
    public var instrument: EditorInstrument
    public var skill = TheorySkill.hearing
    public var completed = false
    public var independent = false
    public var assisted = true
    public var attempts = 0
    public var heard: Set<Int> = []
    public var substituteSlot: Int
    public var reviews: [String: ReviewSchedule] = [:]
    public var reflection = ""
    public var updatedAt = Date()
    public init(source: ReharmSource, instrument: EditorInstrument, substituteSlot: Int = Int.random(in: 0...1)) {
        self.source = source
        self.instrument = instrument
        self.substituteSlot = substituteSlot
    }
    public var valid: Bool {
        source.valid && (0...1).contains(substituteSlot) && (0...100000).contains(attempts)
            && heard.isSubset(of: [0, 1]) && reflection.count <= 2000 && updatedAt.timeIntervalSince1970.isFinite
            && reviews.count <= 4
            && reviews.allSatisfy { TheorySkill.allCases.map(\.rawValue).contains($0.key) && $0.value.valid }
    }
    public mutating func beginReview(_ skill: TheorySkill, now: Date = Date()) {
        id = UUID()
        self.skill = skill
        independent = true
        assisted = false
        attempts = 0
        heard = []
        completed = false
        substituteSlot = Int.random(in: 0...1)
        updatedAt = now
    }
    public mutating func apply(_ action: ReharmAction, now: Date = Date()) throws -> PracticeAttempt? {
        guard valid, !completed, now.timeIntervalSince1970.isFinite, attempts < 100000 else {
            throw MusicError.invalid("Open a current jazz study before answering.")
        }
        if case .reveal = action {
            assisted = true
            updatedAt = now
            return nil
        }
        if case .heard(let slot) = action {
            guard skill == .hearing, (0...1).contains(slot) else {
                throw MusicError.invalid("Listen from the hearing step.")
            }
            heard.insert(slot)
            return nil
        }
        var outcome = PracticeOutcome.correct
        var input = PracticeInput.choice
        var played: [Int] = []
        var target: [Int] = []
        var choice: String?
        switch (skill, action) {
        case (.hearing, .hearing(let slot)):
            guard heard == [0, 1], (0...1).contains(slot) else {
                throw MusicError.invalid("Hear both versions before choosing.")
            }
            outcome = slot == substituteSlot ? .correct : .incorrect
            choice = slot == 0 ? "A" : "B"
        case (.explaining, .explanation(let option)):
            guard (0...2).contains(option) else { throw MusicError.invalid("Choose an explanation.") }
            outcome = option == 0 ? .correct : .incorrect
            choice =
                [
                    "Shared sounding third/seventh pair; exchanged roles", "Identical roots",
                    "Any chord fits any melody",
                ][option]
        case (.playing, .guides(let groups)):
            guard instrument == .piano, groups.count == source.changes.count,
                groups.allSatisfy({ !$0.isEmpty && $0.count <= 8 && $0.allSatisfy { (0...127).contains($0) } })
            else { throw MusicError.invalid("Play and release one guide-tone pair for each chord.") }
            let targets = try source.changes.indices.map {
                try ChordRealization(source.symbol($0, version: .substitute)).target(.guides)
            }
            outcome = zip(targets, groups).allSatisfy { $0.judge($1).correct } ? .correct : .incorrect
            input = .midi
            played = groups.flatMap { $0 }
            target = try source.guideVoicings(.substitute).flatMap { $0 }
        case (.playing, .guitarReport):
            guard instrument == .guitar else { throw MusicError.invalid("Choose the guitar activity first.") }
            input = .selfReport
            outcome = .revealed
            assisted = true
            choice = "I played the guide-tone route and compared both bass lines."
        case (.creating, .creation(let text)):
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.count <= 2000 else {
                throw MusicError.invalid("Describe your harmonic or melodic choice in up to 2,000 characters.")
            }
            reflection = clean
            input = .selfReport
            outcome = .revealed
            assisted = true
            choice = String(clean.prefix(500))
        case (_, .skip):
            input = .selfReport
            outcome = .skipped
        default: throw MusicError.invalid("This answer belongs to another jazz activity.")
        }
        let old = skill
        let grade: ReviewGrade =
            outcome == .incorrect
            ? .again : outcome == .correct && independent && !assisted && attempts == 0 ? .good : .supported
        var review = reviews[old.rawValue] ?? ReviewSchedule()
        review.record(grade, episode: id, input: input, now: now)
        reviews[old.rawValue] = review
        var evidence = PracticeAttempt(
            sessionID: id, activityID: source.id + ":" + old.rawValue,
            title: "Reharmonise and improvise · " + old.rawValue,
            skills: ["Tritone substitution", "Guide tones", old.rawValue], input: input, outcome: outcome,
            assisted: assisted || !independent || attempts > 0, ordinal: attempts + 1, selectedChoice: choice,
            played: played, target: target, date: now)
        evidence.pieceID = source.pieceID
        evidence.scoreFingerprint = source.fingerprint
        evidence.passageScope = source.scope
        attempts += 1
        updatedAt = now
        if outcome == .incorrect {
            assisted = true
        } else if independent || old == .creating {
            completed = true
        } else {
            skill = TheorySkill.allCases[TheorySkill.allCases.firstIndex(of: old)! + 1]
            attempts = 0
            assisted = true
        }
        return evidence
    }
}
public struct ReharmPractice: Codable, Equatable, Sendable {
    public var sessions: [ReharmSession] = []
    public var takes: [ReharmTake] = []
    public var activeID: UUID?
    public init() {}
    public var active: ReharmSession? { sessions.first { $0.id == activeID } }
    public mutating func append(_ take: ReharmTake) throws {
        guard take.valid else {
            throw MusicError.invalid("This improvisation is invalid; the unsaved recording is still here.")
        }
        if let existing = takes.first(where: { $0.id == take.id }) {
            guard existing == take else { throw MusicError.invalid("A different take already uses that identity.") }
            return
        }
        guard takes.count < 100,
            takes.reduce(0, { $0 + $1.recording.events.count }) + take.recording.events.count <= 100_000
        else {
            throw MusicError.invalid("Your saved improvisations are full. Delete an older take before saving this one.")
        }
        takes.append(take)
    }
    public func validated() throws -> Self {
        guard sessions.count <= 100, Set(sessions.map(\.id)).count == sessions.count,
            Set(sessions.map { $0.source.id + ":" + $0.instrument.rawValue }).count == sessions.count,
            sessions.allSatisfy(\.valid),
            activeID == nil || active != nil, takes.count <= 100, Set(takes.map(\.id)).count == takes.count,
            takes.allSatisfy(\.valid), takes.reduce(0, { $0 + $1.recording.events.count }) <= 100_000,
            takes.allSatisfy({ take in sessions.contains { $0.source == take.source && $0.instrument == .piano } })
        else {
            throw MusicError.invalid(
                "The saved jazz studies or improvisations are invalid. Existing data has been preserved.")
        }
        return self
    }
}
