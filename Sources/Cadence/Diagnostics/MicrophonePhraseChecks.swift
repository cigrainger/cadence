// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

@MainActor enum MicrophonePhraseDiagnostics { static var checks: [String: Bool] = [:] }
@MainActor enum MicrophonePhraseChecks {
    static func take(_ plan: MicrophonePhrasePlan, date: Date, clean: Bool = false) -> MicrophonePhraseTake {
        let rate = 12000.0
        let origin = 1000.0
        let mapping = AcousticClockEvidence(
            firstSampleTime: 0, firstHostSeconds: origin - 5, sampleRate: rate, frameCount: Int(rate * 30),
            maximumHostResidualMS: 2)
        var calibration = AcousticCalibration(
            routeID: "original-synthetic-loopback", sampleRate: rate, offsetMS: 80, jitterMS: 5,
            date: date.addingTimeInterval(-60), matchedPulses: 8)
        calibration.clockEvidence = .init(
            firstSampleTime: 0, firstHostSeconds: 100, sampleRate: rate, frameCount: Int(rate * 8),
            maximumHostResidualMS: 2)
        let attacks = plan.timed.targets.enumerated().map { index, target in
            let pitch = target.pitch + (!clean && index == 2 ? 1 : 0)
            let host = origin + target.beat * plan.timed.secondsPerBeat + 0.08 + (!clean && index == 4 ? 0.14 : 0)
            return AcousticAttack(
                hostSeconds: host, frequency: 440 * pow(2, Double(pitch - 69) / 12), confidence: 0.98,
                rms: 0.12, clippedFraction: 0, onsetUncertaintyMS: 10,
                sampleTime: mapping.sampleTime(at: host), sampleRate: rate)
        }
        return .init(
            date: date, plan: plan, originHostSeconds: origin, calibration: calibration,
            routeID: calibration.routeID, sampleRate: rate, attacks: attacks, clock: .sharedHost,
            clockEvidence: mapping)
    }

    static func preview(_ state: AppState) throws {
        try state.addMicrophoneExample()
        let plan = state.microphonePhraseSession.plan!
        let args = CommandLine.arguments
        let independent = args.contains("--microphone-independent")
        var selected = take(plan, date: Date().addingTimeInterval(-22 * 3600), clean: independent)
        if args.contains("--microphone-uncertain") {
            selected.signalIssue =
                "Clipped input in this original synthetic example. Reduce the input gain, then try a clean single note."
            selected.disputedTargets = [1]
        }
        try state.saveMicrophoneTake(selected)
        if args.contains("--microphone-focus") {
            let focus = try plan.focused(around: 2).configured(tempo: 64)
            selected = take(focus, date: Date(), clean: true)
            try state.saveMicrophoneTake(selected)
        } else if independent {
            try state.resumeMicrophonePhrase(plan.key, independent: true)
            selected = take(state.microphonePhraseSession.plan!, date: Date(), clean: true)
            try state.saveMicrophoneTake(selected)
        }
        state.microphonePhraseSession.inspect(selected)
        var checks = [
            "sourceLinked": selected.plan.isCurrent(in: state.libraryPieces.first { $0.id == plan.material.pieceID }!),
            "validState": (try? state.practiceState.validated()) != nil,
            "clockProvenance": selected.clockEvidence?.usable == true
                && selected.attacks.allSatisfy { $0.sampleTime != nil },
            "calibrationSeparate": state.microphonePhraseSession.calibration == nil,
            "noLiveInput": !state.microphone.listening && !state.audio.isPlaying,
            "savedEvidence": state.microphonePhrases.active?.latest?.id == selected.id,
            "perNoteCoachData": selected.evidence.contains("Per-note evidence:"),
        ]
        if args.contains("--microphone-uncertain") {
            checks["uncertaintyAbstains"] =
                !selected.report.conclusive && selected.scoreFeedback.isEmpty
                && state.journal.attempts.last?.outcome == .skipped
        } else if args.contains("--microphone-focus") {
            checks["focusedContextRetained"] =
                selected.plan.material == plan.material && !selected.plan.isFullPhrase
                && selected.plan.mode == .focused
        } else if independent {
            checks["independentReturn"] =
                !selected.assisted && selected.plan.isFullPhrase
                && state.microphonePhrases.active?.review.lastGrade == .good
        } else {
            checks["pitchTimingSeparate"] = selected.report.wrongPitch == 1 && selected.report.late == 1
            checks["finalNoteUnaffected"] = selected.report.notes.last?.clean == true
        }
        MicrophonePhraseDiagnostics.checks = checks
        if args.contains("--microphone-coach") {
            state.openContextCoach()
            checks["coachPinsSelectedTake"] =
                state.contextCoach.context?.reference.contains("Per-note evidence:") == true
            MicrophonePhraseDiagnostics.checks = checks
        }
    }
}
