// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct TensionHomeCard: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 27)).foregroundStyle(Color.clay)
            VStack(alignment: .leading, spacing: 5) {
                Text("Create and resolve tension").font(.system(size: 23, weight: .medium, design: .serif))
                Text("Hear a difference. Understand its pull. Write your own ending.").font(.callout).foregroundStyle(
                    .secondary)
            }
            Spacer()
            Button(
                state.tensionPractice.active == nil ? "Explore harmony" : "Continue theory", systemImage: "arrow.right"
            ) { state.showTension() }.buttonStyle(.cadencePrimary)
        }.padding(22).background(Color.clay.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
}
struct TensionPathwayView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var input: TensionInput
    @ObservedObject var audio: AudioPlayer
    @ObservedObject var midi: MIDIKeyboard
    @State private var instrument = EditorInstrument.piano
    @State private var choosing = false
    @State private var reflection = ""
    @State private var error: String?
    @State private var showReadings = false
    @State private var showNotebook = false
    private var session: TensionSession? { state.tensionPractice.active }
    private var piece: LibraryPiece? { state.libraryPieces.first { $0.id == session?.source.pieceID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button("Back to Learn", systemImage: "arrow.left") { state.showPracticeHome() }.buttonStyle(.plain)
                    .foregroundStyle(Color.moss)
                Spacer()
                Button(choosing ? "Back to lesson" : "Choose an activity") {
                    input.pause()
                    audio.stop()
                    choosing.toggle()
                }.disabled(session == nil || input.pending != nil)
            }
            VStack(alignment: .leading, spacing: 7) {
                Eyebrow(text: "Harmony studio · example into understanding").foregroundStyle(Color.clay)
                Text("Create and resolve tension").font(.system(size: 34, weight: .medium, design: .serif))
                Text("One changed note can point the music somewhere new.").foregroundStyle(.secondary)
            }
            if let pending = input.pending {
                Card(title: "Your answer is waiting to be saved", padding: 16) {
                    Text(input.error ?? "This answer is still here. Save or discard it before continuing.").font(
                        .callout)
                    HStack {
                        Button("Try saving again") { input.save(state) }
                        Button("Discard unsaved answer") { input.discard() }
                    }
                    Text(pending.expected.skill.rawValue).font(.caption).foregroundStyle(.secondary)
                }
            }
            if choosing || session == nil {
                setup
            } else if let session, let piece {
                if !state.tensionCurrent(session.source) {
                    ContentUnavailableView(
                        "Revisit the source", systemImage: "book.closed",
                        description: Text(
                            "The music or page review has changed. Your earlier readings and practice are preserved. Open the current piece and begin a new lesson."
                        ))
                } else {
                    header(session, piece: piece)
                    if showNotebook {
                        ScoreAnalysisPanel(piece: piece, scope: session.source.scope)
                    } else if session.completed {
                        completion(session)
                    } else {
                        if session.skill != .hearing
                            && !(session.independent && session.skill == .playing && !session.assisted)
                        {
                            HarmonicScore(
                                piece: piece, scope: session.source.scope,
                                analysis: session.independent ? nil : state.savedAnalysis(piece),
                                focus: session.source.changes[session.source.pair].bar, playhead: audio.studyPlayhead)
                        }
                        Group {
                            switch session.skill {
                            case .hearing: hearing(session)
                            case .explaining: explaining(session, piece: piece)
                            case .playing: playing(session)
                            case .creating: creating(session)
                            }
                        }.disabled(input.pending != nil)
                    }
                }
            } else {
                Text("The source piece is no longer in the library. Your earlier practice is preserved.")
                    .foregroundStyle(Color.clay)
            }
            if let feedback = input.feedback {
                Label(feedback, systemImage: "ear").font(.callout).foregroundStyle(Color.clay)
            }
            if let error = error ?? input.error ?? audio.error {
                Text(error).foregroundStyle(Color.clay).font(.callout).textSelection(.enabled)
            }
            TheoryReferences()
        }
        .onAppear { if CommandLine.arguments.contains("--tension-analysis") { showNotebook = true } }
        .onReceive(midi.updates) { input.receive($0, state: state) }
        .onChange(of: midi.connectionRevision) { _, _ in input.pause() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                input.pause()
                audio.stop()
            }
        }
        .onChange(of: audio.isPlaying) { _, playing in if playing { input.pause() } }
        .onChange(of: session?.skill) { _, _ in
            input.pause()
            audio.stop()
            showReadings = false
        }
        .onChange(of: session?.id) { _, _ in
            reflection = ""
            showReadings = false
            showNotebook = false
        }
        .onDisappear {
            input.pause()
            audio.stop()
        }
    }
    private var setup: some View {
        Card(title: "Start with an audible question", subtitle: "About 10 minutes · first lesson in harmonic colour") {
            Text(
                "Compare Am7 → Dm7 with A7 → Dm7. Imagine where the changed note wants to go, find it on your instrument, and make a different ending."
            ).font(.system(size: 18)).fixedSize(horizontal: false, vertical: true)
            ChoiceMenu(title: "Instrument", selection: $instrument, options: EditorInstrument.allCases) { $0.rawValue }
                .frame(width: 220)
            HStack {
                Button("Begin the original example", systemImage: "play.fill") {
                    do {
                        try state.beginTensionExample(instrument: instrument)
                        choosing = false
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                    }
                }.buttonStyle(.cadencePrimary)
                Button("Use music from my library", systemImage: "books.vertical") { state.destination = .library }
            }
            Text(
                "For your own music, open Library → Score analysis, select reviewed bars and a local major key, then choose Explore tension. This first lesson follows an applied dominant into its written destination."
            ).font(.callout).foregroundStyle(.secondary)
            Text("Original Cadence examples, with further reading from Open Music Theory. No model key is needed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func header(_ s: TensionSession, piece: LibraryPiece) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(s.source.title).font(.headline)
                Spacer()
                Text(
                    s.independent
                        ? "Independent return · " + s.skill.rawValue : s.instrument.rawValue + " · guided exploration"
                ).font(.caption).foregroundStyle(Color.moss)
                Button(showNotebook ? "Back to activity" : "Score notebook", systemImage: "pencil.and.outline") {
                    if !showNotebook && !s.completed { reveal() }
                    if input.pending == nil { showNotebook.toggle() }
                }.disabled(input.pending != nil)
                Button("Open full piece", systemImage: "arrow.up.right") {
                    if !s.completed { input.submit(.reveal, state: state) }
                    if input.pending == nil { state.openLibraryPiece(piece) }
                }.disabled(input.pending != nil)
            }
            HStack(spacing: 8) {
                ForEach(TheorySkill.allCases, id: \.self) { skill in
                    Text(skill.rawValue).font(.callout.weight(.semibold)).frame(maxWidth: .infinity).padding(
                        .vertical, 9
                    )
                    .foregroundStyle(!s.completed && s.skill == skill ? Color.white : Color.moss)
                    .background(
                        !s.completed && s.skill == skill ? Color.moss : Color.moss.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }
    }
    private func hearing(_ s: TensionSession) -> some View {
        Card(title: "A small change. A different pull.", subtitle: "Listen → imagine → compare") {
            Text(
                "Hear both versions. Which begins with a major-third dominant seventh, rather than a minor seventh? Before answering, imagine or sing the note that follows the changed third."
            ).font(.system(size: 18)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                ForEach(0..<2, id: \.self) { slot in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(slot == 0 ? "A" : "B").font(.system(size: 40, weight: .medium, design: .serif))
                        Text("Two chords · same pace and register").font(.caption).foregroundStyle(.secondary)
                        Button("Listen", systemImage: "speaker.wave.2") {
                            input.submit(.heard(slot), state: state)
                            if input.pending == nil { audio.play(s.source.comparison(majorThird: slot == s.majorSlot)) }
                        }
                        Button("Choose " + (slot == 0 ? "A" : "B")) {
                            audio.stop()
                            input.submit(.hearChoice(slot), state: state)
                        }.buttonStyle(.cadencePrimary).disabled(s.heard != [0, 1])
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(
                        Color.paper, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            Text(
                "These are chord-quality reductions of the selected change, with equal four-beat chords. They do not reproduce every extension or the written rhythm."
            ).font(.caption).foregroundStyle(.secondary)
            Button("Give me a listening clue", systemImage: "lightbulb") { reveal() }
            if s.assisted && s.independent || showReadings {
                Text(
                    "Listen for the first chord’s third moving a semitone upward into the next root. The minor version’s third starts one semitone lower. Hum that small line, then listen again."
                ).foregroundStyle(Color.moss)
            }
            skip
        }
    }
    private func explaining(_ s: TensionSession, piece: LibraryPiece) -> some View {
        Card(
            title: "Why does \(s.source.dominant.label) lead towards \(s.source.destination.label)?",
            subtitle: "Local frame: \(s.source.tonic.name) major · a tonal / jazz reading"
        ) {
            Text(
                "Choose the explanation that fits this chord pair. Then add your own Roman numerals, functional labels and alternative readings to the score."
            ).font(.callout)
            ForEach([1, 0, 2], id: \.self) { option in
                Button {
                    input.submit(.explanation(option), state: state)
                } label: {
                    Text(
                        [
                            "It acts as the dominant of the following chord, briefly making that chord a destination.",
                            "It is the home tonic of the stated key.",
                            "These two chords alone prove a lasting change of key.",
                        ][option]
                    ).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Explore / edit the score analysis", systemImage: "pencil.and.outline") { reveal() }
            if showReadings {
                Text(s.source.reading.roman + " · " + s.source.reading.explanation).font(.callout).foregroundStyle(
                    Color.moss)
                ScoreAnalysisPanel(piece: piece, scope: s.source.scope, showsScore: false)
            }
            Text(
                "A local tonicization is a useful reading here. A complete piece may support other readings; your analysis notebook is not graded against a single label."
            ).font(.caption).foregroundStyle(.secondary)
            skip
        }
    }
    private func playing(_ s: TensionSession) -> some View {
        Card(
            title: "Make the pull audible",
            subtitle: s.instrument == .piano ? "Two single notes · MIDI" : "One moving voice · guitar"
        ) {
            Text(
                "Find the third of \(s.source.dominant.label), then move one semitone up to the root of \(s.source.destination.label). Imagine and sing that little line before you play it."
            ).font(.system(size: 18)).fixedSize(horizontal: false, vertical: true)
            if !s.independent || s.assisted {
                Text(s.source.leadingTone.name + " → " + s.source.resolution.name).font(
                    .system(size: 32, weight: .medium, design: .serif)
                ).foregroundStyle(Color.moss)
                if s.instrument == .piano {
                    Piano(
                        root: s.source.resolution, notes: [s.source.leadingTone, s.source.resolution],
                        degrees: ["third", "root"], showDegrees: false, exactNotes: Set(s.source.melody),
                        play: { audio.note($0) })
                } else {
                    guitar(s)
                }
            }
            if s.instrument == .piano { MIDIConnectionView(midi: midi) }
            HStack {
                Button("Hear / reveal the line", systemImage: "ear") {
                    reveal()
                    if input.pending == nil {
                        audio.play(
                            Score(
                                tempo: 76,
                                notes: s.source.melody.enumerated().map {
                                    ScoreNote(midi: $0.element, start: Double($0.offset) * 2, duration: 1.5)
                                }))
                    }
                }
                if s.instrument == .piano {
                    Button(input.listening ? "Start again" : "Listen to my keyboard", systemImage: "pianokeys") {
                        input.arm(state)
                    }.buttonStyle(.cadencePrimary)
                    Text(input.listening ? "\(input.notes.count) / 2 · release each key" : midi.status).font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("I played the line and shapes", systemImage: "checkmark") {
                        input.submit(.guitarReport, state: state)
                    }.buttonStyle(.cadencePrimary)
                }
            }
            Text(
                s.instrument == .piano
                    ? "Any octave is welcome. Play one note at a time without pedal; the second must be one semitone higher. This checks pitches and order, not timing or expression."
                    : "Your guitar practice is saved as your own report. The app does not infer a chord or fingering from the microphone in this activity."
            ).font(.caption).foregroundStyle(.secondary)
            skip
        }
    }
    private func guitar(_ s: TensionSession) -> some View {
        HStack(alignment: .top, spacing: 28) {
            ForEach([s.source.dominant, s.source.destination].indices, id: \.self) { index in
                let symbol = [s.source.dominant, s.source.destination][index]
                VStack(alignment: .leading, spacing: 8) {
                    Text(symbol.label).font(.headline)
                    if let target = try? ChordRealization(symbol).target(.complete),
                        let shape = target.guitarVoicings(tuning: state.tuning, capo: state.capo).first
                    {
                        ChordDiagram(voicing: shape, root: target.root, tuning: state.tuning, capo: state.capo).frame(
                            width: 150, height: 175)
                        Button("Hear shape") { audio.chord(shape.pitches) }
                    } else {
                        Text("No compact full-chord shape in this tuning. Focus on the two-note line.").font(.caption)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Find a neighbouring pair").font(.headline)
                ForEach(0..<6, id: \.self) { string in
                    let fret = mod(s.source.leadingTone.pc - state.tuning.pitches[string] - state.capo)
                    Text("String \(6-string): fret \(fret) → \(fret+1)").font(.callout.monospacedDigit())
                }
                Text(state.tuning.name + " · capo \(state.capo)\nFrets relative to capo").font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    private func creating(_ s: TensionSession) -> some View {
        Card(title: "Give the phrase another ending", subtitle: "Two bars · your own composition") {
            Text(
                "Keep a little of the original idea. Write an answer that settles on the destination, or change the harmony so it keeps moving. Listen back and describe the choice you made."
            ).font(.system(size: 18)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(
                    state.tensionEnding(s) == nil ? "Write my alternative ending" : "Open my ending",
                    systemImage: "pencil.and.outline"
                ) { do { try state.openTensionEnding() } catch { self.error = error.localizedDescription } }
                .buttonStyle(.cadencePrimary)
                if let ending = state.tensionEnding(s) {
                    Button("Hear my ending", systemImage: "play.fill") { playEnding(ending) }
                }
            }
            Text(
                "Starts with two blank bars and the source chord pair, adapted to 4/4. Edit both notes and chords in Compose. Guitar answers include linked tab."
            ).font(.caption).foregroundStyle(.secondary)
            Text("What did you keep or change? Where does your ending lead?").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $reflection).font(.callout).frame(height: 72).scrollContentBackground(.hidden).padding(9)
                .background(Color.paper, in: RoundedRectangle(cornerRadius: 8)).overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(Color.line)
                )
                .accessibilityLabel("Reflection on my alternative ending")
            Button("Save my reflection & finish", systemImage: "checkmark") {
                input.submit(.creation(reflection), state: state)
            }.disabled(
                state.tensionEnding(s)?.events.contains(where: { !$0.isRest }) != true
                    || reflection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text(
                "Creating is recorded as your reflection and a link to your saved score. There is no automatic artistic-quality grade."
            ).font(.caption).foregroundStyle(.secondary)
            skip
        }
    }
    private func completion(_ s: TensionSession) -> some View {
        Card(title: s.independent ? "A fresh encounter with the same idea." : "A musical idea you can return to.") {
            Text(
                "Hearing, explaining, playing and creating each keep their own review. A hint or retry stays visible in the evidence; an independent first answer can lengthen that skill’s interval."
            ).font(.callout).foregroundStyle(.secondary)
            ForEach(TheorySkill.allCases, id: \.self) { skill in
                HStack {
                    Text(skill.rawValue).font(.headline).frame(width: 100, alignment: .leading)
                    Text(s.reviews[skill.rawValue]?.reason() ?? "Not visited yet").font(.callout)
                    Spacer()
                    Button("Try independently") {
                        do { try state.resumeTension(s.id, skill: skill) } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }.padding(.vertical, 7)
            }
            if !s.reflection.isEmpty { Text(s.reflection).italic().foregroundStyle(Color.moss) }
            HStack {
                if state.tensionEnding(s) != nil {
                    Button("Open my ending") {
                        do { try state.openTensionEnding() } catch { self.error = error.localizedDescription }
                    }
                }
                Button("Explore the score analysis") { showReadings.toggle() }
                Button("Practice home") { state.showPracticeHome() }
            }
            if showReadings, let piece { ScoreAnalysisPanel(piece: piece, scope: s.source.scope) }
            Text(
                "Guitar reports and creative reflections prompt a revisit; they do not count as measured independent performance."
            ).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var skip: some View {
        Button("Skip for now", systemImage: "arrow.right") {
            audio.stop()
            input.submit(.skip, state: state)
        }.buttonStyle(.plain).foregroundStyle(.secondary).font(.caption)
    }
    private func reveal() {
        input.submit(.reveal, state: state)
        if input.pending == nil { showReadings = true }
    }
    private func playEnding(_ document: EditorDocument) {
        do {
            var study = try RehearsalSource.whole(.init(source: .score(document)))
            study.countIn = false
            audio.playStudy(try StudyPlaybackPlan(study: study, wholePiece: true), loop: false)
        } catch { self.error = error.localizedDescription }
    }
}
struct TensionAnswerBar: View {
    @EnvironmentObject private var state: AppState
    let source: TensionSource
    let instrument: EditorInstrument
    var body: some View {
        Card(title: "Your alternative ending", subtitle: source.title, padding: 16, spacing: 10) {
            Text(
                "Keep or change the pull towards \(source.destination.label). Write, play back, then return to reflect on your choice."
            ).font(.callout)
            HStack {
                if let session = state.tensionPractice.sessions.first(where: {
                    $0.source.id == source.id && $0.instrument == instrument
                }) {
                    Button("Return to tension pathway", systemImage: "arrow.uturn.backward") {
                        do { try state.resumeTension(session.id) } catch { state.message = error.localizedDescription }
                    }
                }
                if let piece = state.libraryPieces.first(where: { $0.id == source.pieceID }) {
                    Button("Open original") { state.openLibraryPiece(piece) }
                }
                Text("My compositions · linked to the original").font(.caption).foregroundStyle(Color.moss)
            }
        }
    }
}
