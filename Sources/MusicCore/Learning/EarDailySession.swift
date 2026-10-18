// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum EarDailyMode: String, Codable, Sendable {
    case learning, recall, transfer
}

public enum EarDailyStage: String, Codable, CaseIterable, Sendable {
    case hear, imagine, play, review, create, complete
}

public struct EarDailyRecommendation: Equatable, Sendable {
    public var mode: EarDailyMode
    public var reason: String
    public static func choose(
        completed: Bool, independentFamiliar: Bool,
        familiarDue: Date?, transferDue: Date?, now: Date
    ) -> Self {
        func due(_ date: Date?) -> Bool {
            now.timeIntervalSince1970.isFinite && date.map { $0.timeIntervalSince1970.isFinite && $0 <= now } == true
        }
        if completed, independentFamiliar, due(transferDue) {
            return .init(
                mode: .transfer,
                reason:
                    "Your familiar phrase came back independently. Hear a new phrase once and try the idea in another piece."
            )
        }
        if completed, due(familiarDue) {
            return .init(
                mode: .recall, reason: "Time has passed. Bring the familiar phrase back before a replay or hint.")
        }
        return .init(
            mode: .learning,
            reason: completed
                ? "Your independent return is later. Supported practice and a musical answer stay open today."
                : "A first hearing, a short playing check and a musical answer will shape today’s practice.")
    }
}

