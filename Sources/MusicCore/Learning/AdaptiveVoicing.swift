// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A deliberately bounded musical task, not a fingering or artistic-quality grade.
/// Compare three ordered voices, allow any inversion, and keep shared pitches
/// in the same register. The five-semitone limit belongs to this exercise only.
public struct VoicingPrompt: Codable, Equatable, Sendable {
    public var fromRoot: Int
    public var toRoot: Int
    public var from: [Int]
    public init(fromRoot: Int, toRoot: Int, from: [Int]) {
        self.fromRoot = fromRoot
        self.toRoot = toRoot
        self.from = from
    }
    public var title: String { "\(Pitch.spelled(fromRoot).name) → \(Pitch.spelled(toRoot).name)" }
    public var targetPCs: Set<Int> { Set([0, 4, 7].map { mod(mod(toRoot) + $0) }) }
    public var common: [Int] { from.filter { targetPCs.contains(mod($0)) } }
    public var valid: Bool {
        (0...11).contains(fromRoot) && (0...11).contains(toRoot) && fromRoot != toRoot
            && from == Array(Set(from)).sorted() && from.count == 3 && from.allSatisfy { (48...84).contains($0) }
            && from.last! - from.first! <= 12
            && ChordJudgement.match(from, required: Set([0, 4, 7].map { mod(fromRoot + $0) }), bass: nil).correct
    }
    public func judge(_ notes: [Int]) -> VoicingFeedback {
        guard valid else {
            return .init(harmony: false, shape: false, common: false, movements: [], missing: [], extra: [])
        }
        let sorted = notes.sorted()
        let harmony = ChordJudgement.match(notes, required: targetPCs, bass: nil)
        let shape =
            notes.count == 3 && Set(notes).count == 3 && notes.allSatisfy { (48...84).contains($0) }
            && (sorted.last ?? 0) - (sorted.first ?? 0) <= 12
        let movements = shape && from.count == 3 ? zip(from, sorted).map { abs($0 - $1) } : []
        return .init(
            harmony: harmony.correct, shape: shape, common: common.allSatisfy { notes.contains($0) },
            movements: movements, missing: harmony.missing, extra: harmony.extra)
    }
    public var solutions: [[Int]] {
        guard valid else { return [] }
        let notes = (48...84).filter { targetPCs.contains(mod($0)) }
        var result: [[Int]] = []
        for a in notes.indices {
            for b in notes.indices where b > a {
                for c in notes.indices where c > b {
                    let chord = [notes[a], notes[b], notes[c]]
                    if judge(chord).correct { result.append(chord) }
                }
            }
        }
        return result.sorted { a, b in
            let x = judge(a).movements.reduce(0, +)
            let y = judge(b).movements.reduce(0, +)
            return x == y ? a.lexicographicallyPrecedes(b) : x < y
        }
    }
    public var isTransferKey: Bool { [fromRoot, toRoot].contains(2) || [fromRoot, toRoot].contains(9) }
    public func reviewID() -> String {
        "smooth-v1:\(isTransferKey ? "transfer" : "familiar"):\(fromRoot):\(toRoot):"
            + from.map(String.init).joined(separator: "-")
    }
}

public struct VoicingFeedback: Equatable, Sendable {
    public var harmony: Bool
    public var shape: Bool
    public var common: Bool
    public var movements: [Int]
    public var missing: [Int]
    public var extra: [Int]
    public var movement: Bool { movements.count == 3 && movements.allSatisfy { $0 <= 5 } }
    public var correct: Bool { harmony && shape && common && movement }
    public var message: String {
        if !harmony { return "Check the chord tones. There may be a missing or extra note." }
        if !shape {
            return
                "The harmony matches. For this exercise, use three different notes within one octave, between C3 and C6."
        }
        if !common { return "The harmony matches. Keep the shared note in its original octave for this change." }
        if !movement { return "The harmony matches. Try a nearer inversion: one voice moved more than five semitones." }
        return "That connects. Your chord tones and the movement both fit this exercise."
    }
}

public enum SmoothPhase: String, Codable, CaseIterable, Sendable {
    case opening, workshop, transfer, composition, summary
    public var title: String {
        switch self {
        case .opening: "Find your starting point"
        case .workshop: "Give one change some care"
        case .transfer: "Take the idea somewhere new"
        case .composition: "Make a phrase of your own"
        case .summary: "Something to take with you"
        }
    }
    public var label: String {
        switch self {
        case .opening: "Opening check"
        case .workshop: "Focused practice"
        case .transfer: "Try independently"
        case .composition: "Create"
        case .summary: "Reflection"
        }
    }
    public var count: Int {
        switch self {
        case .opening, .transfer: 3
        case .workshop: 2
        default: 0
        }
    }
}

