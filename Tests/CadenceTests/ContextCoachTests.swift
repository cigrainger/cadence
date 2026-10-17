// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

@testable import Cadence

final class ContextCoachTests: XCTestCase {
    private func context(_ id: String = "first") -> CoachContext {
        CoachContext(id: id, title: id, subtitle: "A small passage", reference: "Supplied notes: C E G")
    }
    @MainActor private func settled(_ session: ContextCoachSession) async throws {
        for _ in 0..<200 {
            if !session.reply.busy { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw MusicError.invalid("The fake coach request did not settle")
    }
    @MainActor func testOpeningAndSwitchingContextNeverSendsAndKeepsSeparateDrafts() {
        let session = ContextCoachSession()
        session.open(context(), prompt: "First question")
        session.includeContext = false
        session.typing = true
        session.presented = false
        XCTAssertFalse(session.typing)
        session.open(context("second"), prompt: "Second question")
        session.open(context())
        XCTAssertEqual(session.draft, "First question")
        XCTAssertFalse(session.includeContext)
        XCTAssertTrue(session.presented)
        XCTAssertFalse(session.reply.busy)
        XCTAssertTrue(session.lines.isEmpty)
        session.open(context(), prompt: "Replacement")
        XCTAssertEqual(session.draft, "First question")
    }
    @MainActor func testSuccessUsesVisibleContextAndConversationSurvivesPanelClosure() async throws {
        let session = ContextCoachSession()
        session.open(context(), prompt: "Explain this")
        var calls = 0
        session.send(
            apiKey: "fixture", model: "fixture",
            complete: { messages, _, _ in
                calls += 1
                XCTAssertEqual(messages.last?.role, "user")
                XCTAssertTrue(messages.last?.content.contains("Supplied notes: C E G") == true)
                return "A major triad"
            }, save: { XCTAssertEqual($0.context.id, "first") })
        session.presented = false
        try await settled(session)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(session.lines.map(\.text), ["Explain this", "A major triad"])
        XCTAssertTrue(session.draft.isEmpty)
        session.open(context("second"))
        XCTAssertTrue(session.lines.isEmpty)
        session.open(context())
        XCTAssertEqual(session.lines.count, 2)
    }
    @MainActor func testContextCanBeExcludedAndFailedRequestKeepsTheQuestion() async throws {
        let session = ContextCoachSession()
        session.open(context(), prompt: "Question only")
        session.includeContext = false
        session.send(
            apiKey: "fixture", model: "fixture",
            complete: { messages, _, _ in
                XCTAssertEqual(messages.last?.content, "Question only")
                throw MusicError.invalid("Provider unavailable")
            }, save: { _ in XCTFail("A failed request must not be saved") })
        try await settled(session)
        XCTAssertEqual(session.draft, "Question only")
        XCTAssertTrue(session.lines.isEmpty)
        XCTAssertNil(session.reply.pending)
    }
    @MainActor func testFailedSaveKeepsPaidReplyAndBlocksRetargetingUntilSaveOnlyRetry() async throws {
        let session = ContextCoachSession()
        session.open(context(), prompt: "Keep this reply")
        let failure = WriteFailure()
        var sends = 0
        var saved = 0
        session.send(
            apiKey: "fixture", model: "fixture",
            complete: { _, _, _ in
                sends += 1
                return "Received once"
            },
            save: { _ in
                if failure.enabled { throw MusicError.invalid("Disk unavailable") }
                saved += 1
            })
        try await settled(session)
        XCTAssertNotNil(session.reply.pending)
        XCTAssertTrue(session.lines.isEmpty)
        session.presented = false
        session.open(context("other"))
        XCTAssertEqual(session.context?.id, "first")
        session.send(
            apiKey: "fixture", model: "fixture",
            complete: { _, _, _ in
                XCTFail("No resend")
                return ""
            }, save: { _ in })
        failure.enabled = false
        session.reply.retrySave()
        session.reply.retrySave()
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(saved, 1)
        XCTAssertNil(session.reply.pending)
        XCTAssertEqual(session.lines.count, 2)
    }
    @MainActor func testCancelledLateReplyCannotEnterAnotherContext() async throws {
        let session = ContextCoachSession()
        session.open(context(), prompt: "Old question")
        var continuation: CheckedContinuation<String, Never>?
        session.send(
            apiKey: "fixture", model: "fixture",
            complete: { _, _, _ in
                await withCheckedContinuation { continuation = $0 }
            }, save: { _ in XCTFail("A late reply cannot commit") })
        for _ in 0..<100 {
            if continuation != nil { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let pending = try XCTUnwrap(continuation)
        session.open(context("blocked"))
        XCTAssertEqual(session.context?.id, "first")
        session.reply.cancel()
        session.open(context("second"), prompt: "New question")
        pending.resume(returning: "Late reply")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(session.context?.id, "second")
        XCTAssertEqual(session.draft, "New question")
        XCTAssertTrue(session.lines.isEmpty)
    }
    @MainActor func testOversizedOrEmptyRepliesDoNotBecomeConversationAndQuestionsAreBounded() async throws {
        let session = ContextCoachSession()
        session.open(context(), prompt: String(repeating: "x", count: PieceExchange.maximumQuestionCharacters + 1))
        session.send(
            apiKey: "fixture", model: "fixture",
            complete: { _, _, _ in
                XCTFail()
                return ""
            }, save: { _ in XCTFail() })
        XCTAssertFalse(session.reply.busy)
        session.draft = "A valid small question"
        session.send(
            apiKey: "fixture", model: String(repeating: "x", count: PieceExchange.maximumModelCharacters + 1),
            complete: { _, _, _ in
                XCTFail("Invalid model metadata must fail before sending")
                return ""
            }, save: { _ in XCTFail() })
        XCTAssertFalse(session.reply.busy)
        for answer in [" ", String(repeating: "x", count: PieceExchange.maximumAnswerCharacters + 1)] {
            session.draft = "Small question"
            session.send(apiKey: "fixture", model: "fixture", complete: { _, _, _ in answer }, save: { _ in XCTFail() })
            try await settled(session)
            XCTAssertTrue(session.lines.isEmpty)
            XCTAssertNil(session.reply.pending)
        }
    }
    @MainActor func testOpenQuestionLimitNeverSilentlyDiscardsAnUnsentDraft() {
        let session = ContextCoachSession()
        for index in 0..<24 { session.open(context(String(index)), prompt: "Question \(index)") }
        session.open(context("one-too-many"))
        XCTAssertEqual(session.context?.id, "23")
        session.open(context("0"))
        XCTAssertEqual(session.draft, "Question 0")
        session.draft = ""
        session.open(context("one-too-many"))
        XCTAssertEqual(session.context?.id, "one-too-many")
    }
    @MainActor func testExplicitDiscardOfUnsavableReplyDoesNotInventCompletionOrAnotherRequest() async throws {
        let session = ContextCoachSession()
        session.open(context(), prompt: "My question")
        var sends = 0
        session.send(
            apiKey: "fixture", model: "fixture",
            complete: { _, _, _ in
                sends += 1
                return "A received reply"
            }, save: { _ in throw MusicError.invalid("Original piece removed") })
        try await settled(session)
        XCTAssertNotNil(session.reply.pending)
        session.reply.discardPending()
        XCTAssertNil(session.reply.pending)
        XCTAssertNil(session.reply.completedID)
        XCTAssertEqual(session.draft, "My question")
        XCTAssertTrue(session.lines.isEmpty)
        session.open(context("new"))
        XCTAssertEqual(session.context?.id, "new")
        XCTAssertEqual(sends, 1)
    }
}