/// A resumable invitation, with references to canonical journal evidence. Neither
/// detector results nor a coach's response advance the learner's chosen stage.
public struct EarDailySession: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let journeyID: UUID
    public let material: ScoreEarMaterial
    public let instrument: EditorInstrument
    public let mode: EarDailyMode
    public let created: Date
    public let reviewReadyAt: Date?
    public let answerID: UUID
    public private(set) var stage: EarDailyStage
    public private(set) var assisted: Bool
    public private(set) var revealed: Bool
    public private(set) var focusBar: Int?
    public private(set) var attemptIDs: [UUID]
    public private(set) var lastExposure: Date
    public private(set) var completedAt: Date?
    public private(set) var attemptStartedAt: Date?

    public init(
        journeyID: UUID, material: ScoreEarMaterial, instrument: EditorInstrument, mode: EarDailyMode,
        reviewReadyAt: Date? = nil, now: Date = Date()
    ) throws {
        id = UUID()
        self.journeyID = journeyID
        self.material = material
        self.instrument = instrument
        self.mode = mode
        created = now
        self.reviewReadyAt = reviewReadyAt
        answerID = UUID()
        stage = mode == .recall ? .imagine : .hear
        assisted = mode == .learning
        revealed = false
        focusBar = nil
        attemptIDs = []
        lastExposure = now
        completedAt = nil
        attemptStartedAt = nil
        guard valid else {
            throw MusicError.invalid("Choose valid ear material and wait until the independent return is ready.")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, journeyID, material, instrument, mode, created, reviewReadyAt, answerID
        case stage, assisted, revealed, focusBar, attemptIDs, lastExposure, completedAt, attemptStartedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        journeyID = try values.decode(UUID.self, forKey: .journeyID)
        material = try values.decode(ScoreEarMaterial.self, forKey: .material)
        instrument = try values.decode(EditorInstrument.self, forKey: .instrument)
        mode = try values.decode(EarDailyMode.self, forKey: .mode)
        created = try values.decode(Date.self, forKey: .created)
        reviewReadyAt = try values.decodeIfPresent(Date.self, forKey: .reviewReadyAt)
        answerID = try values.decode(UUID.self, forKey: .answerID)
        stage = try values.decode(EarDailyStage.self, forKey: .stage)
        assisted = try values.decode(Bool.self, forKey: .assisted)
        revealed = try values.decode(Bool.self, forKey: .revealed)
        focusBar = try values.decodeIfPresent(Int.self, forKey: .focusBar)
        attemptIDs = try values.decode([UUID].self, forKey: .attemptIDs)
        lastExposure = try values.decode(Date.self, forKey: .lastExposure)
        completedAt = try values.decodeIfPresent(Date.self, forKey: .completedAt)
        attemptStartedAt = try values.decodeIfPresent(Date.self, forKey: .attemptStartedAt)
        guard valid else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid saved daily ear session state."))
        }
    }

    /// Focus and tempo never create another review identity.
    public var activityID: String { material.id + ":daily-ear:" + instrument.rawValue }
    public var invitationTempo: Int {
        let base = min(140, max(50, Int(material.tempo.rounded())))
        return focusBar == nil ? base : max(50, Int(Double(base) * 0.8))
    }

    public var expectedNotes: [Int] {
        guard material.valid else { return [] }
        guard let focusBar else { return material.melody.map(\.midi) }
        guard (material.scope.fromBar...material.scope.throughBar).contains(focusBar) else { return [] }
        // The daily invitation uses the complete material's average bar length;
        // microphone capture separately verifies the actual source meter.
        let beatsPerBar = material.beats / Double(material.scope.throughBar - material.scope.fromBar + 1)
        let start = Double(focusBar - material.scope.fromBar) * beatsPerBar
        let end = start + beatsPerBar
        return material.melody.filter { $0.start >= start - 0.00001 && $0.start < end - 0.00001 }.map(\.midi)
    }

    public var valid: Bool {
        guard material.valid, created.timeIntervalSince1970.isFinite,
            lastExposure.timeIntervalSince1970.isFinite, lastExposure >= created,
            attemptStartedAt.map({ $0.timeIntervalSince1970.isFinite && $0 >= created && $0 <= lastExposure }) ?? true,
            reviewReadyAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
            mode == .learning || reviewReadyAt.map({ $0 <= created }) == true,
            attemptIDs.count <= 32, Set(attemptIDs).count == attemptIDs.count,
            !revealed || assisted, mode != .learning || assisted,
            focusBar.map({
                (material.scope.fromBar...material.scope.throughBar).contains($0) && assisted && !attemptIDs.isEmpty
            }) ?? true
        else { return false }
        if let completedAt {
            guard stage == .complete, completedAt.timeIntervalSince1970.isFinite,
                completedAt >= created, completedAt <= lastExposure
            else { return false }
        } else if stage == .complete {
            return false
        }
        switch stage {
        case .hear:
            return mode != .recall && !revealed && focusBar == nil && attemptIDs.isEmpty
        case .imagine:
            return focusBar == nil && attemptIDs.isEmpty
        case .review:
            return !attemptIDs.isEmpty
        case .play:
            return focusBar == nil || !attemptIDs.isEmpty
        case .create, .complete:
            return !attemptIDs.isEmpty || assisted
        }
    }

    public mutating func heard(now: Date = Date()) throws {
        try check(now: now, stages: [.hear, .imagine, .play, .review])
        // Transfer first supplies an unfamiliar stimulus. Replaying it supplies
        // support; the initial hearing itself does not forfeit independence.
        if stage == .hear {
            stage = .imagine
        } else {
            assisted = true
        }
        lastExposure = now
    }

    public mutating func imagined(now: Date = Date()) throws {
        try check(now: now, stages: [.imagine])
        stage = .play
        lastExposure = now
    }

    public mutating func reveal(now: Date = Date()) throws {
        try check(now: now, stages: [.imagine, .play, .review])
        revealed = true
        assisted = true
        lastExposure = now
    }

    /// Arming an independent capture is exposure, but is not a hint.
    public mutating func beganAttempt(now: Date = Date()) throws {
        try check(now: now, stages: [.play])
        // Re-arming after an interrupted or abandoned pass is a retry even when
        // no answer was kept. Persist this across navigation and app restarts.
        if attemptStartedAt != nil { assisted = true }
        attemptStartedAt = now
        lastExposure = now
    }

    /// Abandoned takes and source/coach visits delay the next return. A later
    /// visit must not rewrite the assistance or finish date of a completed session.
    public mutating func noteExposure(now: Date = Date()) throws {
        try check(now: now, stages: EarDailyStage.allCases)
        if stage != .complete { assisted = true }
        lastExposure = now
    }

    public mutating func retry(bar: Int? = nil, now: Date = Date()) throws {
        try check(now: now, stages: [.review, .play])
        guard stage == .review || (focusBar != nil && bar == nil) else {
            throw MusicError.invalid(
                "Keep the current take before choosing another focus; the whole phrase stays available.")
        }
        guard bar.map({ (material.scope.fromBar...material.scope.throughBar).contains($0) }) ?? true else {
            throw MusicError.invalid("Choose a focus bar inside the complete ear phrase.")
        }
        stage = .play
        focusBar = bar
        assisted = true
        lastExposure = now
    }

    public mutating func record(attemptID: UUID, now: Date = Date()) throws {
        try check(now: now, stages: [.play, .review])
        if stage == .review && attemptIDs.last == attemptID { return }
        guard stage == .play, !attemptIDs.contains(attemptID), attemptIDs.count < 32 else {
            throw MusicError.invalid("Keep a new journal attempt in play; the 32 saved references cannot be replaced.")
        }
        attemptIDs.append(attemptID)
        stage = .review
        lastExposure = now
    }

    public mutating func skip(now: Date = Date()) throws {
        try check(now: now, stages: [.imagine, .play, .review])
        stage = .create
        assisted = true
        lastExposure = now
    }

    public mutating func beginAnswer(now: Date = Date()) throws {
        try check(now: now, stages: [.review])
        stage = .create
        lastExposure = now
    }

    public mutating func finish(now: Date = Date()) throws {
        try check(now: now, stages: [.create])
        stage = .complete
        completedAt = now
        lastExposure = now
    }

    public mutating func finishReview(now: Date = Date()) throws {
        try check(now: now, stages: [.review])
        guard mode != .learning else {
            throw MusicError.invalid("Finish the first session with a musical answer; later reviews can end here.")
        }
        stage = .complete
        completedAt = now
        lastExposure = now
    }

    /// Exact sounding pitches and attack order only; no timing claim is made.
    /// Creating evidence does not record its reference or advance the session.
    public func midiAttempt(notes: [Int], now: Date, id: UUID = UUID()) throws -> PracticeAttempt {
        try check(now: now, stages: [.play])
        guard instrument == .piano, notes.count <= 128, notes.allSatisfy({ (0...127).contains($0) }),
            !expectedNotes.isEmpty
        else { throw MusicError.invalid("Use valid MIDI pitches for the selected piano phrase.") }
        return try attempt(
            id: id, date: now, input: .midi, played: notes,
            correct: notes == expectedNotes, assisted: assisted)
    }

    /// A pitch-only take can establish order without calibrated timing. Missing,
    /// disputed or uncertain pitches abstain instead of becoming an incorrect grade.
    public func microphoneAttempt(_ take: MicrophonePhraseTake) throws -> PracticeAttempt? {
        try check(now: take.date, stages: [.play])
        let source = take.plan.material
        guard instrument == .guitar, take.valid, !take.isArchivalOnly,
            source.id == material.id, source.fingerprint == material.fingerprint,
            source.scope.fromBar == material.scope.fromBar, source.scope.throughBar == material.scope.throughBar,
            source.scope.partID == material.scope.partID, source.staff == material.staff,
            source.voice == material.voice,
            Self.semantic(source) == Self.semantic(material),
            take.plan.fromBar == (focusBar ?? material.scope.fromBar),
            take.plan.throughBar == (focusBar ?? material.scope.throughBar),
            take.plan.timed.targets.map(\.pitch) == expectedNotes
        else {
            throw MusicError.invalid("This microphone take does not match the daily guitar phrase and selected scope.")
        }
        let report = take.report
        guard !expectedNotes.isEmpty, report.notes.count == expectedNotes.count, report.extras.isEmpty,
            report.notes.allSatisfy({ $0.pitch == .matched || $0.pitch == .wrong })
        else { return nil }
        return try attempt(
            id: take.id, date: take.date, input: .microphone, played: take.attacks.compactMap(\.midi),
            correct: report.notes.allSatisfy({ $0.pitch == .matched }), assisted: assisted || take.usedHint)
    }

    private func check(now: Date, stages: [EarDailyStage]) throws {
        guard valid, now.timeIntervalSince1970.isFinite, now >= lastExposure, stages.contains(stage) else {
            throw MusicError.invalid("This daily action is out of order or predates the saved exposure.")
        }
    }

    private func attempt(
        id: UUID, date: Date, input: PracticeInput, played: [Int], correct: Bool, assisted: Bool
    ) throws -> PracticeAttempt {
        var attempt = PracticeAttempt(
            sessionID: self.id, activityID: activityID, title: material.title, skills: ["Play it by ear"],
            input: input, outcome: correct ? .correct : .incorrect, assisted: assisted,
            played: played, target: expectedNotes, date: date)
        attempt.id = id
        attempt.pathwayID = journeyID
        attempt.pieceID = material.pieceID
        attempt.scoreFingerprint = material.fingerprint
        attempt.passageScope = PassageScope(
            partID: material.scope.partID, staff: material.staff,
            from: (focusBar ?? material.scope.fromBar) - 1,
            through: (focusBar ?? material.scope.throughBar) - 1)
        guard attempt.valid else { throw MusicError.invalid("Invalid daily ear journal evidence.") }
        return attempt
    }

    private static func semantic(_ material: ScoreEarMaterial) -> ScoreEarMaterial {
        var copy = material
        copy.title = ""
        copy.scope.partName = ""
        for index in copy.melody.indices {
            copy.melody[index].id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        }
        return copy
    }

    fileprivate func canReplace(_ old: Self) -> Bool {
        let followsStart =
            old.attemptStartedAt.map { previous in
                attemptStartedAt.map { $0 >= previous } ?? false
            } ?? true
        guard id == old.id, journeyID == old.journeyID, material == old.material,
            instrument == old.instrument, mode == old.mode, created == old.created,
            reviewReadyAt == old.reviewReadyAt, answerID == old.answerID, lastExposure >= old.lastExposure,
            attemptIDs.starts(with: old.attemptIDs), !old.assisted || assisted, !old.revealed || revealed,
            old.completedAt == nil || completedAt == old.completedAt, followsStart
        else { return false }
        // A replacement can include several explicit actions, including retries,
        // but cannot reopen a terminal stage or erase an already played phrase.
        switch old.stage {
        case .complete:
            return stage == .complete && attemptIDs == old.attemptIDs && focusBar == old.focusBar
                && assisted == old.assisted && revealed == old.revealed
        case .create:
            return (stage == .create || stage == .complete) && attemptIDs == old.attemptIDs
                && focusBar == old.focusBar && revealed == old.revealed
        case .play, .review:
            return stage != .hear && stage != .imagine
                && (stage != .review || old.stage == .review || attemptIDs.count > old.attemptIDs.count)
        case .imagine:
            return stage != .hear
        case .hear:
            return true
        }
    }
}

