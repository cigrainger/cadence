// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct IntervalSingingView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var microphone: Microphone
    @ObservedObject var audio: AudioPlayer
    @State private var intervalSet = SingingIntervalSet.scale
    @State private var direction = SingingDirection.mixed
    @State private var referenceOctave = 3
    @State private var matchReference = false
    @State private var question: PracticeQuestion?
    @State private var echo = IntervalEchoAttempt()
    @State private var played = false
    @State private var solved = false
    @State private var attempts = 0
    @State private var feedback = ""
    @State private var awaitingMicrophone = false
    private var deck: [PracticeQuestion] {
        IntervalSingingFactory.deck(
            root: state.root, scale: state.scale, set: intervalSet, direction: direction, octave: referenceOctave)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ChoiceMenu(
                    title: "Interval selection", selection: $intervalSet, options: SingingIntervalSet.allCases,
                    label: { $0.rawValue })
                ChoiceMenu(
                    title: "Interval direction", selection: $direction, options: SingingDirection.allCases,
                    label: { $0.rawValue })
                ChoiceMenu(
                    title: "Reference tonic", selection: $referenceOctave, options: [2, 3, 4],
                    label: { Solfege.noteName(midi: 12 * ($0 + 1) + state.root.pc, pitch: state.root) }
                ).frame(width: 100)
            }
            Text("Echo the interval").font(.system(size: 25, weight: .medium, design: .serif))
            Text("Hear two notes. Then sing both in the same order, holding each for about a second.").font(
                .system(size: 12)
            ).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let question, let interval = question.singingInterval {
                HStack(spacing: 12) {
                    Button(played ? "Hear interval again" : "Play interval", systemImage: "play.fill") {
                        play(interval.audio)
                    }.buttonStyle(.cadencePrimary).keyboardShortcut(.space, modifiers: [])
                    Button("First note only") {
                        microphone.stop()
                        echo.reset()
                        audio.play(
                            Score(tempo: 90, notes: [ScoreNote(midi: interval.first.midi, start: 0, duration: 1.1)]))
                    }
                    Spacer()
                    Toggle("Solfège guide", isOn: $state.showSolfege).toggleStyle(.checkbox).font(.caption)
                }
                if state.showSolfege || solved { singingGuide(interval) }
                HStack(spacing: 10) {
                    Toggle("Match reference notes", isOn: $matchReference).toggleStyle(.checkbox).font(.caption)
                        .disabled(microphone.listening)
                    Text(
                        matchReference
                            ? "Both notes may shift together by an octave."
                            : "Any starting pitch is fine. Match the distance and direction."
                    ).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 12) {
                    Image(systemName: solved ? "checkmark.circle.fill" : "waveform").font(.system(size: 22))
                        .foregroundStyle(Color.moss).frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            solved
                                ? "You’ve got the interval."
                                : echo.firstHeard == nil
                                    ? "First, sing the starting note."
                                    : "First note: \(heardNote(echo.firstHeard!)). Now sing the second."
                        ).font(.system(size: 13, weight: .medium))
                        Text("Two steady notes, checked on this Mac. Nothing is uploaded.").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if awaitingMicrophone { ProgressView().controlSize(.small) }
                    Button(
                        microphone.listening ? "Stop listening" : "Listen to my voice",
                        systemImage: microphone.listening ? "stop.circle" : "mic"
                    ) {
                        if microphone.listening {
                            microphone.stop()
                        } else {
                            echo.reset()
                            feedback = ""
                            awaitingMicrophone = true
                            Task {
                                await microphone.start()
                                awaitingMicrophone = false
                            }
                        }
                    }.disabled(!played || audio.isPlaying || solved || awaitingMicrophone)
                    if echo.firstHeard != nil && !solved {
                        Button("Restart both notes") {
                            echo.reset()
                            microphone.resetHold()
                            feedback = ""
                        }
                    }
                }.padding(12).background(Color.canvas, in: RoundedRectangle(cornerRadius: 10))
                if let pitch = microphone.pitch {
                    HStack(spacing: 12) {
                        Text("\(Pitch.chromatic(pitch.midi))\(pitch.midi/12-1)").font(
                            .system(size: 16, weight: .medium, design: .serif))
                        PitchMeter(cents: pitch.cents).frame(height: 22)
                        Text("\(Int(pitch.cents)) cents").font(.system(.caption, design: .monospaced)).foregroundStyle(
                            .secondary
                        ).frame(width: 68, alignment: .trailing)
                    }
                } else if microphone.listening {
                    Text("Listening for a clear, steady note…").font(.caption).foregroundStyle(.secondary)
                }
                if !feedback.isEmpty {
                    Text(feedback).font(.system(size: 12)).foregroundStyle(solved ? Color.moss : Color.clay)
                        .multilineTextAlignment(.center).accessibilityAddTraits(.updatesFrequently)
                }
                if let error = microphone.error { Text(error).font(.caption).foregroundStyle(Color.clay) }
                HStack(spacing: 12) {
                    if solved {
                        Button("Next interval", systemImage: "arrow.right") { newQuestion() }.buttonStyle(
                            .cadencePrimary
                        ).keyboardShortcut(.return, modifiers: [])
                    } else {
                        Button("Skip for now", systemImage: "arrow.right") {
                            if state.recordEvidence(question, outcome: .skipped, input: .singing) { newQuestion() }
                        }
                    }
                    Spacer()
                    Text(solved ? "Return for next interval" : "Space to hear the interval").font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear {
            if state.isPreview && CommandLine.arguments.contains("--singing-down") { direction = .descending }
            if state.isPreview && CommandLine.arguments.contains("--singing-chromatic") { intervalSet = .chromatic }
            newQuestion()
        }
        .onChange(of: intervalSet) { _, _ in newQuestion() }
        .onChange(of: direction) { _, _ in newQuestion() }
        .onChange(of: referenceOctave) { _, _ in newQuestion() }
        .onChange(of: state.root) { _, _ in newQuestion() }
        .onChange(of: state.scale) { _, _ in newQuestion() }
        .onChange(of: matchReference) { _, _ in
            echo.reset()
            microphone.stop()
            feedback = ""
        }
        .onChange(of: microphone.heldPitch) { _, value in
            guard let value, let question, let interval = question.singingInterval, microphone.listening, played,
                !solved, !audio.isPlaying
            else { return }
            switch echo.hear(value, for: interval, matchReference: matchReference) {
            case .ignored: break
            case .firstNote: feedback = ""
            case .wrongReference:
                miss(question)
                feedback =
                    "Start on \(interval.first.pitch.name), in any comfortable octave, then sing the second note."
            case .wrongInterval(let distance):
                miss(question)
                feedback =
                    "You sang \(SingingInterval.describe(distance)). Aim for \(interval.prompt.lowercased()). Try the second note again, or restart both."
            case .correct:
                guard
                    let reward = state.record(
                        question, correct: true, firstTry: attempts == 0, revealed: false, input: .singing,
                        played: [echo.firstHeard, value].compactMap { $0 }, ordinal: attempts + 1)
                else {
                    echo.reset()
                    feedback = state.message ?? "The answer could not be saved."
                    return
                }
                solved = true
                microphone.stop()
                feedback =
                    "\(interval.prompt) matched · \(heardNote(echo.firstHeard!)) → \(heardNote(value))"
                    + (state.showRewards && reward > 0 ? " +\(reward) points" : "")
            }
        }
        .onDisappear {
            microphone.stop()
            audio.stop()
        }
    }
    private func singingGuide(_ interval: SingingInterval) -> some View {
        VStack(spacing: 7) {
            Text(interval.prompt).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                tone(interval.first, number: 1, captured: echo.firstHeard != nil || solved)
                Image(systemName: interval.semitones < 0 ? "arrow.down.right" : "arrow.up.right").font(
                    .system(size: 18)
                ).foregroundStyle(Color.moss)
                tone(interval.second, number: 2, captured: solved)
            }
            if state.showSolfege {
                Text("Movable Do · Do is the tonic · minor uses Me, Le, and Te · ′ marks the upper octave").font(
                    .system(size: 10)
                ).foregroundStyle(.secondary)
            }
        }
    }
    private func tone(_ note: SingingTone, number: Int, captured: Bool) -> some View {
        HStack(spacing: 12) {
            Text("\(number)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(state.showSolfege ? note.singingLabel : note.noteName).font(
                .system(size: 26, weight: .medium, design: .serif)
            ).foregroundStyle(Color.moss)
            VStack(alignment: .leading, spacing: 3) {
                if state.showSolfege { Text(note.noteName).font(.system(size: 12, weight: .medium)) }
                Text("Degree \(note.degreeLabel)").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if captured { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.moss) }
        }.padding(.horizontal, 15).padding(.vertical, 10).frame(maxWidth: .infinity).background(
            captured ? Color.moss.opacity(0.09) : Color.canvas, in: RoundedRectangle(cornerRadius: 10))
    }
    private func heardNote(_ midi: Int) -> String { "\(Pitch.chromatic(midi))\(midi/12-1)" }
    private func play(_ score: Score) {
        microphone.stop()
        echo.reset()
        feedback = ""
        audio.play(score)
        played = true
    }
    private func miss(_ question: PracticeQuestion) {
        guard
            state.record(
                question, correct: false, firstTry: attempts == 0, revealed: false, input: .singing,
                played: [echo.firstHeard, microphone.heldPitch].compactMap { $0 }, ordinal: attempts + 1) != nil
        else {
            feedback = state.message ?? "The answer could not be saved."
            return
        }
        attempts += 1
    }
    private func newQuestion() {
        state.beginPracticeSession()
        microphone.stop()
        audio.stop()
        echo.reset()
        played = false
        solved = false
        attempts = 0
        feedback = ""
        let questions = deck
        if state.isPreview, let argument = CommandLine.arguments.firstIndex(of: "--interval"),
            argument + 1 < CommandLine.arguments.count, let distance = Int(CommandLine.arguments[argument + 1]),
            let chosen = questions.first(where: { $0.singingInterval?.semitones == distance })
        {
            question = chosen
        } else {
            question = state.history.next(in: questions, avoiding: question?.id)
        }
        if state.isPreview, let interval = question?.singingInterval {
            if CommandLine.arguments.contains("--singing-first") || CommandLine.arguments.contains("--singing-complete")
            {
                played = true
                _ = echo.hear(interval.first.midi, for: interval)
            }
            if CommandLine.arguments.contains("--singing-complete") {
                _ = echo.hear(interval.second.midi, for: interval)
                solved = true
                feedback =
                    "\(interval.prompt) matched · \(heardNote(interval.first.midi)) → \(heardNote(interval.second.midi))"
            }
        }
    }
}
