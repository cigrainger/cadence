// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI
import WebKit

@MainActor enum ScoreRendererDiagnostics {
    static var latest: [String: Any] = [:]
}

struct ScoreRenderer: NSViewRepresentable {
    var study: MusicStudy
    var playhead: StudyPlayhead?
    var feedback: [LiveTimedNote] = []
    var feedbackStart: Double? = nil
    var focus: PassageScope? = nil
    var feedbackRoom = false
    @Binding var height: CGFloat
    @Binding var error: String?
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "study")
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("ScoreViewer", isDirectory: true)
        let source = AppResources.sourceDirectory.appendingPathComponent("ScoreViewer", isDirectory: true)
        let folder = [bundled, source].compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path)
        }
        if let folder {
            context.coordinator.entryURL = folder.appendingPathComponent("index.html")
            web.loadFileURL(folder.appendingPathComponent("index.html"), allowingReadAccessTo: folder)
        } else {
            DispatchQueue.main.async {
                error = "The offline notation renderer is missing. Rebuild or reopen the complete Cadence app."
            }
        }
        context.coordinator.web = web
        return web
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update()
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "study")
        view.navigationDelegate = nil
        view.stopLoading()
    }
    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: ScoreRenderer
        weak var web: WKWebView?
        var entryURL: URL?
        var loaded = false
        var key = ""
        var previousXML = ""
        var previousPosition = ""
        var previousFeedback: [LiveTimedNote]?
        var previousFeedbackStart: Double?
        var previousFocus = ""
        init(_ parent: ScoreRenderer) { self.parent = parent }
        func update() {
            guard loaded, let web else { return }
            let study = parent.study
            let newKey =
                "\(study.id):\(study.partID):\(study.from):\(study.through):\(Int(web.bounds.width)):\(parent.feedbackRoom)"
            if key != newKey || previousXML != study.document.originalXML, web.bounds.width > 100 {
                previousXML = study.document.originalXML
                key = newKey
                previousPosition = ""
                previousFeedback = nil
                previousFocus = ""
                web.callAsyncJavaScript(
                    "await window.loadStudy(xml,partID,from,through,durations,feedbackRoom,verifyCursor)",
                    arguments: [
                        "xml": study.document.originalXML, "partID": study.partID, "from": study.from,
                        "through": study.through, "durations": study.selectedMeasures.map(\.duration),
                        "feedbackRoom": parent.feedbackRoom,
                        "verifyCursor": CommandLine.arguments.contains("--snapshot"),
                    ], in: nil, in: .page
                ) { [weak self] result in
                    if case .failure(let failure) = result { self?.parent.error = failure.localizedDescription }
                }
            }
            // Playback ticks only move the cursor. Rebuild feedback payloads when
            // evidence or its timing origin changes, not 30 times a second.
            if previousFeedback != parent.feedback || previousFeedbackStart != parent.feedbackStart {
                previousFeedback = parent.feedback
                previousFeedbackStart = parent.feedbackStart
                let marks: [[String: Any]] = parent.feedback.compactMap { item in
                    let note = item.assessment
                    guard let bar = study.selectedMeasures.first(where: { $0.index == note.target.bar }) else {
                        return nil
                    }
                    return [
                        "bar": bar.index - study.from,
                        "offset": (parent.feedbackStart ?? study.start) + note.target.beat - bar.start,
                        "verdict": note.verdict.rawValue,
                        "settled": item.settled,
                        "label": Pitch.chromatic(note.target.pitch) + String(note.target.pitch / 12 - 1) + " · "
                            + note.verdict.rawValue,
                    ]
                }
                web.callAsyncJavaScript(
                    "return window.setStudyFeedback(marks)", arguments: ["marks": marks], in: nil, in: .page
                ) { result in
                    if case .success(let value) = result, let checks = value as? [String: Any] {
                        for (key, value) in checks { ScoreRendererDiagnostics.latest[key] = value }
                        if let height = checks["feedbackHeight"] as? Double {
                            self.parent.height = min(100000, max(160, CGFloat(height)))
                        }
                    }
                }
            }
            let focusKey = parent.focus.map { "\($0.from):\($0.through)" } ?? "none"
            if focusKey != previousFocus {
                previousFocus = focusKey
                web.callAsyncJavaScript(
                    "return window.setStudyFocus(from,through)",
                    arguments: [
                        "from": parent.focus.map { $0.from - study.from } ?? -1,
                        "through": parent.focus.map { $0.through - study.from } ?? -1,
                    ], in: nil, in: .page
                ) { result in
                    if case .success(let value) = result, let checks = value as? [String: Any] {
                        for (key, value) in checks { ScoreRendererDiagnostics.latest[key] = value }
                    }
                }
            }
            let head = parent.playhead
            let bar =
                study.selectedMeasures.last { $0.start <= (head?.sourceBeat ?? study.start) + 0.00001 }
                ?? study.selectedMeasures[0]
            let offset = (head?.sourceBeat ?? study.start) - bar.start
            let visible = head != nil && head?.isCountIn == false
            let positionKey = "\(bar.index):\(Int(offset*32)):\(visible)"
            guard previousPosition != positionKey else { return }
            previousPosition = positionKey
            web.callAsyncJavaScript(
                "window.positionStudy(bar,offset,visible)",
                arguments: ["bar": bar.index - study.from, "offset": offset, "visible": visible], in: nil, in: .page,
                completionHandler: nil)
        }
        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard let data = message.body as? [String: Any] else { return }
            receive(data, isMainFrame: message.frameInfo.isMainFrame)
        }
        func receive(_ data: [String: Any], isMainFrame: Bool) {
            guard isMainFrame, let kind = data["kind"] as? String else { return }
            if kind == "loaded" {
                loaded = true
                update()
            }
            if kind == "ready" {
                guard let layout = RendererLayout(data, defaultHeight: 240) else {
                    parent.error = "The score renderer returned an invalid layout."
                    return
                }
                ScoreRendererDiagnostics.latest = data
                parent.height = layout.height
                parent.error = nil
            }
            if kind == "error" {
                parent.error = String((data["message"] as? String ?? "The score could not be displayed.").prefix(2000))
                ScoreRendererDiagnostics.latest = data
            }
        }
        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(
                LocalDocumentPolicy.allows(navigationAction.request.url, entry: entryURL) ? .allow : .cancel)
        }
    }
}
