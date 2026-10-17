// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

@MainActor enum PlayAlongDiagnostics { static var checks: [String: Bool] = [:] }
@MainActor enum PlayAlongChecks {
    static func preview(state: AppState) throws {
        let doc = try ScoreEarChecks.document()
        let material = try ScoreEarChecks.material(doc)
        state.editor.documents.append(doc)
        state.midi.installPreview()
        var setup = PlayAlongSetup()
        setup.tempo = 80
        setup.challenge = .pulse
        state.openPlayAlong(material, setup: setup)
        let session = state.playAlongSession
        let timing = session.timing
        // Exercise the real timing adapter, using an injected audible origin and
        // original host timestamps. No sound or physical MIDI is needed here.
        let calibration = TimedPracticePlan.calibration()
        let calibrationOrigin = PracticeClock.now() - calibration.duration - 1
        guard timing.prepare(calibration, conditions: .init(), held: [], calibration: true) else {
            throw MusicError.invalid("Calibration preview could not start.")
        }
        timing.begin(at: calibrationOrigin)
        for target in calibration.targets {
            timing.attack(at: calibrationOrigin + target.beat * calibration.secondsPerBeat + 0.07)
        }
        timing.tick()
        session.applyCalibration()
        var checks = [
            "calibrated": session.calibrated && session.offsetMS == 70,
            "calibrationUngraded": timing.result == nil && state.history.playAlong == nil,
        ]
        if !CommandLine.arguments.contains("--playalong-calibration") {
            let plan = try state.playAlongPlan(material, setup: setup)
            guard session.prepare(plan, held: []) else {
                throw MusicError.invalid("Play-along preview could not start.")
            }
            let live = CommandLine.arguments.contains("--playalong-live")
            let origin = PracticeClock.now() - (live ? 4.6 : plan.timed.duration + 1)
            timing.begin(at: origin)
            var keys = MIDIKeyboardState()
            for (index, target) in plan.timed.targets.enumerated() where !live || index < 3 {
                if index == 3 { continue }
                let pitch = target.pitch + (index == 2 ? 1 : 0)
                let seconds = target.beat * plan.timed.secondsPerBeat + (index == 1 ? -0.14 : index == 4 ? 0.13 : 0)
                for message in [
                    MIDIMessage.noteOn(channel: 0, note: pitch, velocity: 90), .noteOff(channel: 0, note: pitch),
                ] {
                    keys.receive(message)
                    timing.receive(.init(message: message, keyboard: keys, timestamp: origin + seconds + 0.07))
                }
            }
            timing.tick()
            if !live {
                session.save { try state.savePlayAlong($0) }
                guard let result = session.result else {
                    throw MusicError.invalid("The preview result was not produced.")
                }
                checks["separatePitchPulse"] =
                    result.pass.report.matchedPitch == 6
                    && result.pass.report.timedEntrances(tolerance: plan.timed.tolerance) == 5
                checks["missDoesNotCascade"] = result.pass.report.notes.last?.verdict == .onTime
                checks["savedAndReviewable"] =
                    timing.saved
                    && state.practiceReviews(now: Date().addingTimeInterval(601)).contains {
                        $0.id == result.practiceID
                    }
                checks["canonicalResult"] = result.valid && (try? state.practiceState.validated()) != nil
            } else {
                checks["liveFeedback"] = session.feedback.count == 3 && session.feedback.allSatisfy(\.settled)
                checks["unfinishedUngraded"] = session.result == nil
            }
        }
        PlayAlongDiagnostics.checks = checks
    }
}
