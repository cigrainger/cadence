// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import MusicCore
import PDFKit
import SwiftUI

@MainActor final class PDFImportAsset {
    let data: Data
    let filename: String
    let document: PDFDocument
    var pageCount: Int { document.pageCount }
    init(data: Data, filename: String) throws {
        guard data.count <= 100_000_000, let document = PDFDocument(data: data), !document.isLocked,
            (1...1000).contains(document.pageCount)
        else { throw MusicError.invalid("Choose an unlocked PDF of up to 100 MB and 1,000 pages.") }
        self.data = data
        self.filename = String(filename.prefix(300))
        self.document = document
    }
    static func read(_ url: URL) async throws -> PDFImportAsset {
        let data = try await Task.detached(priority: .userInitiated) {
            let scope = url.startAccessingSecurityScopedResource()
            defer { if scope { url.stopAccessingSecurityScopedResource() } }
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 100_000_000 else {
                throw MusicError.invalid("Choose a PDF smaller than 100 MB.")
            }
            return try Data(contentsOf: url)
        }.value
        try Task.checkCancellation()
        return try PDFImportAsset(data: data, filename: url.lastPathComponent)
    }
    func pagePDF(_ number: Int) throws -> Data { try excerptPDF([number], maximumPages: 1, maximumBytes: 8_000_000) }
    func excerptPDF(_ pages: [Int], maximumPages: Int = 8, maximumBytes: Int = 12_000_000) throws -> Data {
        guard !pages.isEmpty, pages.count <= maximumPages, Set(pages).count == pages.count, pages == pages.sorted(),
            pages.allSatisfy({ (1...pageCount).contains($0) })
        else { throw MusicError.invalid("Choose a bounded selection of pages inside this PDF.") }
        let excerpt = PDFDocument()
        for number in pages {
            guard let page = document.page(at: number - 1)?.copy() as? PDFPage else {
                throw MusicError.invalid("This PDF page could not be opened.")
            }
            excerpt.insert(page, at: excerpt.pageCount)
        }
        guard let data = excerpt.dataRepresentation(), data.count <= maximumBytes else {
            throw MusicError.invalid("These pages are too large to send. Choose a smaller excerpt.")
        }
        return data
    }
}

struct NativePDFPage: NSViewRepresentable {
    var document: PDFDocument
    var page: Int
    var zoom: Int
    var fit: Int
    final class Coordinator { var page = -1, zoom = 0, fit = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.backgroundColor = NSColor(Color.canvas)
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        view.autoScales = true
        view.minScaleFactor = 0.05
        view.maxScaleFactor = 10
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
            view.autoScales = true
            context.coordinator.page = -1
        }
        if context.coordinator.page != page, let target = document.page(at: page - 1) {
            view.go(to: target)
            context.coordinator.page = page
        }
        if context.coordinator.zoom != zoom {
            let delta = zoom - context.coordinator.zoom
            view.autoScales = false
            view.scaleFactor *= pow(1.2, Double(delta))
            context.coordinator.zoom = zoom
        }
        if context.coordinator.fit != fit {
            view.autoScales = true
            context.coordinator.fit = fit
        }
    }
}

struct PDFPagePane: View {
    let asset: PDFImportAsset
    @Binding var page: Int
    @State private var zoom = 0
    @State private var fit = 0
    var body: some View {
        VStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    pageControls
                    Spacer(minLength: 0)
                    zoomControls
                }
                VStack(alignment: .leading, spacing: 8) {
                    pageControls
                    zoomControls
                }
            }.controlSize(.small)
            NativePDFPage(document: asset.document, page: page, zoom: zoom, fit: fit).clipShape(
                RoundedRectangle(cornerRadius: 8)
            )
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.line, lineWidth: 1))
        }
    }

    // Keep navigation and zoom in distinct groups. Narrow source columns wrap
    // the groups instead of splitting page labels or squeezing the buttons.
    private var pageControls: some View {
        HStack(spacing: 8) {
            Button {
                page = max(1, page - 1)
            } label: {
                Image(systemName: "chevron.left")
            }.disabled(page <= 1).accessibilityLabel("Previous page").help("Previous page")
            Text("Page").font(.caption)
            TextField(
                "Page number", value: Binding(get: { page }, set: { page = min(asset.pageCount, max(1, $0)) }),
                format: .number
            ).labelsHidden().textFieldStyle(.roundedBorder).font(.caption.monospacedDigit()).frame(width: 44)
            Text("of \(asset.pageCount)").font(.caption.monospacedDigit())
            Button {
                page = min(asset.pageCount, page + 1)
            } label: {
                Image(systemName: "chevron.right")
            }.disabled(page >= asset.pageCount).accessibilityLabel("Next page").help("Next page")
        }.fixedSize()
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            Button {
                zoom -= 1
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }.accessibilityLabel("Zoom out").help("Zoom out")
            Button {
                zoom += 1
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }.accessibilityLabel("Zoom in").help("Zoom in")
            Button("Fit") { fit += 1 }.help("Fit the page to the available space")
        }.fixedSize()
    }

}

struct PDFReferencePane: View {
    var url: URL?
    var source: PDFScoreSource
    @State private var asset: PDFImportAsset?
    @State private var page = 1
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Original sheet music").font(.system(size: 17, weight: .semibold, design: .serif))
            Text(source.filename).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if let asset {
                PDFPagePane(asset: asset, page: $page)
            } else if let error {
                ContentUnavailableView("Source unavailable", systemImage: "doc", description: Text(error))
            } else {
                ProgressView("Opening the source…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Button("Imported page \(source.page)") { page = source.page }.disabled(asset == nil)
                Spacer(minLength: 0)
                if let url { Button("Open PDF", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(url) } }
            }.controlSize(.small)
            Text("Reference for the imported draft. Your corrections do not alter this PDF.").font(.caption)
                .foregroundStyle(.secondary)
        }.padding(14).background(Color.canvas.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
            .onChange(of: source.page) { _, value in page = value }
            .task(id: source.fileID) {
                page = source.page
                asset = nil
                error = nil
                guard let url else {
                    error =
                        "The saved PDF is missing on this Mac. Restore the PDF Sources folder from your Cadence backup. The notation remains editable."
                    return
                }
                do { asset = try await PDFImportAsset.read(url) } catch is CancellationError {} catch {
                    self.error = error.localizedDescription
                }
            }
    }
}

@MainActor enum PDFImportDiagnostics { static var checks: [String: Bool] = [:] }

enum PDFImportExamples {
    static func url(_ name: String) -> URL {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("ImportExamples/\(name).pdf")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return AppResources.sourceDirectory.appendingPathComponent("ImportExamples/\(name).pdf")
    }
}
