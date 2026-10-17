// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct ShapePhrasePanel: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var session: PieceRehearsalSession
    @ObservedObject var midi: MIDIKeyboard
    @State private var reflection = PhraseReflection.unsure
    @State private var listeningNote = ""
    @State private var error: String?
    @State private var library = false
    @State private var tempo = 65
    private var take: PianoTake? { state.rehearsalTakes.first { $0.id == session.selectedTakeID } }
    private var comparison: PianoTake? { candidates.first { $0.id == session.comparisonTakeID } }
    private var candidates: [PianoTake] {
        guard let take else { return [] }
        return state.rehearsalTakes.filter { $0.id != take.id && $0.comparable(to: take) }
    }
    private var locked: Bool {
        session.timing.busy || session.timing.hasUnsavedResult || session.takePlayer.busy || state.audio.isPlaying
            || state.audio.isPreparing
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Eyebrow(text: "Listen · notice · shape").foregroundStyle(Color.moss)
            Text("Shape the phrase").font(.system(size: 26, weight: .medium, design: .serif))
            if let record = state.currentRehearsal, !state.rehearsalCurrent(record) {
                Text(
                    "The score has changed or needs review. Your takes are kept, but playback is paused until you choose a current reviewed phrase."
                ).font(.callout).foregroundStyle(Color.clay)
            }
            Text("Imagine a connected line. After playing, hear your take before looking closely at the joins.").font(
                .callout
            ).foregroundStyle(.secondary)
            if let take {
                Text("Take A").font(.caption.weight(.medium)).foregroundStyle(Color.moss)
                Picker("Your take", selection: $session.selectedTakeID) {
                    ForEach(state.rehearsalTakes) { item in Text(takeLabel(item)).tag(Optional(item.id)) }
                }.labelsHidden().disabled(locked)
                Text(
                    scopeLabel(take)
                        + " · \(take.pass.plan.tempo) bpm\n\(take.phase.title) · \(take.pass.conditions.flowPulse?.rawValue ?? (take.pass.conditions.click ? "with click" : "without click"))\nPartner \(take.pass.conditions.partnerStaff.map { "staff \($0)" } ?? "off")"
                ).font(.caption).foregroundStyle(.secondary)
                if session.takePlayer.busy {
                    Text(
                        session.takePlayer.preparing
                            ? "Preparing piano…"
                            : session.takePlayer.take?.id == take.id ? "Listening to A" : "Listening to B"
                    ).font(.caption.weight(.semibold)).foregroundStyle(Color.moss)
                    Button(
                        session.takePlayer.preparing ? "Cancel preparation" : "Stop listening", systemImage: "stop.fill"
                    ) { session.takePlayer.stop() }
                } else {
                    Button("Listen to A", systemImage: "play.fill") { perform { try state.playPianoTake(take.id) } }
                        .buttonStyle(.cadencePrimary).disabled(locked)
                }
                if !candidates.isEmpty {
                    Text("Compare with B").font(.caption.weight(.medium)).foregroundStyle(Color.moss)
                    Picker("Compare with", selection: $session.comparisonTakeID) {
                        Text("Choose another take").tag(Optional<UUID>.none)
                        ForEach(candidates) { item in Text(takeLabel(item)).tag(Optional(item.id)) }
                    }.labelsHidden().disabled(locked)
                    if let comparison {
                        Button("Listen to B · \(comparison.pass.plan.tempo) bpm", systemImage: "play.fill") {
                            perform { try state.playPianoTake(comparison.id) }
                        }.disabled(locked)
                        Text(
                            "Same bars, staves, flow click and partner setting · original timing and touch. \(take.pass.plan.tempo == comparison.pass.plan.tempo ? "Same practice tempo." : "Different practice tempos; compare the sound, not a score.")"
                        ).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Another take of these same bars will appear here for comparison.").font(.caption)
                        .foregroundStyle(.secondary)
                }
                if take.listenedAt != nil {
                    Divider()
                    Text("What did you hear?").font(.headline)
                    Picker("Listening reflection", selection: $reflection) {
                        ForEach(PhraseReflection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden()
                    TextField("A moment to remember…", text: $listeningNote, axis: .vertical).lineLimit(2...4)
                    Button("Save reflection") {
                        perform { try state.reflectOnPianoTake(take.id, reflection: reflection, note: listeningNote) }
                    }.disabled(locked)
                    if take.reflection != nil { observations(take) }
                } else {
                    Text(
                        "Listen through A, then leave a reflection to open the observations. There is no expression score."
                    ).font(.callout).foregroundStyle(Color.moss)
                }
                if take.recording.notes.contains(where: \.clipped) {
                    Text(
                        "Some note endings were not fully captured. Playback closes them at the next press or recording boundary; missing releases are not assessed."
                    ).font(.caption).foregroundStyle(Color.clay)
                }
                if take.recording.events.contains(where: \.arrivalTimestamp) {
                    Text(
                        "Some MIDI events used arrival time. Listen-back is available; precise join measurements are withheld."
                    ).font(.caption).foregroundStyle(Color.clay)
                }
            } else {
                Text(
                    "Your next piano pass will be saved here, including key releases, touch and sustain pedal. Opening, focused and return passes all keep a take."
                ).font(.callout)
                Text(
                    "Use a piano or keyboard part and 1–8 bars, with one or both staves. Previous releases saved entrance summaries only; they cannot be replayed."
                ).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            connectedExercise
            Button("Back to practice", systemImage: "arrow.left") { perform { try state.showPhraseShaping(false) } }
                .disabled(locked)
            Button("Manage saved takes…") { library = true }.font(.caption).disabled(
                session.timing.busy || session.takePlayer.busy)
            if let message = error ?? session.takePlayer.error {
                Text(message).font(.caption).foregroundStyle(Color.clay)
            }
        }
        .onAppear {
            loadReflection()
            tempo = max(40, (state.currentRehearsal?.opening.tempo ?? 80) - 15)
        }
        .onChange(of: take?.id) { _, _ in
            loadReflection()
            if comparison == nil { session.comparisonTakeID = nil }
        }
        .sheet(isPresented: $library) { PianoTakeLibraryView() }
    }
    @ViewBuilder private var connectedExercise: some View {
        if let record = state.currentRehearsal {
            Text(record.phraseIntention?.rawValue ?? "Try a connected melody").font(.headline)
            if record.stage == .focus && record.opening.handStaves == nil {
                Text(
                    "Hear the next note inwardly. Let the line pass from one key to the next; keep the written rests. Try without pedal first if that feels comfortable."
                ).font(.callout)
                Stepper(
                    "\(record.flow?.tempo ?? tempo) bpm",
                    value: Binding(
                        get: { record.flow?.tempo ?? tempo },
                        set: { value in
                            if var flow = record.flow {
                                flow.tempo = value
                                perform { try state.configureRehearsalFlow(flow) }
                            } else {
                                tempo = value
                            }
                        }), in: 40...record.opening.tempo, step: 5
                ).disabled(locked)
                Button("Record a connected melody", systemImage: "record.circle") {
                    perform {
                        try state.startRehearsal(exercise: .connected, tempo: tempo, input: .midi)
                        session.shaping = false
                    }
                }.buttonStyle(.cadencePrimary).disabled(locked || !midi.connected)
                Text(
                    "The selected practice support stays with this pass. Written rests, repeated pitches, chords and detached notes are excluded from join observations."
                ).font(.caption).foregroundStyle(.secondary)
            } else if record.opening.handStaves != nil {
                Text(
                    "Listen for how the parts fit together. Your take contains your own playing; Cadence’s partner part is not recorded. Join measurements remain a single-melody exercise."
                ).font(.callout)
            } else if record.stage == .opening {
                Text("Start with your opening pass. Then choose Connect the melody in focused practice.").font(.callout)
            } else if record.stage == .complete {
                Text(
                    "Your intention stays with this phrase for its next return. Listening here moves the fresh review at least 20 hours away."
                ).font(.callout)
                Button("More supported practice") {
                    perform {
                        try state.updateRehearsal(record.key) { try $0.practiseAgain() }
                        session.timing.discard()
                    }
                }.disabled(locked)
            } else {
                Text(
                    "Carry this intention into the whole phrase. Its take will be saved alongside the pitch and timing result."
                ).font(.callout)
            }
        }
    }
    private func observations(_ take: PianoTake) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("At the joins").font(.headline)
            Text(
                "\(take.joins.count) observed of \(take.phrase.joins.count) eligible joins. A gap or overlap is something to listen to, not a verdict about technique."
            ).font(.caption).foregroundStyle(.secondary)
            ForEach(take.joins) { join in
                VStack(alignment: .leading, spacing: 3) {
                    Text("Bar \(join.bar+1) · \(Pitch.chromatic(join.from)) → \(Pitch.chromatic(join.to))").font(
                        .caption.weight(.medium))
                    Text(joinLabel(join)).font(.caption).foregroundStyle(Color.moss)
                }
            }
            if take.joins.isEmpty {
                Text(
                    "No confident joins to measure in this take. Missing or ambiguous pitches and releases are left unjudged."
                ).font(.caption)
            }
            Text(
                "Pedal bridging uses MIDI sustain on/off, not an acoustic measurement. Half-pedal, fingering and physical technique are not evaluated."
            ).font(.caption).foregroundStyle(.secondary)
        }.padding(.top, 4)
    }
    private func joinLabel(_ join: MelodyJoin) -> String {
        let ms = Int((abs(join.gap) * 1000).rounded())
        if ms == 0 { return "Keys meet at the next entrance" }
        if join.gap < 0 { return "Keys overlap by \(ms) ms" }
        return "\(ms) ms between keys" + (join.pedalBridged ? " · pedal bridges it" : "")
    }
    private func takeLabel(_ take: PianoTake) -> String {
        let ordered = state.pianoTakes.takes.filter { $0.rehearsalKey == take.rehearsalKey }
        let number = (ordered.firstIndex { $0.id == take.id } ?? 0) + 1
        return "Take \(number) · "
            + (take.pass.plan.handStaves != nil
                ? "Both hands"
                : take.pass.plan.source?.scope.staff.map { "Staff \($0)" } ?? take.phase.rawValue.capitalized)
            + " · \(take.pass.plan.tempo) bpm"
    }
    private func scopeLabel(_ take: PianoTake) -> String {
        take.pass.plan.source.map {
            ($0.scope.from == $0.scope.through
                ? "Bar \($0.scope.from+1)" : "Bars \($0.scope.from+1)–\($0.scope.through+1)")
                + ($0.scope.staff.map { " · staff \($0)" } ?? " · both hands")
        } ?? "Piano phrase"
    }
    private func loadReflection() {
        reflection = take?.reflection ?? .unsure
        listeningNote = take?.note ?? ""
    }
    private func perform(_ action: () throws -> Void) {
        do {
            error = nil
            try action()
        } catch { self.error = error.localizedDescription }
    }
}

