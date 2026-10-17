// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct TriadHomeCard: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: "guitars").font(.system(size: 27)).foregroundStyle(Color.clay)
            VStack(alignment: .leading, spacing: 5) {
                Text("Triads across the neck").font(.system(size: 23, weight: .medium, design: .serif))
                Text("Your music → three strings → a phrase of your own").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(
                state.triadPractice.active == nil ? "Explore on guitar" : "Continue on guitar",
                systemImage: "arrow.right"
            ) { state.showTriads() }.buttonStyle(.cadencePrimary)
        }.padding(22).background(Color.clay.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
}
struct TriadPathwayView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var input: TriadInput
    @ObservedObject var microphone: Microphone
    @ObservedObject var audio: AudioPlayer
    @State private var choosing = false
    @State private var pieceID = ""
    @State private var partID = "P1"
    @State private var staff = 1
    @State private var from = 1
    @State private var through = 4
    @State private var group = 0
    @State private var browseInversion = TriadInversion.root
    @State private var reveal = false
    @State private var error: String?
    private var session: TriadSession? { state.triadPractice.active }
    private var piece: LibraryPiece? { state.libraryPieces.first { $0.id == pieceID } }
    private var parts: [(String, String)] {
        if case .study(let study) = piece?.source { return study.document.parts.map { ($0.id, $0.name) } }
        return [("P1", "Guitar / piano score")]
    }
    private var barCount: Int {
        if case .study(let study) = piece?.source {
            return study.document.parts.first { $0.id == partID }?.measures.count ?? 1
        }
        return piece?.bars ?? 1
    }
    private var source: ChangesSource? {
        guard let piece else { return nil }
        return try? ChangesSource(piece: piece, from: from - 1, through: through - 1, partID: partID)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Button("Back to Learn", systemImage: "arrow.left") { state.showPracticeHome() }.buttonStyle(.plain)
                    .foregroundStyle(Color.moss)
                Spacer()
                Button(choosing ? "Back to session" : "Choose music / string set", systemImage: "slider.horizontal.3") {
                    stop()
                    choosing.toggle()
                }.disabled(session == nil || input.pending != nil)
            }
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(text: "Guitar · hear the shape").foregroundStyle(Color.clay)
                Text("Triads across the neck").font(.system(size: 34, weight: .medium, design: .serif))
                Text("Three notes. Many places. One connected musical idea.").foregroundStyle(.secondary)
            }
            if input.pending != nil {
                Card(title: "Your answer is waiting to be saved", padding: 16) {
                    Text(input.error ?? "Try saving again before continuing.").font(.callout)
                    HStack {
                        Button("Try saving again") { input.save(state) }.buttonStyle(.cadencePrimary)
                        Button("Discard unsaved answer") { input.discard() }
                    }
                }
            }
            if choosing || session == nil {
                setup
            } else if let session {
                sessionHeader(session)
                if !state.triadCurrent(session.material) {
                    ContentUnavailableView(
                        "Revisit the source", systemImage: "book.closed",
                        description: Text(
                            "This piece has changed or its original pages need review. Your previous work is kept. Choose the music again to start from its current version."
                        ))
                } else {
                    Group {
                        switch session.stage {
                        case .find: find(session)
                        case .connect: connect(session)
                        case .ear: ear(session)
                        case .create: creative(session)
                        case .complete: complete(session)
                        }
                    }.disabled(input.pending != nil)
                }
            }
            if let feedback = input.feedback {
                Label(feedback, systemImage: "ear").font(.callout).foregroundStyle(Color.clay).fixedSize(
                    horizontal: false, vertical: true)
            }
            if let error = error ?? input.error ?? microphone.error ?? audio.error {
                Text(error).font(.callout).foregroundStyle(Color.clay).textSelection(.enabled)
            }
        }
        .onChange(of: pieceID) { _, _ in resetSelection() }
        .onChange(of: partID) { _, _ in
            from = 1
            through = min(4, barCount)
            staff = source?.staffs.first ?? 1
        }
        .onChange(of: from) { _, _ in through = min(barCount, max(from, min(through, from + 7))) }
        .onChange(of: session?.stage) { _, _ in
            stop()
            reveal = false
        }
        .onChange(of: session?.cursor) { _, _ in reveal = false }
        .onReceive(microphone.detections) { input.receive($0.0, at: $0.1, state: state) }
        .onChange(of: audio.isPlaying) { _, playing in
            if playing {
                input.pause()
                microphone.stop()
            }
        }
        .onChange(of: microphone.listening) { _, listening in if !listening { input.pause() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { stop() } }
        .onDisappear { stop() }
        .onAppear {
            if pieceID.isEmpty { pieceID = session?.material.pieceID ?? state.libraryPieces.first?.id ?? "" }
            if session == nil || CommandLine.arguments.contains("--triad-setup") { choosing = true }
        }
    }
    private var setup: some View {
        Card(title: "Start with a piece you know", subtitle: "About 10 minutes") {
            Text(
                "Choose a reviewed passage with written chord symbols. We’ll explore its root, third and fifth; sevenths, extensions and slash bass remain in the original score."
            ).font(.callout).foregroundStyle(.secondary)
            if state.libraryPieces.isEmpty {
                Text("Add a composition or import a piece, then add or review its chord symbols.")
                Button("Open library", systemImage: "books.vertical") { state.destination = .library }
            } else {
                ChoiceMenu(title: "Piece", selection: $pieceID, options: state.libraryPieces.map(\.id)) { id in
                    state.libraryPieces.first { $0.id == id }?.title ?? "Choose a piece"
                }
                HStack {
                    ChoiceMenu(title: "Part", selection: $partID, options: parts.map(\.0)) { id in
                        parts.first { $0.0 == id }?.1 ?? id
                    }
                    ChoiceMenu(title: "Harmony staff", selection: $staff, options: source?.staffs ?? [1]) {
                        "Harmony staff \($0)"
                    }
                    Stepper("From \(from)", value: $from, in: 1...max(1, barCount))
                    Stepper("Through \(through)", value: $through, in: from...max(from, min(barCount, from + 7)))
                }
                HStack {
                    ChoiceMenu(title: "String set", selection: $group, options: Array(0...3)) { TriadNeck.sets[$0] }
                    TuningPicker()
                    Stepper("Capo \(state.capo)", value: $state.capo, in: 0...9).fixedSize()
                }
                Text(
                    "String 1 is the highest string. Shapes use frets 0–12 relative to the capo; tuning and capo are saved with this pathway."
                ).font(.caption).foregroundStyle(.secondary)
                Button("Find my triads", systemImage: "guitars") {
                    do {
                        guard let piece else { return }
                        try state.beginTriads(
                            piece: piece,
                            scope: .init(partID: partID, staff: staff, from: from - 1, through: through - 1),
                            group: group)
                        choosing = false
                        error = nil
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.cadencePrimary).disabled(input.pending != nil)
                if source == nil {
                    Text(
                        "No chord symbols in this selection yet. Open the full piece and add them in Compose, or select another passage."
                    ).font(.caption).foregroundStyle(Color.clay)
                }
            }
        }
    }
    private func sessionHeader(_ session: TriadSession) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.material.title).font(.headline)
                    Text(
                        session.material.label + " · " + session.material.tuning.name
                            + " · capo \(session.material.capo)"
                    ).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open full piece", systemImage: "arrow.up.right") {
                    if let original = state.libraryPieces.first(where: { $0.id == session.material.pieceID }) {
                        state.openLibraryPiece(original)
                    }
                }
            }
            HStack(spacing: 8) {
                ForEach(Array(TriadStage.allCases.dropLast().enumerated()), id: \.offset) { i, stage in
                    HStack(spacing: 7) {
                        Text(String(i + 1)).font(.caption.monospacedDigit())
                        Text(["Find", "Connect", "Hear", "Create"][i]).font(.callout.weight(.semibold))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9).frame(maxWidth: .infinity)
                    .foregroundStyle(session.stage == stage ? Color.white : Color.moss)
                    .background(
                        session.stage == stage ? Color.moss : Color.moss.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                    .accessibilityLabel(stage.title + (session.stage == stage ? ", current step" : ""))
                }
            }
        }
    }
    private func find(_ session: TriadSession) -> some View {
        let m = session.material
        let change = m.changes[session.cursor]
        let shape = m.route[session.cursor]
        return Card(title: "Which note is underneath?", subtitle: "\(session.cursor+1) of \(m.changes.count) changes") {
            HStack(alignment: .top, spacing: 26) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(change.triadName + " triad").font(.system(size: 38, weight: .medium, design: .serif))
                    Text(
                        "From \(change.symbol.label) · bar \(change.bar+1)"
                            + (change.carried ? " · chord carried in" : "")
                    ).font(.caption).foregroundStyle(.secondary)
                    Text(
                        "Play these three strings, then name the inversion by the lowest sounding note. Keep the other strings quiet."
                    ).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Button("Hear the shape", systemImage: "speaker.wave.2") { hear(shape.notes) }
                    Button(reveal ? "Hide note names" : "Show the notes", systemImage: "eye") { reveal.toggle() }
                    if reveal {
                        Text(zip([1, 3, 5], change.tones).map { "\($0.0) · \($0.1.name)" }.joined(separator: "   "))
                            .font(.callout).foregroundStyle(Color.moss)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                ChordDiagram(voicing: shape.voicing, root: change.tones[0], tuning: m.tuning, capo: m.capo).frame(
                    width: 190, height: 200)
            }
            HStack {
                ForEach(TriadInversion.allCases, id: \.self) { answer in
                    Button {
                        input.submit(.inversion(answer), state: state)
                    } label: {
                        VStack(spacing: 5) {
                            Text(answer.label)
                            Text("\(answer.bassDegree) in the bass").font(.caption).fontWeight(.regular)
                        }.frame(maxWidth: .infinity)
                    }
                }
            }
            Text("This is a shape-reading check. Cadence isn’t listening to the chord.").font(.caption).foregroundStyle(
                .secondary)
            skip
        }
    }
    private func connect(_ session: TriadSession) -> some View {
        let m = session.material
        return VStack(alignment: .leading, spacing: 18) {
            Card(title: "Keep a note. Move a little.", subtitle: "A suggested route") {
                Text(
                    "Follow each string into the next chord. The numbers show total fret movement across the three strings; your hand decides what feels comfortable. The demonstration gives each chord four beats."
                ).font(.callout).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(m.route.indices, id: \.self) { i in
                            VStack(spacing: 9) {
                                Text(m.changes[i].triadName).font(.system(size: 24, weight: .medium, design: .serif))
                                Text("from \(m.changes[i].symbol.label)").font(.caption).foregroundStyle(.secondary)
                                ChordDiagram(
                                    voicing: m.route[i].voicing, root: m.changes[i].tones[0], tuning: m.tuning,
                                    capo: m.capo
                                ).frame(width: 145, height: 170)
                                Text(m.route[i].inversion.label).font(.caption)
                                Button("Hear", systemImage: "speaker.wave.2") { hear(m.route[i].notes) }
                                if i > 0 {
                                    Text("\(TriadNeck.movement(m.route[i-1],m.route[i])) frets of movement").font(
                                        .caption
                                    ).foregroundStyle(Color.moss)
                                }
                            }.frame(width: 160)
                        }
                    }
                }
                HStack {
                    Button("Hear the route", systemImage: "play.fill") { playRoute(m) }
                    Button("I tried these changes", systemImage: "arrow.right") {
                        input.submit(.connected, state: state)
                    }.buttonStyle(.cadencePrimary)
                }
                Text(
                    "Play slowly, listen for the top line, then repeat with less looking. This saves your own report of practice."
                ).font(.caption).foregroundStyle(.secondary)
                skip
            }
            Card(title: "Another inversion, same chord", padding: 18) {
                ChoiceMenu(title: "Inversion", selection: $browseInversion, options: TriadInversion.allCases) {
                    $0.label
                }
                let shapes = TriadNeck.shapes(m.changes[0].tones, tuning: m.tuning, capo: m.capo, group: m.group).filter
                { $0.inversion == browseInversion }
                if let shape = shapes.first {
                    Fretboard(
                        root: m.changes[0].tones[0], notes: m.changes[0].tones, degrees: ["1", "3", "5"],
                        tuning: m.tuning, capo: m.capo, showDegrees: true, leftHanded: state.leftHanded,
                        play: { hear([$0]) },
                        exactFrets: Dictionary(
                            uniqueKeysWithValues: shape.frets.enumerated().filter { $0.element >= 0 }.map {
                                ($0.offset, $0.element)
                            }))
                } else {
                    Text("This inversion has no compact shape in frets 0–12 on this string set. Try another set.").font(
                        .callout)
                }
            }
        }
    }
    private func ear(_ session: TriadSession) -> some View {
        let m = session.material
        return Card(title: "Hear it. Imagine it. Find it.", subtitle: "Single-note guitar · local microphone") {
            Text(
                "Listen to the root and third of \(m.changes[0].symbol.label), then imagine the interval in silence. Sing it if you like. Find those two pitches on your guitar before looking at the notes."
            ).font(.system(size: 17)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Hear the two notes", systemImage: "ear") {
                    stop()
                    audio.play(
                        Score(
                            tempo: 72,
                            notes: m.earNotes.enumerated().map {
                                ScoreNote(midi: $0.element, start: Double($0.offset) * 1.5, duration: 1)
                            }))
                }
                Button(reveal ? "Hide notes" : "Reveal notes", systemImage: "eye") { reveal.toggle() }
            }
            if reveal {
                Text(m.earNotes.map { Solfege.noteName(midi: $0, pitch: Pitch.spelled($0)) }.joined(separator: " → "))
                    .font(.system(size: 26, weight: .medium, design: .serif)).foregroundStyle(Color.moss)
            }
            HStack(spacing: 18) {
                Image(systemName: input.listening ? "waveform" : "mic").font(.system(size: 30)).foregroundStyle(
                    Color.clay)
                VStack(alignment: .leading, spacing: 5) {
                    Text(
                        input.listening
                            ? "Listening for two separate notes…"
                            : input.notes.isEmpty ? "Ready when you are" : "Two notes captured"
                    ).font(.headline)
                    Text("\(input.notes.count) / 2 notes · let each ring for at least half a second").font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if input.listening {
                    Button("Stop listening") {
                        input.pause()
                        microphone.stop()
                    }
                } else {
                    Button(input.notes.isEmpty ? "Listen to my guitar" : "Try another take", systemImage: "mic.fill") {
                        input.arm(state)
                        Task {
                            await microphone.start(forTuner: true)
                            if !input.listening { microphone.stop() }
                            if !microphone.listening { input.pause() }
                        }
                    }.buttonStyle(.cadencePrimary)
                }
            }.padding(20).background(Color.moss.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            Text(
                "Use headphones, mute unused strings and pluck one note at a time. Pitch matching uses the demonstrated octave and A = 440 Hz. It cannot identify which string you used, or assess strummed chords or timing. Audio stays on this Mac."
            ).font(.caption).foregroundStyle(.secondary)
            if !input.notes.isEmpty {
                Button("Check these pitches") { input.submit(.microphone(input.notes), state: state) }.buttonStyle(
                    .cadencePrimary
                ).disabled(input.notes.count != 2)
            }
            skip
        }
    }
    private func creative(_ session: TriadSession) -> some View {
        Card(title: "Answer the changes", subtitle: "Two bars · your own idea") {
            Text(
                session.material.changes.count > 1
                    ? "Choose two chords from your route. Make a short phrase that lands on the third of the second chord. Leave a little space; repeat one idea and change its ending."
                    : "Stay with this chord. Make a short call and answer, landing on its third. Leave a little space; repeat one idea and change its ending."
            ).font(.system(size: 18)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Hear my route", systemImage: "play.fill") { playRoute(session.material) }
                Button("Write a two-bar answer", systemImage: "pencil.and.outline") {
                    do { try state.openTriadAnswer() } catch { self.error = error.localizedDescription }
                }
            }
            Text(
                "Play freely on your guitar, or use Compose to write, hear and save notation with linked tab. A written answer keeps its original-piece link and starts with the first two chord symbols, one per bar in 4/4—an adaptation you can change."
            ).font(.callout).foregroundStyle(.secondary)
            Button("I improvised an answer", systemImage: "checkmark") { input.submit(.finish, state: state) }
                .buttonStyle(.cadencePrimary)
            Text("Your reflection is saved as self-reported practice, without a performance score.").font(.caption)
                .foregroundStyle(.secondary)
            skip
        }
    }
    private func complete(_ session: TriadSession) -> some View {
        Card(title: "A small part of the neck, made familiar.") {
            Text(
                "You’ve reached the end of this session. Come back to these shapes, then choose a neighbouring string set and find the same notes somewhere new."
            ).font(.system(size: 18)).fixedSize(horizontal: false, vertical: true)
            Text(session.review.reason()).foregroundStyle(Color.moss)
            Text(
                "The review is a reminder to revisit supported practice. Shape choices, microphone pitches and your own reports remain separate in your history."
            ).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Try another string set") {
                    group = (session.material.group + 1) % 4
                    choosing = true
                }
                Button("Revisit these shapes") {
                    do { try state.resumeTriads(session.id, restart: true) } catch {
                        self.error = error.localizedDescription
                    }
                }
                Button("Open my written answer") {
                    do { try state.openTriadAnswer() } catch { self.error = error.localizedDescription }
                }
            }
        }
    }
    private var skip: some View {
        Button("Skip this step for now", systemImage: "arrow.right") { input.submit(.skip, state: state) }.buttonStyle(
            .plain
        ).font(.caption).foregroundStyle(.secondary)
    }
    private func stop() {
        input.pause()
        microphone.stop()
        audio.stop()
    }
    private func hear(_ notes: [Int]) {
        stop()
        audio.chord(notes)
    }
    private func playRoute(_ m: TriadMaterial) {
        stop()
        audio.play(
            Score(
                tempo: 72,
                notes: m.route.enumerated().flatMap { i, shape in
                    shape.notes.map { ScoreNote(midi: $0, start: Double(i) * 4, duration: 3.5) }
                }))
    }
    private func resetSelection() {
        partID = parts.first?.0 ?? "P1"
        from = 1
        through = min(4, barCount)
        staff = source?.staffs.first ?? 1
    }
}

