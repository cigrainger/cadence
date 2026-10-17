// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

@MainActor enum EarPathwayDiagnostics { static var checks: [String: Bool] = [:] }
@MainActor enum GrooveDiagnostics { static var checks: [String: Bool] = [:] }
@MainActor enum EarPathwayChecks {
    static func preview(state: AppState) throws {
        state.openEarPathway()
        let opening = state.earPractice
        func event(_ kind: EarEvent.Kind, notes: [Int] = []) throws {
            guard let session = state.earPractice.active else { throw MusicError.invalid("Missing ear fixture.") }
            try state.saveEarEvent(.init(expected: session, event: .init(kind, notes: notes)))
        }
        func sing(_ notes: [Int]) throws {
            state.earInput.arm(state: state)
            for (index, note) in notes.enumerated() {
                let frequency = 440 * pow(2, Double(note - 69) / 12)
                let samples = (0..<4096).map { Float(sin(2 * Double.pi * frequency * Double($0) / 12000)) }
                let detection = PitchDetector.detect(samples, sampleRate: 12000)
                state.earInput.receivePitch(detection, at: Double(index), state: state)
                state.earInput.receivePitch(detection, at: Double(index) + 0.4, state: state)
            }
            state.earInput.submit(.init(.answer, notes: state.earInput.notes), state: state)
        }
        func play(_ notes: [Int]) {
            state.earInput.arm(state: state)
            var keys = MIDIKeyboardState()
            for note in notes {
                for message in [
                    MIDIMessage.noteOn(channel: 0, note: note, velocity: 80), .noteOff(channel: 0, note: note),
                ] {
                    keys.receive(message)
                    state.earInput.receive(.init(message: message, keyboard: keys), state: state)
                }
            }
            state.earInput.submit(.init(.answer, notes: state.earInput.notes), state: state)
        }
        try event(.heard)
        try event(.imagined)
        try sing([60, 61, 60])
        try event(.next)
        let keyboard = state.earPractice
        play([60, 62, 60])
        try event(.next)
        let review = state.earPractice
        var checks = [
            "voiceCaptured": state.journal.attempts.first?.input == .singing
                && state.journal.attempts.first?.outcome == .incorrect,
            "midiCaptured": state.journal.attempts.last?.input == .midi
                && state.journal.attempts.last?.outcome == .correct,
        ]
        try event(.next)
        checks["focusedReturn"] = try state.earPractice.active?.projection().focused == true
        try event(.heard)
        try event(.imagined)
        try event(.hint)
        let solfege = state.earPractice
        try sing([60, 62, 60])
        try event(.next)
        play([60, 62, 60])
        try event(.next)
        try event(.next)
        checks["separateReviews"] =
            state.history.cards["ear:v1:0:60:singing"]?.review.lastGrade == .again
            && state.history.cards["ear:v1:0:60:midi"]?.review.intervalDays == 1
        checks["transferHidden"] =
            try state.earPractice.active?.projection().phrase.tonic == 62
            && state.earPractice.active?.projection().hinted == false
        try event(.heard)
        try event(.imagined)
        try sing([62, 64, 62])
        try event(.next)
        play([62, 64, 62])
        try event(.next)
        try event(.next)
        checks["sessionComplete"] = try state.earPractice.active?.projection().stage == .complete
        checks["validSnapshot"] = (try? state.practiceState.validated()) != nil
        let args = CommandLine.arguments
        if args.contains("--ear-solfege") {
            state.earPractice = solfege
        } else if args.contains("--ear-play") {
            state.earPractice = keyboard
        } else if args.contains("--ear-review") {
            state.earPractice = review
        } else if !args.contains("--ear-summary") {
            state.earPractice = opening
        }
        state.earInput.pause()
        state.practicePage = .ear
        state.destination = .practice
        EarPathwayDiagnostics.checks = checks
    }
}
