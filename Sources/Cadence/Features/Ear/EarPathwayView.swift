// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct EarPathwayView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var input: EarSessionInput
    @ObservedObject var midi: MIDIKeyboard
    @ObservedObject var audio: AudioPlayer
    @ObservedObject var microphone: Microphone
    @State private var playback: (UUID, EarSession)?
    @State private var imagineStart = Date()
    private var session: EarSession? { input.active(state) }
    private var material: ScoreEarMaterial? { session?.opening.material }
    private var current: Bool { material.map { state.scoreEarCurrent($0) } ?? true }
    private var projection: EarProjection? { try? session?.projection() }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Button("Practice home", systemImage: "arrow.left") { state.showPracticeHome() }.buttonStyle(.plain)
                Spacer()
                Label(input.pending == nil ? "Your place is saved" : "Waiting to save", systemImage: "bookmark").font(
                    .caption
                ).foregroundStyle(.secondary)
            }
            if let p = projection {
                HStack(alignment: .lastTextBaseline) {
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow(
                            text: material == nil
                                ? "Ear-first · about 5 minutes" : "From your library · " + (material?.label ?? "")
                        ).foregroundStyle(Color.moss)
                        Text(material == nil ? "Hear it. Carry it. Find it." : (material?.title ?? "Your passage"))
                            .font(.system(size: 32, weight: .medium, design: .serif))
                    }
                    Spacer()
                    Text(
                        p.stage == .complete
                            ? "Session complete"
                            : material == nil ? "\(p.round+1) of 3 · \(p.roundTitle)" : p.roundTitle
                    ).font(.callout).foregroundStyle(Color.moss)
                }
                if !current {
                    Text(
                        "The linked score changed or is no longer reviewed. These results are preserved. Choose a fresh reviewed passage in the library."
                    ).foregroundStyle(Color.clay)
                }
                journey(p)
                if p.stage == .complete {
                    if material != nil { librarySummary(p) } else { summary(p) }
                } else {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 22) {
                            Eyebrow(text: p.phrase.key + " · \(p.phrase.notes.count) notes").foregroundStyle(Color.moss)
                            Text(title(p)).font(.system(size: 28, weight: .medium, design: .serif))
                            stage(p)
                            if p.hinted || (p.stage == .review && material == nil) { phrase(p) }
                            if !p.awaitingAdvance, [.imagine, .sing, .play].contains(p.stage) {
                                HStack {
                                    if material != nil { Button("Hear home note") { hearTonic() } }
                                    Button("Hear it again", systemImage: "speaker.wave.2") { listen() }
                                    if !p.hinted { Button("Show solfège") { action(.hint) } }
                                }.disabled(audio.isPreparing || audio.isPlaying || input.pending != nil)
                                Text(
                                    material == nil
                                        ? "Replaying or opening solfège makes this supported practice."
                                        : "The home note gives the key. Replaying the melody or opening solfège counts as support."
                                ).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(26).frame(maxWidth: .infinity, alignment: .leading).background(
                            Color.paper, in: RoundedRectangle(cornerRadius: 14)
                        ).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.line))
                        VStack(alignment: .leading, spacing: 16) {
                            Eyebrow(text: material == nil ? "Why this phrase" : "Your music, remembered")
                                .foregroundStyle(Color.moss)
                            Text(p.reason).font(.callout).fixedSize(horizontal: false, vertical: true)
                            if let material {
                                Text(material.sourceLabel).font(.caption).foregroundStyle(.secondary)
                                Button("Score & original", systemImage: "doc.text.magnifyingglass") { openSource() }
                                    .disabled(input.pending != nil)
                                Text(
                                    "Opening the source before answering counts as support. Return through Practice home to resume."
                                ).font(.caption).foregroundStyle(.secondary)
                            }
                            Divider()
                            Text("A sound before a name.").font(.system(size: 21, weight: .medium, design: .serif))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(
                                "Imagine the next note before you make it. Movable Do helps name the relationships: Do is home, even when the key changes."
                            ).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Text("Pitch and note order are checked. Timing and imagination are yours to explore.").font(
                                .caption
                            ).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }.padding(20).frame(width: 235).background(
                            Color.moss.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    }.disabled(!current)
                }
                if let error = input.error { Text(error).foregroundStyle(Color.clay).font(.callout) }
                if input.pending != nil {
                    HStack {
                        Button("Retry saving") { input.save(state: state) }
                        Button("Discard unsaved action") { input.discard() }
                    }
                }
                if let error = audio.error ?? microphone.error {
                    Text(error).foregroundStyle(Color.clay).font(.callout)
                }
            }
        }
        .onChange(of: audio.completedPlayback) { _, token in
            guard let token, let request = playback, token == request.0 else { return }
            playback = nil
            if (try? request.1.projection().stage) == .hear {
                input.submit(EarEvent(.heard), state: state, expected: request.1)
            }
            imagineStart = Date()
        }
        .onReceive(midi.updates) { input.receive($0, state: state) }
        .onReceive(microphone.detections) { input.receivePitch($0.0, at: $0.1, state: state) }
        .onChange(of: midi.connectionRevision) { _, _ in if projection?.stage == .play { input.pause() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { pause() } }
        .onDisappear { pause() }
        .onAppear {
            imagineStart = Date()
            midi.start()
        }
    }
    private func title(_ p: EarProjection) -> String {
        if p.awaitingAdvance {
            return p.results.last?.event.skipped == true
                ? "Leave room to return."
                : p.results.last?.correct == true ? "The phrase came back." : "A useful place to listen again."
        }
        switch p.stage {
        case .hear: return "First, just listen."
        case .imagine: return "Let it play in your mind."
        case .sing: return "Give the phrase your voice."
        case .play: return "Now find it on the keys."
        case .review: return "Notice what connected."
        case .complete: return "A little more music inside."
        }
    }
    @ViewBuilder private func stage(_ p: EarProjection) -> some View {
        if p.awaitingAdvance {
            if let result = p.results.last {
                Text(
                    result.event.skipped
                        ? "No result was inferred. You can still continue with the other stages."
                        : result.correct
                            ? (result.assisted
                                ? "Matched with support. A later return will help it settle."
                                : "Pitch and order matched on this attempt.")
                            : (material == nil
                                ? "The captured pitches or note order differed. We'll revisit the phrase before trying a new key."
                                : "Some pitches or their order differed. Keep the shape in mind; you can listen again after both checks.")
                ).foregroundStyle(.secondary)
                Button("Continue", systemImage: "arrow.right") { action(.next) }.buttonStyle(.cadencePrimary)
            }
        } else {
            switch p.stage {
            case .hear:
                Text("You'll hear the home note, a breath, then a short phrase. Keep its shape in mind.")
                    .foregroundStyle(.secondary)
                Button(
                    audio.isPlaying || audio.isPreparing ? "Stop listening" : "Hear the phrase",
                    systemImage: audio.isPlaying ? "stop.fill" : "play.fill"
                ) {
                    if audio.isPlaying || audio.isPreparing {
                        playback = nil
                        audio.stop()
                    } else {
                        listen()
                    }
                }.buttonStyle(.cadencePrimary).controlSize(.large).disabled(input.pending != nil)
            case .imagine:
                Text(
                    p.isReturn
                        ? "Without replaying it, imagine the passage from last time. Its shape, its rhythm, its ending. Take a moment before you sing."
                        : "No sound for a moment. Hear the phrase internally; imagine how each note leads to the next."
                ).foregroundStyle(.secondary)
                TimelineView(.periodic(from: Date(), by: 0.25)) { time in
                    let remaining = max(0, 3 - Int(time.date.timeIntervalSince(imagineStart)))
                    HStack {
                        Image(systemName: "waveform.path").font(.system(size: 35)).foregroundStyle(Color.moss)
                        Text(remaining > 0 ? "A breath of silence · \(remaining)" : "Ready when you are.").font(
                            .system(size: 20, design: .serif))
                    }.padding(.vertical, 10)
                    Button("I'm ready to sing", systemImage: "arrow.right") { action(.imagined) }.disabled(
                        remaining > 0 || audio.isPlaying || audio.isPreparing || input.pending != nil)
                }
            case .sing:
                Text(
                    "Sing on a comfortable syllable or use solfège. Hold each note for about half a second; leave a small breath between repeated notes. Any comfortable octave is welcome."
                ).foregroundStyle(.secondary)
                capture(p)
                HStack {
                    Button(input.listening ? "Stop capture" : "Use microphone", systemImage: "mic") {
                        if input.listening {
                            input.pause()
                            microphone.stop()
                        } else {
                            input.arm(state: state)
                            Task {
                                await microphone.start()
                                if !input.listening { microphone.stop() }
                                if !microphone.listening { input.pause() }
                            }
                        }
                    }
                    Button("Check my singing") { answer() }.disabled(input.notes.isEmpty || input.invalidTake)
                    Button("Skip singing") { action(.answer, skipped: true) }
                }.disabled(input.pending != nil || audio.isPlaying || audio.isPreparing)
                Text("Processed on this Mac. No recording is saved or uploaded.").font(.caption).foregroundStyle(
                    .secondary)
            case .play:
                Text(
                    "Start in the reference octave: home is \(noteName(p.phrase.tonic)). Play the phrase one note at a time, releasing each key. Use your piano's own sound."
                ).foregroundStyle(.secondary)
                MIDIConnectionView(midi: midi)
                capture(p)
                HStack {
                    Button(input.listening ? "Clear and restart" : "Capture keyboard", systemImage: "pianokeys") {
                        input.arm(state: state)
                    }.disabled(!midi.connected)
                    Button("Check my playing") { answer() }.disabled(
                        input.notes.isEmpty || input.invalidTake || !midi.keyboard.downNotes.isEmpty)
                    Button("Skip keyboard") { action(.answer, skipped: true) }
                }.disabled(input.pending != nil || audio.isPlaying || audio.isPreparing)
                if input.waitingForRelease {
                    Text("Release held keys to begin.").font(.caption).foregroundStyle(Color.clay)
                }
            case .review:
                ForEach(p.results.filter { $0.round == p.round }, id: \.event.id) { result in
                    VStack(alignment: .leading, spacing: 5) {
                        Label(
                            result.input == .singing ? "Singing" : "Keyboard",
                            systemImage: result.input == .singing ? "mic" : "pianokeys"
                        ).font(.headline)
                        Text(
                            result.event.skipped
                                ? "Skipped · no assessment"
                                : result.event.notes.map(noteName).joined(separator: "  →  ")
                        ).font(.callout)
                        Text(
                            result.event.skipped
                                ? "Return whenever you're ready."
                                : result.correct
                                    ? (result.assisted ? "Matched with support" : "Matched independently")
                                    : "Different pitches or note order"
                        ).font(.caption).foregroundStyle(result.correct ? Color.moss : Color.secondary)
                    }
                }
                if let material {
                    phrase(p)
                    ScoreAccompanimentView(material: material, input: input, midi: midi).id("score-band")
                }
                if material != nil, let session { CreativeAnswerCard(session: session) }
                Button(p.round == 2 || material != nil ? "Finish session" : "Next phrase", systemImage: "arrow.right") {
                    action(.next)
                }.buttonStyle(.cadencePrimary).disabled(input.pending != nil)
            case .complete: EmptyView()
            }
        }
    }
    private func capture(_ p: EarProjection) -> some View {
        HStack(spacing: 10) {
            ForEach(0..<max(p.phrase.notes.count, input.notes.count), id: \.self) { i in
                Text(i < input.notes.count ? "●" : "○").font(.system(size: 28)).foregroundStyle(
                    i < input.notes.count ? Color.moss : Color.secondary.opacity(0.4))
            }
            Spacer()
            Text("\(input.notes.count) captured").font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 12).accessibilityElement(children: .ignore).accessibilityLabel(
            "\(input.notes.count) notes captured")
    }
    private func phrase(_ p: EarProjection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(p.stage == .review ? "The phrase" : "Solfège support is open").font(.caption).foregroundStyle(
                Color.moss)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 10)], spacing: 10) {
                ForEach(Array(p.phrase.notes.enumerated()), id: \.offset) { index, note in
                    VStack(spacing: 8) {
                        Text(p.phrase.solfege[index]).font(.system(size: 26, weight: .medium, design: .serif))
                        Text(
                            p.phrase.material.map { $0.tones[index].degreeLabel + " · " + $0.tones[index].noteName }
                                ?? "\(p.phrase.degrees[index]) · \(noteName(note))"
                        ).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 12).background(
                        Color.moss.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }
    }
    private func journey(_ p: EarProjection) -> some View {
        HStack(spacing: 0) {
            ForEach(Array([EarStage.hear, .imagine, .sing, .play, .review].enumerated()), id: \.offset) { i, stage in
                HStack(spacing: 8) {
                    Text(String(format: "%02d", i + 1)).font(.caption.monospacedDigit())
                    Text(stage == .hear && p.isReturn ? "Recall" : stage.rawValue.capitalized).font(
                        .callout.weight(.medium))
                    Spacer(minLength: 5)
                }
                .foregroundStyle(p.stage == stage ? Color.moss : .secondary).padding(.vertical, 13)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(p.stage == stage ? Color.moss : Color.line).frame(height: p.stage == stage ? 3 : 1)
                }
            }
        }
    }
    private func summary(_ p: EarProjection) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("A little more music inside.").font(.system(size: 29, weight: .medium, design: .serif))
            Text(
                "You moved between listening, imagining, singing and playing. Here's what the checked attempts tell us."
            ).foregroundStyle(.secondary)
            ForEach([PracticeInput.singing, .midi], id: \.rawValue) { mode in
                let results = p.results.filter { $0.input == mode && !$0.event.skipped }
                Text(
                    "\(mode == .singing ? "Singing" : "Keyboard"): \(results.filter(\.correct).count) of \(results.count) matched · \(results.filter { $0.correct && !$0.assisted }.count) without support"
                ).font(.callout)
            }
            Text(
                "Difficult phrases return sooner. Supported matches receive a short review; independent matches can return tomorrow. Repeating a phrase in this session never lengthens its interval twice."
            ).font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Another short session") { state.openEarPathway() }
                Button("Find the groove", systemImage: "arrow.right") { state.practicePage = .groove }
            }
        }.padding(28).frame(maxWidth: .infinity, alignment: .leading).background(
            Color.moss.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
    private func librarySummary(_ p: EarProjection) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("A passage to carry with you.").font(.system(size: 29, weight: .medium, design: .serif))
            ForEach(p.results, id: \.event.id) { result in
                Text(
                    "\(result.input == .singing ? "Singing" : "Keyboard"): \(result.event.skipped ? "skipped, no grade" : result.correct ? (result.assisted ? "matched with support" : "matched without hints") : "pitches or order differed")"
                ).font(.callout)
            }
            Text("\(p.accompanimentVisits) play-along visits · no performance grade inferred").font(.caption)
                .foregroundStyle(.secondary)
            if let material {
                if let session { CreativeAnswerCard(session: session) }
                Text(state.scoreEarReview(material).reason()).font(.callout).foregroundStyle(Color.moss)
                Text(
                    "A return starts with the melody hidden. We leave at least 20 hours after this encounter before calling it a delayed return. Early practice stays available and counts as supported. Singing and keyboard recall have separate review cards."
                ).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Back to my piece", systemImage: "books.vertical") {
                        state.libraryLearning = true
                        state.showLibraryPiece(material.pieceID)
                    }
                    Button("Practise again now") {
                        do { try state.openScoreEar(material) } catch { state.message = error.localizedDescription }
                    }
                }
            }
        }.padding(26).frame(maxWidth: .infinity, alignment: .leading).background(
            Color.moss.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
    private func hearTonic() {
        guard current, let phrase = projection?.phrase, input.pending == nil else { return }
        input.submit(.init(.tonic), state: state)
        guard input.pending == nil else { return }
        audio.play(Score(tempo: 90, notes: [ScoreNote(midi: phrase.tonic, start: 0, duration: 1)]))
    }
    private func openSource() {
        guard let material, let piece = state.libraryPieces.first(where: { $0.id == material.pieceID }) else { return }
        if let p = projection, [.imagine, .sing, .play].contains(p.stage), !p.hinted {
            action(.hint)
            guard input.pending == nil else { return }
        }
        pause()
        state.openLibraryPiece(
            piece, from: material.scope.fromBar - 1, through: material.scope.throughBar - 1,
            partID: material.scope.partID)
    }
    private func noteName(_ note: Int) -> String { Solfege.noteName(midi: note, pitch: Pitch.spelled(note)) }
    private func action(_ kind: EarEvent.Kind, skipped: Bool = false) {
        input.submit(EarEvent(kind, skipped: skipped), state: state)
    }
    private func answer() { input.submit(EarEvent(.answer, notes: input.notes), state: state) }
    private func listen() {
        guard current, session != nil, let p = projection, input.pending == nil else { return }
        input.pause()
        microphone.stop()
        if p.stage != .hear {
            input.submit(EarEvent(.replay), state: state)
            guard input.pending == nil else { return }
        }
        guard let current = session else { return }
        audio.play(p.phrase.score)
        playback = (audio.playbackID, current)
    }
    private func pause() {
        playback = nil
        input.pause()
        microphone.stop()
        audio.stop()
    }
}
