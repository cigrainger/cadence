// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct PickingHomeCard: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: "hand.draw").font(.system(size: 27)).foregroundStyle(Color.clay)
            VStack(alignment: .leading, spacing: 5) {
                Text("Find your picking pattern").font(.system(size: 23, weight: .medium, design: .serif))
                Text("Travis · arpeggios · strumming → an accompaniment of your own").font(.callout).foregroundStyle(
                    .secondary)
            }
            Spacer()
            Button("Explore picking", systemImage: "arrow.right") { state.showPicking() }.buttonStyle(.cadencePrimary)
        }.padding(22).background(Color.clay.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
}
struct PickingPathwayView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var input: PickingInput
    @ObservedObject var audio: AudioPlayer
    @ObservedObject var microphone: Microphone
    @State private var choosing = false
    @State private var pieceID = ""
    @State private var partID = "P1"
    @State private var staff = 1
    @State private var from = 1
    @State private var through = 4
    @State private var style = PickingStyle.travis
    @State private var tempo = 72
    @State private var layer = "All notes"
    @State private var backbeat = false
    @State private var taps = 0
    @State private var document: EditorDocument?
    @State private var selection: UUID?
    @State private var height: CGFloat = 360
    @State private var renderError: String?
    @State private var metrics = ""
    @State private var error: String?
    private var session: PickingSession? { state.pickingPractice.active }
    private var piece: LibraryPiece? { state.libraryPieces.first { $0.id == pieceID } }
    private var parts: [(String, String)] {
        if case .study(let study) = piece?.source { return study.document.parts.map { ($0.id, $0.name) } }
        return [("P1", "Guitar / piano score")]
    }
    private var bars: Int {
        if case .study(let study) = piece?.source {
            return study.document.parts.first { $0.id == partID }?.measures.count ?? 1
        }
        return piece?.bars ?? 1
    }
    private var source: ChangesSource? {
        piece.flatMap { try? ChangesSource(piece: $0, from: from - 1, through: through - 1, partID: partID) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Button("Back to Learn", systemImage: "arrow.left") { state.showPracticeHome() }.buttonStyle(.plain)
                Spacer()
                Button(choosing ? "Back to session" : "Choose music / pattern", systemImage: "slider.horizontal.3") {
                    stop()
                    choosing.toggle()
                }
                .disabled(session == nil || input.pending != nil)
            }
            VStack(alignment: .leading, spacing: 7) {
                Eyebrow(text: "Guitar · rhythm into accompaniment").foregroundStyle(Color.clay)
                Text("Find your picking pattern").font(.system(size: 34, weight: .medium, design: .serif))
                Text("One pulse. Your changes. A new way to play them.").foregroundStyle(.secondary)
            }
            if input.pending != nil {
                Card(title: "Your result is waiting to be saved") {
                    Text(input.error ?? "Try saving again before continuing.")
                    HStack {
                        Button("Try saving again") { input.save(state) }.buttonStyle(.cadencePrimary)
                        Button("Discard unsaved result") { input.discard() }
                    }
                }
            }
            if choosing || session == nil {
                setup
            } else if let session {
                if state.pickingCurrent(session.material) {
                    lesson(session)
                } else {
                    ContentUnavailableView(
                        "Revisit the source", systemImage: "book.closed",
                        description: Text(
                            "Your work is kept. This piece changed or needs review; choose its current version to start a new pathway."
                        ))
                }
            }
            if let error = error ?? input.error ?? renderError ?? microphone.error ?? audio.error {
                Text(error).font(.callout).foregroundStyle(Color.clay).textSelection(.enabled)
            }
        }
        .onAppear {
            if pieceID.isEmpty { pieceID = session?.material.pieceID ?? state.libraryPieces.first?.id ?? "" }
            if let session { style = session.style }
            refresh()
        }
        .onChange(of: pieceID) { _, _ in
            partID = parts.first?.0 ?? "P1"
            from = 1
            through = min(4, bars)
            staff = source?.staffs.first ?? 1
        }
        .onChange(of: partID) { _, _ in
            from = 1
            through = min(4, bars)
            staff = source?.staffs.first ?? 1
        }
        .onChange(of: from) { _, _ in through = min(bars, max(from, min(through, from + 7))) }
        .onChange(of: session?.stage) { _, _ in
            stop()
            taps = 0
            refresh()
        }
        .onChange(of: session?.id) { _, _ in
            stop()
            refresh()
        }
        .onChange(of: tempo) { _, _ in
            stop()
            refresh()
        }
        .onChange(of: style) { _, _ in
            stop()
            refresh()
        }
        .onChange(of: backbeat) { _, _ in
            stop()
            refresh()
        }
        .onReceive(microphone.observations) { input.receive($0, state: state) }
        .onChange(of: microphone.listening) { _, listening in if !listening { input.pause() } }
        .onChange(of: audio.isPlaying) { _, playing in
            if playing {
                input.pause()
                microphone.stop()
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { stop() } }
        .onDisappear { stop() }
    }
    private var setup: some View {
        Card(title: "Start with your changes", subtitle: "An original pattern over music you know") {
            Text(
                "Choose 1–8 reviewed bars in 4/4, with chord changes at bar lines. We keep the original score and create a separate guitar accompaniment."
            ).font(.callout).foregroundStyle(.secondary)
            if state.libraryPieces.isEmpty {
                Button("Open Library", systemImage: "books.vertical") { state.destination = .library }
            } else {
                ChoiceMenu(title: "Piece", selection: $pieceID, options: state.libraryPieces.map(\.id)) { id in
                    state.libraryPieces.first { $0.id == id }?.title ?? "Choose music"
                }
                HStack {
                    ChoiceMenu(title: "Part", selection: $partID, options: parts.map(\.0)) { id in
                        parts.first { $0.0 == id }?.1 ?? id
                    }
                    ChoiceMenu(title: "Harmony staff", selection: $staff, options: source?.staffs ?? [1]) {
                        "Staff \($0)"
                    }
                    Stepper("From \(from)", value: $from, in: 1...max(1, bars))
                    Stepper("Through \(through)", value: $through, in: from...max(from, min(bars, from + 7)))
                }
                HStack {
                    ChoiceMenu(title: "Pattern", selection: $style, options: PickingStyle.allCases) { $0.rawValue }
                    TuningPicker()
                    Stepper("Capo \(state.capo)", value: $state.capo, in: 0...9).fixedSize()
                }
                Text(style.detail).font(.callout)
                Button("Build my picking pathway", systemImage: "hand.draw") {
                    do {
                        guard let piece else { return }
                        try state.beginPicking(
                            piece: piece,
                            scope: .init(partID: partID, staff: staff, from: from - 1, through: through - 1),
                            style: style)
                        choosing = false
                        error = nil
                        refresh()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.cadencePrimary).disabled(input.pending != nil)
            }
        }
    }
    @ViewBuilder private func lesson(_ session: PickingSession) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.material.title).font(.headline)
                Text(
                    "Bars \(session.material.scope.from + 1)–\(session.material.scope.through + 1) · \(session.style.rawValue) · \(session.material.tuning.name) · capo \(session.material.capo)"
                ).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open full piece", systemImage: "arrow.up.right") {
                if let original = state.libraryPieces.first(where: { $0.id == session.material.pieceID }) {
                    state.openLibraryPiece(original)
                }
            }
        }
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(PickingStage.allCases.dropLast()), id: \.self) { stage in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: session.stage == stage ? "circle.inset.filled" : "circle").foregroundStyle(
                            session.stage == stage ? Color.clay : Color.moss.opacity(0.35))
                        Text(stage.title).font(.callout.weight(session.stage == stage ? .semibold : .regular))
                            .foregroundStyle(session.stage == stage ? Color.ink : .secondary)
                    }.padding(.vertical, 12)
                    if stage != .independent {
                        Rectangle().fill(Color.moss.opacity(0.15)).frame(width: 1, height: 12).padding(.leading, 7)
                    }
                }
            }.frame(width: 180, alignment: .leading).accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: 18) {
                Card(title: session.stage.title) {
                    Text(instruction(session)).font(.callout)
                    if session.stage != .complete {
                        HStack {
                            Stepper("\(tempo) bpm", value: $tempo, in: 30...140, step: 4).fixedSize()
                            Spacer()
                            Text(state.leftHanded ? "Picking hand: left" : "Picking hand: right").font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if session.stage != .independent || session.supported {
                        Text(
                            "p = thumb · i = index · m = middle · a = ring · ↓ / ↑ = stroke direction. Suggested movements, not measured technique."
                        ).font(.caption).foregroundStyle(.secondary)
                        if let document, session.stage != .complete {
                            EditorRenderer(
                                document: document, engine: "OpenSheetMusicDisplay", from: 0,
                                through: document.barCount - 1,
                                selection: selection, playhead: nil, select: { selection = $0 }, height: $height,
                                error: $renderError, metrics: $metrics
                            )
                            .frame(height: max(290, height))
                            HStack {
                                Button("Hear the pattern", systemImage: "play.fill") { play() }.buttonStyle(
                                    .cadencePrimary)
                                Button("Stop", systemImage: "stop.fill") { stop() }
                                ChoiceMenu(
                                    title: "Listen to", selection: $layer,
                                    options: ["All notes", "Bass", "Upper notes"]
                                ) { $0 }
                            }
                        }
                    } else {
                        Button("Show the pattern and demonstration") { input.submit(.reveal, state: state) }
                    }
                    if session.stage == .hear {
                        Button("Tap the pulse · \(taps)", systemImage: "hand.tap") { taps += 1 }.keyboardShortcut(
                            .space, modifiers: [])
                        Text(
                            "Spacebar or click. Listen for the rests; tapping here is exploration, without a timing grade."
                        ).font(.caption).foregroundStyle(.secondary)
                    }
                    if session.stage == .changes, session.material.chords.count > 1 {
                        HStack {
                            Stepper(
                                "Join \(input.join + 1) → \(input.join + 2)", value: $input.join,
                                in: 0...max(0, session.material.chords.count - 2))
                            Button("Hear this join") { play(join: true) }
                        }
                        Text(
                            "Repeat this join on guitar, then return to the whole phrase. A difficult join is a reason to slow down, not restart everything."
                        ).font(.caption).foregroundStyle(.secondary)
                    }
                    if session.stage == .chord { observation(session) }
                    if session.stage == .create {
                        ChoiceMenu(title: "Compare / adapt", selection: $style, options: PickingStyle.allCases) {
                            $0.rawValue
                        }
                        Toggle("Accent beats 2 and 4", isOn: $backbeat)
                        Button("Save and shape in Studio", systemImage: "square.and.pencil") {
                            do {
                                try state.savePickingArrangement(style: style, tempo: tempo, backbeat: backbeat)
                            } catch { self.error = error.localizedDescription }
                        }.buttonStyle(.cadencePrimary)
                        Text(
                            "A separate editable composition, linked to the original. Reopening a saved version keeps your edits. Add a melody or change the rhythm in Studio."
                        ).font(.caption).foregroundStyle(.secondary)
                    }
                    if session.stage == .complete {
                        Text(session.review.reason()).font(.callout)
                        Button("Try an independent return") {
                            do { try state.resumePicking(session.id, independent: true) } catch {
                                self.error = error.localizedDescription
                            }
                        }
                        Button("Choose another progression") { choosing = true }
                    } else {
                        HStack {
                            Button(session.stage == .create ? "Finish this session" : "I tried it · continue") {
                                input.submit(.tried, state: state)
                            }.buttonStyle(.cadencePrimary)
                            Button("Needs a focused retry") { input.submit(.needsWork, state: state) }
                            Button("Skip for now") { input.submit(.skip, state: state) }
                        }.disabled(input.pending != nil || input.recording)
                        Text(
                            "Your report is saved separately from microphone observations. It does not certify technique or mastery."
                        ).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth: .infinity)
        }.disabled(input.pending != nil)
    }
    private func observation(_ session: PickingSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Optional: listen to one bass note").font(.headline)
            Text(
                "Pluck only the first bass note and let it ring. Use headphones and a quiet room. This compares sustained pitch; it does not assess the full pattern, rhythm or picking hand."
            ).font(.caption).foregroundStyle(.secondary)
            if input.recording {
                Button("Stop and inspect · \(input.frames.count) windows") { input.finish(state) }
            } else {
                Button("Listen locally", systemImage: "mic") {
                    input.arm(state)
                    Task { await input.startMicrophone(microphone) }
                }
            }
            if let take = session.takes.last {
                PitchObservationStrip(take: take)
                Text(take.summary).font(.callout).textSelection(.enabled)
                Text(
                    "Target \(EditorPitch(take.target).label) · \(take.frames.count) pitch readings saved on this Mac · no audio uploaded"
                ).font(.caption).foregroundStyle(.secondary)
                Button("Discuss these observations with coach", systemImage: "sparkles") { state.openContextCoach() }
            }
        }
    }
    private func instruction(_ s: PickingSession) -> String {
        switch s.stage {
        case .hear: s.style.detail + " Hear a bar, imagine it, then tap its pulse."
        case .muted:
            "Lightly mute the strings with your fretting hand. Follow the picking cues, keeping the motion through silent subdivisions. Release any tension."
        case .chord:
            "Hold the first shape comfortably. Keep the pattern even; stop and adjust if the shape is uncomfortable. The displayed score repeats this one chord."
        case .changes:
            "Carry the same picking motion through the source progression. Isolate a join, then reconnect it to its surrounding phrase."
        case .create:
            "Hear three ways of accompanying these changes. Choose a pattern, shape its accents, then make the arrangement your own in Studio."
        case .independent:
            "Before opening the pattern, recall its sound and play the changes. Report how it felt; this is self-assessment, without an automatic performance grade."
        case .complete:
            "Your pathway and observations are saved. Return after a break, then try the pattern over another progression."
        }
    }
    private func refresh() {
        guard let s = session else { return }
        do {
            document = try s.material.document(
                style: s.stage == .create ? style : s.style, tempo: tempo,
                oneChord: [.hear, .muted, .chord].contains(s.stage), strongerBackbeat: backbeat)
            selection = document?.events.first?.id
            renderError = nil
        } catch { self.error = error.localizedDescription }
    }
    private func play(join focused: Bool = false) {
        guard var document else { return }
        state.stopAllPlayback()
        if layer != "All notes" {
            for index in document.events.indices {
                document.events[index].pitches = document.events[index].pitches.filter { pitch in
                    guard let string = pitch.string else { return false }
                    guard let session else { return false }
                    let bar =
                        session.stage == .chord || session.stage == .hear || session.stage == .muted
                        ? 0 : document.events[index].bar
                    let shape = session.material.frets[bar]
                    let strings = shape.indices.filter { shape[$0] >= 0 }
                    let bassStrings = Array(
                        strings.prefix((session.stage == .create ? style : session.style) == .travis ? 2 : 1))
                    let isBass = bassStrings.contains(string)
                    return layer == "Bass" ? isBass : !isBass
                }
            }
        }
        let bars = focused ? input.focusedBars(document.barCount) : 0...(document.barCount - 1)
        audio.play(document.playback(from: bars.lowerBound, through: bars.upperBound))
    }
    private func stop() {
        input.pause()
        microphone.stop()
        audio.stop()
    }
}

private struct PitchObservationStrip: View {
    var take: MonophonicTake
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Pitch windows · centre line is the selected bass note").font(.caption).foregroundStyle(.secondary)
            GeometryReader { geometry in
                Path { path in
                    path.move(to: .init(x: 0, y: 40))
                    path.addLine(to: .init(x: geometry.size.width, y: 40))
                }.stroke(Color.moss.opacity(0.2), lineWidth: 1)
                Path { path in
                    var connected = false
                    for (index, frame) in take.frames.enumerated() {
                        guard frame.usable, let frequency = frame.frequency else {
                            connected = false
                            continue
                        }
                        let cents = 1200 * log2(frequency / (440 * pow(2, Double(take.target - 69) / 12)))
                        let point = CGPoint(
                            x: Double(index) / Double(max(1, take.frames.count - 1)) * geometry.size.width,
                            y: 40 - max(-100, min(100, cents)) * 0.35)
                        if connected { path.addLine(to: point) } else { path.move(to: point) }
                        connected = true
                    }
                }.stroke(Color.clay, lineWidth: 2)
            }.frame(height: 80).accessibilityElement(children: .ignore).accessibilityLabel(take.summary)
            Text("±100 cents shown; gaps are uncertain windows. A window is not a note attack.").font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
