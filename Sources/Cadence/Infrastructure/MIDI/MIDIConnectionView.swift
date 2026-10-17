// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct MIDIConnectionView: View {
    @ObservedObject var midi: MIDIKeyboard
    var compact = false
    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 10) {
                    sourcePicker
                    HStack(spacing: 8) {
                        Circle().fill(midi.connected ? Color.moss : Color.secondary.opacity(0.4)).frame(
                            width: 6, height: 6)
                        Text(midi.connected ? "Connected" : "No input").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            midi.start()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }.help("Refresh MIDI inputs").accessibilityLabel("Refresh MIDI inputs")
                        Button("Clear keys") { midi.panic() }.help(
                            "Reset held notes and sustain without grading an answer.")
                    }
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "pianokeys").foregroundStyle(Color.moss)
                    sourcePicker.frame(maxWidth: 320)
                    Button("Refresh", systemImage: "arrow.clockwise") { midi.start() }
                    Circle().fill(midi.connected ? Color.moss : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                    Text(midi.connected ? "Connected" : "No input").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Clear held notes") { midi.panic() }.help(
                        "Reset held keys and sustain, without entering or grading a chord.")
                }
            }
        }.controlSize(.small)
            .onAppear { midi.start() }
        if let error = midi.error { Text(error).font(.caption).foregroundStyle(Color.clay) }
    }
    private var sourcePicker: some View {
        HStack(spacing: 8) {
            Text("Keyboard").font(.caption)
            ChoiceMenu(
                title: "MIDI keyboard", selection: Binding<Int32?>(get: { midi.selectedID }, set: { midi.choose($0) }),
                options: [nil] + midi.sources.map { Optional($0.id) }
                    + (midi.selectedID.map { id in midi.sources.contains(where: { $0.id == id }) ? [] : [Optional(id)] }
                        ?? []),
                label: { id in
                    guard let id else { return "None" }
                    return midi.sources.first { $0.id == id }?.name ?? "Disconnected keyboard"
                })
        }
    }
}
