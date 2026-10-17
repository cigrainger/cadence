// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import MusicCore
import SwiftUI

struct PlayAlongView: View {
    @EnvironmentObject private var state: AppState
    let material: ScoreEarMaterial
    @ObservedObject var session: PlayAlongSession
    @ObservedObject var midi: MIDIKeyboard
    @State private var study: MusicStudy?
    @State private var scoreHeight: CGFloat = 240
    @State private var scoreError: String?
    @State private var timingExpanded = false
    @State private var notesExpanded = false
    @State private var discarding = false
    private var timing: TimedPracticeSession { session.timing }
    private var locked: Bool { timing.busy || timing.hasUnsavedResult }
    private var samePassage: Bool { session.plan?.material.id == material.id }
    private var head: StudyPlayhead? {
        guard timing.active, !timing.calibration, samePassage, let plan = session.plan else { return nil }
        return .init(
            sourceBeat: plan.sourceStart
                + max(0, min(plan.material.beats - 0.00001, timing.elapsed / plan.timed.secondsPerBeat)),
            isCountIn: timing.elapsed < 0, countInRemaining: Double(timing.countInRemaining), cycle: 0)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Find your place in the music.").font(.system(size: 30, weight: .medium, design: .serif))
                    Text(material.title + " · " + material.label).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Label("PLAY ALONG", systemImage: "pianokeys").font(.caption.weight(.semibold)).tracking(1.4)
                    .foregroundStyle(Color.moss).padding(10).background(Color.moss.opacity(0.08), in: Capsule())
            }
            settings
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(material.chords.map { $0.symbol.label }.joined(separator: "  →  ")).font(.headline)
                        .foregroundStyle(Color.moss)
                    Spacer()
                    Text(status).font(.callout.monospacedDigit()).foregroundStyle(Color.moss)
                }
                if let study {
                    ScoreRenderer(
                        study: study, playhead: head, feedback: samePassage ? session.feedback : [],
                        height: $scoreHeight, error: $scoreError
                    )
                    .frame(height: min(330, scoreHeight)).background(.white, in: RoundedRectangle(cornerRadius: 12))
                }
                ProgressView(value: progress).tint(Color.moss)
                HStack(spacing: 16) {
                    Label("On time", systemImage: "checkmark.circle.fill").foregroundStyle(Color.moss)
                    Text("← Early    → Late").foregroundStyle(Color.clay)
                    Text("× Pitch    – Missed").foregroundStyle(.secondary)
                    Spacer()
                    Text(
                        "\(midi.keyboard.downNotes.sorted().map { Pitch.chromatic($0)+String($0/12-1) }.joined(separator:" · "))"
                    ).monospacedDigit()
                }.font(.caption)
                transport
            }.padding(18).background(Color.white, in: RoundedRectangle(cornerRadius: 18))
            if let result = session.result {
                resultCard(result)
            } else if timing.active && !timing.calibration {
                let notes = session.feedback.filter(\.settled).map(\.assessment)
                HStack(spacing: 24) {
                    Text(
                        "\(notes.filter { $0.verdict != .wrongPitch && $0.verdict != .missed }.count)/\(notes.count) pitches"
                    )
                    Text(
                        "\(notes.filter { $0.delta.map { abs($0) <= (timing.plan?.tolerance ?? 0.08) } ?? false }.count)/\(notes.count) entrances on time"
                    )
                    Spacer()
                    Text("Keep going. The next note is a fresh start.").foregroundStyle(.secondary)
                }.font(.callout)
                Text(
                    "Live marks settle just after each note’s timing window. Final feedback uses the keyboard’s original timestamps."
                ).font(.caption).foregroundStyle(.secondary)
            }
            timingSetup
            MIDIConnectionView(midi: midi).disabled(timing.busy)
            if let error = scoreError ?? timing.error {
                Text(error).font(.callout).foregroundStyle(Color.clay).textSelection(.enabled)
            }
            if timing.hasUnsavedResult {
                HStack {
                    Text("Your completed pass is still here.").font(.callout)
                    Button("Try saving again") { save() }
                    Button("Discard unsaved pass…", role: .destructive) { discarding = true }
                }
            }
            Text(
                "One complete pass of the selected melody. Pitches and entrances are assessed; note lengths, pedal, dynamics and technique are yours to explore. Swing changes the backing, while your melody follows the written rhythm."
            ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            session.connect(midi)
            if state.isPreview { timingExpanded = CommandLine.arguments.contains("--playalong-calibration") }
            do {
                if let piece = state.libraryPieces.first(where: { $0.id == material.pieceID }) {
                    study = try ScoreEarMaterial.study(piece: piece, scope: material.scope)
                }
            } catch { scoreError = error.localizedDescription }
        }
        .onReceive(midi.updates) { if state.isPreview || NSApp.isActive { timing.receive($0) } }
        .onChange(of: timing.result?.id) { _, _ in save() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            timing.cancel()
        }
        .onChange(of: state.editor) { _, _ in checkSource() }
        .onChange(of: state.studies) { _, _ in checkSource() }
        .onDisappear { timing.cancel() }
        .confirmationDialog("Discard this unsaved play-along pass?", isPresented: $discarding) {
            Button("Discard pass", role: .destructive) { timing.discard() }
        }
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 18) {
                Stepper("\(session.setup.tempo) bpm", value: $session.setup.tempo, in: 50...160, step: 5).frame(
                    width: 145
                ).monospacedDigit()
                Picker("Feel", selection: $session.setup.style) {
                    ForEach(GrooveStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(maxWidth: 270)
                Spacer()
                Toggle("Guide melody", isOn: $session.setup.guide).toggleStyle(.checkbox)
            }
            HStack(spacing: 20) {
                Text("Your band").font(.caption).foregroundStyle(.secondary)
                Toggle("Piano", isOn: $session.setup.piano)
                Toggle("Bass", isOn: $session.setup.bass)
                Toggle("Drums", isOn: $session.setup.drums)
                Spacer()
                Text(session.setup.guide ? "Supported practice" : "You take the melody").foregroundStyle(.secondary)
            }.toggleStyle(.checkbox).font(.callout)
            Picker("Challenge", selection: $session.setup.challenge) {
                ForEach(PlayAlongChallenge.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Text(
                session.setup.challenge.invitation
                    + (session.setup.challenge == .notes || session.setup.challenge == .pulse
                        ? " Leave the spaces free of extra presses." : "")
            ).font(.callout).foregroundStyle(.secondary)
        }.disabled(locked)
    }
    private var progress: Double {
        guard timing.active, let plan = timing.plan else { return session.result == nil ? 0 : 1 }
        return min(1, max(0, timing.elapsed / plan.duration))
    }
    private var status: String {
        if timing.preparing { return "Preparing…" }
        if timing.active {
            if timing.elapsed < 0 { return "Count in · \(timing.countInRemaining)" }
            if timing.calibration { return "Tap one key on each click" }
            if timing.elapsed >= (timing.plan?.duration ?? 0) { return "Finishing…" }
            return "Bar \(material.scope.fromBar+Int(max(0,timing.elapsed)/(timing.plan?.secondsPerBeat ?? 1)/4))"
        }
        return session.result != nil ? "Pass complete" : "Ready when you are"
    }
    private var transport: some View {
        HStack(spacing: 14) {
            if timing.busy {
                Button("Stop", systemImage: "stop.fill") { timing.cancel() }.buttonStyle(.cadencePrimary)
                Text("An unfinished pass stays ungraded.").font(.caption).foregroundStyle(.secondary)
            } else {
                Button(session.result == nil ? "Count in & play" : "Try another pass", systemImage: "play.fill") {
                    start()
                }.buttonStyle(.cadencePrimary).disabled(timing.hasUnsavedResult || !midi.connected)
                Text(
                    session.calibrated
                        ? "Timing checked · \(session.offsetMS) ms" : "Release your keys · four-beat count-in"
                ).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !session.calibrated {
                    Button("Check MIDI timing") { timingExpanded = true }.buttonStyle(.plain).foregroundStyle(
                        Color.moss)
                }
            }
        }
    }
    private var timingSetup: some View {
        DisclosureGroup(
            "MIDI timing · \(session.calibrated ? "checked for this setup" : "optional eight-tap check")",
            isExpanded: $timingExpanded
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Listen to four count-in clicks, then press and release any one piano key on each of the next eight clicks. Use the same keyboard and audio output you’ll practise with."
                ).font(.callout)
                HStack {
                    Button("Count in & check eight taps", systemImage: "metronome") {
                        state.audio.stop()
                        state.microphone.stop()
                        session.calibrate(held: midi.keyboard.downNotes)
                    }.disabled(locked || !midi.connected)
                    Button("Reset timing") { session.invalidateTiming() }.disabled(locked)
                    Text("Offset \(session.offsetMS) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let report = timing.calibrationReport {
                    if let delta = report.calibrationOffsetMS,
                        (-250...250).contains(timing.conditions.offsetMS + delta),
                        !timing.attacks.contains(where: \.arrivalTimestamp)
                    {
                        HStack {
                            Text("Consistent taps · \(abs(delta)) ms \(delta >= 0 ? "after" : "before") the clicks.")
                            Button("Use this timing") { session.applyCalibration() }.disabled(locked)
                        }.font(.callout)
                    } else {
                        Text(
                            "These taps weren’t consistent enough, or MIDI timestamps were unavailable. Try again; no offset was applied."
                        ).font(.callout).foregroundStyle(Color.clay)
                    }
                }
                Text(
                    "This includes your tapping tendency as well as device delay. It lasts for this app session and resets after a keyboard or audio change. Built-in or wired audio is best for steady timing."
                ).font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 8)
        }.font(.callout)
    }
    @ViewBuilder private func resultCard(_ result: PlayAlongResult) -> some View {
        let report = result.pass.report
        let challenge = result.plan.setup.challenge
        let achieved = challenge.met(by: report, tolerance: result.pass.plan.tolerance)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(
                    challenge != .none && achieved
                        ? (result.assisted ? "Goal reached with support" : "Goal reached")
                        : report.clean ? "A steady pass." : "Here’s your next step."
                ).font(.system(size: 24, weight: .medium, design: .serif))
                Spacer()
                if challenge != .none {
                    Image(systemName: achieved ? "sparkles" : "scope").font(.title2).foregroundStyle(Color.moss)
                }
            }
            Text(
                "Last pass · \(result.plan.material.title) · \(result.plan.setup.tempo) bpm\(timing.saved ? " · saved" : " · awaiting save")"
            ).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 24) {
                metric("Pitch", value: report.matchedPitch, total: report.notes.count)
                metric(
                    "Pulse", value: report.timedEntrances(tolerance: result.pass.plan.tolerance),
                    total: report.notes.count)
                VStack(alignment: .leading, spacing: 5) {
                    Text("SPACE").font(.caption).tracking(1.2)
                    Text("\(report.extras.count) extra presses").font(.headline)
                }.foregroundStyle(.secondary)
            }
            if challenge != .none {
                Text(
                    challenge.rawValue + " · " + (achieved ? "completed" : "keep exploring")
                        + (result.plan.setup.guide ? " · guide melody on" : "")
                ).font(.callout).foregroundStyle(Color.moss)
            }
            if let bar = report.difficultBars.first {
                HStack {
                    Text("Start with bar \(bar+1). Hear its rhythm, then try a little slower.").font(.callout)
                    Spacer()
                    Button("Try 10 bpm slower") { session.setup.tempo = max(50, result.plan.setup.tempo - 10) }
                        .disabled(locked)
                }
            } else if !report.extras.isEmpty {
                Text("Let the written rests breathe; the extra presses are shown below.").font(.callout)
            }
            if let progress = state.history.playAlong?[result.practiceID], let due = progress.review.due {
                Text(
                    "Saved to your practice review · \(due.formatted(date:.abbreviated,time:.omitted)). Returning later helps test what stayed with you."
                ).font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup(
                "Every note · \(report.missed) missed, \(report.wrong) different pitches", isExpanded: $notesExpanded
            ) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(report.notes.enumerated()), id: \.offset) { _, note in
                        HStack {
                            Text(
                                "Bar \(note.target.bar+1) · beat \(String(format:"%g",note.target.beat.truncatingRemainder(dividingBy:4)+1))"
                            ).frame(width: 135, alignment: .leading)
                            Text(Pitch.chromatic(note.target.pitch) + String(note.target.pitch / 12 - 1)).frame(
                                width: 48, alignment: .leading)
                            Text(noteLabel(note)).foregroundStyle(note.verdict == .onTime ? Color.moss : Color.clay)
                            Spacer()
                        }.font(.callout.monospacedDigit())
                    }
                    if !report.extras.isEmpty {
                        Text(
                            "Extra presses: "
                                + report.extras.map {
                                    Pitch.chromatic($0.pitch) + String($0.pitch / 12 - 1) + " at "
                                        + String(format: "%.2fs", $0.seconds)
                                }.joined(separator: ", ")
                        ).font(.caption)
                    }
                }.padding(.top, 8)
            }
            Text(
                "On time: ±\(Int((result.pass.plan.tolerance*1000).rounded())) ms. Offset: \(result.pass.conditions.offsetMS) ms. \(result.assisted ? "Guide melody or fallback timestamps make this supported evidence." : "The guide melody was muted.")"
            ).font(.caption).foregroundStyle(.secondary)
        }.padding(20).background(Color.moss.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
    }
    private func metric(_ title: String, value: Int, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.caption).tracking(1.2).foregroundStyle(.secondary)
            Text("\(value) / \(total)").font(.system(size: 27, weight: .medium, design: .serif)).foregroundStyle(
                Color.moss)
        }
    }
    private func noteLabel(_ note: TimedAssessment) -> String {
        let delta = note.delta.map { " · \(Int(abs($0)*1000)) ms \($0 < 0 ? "early" : "late")" } ?? ""
        switch note.verdict {
        case .onTime: return "On time"
        case .early: return "Early" + delta
        case .late: return "Late" + delta
        case .wrongPitch:
            return "Played " + (note.attack.map { Pitch.chromatic($0.pitch) + String($0.pitch / 12 - 1) } ?? "?")
                + delta
        case .missed: return "Missed · keep going"
        }
    }
    private func start() {
        do {
            let plan = try state.playAlongPlan(material, setup: session.setup)
            state.audio.stop()
            state.microphone.stop()
            session.start(plan, held: midi.keyboard.downNotes)
        } catch { timing.error = error.localizedDescription }
    }
    private func save() { session.save { try state.savePlayAlong($0) } }
    private func checkSource() {
        if timing.busy, !state.scoreEarCurrent(material) {
            timing.cancel("The source changed. Open a reviewed passage from the current piece.")
        }
    }
}
