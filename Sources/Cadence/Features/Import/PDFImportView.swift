// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import MusicCore
import SwiftUI
import UniformTypeIdentifiers

struct PDFImportView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var aiSettings: AISettings
    @Environment(\.dismiss) private var dismiss
    @StateObject private var queue = PDFImportQueue()
    @State private var asset: PDFImportAsset?
    @State private var page = 1
    @State private var ranges = "1"
    @State private var instrument = EditorInstrument.guitar
    @State private var model = PDFImportModel.recommended
    @State private var passage = ""
    @State private var scoreID: UUID?
    @State private var opening = false
    @State private var error: String?
    @State private var loading: Task<Void, Never>?
    @State private var loadID = UUID()
    @State private var replacementPage: Int?
    @State private var replacementBar = 0
    @State private var notationHeight: CGFloat = 240
    @State private var notationError: String?
    @State private var metrics = ""
    private var score: EditorDocument? { state.editor.documents.first { $0.id == scoreID } }
    private var source: PDFScoreSource? { score?.pdfSource }
    private var records: [PDFImportPage] { source?.pages ?? [] }
    private var selectedRecord: PDFImportPage? { records.first { $0.page == page } }
    private var parsedPages: [Int] { (try? PDFPageRanges.parse(ranges, pageCount: asset?.pageCount ?? 1)) ?? [] }
    private var rangeError: String? {
        guard asset != nil else { return nil }
        do {
            _ = try PDFPageRanges.parse(ranges, pageCount: asset!.pageCount)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
    private var canRequest: Bool {
        !opening && !queue.working && asset != nil && aiSettings.hasSavedKey && !state.isPreview
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(scoreID == nil ? "Bring sheet music into Cadence" : "Your pages, one score").font(
                        .system(size: 27, weight: .medium, design: .serif))
                    Text(
                        scoreID == nil
                            ? "Choose a page range. Keep the originals beside your editable score."
                            : "Progress is saved after each page. Review and retry at your pace."
                    ).foregroundStyle(.secondary)
                }
                Spacer()
                Button(queue.working || opening ? "Stop import" : "Close") {
                    if queue.working {
                        queue.stop()
                    } else if opening {
                        loadID = UUID()
                        loading?.cancel()
                        opening = false
                    } else {
                        dismiss()
                    }
                }.keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(asset?.filename ?? source?.filename ?? "Your sheet music").font(.headline).lineLimit(1)
                        Spacer()
                        if scoreID == nil {
                            Button("Choose PDF…", systemImage: "folder") { choose() }.disabled(opening)
                        }
                    }
                    if scoreID == nil {
                        Button("Try an original example") { example() }.font(.caption).disabled(opening)
                    }
                    if let asset {
                        PDFPagePane(asset: asset, page: $page)
                    } else if opening {
                        ProgressView("Opening your PDF…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(spacing: 16) {
                            Image(systemName: "doc.richtext").font(.system(size: 42)).foregroundStyle(Color.moss)
                            Text(
                                scoreID == nil
                                    ? "Choose a PDF, then enter the pages to import."
                                    : "Restore this original PDF from your Cadence backup to retry a page."
                            ).multilineTextAlignment(.center).foregroundStyle(.secondary)
                            if scoreID == nil { Button("Choose PDF…") { choose() }.buttonStyle(.cadencePrimary) }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(
                            Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        if let replacementPage,
                            let candidate = records.first(where: { $0.page == replacementPage })?.replacement
                        {
                            replacement(candidate, page: replacementPage)
                        } else {
                            if scoreID == nil { setup } else { progress }
                            ChoiceMenu(
                                title: "Transcription model", selection: $model, options: PDFImportModel.allCases
                            ) { $0.name }.disabled(queue.working)
                            Text(
                                "Sol high is the default. Each request sends only one selected page, with a four-minute limit."
                            ).font(.caption).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 7) {
                                Text(scoreID == nil ? "Passage on each page" : "Next attempt · page \(page)").font(
                                    .callout
                                ).fontWeight(.medium)
                                TextField(
                                    "Optional: first exercise, top system, bars 5–12…", text: $passage, axis: .vertical
                                ).lineLimit(2...3).textFieldStyle(.roundedBorder)
                                HStack {
                                    Button("First 4 bars") { passage = "The first 4 complete bars on this page." }
                                    Button("First 8 bars") { passage = "The first 8 complete bars on this page." }
                                }.controlSize(.small)
                                Text(
                                    scoreID == nil
                                        ? "Blank includes the visible music on each selected page, up to 32 complete bars per page. Page ranges follow file order."
                                        : "Changing this text affects the selected page's next retry. Resume keeps the saved instructions for other pages."
                                ).font(.caption).foregroundStyle(.secondary)
                            }.disabled(queue.working)
                            if let selectedRecord, !queue.working { pageDetails(selectedRecord) }
                            if let error = error ?? queue.error {
                                Text(error).font(.caption).foregroundStyle(Color.clay).textSelection(.enabled)
                            }
                            if !aiSettings.hasSavedKey && !state.isPreview {
                                Text("Add your key in Settings → AI coach first.").font(.caption).foregroundStyle(
                                    Color.clay)
                            }
                            if scoreID == nil {
                                Button(
                                    "Import \(parsedPages.count) \(parsedPages.count == 1 ? "page" : "pages")",
                                    systemImage: "wand.and.stars"
                                ) { startNew() }.buttonStyle(.cadencePrimary).controlSize(.large).disabled(
                                    !canRequest || parsedPages.isEmpty)
                            } else {
                                HStack {
                                    Button("Resume waiting pages") {
                                        run(
                                            records.filter {
                                                $0.barCount == 0 && [.pending, .stopped].contains($0.status)
                                            }.map(\.page))
                                    }.disabled(
                                        !canRequest
                                            || !records.contains {
                                                $0.barCount == 0 && [.pending, .stopped].contains($0.status)
                                            })
                                    Button("Retry failed pages") {
                                        run(records.filter { $0.status == .failed }.map(\.page))
                                    }.disabled(!canRequest || !records.contains { $0.status == .failed })
                                }.controlSize(.small)
                                Button("Open combined score", systemImage: "music.note.list") { review(page) }
                                    .buttonStyle(.cadencePrimary).disabled(
                                        queue.working || (source?.importedPageCount ?? 0) == 0)
                            }
                            Divider()
                            Text(
                                "Uses your OpenRouter credits with ZDR required. One request per page; retries happen only when you choose them. The full PDF stays on this Mac."
                            ).font(.caption).foregroundStyle(.secondary)
                            Text(
                                "Start with a few pages. One combined score supports 128 bars in one key and meter. Missing pages stay listed here and contribute no bars until imported."
                            ).font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(width: 445)
            }
        }.padding(24).frame(width: 1040, height: 790).background(Color.canvas)
            .interactiveDismissDisabled(queue.working || opening)
            .onAppear {
                aiSettings.checkKeyIfNeeded()
                restore()
            }
            .onDisappear {
                queue.stop()
                loadID = UUID()
                loading?.cancel()
                state.audio.stop()
            }
            .onChange(of: passage) { _, value in if value.count > 500 { passage = String(value.prefix(500)) } }
            .onChange(of: page) { old, value in
                if scoreID == nil && ranges == String(old) { ranges = String(value) }
                if let record = records.first(where: { $0.page == value }) { passage = record.passage }
            }
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Make an editable score").font(.system(size: 20, weight: .medium, design: .serif))
            Picker("Instrument", selection: $instrument) {
                ForEach(EditorInstrument.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Text(
                instrument == .guitar
                    ? "Guitar treble notation becomes sounding notes and proposed tab. Review fingerings against the source."
                    : "Treble and bass staves, with up to two independent voices per hand."
            ).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Pages").font(.callout)
                TextField("29–32, 35", text: $ranges).textFieldStyle(.roundedBorder)
                Button("Use viewed page") { ranges = String(page) }.controlSize(.small)
            }
            if let rangeError {
                Text(rangeError).font(.caption).foregroundStyle(Color.clay)
            } else {
                Text("\(parsedPages.count) selected · in book order · up to 16 pages").font(.caption).foregroundStyle(
                    .secondary)
            }
        }
    }
    private var progress: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(source?.importedPageCount ?? 0) of \(records.count) pages ready").font(
                .system(size: 20, weight: .medium, design: .serif))
            ProgressView(value: Double(source?.importedPageCount ?? 0), total: Double(max(1, records.count)))
            if queue.working { waiting }
            ForEach(records) { item in
                HStack(spacing: 8) {
                    Button {
                        page = item.page
                    } label: {
                        HStack(spacing: 7) {
                            Image(
                                systemName: item.reviewed
                                    ? "checkmark.seal.fill"
                                    : item.status == .failed
                                        ? "exclamationmark.circle" : item.barCount > 0 ? "doc.text" : "doc")
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Page \(item.page) · \(item.label)").font(.callout)
                                if let range = source?.range(for: item.page) {
                                    Text("Score bars \(range.lowerBound+1)–\(range.upperBound)").font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }.padding(8).background(
                            page == item.page ? Color.moss.opacity(0.10) : Color.white.opacity(0.5),
                            in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                    if item.barCount > 0 { Button("Review") { review(item.page) }.disabled(queue.working) }
                    Button(item.attempts == 0 ? "Import" : "Retry") {
                        let instruction = item.page == page ? passage : item.passage
                        page = item.page
                        run([item.page], override: instruction)
                    }.disabled(!canRequest)
                }.controlSize(.small)
            }
        }
    }
    private var waiting: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                ProgressView().controlSize(.small)
                Text("Reading page \(queue.currentPage ?? page)…").font(.callout)
            }
            if let started = queue.started {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(started)))
                    Text("\(seconds/60):\(String(format:"%02d",seconds%60)) elapsed · 4:00 limit for this page").font(
                        .caption.monospacedDigit())
                }
            }
            Text(
                "Stop keeps completed pages and corrections. You can resume waiting pages or retry a failed page later."
            ).font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private func pageDetails(_ item: PDFImportPage) -> some View {
        if let message = item.error {
            Text("Page \(item.page): " + message).font(.caption).foregroundStyle(Color.clay).textSelection(.enabled)
        }
        if item.replacement != nil {
            Text("A replacement is ready. Your current notes and corrections are still in the score.").font(.caption)
            Button("Review replacement for page \(item.page)") {
                replacementPage = item.page
                replacementBar = 0
            }
        }
        if item.attempts > 0 {
            Text(
                "\(item.attempts) \(item.attempts == 1 ? "attempt" : "attempts") · "
                    + String(format: "US$%.4f reported", item.costUSD)
                    + (item.unpricedAttempts > 0 ? " · \(item.unpricedAttempts) with cost unreported" : "")
            ).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func replacement(_ candidate: PDFPageReplacement, page: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Replacement · page \(page)").font(.system(size: 20, weight: .medium, design: .serif))
            Text(
                "Compare this new draft with the original. Applying it replaces this page's bars, including your corrections. Other pages keep their notes."
            ).font(.callout).foregroundStyle(.secondary)
            HStack {
                Button {
                    replacementBar = max(0, replacementBar - 2)
                } label: {
                    Image(systemName: "chevron.left")
                }.disabled(replacementBar == 0)
                Text(
                    "Bars \(replacementBar+1)–\(min(candidate.document.barCount,replacementBar+2)) of \(candidate.document.barCount)"
                ).font(.caption)
                Button {
                    replacementBar += 2
                } label: {
                    Image(systemName: "chevron.right")
                }.disabled(replacementBar + 2 >= candidate.document.barCount)
            }
            EditorRenderer(
                document: candidate.document, engine: "OpenSheetMusicDisplay", from: replacementBar,
                through: min(candidate.document.barCount - 1, replacementBar + 1), selection: nil, playhead: nil,
                select: { _ in }, height: $notationHeight, error: $notationError, metrics: $metrics
            ).frame(height: max(180, notationHeight))
            if let notationError { Text(notationError).font(.caption).foregroundStyle(Color.clay) }
            ForEach(Array(candidate.warnings.enumerated()), id: \.offset) { _, text in
                Text("• " + text).font(.caption).foregroundStyle(.secondary)
            }
            Button("Apply replacement to page \(page)") {
                guard let scoreID else { return }
                do {
                    try state.changePDFScore(scoreID) { try $0.replacePDFPage(page, with: candidate) }
                    replacementPage = nil
                } catch {
                    self.error = error.localizedDescription
                    replacementPage = nil
                }
            }.buttonStyle(.cadencePrimary)
            Button("Keep current page; discard replacement") {
                guard let scoreID else { return }
                do {
                    try state.changePDFScore(scoreID) { doc in
                        if let i = doc.pdfSource?.pages?.firstIndex(where: { $0.page == page }) {
                            doc.pdfSource!.pages![i].replacement = nil
                        }
                    }
                    replacementPage = nil
                } catch { self.error = error.localizedDescription }
            }
            if let error { Text(error).font(.caption).foregroundStyle(Color.clay) }
            Button("Back to pages") { replacementPage = nil }
        }
    }
    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in if response == .OK, let url = panel.url { load(url) } }
    }
    private func load(_ url: URL) {
        loadID = UUID()
        let token = loadID
        loading?.cancel()
        opening = true
        error = nil
        loading = Task { @MainActor in
            defer { if token == loadID { opening = false } }
            do {
                let opened = try await PDFImportAsset.read(url)
                try Task.checkCancellation()
                guard token == loadID else { return }
                asset = opened
                page = source?.pages?.first?.page ?? 1
                ranges = String(page)
                passage = selectedRecord?.passage ?? ""
            } catch is CancellationError {} catch { if token == loadID { self.error = error.localizedDescription } }
        }
    }
    private func example() {
        do {
            asset = try PDFImportAsset(
                data: Data(contentsOf: PDFImportExamples.url(instrument == .guitar ? "guitar" : "piano")),
                filename: "Original reading study.pdf")
            page = 1
            ranges = "1"
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func restore() {
        scoreID = state.pdfImportScoreID
        if let scoreID, let score, let source = score.pdfSource {
            instrument = score.instrument
            if source.pages == nil && !state.isPreview {
                do {
                    try state.changePDFScore(scoreID) { doc in
                        var item = PDFImportPage(page: source.page, model: source.model)
                        item.barCount = doc.barCount
                        item.status = .ready
                        item.reviewed = source.reviewed
                        item.warnings = source.warnings
                        item.costUSD = source.costUSD ?? 0
                        item.attempts = 1
                        doc.pdfSource!.pages = [item]
                    }
                } catch { self.error = error.localizedDescription }
            }
            if state.isPreview && CommandLine.arguments.contains("--pdf-batch-preview") {
                asset = try? PDFBatchChecks.asset()
                page = CommandLine.arguments.contains("--pdf-replacement-preview") ? 1 : 2
                if CommandLine.arguments.contains("--pdf-replacement-preview") { replacementPage = 1 }
            } else if let url = state.sourcePDFURL(source) {
                load(url)
            } else {
                error = "The original PDF is missing. Restore PDF Sources from your backup to retry."
            }
        } else if state.isPreview && CommandLine.arguments.contains("--pdf-import-wizard") {
            if CommandLine.arguments.contains("--pdf-range-preview") {
                asset = try? PDFBatchChecks.asset()
                ranges = "1–3"
            } else {
                example()
            }
        }
    }
    private func startNew() {
        guard canRequest, let asset else { return }
        do {
            let key = try aiSettings.requestKey()
            let pages = try PDFPageRanges.parse(ranges, pageCount: asset.pageCount)
            let id = try state.createPDFBatch(
                asset: asset, pages: pages, instrument: instrument, model: model, passage: passage)
            scoreID = id
            page = pages[0]
            error = nil
            queue.start(state: state, scoreID: id, asset: asset, pages: pages, model: model) {
                data, instrument, selection, model in
                try await PDFTranscriptionClient().transcribe(
                    pagePDF: data, instrument: instrument,
                    passage: selection.isEmpty
                        ? "All visible written music on this page, continuing the piece in page order; at most 32 complete bars. Do not invent notes from adjacent pages."
                        : selection, model: model, apiKey: key)
            }
        } catch { self.error = error.localizedDescription }
    }
    private func run(_ pages: [Int], override: String? = nil) {
        guard canRequest, let asset, let scoreID else { return }
        do {
            let key = try aiSettings.requestKey()
            error = nil
            queue.start(state: state, scoreID: scoreID, asset: asset, pages: pages, model: model, passage: override) {
                data, instrument, selection, model in
                try await PDFTranscriptionClient().transcribe(
                    pagePDF: data, instrument: instrument,
                    passage: selection.isEmpty
                        ? "All visible written music on this page, continuing the piece in page order; at most 32 complete bars. Do not invent notes from adjacent pages."
                        : selection, model: model, apiKey: key)
            }
        } catch { self.error = error.localizedDescription }
    }
    private func review(_ page: Int) {
        guard let scoreID,
            let ready = records.first(where: { $0.page == page && $0.barCount > 0 })
                ?? records.first(where: { $0.barCount > 0 })
        else { return }
        state.reviewPDFPage(scoreID: scoreID, page: ready.page)
        dismiss()
    }
}
