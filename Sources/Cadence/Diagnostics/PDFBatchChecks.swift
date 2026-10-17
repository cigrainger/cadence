// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore
import PDFKit

/// Local, deterministic checks. These never read a key or contact a provider.
@MainActor enum PDFBatchChecks {
    static func asset() throws -> PDFImportAsset {
        let original = try PDFImportAsset(
            data: Data(contentsOf: PDFImportExamples.url("guitar")), filename: "Study.pdf")
        let book = PDFDocument()
        for i in 0..<3 { book.insert(original.document.page(at: 0)!.copy() as! PDFPage, at: i) }
        return try PDFImportAsset(data: book.dataRepresentation()!, filename: "Three-page reading study.pdf")
    }
    static func wait(_ queue: PDFImportQueue) async throws {
        let end = Date().addingTimeInterval(5)
        while queue.working && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        guard !queue.working else {
            queue.stop()
            throw MusicError.invalid("The local queue check did not finish.")
        }
    }
    static func verify(directory: URL) async throws -> [String: Bool] {
        let asset = try asset()
        let state = AppState(storageOverride: directory)
        let queue = PDFImportQueue()
        let id = try state.createPDFBatch(
            asset: asset, pages: [1, 2, 3], instrument: .guitar, model: .recommended, passage: "")
        let reply = PDFTranscriptionReply(
            transcription: PDFTranscription(.guitarExample), model: PDFImportModel.sol.rawValue, costUSD: 0.03)
        var calls = 0
        var singlePage = true
        var savedBeforeSend = true
        queue.start(state: state, scoreID: id, asset: asset, pages: [1, 2, 3], model: .recommended) {
            data, _, _, model in
            calls += 1
            singlePage = singlePage && PDFDocument(data: data)?.pageCount == 1 && model == .sol
            let disk = AppState(storageOverride: directory)
            savedBeforeSend = savedBeforeSend && disk.editor.active.pdfSource?.pages?[calls - 1].attempts == 1
            if calls == 2 { throw MusicError.invalid("Fixture: page two failed.") }
            return reply
        }
        try await wait(queue)
        var checks = [
            "pdfBatchSendsOnePage": singlePage && calls == 3, "pdfBatchSavesBeforeSending": savedBeforeSend,
            "pdfBatchContinuesAfterFailure": state.editor.active.barCount == 8
                && state.editor.active.pdfSource?.pages?.map(\.status) == [.ready, .failed, .ready],
        ]
        let restored = AppState(storageOverride: directory)
        checks["pdfBatchRestoresPartialScore"] = restored.editor.active == state.editor.active
        let fileID = state.editor.active.pdfSource!.fileID
        checks["pdfBatchOneOriginal"] =
            try FileManager.default.contentsOfDirectory(
                at: directory.appendingPathComponent("PDF Sources"), includingPropertiesForKeys: nil
            ).count == 1
        queue.start(state: restored, scoreID: id, asset: asset, pages: [2], model: .recommended) { _, _, _, _ in
            calls += 1
            return reply
        }
        try await wait(queue)
        checks["pdfBatchRetriesOnlyFailedPage"] =
            calls == 4 && restored.editor.active.barCount == 12
            && restored.editor.active.pdfSource?.range(for: 2) == 4..<8
            && restored.editor.active.pdfSource?.fileID == fileID
        try restored.changePDFScore(id) { doc in
            try doc.setPitch(doc.events[0].id, midi: 62)
            doc.pdfSource?.setReviewed(true, page: 1)
            doc.pdfSource?.setReviewed(true, page: 2)
            doc.pdfSource?.setReviewed(true, page: 3)
        }
        let before = restored.editor.active
        queue.start(state: restored, scoreID: id, asset: asset, pages: [1], model: .recommended) { _, _, _, _ in
            calls += 1
            return reply
        }
        try await wait(queue)
        checks["pdfBatchRetryStagesReplacement"] =
            restored.editor.active.events == before.events
            && restored.editor.active.pdfSource?.pages?[0].replacement != nil
            && restored.editor.active.pdfSource?.pages?[0].reviewed == true
        let reopened = AppState(storageOverride: directory)
        checks["pdfBatchReplacementPersists"] = reopened.editor.active == restored.editor.active
        let candidate = reopened.editor.active.pdfSource!.pages![0].replacement!
        try reopened.changePDFScore(id) { try $0.replacePDFPage(1, with: candidate) }
        checks["pdfBatchApplyChangesOnlyOnePage"] =
            reopened.editor.active.events.filter { $0.bar >= 4 } == before.events.filter { $0.bar >= 4 }
            && reopened.editor.active.pdfSource?.pages?.map(\.reviewed) == [false, true, true]
        checks["pdfBatchAccountsEachAttempt"] =
            reopened.editor.active.pdfSource?.pages?.map(\.attempts) == [2, 2, 1]
            && abs((reopened.editor.active.pdfSource?.costUSD ?? 0) - 0.12) < 0.0001
            && reopened.editor.active.pdfSource?.pages?[1].unpricedAttempts == 1
        let second = try reopened.createPDFBatch(
            asset: asset, pages: [1, 2, 3], instrument: .guitar, model: .recommended, passage: "")
        var stopCalls = 0
        queue.start(state: reopened, scoreID: second, asset: asset, pages: [1, 2, 3], model: .recommended) {
            _, _, _, _ in
            stopCalls += 1
            if stopCalls == 1 { return reply }
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return reply
        }
        let deadline = Date().addingTimeInterval(5)
        while stopCalls < 2 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        queue.stop()
        let stopped = reopened.editor.active
        try await Task.sleep(nanoseconds: 50_000_000)
        checks["pdfBatchStopKeepsCompletedPages"] =
            stopCalls == 2 && stopped.barCount == 4
            && stopped.pdfSource?.pages?.map(\.status) == [.ready, .stopped, .pending]
        checks["pdfBatchStopRejectsLateResults"] = reopened.editor.active == stopped && !queue.working
        let final = AppState(storageOverride: directory)
        checks["pdfBatchStoppedQueuePersists"] = final.editor.active == stopped
        checks["pdfBatchSharedOriginalAcrossScores"] =
            try FileManager.default.contentsOfDirectory(
                at: directory.appendingPathComponent("PDF Sources"), includingPropertiesForKeys: nil
            ).count == 1
        try final.changePDFScore(second) { doc in doc.pdfSource!.pages![1].status = .reading }
        let recovered = AppState(storageOverride: directory)
        checks["pdfBatchRestartDoesNotRetry"] =
            recovered.editor.active.pdfSource?.pages?[1].status == .stopped
            && recovered.editor.active.pdfSource?.pages?[1].attempts == 1
        let storageURL = directory.appendingPathComponent("editor.json")
        let saved = try Data(contentsOf: storageURL)
        let old = recovered.editor
        try FileManager.default.removeItem(at: storageURL)
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: storageURL)
            try? saved.write(to: storageURL)
        }
        do {
            try recovered.changePDFScore(second) { $0.title = "Unsaved" }
            checks["pdfBatchSaveFailureAtomic"] = false
        } catch { checks["pdfBatchSaveFailureAtomic"] = recovered.editor == old }
        var blockedCalls = 0
        queue.start(state: recovered, scoreID: second, asset: asset, pages: [3], model: .recommended) { _, _, _, _ in
            blockedCalls += 1
            return reply
        }
        try await wait(queue)
        checks["pdfBatchCannotSendBeforeSaving"] = blockedCalls == 0 && recovered.editor == old && queue.error != nil
        state.midi.shutdown()
        restored.midi.shutdown()
        reopened.midi.shutdown()
        final.midi.shutdown()
        recovered.midi.shutdown()
        return checks
    }
    static func preview(state: AppState) throws {
        let asset = try asset()
        var doc = try EditorDocument.blank(instrument: .guitar, bars: 1)
        doc.title = "Three-page reading study"
        var source = PDFScoreSource(
            filename: asset.filename, page: 1, model: PDFImportModel.sol.rawValue, costUSD: 0.06)
        source.pages = (1...3).map { PDFImportPage(page: $0, model: PDFImportModel.sol.rawValue) }
        doc.pdfSource = source
        let candidate = PDFPageReplacement(
            document: .guitarExample, model: PDFImportModel.sol.rawValue,
            warnings: ["Check the pitches and rhythm against the original, especially at the page join."])
        try doc.replacePDFPage(1, with: candidate)
        try doc.replacePDFPage(3, with: candidate)
        doc.pdfSource!.pages![0].reviewed = true
        for i in 0...2 {
            doc.pdfSource!.pages![i].attempts = 1
            doc.pdfSource!.pages![i].costUSD = i == 1 ? 0 : 0.03
        }
        doc.pdfSource!.pages![1].status = .failed
        doc.pdfSource!.pages![1].error =
            "The model did not finish within four minutes. Retry this page or choose a shorter passage."
        doc.pdfSource!.pages![1].unpricedAttempts = 1
        if CommandLine.arguments.contains("--pdf-replacement-preview") {
            doc.pdfSource!.pages![0].replacement = candidate
        }
        state.editor.documents.append(try doc.validated())
        state.editor.activeID = doc.id
        state.destination = .editor
        state.pdfImportScoreID = doc.id
        state.pdfReviewPage = 3
        PDFImportDiagnostics.checks["batchSourceLinks"] =
            doc.pdfSource?.range(for: 3) == 4..<8 && doc.pdfSource?.reference(at: 4).page == 3
    }
}
