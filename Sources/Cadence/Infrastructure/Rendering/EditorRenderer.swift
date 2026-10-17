// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI
import WebKit

@MainActor enum EditorDiagnostics {
    static var latest: [String: Any] = [:]
    static var native: [String: Bool] = [:]
}

struct EditorRenderer: NSViewRepresentable {
    var document: EditorDocument
    var engine: String
    var from: Int
    var through: Int
    var selection: UUID?
    var playhead: StudyPlayhead?
    var select: (UUID) -> Void
    @Binding var height: CGFloat
    @Binding var error: String?
    @Binding var metrics: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "editor")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("EditorViewer")
        let source = AppResources.sourceDirectory.appendingPathComponent("EditorViewer")
        if let folder = [bundled, source].compactMap({ $0 }).first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path)
        }) {
            context.coordinator.entryURL = folder.appendingPathComponent("index.html")
            web.loadFileURL(
                folder.appendingPathComponent("index.html"), allowingReadAccessTo: folder.deletingLastPathComponent())
        } else {
            DispatchQueue.main.async { error = "The editor's offline rendering files are missing." }
        }
        context.coordinator.web = web
        return web
    }
    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update()
    }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "editor")
        web.stopLoading()
        web.navigationDelegate = nil
    }
    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: EditorRenderer
        weak var web: WKWebView?
        var entryURL: URL?
        var exportedFixture = false
        var loaded = false, busy = false
        var previous = "", position = ""
        var cachedDocument: EditorDocument?, cachedExcerpt: EditorDocument?
        var cachedFrom = -1, cachedThrough = -1
        var cachedData = Data()
        init(_ parent: EditorRenderer) { self.parent = parent }
        func update() {
            guard loaded, let web, web.bounds.width > 100 else { return }
            do {
                if cachedDocument != parent.document || cachedFrom != parent.from || cachedThrough != parent.through {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = .sortedKeys
                    let excerpt = try parent.document.excerpt(parent.from...parent.through)
                    cachedData = try encoder.encode(excerpt)
                    cachedExcerpt = excerpt
                    cachedDocument = parent.document
                    cachedFrom = parent.from
                    cachedThrough = parent.through
                }
                guard let excerpt = cachedExcerpt else { return }
                let data = cachedData
                let key = data.base64EncodedString() + parent.engine + "\(parent.from):\(Int(web.bounds.width))"
                if previous != key && !busy {
                    busy = true
                    previous = key
                    position = ""
                    var payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                    payload["barOffset"] = parent.from
                    web.callAsyncJavaScript(
                        "window.editorPreview=preview; await window.loadEditor(document,engine,xml,notationXML)",
                        arguments: [
                            "preview": CommandLine.arguments.contains("--snapshot"), "document": payload,
                            "engine": parent.engine,
                            "xml": try EditorXML.encode(excerpt, firstBarNumber: parent.from + 1),
                            "notationXML": try EditorXML.encode(
                                excerpt, includeTab: false, firstBarNumber: parent.from + 1),
                        ], in: nil, in: .page
                    ) { [weak self] result in
                        guard let self else { return }
                        self.busy = false
                        if case .failure(let failure) = result { self.parent.error = failure.localizedDescription }
                        self.update()
                    }
                }
                let beat = parent.playhead?.isCountIn == false ? parent.playhead?.sourceBeat : nil
                let selection = parent.selection?.uuidString ?? ""
                let newPosition = selection + ":\(beat.map { Int($0*24) } ?? -1)"
                if newPosition != position {
                    position = newPosition
                    web.callAsyncJavaScript(
                        "window.selectEditor(id,beat)", arguments: ["id": selection, "beat": beat as Any? ?? NSNull()],
                        in: nil, in: .page, completionHandler: nil)
                }
            } catch { parent.error = error.localizedDescription }
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let data = message.body as? [String: Any],
                let kind = data["kind"] as? String
            else { return }
            if kind == "loaded" {
                loaded = true
                update()
            }
            if kind == "diagnostic" { EditorDiagnostics.latest = data }
            if kind == "ready" {
                EditorDiagnostics.latest = data
                parent.height = min(100000, max(160, CGFloat(data["height"] as? Double ?? 260)))
                parent.error = nil
                let time = data["milliseconds"] as? Double ?? 0
                let targets = data["targets"] as? Int ?? 0
                parent.metrics = "\(Int(time.rounded())) ms · \(targets) selectable positions"
                position = ""
                update()
                if !exportedFixture, let index = CommandLine.arguments.firstIndex(of: "--vision-fixture"),
                    index + 1 < CommandLine.arguments.count
                {
                    exportedFixture = true
                    let prefix = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                    let document = parent.document
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let web = self?.web else { return }
                        let configuration = WKPDFConfiguration()
                        configuration.rect = web.bounds
                        web.createPDF(configuration: configuration) { result in
                            Task { @MainActor in
                                do {
                                    try VisionFixture.save(pdf: result.get(), prefix: prefix, document: document)
                                } catch { EditorDiagnostics.native["fixturePDF"] = false }
                                EditorDiagnostics.native["fixturePDF"] = FileManager.default.fileExists(
                                    atPath: prefix.appendingPathExtension("pdf").path)
                            }
                        }
                    }
                }
                if CommandLine.arguments.contains("--creative-preview")
                    || CommandLine.arguments.contains("--full-piece-preview")
                    || CommandLine.arguments.contains("--editor-check")
                    || CommandLine.arguments.contains("--poly-check")
                    || CommandLine.arguments.contains("--harmony-check")
                    || CommandLine.arguments.contains("--course-score-review")
                {
                    web?.callAsyncJavaScript("return await window.verifyEditor()", arguments: [:], in: nil, in: .page) {
                        result in
                        if case .success(let value) = result, let checks = value as? [String: Any] {
                            for (key, value) in checks { EditorDiagnostics.latest[key] = value }
                        }
                    }
                }
            }
            if kind == "select", let value = data["id"] as? String, let id = UUID(uuidString: value),
                parent.document.events.contains(where: { $0.id == id })
            {
                parent.select(id)
            }
            if kind == "error" {
                parent.error = data["message"] as? String ?? "This engine could not draw the score."
                EditorDiagnostics.latest = data
            }
        }
        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) { decisionHandler(LocalDocumentPolicy.allows(action.request.url, entry: entryURL) ? .allow : .cancel) }
    }
}
