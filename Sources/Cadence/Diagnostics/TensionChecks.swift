// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

@MainActor enum TensionDiagnostics { static var checks: [String: Bool] = [:] }
@MainActor enum TensionChecks {
    static func preview(state: AppState) throws {
        let args = CommandLine.arguments
        let guitar = args.contains("--tension-guitar")
        try state.beginTensionExample(instrument: guitar ? .guitar : .piano)
        let source = state.tensionPractice.active!.source
        let piece = state.libraryPieces.first { $0.id == source.pieceID }!
        for (i, anchor) in source.changes.enumerated() {
            let reading = HarmonyTheory.suggestion(
                anchor.symbol, next: i + 1 < source.changes.count ? source.changes[i + 1].symbol : nil,
                tonic: source.tonic)
            var readings = [reading]
            if i == 0 {
                readings.append(
                    .init(
                        roman: "VI7", function: .colour, convention: "Root relation in C major",
                        explanation: "Describes the root and quality; V7/ii also describes its destination."))
            }
            try state.saveHarmonicReading(
                piece: piece, scope: source.scope, item: .init(anchor: anchor, readings: readings), expected: nil)
        }
        if [
            "--tension-explain", "--tension-play", "--tension-create", "--tension-complete", "--tension-ending",
            "--tension-review",
        ].contains(where: args.contains) {
            state.tensionInput.submit(.heard(0), state: state)
            state.tensionInput.submit(.heard(1), state: state)
            state.tensionInput.submit(.hearChoice(state.tensionPractice.active!.majorSlot), state: state)
        }
        if ["--tension-play", "--tension-create", "--tension-complete", "--tension-ending", "--tension-review"]
            .contains(where: args.contains)
        {
            state.tensionInput.submit(.explanation(0), state: state)
        }
        if ["--tension-create", "--tension-complete", "--tension-ending", "--tension-review"].contains(
            where: args.contains)
        {
            if guitar {
                state.tensionInput.submit(.guitarReport, state: state)
            } else {
                state.tensionInput.arm(state)
                var keys = MIDIKeyboardState()
                for note in source.melody {
                    for message in [
                        MIDIMessage.noteOn(channel: 0, note: note, velocity: 80), .noteOff(channel: 0, note: note),
                    ] {
                        keys.receive(message)
                        state.tensionInput.receive(.init(message: message, keyboard: keys), state: state)
                    }
                }
            }
        }
        if ["--tension-complete", "--tension-ending", "--tension-review"].contains(where: args.contains) {
            try state.openTensionEnding()
            var scores = state.editor
            let i = scores.documents.firstIndex { $0.id == scores.activeID }!
            let notes = [61, 62]
            for bar in 0..<2 {
                let event = scores.documents[i].events.first { $0.bar == bar && $0.staff == 1 }!
                try scores.documents[i].setPitch(event.id, midi: notes[bar])
            }
            try state.commitScores(scores)
            if !args.contains("--tension-ending") {
                state.tensionInput.submit(
                    .creation("I kept the rising semitone and left space after the arrival."), state: state)
                state.showTension()
            }
        }
        if args.contains("--tension-review") {
            try state.resumeTension(state.tensionPractice.active!.id, skill: .playing)
        }
        guard state.tensionInput.pending == nil else {
            throw MusicError.invalid(state.tensionInput.error ?? "Preview answer did not save.")
        }
        var checks = [
            "sourceLinked": state.tensionPractice.active?.source.current(in: piece) == true,
            "validState": (try? state.practiceState.validated()) != nil,
            "editableAlternatives": state.savedAnalysis(piece)?.annotations.first?.readings.count == 2,
            "musicalSourceUnchanged": state.libraryPieces.first { $0.id == piece.id }?.fingerprint == piece.fingerprint,
            "noPaidRequests": true,
        ]
        if args.contains("--tension-create") || args.contains("--tension-complete") || args.contains("--tension-ending")
            || args.contains("--tension-review")
        {
            checks["pianoPitchEvidence"] = state.journal.attempts.contains {
                $0.input == .midi && $0.outcome == .correct
            }
        }
        if args.contains("--tension-ending") || args.contains("--tension-complete") {
            checks["savedLinkedEnding"] = state.tensionEnding(state.tensionPractice.active!)?.tensionSource == source
        }
        if args.contains("--tension-complete") {
            checks["fourSeparateReviews"] = state.tensionPractice.active?.reviews.count == 4
        }
        if args.contains("--tension-review") {
            checks["independentHintsHidden"] =
                state.tensionPractice.active?.independent == true && state.tensionPractice.active?.assisted == false
        }
        TensionDiagnostics.checks = checks
    }
}
