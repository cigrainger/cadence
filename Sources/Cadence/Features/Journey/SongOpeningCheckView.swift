// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

/// Keep keyboard packets out of the course map's observation graph. Only this
/// small input surface redraws for held-note/device changes.
struct SongOpeningCheckView: View {
    @EnvironmentObject private var state: AppState
    let journey: SongJourney
    @ObservedObject var input: SongOpeningInput
    @ObservedObject var midi: MIDIKeyboard
    @State private var expanded = false
    @State private var selectedNotes = Set<Int>()
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "From C4–E4–G4, find an F major shape nearby. Keep any shared note in its octave. Several answers work."
                )
                .font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(input.listening ? "Listening…" : "Check with MIDI", systemImage: "pianokeys") {
                        input.listen(held: midi.keyboard.downNotes)
                    }
                    .disabled(input.pending != nil || !midi.connected)
                    Button("Hear the starting chord", systemImage: "speaker.wave.2") {
                        input.pause()
                        state.audio.chord(journey.openingPrompt.from)
                    }
                    Button("Show one possible answer") { input.hint = true }
                }
                if input.hint, let answer = journey.openingPrompt.solutions.first {
                    Text(
                        "One nearby shape: "
                            + answer.map { Pitch.chromatic($0) + String($0 / 12 - 1) }.joined(separator: " · ")
                    )
                    .font(.callout).foregroundStyle(Color.moss)
                }
                DisclosureGroup("Try with on-screen notes") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 45))], spacing: 6) {
                        ForEach(55...76, id: \.self) { note in
                            Button {
                                if selectedNotes.contains(note) {
                                    selectedNotes.remove(note)
                                } else {
                                    selectedNotes.insert(note)
                                }
                            } label: {
                                Text(Pitch.chromatic(note) + String(note / 12 - 1)).frame(maxWidth: .infinity)
                            }
                            .tint(selectedNotes.contains(note) ? Color.moss : Color.ink)
                            .accessibilityValue(selectedNotes.contains(note) ? "Selected" : "Not selected")
                            .accessibilityAddTraits(selectedNotes.contains(note) ? [.isSelected] : [])
                        }
                    }
                    Button("Check selected notes") {
                        input.submit(selectedNotes.sorted(), input: .choice, journey: journey, state: state)
                    }
                    .disabled(selectedNotes.isEmpty || input.pending != nil)
                    Text("On-screen choices are saved separately from instrument performance.").font(.caption)
                        .foregroundStyle(.secondary)
                }
                MIDIConnectionView(midi: midi)
                if let message = input.message { Text(message).font(.callout).foregroundStyle(Color.moss) }
                if input.pending != nil {
                    HStack {
                        Button("Save opening answer again") { input.save(state: state) }
                        Button("Discard unsaved answer") { input.discard() }
                    }
                }
                Text("This is an untimed pitch-and-voicing check. Timing and physical technique are not assessed here.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 12)
        } label: {
            HStack {
                Label("A short opening check", systemImage: "tuningfork").font(.headline)
                Spacer()
                Text(state.songOpening(journey).label).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(18).background(Color.moss.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("journey.opening")
            .onAppear { expanded = state.songOpening(journey).attempts.isEmpty }
            .onReceive(midi.updates) { input.receive($0, state: state, journey: journey) }
            .onDisappear { input.pause() }
    }
}
