// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import MusicCore
import PDFKit

@MainActor enum PDFImportChecks {
    static func verify(directory: URL) throws -> [String: Bool] {
        let guitarData = try Data(contentsOf: PDFImportExamples.url("guitar"))
        let pianoData = try Data(contentsOf: PDFImportExamples.url("piano"))
        let guitar = try PDFImportAsset(data: guitarData, filename: "Guitar example.pdf")
        let piano = try PDFImportAsset(data: pianoData, filename: "Piano example.pdf")
        let book = PDFDocument()
        book.insert(guitar.document.page(at: 0)!.copy() as! PDFPage, at: 0)
        book.insert(piano.document.page(at: 0)!.copy() as! PDFPage, at: 1)
        let asset = try PDFImportAsset(data: book.dataRepresentation()!, filename: "Two-page method.pdf")
        let selectedData = try asset.pagePDF(2)
        let selected = try PDFImportAsset(data: selectedData, filename: "Selected page.pdf")
        var checks: [String: Bool] = [
            "pdfSelectedPageOnly": selected.pageCount == 1 && asset.pageCount == 2
                && selected.document.page(at: 0)?.bounds(for: .mediaBox)
                    == piano.document.page(at: 0)?.bounds(for: .mediaBox)
        ]
        do {
            _ = try asset.pagePDF(3)
            checks["pdfPageBounds"] = false
        } catch { checks["pdfPageBounds"] = true }
        let state = AppState(storageOverride: directory)
        let reply = PDFTranscriptionReply(
            transcription: PDFTranscription(.innerVoiceExample), model: PDFImportModel.astra.rawValue, costUSD: 0.1)
        try state.acceptPDFImport(reply, asset: asset, page: 2, instrument: .piano)
        let document = state.editor.active
        let source = document.pdfSource!
        let url = state.sourcePDFURL(source)!
        checks["pdfOriginalPreserved"] = try Data(contentsOf: url) == asset.data
        checks["pdfImportStartsUnreviewed"] = !source.reviewed && source.page == 2
        let restored = AppState(storageOverride: directory)
        checks["pdfImportPersistence"] = restored.editor.active == document && restored.sourcePDFURL(source) != nil
        checks["pdfImportVoices"] = document.voices(staff: 1) == [1, 2] && document.staffCount == 2
        let before = restored.editor
        var invalid = reply
        invalid.transcription.notes[0].duration = 99
        do {
            try restored.acceptPDFImport(invalid, asset: asset, page: 2, instrument: .piano)
            checks["pdfFailedImportAtomic"] = false
        } catch { checks["pdfFailedImportAtomic"] = restored.editor == before }
        restored.practiseEditor(document, from: 0, through: 1)
        checks["pdfImportedPracticeCopy"] =
            restored.studies.active?.sourceEditor?.scoreID == document.id && restored.studies.active?.from == 0
            && restored.studies.active?.through == 1
        let otherPage = PDFTranscriptionReply(
            transcription: PDFTranscription(.guitarExample), model: PDFImportModel.astra.rawValue)
        try restored.acceptPDFImport(otherPage, asset: asset, page: 1, instrument: .guitar)
        let storedPDFs = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("PDF Sources"), includingPropertiesForKeys: nil)
        checks["pdfSourceSharedAcrossPages"] =
            restored.editor.active.pdfSource?.fileID == source.fileID && storedPDFs.count == 1
        let libraryURL = directory.appendingPathComponent("editor.json")
        let savedLibrary = try Data(contentsOf: libraryURL)
        let beforeSaveFailure = restored.editor
        try FileManager.default.removeItem(at: libraryURL)
        try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: libraryURL)
            try? savedLibrary.write(to: libraryURL, options: .atomic)
        }
        do {
            try restored.acceptPDFImport(otherPage, asset: asset, page: 1, instrument: .guitar)
            checks["pdfSharedSourceSurvivesSaveFailure"] = false
        } catch {
            let preserved = try Data(contentsOf: url)
            checks["pdfSharedSourceSurvivesSaveFailure"] =
                restored.editor == beforeSaveFailure && preserved == asset.data
        }
        let distinct = try PDFImportAsset(data: asset.data, filename: "Separate original.pdf")
        do {
            try restored.acceptPDFImport(otherPage, asset: distinct, page: 1, instrument: .guitar)
            checks["pdfFailedSaveCleansNewSource"] = false
        } catch {
            let files = try FileManager.default.contentsOfDirectory(
                at: directory.appendingPathComponent("PDF Sources"), includingPropertiesForKeys: nil)
            checks["pdfFailedSaveCleansNewSource"] = restored.editor == beforeSaveFailure && files.count == 1
        }
        return checks
    }
}

/// Explicit paid development command, separate from snapshots and self-checks.
