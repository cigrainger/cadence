// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import MusicCore
import SwiftUI

@MainActor enum GuidedDiagnostics { static var checks: [String: Bool] = [:] }

struct GuidedPracticeView: View {
    @EnvironmentObject private var state: AppState
    let study: MusicStudy
    @ObservedObject var midi: MIDIKeyboard
    @ObservedObject var audio: AudioPlayer
    @StateObject private var session = GuidedPracticeSession()
    @State private var scoreHeight: CGFloat = 240
    @State private var renderError: String?
    @State private var accompany = false
    @State private var discarding = false
    private var selection: String {
        "\(study.id):\(study.partID):\(study.staff ?? 0):\(study.from):\(study.through):\(study.speed)"
    }
    private var step: GuidedStep? { session.follower?.current }
    private var head: StudyPlayhead? {
        (step?.beat ?? session.plan?.steps.last?.beat).map {
            StudyPlayhead(sourceBeat: $0, isCountIn: false, countInRemaining: 0, cycle: 0)
        }
    }
    var body: some View {
        VStack(spacing: 16) {
            Card(
                title: "Play with me", subtitle: "Wait-for-me practice · exact pitches · at your pace", padding: 18,
                spacing: 12
            ) {
                MIDIConnectionView(midi: midi)
                HStack {
                    Text(study.staff.map { "Staff \($0)" } ?? "Both notation staves").fontWeight(.medium)
                    Text(study.passageLabel).foregroundStyle(.secondary)
                    Spacer()
                    if let follower = session.follower {
                        Text("\(follower.index) / \(follower.plan.steps.count) steps").monospacedDigit()
                    }
                }.font(.callout)
                HStack {
                    Button(
                        session.listening ? "Pause" : "Listen to keyboard",
                        systemImage: session.listening ? "pause.fill" : "pianokeys"
                    ) {
                        if session.listening {
                            pause()
                        } else {
                            audio.stop()
                            state.microphone.stop()
                            session.start(held: midi.keyboard.downNotes)
                            playOtherHand()
                        }
                    }.buttonStyle(.cadencePrimary).disabled(
                        !midi.connected || session.result != nil || session.plan == nil)
                    Button("Restart passage", systemImage: "arrow.counterclockwise") { configure() }.disabled(
                        session.hasUnsavedResult)
                    Button("Show next notes") { session.hint() }.disabled(step == nil)
                    Spacer()
                    if study.staff != nil {
                        Toggle("Hear other hand", isOn: $accompany).toggleStyle(.checkbox)
                            .help("The other staff plays one segment at each guided step; it waits with you.")
                    }
                }.controlSize(.small)
                if let follower = session.follower, !follower.complete {
                    Text(
                        follower.waitingForRelease
                            ? "Release the held keys before continuing."
                            : session.listening
                                ? "Read the highlighted notes. Play chord notes together; the score waits for you."
                                : "Choose a hand above, then start when ready."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                    if follower.hints.contains(follower.index), let step {
                        Text(
                            "Next: "
                                + step.notes.map {
                                    Solfege.noteName(
                                        midi: $0, pitch: Pitch.spelled($0, flats: study.selectedMeasures[0].fifths < 0))
                                }.joined(separator: " · ")
                        )
                        .foregroundStyle(Color.moss)
                    }
                }
                if !session.feedback.isEmpty {
                    Text(session.feedback).font(.callout).foregroundStyle(Color.moss).accessibilityAddTraits(
                        .updatesFrequently)
                }
                if let result = session.result {
                    HStack(spacing: 26) {
                        Label(
                            "\(result.firstPass) / \(result.steps.count) matched first time",
                            systemImage: "checkmark.circle")
                        Label("\(result.corrections) corrections", systemImage: "arrow.counterclockwise")
                    }.font(.callout)
                }
                if let error = session.error {
                    Text(error).font(.caption).foregroundStyle(Color.clay).textSelection(.enabled)
                }
                if session.hasUnsavedResult {
                    HStack {
                        Button("Save this pass again") { save() }
                        Button("Discard unsaved result…", role: .destructive) { discarding = true }
                    }
                }
                Text(
                    "Checks pitch order and chord notes. Rhythm, note length, pedal and technique are not graded. Repeated notes need a fresh press; tied notes need no extra press. No sound or MIDI is uploaded."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Card(title: "Follow the notation", padding: 18, spacing: 10) {
                if let renderError { Text(renderError).foregroundStyle(Color.clay).font(.caption) }
                ScoreRenderer(study: study, playhead: head, height: $scoreHeight, error: $renderError).frame(
                    height: scoreHeight
                ).background(.white).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if let result = session.result {
                Card(
                    title: session.saved ? "Pass saved" : "Your guided pass",
                    subtitle: "Guided reading · timing and fluency untested", padding: 18, spacing: 12
                ) {
                    if let bar = result.difficultBars.first {
                        Text("Bar \(bar + 1) needed another look. Try it with the preceding bar for context.").font(
                            .callout)
                        Button("Retry bars \(max(result.scope.from, bar - 1) + 1)–\(bar + 1)") {
                            pause()
                            state.editStudy(study.id) { $0.select(from: max(result.scope.from, bar - 1), through: bar) }
                        }.disabled(!session.saved)
                    } else {
                        Text(
                            "The pitch sequence matched. Try it again, then bring back the rhythm with passage playback."
                        ).font(.callout).foregroundStyle(.secondary)
                    }
                    if session.saved, let progress = state.history.guidedPassages?[result.practiceID] {
                        Text(progress.review.reason()).font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Practise this passage again") { configure() }.disabled(!session.saved)
                }
            } else if let id = session.plan?.id, let previous = state.history.guidedPassages?[id] {
                Text(
                    "Last guided pass: \(previous.latest.firstPass)/\(previous.latest.steps.count) first-time matches · \(previous.latest.corrections) corrections. "
                        + previous.review.reason()
                ).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            configure()
            if state.isPreview && CommandLine.arguments.contains("--guided-practice-check") { previewCheck() }
        }
        .onChange(of: selection) { _, _ in configure() }
        .onChange(of: study.document.originalXML) { _, _ in configure() }
        .onChange(of: state.editor) { _, _ in
            do {
                if try state.guidedPassage(study).id != session.plan?.id { configure() }
            } catch {
                pause()
                session.invalidate(error.localizedDescription)
            }
        }
        .onChange(of: midi.connectionRevision) { _, _ in pause() }
        .onChange(of: midi.connected) { _, connected in if !connected { pause() } }
        .onChange(of: accompany) { _, _ in if session.listening { playOtherHand() } }
        .onReceive(midi.updates) { update in
            guard state.isPreview || NSApp.isActive else { return }
            let result = session.receive(update.message, keyboard: update.keyboard)
            if update.message == .reset { audio.stop() }
            if result == .advanced { playOtherHand() }
            if result == .complete {
                audio.stop()
                save()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in pause()
        }
        .onDisappear { pause() }
        .confirmationDialog("Discard this unsaved guided result?", isPresented: $discarding) {
            Button("Discard result", role: .destructive) {
                session.discardResult()
                configure()
            }
        }
    }
    private func configure() {
        pause()
        do { session.configure(try state.guidedPassage(study)) } catch {
            session.invalidate(error.localizedDescription)
        }
    }
    private func pause() {
        session.pause()
        audio.stop()
    }
    private func save() { session.save { try state.saveGuidedResult($0) } }
    private func playOtherHand() {
        audio.stop()
        guard accompany, session.listening, let follower = session.follower,
            let score = follower.plan.otherHand(at: follower.index), !state.isPreview
        else { return }
        audio.play(score)
    }
    private func previewCheck() {
        midi.installPreview()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard let plan = session.plan else {
                GuidedDiagnostics.checks["planBuilt"] = false
                return
            }
            GuidedDiagnostics.checks["planBuilt"] = !plan.steps.isEmpty
            session.start(held: midi.keyboard.downNotes)
            let wrong = (21...108).first { !plan.steps[0].notes.contains($0) && !plan.steps[0].carried.contains($0) }!
            midi.previewInput([.noteOn(channel: 0, note: wrong, velocity: 90), .noteOff(channel: 0, note: wrong)])
            GuidedDiagnostics.checks["wrongNoteWaits"] =
                session.follower?.index == 0 && session.follower?.mistakes[0] == 1
            for step in plan.steps {
                midi.previewInput(step.notes.map { .noteOn(channel: 0, note: $0, velocity: 90) })
                midi.previewInput(step.notes.map { .noteOff(channel: 0, note: $0) })
            }
            GuidedDiagnostics.checks["passageCompleted"] = session.follower?.complete == true
            GuidedDiagnostics.checks["resultSaved"] =
                session.saved && state.history.guidedPassages?[plan.id]?.latest.corrections == 1
            GuidedDiagnostics.checks["guidedEvidenceDistinct"] =
                state.journal.attempts.last?.guidedPracticeID == plan.id
                && state.journal.attempts.last?.assisted == true
            GuidedDiagnostics.checks["reviewReturnsSooner"] =
                state.history.guidedPassages?[plan.id]?.review.lastGrade == .again
        }
    }
}

struct GuidedReviewQueueView: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        if !state.guidedReviews.isEmpty {
            Card(
                title: "Return to your keyboard passages", subtitle: "Guided reading reviews from your own music",
                padding: 18, spacing: 12
            ) {
                ForEach(Array(state.guidedReviews.prefix(3)), id: \.latest.practiceID) { progress in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(progress.latest.title).fontWeight(.medium)
                            Text(
                                "Bars \(progress.latest.scope.from + 1)–\(progress.latest.scope.through + 1) · "
                                    + progress.review.reason()
                            ).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Practise") { state.openGuidedReview(progress) }
                    }
                }
            }
        }
    }
}
