// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import AppKit
import MusicCore
import SwiftUI

struct TimedChangesView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var midi: MIDIKeyboard
    @ObservedObject var session: TimedChangesSession
    @State private var mode = ChangesMode.guides
    @State private var tempo = 80
    @State private var loops = 2
    @State private var click = true
    @State private var bass = false
    @State private var hints = false
    @State private var offset = 0
    @State private var focus: [Int]?
    @State private var fullTempo = 80
    @State private var setupError: String?
    @State private var discarding = false
    private var locked: Bool { session.busy || session.hasUnsavedResult }
    private var conditions: ChangesTimingConditions { .init(click: click, bass: bass, hints: hints, offsetMS: offset) }
    private var previewPlan: TimedChangesPlan? { try? makePlan() }
    private var displayedPlan: TimedChangesPlan? { session.busy ? session.plan : previewPlan }
    private var cueIndex: Int {
        guard let plan = displayedPlan else { return 0 }
        return session.busy ? plan.cueIndex(at: session.elapsed) : 0
    }
    private func makePlan() throws -> TimedChangesPlan {
        try TimedChangesPlan(changes: state.changesPlan, mode: mode, tempo: tempo, loops: loops, focus: focus)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "Play the changes", subtitle: state.changesPlan.title, padding: 20, spacing: 14) {
                HStack {
                    Text("Keep the pulse. Let common tones stay under your fingers.").font(.callout).foregroundStyle(
                        .secondary)
                    Spacer()
                    Button("Explore voicings") {
                        session.cancel()
                        state.showTimedChanges = false
                    }.disabled(session.hasUnsavedResult)
                }
                controls
                MIDIConnectionView(midi: midi).disabled(session.busy)
                if let plan = displayedPlan { progression(plan) }
                HStack {
                    if session.busy {
                        Button("Stop", systemImage: "stop.fill") { session.cancel() }.buttonStyle(.cadencePrimary)
                        Text(
                            session.preparing
                                ? "Preparing count-in…"
                                : session.elapsed < 0
                                    ? "Count in · \(session.countInRemaining)"
                                    : session.demonstration
                                        ? "Listen to the changes"
                                        : "Pass \(min(loops,(displayedPlan?.cues[cueIndex].cycle ?? 0)+1)) · keep going"
                        ).foregroundStyle(Color.moss)
                    } else {
                        Button("Count in & play", systemImage: "play.fill") { start() }.buttonStyle(.cadencePrimary)
                            .disabled(!midi.connected || locked || previewPlan == nil)
                        Button("Hear an example", systemImage: "speaker.wave.2") { start(demonstration: true) }
                            .disabled(locked || previewPlan == nil)
                        Text("Release your keys before starting").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let plan = displayedPlan, session.busy {
                    ProgressView(
                        value: max(0, min(plan.length, session.elapsed / plan.secondsPerBeat)), total: plan.length
                    ).tint(Color.moss)
                }
                if focus != nil {
                    HStack {
                        Text("A smaller passage around the transition, at a gentler tempo.").font(.caption)
                        Spacer()
                        Button("Return to full progression") {
                            self.focus = nil
                            tempo = fullTempo
                            session.discard()
                        }.disabled(locked)
                    }
                }
                if previewPlan == nil { Text(planError).font(.callout).foregroundStyle(Color.clay) }
            }
            if let result = session.result { resultView(result) }
            if let error = setupError ?? session.error {
                Text(error).font(.callout).foregroundStyle(Color.clay).textSelection(.enabled)
            }
            if session.hasUnsavedResult {
                HStack {
                    Button("Try saving again") { save() }
                    Button("Discard unsaved pass…", role: .destructive) { discarding = true }
                }
            }
            DisclosureGroup("Timing & feedback") {
                VStack(alignment: .leading, spacing: 8) {
                    Stepper("Input offset: \(offset) ms", value: $offset, in: -250...250, step: 5).frame(width: 260)
                        .disabled(locked)
                    Text(
                        "Positive offsets compensate for consistently late input. Use the eight-tap timing check in Practice to estimate an offset for your current setup. Prefer built-in or wired audio; changing devices resets this offset."
                    )
                    Text(
                        "A chord must settle under your fingers for 60 ms. On time is within ±100 ms of the change. This checks physical keys around each transition; pedal, technique, note lengths and playing between changes are not graded. For N.C., release the keys at the change."
                    )
                    Text(
                        "Hearing the example turns on tone hints for your next pass. Bass and tone hints are recorded as support. Each tempo, voicing mode and support setup has its own review schedule. Finishing a pass saves locally; stopping leaves it ungraded."
                    )
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }.font(.caption)
        }
        .onAppear {
            if state.changesReview == nil, let result = session.result { restore(result) }
            applyReview()
            if state.isPreview && CommandLine.arguments.contains("--timed-changes-check") { previewCheck() }
        }
        .onChange(of: state.changesReview?.id) { _, _ in applyReview() }
        .onChange(of: session.result?.id) { _, _ in save() }
        .onReceive(midi.updates) { if state.isPreview || NSApp.isActive { session.receive($0) } }
        .onChange(of: midi.connectionRevision) { _, _ in
            if session.busy { session.cancel("Keyboard connection changed. Start a fresh count-in.") }
            offset = 0
        }
        .onChange(of: state.changesPlan.id) { _, _ in session.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            session.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVAudioEngineConfigurationChange)) { _ in
            if session.busy { session.cancel("Audio output changed. Check your setup and start again.") }
            offset = 0
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            session.cancel()
        }
        .onDisappear { session.cancel() }
        .confirmationDialog("Discard this unsaved pass?", isPresented: $discarding) {
            Button("Discard pass", role: .destructive) { session.discard() }
        }
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Play", selection: $mode) {
                    ForEach(ChangesMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(width: 275)
                Stepper("\(tempo) bpm", value: $tempo, in: 40...160, step: 5).frame(width: 145)
                Stepper("\(loops) passes", value: $loops, in: 1...4).frame(width: 140)
                Spacer()
            }
            HStack(spacing: 20) {
                Toggle("Keep the click", isOn: $click)
                Toggle("Bass accompaniment", isOn: $bass)
                Toggle("Show tone hints", isOn: $hints)
            }.toggleStyle(.checkbox)
            Text(mode.instruction).font(.caption).foregroundStyle(.secondary)
        }.controlSize(.small).disabled(locked)
    }
    private func progression(_ plan: TimedChangesPlan) -> some View {
        let cue = plan.cues[cueIndex]
        return VStack(alignment: .leading, spacing: 12) {
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(Array(plan.cues.enumerated()), id: \.offset) { i, item in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.symbol.label).font(.system(size: 25, weight: .medium, design: .serif))
                                Text("Bar \(item.bar+1) · pass \(item.cycle+1)").font(.caption)
                                Text(
                                    String(
                                        format: "%.3g beats",
                                        (i + 1 < plan.cues.count ? plan.cues[i + 1].beat : plan.length) - item.beat)
                                ).font(.caption2)
                            }.padding(14).frame(minWidth: 130, alignment: .leading)
                                .foregroundStyle(i == cueIndex ? Color.white : Color.ink)
                                .background(
                                    i == cueIndex ? Color.moss : Color.canvas, in: RoundedRectangle(cornerRadius: 10)
                                ).id(i)
                        }
                    }
                }.onChange(of: cueIndex) { _, i in withAnimation { reader.scrollTo(i, anchor: .center) } }
            }
            HStack {
                Text(cue.isRest ? "Release for N.C." : "Now · " + cue.symbol.label).font(
                    .system(size: 25, weight: .medium, design: .serif))
                Spacer()
                if cueIndex + 1 < plan.cues.count {
                    Text("Next · " + plan.cues[cueIndex + 1].symbol.label).foregroundStyle(.secondary)
                }
            }
            if hints, let target = try? cue.target(plan.mode) {
                Text(
                    "Tones: " + target.pitches.map(\.name).joined(separator: " · ")
                        + (target.bass.map { " · lowest note: " + $0.name } ?? "")
                ).font(.callout).foregroundStyle(Color.moss)
            }
        }
    }
    private var planError: String {
        do {
            _ = try makePlan()
            return ""
        } catch { return error.localizedDescription }
    }
    private func start(demonstration: Bool = false) {
        do {
            let plan = try makePlan()
            try state.validateTimedChanges(plan)
            if demonstration { hints = true }
            setupError = nil
            state.audio.stop()
            state.microphone.stop()
            state.timedSession.cancel()
            state.changesSession.pause(held: midi.keyboard.downNotes)
            session.start(plan, conditions: conditions, held: midi.keyboard.downNotes, demonstration: demonstration)
        } catch { setupError = error.localizedDescription }
    }
    private func save() { session.save { try state.saveTimedChanges($0) } }
    private func applyReview() {
        guard let result = state.changesReview else { return }
        restore(result)
        state.changesReview = nil
    }
    private func restore(_ result: TimedChangesResult) {
        fullTempo = result.plan.tempo
        mode = result.plan.mode
        tempo = result.plan.tempo
        loops = result.plan.loops
        focus = result.plan.focus
        click = result.conditions.click
        bass = result.conditions.bass
        hints = result.conditions.hints
        offset = 0
    }
    private func isolate(_ result: TimedChangesResult, index: Int) {
        do {
            let full = try TimedChangesPlan(
                changes: state.changesPlan, mode: result.plan.mode, tempo: result.plan.tempo, loops: 1)
            let cue = result.plan.cues[index]
            guard let i = full.cues.firstIndex(where: { $0.sourceIndex == cue.sourceIndex }) else { return }
            if focus == nil { fullTempo = result.plan.tempo }
            focus = [max(0, i - 1), i]
            tempo = max(40, result.plan.tempo - 10)
            mode = result.plan.mode
            session.discard()
        } catch { setupError = error.localizedDescription }
    }
    private func resultView(_ result: TimedChangesResult) -> some View {
        let report = result.report
        return Card(
            title: report.clean ? "The changes landed" : "A useful next step",
            subtitle:
                "Last pass · \(result.plan.mode.rawValue) · \(result.plan.tempo) bpm\(session.saved ? " · saved" : "")",
            padding: 20, spacing: 12
        ) {
            HStack(spacing: 24) {
                Label("\(report.harmonicMatches)/\(report.changes.count) harmonies matched", systemImage: "pianokeys")
                Label("\(report.onTime)/\(report.changes.count) on time or held", systemImage: "metronome")
                if report.recoveryCount > 0 {
                    Text("\(report.recoveryCount) \(report.recoveryCount == 1 ? "recovery" : "recoveries")")
                }
            }.font(.callout)
            // Keep long sessions readable while still making every transition available.
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(report.changes.enumerated()), id: \.offset) { _, change in
                        HStack {
                            Text("\(change.cue.symbol.label) · bar \(change.cue.bar+1) · pass \(change.cue.cycle+1)")
                                .frame(width: 205, alignment: .leading)
                            Text(change.harmonyCorrect ? "Harmony matched" : missed(change)).frame(
                                maxWidth: .infinity, alignment: .leading)
                            Text(
                                change.timing.rawValue + (change.delta.map { " · \(Int(abs($0)*1000)) ms" } ?? "")
                                    + (change.strayPresses > 0 ? " · \(change.strayPresses) extra presses" : ""))
                        }.font(.caption).foregroundStyle(change.clean ? Color.moss : Color.clay)
                    }
                }
            }.frame(maxHeight: 155)
            if let index = report.difficultIndex {
                Text(
                    "\(report.changes[index].cue.symbol.label) in bar \(report.changes[index].cue.bar+1) \(report.changes[index].harmonyCorrect ? "matched, but its arrival needs attention" : "didn’t settle into the target notes"). Try it with the preceding change, 10 bpm slower."
                ).font(.callout)
                Button("Focus on this transition") { isolate(result, index: index) }.disabled(locked)
            } else {
                Text("Let this settle, then revisit it another day. You can explore a new voicing whenever you like.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let progress = state.history.timedChanges?[result.practiceID], let due = progress.review.due {
                Text("Next review \(due.formatted(date:.abbreviated,time:.shortened))").font(.caption).foregroundStyle(
                    .secondary)
            }
            if result.assisted {
                Text(
                    "Recorded with support: bass, tone hints or arrival-time MIDI. This keeps the review close without claiming independent recall."
                ).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func missed(_ change: ChangeAssessment) -> String {
        var parts: [String] = []
        if !change.missing.isEmpty {
            parts.append("Missing " + change.missing.map { Pitch.spelled($0).name }.joined(separator: ", "))
        }
        if !change.extra.isEmpty {
            parts.append("extra " + change.extra.map { Pitch.spelled($0).name }.joined(separator: ", "))
        }
        if !change.bassCorrect { parts.append("check lowest note") }
        return parts.isEmpty ? "Hold the shape a little longer" : parts.joined(separator: " · ")
    }
    private func previewCheck() {
        midi.installPreview()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            do {
                let plan = try makePlan()
                let conditions = conditions
                TimedChangesDiagnostics.checks["planBuilt"] = plan.valid
                guard session.prepare(plan, conditions: conditions, held: []) else { return }
                let origin = PracticeClock.now() - plan.duration - 1
                session.begin(at: origin)
                var held = Set<Int>()
                for (index, cue) in plan.cues.enumerated() {
                    let notes = Set(
                        try cue.target(plan.mode)?.pianoVoicings(previous: Array(held).sorted()).first ?? [])
                    let time = origin + cue.beat * plan.secondsPerBeat + (index == 1 ? 0.18 : 0)
                    midi.previewInput(
                        held.subtracting(notes).sorted().map { .noteOff(channel: 0, note: $0) }
                            + notes.subtracting(held).sorted().map { .noteOn(channel: 0, note: $0, velocity: 90) },
                        timestamp: time)
                    held = notes
                }
                session.tick()
                save()
                let report = session.result?.report
                TimedChangesDiagnostics.checks["harmonyMatched"] = report?.harmonicMatches == plan.cues.count
                TimedChangesDiagnostics.checks["timingSeparated"] =
                    report?.changes.filter { $0.timing == .late }.count == 1
                TimedChangesDiagnostics.checks["resultSaved"] = session.saved
                TimedChangesDiagnostics.checks["reviewRecorded"] =
                    state.history.timedChanges?[plan.identity(conditions)]?.review.lastGrade == .again
                TimedChangesDiagnostics.checks["sourceLinked"] = state.journal.attempts.last?.pieceID == plan.pieceID
                TimedChangesDiagnostics.checks["sourceValidated"] = (try? state.validateTimedChanges(plan)) != nil
            } catch {
                setupError = error.localizedDescription
                TimedChangesDiagnostics.checks["planBuilt"] = false
            }
        }
    }
}
@MainActor enum TimedChangesDiagnostics { static var checks: [String: Bool] = [:] }
struct TimedChangesReviewQueue: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        if !state.timedChangesReviews.isEmpty {
            Card(
                title: "Return to the changes", subtitle: "Chord transitions ready to revisit", padding: 18, spacing: 12
            ) {
                ForEach(Array(state.timedChangesReviews.prefix(3)), id: \.latest.practiceID) { progress in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(progress.latest.plan.title).fontWeight(.medium)
                            Text(
                                "\(progress.latest.plan.mode.rawValue) · \(progress.latest.plan.tempo) bpm · "
                                    + progress.review.reason()
                            ).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Practise") { state.openTimedChangesReview(progress.latest) }
                    }
                }
            }
        }
    }
}
