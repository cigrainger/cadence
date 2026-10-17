// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

extension AppState {
    func sourcePDFURL(_ source: PDFScoreSource) -> URL? {
        if isPreview && CommandLine.arguments.contains("--course-preview") { return PDFImportExamples.url("chapter") }
        if isPreview && CommandLine.arguments.contains("--library-preview") { return PDFImportExamples.url("guitar") }
        if isPreview && CommandLine.arguments.contains("--pdf-batch-preview") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "cadence-preview-\(source.fileID).pdf")
            if !FileManager.default.fileExists(atPath: url.path), let asset = try? PDFBatchChecks.asset() {
                try? asset.data.write(to: url)
            }
            return url
        }
        if isPreview
            && (CommandLine.arguments.contains("--pdf-review-check")
                || CommandLine.arguments.contains("--pdf-batch-preview"))
        {
            if let i = CommandLine.arguments.firstIndex(of: "--pdf-source"), i + 1 < CommandLine.arguments.count {
                return URL(fileURLWithPath: CommandLine.arguments[i + 1])
            }
            return PDFImportExamples.url(editor.active.instrument == .guitar ? "guitar" : "piano")
        }
        let url = storage.appendingPathComponent("PDF Sources", isDirectory: true).appendingPathComponent(
            source.fileID.uuidString + ".pdf")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    func acceptPDFImport(_ reply: PDFTranscriptionReply, asset: PDFImportAsset, page: Int, instrument: EditorInstrument)
        throws
    {
        if let editorStorageError { throw MusicError.invalid(editorStorageError) }
        guard !isPreview, (1...asset.pageCount).contains(page), editor.documents.count < 100 else {
            throw MusicError.invalid("Cadence keeps up to 100 editable scores. This draft has not been saved.")
        }
        let draft = try reply.transcription.makeDocument(instrument: instrument)
        let existing = editor.documents.compactMap(\.pdfSource).first { old in
            guard old.filename == asset.filename, let url = sourcePDFURL(old),
                (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == asset.data.count
            else { return false }
            return (try? Data(contentsOf: url)) == asset.data
        }
        let source = PDFScoreSource(
            fileID: existing?.fileID ?? UUID(), filename: asset.filename, page: page, model: reply.model,
            costUSD: reply.costUSD, warnings: draft.warnings)
        var document = draft.document
        document.pdfSource = source
        document = try document.validated()
        let folder = storage.appendingPathComponent("PDF Sources", isDirectory: true)
        let sourceURL = folder.appendingPathComponent(source.fileID.uuidString + ".pdf")
        var library = editor
        library.documents.append(document)
        library.activeID = document.id
        library.engine = "OpenSheetMusicDisplay"
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if existing == nil { try asset.data.write(to: sourceURL, options: .atomic) }
        do { try libraryWorkspace.commitScores(library) } catch {
            if existing == nil { try? FileManager.default.removeItem(at: sourceURL) }
            throw error
        }
        audio.stop()
        microphone.stop()
        destination = .editor
    }
    func createPDFBatch(
        asset: PDFImportAsset, pages: [Int], instrument: EditorInstrument, model: PDFImportModel, passage: String,
        documentID: UUID = UUID(), sourceID: UUID? = nil
    ) throws -> UUID {
        if let editorStorageError { throw MusicError.invalid(editorStorageError) }
        guard !isPreview, editor.documents.count < 100, !pages.isEmpty, pages.count <= 16,
            pages.allSatisfy({ (1...asset.pageCount).contains($0) }), Set(pages).count == pages.count
        else { throw MusicError.invalid("Choose up to 16 pages. Cadence keeps up to 100 editable scores.") }
        let existing = editor.documents.compactMap(\.pdfSource).first { old in
            guard old.filename == asset.filename, let url = sourcePDFURL(old),
                (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == asset.data.count
            else { return false }
            return (try? Data(contentsOf: url)) == asset.data
        }
        if let sourceID {
            let saved = storage.appendingPathComponent("PDF Sources").appendingPathComponent(
                sourceID.uuidString + ".pdf")
            guard (try? Data(contentsOf: saved)) == asset.data else {
                throw MusicError.invalid("The book PDF changed or is unavailable. Restore its original source.")
            }
        }
        guard !editor.documents.contains(where: { $0.id == documentID }) else {
            throw MusicError.invalid("This exercise score already exists.")
        }
        var source = PDFScoreSource(
            fileID: sourceID ?? existing?.fileID ?? UUID(), filename: asset.filename, page: pages[0],
            model: model.rawValue, costUSD: 0)
        source.pages = pages.sorted().map { PDFImportPage(page: $0, model: model.rawValue, passage: passage) }
        var document = try EditorDocument.blank(instrument: instrument, bars: 1)
        document.id = documentID
        document.title = String((asset.filename as NSString).deletingPathExtension.prefix(120))
        document.pdfSource = source
        document = try document.validated()
        let folder = storage.appendingPathComponent("PDF Sources", isDirectory: true)
        let url = folder.appendingPathComponent(source.fileID.uuidString + ".pdf")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if existing == nil && sourceID == nil { try asset.data.write(to: url, options: .atomic) }
        var library = editor
        library.documents.append(document)
        library.activeID = document.id
        library.engine = "OpenSheetMusicDisplay"
        do { try libraryWorkspace.commitScores(library) } catch {
            if existing == nil && sourceID == nil { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        audio.stop()
        microphone.stop()
        destination = .editor
        pdfImportScoreID = document.id
        pdfImportRevision += 1
        return document.id
    }
    func changePDFScore(_ id: UUID, _ change: (inout EditorDocument) throws -> Void) throws {
        try libraryWorkspace.changePDFScore(id, change)
        pdfImportRevision += 1
    }
    func reviewPDFPage(scoreID: UUID, page: Int) {
        editor.activeID = scoreID
        destination = .editor
        pdfReviewPage = page
        showPDFImport = false
    }
}