public struct SmoothResponse: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var date: Date
    public var phase: SmoothPhase
    public var round: Int
    public var prompt: VoicingPrompt
    public var played: [Int]
    public var assisted: Bool
    public var ordinal: Int
    public var skipped: Bool
    public var input: PracticeInput
    public var feedback: VoicingFeedback { prompt.judge(played) }
    public var outcome: PracticeOutcome { skipped ? .skipped : feedback.correct ? .correct : .incorrect }
    public var valid: Bool {
        date.timeIntervalSince1970.isFinite && (0..<phase.count).contains(round) && prompt.valid
            && !prompt.solutions.isEmpty && (1...256).contains(ordinal) && played.count <= 128
            && played.allSatisfy { (0...127).contains($0) } && (skipped ? played.isEmpty : !played.isEmpty)
            && (ordinal == 1 || assisted) && (input == .midi || input == .choice)
    }
    public func attempt(sessionID: UUID, pathwayID: UUID) -> PracticeAttempt {
        var value = PracticeAttempt(
            sessionID: sessionID, activityID: prompt.reviewID() + ":" + input.rawValue,
            title: prompt.title + " · " + phase.label,
            skills: ["Smooth chord changes", "Voicing choices"], input: skipped ? .selfReport : input, outcome: outcome,
            assisted: assisted, ordinal: ordinal,
            expectedChoice: "Three chord tones; retain shared pitches; ordered voices move at most five semitones",
            keyPC: prompt.isTransferKey ? 2 : 0, played: played, date: date)
        value.id = id
        value.pathwayID = pathwayID
        return value
    }
}

