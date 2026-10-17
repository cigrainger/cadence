// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import MusicCore
import SwiftUI

struct PlayChordView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var midi: MIDIKeyboard
    @ObservedObject var audio: AudioPlayer
    @State private var quality = ChordQuality.major
    @State private var inversion = 0
    @State private var listening = false
    @State private var capture = MIDIStepCapture()
    @State private var tries = 0
    @State private var assisted = false
    @State private var solved = false
    @State private var lastNotes: [Int] = []
    @State private var judgement: ChordJudgement?
    private let qualities: [ChordQuality] = [.major, .minor, .diminished, .augmented, .dominant7, .maj7, .min7]
    private var chord: PlayedChord { PlayedChord(root: state.root, quality: quality, inversion: inversion) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MIDIConnectionView(midi: midi)
            HStack(spacing: 14) {
                Picker(
                    "Chord",
                    selection: Binding(
                        get: { quality },
                        set: { value in
                            inversion = min(inversion, value.intervals.count - 1)
                            quality = value
                        })
                ) { ForEach(qualities, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 185)
                Picker("Position", selection: $inversion) {
                    ForEach(0..<quality.intervals.count, id: \.self) {
                        Text(["Root position", "First inversion", "Second inversion", "Third inversion"][$0]).tag($0)
                    }
                }.frame(width: 200)
                Spacer()
                Button(
                    listening ? "Pause input" : "Listen to keyboard",
                    systemImage: listening ? "pause.circle" : "pianokeys"
                ) {
                    listening.toggle()
                    capture.reset(held: midi.keyboard.downNotes)
                }.disabled(!midi.connected || solved)
            }.controlSize(.small)
            VStack(spacing: 12) {
                Text("Play \(chord.title)").font(.system(size: 27, weight: .medium, design: .serif))
                Text(chord.inversionLabel + " · any comfortable register · octave doublings are welcome").font(.callout)
                    .foregroundStyle(.secondary)
                Text(
                    solved
                        ? "Chord matched."
                        : capture.waitingForRelease
                            ? "Release the held keys, then play your answer."
                            : listening
                                ? "Play all the chord tones, then release the keys to check."
                                : "Turn on keyboard input when you are ready."
                ).foregroundStyle(solved ? Color.moss : .secondary)
                if !midi.keyboard.downNotes.isEmpty {
                    Text("Held: " + names(midi.keyboard.downNotes.sorted())).font(.caption).foregroundStyle(.secondary)
                }
                if let judgement {
                    Text("You played: " + names(lastNotes)).font(.callout)
                    if !judgement.missing.isEmpty {
                        Text(
                            "Missing chord tones: "
                                + judgement.missing.map { spelling($0).name }.joined(separator: " · ")
                        ).foregroundStyle(Color.clay)
                    }
                    if !judgement.extra.isEmpty {
                        Text(
                            "Outside this chord: " + judgement.extra.map { spelling($0).name }.joined(separator: " · ")
                        ).foregroundStyle(Color.clay)
                    }
                    if !judgement.bassCorrect {
                        Text("For this position, put \(chord.bass.name) in the bass.").foregroundStyle(Color.clay)
                    }
                }
                if assisted {
                    Text(
                        "Chord tones: " + chord.tones.map(\.name).joined(separator: " · ") + " · bass: "
                            + chord.bass.name
                    ).font(.callout).foregroundStyle(Color.moss)
                }
                HStack(spacing: 12) {
                    Button("Show tones") { reveal() }
                    Button("Hear example", systemImage: "speaker.wave.2") {
                        reveal()
                        listening = false
                        capture.reset(held: midi.keyboard.downNotes)
                        if !state.isPreview { audio.chord(chord.reference) }
                    }
                    if solved {
                        Button("Practise another", systemImage: "arrow.right") { next() }.buttonStyle(.cadencePrimary)
                    } else {
                        Button("Skip for now") { if recordOther(.skipped) { next() } }
                    }
                }.controlSize(.small)
                Text(
                    "Checks chord tones and the lowest pitch. Timing, fingering and technique are not graded. Sustain does not join separate answers."
                ).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if assisted {
                    Text("This answer will be recorded as assisted.").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity).padding(.vertical, 14)
        }
        .onAppear {
            capture.reset(held: midi.keyboard.downNotes)
            if state.isPreview && CommandLine.arguments.contains("--midi-chord-check") {
                midi.installPreview()
                listening = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    midi.previewInput([
                        .noteOn(channel: 0, note: 60, velocity: 90), .noteOn(channel: 0, note: 64, velocity: 90),
                        .noteOff(channel: 0, note: 60), .noteOff(channel: 0, note: 64),
                    ])
                    MIDIDiagnostics.checks["incompleteChordRecorded"] =
                        state.journal.attempts.last?.outcome == .incorrect
                    midi.previewInput([
                        .noteOn(channel: 0, note: 60, velocity: 90), .noteOn(channel: 0, note: 64, velocity: 90),
                        .noteOn(channel: 0, note: 67, velocity: 90), .noteOff(channel: 0, note: 60),
                        .noteOff(channel: 0, note: 64), .noteOff(channel: 0, note: 67),
                    ])
                    MIDIDiagnostics.checks["chordSolved"] = solved
                    MIDIDiagnostics.checks["midiAttemptInput"] =
                        state.journal.attempts.last?.input == .midi && state.journal.attempts.last?.assisted == false
                    MIDIDiagnostics.checks["twoGesturesTwoAttempts"] = state.journal.attempts.count == 2
                }
            }
        }
        .onChange(of: quality) { _, _ in
            inversion = min(inversion, quality.intervals.count - 1)
            reset()
        }
        .onChange(of: inversion) { _, _ in reset() }
        .onChange(of: state.root) { _, _ in reset() }
        .onChange(of: midi.connectionRevision) { _, _ in
            listening = false
            capture.reset(held: midi.keyboard.downNotes)
        }
        .onChange(of: midi.connected) { _, connected in
            if !connected { listening = false }
            capture.reset(held: midi.keyboard.downNotes)
        }
        .onChange(of: audio.isPlaying) { _, playing in
            if playing {
                listening = false
                capture.reset(held: midi.keyboard.downNotes)
            }
        }
        .onReceive(midi.updates) { update in
            guard listening, !solved, !audio.isPlaying, !audio.isPreparing, state.isPreview || NSApp.isActive else {
                return
            }
            if let notes = capture.receive(update.message, state: update.keyboard) {
                lastNotes = notes
                let result = chord.judge(notes)
                judgement = result
                guard
                    state.recordChord(
                        chord, notes: notes, correct: result.correct, assisted: assisted, ordinal: tries + 1)
                else { return }
                tries += 1
                if result.correct {
                    solved = true
                    listening = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            listening = false
            capture.reset(held: midi.keyboard.downNotes)
        }
        .onDisappear {
            listening = false
            audio.stop()
        }
    }
    private func spelling(_ midi: Int) -> Pitch {
        chord.tones.first { $0.pc == mod(midi) }
            ?? Pitch.spelled(midi, flats: chord.tones.contains { $0.accidental < 0 })
    }
    private func names(_ notes: [Int]) -> String {
        notes.map { Solfege.noteName(midi: $0, pitch: spelling($0)) }.joined(separator: " · ")
    }
    private func reset() {
        tries = 0
        solved = false
        assisted = false
        lastNotes = []
        judgement = nil
        capture.reset(held: midi.keyboard.downNotes)
        audio.stop()
    }
    private func next() {
        quality = qualities[(qualities.firstIndex(of: quality)! + 1) % qualities.count]
        reset()
        listening = midi.connected
    }
    private func reveal() {
        guard !assisted && !solved else { return }
        if recordOther(.revealed) { assisted = true }
    }
    @discardableResult private func recordOther(_ outcome: PracticeOutcome) -> Bool {
        state.recordAttempt(
            PracticeAttempt(
                sessionID: state.practiceSessionID, activityID: chord.id,
                title: "\(chord.title) · \(chord.inversionLabel)",
                skills: ["Chord playing", quality.rawValue, "Inversion \(inversion)"], input: .midi, outcome: outcome,
                assisted: assisted || outcome == .revealed, keyPC: chord.root.pc, target: chord.reference))
    }
}
