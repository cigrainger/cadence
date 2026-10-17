// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum TheorySkill: String, Codable, CaseIterable, Sendable {
    case hearing = "Hearing"
    case explaining = "Explaining"
    case playing = "Playing"
    case creating = "Creating"
    public var instruction: String {
        switch self {
        case .hearing: "Hear the change"
        case .explaining: "Explain the pull"
        case .playing: "Make the resolution"
        case .creating: "Write another ending"
        }
    }
}
public struct TensionSource: Codable, Equatable, Sendable {
    public var pieceID: String
    public var fingerprint: String
    public var title: String
    public var scope: PassageScope
    public var tonic: Pitch
    public var changes: [HarmonyAnchor]
    public var pair: Int
    public var id: String {
        "tension:"
            + ScoreRevision.digest(
                "\(pieceID):\(fingerprint):\(scope.partID):\(scope.staff ?? 1):\(scope.from):\(scope.through):\(tonic.name):\(pair)"
            )
    }
    public var dominant: ChordSymbol { changes[pair].symbol }
    public var destination: ChordSymbol { changes[pair + 1].symbol }
    public var leadingTone: Pitch { dominant.root!.transposed(semitones: 4, steps: 2) }
    public var resolution: Pitch { destination.root! }
    public var reading: HarmonicReading { HarmonyTheory.suggestion(dominant, next: destination, tonic: tonic) }
    public init(piece: LibraryPiece, scope: PassageScope, tonic: Pitch) throws {
        guard (0..<1000).contains(scope.from), (0..<1000).contains(scope.through), scope.through >= scope.from,
            scope.through - scope.from < 8
        else { throw MusicError.invalid("Choose up to eight reviewed bars for this lesson.") }
        let anchors = try HarmonyTheory.anchors(piece: piece, scope: scope)
        guard anchors.count <= 32,
            let pair = anchors.indices.dropLast().first(where: {
                HarmonyTheory.resolves(anchors[$0].symbol, to: anchors[$0 + 1].symbol)
                    && anchors[$0 + 1].symbol.root?.pc != tonic.pc
            })
        else {
            throw MusicError.invalid(
                "This first lesson needs a dominant seventh resolving a fifth down to a major or minor chord other than home. Try the original A7 → Dm7 example, or choose another passage and local major key. Your other analysis remains editable."
            )
        }
        pieceID = piece.id
        fingerprint = piece.fingerprint
        title = piece.title
        self.scope = scope
        self.tonic = tonic
        changes = anchors
        self.pair = pair
        guard valid else {
            throw MusicError.invalid("Choose an ordinary major-key applied dominant for this first pathway.")
        }
    }
    public var valid: Bool {
        guard !pieceID.isEmpty, pieceID.count <= 100, ScoreRevision.valid(fingerprint), title.count <= 500,
            (0..<1000).contains(scope.from), (0..<1000).contains(scope.through), scope.through >= scope.from,
            scope.through - scope.from < 8, scope.partID.count <= 200,
            (1...16).contains(scope.staff ?? 1), (0..<7).contains(tonic.letter), (-1...1).contains(tonic.accidental),
            (2...32).contains(changes.count), pair >= 0, pair + 1 < changes.count,
            changes.allSatisfy(\.valid), Set(changes.map(\.id)).count == changes.count
        else { return false }
        guard
            changes.allSatisfy({
                $0.partID == scope.partID && $0.staff == (scope.staff ?? 1) && $0.bar <= scope.through
            }),
            changes.dropFirst().allSatisfy({ $0.bar >= scope.from }),
            zip(changes, changes.dropFirst()).allSatisfy({ ($0.bar, $0.tick) < ($1.bar, $1.tick) })
        else { return false }
        return HarmonyTheory.resolves(dominant, to: destination) && resolution.pc != tonic.pc
            && abs(leadingTone.accidental) <= 2 && reading.roman != "V7/?"
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
    /// Equal duration/register/dynamics isolate one change of chord quality.
    /// These are teaching reductions, not performances of the written passage.
    public func comparison(majorThird: Bool) -> Score {
        let top = melody[0]
        let root = top - 16
        let first = [root, root + 7, root + 10, top - (majorThird ? 0 : 1)]
        let destinationTop = top + 1
        let classes = (try? ChordRealization(destination).target(.complete).pitchClasses) ?? [resolution.pc]
        // Put the third-to-root line on top in both demonstrations. The exact
        // same destination voicing is used, independent of the comparison slot.
        let target = classes.map { destinationTop - mod(resolution.pc - $0) }.sorted()
        return Score(
            tempo: 76,
            notes: first.map { ScoreNote(midi: $0, start: 0, duration: 3.6) }
                + target.map { ScoreNote(midi: $0, start: 4, duration: 3.6) })
    }
    public var melody: [Int] {
        let first = 60 + leadingTone.pc
        return [first, first + 1]
    }
    public func answerDocument(instrument: EditorInstrument) throws -> EditorDocument {
        var doc = try EditorDocument.blank(instrument: instrument, bars: 2, meter: .init(4, 4))
        doc.title = String(("Another ending · " + title).prefix(120))
        doc.tempo = 76
        doc.harmonies = [EditorHarmony(bar: 0, symbol: dominant), EditorHarmony(bar: 1, symbol: destination)]
        doc.tensionSource = self
        doc.fifths = (-7...7).first { HarmonyTheory.majorTonic(fifths: $0) == tonic } ?? 0
        // Blank notes leave authorship to the learner. Harmony is an explicitly
        // adapted two-bar prompt; the source score is never overwritten.
        return try doc.validated()
    }
    public static func example() throws -> EditorDocument {
        var doc = try EditorDocument.blank(instrument: .piano, bars: 4, meter: .init(4, 4))
        doc.id = UUID(uuidString: "CADEC034-0000-4000-8000-000000000001")!
        doc.title = "Create and resolve tension · an original example"
        doc.tempo = 76
        doc.harmonies = try ["A7", "Dm7", "G7", "Cmaj7"].enumerated().map {
            EditorHarmony(bar: $0.offset, symbol: try ChordSymbol.parse($0.element))
        }
        let melody = [Pitch(0, 1), Pitch(1), Pitch(6), Pitch(0)]
        for i in doc.events.indices {
            let bar = doc.events[i].bar
            if doc.events[i].staff == 1 {
                doc.events[i].pitches = [EditorPitch(60 + melody[bar].pc, spelling: melody[bar])]
            } else {
                let symbol = doc.harmonies[bar].symbol
                let root = symbol.root!
                doc.events[i].pitches = [EditorPitch(36 + root.pc, spelling: root)]
            }
        }
        return try doc.validated()
    }
}
public enum TensionAction: Equatable, Sendable {
    case heard(Int)
    case reveal
    case hearChoice(Int)
    case explanation(Int)
    case midi([Int])
    case guitarReport
    case creation(String)
    case skip
}
public struct TensionSession: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var source: TensionSource
    public var instrument: EditorInstrument
    public var skill = TheorySkill.hearing
    public var completed = false
    public var independent = false
    public var assisted = true
    public var attempts = 0
    public var heard: Set<Int> = []
    public var majorSlot: Int
    public var reviews: [String: ReviewSchedule] = [:]
    public var reflection = ""
    public var updatedAt = Date()
    public init(source: TensionSource, instrument: EditorInstrument, majorSlot: Int = Int.random(in: 0...1)) {
        self.source = source
        self.instrument = instrument
        self.majorSlot = majorSlot
    }
    public var valid: Bool {
        source.valid && (0...1).contains(majorSlot) && (0...100000).contains(attempts) && heard.isSubset(of: [0, 1])
            && reflection.count <= 2000 && updatedAt.timeIntervalSince1970.isFinite && reviews.count <= 4
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
        majorSlot = Int.random(in: 0...1)
        updatedAt = now
    }
    public mutating func apply(_ action: TensionAction, now: Date = Date()) throws -> PracticeAttempt? {
        guard valid, !completed, now.timeIntervalSince1970.isFinite, attempts < 100000 else {
            throw MusicError.invalid("Open a current tension lesson before answering.")
        }
        if case .reveal = action {
            assisted = true
            updatedAt = now
            return nil
        }
        if case .heard(let slot) = action {
            guard skill == .hearing, (0...1).contains(slot) else {
                throw MusicError.invalid("This comparison belongs to the listening step.")
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
        case (.hearing, .hearChoice(let slot)):
            guard heard == [0, 1], (0...1).contains(slot) else {
                throw MusicError.invalid("Hear both comparisons before choosing.")
            }
            outcome = slot == majorSlot ? .correct : .incorrect
            choice = slot == 0 ? "A" : "B"
        case (.explaining, .explanation(let option)):
            guard (0...2).contains(option) else { throw MusicError.invalid("Choose an explanation.") }
            outcome = option == 0 ? .correct : .incorrect
            choice =
                ["Applied dominant of the following chord", "The home tonic", "The key has certainly changed"][option]
        case (.playing, .midi(let notes)):
            guard instrument == .piano, notes.count == 2, notes.allSatisfy({ (0...127).contains($0) }) else {
                throw MusicError.invalid(
                    "Play two separate notes, releasing each: the third, then the destination root.")
            }
            input = .midi
            played = notes
            target = source.melody
            outcome = mod(notes[0]) == source.leadingTone.pc && notes[1] == notes[0] + 1 ? .correct : .incorrect
        case (.playing, .guitarReport):
            guard instrument == .guitar else { throw MusicError.invalid("Choose the guitar activity first.") }
            input = .selfReport
            outcome = .revealed
            choice = "I played the two notes and chord shapes on guitar"
            assisted = true
        case (.creating, .creation(let text)):
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.count <= 2000 else {
                throw MusicError.invalid("Describe a choice you made in the ending, up to 2,000 characters.")
            }
            reflection = clean
            input = .selfReport
            outcome = .revealed
            choice = String(clean.prefix(500))
            assisted = true
        case (_, .skip):
            input = .selfReport
            outcome = .skipped
        default: throw MusicError.invalid("That answer belongs to another activity.")
        }
        let old = skill
        let ordinal = attempts + 1
        let grade: ReviewGrade =
            outcome == .incorrect
            ? .again : outcome == .correct && independent && !assisted && attempts == 0 ? .good : .supported
        var review = reviews[old.rawValue] ?? ReviewSchedule()
        review.record(grade, episode: id, input: input, now: now)
        reviews[old.rawValue] = review
        var evidence = PracticeAttempt(
            sessionID: id, activityID: source.id + ":" + old.rawValue,
            title: "Create and resolve tension · " + old.instruction, skills: ["Applied dominants", old.rawValue],
            input: input, outcome: outcome, assisted: assisted || !independent || attempts > 0, ordinal: ordinal,
            selectedChoice: choice, played: played, target: target, date: now)
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
public struct TensionPractice: Codable, Equatable, Sendable {
    public var sessions: [TensionSession] = []
    public var analyses: [ScoreAnalysis] = []
    public var activeID: UUID?
    public init() {}
    public var active: TensionSession? { sessions.first { $0.id == activeID } }
    public func validated() throws -> Self {
        guard sessions.count <= 100, analyses.count <= 200, Set(sessions.map(\.id)).count == sessions.count,
            Set(sessions.map { $0.source.id + ":" + $0.instrument.rawValue }).count == sessions.count,
            sessions.allSatisfy(\.valid), analyses.allSatisfy(\.valid), Set(analyses.map(\.id)).count == analyses.count,
            activeID == nil || active != nil
        else { throw MusicError.invalid("The saved theory pathways or score analyses are invalid.") }
        return self
    }
}
