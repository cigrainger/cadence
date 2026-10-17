// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import PDFKit
import XCTest

@testable import Cadence

final class PDFQueueIntegrationTests: XCTestCase {
    @MainActor private func fixture() throws -> (
        WorkspaceStorage, LibraryWorkspace, PDFImportQueue, UUID, PDFImportAsset
    ) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let storage = WorkspaceStorage(directory: url)
        let owner = LibraryWorkspace(storage: storage)
        owner.load()
        var document = try EditorDocument.blank(instrument: .guitar, bars: 1)
        document.pdfSource = PDFScoreSource(filename: "Original.pdf", page: 1, model: PDFImportModel.sol.rawValue)
        document.pdfSource!.pages = (1...3).map { PDFImportPage(page: $0, model: PDFImportModel.sol.rawValue) }
        var library = owner.editor
        library.documents.append(document)
        try owner.commitScores(library)
        return (storage, owner, PDFImportQueue(), document.id, try PDFBatchChecks.asset())
    }
    private var reply: PDFTranscriptionReply {
        .init(transcription: PDFTranscription(.guitarExample), model: PDFImportModel.sol.rawValue, costUSD: 0.03)
    }
    @MainActor private func wait(_ queue: PDFImportQueue) async throws {
        let deadline = Date().addingTimeInterval(5)
        while queue.working && Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(queue.working)
    }
    @MainActor func testPartialFailureSendsOnlyOnePageAndContinuesThenRetriesExplicitly() async throws {
        let (_, owner, queue, id, asset) = try fixture()
        var calls = 0
        queue.start(workspace: owner, scoreID: id, asset: asset, pages: [1, 2, 3], model: .sol) { data, _, _, _ in
            calls += 1
            XCTAssertEqual(PDFDocument(data: data)?.pageCount, 1)
            XCTAssertEqual(owner.editor.documents.first { $0.id == id }!.pdfSource!.pages![calls - 1].status, .reading)
            if calls == 2 { throw MusicError.invalid("Provider unavailable") }
            return self.reply
        }
        try await wait(queue)
        var document = try XCTUnwrap(owner.editor.documents.first { $0.id == id })
        XCTAssertEqual(document.pdfSource!.pages!.map(\.status), [.ready, .failed, .ready])
        XCTAssertEqual(document.barCount, 8)
        XCTAssertEqual(calls, 3)
        queue.start(workspace: owner, scoreID: id, asset: asset, pages: [2], model: .sol) { _, _, _, _ in
            calls += 1
            return self.reply
        }
        try await wait(queue)
        document = try XCTUnwrap(owner.editor.documents.first { $0.id == id })
        XCTAssertEqual(document.barCount, 12)
        XCTAssertEqual(document.pdfSource!.pages!.map(\.attempts), [1, 2, 1])
        XCTAssertEqual(document.pdfSource!.pages![1].unpricedAttempts, 1)
    }
    @MainActor func testReceivedReplySurvivesDiskConflictAndSaveRetryDoesNotSendOrReprice() async throws {
        let (storage, owner, queue, id, asset) = try fixture()
        var bytes: Data?
        var calls = 0
        queue.start(workspace: owner, scoreID: id, asset: asset, pages: [1, 2], model: .sol) { _, _, _, _ in
            calls += 1
            bytes = try Data(contentsOf: storage.editor.url)
            try Data("foreign edit".utf8).write(to: storage.editor.url)
            return self.reply
        }
        try await wait(queue)
        XCTAssertEqual(queue.pendingPage, 1)
        XCTAssertEqual(calls, 1)
        queue.start(workspace: owner, scoreID: id, asset: asset, pages: [2], model: .sol) { _, _, _, _ in
            XCTFail("Pending paid reply must block another request")
            return self.reply
        }
        queue.stop()
        XCTAssertEqual(queue.pendingPage, 1)
        try XCTUnwrap(bytes).write(to: storage.editor.url)
        queue.retrySave()
        queue.retrySave()
        let document = try XCTUnwrap(owner.editor.documents.first { $0.id == id })
        XCTAssertNil(queue.pendingPage)
        XCTAssertEqual(document.pdfSource!.pages!.map(\.attempts), [1, 0, 0])
        XCTAssertEqual(document.pdfSource!.costUSD!, 0.03, accuracy: 0.00001)
        XCTAssertEqual(calls, 1)
    }
    @MainActor func testStopRejectsLateReplyAndOldTaskCannotClearANewerRun() async throws {
        let (_, owner, queue, id, asset) = try fixture()
        var gate: CheckedContinuation<PDFTranscriptionReply, Never>?
        queue.start(workspace: owner, scoreID: id, asset: asset, pages: [1], model: .sol) { _, _, _, _ in
            await withCheckedContinuation { gate = $0 }
        }
        for _ in 0..<1000 {
            if gate != nil { break }
            await Task.yield()
        }
        let continuation = try XCTUnwrap(gate)
        queue.stop()
        XCTAssertEqual(owner.editor.documents.first { $0.id == id }!.pdfSource!.pages![0].status, .stopped)
        queue.start(workspace: owner, scoreID: id, asset: asset, pages: [2], model: .sol) { _, _, _, _ in self.reply }
        continuation.resume(returning: reply)
        try await wait(queue)
        XCTAssertEqual(
            owner.editor.documents.first { $0.id == id }!.pdfSource!.pages!.map(\.status), [.stopped, .ready, .pending])
        XCTAssertNil(queue.pendingPage)
    }
    @MainActor func testRemovedSourceRejectsLateReplyAndExplicitDiscardMakesNoRequest() async throws {
        let (_, owner, queue, id, asset) = try fixture()
        queue.start(workspace: owner, scoreID: id, asset: asset, pages: [1], model: .sol) { _, _, _, _ in
            try owner.changePDFScore(id) { $0.pdfSource!.fileID = UUID() }
            return self.reply
        }
        try await wait(queue)
        XCTAssertEqual(queue.pendingPage, 1)
        XCTAssertEqual(owner.editor.documents.first { $0.id == id }!.barCount, 1)
        queue.discardReply()
        XCTAssertNil(queue.pendingPage)
        XCTAssertTrue(queue.error?.contains("could not be saved") == true)
    }
    @MainActor func testFailedAttemptSaveNeverSendsAndInvalidSelectionIsIdle() async throws {
        let (storage, owner, queue, id, asset) = try fixture()
        queue.start(workspace: owner, scoreID: id, asset: asset, pages: [999], model: .sol) { _, _, _, _ in
            XCTFail()
            return self.reply
        }
        XCTAssertFalse(queue.working)
        try Data("changed".utf8).write(to: storage.editor.url)
        queue.start(workspace: owner, scoreID: id, asset: asset, pages: [1], model: .sol) { _, _, _, _ in
            XCTFail("No paid send before durable attempt")
            return self.reply
        }
        try await wait(queue)
        XCTAssertNotNil(queue.error)
        XCTAssertNil(queue.pendingPage)
    }
}
