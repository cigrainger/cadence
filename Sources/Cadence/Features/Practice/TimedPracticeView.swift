// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import AppKit
import MusicCore
import SwiftUI

struct TimedPracticeView: View {
    @EnvironmentObject private var state: AppState
    var study: MusicStudy?
    @ObservedObject var midi: MIDIKeyboard
    @ObservedObject var session: TimedPracticeSession
    @State private var exercise = RhythmExercise.pulse
    @State private var tempo = 80
    @State private var input = TimedInput.space
    @State private var click = true
    @State private var offset = 0
    @State private var setupError: String?
    @State private var scoreHeight: CGFloat = 200
    @State private var renderError: String?
    @State private var discarding = false
    @State private var timingDetails = false
    private var conditions: TimedConditions {
        TimedConditions(input: study == nil ? input : .midi, click: click, offsetMS: offset)
    }
    private var selection: String {
        study.map { "\($0.id):\($0.partID):\($0.staff ?? 0):\($0.from):\($0.through)" } ?? exercise.id
    }
    private var locked: Bool { session.busy || session.hasUnsavedResult }
    private var head: StudyPlayhead? {
        guard session.active, !session.calibration, let plan = session.plan, let source = plan.source else {
            return nil
        }
        return StudyPlayhead(
            sourceBeat: source.startBeat + max(0, min(plan.length, session.elapsed / plan.secondsPerBeat)),
            isCountIn: session.elapsed < 0, countInRemaining: Double(session.countInRemaining), cycle: 0)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(study == nil ? "Tap the rhythm" : "Play in time").font(
                .system(size: 25, weight: .medium, design: .serif))
            Text(
                study == nil
                    ? exercise.instruction : "A count-in, one hand, and a steady tempo. Keep going after a mistake."
            ).font(.callout).foregroundStyle(.secondary)
            controls
            if conditions.input == .midi { MIDIConnectionView(midi: midi).disabled(session.busy) }
            if let study {
                if let renderError { Text(renderError).font(.caption).foregroundStyle(Color.clay) }
                ScoreRenderer(study: study, playhead: head, height: $scoreHeight, error: $renderError)
                    .frame(height: scoreHeight).background(.white).clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RhythmTapGrid(
                    exercise: exercise,
                    beat: session.active && !session.calibration
                        ? session.elapsed / (session.plan?.secondsPerBeat ?? 1) : nil)
            }
            transport
            if session.active {
                HStack(spacing: 20) {
                    Text(
                        session.elapsed < 0
                            ? "Count in · \(max(1, session.countInRemaining))"
                            : session.calibration
                                ? "Tap on each click"
                                : session.demonstration ? "Listen to the rhythm" : "Keep the pulse"
                    )
                    .font(.system(size: 23, weight: .medium, design: .serif)).foregroundStyle(Color.moss)
                    Spacer()
                    if !session.demonstration {
                        Text("\(session.attacks.count) presses").monospacedDigit().foregroundStyle(.secondary)
                    }
                }.accessibilityAddTraits(.updatesFrequently)
            }
            if let result = session.result { resultView(result) }
            if let report = session.calibrationReport {
                VStack(alignment: .leading, spacing: 8) {
                    if let adjustment = report.calibrationOffsetMS,
                        (-250...250).contains(session.conditions.offsetMS + adjustment)
                    {
                        Text(
                            "Your taps averaged \(abs(adjustment)) ms \(adjustment >= 0 ? "after" : "before") the clicks. This includes your own tapping tendency."
                        )
                        Button("Use \(session.conditions.offsetMS + adjustment) ms offset for this setup") {
                            offset = session.conditions.offsetMS + adjustment
                        }
                    } else {
                        Text(
                            "The taps varied too much for an offset. Try the timing check again, following each click.")
                    }
                    Text(
                        "Optional, for this visit only. Repeat after changing your keyboard or audio output. A timing check cannot separate device delay from how you tap."
                    ).font(.caption).foregroundStyle(.secondary)
                }.font(.callout)
            }
            if let error = setupError ?? session.error {
                Text(error).font(.callout).foregroundStyle(Color.clay).textSelection(.enabled)
            }
            if session.hasUnsavedResult {
                HStack {
                    Button("Try saving again") { save() }
                    Button("Discard unsaved pass…", role: .destructive) { discarding = true }
                }
            }
            DisclosureGroup("Timing setup", isExpanded: $timingDetails) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Stepper("Input offset: \(offset) ms", value: $offset, in: -250...250, step: 5).frame(width: 245)
                        Button("Check with eight taps") { start(calibration: true) }.disabled(
                            conditions.input == .midi && !midi.connected)
                        Button("Reset offset") { offset = 0 }
                    }.disabled(locked)
                    Text(
                        "Positive offsets compensate for taps arriving consistently late. Prefer built-in or wired audio for timing. Spacebar and MIDI results are kept separately; this pass records tempo, click and offset."
                    ).font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }.font(.caption)
            Text(
                study == nil
                    ? "Tap Space or one piano key per note; release between taps. Held keys and key repeat do not create extra taps. This checks entrances, not how long you hold a note."
                    : "First version: one staff, 1–8 bars, 2/4, 3/4 or 4/4. Checks sounding pitches and entrances; note length, pedal, dynamics and technique are not graded. Ties do not need a fresh press."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .background(
            SpaceTapCapture(enabled: session.busy && conditions.input == .space) { timestamp in
                session.attack(at: timestamp)
            }.frame(width: 0, height: 0)
        )
        .onAppear {
            if let study {
                input = .midi
                tempo = min(160, max(40, Int((study.document.tempo * study.speed).rounded())))
            }
            applyReview()
            if state.isPreview && CommandLine.arguments.contains("--timed-practice-check") { previewCheck() }
        }
        .onChange(of: selection) { _, _ in
            session.cancel()
            setupError = nil
        }
        .onChange(of: input) { _, _ in
            session.cancel()
            offset = 0
        }
        .onChange(of: state.rhythmReview?.id) { _, _ in applyReview() }
        .onChange(of: midi.connectionRevision) { _, _ in
            if session.busy && conditions.input == .midi {
                session.cancel("Keyboard connection changed. Start a fresh count-in.")
            }
            offset = 0
        }
        .onReceive(midi.updates) { if state.isPreview || NSApp.isActive { session.receive($0) } }
        .onChange(of: session.result?.id) { _, _ in save() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            session.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVAudioEngineConfigurationChange)) { _ in
            if session.active {
                session.cancel("Audio output changed. Check your timing setup and start again.")
                offset = 0
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            session.cancel()
        }
        .onChange(of: study?.document) { _, _ in session.cancel("The score changed. Start a fresh pass.") }
        .onDisappear { session.cancel() }
        .confirmationDialog("Discard this unsaved timed pass?", isPresented: $discarding) {
            Button("Discard pass", role: .destructive) { session.discard() }
        }
    }
    private var controls: some View {
        HStack(spacing: 18) {
            if study == nil {
                Picker("Pattern", selection: $exercise) {
                    ForEach(RhythmExercise.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(maxWidth: 240)
                Picker("Tap with", selection: $input) {
                    ForEach(TimedInput.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(width: 180)
            }
            Stepper("\(tempo) bpm", value: $tempo, in: 40...160, step: 5).monospacedDigit().frame(width: 140)
            Toggle("Keep the click", isOn: $click).toggleStyle(.checkbox)
            Spacer(minLength: 0)
        }.controlSize(.small).disabled(locked)
    }
    private var transport: some View {
        HStack(spacing: 12) {
            if session.busy {
                Button("Stop", systemImage: "stop.fill") { session.cancel() }.buttonStyle(.cadencePrimary)
                Text(session.preparing ? "Preparing the count-in…" : "Stopping leaves this unfinished pass ungraded.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Button(study == nil ? "Count in & tap" : "Count in & play", systemImage: "play.fill") { start() }
                    .buttonStyle(.cadencePrimary).disabled(
                        session.hasUnsavedResult || (conditions.input == .midi && !midi.connected))
                if study == nil {
                    Button("Hear the pattern", systemImage: "speaker.wave.2") { start(demonstration: true) }.disabled(
                        session.hasUnsavedResult)
                }
                Text(
                    conditions.input == .space
                        ? "Space to tap once the count-in begins" : "Release your keys, then start"
                ).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func makePlan() throws -> TimedPracticePlan {
        if let study { return try state.timedPlan(study, tempo: tempo) }
        return TimedPracticePlan(rhythm: exercise, tempo: tempo)
    }
    private func start(demonstration: Bool = false, calibration: Bool = false) {
        do {
            let plan = try calibration ? TimedPracticePlan.calibration() : makePlan()
            setupError = nil
            state.audio.stop()
            state.microphone.stop()
            var conditions = conditions
            if calibration { conditions.click = true }
            session.start(
                plan, conditions: conditions, held: midi.keyboard.downNotes, demonstration: demonstration,
                calibration: calibration)
        } catch { setupError = error.localizedDescription }
    }
    private func save() { session.save { try state.saveTimedResult($0) } }
    private func applyReview() {
        guard let review = state.rhythmReview, review.plan.source?.studyID == study?.id else { return }
        if study == nil, let chosen = RhythmExercise.allCases.first(where: { $0.id == review.plan.rhythmID }) {
            exercise = chosen
        }
        tempo = review.plan.tempo
        input = review.conditions.input
        click = review.conditions.click
        // Offsets are intentionally recalibrated for the current device/output setup.
        offset = 0
        state.rhythmReview = nil
    }
    @ViewBuilder private func resultView(_ result: TimedPracticeResult) -> some View {
        let report = result.report
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(report.clean ? "A steady pass" : "A useful next step").font(
                    .system(size: 21, weight: .medium, design: .serif))
                Spacer()
                Text("\(result.plan.tempo) bpm · \(result.conditions.input.rawValue)\(session.saved ? " · saved" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(
                "Last pass · \(result.plan.title)"
                    + (result.plan.source.map { " · bars \($0.scope.from + 1)–\($0.scope.through + 1)" } ?? "")
            ).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 20) {
                Label("\(report.onTime)/\(report.notes.count) on time", systemImage: "metronome")
                if !result.plan.rhythmOnly { Text("\(report.matchedPitch)/\(report.notes.count) correct pitches") }
                Text(
                    "\(report.early) early · \(report.late) late · \(report.missed) missed · \(report.extras.count) extra"
                )
            }.font(.callout)
            if report.wrong > 0 {
                Text("\(report.wrong) presses had a different pitch.").foregroundStyle(Color.clay).font(.callout)
            }
            TimingFeedbackStrip(report: report, tolerance: result.plan.tolerance)
            ForEach(Array(report.difficultBars.prefix(3)), id: \.self) { bar in
                let notes = report.notes.filter { $0.target.bar == bar }
                Text(
                    "Bar \(bar + 1): \(notes.filter { $0.verdict == .early }.count) early · \(notes.filter { $0.verdict == .late }.count) late · \(notes.filter { $0.verdict == .missed }.count) missed\(result.plan.rhythmOnly ? "" : " · \(notes.filter { $0.verdict == .wrongPitch }.count) different pitches")"
                ).font(.caption).foregroundStyle(.secondary)
            }
            if let bar = report.difficultBars.first {
                Text(
                    "Try bar \(bar + 1)\(bar > (result.plan.source?.scope.from ?? 0) ? " with the bar before it" : " on its own"), at \(max(40, result.plan.tempo - 10)) bpm. Count the subdivisions aloud before playing."
                ).font(.callout)
                if let source = result.plan.source {
                    Button("Practise that smaller passage") {
                        guard !session.hasUnsavedResult else { return }
                        state.editStudy(source.studyID) {
                            $0.select(from: max(source.scope.from, bar - 1), through: bar)
                        }
                        tempo = max(40, result.plan.tempo - 10)
                        session.discard()
                    }.disabled(session.hasUnsavedResult)
                } else {
                    Button("Try 10 bpm slower") { tempo = max(40, result.plan.tempo - 10) }.disabled(locked)
                }
            } else if !report.extras.isEmpty {
                Text("The written entrances lined up. Try keeping the spaces between them quiet.").font(.callout)
            } else {
                Text("Return another day to see what has stayed with you, or choose a new pattern whenever you like.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text(
                "On time means within ±\(Int((result.plan.tolerance * 1000).rounded())) ms. Very distant presses appear as an extra press and a missed note. Offset: \(result.conditions.offsetMS) ms; click \(result.conditions.click ? "on" : "off")."
            ).font(.caption).foregroundStyle(.secondary)
            if result.attacks.contains(where: \.arrivalTimestamp) {
                Text(
                    "This keyboard supplied some missing or unusable timestamps; those presses used arrival time. Treat small timing differences cautiously."
                ).font(.caption).foregroundStyle(Color.clay)
            }
        }.padding(16).background(Color.moss.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
    private func previewCheck() {
        midi.installPreview()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            do {
                let plan = try makePlan()
                TimedDiagnostics.checks["planBuilt"] = plan.valid
                let condition = TimedConditions(input: study == nil ? .space : .midi)
                guard session.prepare(plan, conditions: condition, held: []) else { return }
                let origin = PracticeClock.now() - plan.duration - 1
                session.begin(at: origin)
                for (index, target) in plan.targets.enumerated() {
                    let time = origin + target.beat * plan.secondsPerBeat + (index == 1 ? 0.12 : 0)
                    if study == nil {
                        session.attack(at: time)
                    } else {
                        midi.previewInput(
                            [
                                .noteOn(channel: 0, note: target.pitch, velocity: 90),
                                .noteOff(channel: 0, note: target.pitch),
                            ], timestamp: time)
                    }
                }
                session.tick()
                save()
                TimedDiagnostics.checks["timingSeparated"] = session.result?.report.late == 1
                TimedDiagnostics.checks["noCascade"] = session.result?.report.missed == 0
                TimedDiagnostics.checks["resultSaved"] = session.saved
                TimedDiagnostics.checks["reviewRecorded"] =
                    state.history.timedPassages?[plan.identity(condition)]?.review.lastGrade == .again
                TimedDiagnostics.checks["inputDistinct"] =
                    state.journal.attempts.last?.input == condition.input.journalInput
            } catch {
                TimedDiagnostics.checks["planBuilt"] = false
                setupError = error.localizedDescription
            }
        }
    }
}

@MainActor enum TimedDiagnostics { static var checks: [String: Bool] = [:] }

private struct RhythmTapGrid: View {
    var exercise: RhythmExercise
    var beat: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(0..<2) { bar in
                HStack(spacing: 6) {
                    Text("\(bar + 1)").font(.caption).foregroundStyle(.secondary).frame(width: 20)
                    ForEach(0..<8) { cell in
                        let time = Double(bar * 4) + Double(cell) / 2
                        let note = exercise.beats.contains(time)
                        let active = beat.map { $0 >= time && $0 < time + 0.5 } ?? false
                        VStack(spacing: 6) {
                            Text(note ? "●" : "—").font(.system(size: 22)).foregroundStyle(
                                note ? Color.ink : Color.secondary.opacity(0.5))
                            Text(cell % 2 == 0 ? "\(cell / 2 + 1)" : "&").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(
                                active ? Color.moss.opacity(0.22) : cell % 2 == 0 ? Color.canvas : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                            .accessibilityLabel(
                                "Bar \(bar + 1), \(cell % 2 == 0 ? "beat \(cell / 2 + 1)" : "and after beat \(cell / 2 + 1)"), \(note ? "tap" : "no tap")"
                            )
                    }
                }
            }
            Text("● Tap    — No new tap    Each pair of boxes is one beat. Keep counting through the spaces.").font(
                .caption
            ).foregroundStyle(.secondary)
        }
    }
}

private struct TimingFeedbackStrip: View {
    var report: TimedReport
    var tolerance: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Early")
                Spacer()
                Text("On the beat")
                Spacer()
                Text("Late")
            }.font(.caption).foregroundStyle(.secondary)
            Canvas { context, size in
                let centre = size.width / 2
                let scale = size.width / 0.8
                context.fill(
                    Path(
                        CGRect(x: centre - tolerance * scale, y: 0, width: tolerance * scale * 2, height: size.height)),
                    with: .color(.moss.opacity(0.12)))
                context.fill(Path(CGRect(x: centre, y: 0, width: 1, height: size.height)), with: .color(.moss))
                for (index, note) in report.notes.enumerated() {
                    guard let delta = note.delta else { continue }
                    let x = min(size.width - 4, max(4, centre + delta * scale))
                    let y = 8 + Double(index % 3) * 10
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - 3, y: y, width: 6, height: 6)),
                        with: .color(note.verdict == .onTime ? .moss : .clay))
                }
            }.frame(height: 40)
                .accessibilityLabel(
                    "\(report.onTime) on time, \(report.early) early, \(report.late) late, \(report.wrong) wrong pitches, \(report.missed) missed"
                )
        }
    }
}

/// A local event monitor only while this view is mounted. No global key capture.
struct SpaceTapCapture: NSViewRepresentable {
    var enabled: Bool
    var tap: (Double) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.enabled = enabled
        context.coordinator.tap = tap
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.remove() }
    @MainActor final class Coordinator {
        weak var view: NSView?
        var enabled = false
        var tap: ((Double) -> Void)?
        var monitor: Any?
        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.process(event, appActive: NSApp.isActive)
            }
        }
        func process(_ event: NSEvent, appActive: Bool) -> NSEvent? {
            guard enabled, appActive, let window = view?.window, event.window === window,
                event.type == .keyDown, event.keyCode == 49,
                event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                !(window.firstResponder is NSTextView)
            else { return event }
            if !event.isARepeat { tap?(event.timestamp) }
            return nil
        }
        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        isolated deinit { remove() }
    }
}

struct TimedReviewQueueView: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        if !state.timedReviews.isEmpty {
            Card(
                title: "Return to the pulse", subtitle: "Timed passages and rhythm patterns ready to revisit",
                padding: 18, spacing: 12
            ) {
                ForEach(Array(state.timedReviews.prefix(3)), id: \.latest.practiceID) { progress in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(progress.latest.plan.title).fontWeight(.medium)
                            Text(
                                "\(progress.latest.plan.tempo) bpm · \(progress.latest.conditions.input.rawValue) · "
                                    + progress.review.reason()
                            ).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Practise") { state.openTimedReview(progress.latest) }
                    }
                }
            }
        }
    }
}
