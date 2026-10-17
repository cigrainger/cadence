// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

@MainActor enum PassageDiagnostics { static var checks: [String: Bool] = [:] }

struct PassageSingingView: View {
    @EnvironmentObject private var state: AppState
    var study: MusicStudy
    @ObservedObject var audio: AudioPlayer
    @ObservedObject var microphone: Microphone
    var locate: (UUID) -> Void
    @State private var voiceID = ""
    @State private var minorOverride: Bool?
    @State private var melody: PassageMelody?
    @State private var guideError: String?
    @State private var referenceStart: Double?
    @State private var phrase = 0
    @State private var octaves = 0
    @State private var matchReference = false
    @State private var showPitchGuide = true
    @State private var played = false
    @State private var awaitingMicrophone = false
    @State private var echo = MelodyEchoAttempt()
    @State private var feedback = ""
    private var voices: [SingingVoice] { SingingVoice.choices(study) }
    private var voice: SingingVoice? { voices.first { $0.id == voiceID } ?? voices.first }
    private var notes: [PassageSingingNote] { melody?.notes ?? [] }
    private var chunk: [PassageSingingNote] { Array(notes.dropFirst(phrase * 8).prefix(8)) }
    private var targets: [Int] { chunk.map { $0.tone.midi + octaves * 12 } }
    private var complete: Bool { !chunk.isEmpty && echo.matched == chunk.count }
    private var guideKey: String {
        "\(study.id):\(study.partID):\(study.staff ?? 0):\(study.from):\(study.through):\(voice?.id ?? ""):\(minorOverride.map { $0 ? 1 : 0 } ?? -1)"
    }
    private var tonicLabel: String {
        let labels = study.selectedMeasures.map { bar in
            let minor = minorOverride ?? bar.minor ?? false
            return ScoreKey.tonic(fifths: bar.fifths, minor: minor).name + (minor ? " minor" : " major")
        }
        return labels.allSatisfy { $0 == labels.first }
            ? labels.first ?? "Score key" : "Changing key · follows each bar"
    }
    var body: some View {
        Card(title: "Sing the melody", subtitle: "Movable Do · \(tonicLabel)", padding: 18, spacing: 14) {
            HStack(spacing: 12) {
                ChoiceMenu(
                    title: "Singing line", selection: Binding(get: { voice?.id ?? "" }, set: { voiceID = $0 }),
                    options: voices.map(\.id), label: { id in voices.first { $0.id == id }?.label ?? id }
                ).frame(width: 185)
                ChoiceMenu(
                    title: "Key interpretation", selection: $minorOverride, options: [nil, false, true],
                    label: { $0.map { $0 ? "Use minor" : "Use major" } ?? "Score key" }
                ).frame(width: 140)
                ChoiceMenu(
                    title: "Reference register", selection: $octaves,
                    options: (-2...2).filter { shift in
                        chunk.allSatisfy { (21...108).contains($0.tone.midi + shift * 12) }
                    },
                    label: { $0 == 0 ? "Score register" : "\($0 > 0 ? "+" : "")\($0) octave\(abs($0) == 1 ? "" : "s")" }
                ).frame(width: 160)
                Spacer()
                Toggle("Pitch guide", isOn: $showPitchGuide).toggleStyle(.checkbox).font(.caption)
            }
            if !chunk.isEmpty {
                HStack {
                    Button {
                        phrase = max(0, phrase - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }.disabled(phrase == 0)
                    Text("Notes \(phrase*8+1)–\(phrase*8+chunk.count) of \(notes.count)").font(.caption)
                        .monospacedDigit()
                    Button {
                        phrase += 1
                    } label: {
                        Image(systemName: "chevron.right")
                    }.disabled((phrase + 1) * 8 >= notes.count)
                    Spacer()
                    Text(
                        melody?.reducedChords == true
                            ? "Top note at each chord onset · choose a voice to isolate a line"
                            : "One voice · tied notes stay joined"
                    ).font(.caption).foregroundStyle(.secondary)
                }.controlSize(.small)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                    ForEach(Array(chunk.enumerated()), id: \.element.id) { index, note in
                        Button {
                            reference(note, index: index)
                        } label: {
                            VStack(spacing: 5) {
                                HStack {
                                    Text("\(phrase*8+index+1)")
                                    Spacer()
                                    if index < echo.matched { Image(systemName: "checkmark") }
                                }.font(.system(size: 10)).foregroundStyle(.secondary)
                                Text(note.tone.solfege).font(.system(size: 25, weight: .medium, design: .serif))
                                    .foregroundStyle(Color.moss)
                                Text(Solfege.noteName(midi: note.tone.midi + octaves * 12, pitch: note.tone.pitch))
                                    .font(.system(size: 11, weight: .medium))
                                Text("Bar \(study.part.measures[note.measure].label)").font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity).padding(11).background(
                                index == echo.matched && !complete ? Color.moss.opacity(0.13) : Color.canvas,
                                in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).help("Hear this reference note and locate it in the notation")
                    }
                }
                HStack(spacing: 12) {
                    Button("Hear phrase", systemImage: "play.fill") { hearPhrase() }.buttonStyle(.cadencePrimary)
                    Button("First note") { if let note = chunk.first { reference(note, index: 0) } }
                    Toggle("Match reference key", isOn: $matchReference).toggleStyle(.checkbox).font(.caption).disabled(
                        microphone.listening)
                    Spacer()
                    if awaitingMicrophone { ProgressView().controlSize(.small) }
                    Button(
                        microphone.listening ? "Stop listening" : complete ? "Sing again" : "Listen to my voice",
                        systemImage: microphone.listening ? "stop.circle" : "mic"
                    ) { listen() }.disabled(
                        !played || audio.isPlaying || audio.isPreparing || awaitingMicrophone || state.isPreview)
                }.controlSize(.small)
                Text(
                    matchReference
                        ? "Sing in the reference key, in any comfortable octave. Keep the same octave shift throughout."
                        : "Any comfortable starting pitch is fine. Keep the same intervals throughout the phrase."
                ).font(.caption).foregroundStyle(.secondary)
                if showPitchGuide, let detected = microphone.pitch {
                    let expected = complete ? nil : echo.offset.map { targets[echo.matched] + $0 }
                    let cents = expected.map { Double(detected.midi - $0) * 100 + detected.cents } ?? detected.cents
                    HStack(spacing: 14) {
                        Text("Hearing \(Pitch.chromatic(detected.midi))\(detected.midi/12-1)").font(.caption).frame(
                            width: 115, alignment: .leading)
                        PitchMeter(cents: cents).frame(height: 24).accessibilityLabel(
                            expected.map { "Pitch offset \(Int(cents)) cents from target MIDI note \($0)" }
                                ?? "Pitch steadiness")
                        Text(abs(cents) < 35 ? "Steady" : cents > 0 ? "Lower" : "Higher").font(.caption)
                            .foregroundStyle(abs(cents) < 35 ? Color.moss : Color.clay).frame(width: 55)
                    }
                }
                HStack {
                    Label(
                        complete ? "Phrase matched" : "\(echo.matched) of \(chunk.count) notes matched",
                        systemImage: complete ? "checkmark.circle.fill" : "waveform"
                    ).foregroundStyle(Color.moss)
                    Spacer()
                    Button("Restart") { reset(requireReference: false) }.buttonStyle(.plain)
                    if complete && (phrase + 1) * 8 < notes.count {
                        Button("Next phrase", systemImage: "arrow.right") { phrase += 1 }
                    }
                    Button("Ask about this phrase", systemImage: "bubble.left") { askCoach() }.buttonStyle(.plain)
                }.font(.caption)
                if !feedback.isEmpty {
                    Text(feedback).font(.caption).foregroundStyle(complete ? Color.moss : Color.clay)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            } else {
                Text(guideError ?? "Choose a pitched staff and voice in this passage to make a singing guide.").font(
                    .callout
                ).foregroundStyle(.secondary)
            }
            if let error = microphone.error { Text(error).font(.caption).foregroundStyle(Color.clay) }
            Text(
                "Sing slowly and hold each note for about a second. Leave a short gap between repeated notes. This checks pitch order, not rhythm, words or playing technique. Analysis stays on this Mac; A4 = 440 Hz."
            ).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(
                "Do is the tonic. Minor uses Me, Le and Te; accidentals follow the written spelling. If an imported score has no key mode, major is assumed—choose minor above when appropriate."
            ).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .onAppear {
            rebuild()
            if state.isPreview && CommandLine.arguments.contains("--practice-check") { nativeChecks() }
        }
        .onChange(of: guideKey) { _, _ in rebuild() }
        .onChange(of: phrase) { _, _ in reset() }
        .onChange(of: octaves) { _, _ in reset() }
        .onChange(of: matchReference) { _, _ in reset() }
        .onChange(of: microphone.heldPitch) { _, value in
            guard microphone.listening, played, !audio.isPlaying, !audio.isPreparing else { return }
            receive(value)
        }
        .onChange(of: audio.beat) { _, beat in
            if let start = referenceStart, audio.isPlaying, audio.studyPlayhead == nil,
                let note = chunk.last(where: { $0.start <= start + beat })
            {
                locate(note.id)
            }
        }
        .onChange(of: audio.isPreparing) { _, preparing in if preparing { microphone.stop() } }
        .onChange(of: audio.isPlaying) { _, playing in if playing { microphone.stop() } }
        .onDisappear {
            microphone.stop()
            audio.stop()
        }
    }
    private func reset(requireReference: Bool = true) {
        microphone.stop()
        audio.stop()
        referenceStart = nil
        echo = MelodyEchoAttempt()
        feedback = ""
        if requireReference { played = false }
        if let first = chunk.first { locate(first.id) }
    }
    private func rebuild() {
        reset()
        phrase = 0
        melody = nil
        guideError = nil
        if let voice {
            do { melody = try PassageMelody(study: study, voice: voice, minorOverride: minorOverride) } catch {
                guideError = error.localizedDescription
            }
        }
        if !targets.allSatisfy({ (21...108).contains($0) }) { octaves = 0 }
        if let first = chunk.first { locate(first.id) }
    }
    private func reference(_ note: PassageSingingNote, index: Int) {
        microphone.stop()
        audio.stop()
        referenceStart = nil
        echo = MelodyEchoAttempt()
        feedback = ""
        locate(note.id)
        if !state.isPreview { audio.note(note.tone.midi + octaves * 12) }
        if index == 0 { played = true }
    }
    private func hearPhrase() {
        reset()
        guard let first = chunk.first else { return }
        locate(first.id)
        let score = Score(
            tempo: study.document.tempo * study.speed,
            notes: chunk.map {
                ScoreNote(
                    midi: $0.tone.midi + octaves * 12, start: $0.start - first.start, duration: $0.duration,
                    spelling: $0.tone.pitch)
            })
        referenceStart = first.start
        if !state.isPreview { audio.play(score) }
        played = true
    }
    private func listen() {
        guard !state.isPreview else { return }
        if microphone.listening {
            microphone.stop()
            return
        }
        referenceStart = nil
        echo = MelodyEchoAttempt()
        feedback = ""
        awaitingMicrophone = true
        Task {
            await microphone.start()
            awaitingMicrophone = false
        }
    }
    private func receive(_ midi: Int?) {
        let result = echo.hear(midi, targets: targets, matchReference: matchReference)
        switch result {
        case .ignored: break
        case .wrong(let expected, let heard):
            feedback =
                "Heard \(Pitch.chromatic(heard))\(heard/12-1). Aim for \(Pitch.chromatic(expected))\(expected/12-1), then try that note again."
        case .matched:
            feedback = ""
            locate(chunk[min(echo.matched, chunk.count - 1)].id)
        case .complete:
            feedback = "The pitch sequence matched. Try it again, or bring the rhythm back with passage playback."
            microphone.stop()
            locate(chunk[chunk.count - 1].id)
        }
    }
    private func askCoach() {
        guard let voice else { return }
        let line = chunk.map { "\($0.tone.noteName) / \($0.tone.solfege)" }.joined(separator: ", ")
        state.ask(
            "Help me sing this phrase from \(study.passageLabel), \(voice.label). My solfège interpretation is \(tonicLabel). These are the selected reference notes: \(line). Explain the intervals and suggest a small singing exercise. No recording or assessment of my voice is supplied.",
            study: study.reference)
    }
    private func nativeChecks() {
        let originalPhrase = phrase
        hearPhrase()
        PassageDiagnostics.checks["singingGuide"] = !chunk.isEmpty && chunk.allSatisfy { !$0.tone.solfege.isEmpty }
        let first = chunk.first
        if let first { reference(first, index: 0) }
        PassageDiagnostics.checks["referenceEnablesListening"] = played && first != nil
        reset()
        played = true
        for midi in targets {
            receive(nil)
            receive(midi)
        }
        PassageDiagnostics.checks["melodySequence"] = complete
        reset()
        PassageDiagnostics.checks["singingReset"] = echo.matched == 0 && !played
        phrase = originalPhrase
    }
}
