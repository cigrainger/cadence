// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class AdaptiveVoicingTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private func session() throws -> SmoothSession { try .init(pathwayID: UUID(), now: date) }
    private func finishBlock(_ session: inout SmoothSession) throws {
        while let prompt = session.current {
            _ = try session.answer(prompt.solutions[0], now: date)
            try session.advance()
        }
    }
    func testDifferentValidVoicingsAndPermutedInputAreAccepted() throws {
        let prompt = SmoothSession.focusPrompt(0)
        XCTAssertEqual(prompt.title, "C → F")
        XCTAssertTrue(prompt.judge([60, 65, 69]).correct)
        XCTAssertTrue(prompt.judge([57, 60, 65]).correct)
        XCTAssertTrue(prompt.judge([69, 60, 65]).correct)
        XCTAssertGreaterThanOrEqual(prompt.solutions.count, 2)
        XCTAssertEqual(prompt.common, [60])
    }
    func testHarmonyShapeCommonToneAndMovementHaveSeparateFeedback() {
        let prompt = SmoothSession.focusPrompt(0)
        let wrong = prompt.judge([60, 64, 67])
        XCTAssertFalse(wrong.harmony)
        XCTAssertEqual(wrong.missing, [5, 9])
        XCTAssertEqual(wrong.extra, [4, 7])
        XCTAssertTrue(wrong.message.contains("chord tones"))
        let double = prompt.judge([60, 60, 65, 69])
        XCTAssertTrue(double.harmony)
        XCTAssertFalse(double.shape)
        XCTAssertTrue(double.message.contains("three"))
        let shifted = prompt.judge([65, 69, 72])
        XCTAssertTrue(shifted.harmony)
        XCTAssertFalse(shifted.common)
        XCTAssertTrue(shifted.message.contains("shared"))
        let leap = prompt.judge([53, 57, 60])
        XCTAssertTrue(leap.harmony)
        XCTAssertTrue(leap.common)
        XCTAssertFalse(leap.movement)
        XCTAssertTrue(leap.message.contains("nearer"))
        XCTAssertTrue(prompt.judge([60, 65, 69]).message.contains("connects"))
    }
    func testInvalidAndExtremeNotesNeverBecomeCorrectOrCrash() {
        let prompt = SmoothSession.focusPrompt(0)
        for notes in [
            [], [60], [60, 65], [60, 65, 69, 72], [-1, 65, 69], [60, 65, 128], [Int.min, 65, Int.max], [60, 65, 65],
        ] { XCTAssertFalse(prompt.judge(notes).correct) }
        for bad in [
            VoicingPrompt(fromRoot: 0, toRoot: Int.max, from: [60, 64, 67]),
            VoicingPrompt(fromRoot: 0, toRoot: 5, from: [Int.min, 64, 67]),
            VoicingPrompt(fromRoot: 0, toRoot: 5, from: []),
        ] {
            XCTAssertFalse(bad.valid)
            XCTAssertFalse(bad.judge([60, 65, 69]).correct)
            XCTAssertTrue(bad.solutions.isEmpty)
        }
    }
    func testAllAuthoredVariantsAndReachableTransferShapesHaveSolutions() throws {
        for index in 0..<3 {
            for variant in 0..<2 {
                let prompt = SmoothSession.focusPrompt(index, variant: variant)
                XCTAssertTrue(prompt.valid)
                XCTAssertFalse(prompt.solutions.isEmpty)
                for notes in prompt.solutions {
                    XCTAssertTrue(prompt.judge(notes).correct)
                    XCTAssertEqual(Set(notes.map { mod($0) }), prompt.targetPCs)
                }
            }
        }
        var s = try session()
        try finishBlock(&s)
        try s.nextPhase()
        try finishBlock(&s)
        try s.nextPhase()
        var frontier = [s]
        for _ in 0..<3 {
            frontier = try frontier.flatMap { session -> [SmoothSession] in
                let prompt = try XCTUnwrap(session.current)
                XCTAssertFalse(prompt.solutions.isEmpty)
                return try prompt.solutions.map { notes in
                    var next = session
                    _ = try next.answer(notes, now: date)
                    try next.advance()
                    _ = try next.validated()
                    return next
                }
            }
        }
        XCTAssertTrue(frontier.allSatisfy(\.blockComplete))
    }
    func testMissRetryAndRevealNeverBecomeIndependentSuccess() throws {
        var s = try session()
        let miss = try s.answer([60, 64, 67], now: date)
        XCTAssertEqual(miss.outcome, .incorrect)
        XCTAssertFalse(miss.assisted)
        XCTAssertThrowsError(try s.answer([60, 65, 69], now: date))
        XCTAssertThrowsError(try s.reveal())
        try s.retry()
        let passed = try s.answer([60, 65, 69], now: date)
        XCTAssertEqual(passed.ordinal, 2)
        XCTAssertTrue(passed.assisted)
        XCTAssertEqual(passed.outcome, .correct)
        try s.advance()
        XCTAssertFalse(s.hinted)
        try s.reveal()
        let hinted = try s.answer(try XCTUnwrap(s.current).solutions[0], now: date)
        XCTAssertTrue(hinted.assisted)
        XCTAssertEqual(s.responses.count, 3)
        _ = try s.validated()
    }
    func testFocusUsesObservedDifficultyAndAllowsLearnerChoice() throws {
        var s = try session()
        _ = try s.answer([53, 57, 60], now: date)
        try s.advance()
        try finishBlock(&s)
        s.suggestFocus()
        XCTAssertEqual(s.focusIndex, 0)
        XCTAssertTrue(s.focusReason.contains("movement"))
        try s.chooseFocus(2)
        XCTAssertEqual(s.focusIndex, 2)
        XCTAssertTrue(s.focusReason.contains("You chose"))
        try s.nextPhase()
        XCTAssertEqual(s.current, SmoothSession.focusPrompt(2))
        XCTAssertThrowsError(try s.chooseFocus(0))
        let response = try s.answer(try XCTUnwrap(s.current).solutions[0], now: date)
        XCTAssertTrue(response.assisted)
        try s.advance()
        XCTAssertEqual(s.current, SmoothSession.focusPrompt(2, variant: 1))
    }
    func testHarmonyMissSelectsNoteRepairAndNoMissKeepsPriorSuggestion() throws {
        var s = try session()
        _ = try s.answer([60, 64, 67], now: date)
        try s.advance()
        try finishBlock(&s)
        s.suggestFocus()
        XCTAssertTrue(s.focusReason.contains("chord tones"))
        var clean = try SmoothSession(pathwayID: UUID(), focusIndex: 2, focusReason: "Review G to C", now: date)
        try finishBlock(&clean)
        clean.suggestFocus()
        XCTAssertEqual(clean.focusIndex, 2)
    }
    func testCompleteSessionKeepsTransferIndependentAndCompositionSeparate() throws {
        var s = try session()
        try finishBlock(&s)
        try s.nextPhase()
        try finishBlock(&s)
        try s.nextPhase()
        XCTAssertEqual(s.phase, .transfer)
        XCTAssertEqual(s.current?.from, [62, 66, 69])
        XCTAssertFalse(s.hinted)
        try finishBlock(&s)
        XCTAssertEqual(s.independentTransferCount, 3)
        try s.nextPhase()
        XCTAssertEqual(s.phase, .composition)
        XCTAssertThrowsError(try s.nextPhase())
        XCTAssertThrowsError(try s.finish(reflection: "choice", compositionID: UUID(), fingerprint: nil))
        let score = try SmoothChangesRecipe.score(index: 1)
        let id = UUID()
        try s.finish(
            reflection: "Kept C in place", compositionID: id,
            fingerprint: LibraryPiece(source: .score(score)).fingerprint, now: date)
        XCTAssertEqual(s.phase, .summary)
        XCTAssertEqual(s.compositionID, id)
        XCTAssertEqual(s.responses.count, 8)
        XCTAssertThrowsError(try s.finish(reflection: "again", compositionID: nil, fingerprint: nil))
        _ = try s.validated()
        let restored = try JSONDecoder().decode(SmoothSession.self, from: JSONEncoder().encode(s)).validated()
        XCTAssertEqual(restored, s)
    }
    func testSkipDoesNotCreatePerformanceOrReviewCredit() throws {
        var s = try session()
        var history = PracticeProgress()
        let response = try s.answer([], now: date, skipped: true, input: .choice)
        XCTAssertEqual(response.outcome, .skipped)
        XCTAssertEqual(response.attempt(sessionID: s.id, pathwayID: s.pathwayID).input, .selfReport)
        try history.record(response, sessionID: s.id, pathwayID: s.pathwayID)
        XCTAssertTrue(history.cards.isEmpty)
        try s.advance()
        XCTAssertEqual(s.current?.from, [60, 65, 69])
        _ = try s.validated()
    }
    func testReviewSchedulesKeepRetryAndInputEvidenceSeparate() throws {
        var s = try session()
        var history = PracticeProgress()
        let first = try s.answer([60, 64, 67], now: date)
        try history.record(first, sessionID: s.id, pathwayID: s.pathwayID)
        try s.retry()
        let second = try s.answer([60, 65, 69], now: date.addingTimeInterval(2))
        try history.record(second, sessionID: s.id, pathwayID: s.pathwayID)
        let key = first.attempt(sessionID: s.id, pathwayID: s.pathwayID).activityID
        XCTAssertEqual(history.cards[key]?.review.lastGrade, .again)
        XCTAssertEqual(history.cards[key]?.review.encounters, 1)
        XCTAssertEqual(history.cards[key]?.review.intervalDays, 0)
        var screen = try session()
        let screenAnswer = try screen.answer([60, 65, 69], now: date, input: .choice)
        try history.record(screenAnswer, sessionID: screen.id, pathwayID: screen.pathwayID)
        XCTAssertEqual(history.cards.count, 2)
        var later = try session()
        let good = try later.answer([60, 65, 69], now: date.addingTimeInterval(86400))
        try history.record(good, sessionID: later.id, pathwayID: later.pathwayID)
        XCTAssertEqual(history.cards[key]?.review.intervalDays, 1)
        _ = try history.validated()
    }
    func testExactSpacedPromptCanOpenSessionWithoutBreakingLaterChecks() throws {
        let review = VoicingPrompt(fromRoot: 9, toRoot: 7, from: [61, 64, 69])
        var s = try SmoothSession(pathwayID: UUID(), openingReview: review, now: date)
        XCTAssertEqual(s.current, review)
        let answer = try s.answer(review.solutions[0], now: date)
        XCTAssertTrue(answer.attempt(sessionID: s.id, pathwayID: s.pathwayID).activityID.contains("transfer"))
        try s.advance()
        XCTAssertEqual(s.current, SmoothSession.focusPrompt(1))
        try finishBlock(&s)
        _ = try s.validated()
    }
    func testInvalidSettingsActionsAndForgedSavedDataAreRejected() throws {
        XCTAssertThrowsError(try SmoothSession(pathwayID: UUID(), minutes: 0))
        XCTAssertThrowsError(try SmoothSession(pathwayID: UUID(), focusIndex: 3))
        var s = try session()
        XCTAssertThrowsError(try s.advance())
        XCTAssertThrowsError(try s.retry())
        XCTAssertThrowsError(try s.nextPhase())
        XCTAssertThrowsError(try s.chooseFocus(0))
        XCTAssertThrowsError(try s.answer([], now: date))
        XCTAssertThrowsError(try s.answer([60, 65, 69], now: date, input: .singing))
        _ = try s.answer([60, 65, 69], now: date)
        let data = try JSONEncoder().encode(s)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for (key, value) in [
            ("version", 2 as Any), ("cursor", 9 as Any), ("minutes", 99 as Any), ("previous", [1, 2, 3] as Any),
            ("phase", "summary" as Any), ("phase", "composition" as Any), ("compositionFingerprint", "forged" as Any),
        ] {
            var json = original
            json[key] = value
            XCTAssertThrowsError(
                try JSONDecoder().decode(SmoothSession.self, from: JSONSerialization.data(withJSONObject: json))
                    .validated(), key)
        }
        var response = s.responses[0]
        response.played = [-5]
        XCTAssertFalse(response.valid)
        response = s.responses[0]
        response.ordinal = 2
        response.assisted = false
        XCTAssertFalse(response.valid)
        response = s.responses[0]
        response.skipped = true
        XCTAssertFalse(response.valid)
    }
    func testForgedCompletionAndForeignQuestionCannotSupplyEvidence() throws {
        var s = try session()
        _ = try s.answer([60, 65, 69], now: date)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
        json["phase"] = "composition"
        json["cursor"] = 0
        json["awaitingAdvance"] = false
        XCTAssertThrowsError(
            try JSONDecoder().decode(SmoothSession.self, from: JSONSerialization.data(withJSONObject: json)).validated()
        )
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
        var responses = try XCTUnwrap(json["responses"] as? [[String: Any]])
        responses[0]["prompt"] = ["fromRoot": 5, "toRoot": 0, "from": [60, 65, 69]]
        json["responses"] = responses
        XCTAssertThrowsError(
            try JSONDecoder().decode(SmoothSession.self, from: JSONSerialization.data(withJSONObject: json)).validated()
        )
        XCTAssertThrowsError(
            try SmoothSession(
                pathwayID: UUID(), openingReview: SmoothSession.focusPrompt(0), openingReviewInput: .singing))
    }
    func testPracticeMigrationAndBoundedArchiveRetainSessions() throws {
        // Use the actual old shape from our encoder; omitted optional fields decode.
        var snapshot = PracticeState()
        snapshot.schemaVersion = 4
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        json.removeValue(forKey: "smooth")
        let migrated = try JSONDecoder().decode(PracticeState.self, from: JSONSerialization.data(withJSONObject: json))
            .validated()
        XCTAssertEqual(migrated.schemaVersion, 18)
        XCTAssertNil(migrated.smooth)
        var book = SmoothPractice()
        try book.begin(session())
        XCTAssertThrowsError(try book.begin(session()))
        for _ in 0..<22 {
            var item = try XCTUnwrap(book.active)
            for _ in 0..<3 {
                try finishBlock(&item)
                try item.nextPhase()
            }
            try item.finish(reflection: "", compositionID: nil, fingerprint: nil, now: date)
            book.active = item
            try book.begin(session())
        }
        XCTAssertEqual(book.completed.count, 20)
        _ = try book.validated()
        snapshot.smooth = book
        _ = try snapshot.validated()
        book.completed.append(book.active!)
        XCTAssertThrowsError(try book.validated())
    }
}