/// Durable session state. All MIDI and UI adapters use these same transitions.
/// A fresh transfer prompt cannot inherit credit from a supported familiar one.
public struct SmoothSession: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public let version: Int
    public let pathwayID: UUID
    public let started: Date
    public let minutes: Int
    public let openingReview: VoicingPrompt?
    public let openingReviewInput: PracticeInput?
    public private(set) var phase = SmoothPhase.opening
    public private(set) var cursor = 0
    public private(set) var focusIndex: Int
    public private(set) var focusReason: String
    public private(set) var previous = [60, 64, 67]
    public private(set) var hinted = false
    public private(set) var awaitingAdvance = false
    public private(set) var responses: [SmoothResponse] = []
    public private(set) var reflection = ""
    public private(set) var compositionID: UUID?
    public private(set) var compositionFingerprint: String?
    public private(set) var finished: Date?
    public init(
        pathwayID: UUID, minutes: Int = 15, focusIndex: Int = 0,
        focusReason: String = "Begin with a familiar change, then choose what needs care.",
        openingReview: VoicingPrompt? = nil, openingReviewInput: PracticeInput? = nil, now: Date = Date()
    ) throws {
        guard [10, 15, 25].contains(minutes), (0...2).contains(focusIndex), focusReason.count <= 500,
            now.timeIntervalSince1970.isFinite,
            openingReview.map({ $0.valid && !$0.solutions.isEmpty }) ?? true,
            openingReviewInput.map({ $0 == .midi || $0 == .choice }) ?? true
        else { throw MusicError.invalid("These session settings are invalid.") }
        self.version = 1
        self.pathwayID = pathwayID
        self.minutes = minutes
        self.focusIndex = focusIndex
        self.focusReason = focusReason
        self.started = now
        self.openingReview = openingReview
        self.openingReviewInput = openingReview == nil ? nil : openingReviewInput ?? .midi
    }
    public var blockComplete: Bool { phase.count > 0 && cursor == phase.count }
    public var current: VoicingPrompt? {
        guard cursor >= 0, cursor < phase.count else { return nil }
        switch phase {
        case .opening:
            if let openingReview { return cursor == 0 ? openingReview : Self.focusPrompt(cursor) }
            return .init(fromRoot: [0, 5, 7][cursor], toRoot: [5, 7, 0][cursor], from: previous)
        case .workshop: return Self.focusPrompt(focusIndex, variant: cursor)
        case .transfer: return .init(fromRoot: [2, 9, 7][cursor], toRoot: [9, 7, 2][cursor], from: previous)
        default: return nil
        }
    }
    public static func focusPrompt(_ index: Int, variant: Int = 0) -> VoicingPrompt {
        let i = min(2, max(0, index))
        let v = min(1, max(0, variant))
        let notes = [[[60, 64, 67], [64, 67, 72]], [[60, 65, 69], [65, 69, 72]], [[59, 62, 67], [62, 67, 71]]]
        return .init(fromRoot: [0, 5, 7][i], toRoot: [5, 7, 0][i], from: notes[i][v])
    }
    public var lastResponse: SmoothResponse? { responses.last { $0.phase == phase && $0.round == cursor } }
    public var independentTransferCount: Int {
        responses.filter { $0.phase == .transfer && $0.outcome == .correct && $0.ordinal == 1 && !$0.assisted }.count
    }
    public mutating func reveal() throws {
        guard current != nil, !awaitingAdvance else {
            throw MusicError.invalid("Start the next attempt before opening a hint.")
        }
        hinted = true
    }
    public mutating func answer(
        _ notes: [Int], now: Date = Date(), skipped: Bool = false, input: PracticeInput = .midi, id: UUID = UUID()
    ) throws -> SmoothResponse {
        guard let prompt = current, !awaitingAdvance, responses.count < 256 else {
            throw MusicError.invalid("Move to the next attempt before answering again.")
        }
        let ordinal = responses.filter { $0.phase == phase && $0.round == cursor }.count + 1
        var response = SmoothResponse(
            date: now, phase: phase, round: cursor, prompt: prompt, played: notes.sorted(),
            assisted: hinted || ordinal > 1 || phase == .workshop, ordinal: ordinal, skipped: skipped, input: input)
        response.id = id
        guard response.valid else { throw MusicError.invalid("The keyboard answer is invalid.") }
        responses.append(response)
        awaitingAdvance = true
        return response
    }
    public mutating func retry() throws {
        guard current != nil, awaitingAdvance else { throw MusicError.invalid("There is no answer to retry.") }
        awaitingAdvance = false
        hinted = true
    }
    public mutating func advance() throws {
        guard let prompt = current, awaitingAdvance, let answer = lastResponse else {
            throw MusicError.invalid("Play or skip this change first.")
        }
        previous = answer.outcome == .correct ? answer.played : prompt.solutions[0]
        cursor += 1
        hinted = false
        awaitingAdvance = false
    }
    public mutating func chooseFocus(_ index: Int) throws {
        guard phase == .opening && blockComplete, (0...2).contains(index) else {
            throw MusicError.invalid("Choose your focus after the opening check.")
        }
        focusIndex = index
        focusReason = "You chose to spend time on " + Self.focusPrompt(index).title + "."
    }
    public mutating func suggestFocus() {
        guard phase == .opening, blockComplete else { return }
        let misses = (0...2).map { index in
            responses.filter {
                $0.phase == .opening && $0.prompt.fromRoot == Self.focusPrompt(index).fromRoot
                    && $0.prompt.toRoot == Self.focusPrompt(index).toRoot && $0.outcome == .incorrect
            }.count
        }
        if let largest = misses.max(), largest > 0, let index = misses.firstIndex(of: largest) {
            focusIndex = index
            let harmonyMiss = responses.contains {
                $0.phase == .opening && $0.prompt.fromRoot == Self.focusPrompt(index).fromRoot
                    && $0.prompt.toRoot == Self.focusPrompt(index).toRoot && !$0.skipped && !$0.feedback.harmony
            }
            focusReason =
                harmonyMiss
                ? "Some chord tones needed another try on " + Self.focusPrompt(index).title
                    + ". Start with the notes, then connect the shapes."
                : "The chord tones matched on " + Self.focusPrompt(index).title
                    + ", but the movement needed another try. Explore a nearer inversion."
        }
    }
    public mutating func nextPhase() throws {
        guard blockComplete else { throw MusicError.invalid("Finish or skip the remaining changes first.") }
        switch phase {
        case .opening: phase = .workshop
        case .workshop:
            phase = .transfer
            previous = [62, 66, 69]
        case .transfer: phase = .composition
        default: throw MusicError.invalid("This session has no next playing stage.")
        }
        cursor = 0
        hinted = false
        awaitingAdvance = false
    }
    public mutating func finish(reflection: String, compositionID: UUID?, fingerprint: String?, now: Date = Date())
        throws
    {
        guard phase == .composition, reflection.count <= 3000, now.timeIntervalSince1970.isFinite,
            (compositionID == nil) == (fingerprint == nil), fingerprint.map(ScoreRevision.valid) ?? true
        else { throw MusicError.invalid("Check the composition and reflection before finishing.") }
        self.reflection = reflection
        self.compositionID = compositionID
        compositionFingerprint = fingerprint
        finished = now
        phase = .summary
    }
    public func validated() throws -> Self {
        guard version == 1, [10, 15, 25].contains(minutes), (0...2).contains(focusIndex), focusReason.count <= 500,
            started.timeIntervalSince1970.isFinite, finished.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
            (0...phase.count).contains(cursor), previous.count == 3, previous.allSatisfy({ (48...84).contains($0) }),
            previous == Array(Set(previous)).sorted(),
            responses.count <= 256, Set(responses.map(\.id)).count == responses.count, responses.allSatisfy(\.valid),
            reflection.count <= 3000, (phase == .summary) == (finished != nil),
            (compositionID == nil) == (compositionFingerprint == nil),
            compositionFingerprint.map(ScoreRevision.valid) ?? true,
            openingReview.map({ $0.valid && !$0.solutions.isEmpty }) ?? true,
            (openingReview == nil) == (openingReviewInput == nil),
            openingReviewInput.map({ $0 == .midi || $0 == .choice }) ?? true,
            !awaitingAdvance || lastResponse != nil,
            current.map({ $0.valid && !$0.solutions.isEmpty }) ?? true
        else { throw MusicError.invalid("This saved chord session is invalid or needs a newer Cadence.") }
        // Derive the musical prompts again instead of trusting a saved answer
        // to redefine its own question or manufacture completion.
        var consumed = 0
        let phases: [SmoothPhase] = [.opening, .workshop, .transfer]
        for (phaseIndex, part) in phases.enumerated() {
            let activeIndex = SmoothPhase.allCases.firstIndex(of: phase)!
            let completedRounds = phaseIndex < activeIndex ? part.count : phaseIndex == activeIndex ? cursor : 0
            var prior = part == .transfer ? [62, 66, 69] : [60, 64, 67]
            for round in 0..<part.count {
                let answers = responses.filter { $0.phase == part && $0.round == round }
                let expected: VoicingPrompt
                if part == .workshop {
                    expected = Self.focusPrompt(focusIndex, variant: round)
                } else if part == .opening, let openingReview {
                    expected = round == 0 ? openingReview : Self.focusPrompt(round)
                } else {
                    expected = .init(
                        fromRoot: (part == .transfer ? [2, 9, 7] : [0, 5, 7])[round],
                        toRoot: (part == .transfer ? [9, 7, 2] : [5, 7, 0])[round], from: prior)
                }
                guard round >= completedRounds || !answers.isEmpty,
                    phaseIndex <= activeIndex || answers.isEmpty,
                    phaseIndex != activeIndex || round <= cursor || answers.isEmpty
                else { throw MusicError.invalid("A saved session has skipped its recorded steps.") }
                for (ordinal, answer) in answers.enumerated() {
                    guard answer.prompt == expected, answer.ordinal == ordinal + 1, consumed < responses.count,
                        responses[consumed].id == answer.id
                    else { throw MusicError.invalid("A saved answer does not match its session prompt.") }
                    consumed += 1
                }
                if let last = answers.last { prior = last.outcome == .correct ? last.played : expected.solutions[0] }
            }
        }
        guard consumed == responses.count, !awaitingAdvance || current != nil,
            lastResponse == nil || awaitingAdvance || hinted
        else { throw MusicError.invalid("The saved session position does not match its answers.") }
        return self
    }
}

