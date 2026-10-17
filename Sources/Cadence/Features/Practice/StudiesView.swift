// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import MusicCore
import SwiftUI
import UniformTypeIdentifiers

struct StudiesView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var audio: AudioPlayer
    @State private var removing = false
    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                if let study = state.studies.active {
                    ChoiceMenu(
                        title: "Saved study",
                        selection: Binding(
                            get: { state.studies.active?.id },
                            set: {
                                audio.stop()
                                state.studies.activeID = $0
                            }), options: state.studies.studies.map { Optional($0.id) },
                        label: { id in
                            state.studies.studies.first { $0.id == id }.map {
                                $0.document.title
                                    + ($0.sourceEditor == nil
                                        ? "" : " · " + $0.importedAt.formatted(date: .abbreviated, time: .shortened))
                            } ?? "Choose a study"
                        }
                    ).frame(maxWidth: 420)
                    Menu {
                        Button("Try the example") {
                            audio.stop()
                            state.addExampleStudy()
                        }
                        Button("Remove study…", role: .destructive) { removing = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(
                        "Study options")
                    Text(study.filename).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Library", systemImage: "books.vertical") {
                    if let study = state.studies.active {
                        state.showLibraryPiece(
                            study.sourceEditor.map { "score:" + $0.scoreID.uuidString } ?? "study:"
                                + study.id.uuidString)
                    } else {
                        state.destination = .library
                    }
                }
                Button("Import PDF", systemImage: "doc.viewfinder") {
                    state.pdfImportScoreID = nil
                    state.showPDFImport = true
                }
                if state.importingStudy { ProgressView().controlSize(.small) }
                Button("Import MusicXML", systemImage: "square.and.arrow.down") { importScore() }.disabled(
                    state.importingStudy)
            }
            if state.pathwaySession?.studyID != nil { PathwayPassageReviewView() }
            if let study = state.studies.active {
                StudyWorkspace(study: study, audio: audio).id(study.id)
            } else {
                Card(title: "A place for the music you want to play", padding: 28, spacing: 18) {
                    Image(systemName: "music.note.list").font(.system(size: 36)).foregroundStyle(Color.moss)
                    Text("Bring in a score, find a small passage, and spend some time with it.").font(
                        .system(size: 25, weight: .medium, design: .serif))
                    Text(
                        "Import a partwise MusicXML file (.musicxml, .xml, or .mxl). Read the notation, explore guitar fingerings, slow down a passage, and loop it with a count-in. Your scores stay on this Mac."
                    ).font(.system(size: 14)).foregroundStyle(.secondary).frame(maxWidth: 650, alignment: .leading)
                    HStack {
                        Button("Try a four-bar example", systemImage: "play.circle") { state.addExampleStudy() }
                            .buttonStyle(.cadencePrimary)
                        Text("An original two-voice guitar study in C.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(
                        "Import PDF creates an AI draft in Compose with the original beside it. Review and correct it, then choose Practise passage. You can also import MusicXML or write your own music in Compose."
                    ).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog(
            "Remove this study and its practice notes?", isPresented: $removing, titleVisibility: .visible
        ) {
            Button("Remove study", role: .destructive) {
                guard let id = state.studies.active?.id else { return }
                audio.stop()
                state.studies.studies.removeAll { $0.id == id }
                state.studies.activeID = state.studies.studies.first?.id
                state.save()
            }
        } message: {
            Text("Linked pathways keep their saved passage reference.")
        }
    }
    private func importScore() {
        let panel = NSOpenPanel()
        panel.title = "Choose a MusicXML score"
        panel.prompt = "Import"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowsOtherFileTypes = true
        panel.allowedContentTypes = [UTType(filenameExtension: "musicxml"), UTType(filenameExtension: "mxl"), .xml]
            .compactMap { $0 }
        panel.begin { response in if response == .OK, let url = panel.url { state.importStudy(url) } }
    }
}

struct StudyWorkspace: View {
    @EnvironmentObject private var state: AppState
    var study: MusicStudy
    @ObservedObject var audio: AudioPlayer
    @State private var scoreHeight: CGFloat = 200
    @State private var renderError: String?
    @State private var instrument = 0
    @State private var selectedID: UUID?
    @State private var mode = 0
    private var fullView: Bool { state.studyWholePiece && mode == 0 }
    private var displayedStudy: MusicStudy {
        var copy = study
        if fullView {
            copy.from = 0
            copy.through = copy.part.measures.count - 1
        }
        return copy
    }
    private var fingered: [ScoreNote] {
        Score(notes: study.selectedNotes).fingered(tuning: state.tuning, capo: state.capo).notes
    }
    private var head: StudyPlayhead? {
        audio.studyPlayhead
            ?? fingered.first { $0.id == selectedID }.map {
                StudyPlayhead(sourceBeat: max(study.start, $0.start), isCountIn: false, countInRemaining: 0, cycle: 0)
            }
    }
    private var active: [ScoreNote] {
        let notes = fingered
        if let head, !head.isCountIn {
            return notes.filter {
                $0.start <= head.sourceBeat + 0.00001 && $0.start + $0.duration > head.sourceBeat + 0.00001
            }
        }
        let start = notes.map(\.start).min() ?? study.start
        return notes.filter { abs($0.start - start) < 0.0001 }
    }
    private var playbackKey: String {
        "\(study.partID):\(study.staff ?? 0):\(study.from):\(study.through):\(study.speed):\(study.loop):\(study.countIn):\(study.metronome)"
    }
    var body: some View {
        VStack(spacing: 18) {
            controls
            if mode == 3 {
                Card(title: "", padding: 18) {
                    TimedPracticeView(study: study, midi: state.midi, session: state.timedSession)
                }
            } else if mode == 2 {
                GuidedPracticeView(study: study, midi: state.midi, audio: audio)
            } else {
                PassageTempoView(study: study)
                Card(
                    title: fullView ? "The whole piece" : "The passage",
                    subtitle: "\(study.part.name) · \(displayedStudy.passageLabel)", padding: 18, spacing: 10
                ) {
                    if let renderError {
                        Label(renderError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(
                            Color.clay
                        ).textSelection(.enabled)
                    }
                    ScoreRenderer(study: displayedStudy, playhead: head, height: $scoreHeight, error: $renderError)
                        .frame(height: min(600, scoreHeight)).background(.white).clipShape(
                            RoundedRectangle(cornerRadius: 8))
                    Text("Original notation · sounding pitches are used for playback and the instruments below.").font(
                        .system(size: 10)
                    ).foregroundStyle(.secondary)
                }
                if !fullView {
                    if mode == 1 {
                        PassageSingingView(
                            study: study, audio: audio, microphone: state.microphone, locate: { selectedID = $0 }
                        ).id(study.id).id("passage-singing")
                    } else {
                        if instrument == 0 { tabCard }
                        instrumentCard.id("study-instrument")
                    }
                }
            }
            coachCard.id("study-learning")
            Card(title: "Practice notes", subtitle: "Saved with this study", padding: 18, spacing: 12) {
                TextField(
                    "What are you listening for? What needs another slow pass?", text: binding(\.notes), axis: .vertical
                ).lineLimit(3...5).textFieldStyle(.roundedBorder)
            }
            DisclosureGroup("Playback details") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "Plays the selected part and staves at a steady practice tempo, in written bar order. Ties sustain; basic dynamics, accents, staccato and slur legato shape playback. Repeats, endings, grace notes, ornaments, pedal and tempo changes are displayed but are not performed. Up to five minutes of audio. Focused practice uses up to 16 bars; Whole piece displays and plays the complete selected part."
                    )
                    ForEach(study.document.notices, id: \.self) { Text("• " + $0) }
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 8).frame(
                    maxWidth: .infinity, alignment: .leading)
            }.font(.caption)
        }
        .onChange(of: state.studyWholePiece) { _, value in
            if value { mode = 0 }
            audio.stop()
        }
        .onChange(of: playbackKey) { _, _ in
            audio.stop()
            state.microphone.stop()
            selectedID = nil
        }
        .onChange(of: state.tuning) { _, _ in
            audio.stop()
            selectedID = nil
        }
        .onChange(of: state.capo) { _, _ in
            audio.stop()
            selectedID = nil
        }
        .onChange(of: state.guidedStudyID) { _, id in if id == study.id { mode = 2 } }
        .onChange(of: state.timedStudyID) { _, id in if id == study.id { mode = 3 } }
        .onChange(of: mode) { _, _ in
            if mode != 0 { state.studyWholePiece = false }
            audio.stop()
            state.microphone.stop()
            selectedID = nil
        }
        .onAppear {
            if state.isPreview && CommandLine.arguments.contains("--passage-sing") { mode = 1 }
            if state.guidedStudyID == study.id
                || (state.isPreview && CommandLine.arguments.contains("--guided-practice-check"))
            {
                mode = 2
            }
            if state.timedStudyID == study.id
                || (state.isPreview && CommandLine.arguments.contains("--timed-practice-check"))
            {
                mode = 3
            }
            if study.sourceEditor?.instrument == .piano { instrument = 1 }
            if state.isPreview && CommandLine.arguments.contains("--practice-check") { nativeChecks() }
        }
        .onDisappear {
            audio.stop()
            state.microphone.stop()
        }
    }
    private var controls: some View {
        Card(title: "", padding: 18, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(study.document.title).font(.system(size: 25, weight: .medium, design: .serif)).textSelection(
                        .enabled)
                    Text(study.document.composer.isEmpty ? "Your music, at your pace." : study.document.composer).font(
                        .caption
                    ).foregroundStyle(.secondary)
                }
                Spacer()
                ChoiceMenu(
                    title: "Part",
                    selection: Binding(get: { study.partID }, set: { value in edit { $0.selectPart(value) } }),
                    options: study.document.parts.map(\.id),
                    label: { id in study.document.parts.first { $0.id == id }?.name ?? id }
                ).frame(width: 180)
            }
            if let source = study.sourceEditor {
                HStack {
                    Label("Saved practice copy · source edits stay in Compose", systemImage: "doc.on.doc").font(
                        .caption
                    ).foregroundStyle(.secondary)
                    Spacer()
                    Button("Back to Compose", systemImage: "arrow.up.left") {
                        state.returnToCompose(source.scoreID, from: study.from, through: study.through)
                    }.controlSize(.small)
                }
            }
            HStack(spacing: 12) {
                Button("Practise this piece", systemImage: "play.circle") {
                    let id =
                        study.sourceEditor.map { "score:" + $0.scoreID.uuidString } ?? "study:" + study.id.uuidString
                    if let piece = state.libraryPieces.first(where: { $0.id == id }) { state.openPieceRehearsal(piece) }
                }.controlSize(.small)
                Picker("View", selection: $state.studyWholePiece) {
                    Text("Whole piece").tag(true)
                    Text("Passage").tag(false)
                }.pickerStyle(.segmented).frame(width: 220)
                if !fullView {
                    Text("From bar").font(.caption).foregroundStyle(.secondary)
                    ChoiceMenu(
                        title: "First bar",
                        selection: Binding(
                            get: { study.from },
                            set: { value in edit { $0.select(from: value, through: max(value, study.through)) } }),
                        options: Array(study.part.measures.indices), label: { study.part.measures[$0].label }
                    ).frame(width: 80)
                    Text("through").font(.caption).foregroundStyle(.secondary)
                    ChoiceMenu(
                        title: "Last bar",
                        selection: Binding(
                            get: { study.through },
                            set: { value in edit { $0.select(from: study.from, through: value) } }),
                        options: Array(study.from...min(study.from + 15, study.part.measures.count - 1)),
                        label: { study.part.measures[$0].label }
                    ).frame(width: 80)
                }
                Spacer()
                if study.part.staves.count > 1 {
                    ChoiceMenu(
                        title: "Playback staves", selection: binding(\.staff),
                        options: [nil]
                            + study.part.staves.filter { !study.part.tabStaves.contains($0) }.map { Optional($0) },
                        label: { staff in
                            if study.sourceEditor?.instrument == .piano {
                                return staff == 1 ? "Right hand" : staff == 2 ? "Left hand" : "Both hands"
                            }
                            return staff.map { "Staff \($0)" } ?? "Notation staves"
                        }
                    ).frame(width: 155)
                }
                Text(
                    mode == 3
                        ? "\(String(format:"%.3g",study.document.tempo)) bpm in score"
                        : "\(String(format:"%.3g",study.document.tempo*study.speed)) bpm"
                ).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack {
                Picker("Practice mode", selection: $mode) {
                    Text("Listen & explore").tag(0)
                    Text("Sing with solfège").tag(1)
                    Text("Wait for me").tag(2)
                    Text("Play in time").tag(3)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 550)
                FollowChangesButton(
                    piece: LibraryPiece(source: .study(study)), from: study.from, through: study.through,
                    partID: study.partID
                ).controlSize(.small)
                Spacer()
                Text(
                    mode == 3
                        ? "Keep going. Find your pulse."
                        : mode == 2
                            ? "The notation waits for you."
                            : mode == 1
                                ? "A small phrase. One steady note at a time."
                                : "Find a comfortable tempo, then build from there."
                ).font(.caption).foregroundStyle(.secondary)
            }
            if mode < 2 {
                Divider()
                HStack(spacing: 16) {
                    Button(
                        audio.isPlaying || audio.isPreparing ? "Stop" : fullView ? "Play piece" : "Play passage",
                        systemImage: audio.isPlaying || audio.isPreparing ? "stop.fill" : "play.fill"
                    ) { play() }.buttonStyle(.cadencePrimary).keyboardShortcut(.space, modifiers: [])
                    if audio.isPreparing { ProgressView().controlSize(.small) }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Speed")
                            Spacer()
                            Text("\(Int(study.speed*100))%").monospacedDigit()
                        }.font(.caption)
                        Slider(value: binding(\.speed), in: 0.25...1.5).accessibilityLabel("Playback speed")
                    }.frame(width: 160)
                    Toggle("Loop", isOn: binding(\.loop)).toggleStyle(.checkbox)
                    Toggle("Count-in", isOn: binding(\.countIn)).toggleStyle(.checkbox)
                    Toggle("Metronome", isOn: binding(\.metronome)).toggleStyle(.checkbox)
                    Spacer(minLength: 0)
                    if let head = audio.studyPlayhead {
                        Text(head.isCountIn ? "Count in · \(Int(ceil(head.countInRemaining)))" : "Pass \(head.cycle+1)")
                            .font(.caption).foregroundStyle(Color.moss).monospacedDigit()
                    }
                }.font(.system(size: 12))
            }
        }
    }
    private var tabCard: some View {
        Card(title: "Guitar tab", subtitle: "Click a fret to hear its note", padding: 18, spacing: 12) {
            StudyTablature(
                bars: study.selectedMeasures, notes: fingered, head: head, selectedID: selectedID,
                stringLabels: state.tuning.pitches.reversed().map { Pitch.chromatic($0 + state.capo) }
            ) { note in
                selectedID = note.id
                audio.note(note.midi)
            }
            HStack(spacing: 12) {
                TuningPicker().frame(maxWidth: 280)
                ChoiceMenu(title: "Capo", selection: $state.capo, options: Array(0...9), label: { "Capo \($0)" }).frame(
                    width: 100)
                Spacer()
            }.font(.caption)
            let missing = fingered.filter { $0.string == nil }.count
            Text(
                missing > 0
                    ? "\(missing) note\(missing == 1 ? " has" : "s have") no available string in this tuning or overlap. Playback still includes every pitch. Try a different staff or tuning."
                    : "Fingerings use source tab where it fits this tuning; the rest are suggestions. Check reach and comfort on your instrument."
            ).font(.system(size: 11)).foregroundStyle(missing > 0 ? Color.clay : .secondary)
            Text(
                "Fret numbers share the notation’s timing. Lines show note lengths; parentheses mark notes sustained from an earlier bar. This is a fingering guide, not a finished guitar arrangement."
            ).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    private var instrumentCard: some View {
        Card(title: "Under your fingers", subtitle: "Highlights follow the sounding notes", padding: 18, spacing: 12) {
            Picker("Instrument", selection: $instrument) {
                Text("Guitar").tag(0)
                Text("Piano").tag(1)
            }.pickerStyle(.segmented).frame(width: 210)
            let pitches = Array(Set(active.map { mod($0.midi) })).sorted().map {
                Pitch.spelled($0, flats: study.selectedMeasures[0].fifths < 0)
            }
            if instrument == 0 {
                Fretboard(
                    root: pitches.first ?? Pitch(0), notes: pitches, degrees: [], tuning: state.tuning,
                    capo: state.capo, showDegrees: false, leftHanded: state.leftHanded, play: { audio.note($0) },
                    exactFrets: Dictionary(
                        active.compactMap { note in note.string.flatMap { string in note.fret.map { (string, $0) } } },
                        uniquingKeysWith: { first, _ in first }),
                    fretCount: max(12, fingered.compactMap(\.fret).max() ?? 12), colorRoots: false)
            } else {
                let low = max(0, ((fingered.map(\.midi).min() ?? 48) / 12) * 12)
                let high = min(127, max(low + 23, ((fingered.map(\.midi).max() ?? 83) / 12 + 1) * 12 - 1))
                Piano(
                    root: pitches.first ?? Pitch(0), notes: pitches, degrees: [], showDegrees: false,
                    exactNotes: Set(active.map(\.midi)), play: { audio.note($0) }, midiRange: low...high,
                    colorRoots: false)
            }
            Text(
                active.map {
                    Solfege.noteName(
                        midi: $0.midi, pitch: Pitch.spelled($0.midi, flats: study.selectedMeasures[0].fifths < 0))
                }.joined(separator: " · ")
            ).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var coachCard: some View {
        Card(title: "Make this part of your learning", padding: 18, spacing: 12) {
            Text(
                "The coach can work from the selected passage’s actual pitches, rhythm, voices, and meter. Add a question or describe what feels difficult before sending."
            ).font(.system(size: 13)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Discuss passage", systemImage: "bubble.left") {
                    state.ask(
                        "Help me practise \(study.document.title), \(study.part.name), \(study.passageLabel.lowercased()). Explain what is happening in these supplied notes, suggest a small exercise, and ask what feels difficult.",
                        study: state.guidedReference(study))
                }
                Button("Create a pathway", systemImage: "sparkles") {
                    state.pendingStudyPathway = state.guidedReference(study)
                    state.destination = .plans
                    state.coachFocus += 1
                }
                if !state.learning.pathways.isEmpty {
                    Menu("Attach to pathway") {
                        ForEach(state.learning.pathways) { path in
                            Button(path.outline.title) { state.attachStudy(study.id, to: path.id) }
                        }
                    }
                }
                Spacer()
            }
            if let path = state.learning.pathways.first(where: { $0.id == study.pathwayID }) {
                Button("Open pathway: " + path.outline.title, systemImage: "arrow.up.right") {
                    state.learning.activePathwayID = path.id
                    state.destination = .plans
                }
                if path.study != study.reference {
                    Text(
                        "This pathway keeps its attached passage. Attach again to update it to your current selection and practice notes."
                    ).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(
                "Nothing is sent automatically. Your chosen model receives the passage reference and saved guided or timed results for this exact selection when you send a question or create a pathway."
            ).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    private func edit(_ change: (inout MusicStudy) -> Void) { state.editStudy(study.id, change) }
    private func binding<Value>(_ keyPath: WritableKeyPath<MusicStudy, Value>) -> Binding<Value> {
        Binding(
            get: { study[keyPath: keyPath] },
            set: { value in
                edit { study in
                    if keyPath == \MusicStudy.notes {
                        study.notes = String((value as? String ?? "").prefix(4000))
                    } else {
                        study[keyPath: keyPath] = value
                    }
                }
            })
    }
    private func nativeChecks() {
        let original = study
        var book = study.practiceBook ?? PassagePracticeBook()
        var progress = book.progress(for: study)
        progress.targetBPM = study.document.tempo * 1.1
        try? progress.record(study.document.tempo * 0.75)
        book.set(progress)
        edit { $0.practiceBook = book }
        let saved = state.studies.studies.first { $0.id == study.id }?.practiceBook?.progress(for: study)
        PassageDiagnostics.checks["tempoGoal"] =
            saved?.targetBPM == progress.targetBPM && saved?.comfortable.last?.bpm == study.document.tempo * 0.75
        PassageDiagnostics.checks["coachHasActualNotes"] =
            study.reference.context.contains("Notes in written order")
            && study.reference.context.contains("not a recording")
        PassageDiagnostics.checks["practiceCopy"] = study.sourceEditor != nil
        state.editStudy(study.id) { $0 = original }
    }

    private func play() {
        if audio.isPlaying || audio.isPreparing {
            audio.stop()
            return
        }
        do {
            state.microphone.stop()
            selectedID = nil
            audio.playStudy(
                try StudyPlaybackPlan(study: displayedStudy, wholePiece: fullView), loop: fullView ? false : study.loop)
        } catch { state.message = error.localizedDescription }
    }
}

private struct StudyTablature: View {
    var bars: [StudyMeasure]
    var notes: [ScoreNote]
    var head: StudyPlayhead?
    var selectedID: UUID?
    var stringLabels: [String]
    var select: (ScoreNote) -> Void
    var body: some View {
        GeometryReader { geometry in
            let width = max(220, (geometry.size.width - 22) / Double(min(4, bars.count)))
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(stringLabels.enumerated()), id: \.offset) {
                            Text($0.element).font(.system(size: 10, design: .monospaced)).frame(height: 19)
                        }
                    }.padding(.top, 24).frame(width: 22)
                    ForEach(bars, id: \.index) { bar in
                        Canvas { context, size in
                            let left = 15.0
                            let right = size.width - 10
                            let x: (Double) -> Double = {
                                left + (min(bar.end, max(bar.start, $0)) - bar.start) / bar.duration * (right - left)
                            }
                            context.draw(
                                Text(bar.label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary),
                                at: CGPoint(x: 18, y: 10))
                            for row in 0..<6 {
                                let y = 34.0 + Double(row) * 19
                                var line = Path()
                                line.move(to: CGPoint(x: 0, y: y))
                                line.addLine(to: CGPoint(x: size.width, y: y))
                                context.stroke(line, with: .color(Color.line), lineWidth: 1)
                            }
                            for pulse in 0..<Int(ceil(bar.duration)) {
                                var tick = Path()
                                tick.move(to: CGPoint(x: x(bar.start + Double(pulse)), y: 138))
                                tick.addLine(to: CGPoint(x: x(bar.start + Double(pulse)), y: 142))
                                context.stroke(tick, with: .color(Color.line), lineWidth: 1)
                            }
                            var end = Path()
                            end.move(to: CGPoint(x: size.width - 1, y: 28))
                            end.addLine(to: CGPoint(x: size.width - 1, y: 135))
                            context.stroke(end, with: .color(Color.line), lineWidth: 1)
                            for note in notes where note.start < bar.end && note.start + note.duration > bar.start {
                                guard let string = note.string, let fret = note.fret else { continue }
                                let y = 34.0 + Double(5 - string) * 19
                                let isActive =
                                    head.map {
                                        !$0.isCountIn && note.start <= $0.sourceBeat
                                            && note.start + note.duration > $0.sourceBeat
                                    } ?? (note.id == selectedID)
                                let color = isActive ? Color.clay : Color.moss
                                let start = x(note.start)
                                let finish = x(note.start + note.duration)
                                var line = Path()
                                line.move(to: CGPoint(x: start + 8, y: y))
                                line.addLine(to: CGPoint(x: max(start + 8, finish - 5), y: y))
                                context.stroke(line, with: .color(color.opacity(0.35)), lineWidth: 3)
                                let circle = Path(
                                    roundedRect: CGRect(x: start - 11, y: y - 8, width: 22, height: 16), cornerRadius: 4
                                )
                                context.fill(circle, with: .color(isActive ? Color.clay.opacity(0.12) : .white))
                                context.draw(
                                    Text(note.start < bar.start ? "(\(fret))" : "\(fret)").font(
                                        .system(size: 11, weight: .semibold, design: .monospaced)
                                    ).foregroundStyle(color), at: CGPoint(x: start, y: y))
                            }
                            if let head, !head.isCountIn, (bar.start..<bar.end).contains(head.sourceBeat) {
                                var line = Path()
                                line.move(to: CGPoint(x: x(head.sourceBeat), y: 24))
                                line.addLine(to: CGPoint(x: x(head.sourceBeat), y: 134))
                                context.stroke(line, with: .color(Color.clay.opacity(0.5)), lineWidth: 1.5)
                            }
                        }.frame(width: width, height: 148)
                            .gesture(
                                SpatialTapGesture().onEnded { value in
                                    let row = min(5, max(0, Int(((value.location.y - 34) / 19).rounded())))
                                    let time =
                                        bar.start + max(0, min(1, (value.location.x - 15) / (width - 25)))
                                        * bar.duration
                                    if let note = notes.filter({
                                        $0.string == 5 - row && $0.start < bar.end && $0.start + $0.duration > bar.start
                                    }).min(by: {
                                        abs(max($0.start, bar.start) - time) < abs(max($1.start, bar.start) - time)
                                    }) {
                                        select(note)
                                    }
                                }
                            )
                            .accessibilityLabel("Bar \(bar.label). Guitar fingering suggestions.")
                            .accessibilityChildren {
                                ForEach(notes.filter { $0.start >= bar.start && $0.start < bar.end }) { note in
                                    Button(
                                        "Play \(Pitch.chromatic(note.midi))\(note.midi/12-1), \(note.string.map { "string \(6-$0), fret \(note.fret ?? 0)" } ?? "no available string")"
                                    ) { select(note) }
                                }
                            }
                    }
                }
            }
        }.frame(height: 156)
    }
}
