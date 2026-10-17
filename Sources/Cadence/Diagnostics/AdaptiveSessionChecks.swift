// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

@MainActor enum AdaptiveSessionDiagnostics { static var checks: [String: Bool] = [:] }
@MainActor enum AdaptiveSessionChecks {
    static func preview(state: AppState) throws {
        guard let pathway = state.selectedMusicalPathway else {
            throw MusicError.invalid("The pathway fixture is missing.")
        }
        try state.openAdaptiveSession(pathway.id)
        let initial = state.smoothPractice.active!
        let count = state.journal.attempts.count
        // Use the same capture path as USB MIDI, with actual note-on/off gestures.
        func play(_ notes: [Int]) {
            var keys = MIDIKeyboardState()
            state.adaptiveInput.listen(held: [])
            for chord in [state.smoothPractice.active!.current!.from, notes] {
                for note in chord {
                    let m = MIDIMessage.noteOn(channel: 0, note: note, velocity: 85)
                    keys.receive(m)
                    state.adaptiveInput.receive(.init(message: m, keyboard: keys), state: state, active: true)
                }
                for note in chord {
                    let m = MIDIMessage.noteOff(channel: 0, note: note)
                    keys.receive(m)
                    state.adaptiveInput.receive(.init(message: m, keyboard: keys), state: state, active: true)
                }
            }
        }
        play([60, 64, 67])
        let miss = state.smoothPractice.active?.responses.last
        try state.changeAdaptiveSession { try $0.retry() }
        play([57, 60, 65])
        let retry = state.smoothPractice.active?.responses.last
        var checks = [
            "multipleAnswers": initial.current!.solutions.count >= 2,
            "midiCaptured": state.journal.attempts.count == count + 2,
            "retrySupported": miss?.outcome == .incorrect && retry?.outcome == .correct && retry?.assisted == true,
            "missRetained": state.history.cards[miss!.attempt(sessionID: initial.id, pathwayID: pathway.id).activityID]?
                .review.lastGrade == .again,
        ]
        try state.changeAdaptiveSession { try $0.advance() }
        func finishBlock() throws {
            while let prompt = state.smoothPractice.active?.current {
                play(prompt.solutions[0])
                try state.changeAdaptiveSession {
                    try $0.advance()
                    $0.suggestFocus()
                }
            }
        }
        try finishBlock()
        checks["focusedRepair"] = state.smoothPractice.active?.focusIndex == 0
        try state.changeAdaptiveSession { try $0.nextPhase() }
        try finishBlock()
        try state.changeAdaptiveSession { try $0.nextPhase() }
        checks["transferUnhinted"] =
            state.smoothPractice.active?.phase == .transfer && state.smoothPractice.active?.hinted == false
            && state.smoothPractice.active?.current?.fromRoot == 2
        let transferStart = state.smoothPractice
        try finishBlock()
        checks["independentTransfer"] = state.smoothPractice.active?.independentTransferCount == 3
        try state.changeAdaptiveSession { try $0.nextPhase() }
        let compositionStart = state.smoothPractice
        let scoreID = try state.openPathwayComposition(pathway.id)
        var score = state.editor.active
        for bar in 0..<4 {
            if let index = score.events.firstIndex(where: { $0.bar == bar && $0.staff == 1 }) {
                score.events[index].pitches = [[60, 64, 67], [60, 65, 69], [59, 62, 67], [60, 64, 67]][bar].map {
                    EditorPitch($0)
                }
            }
        }
        state.editor.replace(score)
        try state.finishAdaptiveSession(
            reflection: "I kept C in place on the first change, and let the top voice rise gently.",
            includeComposition: true)
        checks["compositionLinked"] = state.smoothPractice.active?.compositionID == scoreID
        checks["sessionValid"] = (try? state.practiceState.validated()) != nil
        if CommandLine.arguments.contains("--adaptive-transfer") {
            state.smoothPractice = transferStart
        } else if CommandLine.arguments.contains("--adaptive-compose") {
            state.smoothPractice = compositionStart
        } else if !CommandLine.arguments.contains("--adaptive-summary") {
            // Return to the first prompt for a visual check, keeping fixture-only
            // diagnostics above separate from the state displayed here.
            var book = SmoothPractice()
            try book.begin(initial)
            state.smoothPractice = book
            if CommandLine.arguments.contains("--adaptive-feedback") { play([53, 57, 60]) }
        }
        state.showAdaptiveSession = true
        state.destination = .courses
        state.musicalPathwayStep = nil
        AdaptiveSessionDiagnostics.checks = checks
    }
}
