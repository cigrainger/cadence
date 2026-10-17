// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import MusicCore
import SwiftUI

struct FollowChangesView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var midi: MIDIKeyboard
    @ObservedObject var audio: AudioPlayer
    @ObservedObject var session: ChangesSession
    @State private var selected = 0
    @State private var mode = ChangesMode.complete
    @State private var training = false
    @State private var guitar: [Voicing] = []
    @State private var loading = true
    @State private var showFrets = false
    private var plan: ChangesPlan { state.changesPlan }
    private var index: Int { training ? session.practice?.stepIndex ?? 0 : selected }
    private var step: ChangesStep { plan.steps[min(index, plan.steps.count - 1)] }
    private var activeMode: ChangesMode { training ? session.practice?.mode ?? mode : mode }
    private var target: ChangesTarget? { try? step.chord.target(activeMode) }
    private var reveal: Bool { !training || session.practice?.assisted == true || session.practice?.finished == true }
    private var guitarKey: String { "\(plan.id):\(index):\(activeMode):\(state.tuning.pitches):\(state.capo)" }
    private var pianoSequence: [[Int]] {
        var previous: [Int] = []
        return plan.steps.map { step in
            guard let target = try? step.chord.target(activeMode) else {
                previous = []
                return []
            }
            let next = target.pianoVoicings(previous: previous).first ?? []
            previous = next
            return next
        }
    }
    private var pianoNotes: [Int] { pianoSequence[index] }

    var body: some View {
        Group {
            if state.showTimedChanges {
                TimedChangesView(midi: midi, session: state.timedChangesSession)
            } else {
                workspace
            }
        }
    }
    private var workspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "Follow the changes", subtitle: plan.title, padding: 20, spacing: 14) {
                HStack {
                    Text(
                        plan.pieceID == nil
                            ? "ii–V–I in C major · a homecoming in three chords"
                            : "Written symbols · bars \(plan.from+1)–\(plan.through+1) · staff \(plan.staff)"
                    ).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if let id = plan.pieceID {
                        Button("Back to piece") { state.showLibraryPiece(id) }
                        Button("Try ii–V–I") { state.openChanges() }
                    }
                }.controlSize(.small)
                ScrollViewReader { reader in
                    ScrollView(.horizontal) {
                        HStack(spacing: 10) {
                            ForEach(plan.steps.indices, id: \.self) { i in
                                Group {
                                    if training {
                                        chordTile(i)
                                    } else {
                                        Button {
                                            selected = i
                                            audio.stop()
                                        } label: {
                                            chordTile(i)
                                        }.buttonStyle(.plain)
                                    }
                                }.id(i)
                                if i < plan.steps.count - 1 {
                                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }.onChange(of: index) { _, i in withAnimation { reader.scrollTo(i, anchor: .center) } }
                        .onAppear { reader.scrollTo(index, anchor: .center) }
                }
                HStack {
                    Picker("Play", selection: $mode) {
                        ForEach(ChangesMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.frame(width: 280).disabled(training)
                    Spacer()
                    Button("Play in time", systemImage: "metronome") {
                        session.pause(held: midi.keyboard.downNotes)
                        audio.stop()
                        state.showTimedChanges = true
                    }.disabled(session.pending != nil)
                    if training {
                        Button("Explore again") {
                            session.pause(held: midi.keyboard.downNotes)
                            session.reveal()
                            training = false
                        }.disabled(session.pending != nil)
                    } else {
                        Button("Practise these changes", systemImage: "pianokeys") { start() }.buttonStyle(
                            .cadencePrimary
                        ).disabled((try? plan.targets(mode)) == nil || session.pending != nil)
                    }
                }
                Text(activeMode.instruction).font(.callout).foregroundStyle(.secondary)
                if !training, let error = modeError { Text(error).font(.caption).foregroundStyle(Color.clay) }
                if plan.steps.contains(where: { $0.chord.symbol.kind == .none }) {
                    Text(
                        "N.C. marks a break in the harmony. MIDI practice moves between the sounding chords; it does not grade the rests."
                    ).font(.caption).foregroundStyle(.secondary)
                }
            }
            if training { practicePanel }
            if reveal { exploration }
            if let error = session.error {
                Text(error).foregroundStyle(Color.clay).font(.callout).textSelection(.enabled)
            }
            if session.pending != nil {
                HStack {
                    Button("Save answer again") { session.savePending(state: state) }
                    Button("Discard unsaved answer") {
                        session.discardPending()
                        training = false
                    }
                }
            }
            Text(
                "Voicings are suggestions. Your written symbols and notation stay as you wrote them. MIDI checks the notes gathered before all keys are released; rhythm, technique and pedal use are not graded."
            ).font(.caption).foregroundStyle(.secondary)
        }
        .task(id: guitarKey) {
            loading = true
            guitar = []
            let target = target
            let tuning = state.tuning
            let capo = state.capo
            let result = await Task.detached { target?.guitarVoicings(tuning: tuning, capo: capo) ?? [] }.value
            guard !Task.isCancelled else { return }
            guitar = result
            loading = false
        }
        .onAppear {
            if let practice = session.practice, practice.plan.id == plan.id {
                mode = practice.mode
                training = true
            }
            if state.isPreview && CommandLine.arguments.contains("--changes-check") { runPreviewCheck() }
        }
        .onChange(of: mode) { _, _ in audio.stop() }
        .onChange(of: midi.connectionRevision) { _, _ in session.pause(held: midi.keyboard.downNotes) }
        .onChange(of: midi.connected) { _, _ in session.pause(held: midi.keyboard.downNotes) }
        .onChange(of: audio.isPlaying) { _, playing in if playing { session.pause(held: midi.keyboard.downNotes) } }
        .onReceive(midi.updates) { update in
            if training { session.receive(update, state: state, active: state.isPreview || NSApp.isActive) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            session.pause(held: midi.keyboard.downNotes)
        }
        .onDisappear {
            session.pause(held: midi.keyboard.downNotes)
            audio.stop()
        }
    }

    private var modeError: String? {
        do {
            _ = try plan.targets(mode)
            return nil
        } catch { return error.localizedDescription }
    }
    private func chordTile(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(plan.steps[i].chord.symbol.label).font(.system(size: 26, weight: .medium, design: .serif))
            Text(plan.steps[i].position).font(.caption2)
        }.frame(minWidth: 125, alignment: .leading).padding(14)
            .foregroundStyle(index == i ? Color.white : Color.ink)
            .background(index == i ? Color.moss : Color.canvas, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
    }
    private var practicePanel: some View {
        Card(
            title: session.practice?.finished == true ? "You followed the changes" : "Play \(step.chord.symbol.label)",
            subtitle: "Untimed MIDI · \(activeMode.rawValue)", padding: 20, spacing: 12
        ) {
            MIDIConnectionView(midi: midi)
            if let practice = session.practice {
                ProgressView(value: Double(practice.completed), total: Double(practice.targets.count)).tint(Color.moss)
                Text(
                    "\(practice.completed) of \(practice.targets.count) chords matched · \(practice.misses) retries · \(practice.hinted) matched with hints"
                ).font(.caption).foregroundStyle(.secondary)
                if practice.finished {
                    Text(
                        "Each answer is saved in your practice history. Try another voicing, or return to these changes later."
                    ).font(.callout)
                    Button("Another pass", systemImage: "arrow.clockwise") { start() }.buttonStyle(.cadencePrimary)
                } else {
                    Text(
                        session.waitingForRelease
                            ? "Release the held keys before your next answer."
                            : session.listening
                                ? "Play, then release all keys to check and move on."
                                : "Turn on keyboard input when you are ready."
                    ).font(.callout)
                    if let bass = target?.bass { Text("Keep \(bass.name) as the lowest sounding note.").font(.caption) }
                    HStack {
                        Button(
                            session.listening ? "Pause input" : "Listen to keyboard",
                            systemImage: session.listening ? "pause.circle" : "pianokeys"
                        ) {
                            session.listening
                                ? session.pause(held: midi.keyboard.downNotes)
                                : session.listen(held: midi.keyboard.downNotes)
                        }.disabled(!midi.connected || session.pending != nil)
                        Button("Show tones & voicings") { session.reveal() }.disabled(session.pending != nil)
                        Button("Hear example", systemImage: "speaker.wave.2") {
                            session.reveal()
                            hear(pianoNotes)
                        }.disabled(session.pending != nil)
                    }.controlSize(.small)
                    if practice.assisted {
                        Text("This chord will be recorded with hints.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let feedback = session.feedback {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(session.feedbackLabel): " + (feedback.correct ? "matched" : "try again")).foregroundStyle(
                        feedback.correct ? Color.moss : Color.clay
                    ).fontWeight(.medium)
                    if !feedback.missing.isEmpty {
                        Text("Missing: " + names(feedback.missing)).foregroundStyle(Color.clay)
                    }
                    if !feedback.extra.isEmpty {
                        Text("Extra notes: " + names(feedback.extra)).foregroundStyle(Color.clay)
                    }
                    if !feedback.bassCorrect {
                        Text("Check the printed bass and play a complete answer.").foregroundStyle(Color.clay)
                    }
                }.font(.callout).accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    @ViewBuilder private var exploration: some View {
        if let target {
            Card(
                title: "Inside \(step.chord.symbol.label)",
                subtitle: "All written chord tones · selected voicing: \(activeMode.rawValue)", padding: 20, spacing: 14
            ) {
                HStack(spacing: 10) {
                    ForEach(Array(step.chord.tones.enumerated()), id: \.offset) { _, tone in
                        VStack(spacing: 4) {
                            Text(tone.pitch.name).font(.system(size: 23, weight: .medium, design: .serif))
                            Text(tone.label).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(minWidth: 40).padding(10).background(
                            target.pitchClasses.contains(tone.pitch.pc) ? Color.moss.opacity(0.10) : Color.canvas,
                            in: RoundedRectangle(cornerRadius: 9))
                    }
                    Spacer()
                    Button("Hear voicing", systemImage: "play.fill") { hear(pianoNotes) }.buttonStyle(.cadencePrimary)
                }
                if let bass = target.bass {
                    Text("Slash bass: \(bass.name) · keep it below the other tones.").font(.caption).foregroundStyle(
                        .secondary)
                }
                Piano(
                    root: target.root, notes: target.pitches, degrees: [], showDegrees: false,
                    exactNotes: Set(pianoNotes), play: { hear([$0]) }, midiRange: 48...84)
                Text(
                    "Piano suggestion: "
                        + pianoNotes.map { n in
                            Solfege.noteName(
                                midi: n, pitch: target.pitches.first { $0.pc == mod(n) } ?? Pitch.spelled(n))
                        }.joined(separator: " · ")
                ).font(.caption).foregroundStyle(.secondary)
                if index + 1 < plan.steps.count, let next = try? plan.steps[index + 1].chord.target(activeMode) {
                    let common = VoiceLeading.commonTones(target, next)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Into \(plan.steps[index+1].chord.symbol.label)").font(.callout).fontWeight(.medium)
                        Text(
                            common.isEmpty
                                ? "No shared tones in these selected voicings."
                                : "Common tones: " + common.map(\.name).joined(separator: " · ")
                        ).font(.callout).foregroundStyle(Color.moss)
                        if pianoNotes.count == pianoSequence[index + 1].count {
                            Text(
                                zip(pianoNotes, pianoSequence[index + 1]).map { a, b in
                                    "\(names([a])) \(a == b ? "stays" : "→ " + next.pitches.first(where: { $0.pc == mod(b) })!.name)"
                                }.joined(separator: " · ")
                            ).font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Hear the change", systemImage: "play") { hearChange(pianoSequence[index + 1]) }
                            .controlSize(.small)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(
                        Color.canvas, in: RoundedRectangle(cornerRadius: 9))
                }
            }
            Card(
                title: "On the guitar", subtitle: "Compact suggestions · low string at left · frets relative to capo",
                padding: 20, spacing: 12
            ) {
                HStack {
                    TuningPicker().frame(width: 210)
                    Stepper("Capo \(state.capo)", value: $state.capo, in: 0...9).frame(width: 125)
                    Spacer()
                    Toggle("Left handed fretboard", isOn: $state.leftHanded).toggleStyle(.checkbox)
                }.font(.caption)
                if loading {
                    ProgressView().controlSize(.small)
                } else if guitar.isEmpty {
                    Text(
                        "No compact shape contains every selected tone in this tuning. Try shell voicings, or play the piano suggestion."
                    ).font(.callout).foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(Array(guitar.prefix(4).enumerated()), id: \.offset) { i, shape in
                            Button {
                                hear(shape.pitches)
                            } label: {
                                VStack(spacing: 5) {
                                    ChordDiagram(
                                        voicing: shape, root: target.root, tuning: state.tuning, capo: state.capo)
                                    Text(i == 0 ? "Start here" : "Another shape").font(.caption)
                                    Text(shape.label).font(.caption2).foregroundStyle(.secondary)
                                }.padding(10).background(Color.canvas, in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain).frame(maxWidth: 190)
                        }
                    }
                }
                DisclosureGroup("Find all chord tones on the fretboard", isExpanded: $showFrets) {
                    Fretboard(
                        root: target.root, notes: step.chord.tones.map(\.pitch), degrees: step.chord.tones.map(\.label),
                        tuning: state.tuning, capo: state.capo, showDegrees: true, leftHanded: state.leftHanded,
                        play: { hear([$0]) })
                }.font(.caption)
            }
        } else if step.chord.symbol.kind == .none {
            Card(title: "A little space") {
                Text("N.C. means no chord. Let the harmony rest here.").foregroundStyle(.secondary)
            }
        }
    }
    private func names(_ notes: [Int]) -> String {
        notes.map { n in
            step.chord.tones.first { $0.pitch.pc == mod(n) }?.pitch.name
                ?? Pitch.spelled(n, flats: step.chord.tones.contains { $0.pitch.accidental < 0 }).name
        }.joined(separator: " · ")
    }
    private func start() {
        do {
            try state.validateChangesPlan(plan)
            try session.start(plan: plan, mode: mode, held: midi.keyboard.downNotes)
            training = true
            audio.stop()
        } catch { session.error = error.localizedDescription }
    }
    private func hear(_ notes: [Int]) {
        session.pause(held: midi.keyboard.downNotes)
        if training { session.reveal() }
        if !state.isPreview { audio.chord(notes) }
    }
    private func hearChange(_ next: [Int]) {
        session.pause(held: midi.keyboard.downNotes)
        if training { session.reveal() }
        if !state.isPreview {
            audio.play(
                Score(
                    title: "Hear the change", tempo: 72,
                    notes: pianoNotes.map { ScoreNote(midi: $0, start: 0, duration: 1.8) }
                        + next.map { ScoreNote(midi: $0, start: 2, duration: 1.8) }))
        }
    }
    private func runPreviewCheck() {
        midi.installPreview()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            mode = .guides
            start()
            session.listen(held: [])
            @MainActor func gesture(_ notes: [Int]) {
                midi.previewInput(
                    notes.map { .noteOn(channel: 0, note: $0, velocity: 90) }
                        + notes.map { .noteOff(channel: 0, note: $0) })
            }
            let before = state.journal.attempts.count
            gesture([60])
            ChangesDiagnostics.checks["wrongAnswerWaits"] =
                session.practice?.cursor == 0 && session.practice?.misses == 1
            let targets = session.practice?.targets ?? []
            for target in targets { gesture(target.pianoVoicings().first ?? []) }
            ChangesDiagnostics.checks["progressionCompleted"] = session.practice?.finished == true
            ChangesDiagnostics.checks["attemptsSaved"] = state.journal.attempts.count == before + targets.count + 1
            ChangesDiagnostics.checks["hintsSeparated"] = state.journal.attempts.last?.assisted == false
            ChangesDiagnostics.checks["sourceLinked"] =
                state.journal.attempts.last?.pieceID == plan.pieceID
                && state.journal.attempts.last?.scoreFingerprint == plan.fingerprint
            ChangesDiagnostics.checks["voicingsMatch"] = targets.allSatisfy { target in
                target.pianoVoicings().allSatisfy { target.judge($0).correct }
            }
            if CommandLine.arguments.contains("--changes-practice") { start() } else { training = false }
        }
    }
}

@MainActor enum ChangesDiagnostics { static var checks: [String: Bool] = [:] }
