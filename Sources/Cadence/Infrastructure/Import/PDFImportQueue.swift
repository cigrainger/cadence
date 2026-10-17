// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import Foundation
import MusicCore

/// A serial, explicitly retried queue. Each attempt is durable before sending;
/// received replies survive a failed local save without another paid request.
@MainActor final class PDFImportQueue: ObservableObject {
    typealias Request = (Data, EditorInstrument, String, PDFImportModel) async throws -> PDFTranscriptionReply
    private struct Pending {
        var page: Int
        var attempt: Int
        var sourceID: UUID
        var reply: PDFTranscriptionReply
    }
    @Published private(set) var working = false
    @Published private(set) var currentPage: Int?
    @Published private(set) var started: Date?
    @Published private(set) var pendingPage: Int?
    @Published var error: String?
    private var pending: Pending?
    private var job: Task<Void, Never>?
    private var runID = UUID()
    private weak var workspace: LibraryWorkspace?
    private var scoreID: UUID?
    private var changed: () -> Void = {}

    func start(
        workspace: LibraryWorkspace, scoreID: UUID, asset: PDFImportAsset, pages: [Int], model: PDFImportModel,
        passage: String? = nil, changed: @escaping () -> Void = {}, request: @escaping Request
    ) {
        guard !working, pending == nil, workspace.acceptsImports,
            let score = workspace.editor.documents.first(where: { $0.id == scoreID }),
            let source = score.pdfSource, let records = source.pages
        else { return }
        let chosen = records.map(\.page).filter { pages.contains($0) }
        guard !chosen.isEmpty else { return }
        self.workspace = workspace
        self.scoreID = scoreID
        self.changed = changed
        error = nil
        working = true
        runID = UUID()
        let token = runID
        job = Task { @MainActor in
            defer {
                if runID == token {
                    working = false
                    currentPage = nil
                    started = nil
                    job = nil
                }
            }
            for page in chosen {
                guard !Task.isCancelled, runID == token else { return }
                currentPage = page
                started = Date()
                let data: Data
                let attempt: Int
                let instruction: String
                do {
                    data = try asset.pagePDF(page)
                    guard let live = workspace.editor.documents.first(where: { $0.id == scoreID }),
                        live.pdfSource?.fileID == source.fileID,
                        let record = live.pdfSource?.pages?.first(where: { $0.page == page })
                    else { throw MusicError.invalid("The page or its original source changed.") }
                    instruction = passage ?? record.passage
                    attempt = record.attempts + 1
                    try workspace.changePDFScore(scoreID) { document in
                        guard let i = document.pdfSource?.pages?.firstIndex(where: { $0.page == page }) else {
                            throw MusicError.invalid("The page is no longer in this score.")
                        }
                        document.pdfSource!.pages![i].status = .reading
                        document.pdfSource!.pages![i].error = nil
                        document.pdfSource!.pages![i].attempts = attempt
                        document.pdfSource!.pages![i].unpricedAttempts += 1
                        document.pdfSource!.pages![i].passage = instruction
                    }
                    changed()
                } catch {
                    self.error = "The import could not start: " + error.localizedDescription
                    return
                }
                do {
                    let reply = try await request(data, score.instrument, instruction, model)
                    try Task.checkCancellation()
                    guard runID == token else { return }
                    pending = Pending(page: page, attempt: attempt, sourceID: source.fileID, reply: reply)
                    pendingPage = page
                    retrySave()
                    if pending != nil { return }
                } catch {
                    guard !Task.isCancelled, runID == token else { return }
                    do {
                        try updatePage(page, sourceID: source.fileID, attempt: attempt) { document, i in
                            document.pdfSource!.pages![i].status =
                                document.pdfSource!.pages![i].barCount > 0 ? .ready : .failed
                            document.pdfSource!.pages![i].error = String(error.localizedDescription.prefix(4000))
                        }
                    } catch {
                        self.error = "Progress could not be saved. The queue has stopped: " + error.localizedDescription
                        return
                    }
                }
            }
        }
    }