struct TriadLibraryButton: View {
    @EnvironmentObject private var state: AppState
    let piece: LibraryPiece
    let from: Int
    let through: Int
    let partID: String?
    private var source: ChangesSource? {
        try? ChangesSource(piece: piece, from: from, through: through, partID: partID)
    }
    var body: some View {
        Menu {
            ForEach(source?.staffs ?? [1], id: \.self) { staff in
                Section("Harmony staff \(staff)") {
                    ForEach(0..<4, id: \.self) { group in
                        Button(TriadNeck.sets[group]) {
                            do {
                                try state.beginTriads(
                                    piece: piece,
                                    scope: .init(
                                        partID: source?.partID ?? "P1", staff: staff, from: from, through: through),
                                    group: group)
                            } catch { state.message = error.localizedDescription }
                        }
                    }
                }
            }
        } label: {
            Label("Triads across the neck", systemImage: "guitars").padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.paper, in: RoundedRectangle(cornerRadius: 9)).overlay(
                    RoundedRectangle(cornerRadius: 9).stroke(Color.line))
        }
        .menuStyle(.borderlessButton).fixedSize().disabled(source == nil).help(
            "Choose up to eight reviewed bars with chord symbols, then a three-string set.")
    }
}
struct TriadAnswerBar: View {
    @EnvironmentObject private var state: AppState
    let material: TriadMaterial
    var body: some View {
        Card(title: "Your guitar answer", subtitle: material.title, padding: 16, spacing: 10) {
            Text(
                "A two-bar idea inspired by \(material.label.lowercased()). Land on a third, leave space, and make the ending yours."
            ).font(.callout)
            HStack {
                if let session = state.triadPractice.sessions.first(where: { $0.material.id == material.id }) {
                    Button("Return to guitar pathway", systemImage: "arrow.uturn.backward") {
                        do { try state.resumeTriads(session.id) } catch { state.message = error.localizedDescription }
                    }
                }
                if let piece = state.libraryPieces.first(where: { $0.id == material.pieceID }) {
                    Button("Open original", systemImage: "arrow.up.right") { state.openLibraryPiece(piece) }
                }
                Text("Saved in My compositions · linked to the original").font(.caption).foregroundStyle(Color.moss)
            }
        }
    }
}