public struct SmoothPractice: Codable, Equatable, Sendable {
    public var active: SmoothSession?
    public var completed: [SmoothSession] = []
    public init() {}
    public mutating func begin(_ session: SmoothSession) throws {
        let checked = try session.validated()
        if let active {
            guard active.phase == .summary else {
                throw MusicError.invalid("Resume your current session before beginning another.")
            }
            completed.append(active)
            completed = Array(completed.suffix(20))
        }
        active = checked
    }
    public func validated() throws -> Self {
        guard completed.count <= 20, Set(completed.map(\.id)).count == completed.count,
            completed.allSatisfy({ $0.phase == .summary }), !completed.contains(where: { $0.id == active?.id })
        else { throw MusicError.invalid("The saved sessions are invalid.") }
        if let active { _ = try active.validated() }
        for item in completed { _ = try item.validated() }
        return self
    }
}

extension PracticeProgress {
    public mutating func record(_ response: SmoothResponse, sessionID: UUID, pathwayID: UUID) throws {
        guard response.valid else { throw MusicError.invalid("This voicing response is invalid.") }
        guard !response.skipped else { return }
        let attempt = response.attempt(sessionID: sessionID, pathwayID: pathwayID)
        let question = PracticeQuestion(
            id: attempt.activityID, exercise: .triads, title: attempt.title, detail: "", choices: [], answer: 0,
            explanation: "")
        _ = record(
            question, correct: response.feedback.correct, firstTry: response.ordinal == 1,
            revealed: response.assisted || response.phase == .workshop,
            now: response.date, episode: sessionID, input: response.input)
    }
}
