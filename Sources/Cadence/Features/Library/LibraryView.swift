// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import MusicCore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var state: AppState
    @State private var category: PieceKind?
    @State private var query = ""
    @State private var favorites = false
    @State private var order = "Recently opened"
    private var pieces: [LibraryPiece] {
        state.libraryPieces.filter { piece in
            let record = state.pieceRecord(piece)
            return (category == nil || record.kind == category) && (!favorites || record.favorite)
                && (query.isEmpty
                    || (piece.title + " " + record.composer + " " + record.tags + " " + piece.instrument)
                        .localizedCaseInsensitiveContains(query))
        }.sorted { a, b in
            let x = state.pieceRecord(a)
            let y = state.pieceRecord(b)
            if order == "Recently opened", (x.lastOpened ?? x.addedAt) != (y.lastOpened ?? y.addedAt) {
                return (x.lastOpened ?? x.addedAt) > (y.lastOpened ?? y.addedAt)
            }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
    private var selected: LibraryPiece? { pieces.first { $0.id == state.librarySelection } ?? pieces.first }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !state.libraryCourses || state.learningShelf != "Pathways"
                || (state.musicalPathwayStep == nil && !state.showAdaptiveSession)
            {
                Picker("Library", selection: $state.libraryCourses) {
                    Text("Music").tag(false)
                    Text("Courses").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
            }
            if state.libraryCourses { CourseLibraryView() } else { musicWorkspace }
        }
    }
    private var musicWorkspace: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                TextField("Search title, composer, instrument or tag", text: $query).textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 420)
                Spacer()
                Button("Import PDF", systemImage: "doc.viewfinder") {
                    state.pdfImportScoreID = nil
                    state.showPDFImport = true
                }
                Button("MusicXML", systemImage: "square.and.arrow.down") { importXML() }.disabled(state.importingStudy)
                Menu("New composition", systemImage: "plus") {
                    Button("Guitar") { state.newLibraryComposition(.guitar) }
                    Button("Piano") { state.newLibraryComposition(.piano) }
                }.fixedSize()
            }.controlSize(.small)
            HStack {
                Picker("Collection", selection: $category) {
                    Text("All music").tag(Optional<PieceKind>.none)
                    ForEach(PieceKind.allCases, id: \.self) { kind in Text(kind.rawValue).tag(Optional(kind)) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 570)
                Spacer(minLength: 8)
                Toggle("Favorites", isOn: $favorites).toggleStyle(.checkbox).font(.caption)
                Picker("Sort", selection: $order) {
                    Text("Recently opened").tag("Recently opened")
                    Text("Title").tag("Title")
                }.labelsHidden().frame(width: 150)
            }
            if let error = state.libraryStorageError {
                Text(error).font(.caption).foregroundStyle(Color.clay).textSelection(.enabled)
            }
            if let selected {
                HStack(alignment: .top, spacing: 18) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 9) {
                                ForEach(pieces) { piece in row(piece, selected: selected.id == piece.id).id(piece.id) }
                            }
                        }
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                proxy.scrollTo(selected.id, anchor: .center)
                            }
                        }
                        .onChange(of: state.librarySelection) { _, id in
                            if let id { proxy.scrollTo(id, anchor: .center) }
                        }
                    }.frame(width: 255, height: 710)
                    ScrollView {
                        PieceDetailView(piece: selected).id(selected.id).frame(
                            maxWidth: .infinity, alignment: .topLeading
                        ).padding(.trailing, 3)
                    }.frame(maxWidth: .infinity).frame(height: 710)
                }
            } else {
                ContentUnavailableView(
                    query.isEmpty ? "A place for your music" : "No matching pieces", systemImage: "books.vertical",
                    description: Text(
                        query.isEmpty
                            ? "Import sheet music, start a composition, or explore the included examples. Your scores and notes stay on this Mac."
                            : "Try a different title or tag, or change the collection filter.")
                ).frame(minHeight: 400)
            }
            Text("\(pieces.count) pieces · practice copies stay with their parent piece · \(state.storageStatus)").font(
                .caption
            ).foregroundStyle(.secondary)
        }
        .onAppear {
            state.reconcileLibrary()
            state.saveSoon()
        }
        .onChange(of: category) { _, _ in state.librarySelection = nil }
    }
    private func row(_ piece: LibraryPiece, selected: Bool) -> some View {
        let record = state.pieceRecord(piece)
        return Button {
            state.librarySelection = piece.id
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top) {
                    Image(systemName: record.kind == .composition ? "pencil.and.outline" : "music.note.list")
                        .foregroundStyle(Color.moss)
                    Text(piece.title).font(.system(size: 15, weight: .semibold, design: .serif)).lineLimit(3)
                    Spacer(minLength: 0)
                    if record.favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(Color.moss) }
                }
                Text(record.composer.isEmpty ? piece.instrument : record.composer + " · " + piece.instrument).font(
                    .caption
                ).foregroundStyle(.secondary).lineLimit(2)
                HStack {
                    Text(record.stage.rawValue)
                    Spacer()
                    Text("\(piece.bars) bars")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                Text(record.kind.rawValue + " · " + piece.sourceLabel).font(.system(size: 10)).foregroundStyle(
                    .secondary
                ).lineLimit(2)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(
                selected ? Color.moss.opacity(0.10) : Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12)
            ).overlay(
                RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.moss.opacity(0.5) : Color.line, lineWidth: 1)
            )
        }.buttonStyle(.plain)
    }
    private func importXML() {
        let panel = NSOpenPanel()
        panel.title = "Add sheet music"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "musicxml"), UTType(filenameExtension: "mxl"), .xml]
            .compactMap { $0 }
        panel.begin { response in if response == .OK, let url = panel.url { state.importStudy(url) } }
    }
}

