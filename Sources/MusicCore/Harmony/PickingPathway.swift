// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum PickingStyle: String, Codable, CaseIterable, Sendable {
    case travis = "Travis picking"
    case classical = "Classical arpeggio"
    case strumming = "Strumming"
    public var detail: String {
        switch self {
        case .travis: "Alternate two bass strings on the beats; let the fingers answer between them."
        case .classical: "A p–i–m–a arpeggio: keep the thumb and upper fingers relaxed and even."
        case .strumming: "Down, rest, down–up, rest–up, down–up. Keep the hand moving through the rests."
        }
    }
}
extension PickingStyle {
    /// Relative gestures over a voicing: one definition feeds selection,
    /// notation, tab and sound. Silent strums retain their rhythmic slots.
    fileprivate func steps(_ strings: [Int], pitches: [Int]) -> [(targets: [Int], cue: String?)] {
        guard strings.count >= 4 else { return [] }
        let bass = strings[0]
        let alternate = strings[1]
        // Keep familiar left-hand shapes. Choose treble strings that retain
        // their colour tones instead of forcing a new barre shape for a fixed
        // pair of upper strings. Finger choices remain explicit suggestions.
        func treble(_ count: Int, bass: [Int]) -> [Int] {
            let available = Array(strings.dropFirst(bass.count))
            var groups: [[Int]] = [[]]
            for string in available { groups += groups.filter { $0.count < count }.map { $0 + [string] } }
            let desired = Set(strings.map { mod(pitches[$0]) })
            return groups.reversed().first {
                $0.count == count && Set((bass + $0).map { mod(pitches[$0]) }) == desired
            } ?? Array(available.suffix(count))
        }
        switch self {
        case .classical:
            let upper = treble(3, bass: [bass])
            return zip(
                [[bass], [upper[0]], [upper[1]], [upper[2]], [upper[1]], [upper[0]], [upper[1]], [upper[2]]],
                ["p", "i", "m", "a", "m", "i", "m", "a"]
            ).map { ($0, $1) }
        case .travis:
            let upper = treble(2, bass: [bass, alternate])
            return zip(
                [[bass, upper[0]], [upper[1]], [alternate], [upper[0]], [bass], [upper[1]], [alternate], [upper[0]]],
                ["p + i", "m", "p", "i", "p", "m", "p", "i"]
            ).map { ($0, $1) }
        case .strumming:
            return (0..<8).map { slot in
                let targets = [1, 4].contains(slot) ? [] : (slot % 2 == 0 ? strings : Array(strings.suffix(3)))
                return (targets, targets.isEmpty ? nil : (slot % 2 == 0 ? "↓" : "↑"))
            }
        }
    }
}
public enum PickingStage: String, Codable, CaseIterable, Sendable {
    case hear, muted, chord, changes, create, independent, complete
    public var title: String {
        switch self {
        case .hear: "Hear and tap"
        case .muted: "Muted strings"
        case .chord: "One comfortable chord"
        case .changes: "Carry it through the changes"
        case .create: "Make your accompaniment"
        case .independent: "Bring it back"
        case .complete: "Keep it growing"
        }
    }
}
/// A source revision and explicit six-string voicings, not a second score model.
/// The first lesson supports 4/4 with changes at bar boundaries. Other material
/// remains untouched rather than being silently stretched or reharmonised.
public struct PickingMaterial: Codable, Equatable, Sendable {
    public var pieceID: String
    public var fingerprint: String
    public var title: String
    public var scope: PassageScope
    public var tuning: Tuning
    public var capo: Int
    public var chords: [ChordSymbol]
    public var frets: [[Int]]
    public var id: String {
        "picking:"
            + ScoreRevision.digest(
                "\(pieceID):\(fingerprint):\(scope.partID):\(scope.staff ?? 1):\(scope.from):\(scope.through):\(tuning.pitches):\(capo)"
            )
    }
    public init(piece: LibraryPiece, scope: PassageScope, tuning: Tuning, capo: Int) throws {
        guard (0..<1000).contains(scope.from), (0..<1000).contains(scope.through), scope.through >= scope.from,
            scope.through - scope.from < 8,
            tuning.pitches.count == 6, tuning.pitches.allSatisfy({ (24...88).contains($0) }), (0...9).contains(capo)
        else { throw MusicError.invalid("Choose one to eight bars and a six-string guitar tuning.") }
        let source = try ChangesSource(piece: piece, from: scope.from, through: scope.through, partID: scope.partID)
        let plan = try source.plan(staff: scope.staff ?? 1)
        guard plan.barTicks.allSatisfy({ $0 == 1920 }), plan.barUnits.allSatisfy({ $0 == 4 }),
            plan.steps.allSatisfy({ $0.tick == 0 && $0.chord.symbol.kind != .none })
        else {
            throw MusicError.invalid(
                "Start with 4/4 and chord changes on bar lines. Mid-bar changes and N.C. need another lesson.")
        }
        _ = try ReviewedSource.pages(piece: piece, from: plan.steps.first?.bar ?? scope.from, through: scope.through)
        var chords: [ChordSymbol] = []
        var shapes: [[Int]] = []
        for bar in scope.from...scope.through {
            guard let step = plan.steps.last(where: { $0.bar <= bar }) else {
                throw MusicError.invalid("Add a chord symbol at the start of this passage.")
            }
            let target = try step.chord.target(.complete)
            let options = target.guitarVoicings(tuning: tuning, capo: capo).filter {
                Self.validShape($0.frets, target: target, tuning: tuning, capo: capo)
            }
            guard let shape = options.first else {
                throw MusicError.invalid(
                    "\(step.chord.symbol.label) has no supported four-string shape in this tuning. Choose simpler changes or another passage."
                )
            }
            chords.append(step.chord.symbol)
            shapes.append(shape.frets)
        }
        pieceID = piece.id
        fingerprint = piece.fingerprint
        title = piece.title
        self.scope = .init(partID: source.partID, staff: plan.staff, from: scope.from, through: scope.through)
        self.tuning = tuning
        self.capo = capo
        self.chords = chords
        frets = shapes
    }
    public var valid: Bool {
        guard !pieceID.isEmpty, pieceID.count <= 100, ScoreRevision.valid(fingerprint), title.count <= 500,
            (0..<1000).contains(scope.from), scope.through >= scope.from, scope.through - scope.from < 8,
            scope.partID.count <= 200, (1...16).contains(scope.staff ?? 1),
            chords.count == scope.through - scope.from + 1, frets.count == chords.count,
            tuning.pitches.count == 6, tuning.pitches.allSatisfy({ (24...88).contains($0) }), (0...9).contains(capo)
        else { return false }
        return zip(chords, frets).allSatisfy { symbol, shape in
            guard symbol.valid, let target = try? ChordRealization(symbol).target(.complete) else { return false }
            return Self.validShape(shape, target: target, tuning: tuning, capo: capo)
        }
    }
    private static func validShape(_ shape: [Int], target: ChangesTarget, tuning: Tuning, capo: Int) -> Bool {
        guard shape.count == 6, shape.allSatisfy({ (-1...12).contains($0) }) else { return false }
        let strings = shape.indices.filter { shape[$0] >= 0 }
        guard strings.count >= 4 else { return false }
        let pitches = strings.map { tuning.pitches[$0] + capo + shape[$0] }
        guard target.judge(pitches).correct, pitches.allSatisfy({ (21...108).contains($0) }) else { return false }
        return PickingStyle.allCases.allSatisfy { style in
            Set(
                style.steps(strings, pitches: tuning.pitches.indices.map { tuning.pitches[$0] + capo + shape[$0] })
                    .flatMap(\.targets).map { mod(tuning.pitches[$0] + capo + shape[$0]) })
                == target.pitchClasses
        }
    }

