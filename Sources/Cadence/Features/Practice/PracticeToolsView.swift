// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct PracticeToolsView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var audio: AudioPlayer
    @ObservedObject var microphone: Microphone
    @State private var tapper = TapTempo()
    @State private var selectedString: Int?
    @State private var smoother = TunerSmoother()
    @State private var reading: TunerReading?
    @State private var restart: Task<Void, Never>?
    private var targets: [Int] { state.tuning.pitches.map { $0 + (state.tuner.includeCapo ? state.capo : 0) } }
    private var targetMidi: Int? {
        guard state.tuner.mode == .guitar else { return nil }
        if let string = selectedString, targets.indices.contains(string) { return targets[string] }
        return microphone.pitch.flatMap {
            TunerReading.closestTarget(frequency: $0.frequency, targets: targets, referenceA4: state.tuner.referenceA4)
        }
    }
    private var live: TunerReading? { microphone.listening || state.isPreview ? reading : nil }
    var body: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                metronomeCard
                tunerCard
            }
            if state.tuner.mode == .guitar { guitarTargets }
            HStack(spacing: 10) {
                Image(systemName: "leaf").foregroundStyle(Color.moss)
                Text("A pulse to come back to. A pitch to settle into.").font(
                    .system(size: 15, weight: .medium, design: .serif))
                Spacer()
                Text("Works offline").font(.caption).foregroundStyle(.secondary)
            }.padding(16).background(Color.moss.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        }
        .onAppear {
            if state.isPreview && CommandLine.arguments.contains("--tuner-reading") {
                state.tuner.mode = .guitar
                selectedString = 1
                reading = TunerReading(frequency: 109.65, confidence: 0.99, target: 45)
            }
        }
        .onChange(of: state.metronome) { _, _ in
            guard audio.isMetronome else { return }
            restart?.cancel()
            restart = Task {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled, audio.isMetronome else { return }
                audio.playMetronome(state.metronome)
            }
        }
        .onChange(of: microphone.pitch?.frequency) { _, _ in updateReading() }
        .onChange(of: microphone.listening) { _, listening in
            if !listening {
                smoother.reset()
                reading = nil
            }
        }
        .onChange(of: state.tuner.mode) { _, _ in selectedString = nil }
        .onChange(of: state.tuner) { _, _ in
            smoother.reset()
            updateReading()
        }
        .onChange(of: state.tuning) { _, _ in
            selectedString = nil
            smoother.reset()
            updateReading()
        }
        .onChange(of: state.capo) { _, _ in
            smoother.reset()
            updateReading()
        }
        .onChange(of: selectedString) { _, _ in
            smoother.reset()
            updateReading()
        }
        .onDisappear {
            restart?.cancel()
            microphone.stop()
        }
    }
    private var metronomeCard: some View {
        Card(
            title: "Metronome", subtitle: audio.isMetronome ? "Keeping time" : "Your steady pulse", padding: 22,
            spacing: 18
        ) {
            HStack(alignment: .center, spacing: 12) {
                Button {
                    state.metronome.bpm = max(20, state.metronome.bpm - 1)
                } label: {
                    Image(systemName: "minus.circle").font(.system(size: 22))
                }.buttonStyle(.plain).accessibilityLabel("Decrease tempo")
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    Text("\(state.metronome.bpm)").font(.system(size: 72, weight: .medium, design: .serif))
                        .monospacedDigit()
                    Text("BEATS PER MINUTE").font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(
                        .secondary)
                }
                Spacer(minLength: 0)
                Button {
                    state.metronome.bpm = min(300, state.metronome.bpm + 1)
                } label: {
                    Image(systemName: "plus.circle").font(.system(size: 22))
                }.buttonStyle(.plain).accessibilityLabel("Increase tempo")
            }
            Slider(
                value: Binding(get: { Double(state.metronome.bpm) }, set: { state.metronome.bpm = Int($0.rounded()) }),
                in: 20...300
            ).accessibilityLabel("Tempo")
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Beats per bar").font(.caption).foregroundStyle(.secondary)
                    ChoiceMenu(
                        title: "Beats per bar",
                        selection: Binding(get: { state.metronome.beatsPerBar }, set: { state.metronome.setBeats($0) }),
                        options: Array(1...12), label: { "\($0) beats" })
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Subdivision").font(.caption).foregroundStyle(.secondary)
                    ChoiceMenu(
                        title: "Click subdivision", selection: $state.metronome.subdivision,
                        options: BeatSubdivision.allCases, label: { $0.rawValue })
                }
            }
            HStack(spacing: 6) {
                ForEach(0..<state.metronome.beatsPerBar, id: \.self) { beat in
                    let active = audio.isMetronome && audio.metronomePosition?.beat == beat
                    Button {
                        state.metronome.accents[beat].toggle()
                    } label: {
                        Text("\(beat+1)").font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).frame(
                            height: 34
                        )
                        .foregroundStyle(active ? .white : state.metronome.accents[beat] ? Color.moss : .secondary)
                        .background(
                            active
                                ? Color.moss : state.metronome.accents[beat] ? Color.moss.opacity(0.12) : Color.canvas,
                            in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).accessibilityLabel(
                        "Beat \(beat+1), \(state.metronome.accents[beat] ? "accented" : "regular"). Toggle accent.")
                }
            }
            HStack(spacing: 5) {
                ForEach(0..<state.metronome.subdivision.count, id: \.self) { pulse in
                    Capsule().fill(
                        audio.isMetronome && audio.metronomePosition?.subdivision == pulse
                            ? Color.clay : Color.line.opacity(0.5)
                    ).frame(height: 3)
                }
            }.accessibilityHidden(true)
            HStack {
                Button(audio.isMetronome ? "Stop" : "Start", systemImage: audio.isMetronome ? "stop.fill" : "play.fill")
                {
                    restart?.cancel()
                    if audio.isMetronome {
                        audio.stop()
                    } else {
                        microphone.stop()
                        audio.playMetronome(state.metronome)
                    }
                }.buttonStyle(.cadencePrimary).keyboardShortcut(.space, modifiers: [])
                Button("Tap tempo", systemImage: "hand.tap") {
                    if let bpm = tapper.tap(at: Date().timeIntervalSinceReferenceDate) { state.metronome.bpm = bpm }
                }.help("Tap twice or more to set a tempo")
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Image(systemName: state.metronome.volume == 0 ? "speaker.slash" : "speaker.wave.2").foregroundStyle(
                    .secondary)
                Slider(value: $state.metronome.volume, in: 0...1).accessibilityLabel("Metronome volume")
                Text("\(Int(state.metronome.volume*100))%").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: 34)
            }
            Text(
                "Click a beat to accent it. The pulse continues when you browse theory; playing another sound replaces it. Volume at zero gives a silent visual pulse."
            ).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var tunerCard: some View {
        Card(
            title: "Tuner", subtitle: microphone.listening ? "Listening on this Mac" : "One clear note at a time",
            padding: 22, spacing: 18
        ) {
            Picker("Tuner mode", selection: $state.tuner.mode) {
                ForEach(TunerMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Spacer()
                Text(live.map { Pitch.chromatic($0.targetMidi) } ?? "—").font(
                    .system(size: 68, weight: .medium, design: .serif))
                if let live {
                    Text("\(live.targetMidi/12-1)").font(.system(size: 22, weight: .medium, design: .serif))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }.frame(height: 86)
            TuningMeter(cents: live?.cents, inTune: live?.isInTune ?? false).frame(height: 72)
            VStack(spacing: 5) {
                Text(tuningGuidance).font(.system(size: 17, weight: .medium)).foregroundStyle(
                    live?.isInTune == true ? Color.moss : Color.ink)
                Text(
                    live.map { "\(String(format:"%+.1f",$0.cents)) cents · \(String(format:"%.2f",$0.frequency)) Hz" }
                        ?? "Pluck a string or play a single note."
                ).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).monospacedDigit()
                if let live, live.heardMidi != live.targetMidi {
                    Text(
                        "Heard \(noteLabel(live.heardMidi)) · target \(noteLabel(live.targetMidi)). Check the string and octave."
                    ).font(.system(size: 10)).foregroundStyle(Color.clay)
                }
            }.frame(maxWidth: .infinity).frame(minHeight: 55)
            HStack {
                Text("A4 reference").font(.caption).foregroundStyle(.secondary)
                Spacer()
                ChoiceMenu(
                    title: "A4 calibration", selection: $state.tuner.referenceA4,
                    options: Array(430...450).map(Double.init), label: { "\(Int($0)) Hz" }
                ).frame(width: 105)
            }
            HStack {
                Button(
                    microphone.listening ? "Stop listening" : "Start listening",
                    systemImage: microphone.listening ? "stop.fill" : "mic"
                ) {
                    if microphone.listening {
                        microphone.stop()
                    } else if !state.isPreview {
                        audio.stop()
                        Task { await microphone.start(forTuner: true) }
                    }
                }.buttonStyle(.cadencePrimary)
                Spacer(minLength: 0)
                Button("Hear A4", systemImage: "speaker.wave.2") {
                    microphone.stop()
                    audio.note(69, referenceA4: state.tuner.referenceA4)
                }.font(.caption).help("Hear the calibrated A4 reference; pauses microphone listening")
            }
            if let error = microphone.error {
                Text(error).font(.caption).foregroundStyle(Color.clay).textSelection(.enabled)
            }
            Text(
                "The centre band is ±5 cents. Microphone audio is analysed here and never uploaded. Tuning pauses other playback; reference tones pause listening."
            ).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var guitarTargets: some View {
        Card(
            title: "Your strings",
            subtitle: state.tuner.includeCapo ? "With capo \(state.capo)" : "Open strings · remove your capo",
            padding: 20, spacing: 16
        ) {
            HStack(spacing: 12) {
                TuningPicker().frame(maxWidth: 300)
                Toggle("Include capo", isOn: $state.tuner.includeCapo).toggleStyle(.checkbox).font(.caption)
                if state.tuner.includeCapo {
                    ChoiceMenu(
                        title: "Tuner capo", selection: $state.capo, options: Array(0...9), label: { "Capo \($0)" }
                    ).frame(width: 100)
                }
                Spacer()
                Button("Auto-detect string") { selectedString = nil }.font(.caption).disabled(selectedString == nil)
            }
            HStack(spacing: 10) {
                ForEach(0..<6, id: \.self) { string in
                    let target = targets[string]
                    let chosen = selectedString == string || (selectedString == nil && live?.targetMidi == target)
                    VStack(spacing: 8) {
                        Button {
                            selectedString = string
                        } label: {
                            VStack(spacing: 6) {
                                Text("STRING \(6-string)").font(.system(size: 9, weight: .semibold)).tracking(0.8)
                                    .foregroundStyle(.secondary)
                                Text(noteLabel(target)).font(.system(size: 22, weight: .medium, design: .serif))
                                Text(
                                    "\(String(format:"%.1f",TunerReading.frequency(midi:target,referenceA4:state.tuner.referenceA4))) Hz"
                                ).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            }.padding(13).frame(maxWidth: .infinity).background(
                                chosen ? Color.moss.opacity(0.10) : Color.canvas, in: RoundedRectangle(cornerRadius: 10)
                            ).overlay(
                                RoundedRectangle(cornerRadius: 10).stroke(
                                    chosen ? Color.moss.opacity(0.5) : Color.clear, lineWidth: 1))
                        }.buttonStyle(.plain).accessibilityLabel("Tune string \(6-string) to \(noteLabel(target))")
                        Button("Hear", systemImage: "speaker.wave.2") {
                            microphone.stop()
                            selectedString = string
                            audio.note(target, referenceA4: state.tuner.referenceA4)
                        }.font(.caption).help("Hear the calibrated target pitch; pauses microphone listening")
                    }.frame(maxWidth: .infinity)
                }
            }
            Text(
                selectedString.map {
                    "String \(6-$0) is pinned. Choose Auto-detect string to follow the nearest open-string pitch."
                }
                    ?? "Auto-detect follows the nearest string. Pin a string if a harmonic or neighbouring string confuses the reading. Mute the other strings for a steadier result."
            ).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private var tuningGuidance: String {
        guard let live else { return microphone.listening ? "Listening…" : "Ready when you are" }
        if live.isInTune { return "In tune" }
        return live.cents < 0 ? "Flat · raise the pitch" : "Sharp · lower the pitch"
    }
    private func noteLabel(_ midi: Int) -> String { Pitch.chromatic(midi) + String(midi / 12 - 1) }
    private func updateReading() {
        if state.isPreview && CommandLine.arguments.contains("--tuner-reading") {
            reading = TunerReading(frequency: 109.65, confidence: 0.99, target: 45)
            return
        }
        reading = smoother.update(microphone.pitch, referenceA4: state.tuner.referenceA4, target: targetMidi)
    }
}

private struct TuningMeter: View {
    var cents: Double?
    var inTune: Bool
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let centre = width / 2
            Canvas { context, size in
                let left = 14.0
                let right = width - 14
                let x: (Double) -> Double = { left + ($0 + 50) / 100 * (right - left) }
                context.fill(
                    Path(roundedRect: CGRect(x: x(-5), y: 0, width: x(5) - x(-5), height: 43), cornerRadius: 4),
                    with: .color(Color.moss.opacity(0.10)))
                for value in stride(from: -50, through: 50, by: 10) {
                    var tick = Path()
                    tick.move(to: CGPoint(x: x(Double(value)), y: value == 0 ? 7 : 18))
                    tick.addLine(to: CGPoint(x: x(Double(value)), y: 36))
                    context.stroke(tick, with: .color(value == 0 ? .moss : Color.line), lineWidth: value == 0 ? 2 : 1)
                    if [-50, 0, 50].contains(value) {
                        context.draw(
                            Text(value == 0 ? "0" : "\(value)").font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary), at: CGPoint(x: x(Double(value)), y: 57))
                    }
                }
                if let cents {
                    let position = x(min(50, max(-50, cents)))
                    var needle = Path()
                    needle.move(to: CGPoint(x: position, y: 0))
                    needle.addLine(to: CGPoint(x: position, y: 42))
                    context.stroke(needle, with: .color(inTune ? .moss : .clay), lineWidth: 3)
                    context.fill(
                        Path(ellipseIn: CGRect(x: position - 4, y: 2, width: 8, height: 8)),
                        with: .color(inTune ? .moss : .clay))
                } else {
                    context.draw(
                        Text("♭     ·     ♯").font(.system(size: 11)).foregroundStyle(.tertiary),
                        at: CGPoint(x: centre, y: 10))
                }
            }
        }.accessibilityLabel(
            cents.map { "Pitch deviation \(Int($0.rounded())) cents. \(inTune ? "In tune" : $0<0 ? "Flat" : "Sharp")" }
                ?? "Tuner waiting for a note")
    }
}
