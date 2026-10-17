// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import PDFKit
import SwiftUI
import WebKit

@MainActor struct BookAsset {
    let data: Data
    let filename: String
    let pdf: PDFImportAsset?
    let epub: EPUBDocument?
    var pageCount: Int { epub?.sections.count ?? pdf?.pageCount ?? 0 }
    var unit: String { epub == nil ? "PDF page" : "Section" }
    var title: String { epub?.title ?? URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent }
    init(pdf: PDFImportAsset) {
        self.pdf = pdf
        epub = nil
        data = pdf.data
        filename = pdf.filename
    }
    init(data: Data, filename: String, epub: EPUBDocument) {
        self.data = data
        self.filename = filename
        self.epub = epub
        pdf = nil
    }
    static func read(_ url: URL) async throws -> BookAsset {
        if url.pathExtension.lowercased() != "epub" { return try await .init(pdf: PDFImportAsset.read(url)) }
        let result = try await Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= EPUBDocument.maximumBytes else {
                throw MusicError.invalid("Choose an EPUB smaller than 50 MB.")
            }
            let data = try Data(contentsOf: url)
            return (data, try EPUBDocument(data: data))
        }.value
        try Task.checkCancellation()
        return .init(data: result.0, filename: url.lastPathComponent, epub: result.1)
    }
    func book(title: String, author: String, edition: String) -> CourseBook {
        CourseBook(
            data: data, filename: filename, pageCount: pageCount, title: title, author: author, edition: edition,
            epubSections: epub?.sections.map(\.reference))
    }
    func images(in source: CourseSourceAnchor) -> [EPUBImage] {
        guard let epub, source.fromPage > 0, source.throughPage >= source.fromPage,
            source.throughPage <= epub.sections.count
        else { return [] }
        var paths = Set<String>()
        return epub.sections[(source.fromPage - 1)..<source.throughPage].flatMap(\.images).filter {
            paths.insert($0).inserted
        }.compactMap { epub.images[$0] }
    }
    /// The source EPUB remains the book of record. Only selected raster examples
    /// become a small derived PDF so the existing review/retry queue can be reused.
    func imageExcerpt(_ selected: [String], source: CourseSourceAnchor) throws -> PDFImportAsset {
        let available = Dictionary(images(in: source).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        guard (1...4).contains(selected.count), Set(selected).count == selected.count,
            selected.allSatisfy({ available[$0] != nil })
        else { throw MusicError.invalid("Select one to four illustrations from this lesson's sections.") }
        let document = PDFDocument()
        for path in selected {
            guard let data = available[path]?.data, let image = NSImage(data: data), let page = PDFPage(image: image)
            else { throw MusicError.invalid("This illustration cannot be converted to a notation source.") }
            document.insert(page, at: document.pageCount)
        }
        guard let data = document.dataRepresentation(), data.count <= 12_000_000 else {
            throw MusicError.invalid("Choose fewer or smaller illustrations.")
        }
        return try PDFImportAsset(data: data, filename: title + " — selected illustrations.pdf")
    }
}

struct BookSourcePane: View {
    let asset: BookAsset
    @Binding var page: Int
    @State private var query = ""
    @State private var fragment = ""
    @State private var illustrations = false
    @State private var scale = 1.0
    var body: some View {
        if let pdf = asset.pdf {
            PDFPagePane(asset: pdf, page: $page)
        } else if let epub = asset.epub {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "book.closed").foregroundStyle(Color.moss)
                    Text("EPUB · reading view").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        page = max(1, page - 1)
                        fragment = ""
                    } label: {
                        Image(systemName: "chevron.left")
                    }.disabled(page <= 1)
                    Button {
                        page = min(epub.sections.count, page + 1)
                        fragment = ""
                    } label: {
                        Image(systemName: "chevron.right")
                    }.disabled(page >= epub.sections.count)
                }.controlSize(.small)
                TextField("Find a section…", text: $query).textFieldStyle(.roundedBorder)
                Menu {
                    if query.isEmpty {
                        ForEach(Array(epub.navigation.enumerated()), id: \.offset) { _, item in
                            Button(item.title) {
                                page = item.section + 1
                                fragment = item.fragment
                            }
                        }
                    } else {
                        ForEach(
                            Array(epub.sections.enumerated()).filter {
                                $0.element.reference.title.localizedCaseInsensitiveContains(query)
                                    || $0.element.text.localizedCaseInsensitiveContains(query)
                            }.prefix(60), id: \.offset
                        ) { index, item in
                            Button(item.reference.title) {
                                page = index + 1
                                fragment = ""
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(
                            epub.sections.indices.contains(page - 1)
                                ? epub.sections[page - 1].reference.title : "Contents"
                        ).lineLimit(2)
                        Spacer()
                        Image(systemName: "list.bullet")
                    }
                }.menuStyle(.borderlessButton)
                HStack {
                    Picker("Source view", selection: $illustrations) {
                        Text("Read").tag(false)
                        Text("Illustrations").tag(true)
                    }.pickerStyle(.segmented).labelsHidden()
                    Menu {
                        Button("Smaller text") { scale = max(0.75, scale - 0.1) }
                        Button("Larger text") { scale = min(1.5, scale + 0.1) }
                        Button("Reset size") { scale = 1 }
                    } label: {
                        Image(systemName: "textformat.size")
                    }.menuStyle(.borderlessButton).fixedSize().help("Reading text size")
                }
                if illustrations {
                    ScrollView {
                        VStack(spacing: 14) {
                            if epub.sections.indices.contains(page - 1) {
                                ForEach(epub.sections[page - 1].images, id: \.self) { path in
                                    if let data = epub.images[path]?.data, let image = NSImage(data: data) {
                                        Image(nsImage: image).resizable().scaledToFit().accessibilityLabel(
                                            "Original book illustration"
                                        ).padding(8).background(.white, in: RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                                if epub.sections[page - 1].images.isEmpty {
                                    Text("No supported illustrations in this section.").font(.callout).foregroundStyle(
                                        .secondary
                                    ).padding()
                                }
                            }
                        }
                    }.frame(maxHeight: .infinity)
                } else {
                    EPUBReadingView(
                        html: (try? epub.readingHTML(section: page - 1)) ?? "", fragment: fragment, scale: scale
                    ).clipShape(RoundedRectangle(cornerRadius: 12)).overlay(
                        RoundedRectangle(cornerRadius: 12).stroke(Color.line))
                }
                Text("Section \(page) of \(epub.sections.count) · original text & illustrations").font(.caption2)
                    .foregroundStyle(.secondary)
            }.onAppear { if CommandLine.arguments.contains("--smooth-illustrations") { illustrations = true } }
        }
    }
}
struct EPUBReadingView: NSViewRepresentable {
    let html: String
    var fragment = ""
    var scale = 1.0
    final class Coordinator: NSObject, WKNavigationDelegate {
        var html = "", fragment = ""
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !fragment.isEmpty, let data = try? JSONEncoder().encode([fragment]) else { return }
            let literal = String(decoding: data, as: UTF8.self)
            webView.evaluateJavaScript(
                "document.getElementById((" + literal + ")[0])?.scrollIntoView()", completionHandler: nil)
        }
        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(
                navigationAction.navigationType == .other && navigationAction.request.url?.scheme == "about"
                    ? .allow : .cancel)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        view.pageZoom = scale
        if context.coordinator.html != html || context.coordinator.fragment != fragment {
            context.coordinator.html = html
            context.coordinator.fragment = fragment
            view.loadHTMLString(html, baseURL: URL(string: "about:blank"))
        }
    }
}
