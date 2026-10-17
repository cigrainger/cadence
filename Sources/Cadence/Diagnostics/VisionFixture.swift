// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Foundation
import MusicCore
import PDFKit

@MainActor enum VisionFixture {
    static func save(pdf: Data, prefix: URL, document: EditorDocument) throws {
        try FileManager.default.createDirectory(
            at: prefix.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pdf.write(to: prefix.appendingPathExtension("pdf"), options: .atomic)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(VisionTranscription(document)).write(
            to: prefix.appendingPathExtension("expected.json"), options: .atomic)
        try Data(EditorXML.encode(document).utf8).write(to: prefix.appendingPathExtension("musicxml"), options: .atomic)
        guard let page = PDFDocument(data: pdf)?.page(at: 0) else {
            throw MusicError.invalid("The fixture PDF could not be reopened.")
        }
        let bounds = page.bounds(for: .mediaBox)
        let image = page.thumbnail(of: NSSize(width: 2000, height: 2000 * bounds.height / bounds.width), for: .mediaBox)
        if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        {
            try png.write(to: prefix.appendingPathExtension("png"), options: .atomic)
        }
    }
}