/// A quiet performance trace: solid is physical key length, pale is inferred
/// pedal sustain. It supplements the full notation rather than replacing it.
struct PianoTakeTrace: View {
    var take: PianoTake
    var elapsed: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Your performance", systemImage: "waveform").font(.callout.weight(.medium))
                Spacer()
                Text("Keys held · lighter tails show pedal").font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                let notes = take.recording.notes
                let low = notes.map(\.pitch).min() ?? 60
                let high = max(low + 8, notes.map(\.pitch).max() ?? 68)
                let duration = max(0.01, take.recording.duration)
                ZStack(alignment: .topLeading) {
                    ForEach(notes) { note in
                        let x = (note.start - take.recording.start) / duration * geometry.size.width
                        let y = Double(high - note.pitch) / Double(high - low) * 48
                        let end = note.release ?? note.soundEnd
                        Capsule().fill(Color.moss.opacity(0.15)).frame(
                            width: max(2, (note.soundEnd - note.start) / duration * geometry.size.width), height: 5
                        ).offset(x: x, y: y)
                        Capsule().fill(Color.moss.opacity(0.35 + Double(note.velocity) / 127 * 0.65)).frame(
                            width: max(2, (end - note.start) / duration * geometry.size.width), height: 5
                        ).offset(x: x, y: y)
                    }
                    if let elapsed {
                        Rectangle().fill(Color.clay).frame(width: 2, height: 56).offset(
                            x: max(0, min(1, elapsed / duration)) * geometry.size.width)
                    }
                }
            }.frame(height: 56).accessibilityElement(children: .ignore).accessibilityLabel(
                "Piano take, \(take.recording.notes.count) played notes. Solid lines show keys held; lighter tails show sustain pedal."
            )
            Text("Original touch and pacing · sampled piano replay · score cursor follows matched entrances").font(
                .caption
            ).foregroundStyle(.secondary)
        }.padding(14).background(Color.moss.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct PianoTakeLibraryView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var deleting: PianoTake?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Saved piano takes").font(.title2)
                Spacer()
                Button("Done") { dismiss() }
            }
            Text(
                "\(state.pianoTakes.takes.count) of \(PianoTakeBook.limit) takes. Deleting a recording keeps its practice result and review schedule."
            ).font(.callout).foregroundStyle(.secondary)
            List(state.pianoTakes.takes.sorted { $0.pass.date > $1.pass.date }) { take in
                HStack {
                    VStack(alignment: .leading) {
                        Text(take.pass.plan.title)
                        Text(take.pass.date.formatted() + " · " + take.phase.rawValue).font(.caption).foregroundStyle(
                            .secondary)
                    }
                    Spacer()
                    Button("Delete…", role: .destructive) { deleting = take }
                }.padding(.vertical, 5)
            }
            if let error { Text(error).foregroundStyle(Color.clay) }
        }.padding(24).frame(width: 620, height: 460)
            .confirmationDialog(
                "Delete this piano recording?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
            ) {
                Button("Delete take", role: .destructive) {
                    guard let take = deleting else { return }
                    do {
                        try state.deletePianoTake(take.id)
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                    }
                    deleting = nil
                }
            }
    }
}
