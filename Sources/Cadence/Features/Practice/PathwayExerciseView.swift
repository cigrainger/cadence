// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import MusicCore
import SwiftUI

struct PathwayExerciseView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var midi: MIDIKeyboard
    @ObservedObject var audio: AudioPlayer
    @State private var feedback = ""
    @State private var error: String?
    @State private var solved = false
    @State private var shown = false
    @State private var assisted = false
    @State private var played = false
    @State private var attempts = 0
    @State private var listening = false
    @State private var capture = MIDIStepCapture()
    @State private var fewerChoices = false
    var body: some View {
        if let path = state.currentPathway, let task = state.currentPathwayTask {
            let current = state.pathwayCurrent(path)
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Button("Back to pathway", systemImage: "arrow.left") { state.returnToPiecePathway(path) }
                    Spacer()
                    Button("Free practice") { state.pathwaySession = nil }
                }.controlSize(.small)
                Text(state.pieceForPathway(path)?.title ?? path.outline.title).font(
                    .system(size: 25, weight: .medium, design: .serif))
                Text(task.scope.label + " · " + task.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                if !current {
                    Text("The score has changed. Return to its Learn tab to make a fresh plan.").foregroundStyle(
                        Color.clay)
                }
                Card(title: task.title, padding: 24, spacing: 18) {
                    Text(task.instructions).font(.callout).fixedSize(horizontal: false, vertical: true)
                    if task.review.lastGrade == .again && !solved {
                        Text("This was difficult last time. Start with a smaller step, then try recalling it again.")
                            .font(.callout).foregroundStyle(Color.moss).fixedSize(horizontal: false, vertical: true)
                    }
                    if task.kind == .passage {
                        Text(task.readyWhen).font(.callout).foregroundStyle(.secondary).fixedSize(
                            horizontal: false, vertical: true)
                        HStack {
                            Button("Open passage", systemImage: "play.circle") { state.openPathwayPassage() }
                                .buttonStyle(.cadencePrimary)
                            if task.scope.throughBar > task.scope.fromBar {
                                Button("Start with one bar") { state.openPathwayPassage(reduced: true) }
                            }
                        }
                        Text(
                            "Play on your instrument in Studies, then tell Cadence how it felt. A smaller passage counts as supported practice, not a check of the full passage."
                        ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else if task.kind == .chord {
                        MIDIConnectionView(midi: midi)
                        Text(task.readyWhen).font(.caption).foregroundStyle(.secondary)
                        Button(listening ? "Pause keyboard" : "Listen to keyboard", systemImage: "pianokeys") {
                            listening.toggle()
                            capture.reset(held: midi.keyboard.downNotes)
                        }.disabled(!midi.connected || solved || shown || audio.isPlaying)
                        if listening {
                            Text(
                                capture.waitingForRelease
                                    ? "Release the held keys before starting."
                                    : "Play the chord, then release to check."
                            ).foregroundStyle(Color.moss).font(.callout)
                        }
                        if !midi.keyboard.downNotes.isEmpty {
                            Text(
                                "Held: "
                                    + midi.keyboard.downNotes.sorted().map {
                                        Solfege.noteName(midi: $0, pitch: Pitch.spelled($0, flats: false))
                                    }.joined(separator: " · ")
                            ).font(.callout)
                        }
                        Button("Hear the chord · with support", systemImage: "speaker.wave.2") {
                            hint(task, hear: true)
                        }.disabled(solved || shown)
                    } else {
                        if task.needsAudio {
                            Button(played ? "Hear again" : "Listen", systemImage: "play.fill") {
                                if let sound = task.audio {
                                    audio.play(sound)
                                    played = true
                                }
                            }.buttonStyle(.cadencePrimary)
                        }
                        let indices = task.choices.indices.filter {
                            !fewerChoices || $0 == task.answer
                                || $0 == task.choices.indices.first(where: { $0 != task.answer })
                        }
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(indices, id: \.self) { index in
                                Button {
                                    answer(task, index: index)
                                } label: {
                                    Text(task.choices[index]).font(.callout).fixedSize(
                                        horizontal: false, vertical: true
                                    ).frame(maxWidth: .infinity, minHeight: 44).padding(12).background(
                                        (solved || shown) && task.answer == index
                                            ? Color.moss.opacity(0.16) : Color.canvas,
                                        in: RoundedRectangle(cornerRadius: 10))
                                }.buttonStyle(.plain).disabled(
                                    solved || shown || (task.needsAudio && !played) || audio.isPlaying)
                            }
                        }
                        if !solved && !shown && !fewerChoices && task.choices.count > 2 {
                            Button("Make it smaller · two choices") {
                                do {
                                    try state.recordPathwayResult(
                                        .supported, input: .choice, outcome: .revealed, assisted: true,
                                        expectedTaskID: task.id)
                                    fewerChoices = true
                                    assisted = true
                                    error = nil
                                } catch { self.error = error.localizedDescription }
                            }.font(.caption)
                        }
                    }
                    if !feedback.isEmpty {
                        Text(feedback).font(.callout).foregroundStyle(solved ? Color.moss : Color.clay).fixedSize(
                            horizontal: false, vertical: true
                        ).accessibilityAddTraits(.updatesFrequently)
                    }
                    if solved || shown {
                        Text(task.explanation).font(.callout).foregroundStyle(.secondary).fixedSize(
                            horizontal: false, vertical: true)
                    }
                    if task.kind != .passage {
                        HStack {
                            if !solved && !shown { Button("Show answer") { hint(task, hear: false) } }
                            if let piece = state.pieceForPathway(path) {
                                Button("Open notation · with support") {
                                    do {
                                        try state.recordPathwayResult(
                                            .supported, input: task.kind == .chord ? .midi : .choice,
                                            outcome: .revealed, assisted: true, expectedTaskID: task.id)
                                        assisted = true
                                        state.openLibraryPiece(
                                            piece, from: task.scope.fromBar - 1, through: task.scope.throughBar - 1,
                                            partID: task.scope.partID)
                                    } catch { self.error = error.localizedDescription }
                                }.disabled(solved || shown)
                            }
                            Spacer()
                            if solved || shown {
                                Button("Continue", systemImage: "arrow.right") { state.nextPathwayTask() }.buttonStyle(
                                    .cadencePrimary)
                            } else {
                                Button("Skip for now") { state.skipPathwayTask() }
                            }
                        }.controlSize(.small)
                        Text(
                            assisted
                                ? "Recorded as supported practice. The review will return sooner."
                                : "Checked answers shape the review schedule. They do not assess physical technique."
                        ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.disabled(!current)
                if let error {
                    Text(error + " You can try saving this check again.").font(.callout).foregroundStyle(Color.clay)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(task.review.reason()).font(.caption).foregroundStyle(.secondary)
            }
            .onAppear {
                capture.reset(held: midi.keyboard.downNotes)
                if state.isPreview && CommandLine.arguments.contains("--piece-midi"), task.kind == .chord {
                    midi.installPreview()
                    listening = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        listening = true
                        capture.reset(held: midi.keyboard.downNotes)
                        @MainActor func gesture(_ notes: [Int]) {
                            midi.previewInput(
                                notes.map { .noteOn(channel: 0, note: $0, velocity: 90) }
                                    + notes.map { .noteOff(channel: 0, note: $0) })
                        }
                        gesture(Array(task.target.dropLast()))
                        PiecePathwayDiagnostics.checks["pathwayMIDIMissRecorded"] =
                            state.currentPathwayTask?.review.lastGrade == .again
                        gesture(task.target)
                        PiecePathwayDiagnostics.checks["pathwayMIDIAnswerMatched"] = solved
                        PiecePathwayDiagnostics.checks["pathwayMIDIRetryNotPromoted"] =
                            state.currentPathwayTask?.review.encounters == 1
                            && state.currentPathwayTask?.review.intervalDays == 0
                    }
                }
                if task.review.lastEpisode == state.pathwaySession?.episode {
                    assisted = task.review.lastGrade != .good
                    solved = task.review.lastGrade == .good
                }
            }
            .onReceive(midi.updates) { update in
                guard task.kind == .chord, listening, !solved, !shown, current, !audio.isPlaying, !audio.isPreparing,
                    state.destination == .practice, state.isPreview || NSApp.isActive
                else { return }
                if let notes = capture.receive(update.message, state: update.keyboard) {
                    check(task, correct: task.chordMatches(notes), input: .midi, notes: notes)
                }
            }
            .onChange(of: midi.connectionRevision) { _, _ in
                listening = false
                capture.reset(held: midi.keyboard.downNotes)
            }
            .onChange(of: midi.connected) { _, _ in
                listening = false
                capture.reset(held: midi.keyboard.downNotes)
            }
            .onChange(of: audio.isPlaying) { _, active in
                if active {
                    listening = false
                    capture.reset(held: midi.keyboard.downNotes)
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
        } else {
            ContentUnavailableView(
                "This exercise is no longer available", systemImage: "music.note",
                description: Text("Return to Library to choose a piece and its pathway."))
            Button("Free practice") { state.pathwaySession = nil }
        }
    }
    private func answer(_ task: PieceTask, index: Int) {
        check(task, correct: index == task.answer, input: .choice, choice: task.choices[index])
    }
    private func check(_ task: PieceTask, correct: Bool, input: PracticeInput, notes: [Int] = [], choice: String? = nil)
    {
        do {
            try state.recordPathwayResult(
                correct ? .good : .again, input: input, outcome: correct ? .correct : .incorrect,
                assisted: assisted || attempts > 0, played: notes, choice: choice, expectedTaskID: task.id,
                ordinal: attempts + 1)
            attempts += 1
            solved = correct
            error = nil
            if !correct || attempts > 1 { assisted = true }
            if correct {
                listening = false
                feedback = "Matched. Your review schedule is saved."
            } else {
                feedback = "Not quite yet. Revisit the source or use a smaller step; this will return for review."
            }
        } catch { self.error = error.localizedDescription }
    }
    private func hint(_ task: PieceTask, hear: Bool) {
        do {
            try state.recordPathwayResult(
                .supported, input: task.kind == .chord ? .midi : .choice, outcome: .revealed, assisted: true,
                expectedTaskID: task.id)
            assisted = true
            error = nil
            listening = false
            if hear {
                if let sound = task.audio { audio.play(sound) }
            } else {
                shown = true
                feedback = task.answer.map { "Answer: " + task.choices[$0] } ?? "Compare the source tones below."
            }
        } catch { self.error = error.localizedDescription }
    }
}

struct PathwayPassageReviewView: View {
    @EnvironmentObject private var state: AppState
    @State private var error: String?
    var body: some View {
        if let path = state.currentPathway, let task = state.currentPathwayTask, task.kind == .passage {
            Card(title: "How did this passage feel?", padding: 16, spacing: 12) {
                Text(task.title + " · " + task.scope.label).font(.callout).fixedSize(horizontal: false, vertical: true)
                Text(
                    state.pathwaySession?.reduced == true
                        ? "Working on the first bar. A comfortable report counts as supported practice for the full passage."
                        : "Your report guides the next review. Cadence is not grading your performance here."
                ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !state.pathwayPassageMatches {
                    Text("The part, staves or bars have changed. Reopen the linked passage to record a result for it.")
                        .font(.caption).foregroundStyle(Color.clay).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Try guided MIDI") { state.guidedStudyID = state.studies.active?.id }.disabled(
                        !state.pathwayPassageMatches)
                    Button("Felt difficult") { record(.again) }.disabled(!state.pathwayPassageMatches)
                    Button("Needed support") { record(.supported) }.disabled(!state.pathwayPassageMatches)
                    Button("Comfortable") { record(.good) }.disabled(!state.pathwayPassageMatches)
                    Spacer()
                    if !state.pathwayPassageMatches { Button("Reopen linked bars") { state.openPathwayPassage() } }
                    Button("Back to pathway") { state.returnToPiecePathway(path) }
                }.controlSize(.small)
                if let error { Text(error).font(.caption).foregroundStyle(Color.clay) }
            }
        }
    }
    private func record(_ grade: ReviewGrade) {
        do {
            try state.recordPathwayResult(
                grade, input: .selfReport, outcome: grade == .again ? .incorrect : .correct,
                assisted: grade == .supported)
            state.nextPathwayTask()
        } catch { self.error = error.localizedDescription }
    }
}
