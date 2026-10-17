// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import MusicCore
import SwiftUI

struct EditorMIDIView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var midi: MIDIKeyboard
    @ObservedObject var audio: AudioPlayer
    var context: String
    var instrument: EditorInstrument
    var rhythms: [EditorRhythm]
    @Binding var rhythm: EditorRhythm
    var enter: ([Int]) -> Bool
    @State private var armed = false
    @State private var audition = false
    @State private var capture = MIDIStepCapture()
    @State private var notice = ""
    var body: some View {
        Card(
            title: "Write from your keyboard",
            subtitle: "Step entry · selected hand and voice · one gesture per note or chord", padding: 16, spacing: 12
        ) {
            MIDIConnectionView(midi: midi)
            HStack(spacing: 14) {
                Toggle("Write MIDI", isOn: $armed).toggleStyle(.button).disabled(!midi.connected)
                Picker("Duration", selection: $rhythm) { ForEach(rhythms, id: \.self) { Text($0.label).tag($0) } }
                    .frame(width: 200)
                Toggle("Audition on release", isOn: $audition).font(.caption)
                Spacer()
                Text(
                    armed
                        ? (capture.waitingForRelease ? "Release held keys to begin" : "Ready to write")
                        : "Writing is off"
                ).font(.caption).foregroundStyle(armed ? Color.moss : .secondary)
            }.controlSize(.small)
            Text(
                midi.keyboard.downNotes.isEmpty
                    ? "Play a note or chord, then release every key to enter it. The sustain pedal does not join entries."
                    : "Held: "
                        + midi.keyboard.downNotes.sorted().map {
                            Solfege.noteName(midi: $0, pitch: Pitch.spelled($0, flats: false))
                        }.joined(separator: " · ")
            ).font(.caption).foregroundStyle(.secondary)
            if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(Color.moss) }
            if instrument == .guitar {
                Text(
                    "Guitar entry uses sounding pitches and proposes playable strings. Your other voice keeps its pitches; review suggested fingerings."
                ).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: armed) { _, _ in reset() }
        .onChange(of: context) { _, _ in reset() }
        .onChange(of: rhythm) { _, _ in reset() }
        .onChange(of: state.showPDFImport) { _, shown in
            if shown { armed = false }
            reset()
        }
        .onChange(of: midi.connectionRevision) { _, _ in
            armed = false
            capture.reset(held: midi.keyboard.downNotes)
        }
        .onChange(of: midi.connected) { _, connected in
            if !connected { armed = false }
            reset()
        }
        .onReceive(midi.updates) { update in
            guard stateAllowsInput else { return }
            if let notes = capture.receive(update.message, state: update.keyboard) {
                if audition { audio.chord(notes) }
                if armed {
                    if enter(notes) {
                        notice = "Entered \(notes.count == 1 ? "note" : "chord") · advanced in this voice"
                    } else {
                        armed = false
                        notice = "Writing paused. Resolve the score message, then turn Write MIDI on to retry."
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            armed = false
            reset()
        }
        .onDisappear {
            armed = false
            capture.reset()
        }
        .onAppear {
            reset()
            if midi.preview && CommandLine.arguments.contains("--midi-entry-check") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    midi.installPreview()
                    armed = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        capture.reset()
                        midi.previewInput([
                            .noteOn(channel: 0, note: 60, velocity: 90), .noteOn(channel: 0, note: 64, velocity: 90),
                            .noteOn(channel: 0, note: 67, velocity: 90), .noteOff(channel: 0, note: 60),
                            .noteOff(channel: 0, note: 64), .noteOff(channel: 0, note: 67),
                        ])
                        if CommandLine.arguments.contains("--midi-import-pause-check") {
                            let before = state.editor.active
                            state.showPDFImport = true
                            midi.previewInput([
                                .noteOn(channel: 0, note: 62, velocity: 90), .noteOff(channel: 0, note: 62),
                            ])
                            MIDIDiagnostics.checks["importBlocksMIDIImmediately"] = state.editor.active == before
                            midi.previewInput([.noteOn(channel: 0, note: 72, velocity: 90)])
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                MIDIDiagnostics.checks["importDisarmsMIDI"] = !armed
                                MIDIDiagnostics.checks["importKeepsPhysicalKeys"] = midi.keyboard.downNotes == [72]
                                state.showPDFImport = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    midi.previewInput([
                                        .noteOff(channel: 0, note: 72), .noteOn(channel: 0, note: 65, velocity: 90),
                                        .noteOff(channel: 0, note: 65),
                                    ])
                                    MIDIDiagnostics.checks["cancelImportKeepsWritingOff"] =
                                        state.editor.active == before && !armed
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    private var stateAllowsInput: Bool { !state.showPDFImport && (midi.preview || NSApp.isActive) }
    private func reset() {
        capture.reset(held: midi.keyboard.downNotes)
        notice = ""
    }
}
