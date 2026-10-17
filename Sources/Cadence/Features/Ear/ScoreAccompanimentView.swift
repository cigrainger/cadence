// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import AppKit
import MusicCore
import SwiftUI

struct ScoreAccompanimentView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.scenePhase) private var scenePhase
    let material: ScoreEarMaterial
    @ObservedObject var input: EarSessionInput
    @ObservedObject var midi: MIDIKeyboard
    @State private var scoreHeight: CGFloat = 220
    @State private var scoreError: String?
    @State private var study: MusicStudy?
    @StateObject private var playback = GroovePlayback()
    @State private var tempo = 80.0
    @State private var style = GrooveStyle.steady
    @State private var loops = 2
    @State private var piano = true
    @State private var bass = true
    @State private var drums = true
    @State private var melody = false
    private var arrangement: ScoreAccompaniment {
        .init(
            material: material,
            options: .init(tempo: tempo, style: style, loops: loops, piano: piano, bass: bass, drums: drums),
            includeMelody: melody)
    }
    private var running: Bool { playback.preparing || playback.origin != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Now, play inside the music.").font(.system(size: 23, weight: .medium, design: .serif))
            if let issue = material.accompanimentIssue {
                Text(issue).font(.callout).foregroundStyle(.secondary)
            } else {
                Button("Play with note feedback", systemImage: "music.note.list") {
                    playback.stop()
                    state.openPlayAlong(material)
                }.buttonStyle(.cadencePrimary)
                Text("Calibrate your keyboard, follow the score and try an optional pitch or pulse challenge.").font(
                    .caption
                ).foregroundStyle(.secondary)
                Text(material.chords.map { $0.symbol.label }.joined(separator: "  →  ")).font(.headline)
                    .foregroundStyle(Color.moss)
                Text(
                    "A four-beat count-in, then the written changes. Keep the melody muted to take its part, or mute piano to practise comping. The melody keeps the score’s rhythm; swing changes the backing only."
                ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("\(Int(tempo)) bpm").monospacedDigit()
                    Slider(value: Binding(get: { tempo }, set: { tempo = $0.rounded() }), in: 50...160)
                    Stepper("\(loops) rounds", value: $loops, in: 1...4).fixedSize()
                }
                Picker("Feel", selection: $style) {
                    ForEach(GrooveStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                HStack {
                    Toggle("Piano", isOn: $piano)
                    Toggle("Bass", isOn: $bass)
                    Toggle("Drums", isOn: $drums)
                    Toggle("Guide melody", isOn: $melody)
                }.toggleStyle(.checkbox).font(.callout)
                TimelineView(.periodic(from: Date(), by: 0.035)) { _ in
                    let seconds =
                        state.isPreview && CommandLine.arguments.contains("--band-preview")
                        ? 7.5 : playback.origin.map { PracticeClock.now() - $0 } ?? -1
                    let ended = seconds >= arrangement.endBeat * 60 / tempo
                    let position = ScoreBandPosition(
                        seconds: seconds, tempo: tempo, beats: material.beats, loops: loops,
                        sourceStart: study?.start ?? 0)
                    VStack(alignment: .leading, spacing: 12) {
                        if let study {
                            ScoreRenderer(
                                study: study, playhead: position?.head, height: $scoreHeight, error: $scoreError
                            ).frame(height: min(380, scoreHeight)).background(
                                .white, in: RoundedRectangle(cornerRadius: 10))
                        }
                        if let scoreError { Text(scoreError).font(.caption).foregroundStyle(Color.clay) }
                        HStack(spacing: 10) {
                            ForEach(0..<4, id: \.self) { beat in
                                Circle().fill(
                                    position.map {
                                        Int(
                                            ($0.head.sourceBeat - (study?.start ?? 0)).truncatingRemainder(
                                                dividingBy: 4)) == beat && !$0.head.isCountIn
                                    } == true ? Color.moss : Color.moss.opacity(0.12)
                                ).frame(width: 12, height: 12)
                            }
                            ProgressView(value: position?.fraction ?? 0).tint(Color.moss)
                            Text(
                                position.map {
                                    $0.head.isCountIn
                                        ? "Count in · \(Int(ceil($0.head.countInRemaining)))"
                                        : "Round \($0.round) of \(loops)"
                                } ?? (ended ? "Complete" : "Ready")
                            ).font(.caption.monospacedDigit()).frame(minWidth: 100)
                        }
                        MIDIPitchLights(
                            notes: midi.keyboard.downNotes,
                            expected: position.flatMap { p in
                                p.head.isCountIn
                                    ? nil
                                    : material.melody.first {
                                        $0.start <= p.head.sourceBeat - (study?.start ?? 0)
                                            && $0.start + $0.duration > p.head.sourceBeat - (study?.start ?? 0)
                                    }?.midi
                            })
                        HStack {
                            Button(
                                running && !ended ? "Stop band" : "Play along",
                                systemImage: running && !ended ? "stop.fill" : "play.fill"
                            ) {
                                if running && !ended {
                                    playback.stop()
                                } else {
                                    input.submit(.init(.accompaniment), state: state)
                                    guard input.pending == nil else { return }
                                    state.audio.stop()
                                    state.microphone.stop()
                                    playback.start(arrangement)
                                }
                            }.buttonStyle(.cadencePrimary).disabled(
                                input.pending != nil || !state.scoreEarCurrent(material))
                            if playback.preparing {
                                ProgressView().controlSize(.small)
                            } else if let bar = arrangement.bar(at: seconds) {
                                Text("Bar \(bar)").font(.callout.monospacedDigit()).foregroundStyle(Color.moss)
                            } else if running {
                                Text(ended ? "Round complete" : "Count in…").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Text(
                    "Follow the cursor and keep going. MIDI lights show held pitches; a matching pitch lights green. This is live guidance, not a timing or performance grade. Play-along visits are saved."
                ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                MIDIConnectionView(midi: midi)
                if let error = playback.error { Text(error).foregroundStyle(Color.clay).font(.caption) }
            }
        }
        .onChange(of: tempo) { _, _ in playback.stop() }.onChange(of: style) { _, _ in playback.stop() }.onChange(
            of: loops
        ) { _, _ in playback.stop() }
        .onChange(of: piano) { _, _ in playback.stop() }.onChange(of: bass) { _, _ in playback.stop() }.onChange(
            of: drums
        ) { _, _ in playback.stop() }.onChange(of: melody) { _, _ in playback.stop() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { playback.stop() } }
        .onAppear {
            tempo = min(160, max(50, material.tempo))
            do {
                if let piece = state.libraryPieces.first(where: { $0.id == material.pieceID }) {
                    study = try ScoreEarMaterial.study(piece: piece, scope: material.scope)
                }
            } catch { scoreError = error.localizedDescription }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            playback.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVAudioEngineConfigurationChange)) { _ in playback.stop()
        }
        .onChange(of: midi.connectionRevision) { _, _ in playback.stop() }
        .onDisappear { playback.stop() }
    }
}

private struct MIDIPitchLights: View {
    let notes: Set<Int>
    let expected: Int?
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pianokeys").foregroundStyle(Color.moss)
            Text("You play").font(.caption).foregroundStyle(.secondary)
            if notes.isEmpty { Text("—").foregroundStyle(.secondary) }
            ForEach(Array(notes.sorted().prefix(10)), id: \.self) { note in
                Text(Pitch.chromatic(note) + String(note / 12 - 1)).font(.callout.monospacedDigit()).padding(
                    .horizontal, 10
                ).padding(.vertical, 5)
                    .background(note == expected ? Color.moss.opacity(0.2) : Color.clay.opacity(0.12), in: Capsule())
                    .overlay { if note == expected { Capsule().stroke(Color.moss, lineWidth: 1) } }
            }
            Spacer()
            if let expected {
                Text("Melody · " + Pitch.chromatic(expected) + String(expected / 12 - 1)).font(.caption)
                    .foregroundStyle(Color.moss)
            }
        }.accessibilityElement(children: .combine)
    }
}