    public func current(in piece: LibraryPiece) -> Bool {
        guard valid, piece.id == pieceID, piece.fingerprint == fingerprint,
            let source = try? ChangesSource(
                piece: piece, from: scope.from, through: scope.through, partID: scope.partID),
            let plan = try? source.plan(staff: scope.staff ?? 1),
            (try? ReviewedSource.pages(piece: piece, from: plan.steps.first?.bar ?? scope.from, through: scope.through))
                != nil
        else { return false }
        // Saved valid voicings remain choices even if a future ranking changes.
        // Revalidating a source never reruns the expensive fingering search.
        return chords.enumerated().allSatisfy { index, symbol in
            plan.steps.last(where: { $0.bar <= scope.from + index })?.chord.symbol == symbol
        }
    }
    public func document(style: PickingStyle, tempo: Int = 72, oneChord: Bool = false, strongerBackbeat: Bool = false)
        throws -> EditorDocument
    {
        guard valid, (20...180).contains(tempo) else {
            throw MusicError.invalid("Review the source and choose a tempo from 20 to 180.")
        }
        var document = try EditorDocument.blank(instrument: .guitar, bars: chords.count, meter: .init(4, 4))
        document.title = String((style.rawValue + " · " + title).prefix(120))
        document.tuning = tuning
        document.capo = capo
        document.tempo = tempo
        document.pickingSource = self
        document.pickingStyle = style
        document.events = []
        for bar in chords.indices {
            let index = oneChord ? 0 : bar
            let shape = frets[index]
            let strings = shape.indices.filter { shape[$0] >= 0 }
            document.harmonies.append(.init(bar: bar, symbol: chords[index]))
            for (slot, step) in style.steps(
                strings, pitches: tuning.pitches.indices.map { tuning.pitches[$0] + capo + shape[$0] }
            ).enumerated() {
                let targets = step.targets
                let cue = step.cue
                var event = EditorEvent(
                    bar: bar, rhythm: .init(240),
                    pitches: targets.map {
                        EditorPitch(tuning.pitches[$0] + capo + shape[$0], string: $0, fret: shape[$0])
                    }, accent: strongerBackbeat ? [2, 6].contains(slot) : slot == 0)
                event.picking = cue
                document.events.append(event)
            }
        }
        return try document.validated()
    }
}
public enum PickingAction: Equatable, Sendable {
    case tried, needsWork, skip, reveal
    case observation(MonophonicTake)
}
public struct PickingSession: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var material: PickingMaterial
    public var style: PickingStyle
    public var stage = PickingStage.hear
    public var review = ReviewSchedule()
    public var episode = UUID()
    public var supported = true
    public var takes: [MonophonicTake] = []
    public var updatedAt = Date()
    public init(material: PickingMaterial, style: PickingStyle) {
        self.material = material
        self.style = style
    }
    public var key: String { material.id + ":" + style.rawValue }
    public var valid: Bool {
        material.valid && review.valid && takes.count <= 8 && takes.allSatisfy(\.valid)
            && Set(takes.map(\.id)).count == takes.count
            && updatedAt.timeIntervalSince1970.isFinite
    }
    public mutating func apply(_ action: PickingAction, now: Date) throws -> PracticeAttempt {
        guard valid, stage != .complete, now.timeIntervalSince1970.isFinite else {
            throw MusicError.invalid("Reopen this pathway before practising.")
        }
        let previous = stage
        var outcome = PracticeOutcome.revealed
        switch action {
        case .observation(let take):
            guard stage == .chord, take.valid, let shape = material.frets.first,
                let string = shape.indices.first(where: { shape[$0] >= 0 }),
                take.target == material.tuning.pitches[string] + material.capo + shape[string]
            else { throw MusicError.invalid("That observation belongs to another bass-note task.") }
            if !takes.contains(where: { $0.id == take.id }) {
                takes.append(take)
                takes = Array(takes.suffix(8))
            }
        case .reveal: supported = true
        case .needsWork: review.record(.again, episode: episode, input: .selfReport, now: now)
        case .skip:
            outcome = .skipped
            advance()
        case .tried: advance()
        }
        if stage == .complete {
            review.record(
                action == .skip || supported ? .supported : .good, episode: episode, input: .selfReport, now: now)
        }
        updatedAt = now
        var attempt = PracticeAttempt(
            sessionID: episode, activityID: key + ":" + previous.rawValue,
            title: style.rawValue + " · " + previous.title, skills: ["Guitar picking", previous.title],
            input: .selfReport, outcome: outcome, assisted: supported,
            selectedChoice: action == .needsWork
                ? "Needs a focused retry"
                : action == .skip
                    ? "Skipped"
                    : action == .reveal ? "Opened demonstration" : "I tried this on guitar; technique not measured",
            date: now)
        if case .observation(let take) = action {
            attempt.input = .microphone
            attempt.selectedChoice = String(take.summary.prefix(500))
        }
        attempt.pieceID = material.pieceID
        attempt.scoreFingerprint = material.fingerprint
        return attempt
    }
    private mutating func advance() {
        // Independent recall is scheduled later, not claimed at the end of a guided pass.
        stage =
            stage == .create || stage == .independent
            ? .complete : PickingStage.allCases[PickingStage.allCases.firstIndex(of: stage)! + 1]
    }
    public mutating func beginReturn() {
        stage = .independent
        episode = UUID()
        supported = false
    }
}
public struct PickingPractice: Codable, Equatable, Sendable {
    public var sessions: [PickingSession] = []
    public var activeID: UUID?
    public init() {}
    public var active: PickingSession? { sessions.first { $0.id == activeID } }
    public func validated() throws -> Self {
        guard sessions.count <= 100, sessions.allSatisfy(\.valid), Set(sessions.map(\.id)).count == sessions.count,
            Set(sessions.map(\.key)).count == sessions.count, activeID == nil || active != nil
        else { throw MusicError.invalid("The saved picking pathways are invalid.") }
        return self
    }
}