/// Bounded resumable sessions only. Grades and later review intervals belong to
/// PracticeProgress; this collection supplies an independent earliest-return gate.
public struct EarDailyPractice: Codable, Equatable, Sendable {
    public var sessions: [EarDailySession] = []
    public var selectedID: UUID?

    public init() {}

    public var active: EarDailySession? { sessions.first { $0.id == selectedID } }

    public func validated() throws -> Self {
        guard sessions.count <= 32, Set(sessions.map(\.id)).count == sessions.count,
            Set(sessions.map(\.answerID)).count == sessions.count,
            selectedID == nil || sessions.contains(where: { $0.id == selectedID }),
            sessions.allSatisfy(\.valid)
        else { throw MusicError.invalid("Invalid saved daily ear sessions.") }
        let references = sessions.flatMap(\.attemptIDs)
        guard Set(references).count == references.count else {
            throw MusicError.invalid("A journal attempt cannot belong to two daily ear sessions.")
        }
        return self
    }

    public mutating func open(_ session: EarDailySession) throws {
        _ = try validated()
        guard session.valid else { throw MusicError.invalid("Invalid daily ear session.") }
        if let old = sessions.first(where: { $0.id == session.id }) {
            guard old == session else { throw MusicError.invalid("Replace the existing daily session explicitly.") }
            selectedID = session.id
            return
        }
        guard sessions.count < 32 else {
            throw MusicError.invalid("The 32 daily sessions are full. Existing sessions are preserved.")
        }
        if session.mode != .learning, let ready = returnDate(material: session.material) {
            guard session.created >= ready, session.reviewReadyAt.map({ $0 >= ready }) == true else {
                throw MusicError.invalid("Wait a full day after the latest related exposure before independent recall.")
            }
        }
        var copy = self
        copy.sessions.append(session)
        copy.selectedID = session.id
        _ = try copy.validated()
        self = copy
    }

