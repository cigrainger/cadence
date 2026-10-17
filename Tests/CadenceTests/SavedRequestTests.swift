// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore
import XCTest

@testable import Cadence

final class SavedRequestTests: XCTestCase {
    @MainActor private func settled(_ request: SavedRequest<String>) async throws {
        for _ in 0..<100 {
            if !request.busy { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Request did not settle")
    }

    @MainActor func testSuccessfulReplyPublishesCompletionOnlyAfterCommit() async throws {
        let request = SavedRequest<String>()
        var saved: [String] = []
        request.run(
            request: { "reply" },
            commit: {
                XCTAssertNil(request.completedID)
                XCTAssertEqual(request.pending, "reply")
                saved.append($0)
            })
        XCTAssertTrue(request.busy)
        XCTAssertNotNil(request.started)
        try await settled(request)
        XCTAssertEqual(saved, ["reply"])
        XCTAssertNotNil(request.completedID)
        XCTAssertNil(request.pending)
        XCTAssertNil(request.started)
        let id = request.completedID
        request.retrySave()
        XCTAssertEqual(request.completedID, id)
        XCTAssertEqual(saved.count, 1)
    }

    @MainActor func testFailedCommitKeepsReplyAndRetriesWithoutAnotherRequest() async throws {
        let request = SavedRequest<String>()
        var sends = 0
        var commits = 0
        let failure = WriteFailure()
        request.run(
            request: {
                sends += 1
                return "paid reply"
            },
            commit: { _ in
                commits += 1
                if failure.enabled { throw MusicError.invalid("Disk unavailable") }
            })
        try await settled(request)
        XCTAssertEqual(request.pending, "paid reply")
        XCTAssertNil(request.completedID)
        XCTAssertTrue(request.error?.contains("try saving again") == true)
        request.run(
            request: {
                XCTFail("A pending reply must block another send")
                return "other"
            }, commit: { _ in })
        request.accept("replacement", commit: { _ in XCTFail("Must not replace the pending reply") })
        request.cancel()
        XCTAssertEqual(request.pending, "paid reply")
        failure.enabled = false
        request.retrySave()
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(commits, 2)
        XCTAssertNil(request.pending)
        XCTAssertNil(request.error)
        XCTAssertNotNil(request.completedID)
    }

    @MainActor func testCancellationRejectsLateReplyAndDoesNotCommit() async throws {
        let request = SavedRequest<String>()
        var reply: CheckedContinuation<String, Never>?
        request.run(request: { await withCheckedContinuation { reply = $0 } }, commit: { _ in XCTFail("Late commit") })
        for _ in 0..<100 {
            if reply != nil { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let continuation = try XCTUnwrap(reply)
        request.accept("external", commit: { _ in XCTFail("Cannot replace an active request") })
        request.cancel()
        XCTAssertFalse(request.busy)
        XCTAssertNil(request.started)
        XCTAssertTrue(request.error?.contains("already sent may still be charged") == true)
        continuation.resume(returning: "late")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(request.pending)
        XCTAssertNil(request.completedID)
    }

    @MainActor func testOlderCompletionCannotClearNewerBusyStateOrOverwriteItsReply() async throws {
        let request = SavedRequest<String>()
        var old: CheckedContinuation<String, Never>?
        var current: CheckedContinuation<String, Never>?
        var saved: [String] = []
        request.run(request: { await withCheckedContinuation { old = $0 } }, commit: { saved.append($0) })
        for _ in 0..<100 {
            if old != nil { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        request.cancel()
        request.run(request: { await withCheckedContinuation { current = $0 } }, commit: { saved.append($0) })
        for _ in 0..<100 {
            if current != nil { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try XCTUnwrap(old).resume(returning: "old")
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(request.busy)
        XCTAssertNil(request.error)
        XCTAssertTrue(saved.isEmpty)
        try XCTUnwrap(current).resume(returning: "new")
        try await settled(request)
        XCTAssertEqual(saved, ["new"])
    }

    @MainActor func testSendFailureClearsBusyAndCanBeRetriedExplicitly() async throws {
        let request = SavedRequest<String>()
        request.run(request: { throw MusicError.invalid("Provider unavailable") }, commit: { _ in XCTFail() })
        try await settled(request)
        XCTAssertEqual(request.error, "Provider unavailable")
        XCTAssertNil(request.pending)
        XCTAssertNil(request.completedID)
        request.run(request: { "retry" }, commit: { XCTAssertEqual($0, "retry") })
        try await settled(request)
        XCTAssertNil(request.error)
        XCTAssertNotNil(request.completedID)
    }

    @MainActor func testAcceptedReplyUsesTheSameAtomicSaveBoundary() {
        let request = SavedRequest<String>()
        let failure = WriteFailure()
        request.accept("received", commit: { _ in if failure.enabled { throw MusicError.invalid("Read-only folder") } })
        XCTAssertEqual(request.pending, "received")
        XCTAssertNil(request.completedID)
        failure.enabled = false
        request.retrySave()
        XCTAssertNil(request.pending)
        XCTAssertNotNil(request.completedID)
        request.cancel()
        XCTAssertNil(request.error)
    }
}
