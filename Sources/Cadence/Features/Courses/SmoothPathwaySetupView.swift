// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI
import UniformTypeIdentifiers

struct SmoothPathwaySetupView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var song: BookAsset?
    @State private var jazz: BookAsset?
    @State private var inversions = 1
    @State private var songwriting = 1
    @State private var jazzPage = 26
    @State private var source = 0
    @State private var page = 1
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Your books, one pathway").font(.system(size: 28, weight: .medium, design: .serif))
                Spacer()
                Button("Cancel") { dismiss() }
            }
            Text(
                "Choose your editions and check the starting points. The books stay local; the pathway includes four original Cadence studies and a composition invitation."
            ).font(.callout).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("1 · Keyboard songwriting").font(.headline)
                    Button(song?.filename ?? "Choose Rooksby EPUB…", systemImage: "book.closed") { choose(epub: true) }
                        .lineLimit(2)
                    if let song, let epub = song.epub {
                        Text("Inversions").font(.caption).foregroundStyle(.secondary)
                        ChoiceMenu(
                            title: "Inversions section", selection: $inversions,
                            options: Array(1...epub.sections.count), label: { epub.sections[$0 - 1].reference.title })
                        Text("Writing a song").font(.caption).foregroundStyle(.secondary)
                        ChoiceMenu(
                            title: "Songwriting section", selection: $songwriting,
                            options: Array(1...max(1, epub.sections.count - 1)),
                            label: { epub.sections[$0 - 1].reference.title })
                        Button("Read selected inversions section") {
                            source = 0
                            page = inversions
                        }
                    }
                    Divider()
                    Text("2 · Jazz piano").font(.headline)
                    Button(jazz?.filename ?? "Choose Levine PDF…", systemImage: "doc") { choose(epub: false) }
                        .lineLimit(2)
                    if let jazz {
                        Stepper("First PDF page: \(jazzPage)", value: $jazzPage, in: 1...max(1, jazz.pageCount - 1))
                        Text(
                            "Three-Note Voicings, opening two pages. In the inspected edition: PDF 26–27, printed 17–18."
                        ).font(.caption).foregroundStyle(.secondary)
                        Button("Read selected jazz pages") {
                            source = 1
                            page = jazzPage
                        }
                    }
                    Spacer()
                    if busy { ProgressView("Opening your books…").controlSize(.small) }
                    if let error { Text(error).font(.caption).foregroundStyle(Color.clay) }
                    Button("Create my pathway", systemImage: "arrow.right") { create() }.buttonStyle(.cadencePrimary)
                        .controlSize(.large).disabled(song == nil || jazz == nil || busy)
                    Text(
                        "You’ll review the lesson guidance and studies before assessed practice. Nothing is uploaded by this step."
                    ).font(.caption).foregroundStyle(.secondary)
                }.frame(width: 340, height: 560)
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Preview", selection: $source) {
                        Text("EPUB").tag(0)
                        Text("PDF").tag(1)
                    }.pickerStyle(.segmented)
                    if let asset = source == 0 ? song : jazz {
                        BookSourcePane(asset: asset, page: $page)
                    } else {
                        ContentUnavailableView(
                            "The original beside your learning", systemImage: "book.pages",
                            description: Text("Choose the book to preview its source here."))
                    }
                }.frame(width: 440, height: 560)
            }
        }.padding(26).task { await findBooks() }.onChange(of: source) { _, value in
            page = value == 0 ? inversions : jazzPage
        }
    }
    private func choose(epub: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = epub ? [UTType(filenameExtension: "epub")!] : [.pdf]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await load(url, epub: epub) }
        }
    }
    private func load(_ url: URL, epub: Bool) async {
        busy = true
        defer { busy = false }
        do {
            let asset = try await BookAsset.read(url)
            if epub, let document = asset.epub {
                song = asset
                selectSections(document)
                source = 0
                page = inversions
            } else if asset.pdf != nil {
                jazz = asset
                jazzPage = min(26, max(1, asset.pageCount - 1))
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func findBooks() async {
        if state.isPreview {
            song = state.previewBooks.values.first { $0.epub != nil }
            jazz = state.previewBooks.values.first { $0.pdf != nil }
            if let epub = song?.epub {
                selectSections(epub)
                page = inversions
            }
            jazzPage = min(26, max(1, (jazz?.pageCount ?? 2) - 1))
            return
        }
        // Real books are opened only through the learner's file chooser.

    }
    private func selectSections(_ document: EPUBDocument) {
        inversions =
            (document.sections.firstIndex { $0.reference.title.uppercased().contains("THREE CHORDS FROM ONE") } ?? 0)
            + 1
        songwriting = (document.sections.firstIndex { $0.reference.title.uppercased().contains("SECTION 3") } ?? 0) + 1
    }
    private func create() {
        guard let song, let jazz else { return }
        do {
            try state.installSmoothPathway(
                songAsset: song, jazzAsset: jazz, inversions: inversions, songwriting: songwriting, jazzPage: jazzPage)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