    public mutating func replace(_ session: EarDailySession) throws {
        _ = try validated()
        guard session.valid, let index = sessions.firstIndex(where: { $0.id == session.id }),
            session.canReplace(sessions[index])
        else { throw MusicError.invalid("This daily session is stale or changes its saved identity or content.") }
        var copy = self
        copy.sessions[index] = session
        _ = try copy.validated()
        self = copy
    }

    public func returnDate(material: ScoreEarMaterial) -> Date? {
        guard material.valid else { return nil }
        return sessions.filter { session in
            let source = session.material
            return source.pieceID == material.pieceID && source.scope.partID == material.scope.partID
                && source.staff == material.staff && source.voice == material.voice
                && source.scope.fromBar <= material.scope.throughBar
                && material.scope.fromBar <= source.scope.throughBar
        }.map(\.lastExposure).max()?.addingTimeInterval(24 * 3600)
    }
}

extension PracticeProgress {
    public mutating func recordDailyEar(_ attempt: PracticeAttempt) throws {
        guard attempt.valid, attempt.activityID.contains(":daily-ear:"),
            [.midi, .microphone].contains(attempt.input),
            [.correct, .incorrect].contains(attempt.outcome)
        else { throw MusicError.invalid("Only a conclusive daily pitch observation can update its review.") }
        let prior = cards[attempt.activityID]?.review
        let question = PracticeQuestion(
            id: attempt.activityID, exercise: .intervals, title: attempt.title,
            detail: "Pitch and order recall", choices: [], answer: 0, explanation: "")
        record(
            question, correct: attempt.outcome == .correct, firstTry: !attempt.assisted,
            revealed: attempt.assisted, now: attempt.date, episode: attempt.sessionID, input: attempt.input)
        // Practice before an established due date does not reset its interval.
        // The daily exposure gate independently prevents an immediate recall.
        if attempt.assisted, attempt.outcome == .correct, let prior, let due = prior.due,
            attempt.date < due, prior.lastGrade == .good
        {
            cards[attempt.activityID]?.schedule = prior
            cards[attempt.activityID]?.due = due
            cards[attempt.activityID]?.interval = max(0, due.timeIntervalSince(attempt.date))
        }
    }
}
