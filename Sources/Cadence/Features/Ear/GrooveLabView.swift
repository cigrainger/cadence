// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

@MainActor final class GroovePlayback: ObservableObject {
    @Published private(set) var origin: Double?
    @Published private(set) var preparing = false
    @Published var error: String?
    private let audio = TimedAudio()
    private var epoch = UUID()
    func stop() {
        epoch = UUID()
        audio.stop()
        origin = nil
        preparing = false
    }
    func start(_ arrangement: GrooveArrangement) {
        start(lanes: { try arrangement.lanes() }, tempo: arrangement.tempo, endBeat: arrangement.endBeat)
    }
    func start(_ arrangement: ScoreAccompaniment) {
        start(lanes: { try arrangement.lanes() }, tempo: arrangement.options.tempo, endBeat: arrangement.endBeat)
    }
    private func start(lanes: @escaping @Sendable () throws -> [BandLane], tempo: Double, endBeat: Double) {
        stop()
        error = nil
        preparing = true
        let token = epoch
        audio.start(render: { try SampledAudio.render(lanes: lanes(), tempo: tempo, endBeat: endBeat) }) {
            [weak self] result in
            guard let self, self.epoch == token else { return }
            self.preparing = false
            switch result {
            case .success(let time): self.origin = time
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }
}
struct GrooveLabView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var playback = GroovePlayback()
    @State private var tempo = 80.0
    @State private var style = GrooveStyle.steady
    @State private var loops = 2
    @State private var piano = true
    @State private var bass = true
    @State private var drums = true
    @State private var electric = false
    private var arrangement: GrooveArrangement {
        .init(tempo: tempo, style: style, loops: loops, piano: piano, bass: bass, drums: drums, electric: electric)
    }
    private var running: Bool { playback.preparing || playback.origin != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Button("Practice home", systemImage: "arrow.left") { state.showPracticeHome() }.buttonStyle(.plain)
                Spacer()
                Text("Accompaniment lab · listen, then join in").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow(text: "Rhythm lives between the notes").foregroundStyle(Color.moss)
                    Text("Find your place in the band.").font(.system(size: 32, weight: .medium, design: .serif))
                }
                Spacer()
                Label("Piano · bass · drums", systemImage: "waveform").foregroundStyle(Color.moss).font(.callout)
            }
            TimelineView(.periodic(from: Date(), by: 0.04)) { _ in
                let seconds = playback.origin.map { PracticeClock.now() - $0 } ?? -1
                let beat = seconds * tempo / 60
                let current = arrangement.bar(at: seconds)
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Eyebrow(
                            text: playback.preparing
                                ? "Getting the band ready"
                                : seconds < 0
                                    ? "Dm7 → G7 → Cmaj7"
                                    : beat < 4
                                        ? "Count in · \(Int(beat)+1)"
                                        : beat >= arrangement.endBeat
                                            ? "Let the last chord settle" : "Round \(Int((beat-4)/16)+1) of \(loops)"
                        ).opacity(0.8)
                        Spacer()
                        HStack(spacing: 8) {
                            ForEach(0..<4, id: \.self) { i in
                                Circle().fill(
                                    seconds >= 0 && beat < arrangement.endBeat && Int(beat) % 4 == i
                                        ? Color.white : Color.white.opacity(0.2)
                                ).frame(width: 9, height: 9)
                            }
                        }
                    }
                    HStack(spacing: 12) {
                        ForEach(0..<4, id: \.self) { bar in
                            VStack(alignment: .leading, spacing: 16) {
                                Text(String(format: "%02d", bar + 1)).font(.caption.monospacedDigit()).opacity(0.65)
                                Text(GrooveArrangement.symbols[bar]).font(
                                    .system(size: 29, weight: .medium, design: .serif))
                                Text(bar < 2 ? (bar == 0 ? "ii · prepare" : "V · lean forward") : "I · arrive").font(
                                    .caption
                                ).opacity(0.8)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                                .background(
                                    Color.white.opacity(current == bar ? 0.2 : 0.07),
                                    in: RoundedRectangle(cornerRadius: 10)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10).stroke(
                                        Color.white.opacity(current == bar ? 0.8 : 0.12),
                                        lineWidth: current == bar ? 2 : 1))
                        }
                    }
                }.padding(24).foregroundStyle(.white).background(Color.moss, in: RoundedRectangle(cornerRadius: 14))
                    .onChange(of: beat >= arrangement.endBeat + 0.6) { _, ended in if ended { playback.stop() } }
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 18) {
                    LearningSectionHeading(title: "Shape the feel")
                    Picker("Feel", selection: setting($style)) {
                        ForEach(GrooveStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    Text(style.invitation).font(.callout).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
                    HStack {
                        Text("Tempo")
                        Slider(
                            value: Binding(
                                get: { tempo },
                                set: {
                                    playback.stop()
                                    tempo = $0.rounded()
                                }), in: 50...160)
                        Text("\(Int(tempo)) bpm").monospacedDigit().frame(width: 70)
                    }
                    HStack {
                        Stepper("\(loops) rounds", value: setting($loops), in: 1...4)
                        Spacer()
                        Toggle("Electric piano", isOn: setting($electric))
                    }
                    Divider()
                    HStack(spacing: 22) {
                        Toggle("Piano", isOn: setting($piano))
                        Toggle("Bass", isOn: setting($bass))
                        Toggle("Drums", isOn: setting($drums))
                    }
                    HStack {
                        Button(
                            running ? "Stop the band" : "Listen to the band",
                            systemImage: running ? "stop.fill" : "play.fill"
                        ) {
                            if running {
                                playback.stop()
                            } else {
                                state.audio.stop()
                                playback.start(arrangement)
                            }
                        }
                        .buttonStyle(.cadencePrimary).controlSize(.large)
                        Button("Take the piano part", systemImage: "pianokeys") {
                            piano = false
                            state.audio.stop()
                            playback.start(arrangement)
                        }.disabled(running)
                    }
                    Text(
                        "One bar to count in, then \(loops * 4) bars together. Changing a setting stops playback so the next take uses that sound and tempo."
                    ).font(.caption).foregroundStyle(.secondary)
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading).background(
                    Color.paper, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 16) {
                    Eyebrow(text: "Try this in three passes").foregroundStyle(Color.moss)
                    Text("01  Listen for the bass.").font(.system(size: 19, weight: .medium, design: .serif))
                    Text("Tap the beat. Imagine the next root before it arrives.").font(.callout).foregroundStyle(
                        .secondary)
                    Text("02  Leave room to play.").font(.system(size: 19, weight: .medium, design: .serif))
                    Text(
                        "Mute the piano. Begin with one chord on beat one; add a second only when the pulse feels settled."
                    ).font(.callout).foregroundStyle(.secondary)
                    Text("03  Change one thing.").font(.system(size: 19, weight: .medium, design: .serif))
                    Text("Try the same progression off the beat. Notice how the space changes its character.").font(
                        .callout
                    ).foregroundStyle(.secondary)
                    Button("Practise rhythm taps", systemImage: "arrow.right") { state.openPractice(.rhythm) }
                }.padding(22).frame(width: 260).background(
                    Color.ochre.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            }
            GrooveKeyboard(midi: state.midi)
            Text(
                "A listening and play-along space. These takes are not scored. Acoustic / electric piano, upright bass and kit: TimGM6mb sound bank."
            ).font(.caption).foregroundStyle(.secondary)
            if let error = playback.error { Text(error).foregroundStyle(Color.clay) }
        }

        .onChange(of: scenePhase) { _, phase in if phase != .active { playback.stop() } }
        .onAppear {
            state.audio.stop()
            state.microphone.stop()
            if state.isPreview {
                let lanes = try? arrangement.lanes()
                GrooveDiagnostics.checks = [
                    "fourBarChanges": GrooveArrangement.symbols.count == 4,
                    "threeParts": lanes?.count == 3, "countIn": lanes?[2].notes.filter { $0.start < 4 }.count == 4,
                    "soundBank": FileManager.default.fileExists(atPath: SampledAudio.bankURL.path),
                    "validArrangement": arrangement.valid,
                ]
            }
        }
        .onDisappear { playback.stop() }
    }
    private func setting<T>(_ binding: Binding<T>) -> Binding<T> {
        Binding(
            get: { binding.wrappedValue },
            set: {
                playback.stop()
                binding.wrappedValue = $0
            })
    }
}
private struct GrooveKeyboard: View {
    @ObservedObject var midi: MIDIKeyboard
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MIDIConnectionView(midi: midi)
            Piano(
                root: Pitch(0), notes: [], degrees: [], showDegrees: false, exactNotes: midi.keyboard.downNotes,
                play: { _ in }, midiRange: 48...76, colorRoots: false, keyHeight: 72
            ).allowsHitTesting(false)
            Text(
                "Suggested voicings: Dm7 · F3 A3 C4 D4    →    G7 · F3 G3 B3 D4    →    Cmaj7 · E3 G3 B3 C4. Your keyboard's own sound is used for live playing."
            ).font(.caption).foregroundStyle(.secondary)
        }.padding(20).background(Color.paper, in: RoundedRectangle(cornerRadius: 12))
    }
}