private struct PieceDetailView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var ai: AISettings
    @Environment(\.openSettings) private var openSettings
    let piece: LibraryPiece
    @StateObject private var coach = PieceCoachSession()
    @State private var tab = "Overview"
    @State private var from = 1
    @State private var through = 4
    @State private var partID = ""
    @State private var prompt = ""
    @State private var includeProfile = false
    @State private var analysisID: UUID?
    @State private var height: CGFloat = 220
    @State private var renderError: String?
    @State private var metrics = ""
    private var record: PieceRecord { state.pieceRecord(piece) }
    private var study: MusicStudy? {
        if case .study(let study) = piece.source { return study }
        return nil
    }
    private var barCount: Int { study?.document.parts.first { $0.id == partID }?.measures.count ?? piece.bars }
    private var snapshot: PieceSnapshot? {
        try? PieceSnapshot(piece: piece, from: from - 1, through: through - 1, partID: partID.isEmpty ? nil : partID)
    }
    private var analysis: SavedPieceAnalysis? { record.analyses.first { $0.id == analysisID } ?? record.analyses.last }
    private var canSend: Bool {
        !state.isPreview && !coach.busy && coach.pending == nil && ai.isReady && snapshot != nil
            && state.libraryStorageError == nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Picker("Piece notebook", selection: $tab) {
                Text("Overview").tag("Overview")
                Text("Score analysis").tag("Score analysis")
                Text("AI analysis").tag("Analysis")
                Text("Coach").tag("Coach")
                Text("Learn").tag("Learn")
            }.pickerStyle(.segmented).labelsHidden()
            if tab == "Overview" {
                overview
                if let error = coach.error { Text(error).font(.caption).foregroundStyle(Color.clay) }
            } else if tab == "Score analysis" {
                scopeControls
                ScoreAnalysisPanel(
                    piece: piece,
                    scope: .init(
                        partID: partID.isEmpty ? (study?.partID ?? "P1") : partID, staff: 1, from: from - 1,
                        through: through - 1)
                ).id(piece.id + piece.fingerprint + partID)
            } else if tab == "Learn" {
                scopeControls
                TriadLibraryButton(
                    piece: piece, from: from - 1, through: through - 1, partID: partID.isEmpty ? nil : partID)
                PieceLearningView(piece: piece, snapshot: snapshot)
            } else {
                scopeControls
                if tab == "Analysis" { analysisView } else { conversation }
                if coach.busy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Thinking about these bars…").font(.caption)
                        Spacer()
                        Button("Stop") { coach.cancel() }
                    }
                    if let start = coach.started {
                        TimelineView(.periodic(from: start, by: 1)) { value in
                            Text("\(max(0,Int(value.date.timeIntervalSince(start)))) seconds · four-minute limit").font(
                                .caption.monospacedDigit()
                            ).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error = coach.error {
                    Text(error).font(.caption).foregroundStyle(Color.clay).textSelection(.enabled)
                }
                if coach.pending != nil {
                    Button("Save received reply again") { coach.save(state: state) }
                    Text("This saves the reply already received; it does not contact the model again.").font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(
                    "Uses your Settings model and OpenRouter credits with ZDR required. Sends the selected symbolic notes, this piece's goal and notes, and relevant recent conversation. Original PDFs and audio stay on this Mac. Requests start only when you choose them."
                ).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            through = min(4, barCount)
            if let study { partID = study.partID }
            if state.libraryLearning {
                tab = "Learn"
                state.libraryLearning = false
            }
            ai.checkKeyIfNeeded()
            if state.isPreview && CommandLine.arguments.contains("--library-analysis") { tab = "Analysis" }
            if state.isPreview && CommandLine.arguments.contains("--library-coach") { tab = "Coach" }
        }
        .onDisappear { coach.cancel() }
        .onChange(of: from) { _, value in through = max(value, min(through, min(barCount, value + 15))) }
        .onChange(of: partID) { _, _ in
            from = 1
            through = min(4, barCount)
        }
        .onChange(of: record.analyses.last?.id) { _, _ in analysisID = record.analyses.last?.id }
        .onChange(of: record.conversation.last?.id) { _, _ in prompt = "" }
        .onChange(of: prompt) { _, value in if value.count > 2500 { prompt = String(value.prefix(2500)) } }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(piece.title).font(.system(size: 26, weight: .medium, design: .serif))
                    Text(
                        [record.composer, piece.instrument, piece.sourceLabel].filter { !$0.isEmpty }.joined(
                            separator: " · ")
                    ).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    change { $0.favorite.toggle() }
                } label: {
                    Image(systemName: record.favorite ? "star.fill" : "star")
                }.buttonStyle(.plain).foregroundStyle(Color.moss).accessibilityLabel(
                    record.favorite ? "Remove favorite" : "Favorite piece"
                ).disabled(state.libraryStorageError != nil)
            }
            HStack {
                Button(study == nil ? "Open notation" : "Open study", systemImage: "music.note.list") {
                    state.openLibraryPiece(piece)
                }.buttonStyle(.cadencePrimary)
                Button("Practise this piece", systemImage: "play.circle") { state.openPieceRehearsal(piece) }
                FollowChangesButton(
                    piece: piece, from: from - 1, through: through - 1, partID: partID.isEmpty ? nil : partID)
                Menu {
                    if case .score(let score) = piece.source {
                        Button("Make my own composition copy") { state.copyLibraryComposition(piece) }
                        if let source = score.pdfSource {
                            Button("Pages & retries") {
                                state.pdfImportScoreID = score.id
                                state.showPDFImport = true
                            }
                            if let url = state.sourcePDFURL(source) {
                                Button("Open original PDF") { NSWorkspace.shared.open(url) }
                            }
                        }
                    }
                    Button("AI settings") { openSettings() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Piece options")
                Spacer(minLength: 0)
            }.controlSize(.small).disabled(coach.busy)
        }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Open the whole piece, then choose a passage when you want to focus.").font(.caption).foregroundStyle(
                .secondary)
            if case .score(let score) = piece.source, let link = score.responseSource {
                Card(title: "Your musical answer", subtitle: link.material.label, padding: 16, spacing: 10) {
                    Text("Inspired by “\(link.material.title)”").font(.callout)
                    Text(
                        link.isFinished(score)
                            ? "Finished · you’ve heard this version" : "Draft · ready to keep writing"
                    ).font(.caption).foregroundStyle(Color.moss)
                    if let original = state.libraryPieces.first(where: { $0.id == link.material.pieceID }) {
                        Button("Open original piece", systemImage: "arrow.up.right") {
                            state.openLibraryPiece(original)
                        }
                    } else {
                        Text("The original is unavailable. Its passage reference is kept with your composition.").font(
                            .caption
                        ).foregroundStyle(.secondary)
                    }
                }
            }
            if case .score(let score) = piece.source, let source = score.reharmSource {
                ReharmAnswerBar(source: source)
            }
            ForEach(state.reharmPractice.sessions.filter { $0.source.pieceID == piece.id }) { session in
                Button("Continue jazz study · " + session.instrument.rawValue) {
                    do { try state.resumeReharm(session.id) } catch { state.message = error.localizedDescription }
                }
            }
            let reharmAnswers = state.editor.documents.filter { $0.reharmSource?.pieceID == piece.id }
            ForEach(reharmAnswers, id: \.id) { answer in
                Button("Open reharmonisation: " + answer.title) { state.returnToCompose(answer.id) }
            }
            if case .score(let score) = piece.source, let source = score.tensionSource {
                TensionAnswerBar(source: source, instrument: score.instrument)
            }
            let tensionAnswers = state.editor.documents.filter { $0.tensionSource?.pieceID == piece.id }
            ForEach(tensionAnswers, id: \.id) { answer in
                Button("Open alternative ending: " + answer.title) { state.returnToCompose(answer.id) }
            }
            if case .score(let score) = piece.source, let source = score.triadSource {
                TriadAnswerBar(material: source)
            }
            let guitarAnswers = state.editor.documents.filter { $0.triadSource?.pieceID == piece.id }
            if !guitarAnswers.isEmpty {
                Card(title: "My guitar answers", padding: 16) {
                    ForEach(guitarAnswers, id: \.id) { answer in
                        Button(answer.title, systemImage: "guitars") {
                            state.openLibraryPiece(.init(source: .score(answer)))
                        }
                    }
                }
            }
            let answers = state.editor.documents.filter { $0.responseSource?.material.pieceID == piece.id }
            if !answers.isEmpty {
                Card(title: "My musical answers", padding: 16, spacing: 10) {
                    ForEach(answers, id: \.id) { answer in
                        Button(answer.title, systemImage: "music.note") {
                            state.openLibraryPiece(.init(source: .score(answer)))
                        }.buttonStyle(.plain).foregroundStyle(Color.moss)
                    }
                }
            }
            Card(title: "Your connection to this piece", padding: 16, spacing: 12) {
                HStack {
                    Picker("Collection", selection: binding(\.kind)) {
                        ForEach(PieceKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Stage", selection: binding(\.stage)) {
                        ForEach(PieceStage.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }.controlSize(.small)
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Composer / artist").font(.caption).foregroundStyle(.secondary)
                        TextField("Optional credit", text: textBinding(\.composer, limit: 160)).textFieldStyle(
                            .roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Tags").font(.caption).foregroundStyle(.secondary)
                        TextField("Jazz, fingerstyle, harmony…", text: textBinding(\.tags, limit: 250)).textFieldStyle(
                            .roundedBorder)
                    }
                }
                Text("What would you like to learn?").font(.callout).fontWeight(.medium)
                TextField(
                    "A flowing left hand, relaxed chord changes, understand the harmony…",
                    text: textBinding(\.goal, limit: 1500), axis: .vertical
                ).lineLimit(2...4).textFieldStyle(.roundedBorder)
                Text("Your notes").font(.caption).foregroundStyle(.secondary)
                TextField("Your notes about this piece", text: textBinding(\.notes, limit: 5000), axis: .vertical)
                    .lineLimit(3...5).textFieldStyle(.roundedBorder)
                Text("Stage is your own reflection. It is never an automatic mastery score.").font(.caption)
                    .foregroundStyle(.secondary)
            }.disabled(state.libraryStorageError != nil)
            if case .score(let score) = piece.source {
                if let source = score.pdfSource {
                    let total = source.pages?.count ?? 1
                    let reviewed = source.pages?.filter(\.reviewed).count ?? (source.reviewed ? 1 : 0)
                    Text(
                        "Original: \(source.filename) · \(reviewed)/\(total) pages reviewed. "
                            + (source.importedPageCount < total
                                ? "Some pages are still missing; open Pages & retries to continue."
                                : "Review the draft against the original before relying on its analysis.")
                    ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if score.pdfSource?.pages == nil || (score.pdfSource?.importedPageCount ?? 0) > 0 {
                    EditorRenderer(
                        document: score, engine: "OpenSheetMusicDisplay", from: 0, through: min(1, score.barCount - 1),
                        selection: nil, playhead: nil, select: { _ in state.openLibraryPiece(piece) }, height: $height,
                        error: $renderError, metrics: $metrics
                    ).frame(height: max(180, height)).background(.white, in: RoundedRectangle(cornerRadius: 12))
                    if let renderError { Text(renderError).font(.caption).foregroundStyle(Color.clay) }
                }
            }
            practiceCopies
        }
    }
    private var scopeControls: some View {
        Card(title: tab == "Learn" ? "Your passage" : "Music to include", padding: 16, spacing: 11) {
            passageControls
            Text(
                "Bars \(from)–\(through) of \(barCount), using score positions rather than printed bar numbers. Up to 16 bars per request. "
                    + (snapshot?.truncated == true
                        ? "This passage is dense: only its first 160 note/rest events are included. Choose fewer bars for complete coverage."
                        : "Notation and tab describe the same sounding notes.")
            ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if snapshot == nil {
                Text("No analysable music in this selection yet. Finish importing a page or choose another passage.")
                    .font(.caption).foregroundStyle(Color.clay).fixedSize(horizontal: false, vertical: true)
            }
            if tab != "Learn" {
                Toggle("Include my learner profile", isOn: $includeProfile).toggleStyle(.checkbox).font(.caption)
            }
            if tab == "Learn" {
                Text("Ear training uses 1–4 bars and needs no AI key. Learning plans can use up to 16 bars.").font(
                    .caption
                ).foregroundStyle(.secondary)
            } else {
                Text(ai.isReady ? "Model: " + ai.modelName : "Choose a model and add your key in Settings → AI coach.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(coach.busy)
    }
    private var passageControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let study, study.document.parts.count > 1 {
                Picker("Part", selection: $partID) { ForEach(study.document.parts) { Text($0.name).tag($0.id) } }
            }
            HStack {
                Stepper("From bar \(from)", value: $from, in: 1...max(1, barCount))
                Stepper("Through \(through)", value: $through, in: from...max(from, min(barCount, from + 15)))
            }.font(.callout)
        }
    }
    private var analysisView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("A closer look").font(.system(size: 20, weight: .medium, design: .serif))
                Spacer()
                Button(record.analyses.isEmpty ? "Analyse these bars" : "New analysis", systemImage: "sparkles") {
                    analyse()
                }.buttonStyle(.cadencePrimary).disabled(!canSend)
            }
            if record.analyses.count > 1 {
                Picker("Saved analysis", selection: Binding(get: { analysis?.id }, set: { analysisID = $0 })) {
                    ForEach(record.analyses.reversed()) { item in
                        Text(
                            "\(item.date.formatted(date:.abbreviated,time:.shortened)) · bars \(item.scope.fromBar)–\(item.scope.throughBar)"
                        ).tag(Optional(item.id))
                    }
                }
            }
            if let analysis {
                let stale = analysis.fingerprint != piece.fingerprint
                Text("\(analysis.scope.label) · \(analysis.date.formatted(date:.abbreviated,time:.shortened))").font(
                    .caption
                ).foregroundStyle(.secondary)
                if stale {
                    Text(
                        "The score has changed since this analysis. Keep it as a reference or generate a new one. Its old bar links are disabled."
                    ).font(.callout).foregroundStyle(Color.clay).fixedSize(horizontal: false, vertical: true)
                }
                if !analysis.goal.isEmpty {
                    Text("Goal at the time: " + analysis.goal).font(.caption).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
                }
                Text(analysis.outline.summary).font(.body).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                ForEach(Array(analysis.outline.observations.enumerated()), id: \.offset) { _, item in
                    Card(title: item.title, padding: 15, spacing: 9) {
                        Text(item.detail).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(
                            .enabled)
                        Button("Open bars \(item.fromBar)–\(item.throughBar)") {
                            open(from: item.fromBar, through: item.throughBar, partID: analysis.scope.partID)
                        }.controlSize(.small).disabled(stale)
                    }
                }
                Text("Ways to practise").font(.system(size: 19, weight: .medium, design: .serif))
                ForEach(Array(analysis.outline.practice.enumerated()), id: \.offset) { index, item in
                    Card(title: "\(index+1). " + item.title, padding: 15, spacing: 9) {
                        Text(item.instructions).font(.callout).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Text("Listen for: " + item.readyWhen).font(.caption).foregroundStyle(.secondary).fixedSize(
                            horizontal: false, vertical: true)
                        Button("Practise bars \(item.fromBar)–\(item.throughBar)", systemImage: "play.circle") {
                            open(
                                from: item.fromBar, through: item.throughBar, partID: analysis.scope.partID,
                                practise: true)
                        }.controlSize(.small).disabled(stale)
                    }
                }
                ForEach(Array(analysis.outline.caveats.enumerated()), id: \.offset) { _, text in
                    Text("• " + text).font(.caption).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
                }
                Text("Saved with " + analysis.model + " · AI interpretation for your review").font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(
                    "Explore the harmony, rhythm and techniques in this passage, then get small practice steps linked to its bars. Your goal and notes help tailor the advice."
                ).foregroundStyle(.secondary).padding(.vertical, 18)
            }
        }
    }
    private var conversation: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Coach for this piece").font(.system(size: 20, weight: .medium, design: .serif))
            HStack {
                Button("Technique") {
                    prompt = "Break down the main technique in these bars into small practice steps."
                }
                Button("Harmony") {
                    prompt =
                        "Help me understand the harmony of these bars, distinguishing what is certain from what is an interpretation."
                }
                Button("My goal") { prompt = "How can these bars help me work towards my goal for this piece?" }
            }.controlSize(.small)
            ForEach(record.conversation) { line in
                VStack(alignment: .leading, spacing: 9) {
                    Text(line.scope.label + (line.fingerprint != piece.fingerprint ? " · earlier score version" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(line.question).font(.callout).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text(.init(line.answer)).font(.callout).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(
                    Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
            }
            TextField("Ask about this passage, style, technique or your next step…", text: $prompt, axis: .vertical)
                .lineLimit(3...6).textFieldStyle(.roundedBorder).disabled(coach.busy)
            HStack {
                Text("Saved with this piece").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Ask coach", systemImage: "arrow.up") { ask() }.buttonStyle(.cadencePrimary).disabled(
                    !canSend || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
    @ViewBuilder private var practiceCopies: some View {
        if case .score(let score) = piece.source {
            let copies = state.studies.studies.filter { $0.sourceEditor?.scoreID == score.id }.sorted {
                $0.importedAt > $1.importedAt
            }
            if !copies.isEmpty {
                Card(title: "Saved practice copies", padding: 16, spacing: 10) {
                    ForEach(copies) { study in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(study.passageLabel).font(.callout)
                                Text(study.importedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Resume") { state.openStudy(study.reference) }.controlSize(.small)
                        }
                    }
                    Text(
                        "Practice copies preserve the music as it was when saved. Open notation to work on the current score."
                    ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    private func binding<T>(_ path: WritableKeyPath<PieceRecord, T>) -> Binding<T> {
        Binding(get: { record[keyPath: path] }, set: { value in change { $0[keyPath: path] = value } })
    }
    private func textBinding(_ path: WritableKeyPath<PieceRecord, String>, limit: Int) -> Binding<String> {
        Binding(
            get: { record[keyPath: path] }, set: { value in change { $0[keyPath: path] = String(value.prefix(limit)) } }
        )
    }
    private func change(_ action: (inout PieceRecord) -> Void) {
        do { try state.changePiece(piece.id, action) } catch { coach.error = error.localizedDescription }
    }
    private func open(from: Int, through: Int, partID: String? = nil, practise: Bool = false) {
        state.openLibraryPiece(
            piece, from: from - 1, through: through - 1, partID: partID ?? (self.partID.isEmpty ? nil : self.partID),
            practise: practise)
    }
    private var profile: String {
        includeProfile
            ? LearningBrief(
                profile: state.learning.profile, target: record.goal.isEmpty ? "Learn this piece" : record.goal
            ).context : "Learner profile not included."
    }
    private func analyse() {
        guard canSend, let snapshot else { return }
        do {
            let key = try ai.requestKey()
            let model = ai.model
            let record = record
            let profile = profile
            coach.run(state: state, pieceID: piece.id) {
                .analysis(
                    try await PieceCoach().analyse(
                        snapshot: snapshot, record: record, profile: profile, apiKey: key, model: model))
            }
        } catch { coach.error = error.localizedDescription }
    }
    private func ask() {
        guard canSend, let snapshot else { return }
        do {
            let key = try ai.requestKey()
            let model = ai.model
            let record = record
            let profile = profile
            let question = prompt
            coach.run(state: state, pieceID: piece.id) {
                .exchange(
                    try await PieceCoach().ask(
                        question, snapshot: snapshot, record: record, profile: profile, apiKey: key, model: model))
            }
        } catch { coach.error = error.localizedDescription }
    }
}
