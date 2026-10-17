// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import MusicCore
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var audio: AudioPlayer
    @ObservedObject var midi: MIDIKeyboard
    @State private var showTheory = false
    @State private var showHarmony = false
    @State private var harmonyID: UUID?
    @State private var showMIDI = false
    @State private var reviewSource = false
    @State private var reviewWarnings = false
    @State private var selectedID: UUID?
    @State private var pitchID: UUID?
    @State private var session = EditorSession()
    @State private var height: CGFloat = 280
    @State private var renderError: String?
    @State private var metrics = "Preparing the score…"
    @State private var speed = 1.0
    @State private var loop = true
    @State private var countIn = true
    @State private var comparison = false
    @State private var message: String?
    @State private var wholePiece = true
    @State private var rangeFrom = 0
    @State private var rangeThrough = 3
    @State private var copied: EditorDocument?
    @State private var writing = false
    @State private var entryRhythm = EditorRhythm()
    @State private var entryOctave = 4
    @State private var click = false
    @FocusState private var titleFocused: Bool
    private var scoreInputBlocked: Bool { showTheory || showHarmony || state.showPDFImport }
    private var shortcutsBlocked: Bool { titleFocused || scoreInputBlocked }
    private var document: EditorDocument { state.editor.active }
    private var selected: EditorEvent? { document.events.first { $0.id == selectedID } ?? document.events.first }
    private var polyphonic: Bool { (1...document.staffCount).contains { document.voices(staff: $0).count > 1 } }
    private var needsOSMD: Bool { polyphonic || !document.harmonies.isEmpty }
    private var pitch: EditorPitch? { selected?.pitches.first { $0.id == pitchID } ?? selected?.pitches.first }
    private var passage: ClosedRange<Int> {
        let start = min(rangeFrom, document.barCount - 1)
        return start...min(document.barCount - 1, max(start, rangeThrough))
    }
    private var playbackRange: ClosedRange<Int> { wholePiece ? 0...document.barCount - 1 : passage }
    private var displayFrom: Int { wholePiece ? 0 : passage.lowerBound }
    private var displayThrough: Int { wholePiece ? document.barCount - 1 : passage.upperBound }
    private var pageStart: Int { ((selected?.bar ?? 0) / 4) * 4 }
    private var pageEnd: Int { min(document.barCount - 1, pageStart + 3) }
    private var rhythms: [EditorRhythm] { EditorRhythm.choices.filter { $0.ticks <= document.meter.ticks } }
    private var keyRoots: [Pitch] {
        [
            Pitch(0, -1), Pitch(4, -1), Pitch(1, -1), Pitch(5, -1), Pitch(2, -1), Pitch(6, -1), Pitch(3), Pitch(0),
            Pitch(4), Pitch(1), Pitch(5), Pitch(2), Pitch(6), Pitch(3, 1), Pitch(0, 1),
        ]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            toolbar
            Button("Score analysis", systemImage: "pencil.and.outline") {
                audio.stop()
                showMIDI = false
                showTheory = true
            }
            if let source = document.reharmSource { ReharmAnswerBar(source: source) }
            if let source = document.tensionSource { TensionAnswerBar(source: source, instrument: document.instrument) }
            if let material = document.triadSource { TriadAnswerBar(material: material) }
            if document.responseSource != nil { CreativeAnswerBar(document: document, audio: audio) }
            if let source = document.pdfSource { pdfReviewBanner(source) }
            if let source = document.pdfSource, source.pages != nil && source.importedPageCount == 0 {
                ContentUnavailableView(
                    "Your pages are waiting", systemImage: "doc.text",
                    description: Text(
                        "Open Pages & retries to continue this import. Completed pages will appear here as one editable score."
                    ))
            } else if reviewSource, let source = document.pdfSource {
                pdfReviewWorkspace(source.reference(at: selected?.bar ?? 0))
            } else {
                standardWorkspace
            }
        }
        .onAppear {
            reviewSource = document.pdfSource != nil
            if state.isPreview && CommandLine.arguments.contains("--pdf-review-check") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { pdfReviewChecks() }
            }
            if needsOSMD { state.editor.engine = "OpenSheetMusicDisplay" }
            if state.isPreview && CommandLine.arguments.contains("--midi-entry-check") { showMIDI = true }
            entryOctave = document.instrument == .guitar ? 3 : 4
            if (document.responseSource != nil || document.triadSource != nil || document.tensionSource != nil)
                && document.events.allSatisfy(\.isRest)
            {
                writing = true
                entryRhythm = EditorRhythm()
            }
            if selectedID == nil { select(document.events[0].id) }
            if state.isPreview {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    titleFocused = false
                    NSApp.windows.first?.makeFirstResponder(nil)
                }
            }
            if state.isPreview && CommandLine.arguments.contains("--editor-check") { nativeChecks() }
            if state.isPreview && CommandLine.arguments.contains("--poly-check") { polyChecks() }
            if state.isPreview && CommandLine.arguments.contains("--harmony-check") { harmonyChecks() }
            if state.isPreview && CommandLine.arguments.contains("--harmony-sheet") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    harmonyID = document.harmonies.dropFirst().first?.id
                    showHarmony = true
                }
            }
            if state.isPreview && CommandLine.arguments.contains("--editor-page-two") {
                wholePiece = false
                selectBar(4)
                rangeFrom = 4
                rangeThrough = min(7, document.barCount - 1)
            }
            if state.isPreview && CommandLine.arguments.contains("--editor-writing") { writing = true }
            if state.isPreview && CommandLine.arguments.contains("--tension-editor-guard") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    audio.stop()
                    showMIDI = false
                    showTheory = true
                    let before = document
                    let wrote = enterMIDI([60])
                    TensionDiagnostics.checks["analysisBlocksMIDI"] = !wrote && document == before
                    enterLetter(0)
                    TensionDiagnostics.checks["analysisBlocksNoteKeys"] = document == before
                }
            }
            focusPDFPage()
            applyOpeningFocus()
            if state.isPreview && CommandLine.arguments.contains("--editor-live-edit") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    let first = document.events[0]
                    select(first.id)
                    let rhythm =
                        CommandLine.arguments.contains("--editor-triplet")
                        ? EditorRhythm(240, triplet: true) : EditorRhythm(240)
                    edit {
                        try $0.setPitch(first.id, midi: first.pitches[0].midi + 1)
                        try $0.setRhythm(first.id, rhythm)
                    }
                    EditorDiagnostics.native["liveEdit"] =
                        document.events[0].rhythm == rhythm
                        && document.events[0].pitches[0].midi == first.pitches[0].midi + 1
                }
            }
        }
        .onChange(of: state.editor.active.id) { _, _ in
            audio.stop()
            reviewSource = document.pdfSource != nil
            session.reset()
            wholePiece = true
            rangeFrom = 0
            rangeThrough = min(3, document.barCount - 1)
            entryOctave = document.instrument == .guitar ? 3 : 4
            select(document.events[0].id)
            applyOpeningFocus()
        }
        .onChange(of: state.editorPassageFocus) { _, _ in applyOpeningFocus() }
        .onChange(of: wholePiece) { _, _ in audio.stop() }
        .onChange(of: state.pdfReviewPage) { _, _ in focusPDFPage() }
        .onChange(of: state.pdfImportRevision) { _, _ in
            session.reset()
            ensureSelection()
            clampPassage()
        }
        .onChange(of: state.editor) { _, _ in
            if needsOSMD && state.editor.engine != "OpenSheetMusicDisplay" {
                state.editor.engine = "OpenSheetMusicDisplay"
            }
            state.saveSoon()
        }
        .onChange(of: speed) { _, _ in audio.stop() }
        .onChange(of: loop) { _, _ in audio.stop() }
        .onChange(of: click) { _, _ in audio.stop() }
        .onChange(of: rangeFrom) { _, value in
            audio.stop()
            rangeThrough = min(document.barCount - 1, max(value, min(rangeThrough, value + 15)))
        }
        .onChange(of: rangeThrough) { _, _ in audio.stop() }
        .onChange(of: document.meter) { _, _ in if !rhythms.contains(entryRhythm) { entryRhythm = EditorRhythm() } }
        .onChange(of: audio.studyPlayhead) { _, head in
            if !wholePiece, let head, !head.isCountIn {
                let bar = min(document.barCount - 1, Int(head.sourceBeat * 480) / document.meter.ticks)
                if bar < (reviewSource ? reviewStart : pageStart) || bar > (reviewSource ? reviewEnd : pageEnd) {
                    selectBar(bar)
                }
            }
        }
        .onChange(of: countIn) { _, _ in audio.stop() }
        .onDisappear { audio.stop() }
        .sheet(isPresented: $showTheory) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Score analysis").font(.title2)
                    Spacer()
                    Button("Done") { showTheory = false }
                }
                ScrollView {
                    ScoreAnalysisPanel(
                        piece: .init(source: .score(document)),
                        scope: .init(partID: "P1", staff: 1, from: pageStart, through: pageEnd))
                }
            }.padding(24).frame(width: 940, height: 780).background(Color.paper)
        }
        .sheet(isPresented: $showHarmony) {
            EditorHarmonyView(
                document: document, selected: selected, harmony: document.harmonies.first { $0.id == harmonyID },
                save: { item in try apply { try $0.setHarmony(item) } },
                remove: { id in try apply { $0.removeHarmony(id) } })
        }
        .alert("Compose", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }
    private func applyOpeningFocus() {
        guard let focus = state.editorPassageFocus, focus.documentID == document.id else { return }
        wholePiece = focus.wholePiece
        rangeFrom = max(0, min(document.barCount - 1, focus.from))
        rangeThrough = max(rangeFrom, min(document.barCount - 1, min(focus.through, rangeFrom + 15)))
        if wholePiece {
            reviewSource = false
            loop = false
        }
        selectBar(rangeFrom)
        state.editorPassageFocus = nil
        if state.isPreview {
            EditorDiagnostics.native["returnPassageFocus"] =
                selected?.bar == rangeFrom && passage.lowerBound == rangeFrom && passage.upperBound == rangeThrough
        }
    }
    private var standardWorkspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(
                title: "Your score",
                subtitle: "\(document.instrument.rawValue) · \(document.barCount) bars · \(state.storageStatus)",
                padding: 18, spacing: 12
            ) {
                HStack(spacing: 10) {
                    TextField(
                        "Score title",
                        text: Binding(
                            get: { document.title }, set: { value in edit { $0.title = String(value.prefix(120)) } })
                    ).font(.system(size: 20, weight: .medium, design: .serif)).textFieldStyle(.plain).focused(
                        $titleFocused)
                    Spacer()
                    ChoiceMenu(
                        title: "Key signature",
                        selection: Binding(
                            get: { document.fifths + 7 + (document.minor ? 15 : 0) },
                            set: { value in
                                edit {
                                    $0.fifths = value % 15 - 7
                                    $0.minor = value >= 15
                                }
                            }), options: Array(0..<30)
                    ) { value in
                        value < 15
                            ? "\(keyRoots[value].name) major" : "\(Scale.major.notes(keyRoots[value-15])[5].name) minor"
                    }.frame(width: 135)
                    ChoiceMenu(
                        title: "Time signature",
                        selection: Binding(get: { document.meter }, set: { value in edit { try $0.setMeter(value) } }),
                        options: EditorMeter.choices
                    ) { $0.label }.frame(width: 95)
                    Stepper(
                        "\(document.tempo) bpm",
                        value: Binding(get: { document.tempo }, set: { value in edit { $0.tempo = value } }),
                        in: 20...300
                    ).fixedSize()
                }
                HStack(spacing: 7) {
                    Toggle("Write", isOn: $writing).toggleStyle(.button).help(
                        "Write uses the chosen duration, then advances. Edit changes the selected note in place.")
                    if writing {
                        ChoiceMenu(title: "Note value", selection: $entryRhythm, options: rhythms) { $0.label }
                            .labelsHidden().frame(width: 140)
                    }
                    if writing { Stepper("Oct \(entryOctave)", value: $entryOctave, in: 1...7).fixedSize() }
                    ForEach(Array(Pitch.letters.enumerated()), id: \.offset) { index, letter in
                        Button(letter) { enterLetter(index) }.keyboardShortcut(
                            shortcutsBlocked
                                ? nil : KeyboardShortcut(KeyEquivalent(Character(letter.lowercased())), modifiers: [])
                        ).frame(width: 34)
                    }
                    Button("Rest") { rest() }.keyboardShortcut(
                        shortcutsBlocked ? nil : KeyboardShortcut("r", modifiers: []))
                    Button("Add chord tone", systemImage: "plus") { edit { try $0.addChordTone(selected!.id) } }
                        .disabled(selected?.isRest != false)
                    Spacer()
                    Button {
                        move(-1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }.help("Previous event (←)").keyboardShortcut(
                        shortcutsBlocked ? nil : KeyboardShortcut(.leftArrow, modifiers: []))
                    Button {
                        move(1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }.help("Next event (→)").keyboardShortcut(
                        shortcutsBlocked ? nil : KeyboardShortcut(.rightArrow, modifiers: []))
                }.controlSize(.small)
                voiceControls
                harmonyControls
                if showMIDI {
                    EditorMIDIView(
                        midi: midi, audio: audio, context: "\(document.id):\(selected?.id.uuidString ?? "")",
                        instrument: document.instrument, rhythms: rhythms, rhythm: $entryRhythm, enter: enterMIDI)
                }
                HStack(spacing: 10) {
                    Picker("View", selection: $wholePiece) {
                        Text("Whole piece").tag(true)
                        Text("Focus on a passage").tag(false)
                    }.pickerStyle(.segmented).frame(width: 280)
                    if !wholePiece {
                        Button {
                            showPage(-1)
                        } label: {
                            Image(systemName: "chevron.left")
                        }.disabled(pageStart == 0).help("Previous four bars")
                        Text("Bars \(pageStart+1)–\(pageEnd+1) of \(document.barCount)").font(
                            .caption.monospacedDigit())
                        Button {
                            showPage(1)
                        } label: {
                            Image(systemName: "chevron.right")
                        }.disabled(pageEnd == document.barCount - 1).help("Next four bars")
                    }
                    Menu("Bar tools", systemImage: "rectangle.split.3x1") {
                        Button("Insert empty bar before") { insertBar(before: true) }
                        Button("Insert empty bar after") { insertBar(before: false) }
                        Button("Duplicate this bar") { duplicateBar() }
                        Divider()
                        Button("Delete this bar") { deleteSelectedBar() }.disabled(document.barCount == 1)
                    }.fixedSize()
                    Button("Add four bars", systemImage: "plus") {
                        edit { try $0.insertBars(at: $0.barCount, count: min(4, 128 - $0.barCount)) }
                    }.disabled(document.barCount >= 128)
                    Spacer()
                    Menu("Practise", systemImage: "play.circle") {
                        Button("Practise this piece") {
                            state.openPieceRehearsal(LibraryPiece(source: .score(document)))
                        }
                        Button("Listen, sing or read in Studies") {
                            state.practiseEditor(
                                document, from: passage.lowerBound, through: passage.upperBound, speed: speed,
                                loop: loop, countIn: countIn, metronome: click)
                            state.studyWholePiece = wholePiece
                        }
                    }
                    Button(
                        audio.isPlaying ? "Stop" : "Play \(playbackRange.lowerBound+1)–\(playbackRange.upperBound+1)",
                        systemImage: audio.isPlaying ? "stop.fill" : "play.fill"
                    ) { audio.isPlaying ? audio.stop() : play() }.buttonStyle(.cadencePrimary).keyboardShortcut(
                        shortcutsBlocked ? nil : KeyboardShortcut(.space, modifiers: []))
                }.controlSize(.small)
                if !wholePiece {
                    HStack {
                        ChoiceMenu(title: "From bar", selection: $rangeFrom, options: Array(0..<document.barCount)) {
                            "From \($0+1)"
                        }.frame(width: 140)
                        Picker("Through", selection: $rangeThrough) {
                            ForEach(rangeFrom...min(document.barCount - 1, rangeFrom + 15), id: \.self) {
                                Text("Bar \($0+1)").tag($0)
                            }
                        }.frame(width: 155)
                        Text("Choose up to 16 bars to loop or practise.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }.controlSize(.small)
                }
                EditorRenderer(
                    document: document, engine: state.editor.engine, from: displayFrom, through: displayThrough,
                    selection: selected?.id, playhead: audio.studyPlayhead, select: select, height: $height,
                    error: $renderError, metrics: $metrics
                ).id(state.editor.engine).frame(height: min(560, height))
                if let renderError {
                    Text(renderError).font(.caption).foregroundStyle(Color.clay).textSelection(.enabled)
                }
                HStack {
                    Text(
                        document.instrument == .guitar
                            ? "Click a note or fret number to select it. Both staves describe the same music."
                            : "Click a note to select it. The hands and voices keep independent rhythms."
                    ).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("A–G notes · R rest · ← → move").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            if let selected { inspector(selected) }
            eventMap
            inputInstrument
            Text(
                "Up to 128 bars · two voices per staff · one key and meter per score. MusicXML import opens this supported subset; advanced notation can be read in Studies."
            ).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var sourceRange: Range<Int> {
        let source = document.pdfSource
        return source?.page(at: selected?.bar ?? 0).flatMap { source?.range(for: $0.page) } ?? 0..<document.barCount
    }
    private var reviewStart: Int { sourceRange.lowerBound + (((selected?.bar ?? 0) - sourceRange.lowerBound) / 2) * 2 }
    private var reviewEnd: Int { min(sourceRange.upperBound - 1, reviewStart + 1) }
    private func focusPDFPage() {
        guard let page = state.pdfReviewPage, let source = document.pdfSource else { return }
        let range =
            source.range(for: page) ?? (source.pages == nil && source.page == page ? 0..<document.barCount : nil)
        guard let range else { return }
        reviewSource = true
        selectBar(range.lowerBound)
        state.pdfReviewPage = nil
        if state.isPreview && CommandLine.arguments.contains("--course-score-review") {
            CourseDiagnostics.checks["sourceReviewOpened"] = true
        }
    }
    private func pdfReviewBanner(_ source: PDFScoreSource) -> some View {
        let reference = source.reference(at: selected?.bar ?? 0)
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Image(systemName: reference.reviewed ? "checkmark.seal" : "doc.viewfinder").foregroundStyle(Color.moss)
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        reference.reviewed
                            ? "Page reviewed by you"
                            : reference.model == "Cadence original example"
                                ? "Original example · ready for your review" : "AI draft · ready for your review"
                    ).font(.callout).fontWeight(.medium)
                    Text("Page \(reference.page) · \(source.filename)").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Toggle(
                    "Page reviewed",
                    isOn: Binding(
                        get: { document.pdfSource?.reference(at: selected?.bar ?? 0).reviewed ?? false },
                        set: { value in edit { $0.pdfSource?.setReviewed(value, page: reference.page) } })
                ).toggleStyle(.checkbox).font(.caption).disabled(source.importedPageCount == 0)
                Button(
                    reviewSource ? "Full editor" : "Source & draft",
                    systemImage: reviewSource ? "square.and.pencil" : "rectangle.split.2x1"
                ) {
                    audio.stop()
                    showMIDI = false
                    reviewSource.toggle()
                }.controlSize(.small)
            }
            HStack(spacing: 12) {
                if let pages = source.pages {
                    Text(
                        "\(source.importedPageCount)/\(pages.count) pages ready · \(pages.filter { $0.reviewed && $0.barCount > 0 }.count) reviewed"
                    ).font(.caption).foregroundStyle(.secondary)
                    if source.importedPageCount > 0 {
                        Picker(
                            "Source page",
                            selection: Binding(
                                get: { reference.page },
                                set: { page in
                                    if let range = source.range(for: page) {
                                        audio.stop()
                                        selectBar(range.lowerBound)
                                    }
                                })
                        ) {
                            ForEach(pages.filter { $0.barCount > 0 }) { Text("\($0.page)").tag($0.page) }
                        }.frame(width: 145)
                    }
                }
                Spacer(minLength: 0)
                Button("Pages & retries", systemImage: "doc.on.doc") {
                    state.pdfImportScoreID = document.id
                    state.showPDFImport = true
                }
            }.controlSize(.small)
            if let pages = source.pages, source.importedPageCount < pages.count {
                Text(
                    "Missing pages: \(pages.filter { $0.barCount == 0 }.map { String($0.page) }.joined(separator:", ")). Completed pages play consecutively."
                ).font(.caption).foregroundStyle(Color.clay)
            }
            DisclosureGroup(
                "Page \(reference.page) import notes · \(reference.warnings.count) to review",
                isExpanded: $reviewWarnings
            ) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(reference.warnings.enumerated()), id: \.offset) { _, text in
                        Text("• " + text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text(
                        "Check pitches, rhythms, voices and page joins against the original. Editing a page clears its review mark; key or meter changes clear every page's mark."
                    ).font(.caption).foregroundStyle(.secondary)
                    if let cost = reference.costUSD {
                        Text(String(format: "Reported page cost: US$%.4f · ", cost) + reference.model).font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }.padding(.top, 7)
            }.font(.caption)
        }.padding(14).background(Color.moss.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
    private func pdfReviewWorkspace(_ source: PDFScoreSource) -> some View {
        HStack(alignment: .top, spacing: 18) {
            PDFReferencePane(url: state.sourcePDFURL(source), source: source).id(source.fileID).frame(
                minWidth: 300, idealWidth: 390, maxWidth: 420
            ).frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 12) {
                TextField(
                    "Score title",
                    text: Binding(
                        get: { document.title }, set: { value in edit { $0.title = String(value.prefix(120)) } })
                ).font(.system(size: 20, weight: .medium, design: .serif)).textFieldStyle(.plain).focused($titleFocused)
                HStack(spacing: 10) {
                    ChoiceMenu(
                        title: "Key signature",
                        selection: Binding(
                            get: { document.fifths + 7 + (document.minor ? 15 : 0) },
                            set: { value in
                                edit {
                                    $0.fifths = value % 15 - 7
                                    $0.minor = value >= 15
                                }
                            }), options: Array(0..<30)
                    ) { value in
                        value < 15
                            ? "\(keyRoots[value].name) major" : "\(Scale.major.notes(keyRoots[value-15])[5].name) minor"
                    }.frame(width: 160)
                    ChoiceMenu(
                        title: "Time signature",
                        selection: Binding(get: { document.meter }, set: { value in edit { try $0.setMeter(value) } }),
                        options: EditorMeter.choices
                    ) { $0.label }.frame(width: 105)
                    Spacer(minLength: 0)
                }.controlSize(.small)
                HStack(spacing: 9) {
                    Button {
                        selectBar(max(0, reviewStart - 2))
                    } label: {
                        Image(systemName: "chevron.left")
                    }.disabled(reviewStart == 0)
                    Text("Bars \(reviewStart+1)–\(reviewEnd+1) of \(document.barCount)").font(
                        .caption.monospacedDigit())
                    Button {
                        selectBar(min(document.barCount - 1, reviewEnd + 1))
                    } label: {
                        Image(systemName: "chevron.right")
                    }.disabled(reviewEnd == document.barCount - 1)
                    Spacer(minLength: 0)
                    Button(
                        audio.isPlaying ? "Stop" : "Play these bars",
                        systemImage: audio.isPlaying ? "stop.fill" : "play.fill"
                    ) { audio.isPlaying ? audio.stop() : play(bar: reviewStart, through: reviewEnd) }.keyboardShortcut(
                        shortcutsBlocked ? nil : KeyboardShortcut(.space, modifiers: []))
                }.controlSize(.small)
                ScrollView {
                    EditorRenderer(
                        document: document, engine: "OpenSheetMusicDisplay", from: reviewStart, through: reviewEnd,
                        selection: selected?.id, playhead: audio.studyPlayhead, select: select, height: $height,
                        error: $renderError, metrics: $metrics
                    ).id("pdf-review").frame(height: height)
                }.frame(height: min(300, max(170, height)))
                if let renderError { Text(renderError).font(.caption).foregroundStyle(Color.clay) }
                harmonyControls
                if let selected { pdfCorrectionControls(selected) }
                Spacer(minLength: 0)
                Button("Practise these bars", systemImage: "arrow.up.right.square") {
                    state.practiseEditor(
                        document, from: reviewStart, through: reviewEnd, speed: speed, loop: loop, countIn: countIn,
                        metronome: click)
                }.controlSize(.small)
                Text(
                    "Click a note or tab number to correct it. Full editor opens all markings, passage tools, instruments and MIDI entry."
                ).font(.caption).foregroundStyle(.secondary)
            }.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.padding(14).frame(height: 668).background(Color.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 15))
    }
    private func pdfCorrectionControls(_ event: EditorEvent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack {
                Text(
                    "Bar \(event.bar+1) · beat \(String(format:"%.2g",Double(document.onset(event))*Double(document.meter.unit)/1920+1))"
                ).font(.callout).fontWeight(.medium)
                Spacer()
                Button {
                    move(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }.keyboardShortcut(shortcutsBlocked ? nil : KeyboardShortcut(.leftArrow, modifiers: []))
                Button {
                    move(1)
                } label: {
                    Image(systemName: "chevron.right")
                }.keyboardShortcut(shortcutsBlocked ? nil : KeyboardShortcut(.rightArrow, modifiers: []))
            }
            HStack(spacing: 10) {
                if document.instrument == .piano {
                    Picker(
                        "Hand",
                        selection: Binding(
                            get: { event.staff },
                            set: { staff in
                                if let first = document.inBar(event.bar, staff: staff).first { select(first.id) }
                            })
                    ) {
                        Text("Right").tag(1)
                        Text("Left").tag(2)
                    }.frame(width: 125)
                }
                Picker(
                    "Voice",
                    selection: Binding(
                        get: { event.voice },
                        set: { voice in
                            if let first = document.inBar(event.bar, staff: event.staff, voice: voice).first {
                                select(first.id)
                            }
                        })
                ) { ForEach(document.voices(staff: event.staff), id: \.self) { Text("\($0)").tag($0) } }.frame(
                    width: 95)
                Spacer(minLength: 0)
                Text(event.label).font(.callout).lineLimit(1)
            }
            HStack(spacing: 10) {
                Picker(
                    "Duration",
                    selection: Binding(
                        get: { event.rhythm }, set: { value in edit { try $0.setRhythm(event.id, value) } })
                ) { ForEach(rhythms, id: \.self) { Text($0.label).tag($0) } }.frame(width: 185)
                Toggle(
                    "Tie to next",
                    isOn: Binding(get: { event.tieNext }, set: { value in mark(event.id) { $0.tieNext = value } })
                ).disabled(event.isRest)
                Spacer(minLength: 0)
            }
            if let pitch {
                HStack(spacing: 8) {
                    Picker(
                        "Note",
                        selection: Binding(
                            get: { pitch.spelling.letter }, set: { value in setWritten(pitch, letter: value) })
                    ) { ForEach(0..<7, id: \.self) { Text(Pitch.letters[$0]).tag($0) } }.frame(width: 80)
                    ChoiceMenu(
                        title: "Accidental",
                        selection: Binding(
                            get: { pitch.spelling.accidental }, set: { value in setWritten(pitch, accidental: value) }),
                        options: Array(-2...2)
                    ) { ["♭♭", "♭", "♮", "♯", "𝄪"][$0 + 2] }.frame(width: 122)
                    Stepper(
                        "Oct \(octave(pitch))",
                        value: Binding(get: { octave(pitch) }, set: { value in setWritten(pitch, octave: value) }),
                        in: 1...8
                    ).fixedSize()
                    Button("−") { shift(-1) }.keyboardShortcut(
                        shortcutsBlocked ? nil : KeyboardShortcut(.downArrow, modifiers: []))
                    Button("+") { shift(1) }.keyboardShortcut(
                        shortcutsBlocked ? nil : KeyboardShortcut(.upArrow, modifiers: []))
                }
                HStack(spacing: 8) {
                    Picker("Tone", selection: Binding(get: { pitch.id }, set: { pitchID = $0 })) {
                        ForEach(event.pitches) { Text($0.label).tag($0.id) }
                    }.frame(width: 150)
                    Button("Add tone") { edit { try $0.addChordTone(event.id) } }
                    Button("Remove") {
                        edit { doc in
                            if let i = doc.events.firstIndex(where: { $0.id == event.id }) {
                                doc.events[i].pitches.removeAll { $0.id == pitch.id }
                                doc.clearInvalidTies()
                            }
                        }
                    }.disabled(event.pitches.count <= 1)
                    Button("Hear", systemImage: "speaker.wave.2") { audio.chord(event.pitches.map(\.midi)) }
                    Spacer(minLength: 0)
                }
                if document.instrument == .guitar {
                    HStack(spacing: 10) {
                        Picker(
                            "String",
                            selection: Binding(
                                get: { pitch.string ?? 0 },
                                set: { string in chooseString(string, pitch: pitch, event: event) })
                        ) { ForEach((0..<6).reversed(), id: \.self) { Text("\(6-$0)").tag($0) } }.frame(width: 105)
                        Stepper(
                            "Fret \(pitch.fret ?? 0)",
                            value: Binding(
                                get: { pitch.fret ?? 0 },
                                set: { fret in
                                    edit {
                                        try $0.setFingering(
                                            event.id, pitchID: pitch.id, string: pitch.string ?? 0, fret: fret)
                                    }
                                }), in: 0...24
                        ).fixedSize()
                    }
                }
            }
            HStack(spacing: 5) {
                ForEach(0..<7, id: \.self) { index in
                    Button(Pitch.letters[index]) { enterLetter(index) }.keyboardShortcut(
                        shortcutsBlocked
                            ? nil
                            : KeyboardShortcut(
                                KeyEquivalent(Character(Pitch.letters[index].lowercased())), modifiers: []))
                }
                Button("Rest") { rest() }.keyboardShortcut(
                    shortcutsBlocked ? nil : KeyboardShortcut("r", modifiers: []))
            }
        }.controlSize(.small)
    }
    private func pdfReviewChecks() {
        guard let source = document.pdfSource, let first = document.events.first(where: { !$0.isRest }) else {
            PDFImportDiagnostics.checks["draftHasSource"] = false
            return
        }
        let original = document
        select(first.id)
        PDFImportDiagnostics.checks["draftHasSource"] =
            state.sourcePDFURL(source).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        edit { $0.pdfSource?.reviewed = true }
        PDFImportDiagnostics.checks["manualReviewMark"] = document.pdfSource?.reviewed == true
        let marked = document
        edit { try $0.setPitch(first.id, pitchID: first.pitches[0].id, midi: first.pitches[0].midi + 1) }
        PDFImportDiagnostics.checks["correctionClearsReview"] =
            document.pdfSource?.reviewed == false
            && document.events.first { $0.id == first.id }?.pitches.first?.midi == first.pitches[0].midi + 1
        undoOnce()
        PDFImportDiagnostics.checks["correctionUndo"] = document == marked
        redoOnce()
        PDFImportDiagnostics.checks["correctionRedo"] = document.pdfSource?.reviewed == false
        undoOnce()
        undoOnce()
        PDFImportDiagnostics.checks["sourceRetained"] = document == original
        if document.instrument == .guitar {
            PDFImportDiagnostics.checks["linkedTabPresent"] = document.events.filter { !$0.isRest }.allSatisfy {
                $0.pitches.allSatisfy { $0.string != nil && $0.fret != nil }
            }
        }
        session.reset()
        select(first.id)
    }
    private var toolbar: some View {
        HStack(spacing: 10) {
            ChoiceMenu(
                title: "Score", selection: Binding(get: { document.id }, set: { state.editor.activeID = $0 }),
                options: state.editor.documents.map(\.id)
            ) { id in state.editor.documents.first { $0.id == id }?.title ?? "Choose score" }.frame(maxWidth: 300)
            Menu("New", systemImage: "plus") {
                Button("Guitar score") { blank(.guitar) }
                Button("Piano score") { blank(.piano) }
                Divider()
                Button("Fingerstyle guitar study") { addExample(.fingerstyleExample) }
                Button("Piano inner-voice study") { addExample(.innerVoiceExample) }
                Button("Lead sheet with chord symbols") { addExample(.leadSheetExample) }
            }.fixedSize()
            Button("Library", systemImage: "books.vertical") {
                state.showLibraryPiece("score:" + document.id.uuidString)
            }
            Button("Open", systemImage: "folder") { open() }
            Button("Import PDF", systemImage: "doc.viewfinder") {
                state.pdfImportScoreID = nil
                state.showPDFImport = true
            }
            Menu("Export", systemImage: "square.and.arrow.up") {
                Button("MusicXML — notation and tab") { export("musicxml") }
                Button("MIDI") { export("mid") }
                Button("Cadence score — exact editable copy") { export("cadence-score") }
            }.fixedSize()
            Spacer()
            Button {
                undoOnce()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }.disabled(!session.canUndo).keyboardShortcut("z")
            Button {
                redoOnce()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }.disabled(!session.canRedo).help("Redo").keyboardShortcut("z", modifiers: [.command, .shift])
        }.controlSize(.small)
    }
    private var harmonyControls: some View {
        HStack(spacing: 10) {
            Button("Chord symbols", systemImage: "text.badge.plus") {
                audio.stop()
                harmonyID = nil
                showHarmony = true
            }
            FollowChangesButton(
                piece: LibraryPiece(source: .score(document)), from: passage.lowerBound, through: passage.upperBound)
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(document.harmonies(in: selected?.bar ?? 0)) { item in
                        Button(
                            item.symbol.label + " · "
                                + String(format: "%.4g", Double(item.tick) * Double(document.meter.unit) / 1920 + 1)
                        ) {
                            harmonyID = item.id
                            showHarmony = true
                        }.padding(.vertical, 3)
                    }
                }
            }
            Text("Bar \((selected?.bar ?? 0)+1)").font(.caption).foregroundStyle(.secondary)
        }.controlSize(.small)
    }
    private var voiceControls: some View {
        HStack(spacing: 12) {
            if document.instrument == .piano {
                ChoiceMenu(
                    title: "Hand",
                    selection: Binding(
                        get: { selected?.staff ?? 1 },
                        set: { staff in
                            if let e = document.inBar(selected?.bar ?? 0, staff: staff, voice: 1).first { select(e.id) }
                        }), options: [1, 2]
                ) { $0 == 1 ? "Right hand" : "Left hand" }.frame(width: 140)
            }
            ChoiceMenu(
                title: "Voice",
                selection: Binding(
                    get: { selected?.voice ?? 1 },
                    set: { voice in
                        if let e = document.inBar(selected?.bar ?? 0, staff: selected?.staff ?? 1, voice: voice).first {
                            select(e.id)
                        }
                    }), options: document.voices(staff: selected?.staff ?? 1)
            ) { $0 == 1 ? "Voice 1 · upper" : "Voice 2 · lower" }.frame(width: 175)
            if !document.voices(staff: selected?.staff ?? 1).contains(2) {
                Button("Add second voice", systemImage: "plus") {
                    let staff = selected?.staff ?? 1
                    let bar = selected?.bar ?? 0
                    if edit({ try $0.addVoice(staff: staff) }),
                        let e = document.inBar(bar, staff: staff, voice: 2).first
                    {
                        select(e.id)
                    }
                }
            } else {
                Menu {
                    Button("Remove voice 2 from this staff (undoable)") {
                        let staff = selected?.staff ?? 1
                        edit { try $0.removeSecondVoice(staff: staff) }
                    }
                } label: {
                    Label("Voice tools", systemImage: "ellipsis.circle")
                }.fixedSize()
            }
            Toggle("MIDI keyboard", isOn: $showMIDI).toggleStyle(.button)
            Spacer()
            Text(polyphonic ? "Auto stems · 1 up / 2 down" : "Each voice has its own notes and rests").font(.caption)
                .foregroundStyle(.secondary)
        }.controlSize(.small)
    }
    private func expressionControls(_ selected: EditorEvent) -> some View {
        HStack(spacing: 14) {
            ChoiceMenu(
                title: "Stem direction",
                selection: Binding(get: { selected.stem }, set: { value in mark(selected.id) { $0.stem = value } }),
                options: EditorStem.allCases
            ) { $0.rawValue.capitalized + " stem" }.frame(width: 140)
            Toggle(
                "Staccato",
                isOn: Binding(get: { selected.staccato }, set: { value in mark(selected.id) { $0.staccato = value } })
            ).disabled(selected.isRest)
            Toggle(
                "Accent",
                isOn: Binding(get: { selected.accent }, set: { value in mark(selected.id) { $0.accent = value } })
            ).disabled(selected.isRest)
            Picker(
                "Dynamic",
                selection: Binding(
                    get: { selected.dynamic }, set: { value in mark(selected.id) { $0.dynamic = value } })
            ) {
                Text("Continue").tag(Optional<MusicDynamic>.none)
                ForEach(MusicDynamic.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }.frame(width: 145).help("A dynamic continues in this voice until its next marking.")
            Picker(
                "Slur to",
                selection: Binding(get: { selected.slurTo }, set: { value in mark(selected.id) { $0.slurTo = value } })
            ) {
                Text("None").tag(Optional<UUID>.none)
                ForEach(document.slurTargets(selected)) { e in
                    Text(
                        "Bar \(e.bar+1) · beat \(String(format:"%.2g",Double(document.onset(e))*Double(document.meter.unit)/1920+1)) · \(e.label)"
                    ).tag(Optional(e.id))
                }
            }.frame(maxWidth: 300).disabled(selected.isRest).help(
                "Join a phrase in the same voice. Slurs cannot cross rests or overlap.")
            Spacer(minLength: 0)
        }.controlSize(.small)
    }
    private func mark(_ id: UUID, _ change: (inout EditorEvent) -> Void) {
        edit { doc in if let i = doc.events.firstIndex(where: { $0.id == id }) { change(&doc.events[i]) } }
    }
    private func inspector(_ selected: EditorEvent) -> some View {
        Card(
            title:
                "Bar \(selected.bar+1) · beat \(String(format:"%.2g",Double(document.onset(selected))*Double(document.meter.unit)/1920+1))",
            subtitle: (document.instrument == .piano
                ? (selected.staff == 1 ? "Right hand" : "Left hand") : "Notation ↔ tab") + " · voice \(selected.voice)",
            padding: 16, spacing: 12
        ) {
            HStack(alignment: .center, spacing: 12) {
                Text(selected.label).font(.system(size: 18, weight: .medium, design: .serif)).lineLimit(1)
                Spacer()
                ChoiceMenu(
                    title: "Duration",
                    selection: Binding(
                        get: { selected.rhythm }, set: { rhythm in edit { try $0.setRhythm(selected.id, rhythm) } }),
                    options: rhythms
                ) { $0.label }.frame(width: 185)
                Toggle(
                    "Tie to next",
                    isOn: Binding(
                        get: { selected.tieNext },
                        set: { value in
                            edit { doc in
                                if let index = doc.events.firstIndex(where: { $0.id == selected.id }) {
                                    doc.events[index].tieNext = value
                                }
                            }
                        })
                ).disabled(selected.isRest).help("The next event must have the same notes.")
                Button("Hear", systemImage: "speaker.wave.2") {
                    audio.play(
                        Score(
                            tempo: 100, notes: selected.pitches.map { ScoreNote(midi: $0.midi, start: 0, duration: 1) })
                    )
                }.disabled(selected.isRest)
            }.controlSize(.small)
            expressionControls(selected)
            if let pitch {
                HStack(spacing: 12) {
                    if selected.pitches.count > 1 {
                        Picker("Chord note", selection: Binding(get: { pitch.id }, set: { pitchID = $0 })) {
                            ForEach(selected.pitches) { Text($0.label).tag($0.id) }
                        }.frame(width: 140)
                    }
                    ChoiceMenu(
                        title: "Note letter",
                        selection: Binding(
                            get: { pitch.spelling.letter }, set: { value in setWritten(pitch, letter: value) }),
                        options: Array(0..<7)
                    ) { Pitch.letters[$0] }.frame(width: 92)
                    ChoiceMenu(
                        title: "Accidental",
                        selection: Binding(
                            get: { pitch.spelling.accidental }, set: { value in setWritten(pitch, accidental: value) }),
                        options: Array(-2...2)
                    ) { ["♭♭", "♭", "♮", "♯", "𝄪"][$0 + 2] }.frame(width: 112)
                    Stepper(
                        "Octave \(octave(pitch))",
                        value: Binding(get: { octave(pitch) }, set: { value in setWritten(pitch, octave: value) }),
                        in: 1...8
                    ).fixedSize()
                    Button("− semitone") { shift(-1) }.keyboardShortcut(
                        shortcutsBlocked ? nil : KeyboardShortcut(.downArrow, modifiers: []))
                    Button("+ semitone") { shift(1) }.keyboardShortcut(
                        shortcutsBlocked ? nil : KeyboardShortcut(.upArrow, modifiers: []))
                    Spacer()
                    if selected.pitches.count > 1 {
                        Button("Remove tone") {
                            edit { doc in
                                if let index = doc.events.firstIndex(where: { $0.id == selected.id }) {
                                    doc.events[index].pitches.removeAll { $0.id == pitch.id }
                                    doc.clearInvalidTies()
                                }
                            }
                        }
                    }
                }.controlSize(.small)
                if document.instrument == .guitar {
                    HStack(spacing: 12) {
                        Picker(
                            "String",
                            selection: Binding(
                                get: { pitch.string ?? 0 },
                                set: { string in chooseString(string, pitch: pitch, event: selected) })
                        ) {
                            ForEach((0..<6).reversed(), id: \.self) { string in
                                Text("\(6-string) · \(Pitch.chromatic(document.tuning.pitches[string]+document.capo))")
                                    .tag(string)
                            }
                        }.frame(width: 130)
                        Stepper(
                            "Fret \(pitch.fret ?? 0)",
                            value: Binding(
                                get: { pitch.fret ?? 0 },
                                set: { fret in
                                    edit {
                                        try $0.setFingering(
                                            selected.id, pitchID: pitch.id, string: pitch.string ?? 0, fret: fret)
                                    }
                                }), in: 0...24
                        ).fixedSize()
                        Text(
                            "Changing a string keeps the pitch when possible. Changing a fret changes both tab and notation."
                        ).font(.caption).foregroundStyle(.secondary)
                    }.controlSize(.small)
                }
            } else {
                Text("Choose a letter, piano key or guitar fret to replace this rest with a note.").font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    private var eventMap: some View {
        Card(
            title: "Work on a passage", subtitle: "Copy, transform or practise up to 16 bars at a time", padding: 16,
            spacing: 12
        ) {
            HStack(spacing: 12) {
                ChoiceMenu(title: "From bar", selection: $rangeFrom, options: Array(0..<document.barCount)) {
                    "From \($0+1)"
                }.frame(width: 115).id("from-\(document.barCount)")
                ChoiceMenu(
                    title: "Through bar", selection: $rangeThrough,
                    options: Array(passage.lowerBound...min(document.barCount - 1, passage.lowerBound + 15))
                ) { "Through \($0+1)" }.frame(width: 135).id("through-\(rangeFrom)-\(document.barCount)")
                Button("Focus here") {
                    wholePiece = false
                    rangeFrom = pageStart
                    rangeThrough = pageEnd
                }
                Spacer()
                Button("Copy bars", systemImage: "doc.on.doc") { copyPassage() }
                Menu("Paste", systemImage: "doc.on.clipboard") {
                    Button("Insert before selected bar") { pastePassage(inserting: true) }
                    Button("Replace from selected bar") { pastePassage(inserting: false) }
                }.fixedSize().disabled(copied == nil)
                Menu("Transform", systemImage: "arrow.up.arrow.down") {
                    Button("Up a semitone") { edit { try $0.transpose(passage, semitones: 1) } }
                    Button("Down a semitone") { edit { try $0.transpose(passage, semitones: -1) } }
                    Button("Up an octave") { edit { try $0.transpose(passage, semitones: 12) } }
                    Button("Down an octave") { edit { try $0.transpose(passage, semitones: -12) } }
                    Divider()
                    Button("Clear passage to rests") { edit { try $0.clearBars(passage) } }
                    Button("Delete passage") {
                        edit { try $0.deleteBars(passage) }
                        clampPassage()
                    }.disabled(passage.count == document.barCount)
                }.fixedSize()
            }.controlSize(.small)
            if let copied {
                Text(
                    "Copied \(copied.barCount) \(copied.instrument.rawValue.lowercased()) bars in \(copied.meter.label). Paste includes both hands and creates independent notes."
                ).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(1...document.staffCount, id: \.self) { staff in
                Text(
                    (document.instrument == .piano ? (staff == 1 ? "RIGHT HAND" : "LEFT HAND") : "GUITAR")
                        + " · VOICE \(document.voices(staff:staff).contains(selected?.voice ?? 1) ? selected?.voice ?? 1 : 1)"
                ).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 12) {
                    ForEach(pageStart...pageEnd, id: \.self) { bar in
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                selectBar(bar)
                                wholePiece = false
                                rangeFrom = bar
                                rangeThrough = bar
                            } label: {
                                Text("BAR \(bar+1)")
                            }.buttonStyle(.plain).help("Select this bar as the practice passage").font(
                                .system(size: 9, weight: .semibold)
                            ).tracking(1).foregroundStyle(.secondary)
                            ForEach(
                                document.inBar(
                                    bar, staff: staff,
                                    voice: document.voices(staff: staff).contains(selected?.voice ?? 1)
                                        ? selected?.voice ?? 1 : 1)
                            ) { event in
                                Button {
                                    select(event.id)
                                } label: {
                                    HStack {
                                        Text(
                                            event.isRest
                                                ? "Rest"
                                                : event.pitches.map { $0.spelling.name }.joined(separator: " · ")
                                        ).font(.system(size: 11, weight: .medium))
                                        Spacer()
                                        Text(
                                            String(
                                                format: "%.2g",
                                                Double(event.rhythm.ticks) * Double(document.meter.unit) / 1920)
                                        ).font(.system(size: 10)).foregroundStyle(.secondary)
                                        if event.tieNext { Text("⌒").font(.caption) }
                                    }.padding(.horizontal, 9).padding(.vertical, 5).background(
                                        event.id == selected?.id ? Color.moss.opacity(0.13) : Color.canvas.opacity(0.6),
                                        in: RoundedRectangle(cornerRadius: 6))
                                }.buttonStyle(.plain).accessibilityLabel(
                                    "Bar \(bar+1), \(event.label), \(event.rhythm.label)")
                            }
                        }.frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
            HStack(spacing: 12) {
                Button("Play this bar") { play(bar: selected?.bar) }
                ChoiceMenu(title: "Playback speed", selection: $speed, options: [0.25, 0.5, 0.75, 1.0, 1.25, 1.5]) {
                    "\(Int($0*100))% speed"
                }.frame(width: 112)
                Toggle("Loop", isOn: $loop)
                Toggle("Count-in", isOn: $countIn)
                Toggle("Metronome", isOn: $click)
                Spacer()
            }.controlSize(.small)
        }
    }
    private var inputInstrument: some View {
        Card(
            title: document.instrument == .guitar ? "Enter from the fretboard" : "Enter from the piano",
            subtitle: writing ? "Enter a note, then advance with the chosen duration" : "Changes the selected note",
            padding: 16, spacing: 12
        ) {
            if document.instrument == .guitar {
                HStack {
                    Picker(
                        "Tuning",
                        selection: Binding(
                            get: { document.tuning },
                            set: { tuning in edit { try $0.setGuitar(tuning: tuning, capo: $0.capo) } })
                    ) {
                        ForEach(Tuning.presets, id: \.self) { Text($0.name).tag($0) }
                        if !Tuning.presets.contains(document.tuning) { Text(document.tuning.name).tag(document.tuning) }
                    }.frame(width: 200)
                    Stepper(
                        "Capo \(document.capo)",
                        value: Binding(
                            get: { document.capo },
                            set: { capo in edit { try $0.setGuitar(tuning: $0.tuning, capo: capo) } }), in: 0...9
                    ).fixedSize()
                    Spacer()
                    Text("Sounding pitch · guitar notation is written one octave higher").font(.caption)
                        .foregroundStyle(.secondary)
                }.controlSize(.small)
                // Use exact position buttons so entering a fret also preserves which string was clicked.
                VStack(spacing: 4) {
                    HStack {
                        Text("").frame(width: 36)
                        ForEach(0...12, id: \.self) { fret in
                            Text(fret == 0 ? "Open" : "\(fret)").font(.system(size: 9)).frame(maxWidth: .infinity)
                        }
                    }
                    ForEach((0..<6).reversed(), id: \.self) { string in
                        HStack(spacing: 4) {
                            Text("\(6-string) · \(Pitch.chromatic(document.tuning.pitches[string]+document.capo))")
                                .font(.system(size: 10)).frame(width: 36)
                            ForEach(0...12, id: \.self) { fret in
                                let active =
                                    selected?.pitches.contains { $0.string == string && $0.fret == fret } == true
                                Button("\(fret)") { enterFret(string: string, fret: fret) }.font(.system(size: 10))
                                    .buttonStyle(.plain).frame(maxWidth: .infinity).padding(.vertical, 6).background(
                                        active ? Color.moss.opacity(0.2) : Color.canvas,
                                        in: RoundedRectangle(cornerRadius: 5)
                                    ).accessibilityLabel("Enter string \(6-string), fret \(fret)")
                            }
                        }
                    }
                }
            } else {
                Piano(
                    root: Pitch(0), notes: selected?.pitches.map(\.spelling) ?? [], degrees: [], showDegrees: false,
                    exactNotes: Set(selected?.pitches.map(\.midi) ?? []), play: { midi in enterMidi(midi) },
                    midiRange: 36...83, colorRoots: false)
            }
        }
    }
    private func select(_ id: UUID) {
        titleFocused = false
        selectedID = id
        pitchID = document.events.first { $0.id == id }?.pitches.first?.id
    }
    private func ensureSelection() {
        if !document.events.contains(where: { $0.id == selectedID }) { select(document.events[0].id) }
    }
    private func undoOnce() {
        if let previous = session.undo(document) {
            audio.stop()
            state.editor.replace(previous)
            ensureSelection()
            clampPassage()
        }
    }
    private func redoOnce() {
        if let next = session.redo(document) {
            audio.stop()
            state.editor.replace(next)
            ensureSelection()
            clampPassage()
        }
    }
    private func harmonyChecks() {
        let original = document
        guard var first = document.harmonies.first else { return }
        first.symbol = try! ChordSymbol.parse("A7(#11)")
        edit { try $0.setHarmony(first) }
        EditorDiagnostics.native["harmonyEdit"] = document.harmonies.first?.symbol.label == "A7(♯11)"
        let changed = document
        undoOnce()
        EditorDiagnostics.native["harmonyUndo"] = document == original
        redoOnce()
        EditorDiagnostics.native["harmonyRedo"] = document == changed
        undoOnce()
        edit { try $0.transpose(0...0, semitones: 1) }
        EditorDiagnostics.native["harmonyTranspose"] =
            document.harmonies[0].symbol.root?.pc == 3 && document.harmonies[1].symbol.root?.pc == 8
        undoOnce()
        edit { try $0.paste(original.excerpt(0...0), at: 1, inserting: true) }
        EditorDiagnostics.native["harmonyCopy"] =
            document.harmonies(in: 1).map(\.symbol) == original.harmonies(in: 0).map(\.symbol)
        undoOnce()
        session.reset()
    }
    private func nativeChecks() {
        let original = document
        let first = original.events[0]
        select(first.id)
        edit { try $0.setPitch(first.id, midi: first.pitches[0].midi + 1) }
        let changed = document
        EditorDiagnostics.native["pitchEdit"] = changed.events[0].pitches[0].midi == first.pitches[0].midi + 1
        undoOnce()
        EditorDiagnostics.native["undo"] = document == original
        redoOnce()
        EditorDiagnostics.native["redo"] = document == changed
        undoOnce()
        edit { try $0.setRhythm(first.id, EditorRhythm(240)) }
        EditorDiagnostics.native["rhythmEdit"] = document.events[0].rhythm.ticks == 240 && document.events[1].isRest
        undoOnce()
        EditorDiagnostics.native["rhythmUndo"] = document == original
        if original.instrument == .piano {
            EditorDiagnostics.native["handsIndependent"] =
                changed.events.filter { $0.staff == 2 } == original.events.filter { $0.staff == 2 }
        }
        edit { try $0.insertBars(at: 1, count: 3) }
        EditorDiagnostics.native["insertBars"] =
            document.barCount == original.barCount + 3 && document.inBar(1, staff: 1).allSatisfy(\.isRest)
        undoOnce()
        EditorDiagnostics.native["barUndo"] = document == original
        rangeFrom = 0
        rangeThrough = 1
        copyPassage()
        select(first.id)
        pastePassage(inserting: true)
        EditorDiagnostics.native["passagePaste"] =
            document.barCount == original.barCount + 2 && document.events[0].id != first.id && copied?.barCount == 2
        undoOnce()
        EditorDiagnostics.native["pasteUndo"] = document == original
        do {
            var empty = try EditorDocument.blank(instrument: original.instrument, bars: 1, meter: EditorMeter(6, 8))
            empty.id = original.id
            state.editor.replace(empty)
            select(empty.events[0].id)
            writing = true
            entryRhythm = EditorRhythm(240)
            entryOctave = original.instrument == .guitar ? 3 : 4
            enterLetter(0)
            EditorDiagnostics.native["writeAdvances"] =
                selected?.isRest == true && document.events[0].pitches.first?.spelling.letter == 0
                && document.onset(selected!) == 240
            rest()
            EditorDiagnostics.native["writeRestAdvances"] = document.onset(selected!) == 480
            enterLetter(1)
            enterLetter(2)
            enterLetter(3)
            enterLetter(4)
            EditorDiagnostics.native["writeAddsBar"] = document.barCount == 2 && selected?.bar == 1
            if original.instrument == .piano {
                EditorDiagnostics.native["writingKeepsOtherHand"] = document.events.filter { $0.staff == 2 }.allSatisfy(
                    \.isRest)
            }
            undoOnce()
            EditorDiagnostics.native["writeUndoRemovesAddedBar"] = document.barCount == 1
        } catch { EditorDiagnostics.native["writingChecks"] = false }
        state.editor.replace(original)
        writing = false
        entryRhythm = EditorRhythm()
        rangeFrom = 0
        rangeThrough = min(3, original.barCount - 1)
        copied = nil
        session.reset()
        select(first.id)
    }
    private func polyChecks() {
        let original = document
        guard let lower = document.inBar(0, staff: 1, voice: 2).first, let upper = document.inBar(0, staff: 1).first
        else {
            EditorDiagnostics.native["twoVoices"] = false
            return
        }
        select(lower.id)
        EditorDiagnostics.native["selectLowerVoice"] = selected?.voice == 2
        move(1)
        EditorDiagnostics.native["advanceWithinVoice"] = selected?.voice == 2 && selected?.id != lower.id
        select(upper.id)
        mark(upper.id) {
            $0.staccato.toggle()
            $0.accent.toggle()
            $0.dynamic = .f
            $0.stem = .down
        }
        EditorDiagnostics.native["expressionEdit"] =
            document.events.first { $0.id == upper.id }?.dynamic == .f
            && document.ordered(staff: 1, voice: 2) == original.ordered(staff: 1, voice: 2)
        undoOnce()
        EditorDiagnostics.native["expressionUndo"] = document == original
        redoOnce()
        EditorDiagnostics.native["expressionRedo"] = document.events.first { $0.id == upper.id }?.stem == .down
        undoOnce()
        select(upper.id)
        session.reset()
    }
    @discardableResult private func edit(_ change: (inout EditorDocument) throws -> Void) -> Bool {
        do {
            try apply(change)
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    private func apply(_ change: (inout EditorDocument) throws -> Void) throws {
        let copy = try session.edit(document, change: change)
        audio.stop()
        state.editor.replace(copy)
        ensureSelection()
        clampPassage()
    }
    private func move(_ offset: Int) {
        let staff = selected?.staff ?? 1
        let sequence = document.ordered(staff: staff, voice: selected?.voice ?? 1)
        let index = sequence.firstIndex { $0.id == selected?.id } ?? 0
        select(sequence[min(sequence.count - 1, max(0, index + offset))].id)
    }
    private func octave(_ pitch: EditorPitch) -> Int {
        (pitch.midi - Pitch.naturals[pitch.spelling.letter] - pitch.spelling.accidental) / 12 - 1
    }
    private func setWritten(_ pitch: EditorPitch, letter: Int? = nil, accidental: Int? = nil, octave value: Int? = nil)
    {
        guard let selected else { return }
        let spelling = Pitch(letter ?? pitch.spelling.letter, accidental ?? pitch.spelling.accidental)
        let midi = ((value ?? octave(pitch)) + 1) * 12 + Pitch.naturals[spelling.letter] + spelling.accidental
        edit { try $0.setPitch(selected.id, pitchID: pitch.id, midi: midi, spelling: spelling) }
    }
    private func enterMIDI(_ notes: [Int]) -> Bool {
        guard !scoreInputBlocked, let selected else { return false }
        let before = document
        var next = selected.id
        guard edit({ next = try $0.enterMIDI(notes, eventID: selected.id, rhythm: entryRhythm) }) else { return false }
        select(next)
        if state.isPreview && CommandLine.arguments.contains("--midi-entry-check") {
            let written = document.events.first { $0.id == selected.id }
            MIDIDiagnostics.checks["stepChordEntered"] = written?.pitches.map(\.midi) == notes.sorted()
            MIDIDiagnostics.checks["stepAdvanced"] =
                next != selected.id && self.selected?.voice == selected.voice && self.selected?.staff == selected.staff
            MIDIDiagnostics.checks["otherHandUnchanged"] =
                document.events.filter { $0.staff != selected.staff }
                == before.events.filter { $0.staff != selected.staff }
            undoOnce()
            MIDIDiagnostics.checks["midiUndo"] = document == before
            redoOnce()
            MIDIDiagnostics.checks["midiRedo"] =
                document.events.first { $0.id == selected.id }?.pitches.map(\.midi) == notes.sorted()
            select(next)
        }
        return true
    }
    private func enterLetter(_ letter: Int) {
        guard !scoreInputBlocked, let selected else { return }
        let octave =
            writing
            ? entryOctave
            : pitch.map { octave($0) } ?? (document.instrument == .guitar ? 3 : selected.staff == 2 ? 3 : 4)
        let spelling = Scale.major.notes(keyRoots[document.fifths + 7]).first { $0.letter == letter } ?? Pitch(letter)
        write(midi: (octave + 1) * 12 + Pitch.naturals[letter] + spelling.accidental, spelling: spelling)
    }
    private func enterMidi(_ midi: Int) { write(midi: midi) }
    private func shift(_ value: Int) {
        if let pitch, let selected {
            if edit({ try $0.setPitch(selected.id, pitchID: pitch.id, midi: pitch.midi + value) }) {
                audio.note(pitch.midi + value)
            }
        }
    }
    private func rest() {
        guard let selected else { return }
        if edit({ doc in
            if writing { try doc.setRhythm(selected.id, entryRhythm) }
            if let index = doc.events.firstIndex(where: { $0.id == selected.id }) {
                doc.events[index].pitches = []
                doc.clearInvalidTies()
            }
            try prepareAdvance(&doc, from: selected.id)
        }), writing {
            move(1)
        }
    }
    private func chooseString(_ string: Int, pitch: EditorPitch, event: EditorEvent) {
        let fret = pitch.midi - document.tuning.pitches[string] - document.capo
        guard (0...24).contains(fret) else {
            message = "This pitch is outside that string's range. Choose another string or change the pitch first."
            return
        }
        edit { try $0.setFingering(event.id, pitchID: pitch.id, string: string, fret: fret) }
    }
    private func enterFret(string: Int, fret: Int) {
        write(midi: document.tuning.pitches[string] + document.capo + fret, string: string, fret: fret)
    }
    private func write(midi: Int, spelling: Pitch? = nil, string: Int? = nil, fret: Int? = nil) {
        guard let selected else { return }
        titleFocused = false
        let selectedPitch = pitch?.id
        if edit({ doc in
            if writing { try doc.setRhythm(selected.id, entryRhythm) }
            try doc.setPitch(selected.id, pitchID: selectedPitch, midi: midi, spelling: spelling)
            if let string, let fret,
                let p = doc.events.first(where: { $0.id == selected.id })?.pitches.first(where: {
                    $0.id == selectedPitch
                }) ?? doc.events.first(where: { $0.id == selected.id })?.pitches.first
            {
                try doc.setFingering(selected.id, pitchID: p.id, string: string, fret: fret)
            }
            try prepareAdvance(&doc, from: selected.id)
        }) {
            if writing {
                entryOctave = (midi / 12) - 1
                move(1)
            }
            if !state.isPreview { audio.note(midi) }
        }
    }
    private func prepareAdvance(_ doc: inout EditorDocument, from id: UUID) throws {
        guard writing, let e = doc.events.first(where: { $0.id == id }), doc.nextEvent(e) == nil, doc.barCount < 128
        else { return }
        try doc.insertBars(at: doc.barCount)
    }
    private func selectBar(_ bar: Int) {
        if let e = document.inBar(
            min(document.barCount - 1, max(0, bar)), staff: selected?.staff ?? 1, voice: selected?.voice ?? 1
        ).first {
            select(e.id)
        }
    }
    private func showPage(_ delta: Int) {
        let start = min(document.barCount - 1, max(0, pageStart + delta * 4))
        selectBar(start)
        rangeFrom = start
        rangeThrough = min(document.barCount - 1, start + 3)
    }
    private func clampPassage() {
        rangeFrom = min(rangeFrom, document.barCount - 1)
        rangeThrough = min(document.barCount - 1, max(rangeFrom, min(rangeThrough, rangeFrom + 15)))
    }
    private func insertBar(before: Bool) {
        let bar = (selected?.bar ?? 0) + (before ? 0 : 1)
        if edit({ try $0.insertBars(at: bar) }) { selectBar(bar) }
    }
    private func duplicateBar() {
        guard let bar = selected?.bar else { return }
        do {
            let copy = try document.excerpt(bar...bar)
            if edit({ try $0.paste(copy, at: bar + 1, inserting: true) }) { selectBar(bar + 1) }
        } catch { message = error.localizedDescription }
    }
    private func deleteSelectedBar() {
        guard let bar = selected?.bar else { return }
        if edit({ try $0.deleteBars(bar...bar) }) { selectBar(min(bar, document.barCount - 1)) }
    }
    private func copyPassage() {
        do { copied = try document.excerpt(passage) } catch { message = error.localizedDescription }
    }
    private func pastePassage(inserting: Bool) {
        guard let copied else { return }
        let bar = selected?.bar ?? 0
        if edit({ try $0.paste(copied, at: bar, inserting: inserting) }) {
            rangeFrom = bar
            rangeThrough = min(bar + 15, bar + copied.barCount - 1)
            selectBar(bar)
        }
    }
    private func play(bar: Int? = nil, through: Int? = nil) {
        do {
            var study = MusicStudy(
                document: try StudyImport.read(Data(EditorXML.encode(document).utf8)), filename: "Compose")
            study.from = bar ?? playbackRange.lowerBound
            study.through = through ?? bar ?? playbackRange.upperBound
            study.speed = speed
            study.loop = loop
            study.countIn = countIn
            study.metronome = click
            audio.playStudy(try StudyPlaybackPlan(study: study, wholePiece: wholePiece), loop: loop)
        } catch { message = error.localizedDescription }
    }
    private func addExample(_ value: EditorDocument) {
        guard state.editor.documents.count < 100 else {
            message = "Cadence keeps up to 100 scores."
            return
        }
        state.editor.documents.append(value)
        state.editor.activeID = value.id
    }
    private func blank(_ kind: EditorInstrument) {
        guard state.editor.documents.count < 100 else {
            message = "Cadence keeps up to 100 scores."
            return
        }
        do {
            var doc = try EditorDocument.blank(instrument: kind, meter: document.meter)
            doc.title = "Untitled \(kind.rawValue.lowercased())"
            state.editor.documents.append(doc)
            state.editor.activeID = doc.id
        } catch { message = error.localizedDescription }
    }
    private func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "cadence-score")!, UTType(filenameExtension: "musicxml") ?? .xml, .xml,
            UTType(filenameExtension: "mxl") ?? .data,
        ]
        panel.title = "Open a score"
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= StudyImport.maximumBytes else {
                throw MusicError.invalid("Choose a score smaller than 20 MB.")
            }
            let data = try Data(contentsOf: url)
            var doc =
                url.pathExtension == "cadence-score"
                ? try JSONDecoder().decode(EditorDocument.self, from: data) : try EditorXML.decode(data)
            _ = try doc.validated()
            doc.id = UUID()
            guard state.editor.documents.count < 100 else {
                throw MusicError.invalid("Cadence keeps up to 100 scores.")
            }
            state.editor.documents.append(doc)
            state.editor.activeID = doc.id
            if url.pathExtension != "cadence-score" {
                try state.changePiece("score:" + doc.id.uuidString) { $0.kind = .sheetMusic }
            }
        } catch { message = "Could not open the score: " + error.localizedDescription }
    }
    private func export(_ ext: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.title + "." + ext
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        panel.title = "Export your score"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data
            if ext == "musicxml" {
                data = Data(try EditorXML.encode(document).utf8)
            } else if ext == "mid" {
                data = MIDIFile.encode(
                    document.playback(), endBeat: Double(document.barCount * document.meter.ticks) / 480,
                    program: document.instrument == .guitar ? 24 : 0, minor: document.minor)
            } else {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                data = try encoder.encode(document)
            }
            try data.write(to: url, options: .atomic)
        } catch { message = "Could not export the score: " + error.localizedDescription }
    }
}
