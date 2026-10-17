// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore
import SwiftUI

@MainActor final class PDFImportQueue: ObservableObject {
    typealias Request = (Data, EditorInstrument, String, PDFImportModel) async throws -> PDFTranscriptionReply
    @Published private(set) var working = false
    @Published private(set) var currentPage: Int?
    @Published private(set) var started: Date?
    @Published var error: String?
    private var job: Task<Void, Never>?
    private var runID = UUID()
    private weak var state: AppState?
    private var scoreID: UUID?

    func start(
        state: AppState, scoreID: UUID, asset: PDFImportAsset, pages: [Int], model: PDFImportModel,
        passage: String? = nil, request: @escaping Request
    ) {
        guard !working, !state.isPreview, let score = state.editor.documents.first(where: { $0.id == scoreID }),
            let source = score.pdfSource, let records = source.pages
        else { return }
        let chosen = records.map(\.page).filter { pages.contains($0) }
        guard !chosen.isEmpty else { return }
        self.state = state
        self.scoreID = scoreID
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
                var reply: PDFTranscriptionReply?
                do {
                    let data = try asset.pagePDF(page)
                    guard let live = state.editor.documents.first(where: { $0.id == scoreID }),
                        let record = live.pdfSource?.pages?.first(where: { $0.page == page })
                    else { throw MusicError.invalid("The page is no longer in this score.") }
                    let instruction = passage ?? record.passage
                    // Persist the attempt before sending. A crash cannot silently
                    // restart a paid request; recovery leaves it stopped.
                    try state.changePDFScore(scoreID) { document in
                        guard let i = document.pdfSource?.pages?.firstIndex(where: { $0.page == page }) else { return }
                        document.pdfSource!.pages![i].status = .reading
                        document.pdfSource!.pages![i].error = nil
                        document.pdfSource!.pages![i].attempts += 1
                        document.pdfSource!.pages![i].unpricedAttempts += 1
                        document.pdfSource!.pages![i].passage = instruction
                    }
                    reply = try await request(data, score.instrument, instruction, model)
                    try Task.checkCancellation()
                    guard runID == token else { return }
                    try finishPage(state: state, scoreID: scoreID, page: page, reply: reply, failure: nil)
                } catch {
                    guard !Task.isCancelled, runID == token else { return }
                    do {
                        try finishPage(
                            state: state, scoreID: scoreID, page: page, reply: reply,
                            failure: error.localizedDescription)
                    } catch {
                        self.error =
                            "Progress could not be saved. The queue has stopped: " + error.localizedDescription
                        return
                    }
                }
            }
        }
    }
    private func finishPage(state: AppState, scoreID: UUID, page: Int, reply: PDFTranscriptionReply?, failure: String?)
        throws
    {
        try state.changePDFScore(scoreID) { document in
            guard let i = document.pdfSource?.pages?.firstIndex(where: { $0.page == page }) else {
                throw MusicError.invalid("The page is no longer available.")
            }
            if let cost = reply?.costUSD {
                document.pdfSource!.pages![i].costUSD += cost
                document.pdfSource!.pages![i].unpricedAttempts = max(
                    0, document.pdfSource!.pages![i].unpricedAttempts - 1)
                document.pdfSource!.costUSD = document.pdfSource!.pages!.reduce(0) { $0 + $1.costUSD }
            }
            do {
                if let failure { throw MusicError.invalid(failure) }
                guard let reply else { throw MusicError.invalid("No draft was returned.") }
                let draft = try reply.transcription.makeDocument(
                    instrument: document.instrument, tuning: document.tuning, capo: document.capo)
                let candidate = PDFPageReplacement(
                    document: draft.document, model: reply.model, warnings: draft.warnings)
                var proposed = document
                try proposed.replacePDFPage(page, with: candidate)
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
    }
    func stop() {
        guard working else { return }
        runID = UUID()
        job?.cancel()
        job = nil
        working = false
        started = nil
        if let state, let scoreID, let page = currentPage {
            do {
                try state.changePDFScore(scoreID) { document in
                    guard let i = document.pdfSource?.pages?.firstIndex(where: { $0.page == page }) else { return }
                    document.pdfSource!.pages![i].status =
                        document.pdfSource!.pages![i].barCount > 0 ? .ready : .stopped
                    document.pdfSource!.pages![i].error =
                        "Stopped. Work already sent may still be charged; no retry was made."
                }
            } catch { self.error = "Stopped, but progress could not be saved: " + error.localizedDescription }
        }
        currentPage = nil
    }
}
