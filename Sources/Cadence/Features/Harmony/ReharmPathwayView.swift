// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct ReharmHomeCard: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: "pianokeys").font(.system(size: 27)).foregroundStyle(Color.moss)
            VStack(alignment: .leading, spacing: 5) {
                Text("Reharmonise and improvise").font(.system(size: 23, weight: .medium, design: .serif))
                Text("Two routes home. Follow the voices, then make a phrase of your own.").font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(state.reharmPractice.active == nil ? "Explore jazz" : "Continue jazz", systemImage: "arrow.right") {
                state.showReharm()
            }.buttonStyle(.cadencePrimary)
        }.padding(22).background(Color.moss.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ReharmPathwayView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var input: ReharmInput
    @ObservedObject var transport: ReharmTransport
    @ObservedObject var midi: MIDIKeyboard
    @State private var instrument = EditorInstrument.piano
    @State private var choosing = false
    @State private var version = ReharmVersion.original
    @State private var layer = ReharmLayer.band
    @State private var tempo = 84
    @State private var offset = 0
    @State private var reflection = ""
    @State private var error: String?
    @State private var notebook = false
    @State private var hint = false
    @State private var alternative: LibraryPiece?
    private var session: ReharmSession? { state.reharmPractice.active }
    private var piece: LibraryPiece? { state.libraryPieces.first { $0.id == session?.source.pieceID } }
    private var locked: Bool { input.pending != nil || transport.pending != nil || transport.busy }
    private func supported(_ s: ReharmSession) -> Bool { !s.independent || s.assisted || s.completed }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button("Back to Learn", systemImage: "arrow.left") { state.showPracticeHome() }.buttonStyle(.plain)
                    .foregroundStyle(Color.moss)
                Spacer()
                Button(choosing ? "Back to study" : "Choose music") {
                    input.pause()
                    choosing.toggle()
                }.disabled(locked || session == nil)
            }
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: "Harmony studio · two routes home").foregroundStyle(Color.clay)
                Text("Reharmonise and improvise").font(.system(size: 34, weight: .medium, design: .serif))
                Text("Keep the voices. Change the bass. Discover a different way to arrive.").foregroundStyle(
                    .secondary)
            }
            recovery
            if choosing || session == nil {
                setup
            } else if let s = session, let piece {
                if !state.reharmCurrent(s.source) {
                    ContentUnavailableView(
                        "Revisit the original", systemImage: "book.closed",
                        description: Text(
                            "The music or source review changed. Your previous study and takes are preserved. Start again from the current piece."
                        ))
                } else {
                    header(s, piece: piece)
                    if notebook {
                        ScoreAnalysisPanel(piece: piece, scope: s.source.scope)
                    } else {
                        score(s, piece: piece)
                        if s.completed {
                            completion(s)
                        } else {
                            activity(s).id("reharm-activity").disabled(input.pending != nil || transport.pending != nil)
                        }
                    }
                }
            } else {
                Text("The original is no longer in the library. Your saved work is preserved.").foregroundStyle(
                    Color.clay)
            }
            if let feedback = input.feedback {
                Label(feedback, systemImage: "ear").font(.callout).foregroundStyle(Color.clay)
            }
            if let message = error ?? input.error ?? transport.error {
                Text(message).font(.callout).foregroundStyle(Color.clay).textSelection(.enabled)
            }
            HStack(spacing: 16) {
                Text("READ & EXPLORE").font(.system(size: 9, weight: .semibold)).tracking(1)
                Link(
                    "OMT · jazz voicings",
                    destination: URL(string: "https://viva.pressbooks.pub/openmusictheory/chapter/jazz-voicings/")!)
                Link("OMT · jazz harmony", destination: URL(string: HarmonyTheory.jazz)!)
                Link(
                    "OMT · improvisation",
                    destination: URL(string: "https://viva.pressbooks.pub/openmusictheory/chapter/chord-scale-theory/")!
                )
            }.font(.caption).foregroundStyle(Color.moss)
        }
        .task(id: session?.source.id) {
            alternative = nil
            if let s = session, !s.independent, [.playing, .creating].contains(s.skill) { version = .substitute }
            if let s = session, let piece, let doc = try? s.source.alternative(in: piece) {
                alternative = .init(source: .score(doc))
            }
        }
        .onReceive(midi.updates) { update in
            input.receive(update, state: state)
            transport.receive(update, state: state)
        }
        .onChange(of: midi.connectionRevision) { _, _ in
            input.pause()
            transport.stop("The MIDI connection changed. Start a fresh take when ready.")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                input.pause()
                transport.stop()
                state.audio.stop()
            }
        }
        .onChange(of: session?.id) { _, _ in
            input.pause()
            transport.stop()
            notebook = false
            hint = false
            reflection = ""
            version = .original
        }
        .onChange(of: session?.skill) { _, _ in
            input.pause()
            transport.stop()
            hint = false
            version =
                session?.independent == false && [.playing, .creating].contains(session?.skill ?? .hearing)
                ? .substitute : .original
        }
        .onChange(of: transport.completedTakeID) { _, id in
            if let id { do { try state.markReharmTakeListened(id) } catch { self.error = error.localizedDescription } }
        }
        .onDisappear {
            input.pause()
            transport.stop()
            state.audio.stop()
        }
    }
    @ViewBuilder private var recovery: some View {
        if input.pending != nil {
            Card(title: "Your answer is still here", padding: 16) {
                Text(input.error ?? "Save or discard this answer before continuing.")
                HStack {
                    Button("Try saving again") { input.save(state) }
                    Button("Discard answer") { input.discard() }
                }
            }
        }
        if let take = transport.pending {
            Card(
                title: "Keep this improvisation",
                subtitle: "\(take.recording.notes.count) notes · \(take.tempo) bpm · \(take.version.rawValue)",
                padding: 16
            ) {
                Text(
                    "Your MIDI performance includes note releases, velocity and sustain. Save it before starting another take."
                ).font(.callout)
                HStack {
                    Button("Save take", systemImage: "square.and.arrow.down") {
                        do {
                            try state.saveReharmTake()
                            error = nil
                        } catch { self.error = error.localizedDescription }
                    }.buttonStyle(.cadencePrimary)
                    Button("Discard unsaved take") { transport.discard() }
                }
            }
        }
    }
    private var setup: some View {
        Card(
            title: "Hear a familiar cadence take another route",
            subtitle: "Guide tones → tritone substitution → your improvisation"
        ) {
            Text(
                "Start with Dm7 → G7 → Cmaj7. Keep the sounding thirds and sevenths, replace G7 with D♭7, and listen to the chromatic bass line."
            ).font(.system(size: 18)).fixedSize(horizontal: false, vertical: true)
            ChoiceMenu(title: "Instrument", selection: $instrument, options: EditorInstrument.allCases) { $0.rawValue }
                .frame(width: 220)
            HStack {
                Button("Begin the original example", systemImage: "play.fill") {
                    do {
                        try state.beginReharmExample(instrument: instrument)
                        choosing = false
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                    }
                }.buttonStyle(.cadencePrimary)
                Button("Use my library", systemImage: "books.vertical") { state.destination = .library }
            }.disabled(locked)
            Text(
                "In Library → Score analysis, choose 1–8 reviewed bars, then Reharmonise. Start with seventh chords and a dominant resolving a fifth down. Scores must support a full editable copy in Compose."
            ).font(.callout).foregroundStyle(.secondary)
            Text(
                "Piano includes MIDI improvisation recording. Guitar offers guide-tone shapes, accompaniment and a self-reported creative response. No model key is needed."
            ).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func header(_ s: ReharmSession, piece: LibraryPiece) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.source.title).font(.headline)
                    Text(
                        s.independent
                            ? "Independent return · " + s.skill.rawValue
                            : s.instrument.rawValue + " · guided exploration"
                    ).font(.caption).foregroundStyle(Color.moss)
                }
                Spacer()
                Button(notebook ? "Back to activity" : "Score notebook", systemImage: "pencil.and.outline") {
                    if expose(s) { notebook.toggle() }
                }.disabled(locked)
                Button("Open full piece", systemImage: "arrow.up.right") {
                    if expose(s) { state.openLibraryPiece(piece) }
                }.disabled(locked)
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
    private func score(_ s: ReharmSession, piece: LibraryPiece) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if s.skill != .hearing || s.completed {
                HStack {
                    ChoiceMenu(title: "Harmony", selection: $version, options: ReharmVersion.allCases) { $0.rawValue }
                        .frame(width: 225).disabled(!supported(s) || transport.busy || input.pending != nil)
                    if !supported(s) {
                        Text("Original score · reveal the study aids when you want support").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if transport.busy { Button("Stop", systemImage: "stop.fill") { transport.stop() } }
                }.disabled(transport.pending != nil || (transport.busy && transport.recording))
            }
            let shown = version == .substitute && supported(s) ? (alternative ?? piece) : piece
            let scope = PassageScope(
                partID: shown.id == piece.id ? s.source.scope.partID : "P1", staff: s.source.scope.staff,
                from: s.source.scope.from, through: s.source.scope.through)
            HarmonicScore(
                piece: shown, scope: scope,
                analysis: supported(s) && shown.id == piece.id && s.skill != .hearing
                    ? state.savedAnalysis(piece) : nil, playhead: playhead(s))
            if transport.busy {
                HStack {
                    ProgressView(value: transport.beat ?? 0, total: s.source.length).tint(Color.moss)
                    Text(
                        transport.preparing
                            ? "Preparing sound…"
                            : transport.elapsed < 0
                                ? "Count in · \(transport.countInRemaining)"
                                : transport.recording ? "Recording your phrase" : "Listening"
                    ).font(.caption).frame(width: 150, alignment: .trailing)
                    Button(transport.recording ? "Cancel recording" : "Stop") { transport.stop() }
                }
            }
        }
    }
    private func playhead(_ s: ReharmSession) -> StudyPlayhead? {
        guard let beat = transport.beat, let piece,
            let study = try? RehearsalSource.whole(piece, partID: s.source.scope.partID)
        else { return nil }
        return .init(
            sourceBeat: study.part.measures[s.source.scope.from].start + beat, isCountIn: transport.elapsed < 0,
            countInRemaining: Double(transport.countInRemaining), cycle: 0)
    }
    @ViewBuilder private func activity(_ s: ReharmSession) -> some View {
        switch s.skill {
        case .hearing: hearing(s)
        case .explaining: explaining(s)
        case .playing: playing(s)
        case .creating: creating(s)
        }
    }
    private func hearing(_ s: ReharmSession) -> some View {
        Card(title: "Which bass approaches home by a semitone?", subtitle: "Listen first · imagine the arrival") {
            Text(
                "Hear both versions of the passage. The guide tones stay the same. Which uses the substitute dominant immediately before its destination?"
            ).font(.callout)
            HStack(spacing: 16) {
                ForEach(0..<2, id: \.self) { slot in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(slot == 0 ? "A" : "B").font(.system(size: 34, weight: .medium, design: .serif))
                        Button("Listen", systemImage: "speaker.wave.2") {
                            transport.stop()
                            input.pause()
                            state.audio.stop()
                            transport.audition(
                                s.source, version: slot == s.substituteSlot ? .substitute : .original, tempo: tempo,
                                layer: .band
                            ) {
                                if state.reharmPractice.active == s, state.destination == .practice,
                                    state.practicePage == .reharm
                                {
                                    input.submit(.heard(slot), state: state)
                                }
                            }
                        }.disabled(transport.pending != nil)
                        Button("Choose " + (slot == 0 ? "A" : "B")) {
                            transport.stop()
                            input.submit(.hearing(slot), state: state)
                        }.buttonStyle(.cadencePrimary).disabled(s.heard != [0, 1] || transport.busy)
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(
                        Color.paper, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            Text(
                "Listen through both versions before choosing. Same tempo and upper voices; one changed bass note. These teaching reductions omit extensions and printed slash basses."
            ).font(.caption).foregroundStyle(.secondary)
            Button("Give me a clue", systemImage: "lightbulb") { _ = expose(s) }.disabled(locked)
            if hint || s.assisted && (s.independent || s.attempts > 0) {
                Text(
                    "The substitute’s root is a semitone above the destination root. Listen for that small downward bass movement."
                ).foregroundStyle(Color.moss).font(.callout)
            }
            skip
        }
    }
    private func explaining(_ s: ReharmSession) -> some View {
        Card(
            title: "A shared sound, a different role",
            subtitle: "\(s.source.dominant.label) → \(s.source.substitute.label)"
        ) {
            Text("Why can these two dominant chords lead towards the same destination?").font(.system(size: 18))
            ForEach([1, 0, 2], id: \.self) { option in
                Button {
                    input.submit(.explanation(option), state: state)
                } label: {
                    Text(
                        [
                            "Their thirds and sevenths form the same sounding pair, exchanging roles.",
                            "They have the same root, with different names.",
                            "Every dominant chord fits every melody equally well.",
                        ][option]
                    ).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }.disabled(transport.busy)
            }
            Button("Reveal the voices", systemImage: "eye") { _ = expose(s) }.disabled(locked)
            if supported(s) {
                guideIdentity(s)
                listeningControls(s)
                Text(
                    "Keep your own reading in the score notebook. Check the melody against the changed harmony; substitutions are musical choices in context."
                ).font(.caption).foregroundStyle(.secondary)
            }
            skip
        }
    }
    private func guideIdentity(_ s: ReharmSession) -> some View {
        let original = (try? ChordRealization(s.source.dominant).tones.filter { [3, 7].contains($0.degree) }) ?? []
        let substitute = (try? ChordRealization(s.source.substitute).tones.filter { [3, 7].contains($0.degree) }) ?? []
        return HStack(spacing: 24) {
            ForEach([original, substitute].indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 5) {
                    Text(i == 0 ? s.source.dominant.label : s.source.substitute.label).font(
                        .system(size: 24, weight: .medium, design: .serif))
                    Text(
                        [original, substitute][i].map { "\($0.pitch.name) · \($0.degree == 3 ? "third" : "seventh")" }
                            .joined(separator: "     ")
                    ).font(.callout).foregroundStyle(Color.moss)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(16).background(Color.moss.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
    private func playing(_ s: ReharmSession) -> some View {
        Card(
            title: "Follow the thirds and sevenths", subtitle: "\(s.source.changes.count) changes · substitute version"
        ) {
            Text(
                "Imagine or sing one moving voice. Then play just the third and seventh of each chord, releasing both before the next pair. Inversions and octave doublings are welcome."
            ).font(.callout)
            if supported(s) {
                guideRoute(s)
                listeningControls(s)
            } else {
                Button("Reveal notes and shapes", systemImage: "eye") { _ = expose(s) }.disabled(locked)
            }
            if s.instrument == .piano {
                MIDIConnectionView(midi: midi)
                HStack {
                    Button(input.listening ? "Start again" : "Listen to my keyboard", systemImage: "pianokeys") {
                        input.arm(state)
                    }.buttonStyle(.cadencePrimary).disabled(locked)
                    Text(
                        input.listening
                            ? "\(input.groups.count) / \(s.source.changes.count) pairs · release between changes"
                            : "Checks chord tones; no timing or fingering grade"
                    ).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button("I played the guide-tone route", systemImage: "checkmark") {
                    input.submit(.guitarReport, state: state)
                }.buttonStyle(.cadencePrimary).disabled(locked)
                Text("Saved as your report. This activity does not recognise guitar chords through the microphone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            skip
        }
    }
    private func guideRoute(_ s: ReharmSession) -> some View {
        let route = (try? s.source.guideVoicings(.substitute)) ?? []
        return ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(s.source.changes.indices, id: \.self) { i in
                    let symbol = s.source.symbol(i, version: .substitute)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(i+1) · \(symbol.label)").font(.system(size: 22, weight: .medium, design: .serif))
                        if let target = try? ChordRealization(symbol).target(.guides) {
                            Text(target.pitches.map(\.name).joined(separator: " · ")).font(.headline).foregroundStyle(
                                Color.moss)
                            if s.instrument == .guitar {
                                if let shape = target.guitarVoicings(tuning: state.tuning, capo: state.capo).first {
                                    ChordDiagram(
                                        voicing: shape, root: target.root, tuning: state.tuning, capo: state.capo
                                    ).frame(width: 155, height: 175)
                                    Button("Hear shape") {
                                        input.pause()
                                        state.audio.chord(shape.pitches)
                                    }.disabled(locked)
                                } else {
                                    Text("Try these two pitches separately in your tuning.").font(.caption)
                                }
                            } else if route.indices.contains(i) {
                                if i > 0 {
                                    VoiceLeadingDiagram(from: route[i - 1], to: route[i], onDark: false).frame(
                                        height: 88)
                                }
                                Text(
                                    route[i].map { Solfege.noteName(midi: $0, pitch: Pitch.spelled($0, flats: false)) }
                                        .joined(separator: " + ")
                                ).font(.caption)
                                Button("Hear pair") {
                                    input.pause()
                                    state.audio.chord(route[i])
                                }.disabled(locked)
                            }
                        }
                    }.frame(width: 195, alignment: .leading).padding(15).background(
                        Color.paper, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
    private func listeningControls(_ s: ReharmSession) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                ChoiceMenu(title: "Listen to", selection: $layer, options: ReharmLayer.allCases) { $0.rawValue }.frame(
                    width: 235)
                Button("Hear original", systemImage: "play.fill") { audition(s, version: .original, layer: layer) }
                Button("Hear substitute", systemImage: "play.fill") { audition(s, version: .substitute, layer: layer) }
                Button("Stop") {
                    transport.stop()
                    state.audio.stop()
                }
            }.disabled(input.pending != nil || transport.pending != nil || transport.recording)
            Text(
                "Written melody uses the first voice of the selected staff. Compare it with the new chord; existing written accompaniment is not automatically rewritten."
            ).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func creating(_ s: ReharmSession) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Card(title: "Keep your alternative, then answer it", subtitle: "One harmonic choice · one short phrase") {
                Text(
                    "Save the substitute in a full copy of the score. Make a short answer that arrives on the next chord’s third; try changing the rhythm or approaching that note from a semitone away."
                ).font(.callout)
                HStack {
                    Button(
                        state.reharmAlternative(s.source) == nil
                            ? "Save my reharmonisation" : "Edit my reharmonisation", systemImage: "pencil.and.outline"
                    ) {
                        do {
                            let doc = try state.saveReharmAlternative()
                            state.returnToCompose(doc.id)
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }.buttonStyle(.cadencePrimary).disabled(locked)
                    if state.reharmAlternative(s.source) != nil {
                        Label("Saved in My compositions", systemImage: "checkmark.circle").font(.caption)
                            .foregroundStyle(Color.moss)
                    }
                }
                Text(
                    "The full score and written notes are preserved. The selected chord symbol changes; edit any written accompaniment in Compose. The listening study below uses generated bass and guide tones from the original passage."
                ).font(.caption).foregroundStyle(.secondary)
                listeningControls(s)
            }
            Card(
                title: s.instrument == .piano ? "Your improvisation" : "Play an answer on guitar",
                subtitle: "Leave space. Repeat an idea. Listen to the arrival."
            ) {
                if s.instrument == .piano {
                    MIDIConnectionView(midi: midi)
                    HStack {
                        ChoiceMenu(title: "Over", selection: $version, options: ReharmVersion.allCases) { $0.rawValue }
                            .frame(width: 220)
                        Stepper("\(tempo) bpm", value: $tempo, in: 60...160, step: 4).frame(width: 145)
                        Stepper("MIDI offset \(offset) ms", value: $offset, in: -300...300, step: 5).frame(width: 200)
                    }.disabled(locked)
                    Button("Record one pass", systemImage: "record.circle") {
                        transport.startRecording(state, version: version, tempo: tempo, offsetMS: offset)
                    }.buttonStyle(.cadencePrimary).disabled(locked || !midi.connected)
                    Text(
                        "Four quarter-note count-in pulses. Release keys and pedal first. Use your keyboard’s own sound while recording. Timing uses MIDI timestamps and the audible accompaniment start; adjust the offset for your current setup. No accuracy or artistic-quality score."
                    ).font(.caption).foregroundStyle(.secondary)
                    takes(s)
                } else {
                    Text(
                        "Use Hear original / Hear substitute as your band. Sing your idea, find it on the guitar, then describe what you heard. MIDI take recording is available in the piano activity; guitar playing is self-reported here."
                    ).font(.callout)
                }
                Text("What changed in your phrase when the harmony changed?").font(.callout.weight(.medium))
                TextEditor(text: $reflection).font(.callout).frame(height: 70).scrollContentBackground(.hidden).padding(
                    9
                ).background(Color.paper, in: RoundedRectangle(cornerRadius: 8)).overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(Color.line)
                ).accessibilityLabel("Reflection on my improvisation")
                Button("Save reflection & finish", systemImage: "checkmark") {
                    input.submit(.creation(reflection), state: state)
                }.disabled(
                    locked || reflection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || state.reharmAlternative(s.source) == nil
                        || (s.instrument == .piano
                            && !state.reharmPractice.takes.contains { $0.sessionID == s.id && $0.listened })
                )
                Text(
                    "Save and listen through a new take for each piano creative return. Your reflection schedules a revisit; it does not count as measured mastery."
                ).font(.caption).foregroundStyle(.secondary)
                skip
            }.id("reharm-recording")
        }
    }
    private func takes(_ s: ReharmSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(state.reharmPractice.takes.filter { $0.source.id == s.source.id }.sorted { $0.date > $1.date }) {
                take in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(take.date, style: .time).font(.headline)
                        Text("\(take.tempo) bpm · recorded over \(take.version.rawValue.lowercased())").font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if take.listened { Image(systemName: "checkmark.circle").foregroundStyle(Color.moss) }
                    }
                    HStack {
                        Button("Replay over original") { replay(take, over: .original, s: s) }
                        Button("Replay over substitute") { replay(take, over: .substitute, s: s) }
                        Button("Delete take", role: .destructive) {
                            do { try state.deleteReharmTake(take.id) } catch { self.error = error.localizedDescription }
                        }
                    }.disabled(locked)
                    if take.listened { Text(take.observation).font(.caption).foregroundStyle(Color.moss) }
                    if transport.completedTakeID == take.id && !take.listened {
                        Button("Save listening progress") {
                            do { try state.markReharmTakeListened(take.id) } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                }.padding(14).background(Color.paper, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
    private func completion(_ s: ReharmSession) -> some View {
        Card(title: s.independent ? "Another encounter with the same idea." : "Two routes, and a phrase of your own.") {
            Text(
                "Your hearing, explanation, instrument work and creative reflection each keep their own review. A supported retry stays separate from a clean independent answer."
            ).font(.callout).foregroundStyle(.secondary)
            ForEach(TheorySkill.allCases, id: \.self) { skill in
                HStack {
                    Text(skill.rawValue).font(.headline).frame(width: 100, alignment: .leading)
                    Text(s.reviews[skill.rawValue]?.reason() ?? "Not visited yet").font(.callout)
                    Spacer()
                    Button("Try independently") {
                        do { try state.resumeReharm(s.id, skill: skill) } catch {
                            self.error = error.localizedDescription
                        }
                    }.disabled(locked)
                }.padding(.vertical, 6)
            }
            if !s.reflection.isEmpty { Text(s.reflection).italic().foregroundStyle(Color.moss) }
            if let document = state.reharmAlternative(s.source) {
                Button("Open my reharmonisation") { state.returnToCompose(document.id) }.disabled(locked)
            }
            takes(s)
        }
    }
    private var skip: some View {
        Button("Skip for now", systemImage: "arrow.right") { input.submit(.skip, state: state) }.buttonStyle(.plain)
            .font(.caption).foregroundStyle(.secondary).disabled(locked)
    }
    private func expose(_ s: ReharmSession) -> Bool {
        guard !locked else { return false }
        if !s.completed { input.submit(.reveal, state: state) }
        if input.pending == nil { hint = true }
        return input.pending == nil
    }
    private func audition(_ s: ReharmSession, version: ReharmVersion, layer: ReharmLayer) {
        do {
            input.pause()
            state.audio.stop()
            if s.skill != .hearing { self.version = version }
            let melody = layer == .melody ? try piece.map { try s.source.writtenMelody(in: $0) } ?? [] : []
            transport.audition(s.source, version: version, tempo: tempo, layer: layer, melody: melody)
        } catch { self.error = error.localizedDescription }
    }
    private func replay(_ take: ReharmTake, over version: ReharmVersion, s: ReharmSession) {
        guard expose(s) else { return }
        input.pause()
        state.audio.stop()
        self.version = version
        transport.replay(take, over: version)
    }
}

struct ReharmAnswerBar: View {
    @EnvironmentObject private var state: AppState
    let source: ReharmSource
    var body: some View {
        Card(title: "Your reharmonisation", subtitle: source.title, padding: 16, spacing: 10) {
            Text(
                "A full copy with an alternative chord symbol. Written notes are unchanged until you edit them. Return to the study to hear generated accompaniment and record your response."
            ).font(.callout)
            HStack {
                if let session = state.reharmPractice.sessions.first(where: {
                    $0.source.id == source.id && $0.id == state.reharmPractice.activeID
                }) ?? state.reharmPractice.sessions.first(where: { $0.source.id == source.id }) {
                    Button("Return to jazz study", systemImage: "arrow.uturn.backward") {
                        do { try state.resumeReharm(session.id) } catch { state.message = error.localizedDescription }
                    }
                }
                if let original = state.libraryPieces.first(where: { $0.id == source.pieceID }) {
                    Button("Open original") { state.openLibraryPiece(original) }
                }
                Text("My compositions · linked to the original").font(.caption).foregroundStyle(Color.moss)
            }
        }
    }
}