    private func updatePage(
        _ page: Int, sourceID: UUID, attempt: Int, change: (inout EditorDocument, Int) throws -> Void
    ) throws {
        guard let workspace, let scoreID else { throw MusicError.invalid("The import workspace is unavailable.") }
        try workspace.changePDFScore(scoreID) { document in
            guard document.pdfSource?.fileID == sourceID,
                let i = document.pdfSource?.pages?.firstIndex(where: { $0.page == page }),
                document.pdfSource!.pages![i].attempts == attempt,
                document.pdfSource!.pages![i].status == .reading
            else { throw MusicError.invalid("This reply belongs to an earlier page or import attempt.") }
            try change(&document, i)
        }
        changed()
    }

    func retrySave() {
        guard let pending else { return }
        do {
            try updatePage(pending.page, sourceID: pending.sourceID, attempt: pending.attempt) { document, i in
                let reply = pending.reply
                if let cost = reply.costUSD {
                    guard cost.isFinite, (0...10000).contains(cost) else {
                        throw MusicError.invalid("The reported request cost is invalid.")
                    }
                    document.pdfSource!.pages![i].costUSD += cost
                    document.pdfSource!.pages![i].unpricedAttempts -= 1
                    document.pdfSource!.costUSD = document.pdfSource!.pages!.reduce(0) { $0 + $1.costUSD }
                }
                do {
                    let draft = try reply.transcription.makeDocument(
                        instrument: document.instrument, tuning: document.tuning, capo: document.capo)
                    let candidate = PDFPageReplacement(
                        document: draft.document, model: reply.model, warnings: draft.warnings)
                    var proposed = document
                    try proposed.replacePDFPage(pending.page, with: candidate)
                    if document.pdfSource!.pages![i].barCount > 0 {
                        document.pdfSource!.pages![i].replacement = candidate
                        document.pdfSource!.pages![i].status = .ready
                        document.pdfSource!.pages![i].error = nil
                    } else {
                        document = proposed
                    }
                } catch {
                    document.pdfSource!.pages![i].status = document.pdfSource!.pages![i].barCount > 0 ? .ready : .failed
                    document.pdfSource!.pages![i].error = String(error.localizedDescription.prefix(4000))
                }
            }
            self.pending = nil
            pendingPage = nil
            error = nil
        } catch {
            self.error =
                "Page \(pending.page) was received but could not be saved. Keep this window open and retry saving; no new request is needed. "
                + error.localizedDescription
        }
    }

    func stop() {
        guard working else { return }
        runID = UUID()
        job?.cancel()
        job = nil
        working = false
        started = nil
        // A paid reply waiting for disk recovery must remain saveable.
        if pending == nil, let workspace, let scoreID, let page = currentPage {
            do {
                try workspace.changePDFScore(scoreID) { document in
                    guard let i = document.pdfSource?.pages?.firstIndex(where: { $0.page == page }),
                        document.pdfSource!.pages![i].status == .reading
                    else { return }
                    document.pdfSource!.pages![i].status =
                        document.pdfSource!.pages![i].barCount > 0 ? .ready : .stopped
                    document.pdfSource!.pages![i].error =
                        "Stopped. Work already sent may still be charged; no retry was made."
                }
                changed()
            } catch { self.error = "Stopped, but progress could not be saved: " + error.localizedDescription }
        }
        currentPage = nil
    }

    func discardReply() {
        guard !working, pending != nil else { return }
        // Explicitly discarding a received draft never issues a replacement request.
        if let pending {
            do {
                try updatePage(pending.page, sourceID: pending.sourceID, attempt: pending.attempt) { document, i in
                    document.pdfSource!.pages![i].status =
                        document.pdfSource!.pages![i].barCount > 0 ? .ready : .stopped
                    document.pdfSource!.pages![i].error = "Received draft discarded. No retry was made."
                }
                error = nil
            } catch {
                self.error = "Draft discarded, but its stopped status could not be saved: " + error.localizedDescription
            }
        }
        pending = nil
        pendingPage = nil
    }
}

extension PDFImportQueue {
    /// Navigation remains in AppState; the queue operates on the library owner.
    func start(
        state: AppState, scoreID: UUID, asset: PDFImportAsset, pages: [Int], model: PDFImportModel,
        passage: String? = nil, request: @escaping Request
    ) {
        start(
            workspace: state.libraryWorkspace, scoreID: scoreID, asset: asset, pages: pages, model: model,
            passage: passage, changed: { [weak state] in state?.pdfImportRevision += 1 }, request: request)
    }
}
