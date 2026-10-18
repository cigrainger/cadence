// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

@MainActor enum EarDailyDiagnostics { static var checks: [String: Bool] = [:] }

@MainActor enum EarDailyChecks {
    static func preview(_ state: AppState, arguments: [String] = CommandLine.arguments) throws {
        let args = arguments
        let guitar = args.contains("--daily-guitar")
        let instrument: EditorInstrument = guitar ? .guitar : .piano
        let now = Date()
        let returning = args.contains("--daily-recall") || args.contains("--daily-transfer")
        let base = returning ? now.addingTimeInterval(-3 * 86400) : now.addingTimeInterval(-60)
        try state.startSongJourney(instrument: instrument)
        let journey = state.selectedSongJourney!
        try state.openEarDaily(journey, now: base)
        if args.contains("--daily-ax") {
            EarDailyDiagnostics.checks = checks(state, journey: journey, returning: false)
            return
        }
        let id = state.earDailySession!.id
        try state.hearEarDaily(id, now: base, play: { _ in })
        try state.updateEarDaily(id) { try $0.imagined(now: base.addingTimeInterval(1)) }
        let opening = state.earDailySession!
        if guitar {
            let plan = try state.earDailyMicrophonePlan(opening)
            var book = state.microphonePhrases
            try book.open(plan)
            var snapshot = state.practiceState
            snapshot.microphonePhrases = book
            try state.commitPractice(snapshot)
            var take = MicrophonePhraseChecks.take(plan, date: base.addingTimeInterval(2), clean: true)
            take.calibration = nil
            if args.contains("--daily-uncertain") { take.disputedTargets = [0] }
            if args.contains("--daily-miss") {
                let pitch = plan.timed.targets[2].pitch + 1
                take.attacks[2].frequency = 440 * pow(2, Double(pitch - 69) / 12)
            }
            _ = try state.saveEarDailyMicrophone(take)
        } else {
            var notes = opening.expectedNotes
            if args.contains("--daily-miss") { notes[2] += 1 }
            try state.saveEarDailyAttempt(
                opening.midiAttempt(notes: notes, now: base.addingTimeInterval(2)), expected: opening)
        }
        if args.contains("--daily-reveal") {
            try state.updateEarDaily(id) { try $0.reveal(now: base.addingTimeInterval(3)) }
        }
        if args.contains("--daily-focus") {
            try state.updateEarDaily(id) { try $0.retry(bar: 2, now: base.addingTimeInterval(4)) }
        }
        if args.contains("--daily-answer") || args.contains("--daily-complete") || returning {
            let answerID = try state.openEarDailyAnswer(id, now: base.addingTimeInterval(5))
            if args.contains("--daily-complete") || returning {
                var scores = state.editor
                let index = scores.documents.firstIndex { $0.id == answerID }!
                let midi = opening.expectedNotes[0]
                let position =
                    guitar
                    ? Guitar.positions(
                        midi: midi, tuning: scores.documents[index].tuning,
                        capo: scores.documents[index].capo
                    ).first : nil
                scores.documents[index].events[0].pitches = [
                    EditorPitch(midi, string: position?.string, fret: position?.fret)
                ]
                try state.commitScores(scores)
                let answer = state.editor.documents[index]
                try state.finishCreativeAnswer(
                    answerID, listenedFingerprint: LibraryPiece(source: .score(answer)).fingerprint,
                    now: base.addingTimeInterval(6))
                try state.resumeEarDaily(id)
                try state.finishEarDaily(id, now: base.addingTimeInterval(7))
            }
        }
        if returning {
            try state.openEarDaily(journey, mode: args.contains("--daily-transfer") ? .transfer : .recall, now: now)
        }
        if args.contains("--daily-play") {
            try state.updateEarDaily(id) { try $0.retry(now: base.addingTimeInterval(8)) }
        }
        let session = state.earDailySession!
        EarDailyDiagnostics.checks = checks(state, journey: journey, returning: returning)
        if args.contains("--daily-uncertain") {
            EarDailyDiagnostics.checks["uncertaintyAbstains"] = state.earDailyLatestAttempt == nil
        }
        if args.contains("--daily-answer") || args.contains("--daily-complete") {
            EarDailyDiagnostics.checks["stableAnswer"] = state.editor.documents.contains {
                $0.id == session.answerID && $0.responseSource?.sessionID == session.id
            }
        }
    }

    private static func checks(_ state: AppState, journey: SongJourney, returning: Bool) -> [String: Bool] {
        let session = state.earDailySession!
        return [
            "sourceLinked": state.scoreEarCurrent(session.material),
            "validState": (try? state.practiceState.validated()) != nil,
            "inputSpecific": state.earDailyLatestAttempt.map {
                $0.input == (session.instrument == .guitar ? .microphone : .midi)
            } ?? true,
            "noTimingGrade": state.earDailyLatestAttempt?.timedPracticeID == nil,
            "fullPieceRetained": state.libraryPieces.first { $0.id == journey.material.pieceID }?.bars == 8,
            "noLiveInput": !state.microphone.listening && !state.audio.isPlaying,
            "noPaidRequests": state.contextCoach.lines.isEmpty,
            "referencesCanonical": session.attemptIDs.allSatisfy { id in
                state.journal.attempts.contains { $0.id == id }
                    || state.microphonePhrases.sessions.flatMap(\.takes).contains { $0.id == id }
            },
            "independenceSeparate": returning ? !session.assisted : session.assisted,
        ]
    }

    /// The AX runner presses the actual native controls. Only its isolated
    /// preview injects virtual key releases; it never opens a hardware device.
    static func fillMIDI(_ state: AppState) {
        guard state.isPreview, CommandLine.arguments.contains("--daily-ax"), let session = state.earDailySession else {
            return
        }
        var notes = session.expectedNotes
        if session.attemptIDs.isEmpty, notes.count > 2 { notes[2] += 1 }
        var keyboard = MIDIKeyboardState()
        for note in notes {
            for message in [MIDIMessage.noteOn(channel: 0, note: note, velocity: 80), .noteOff(channel: 0, note: note)]
            {
                keyboard.receive(message)
                state.earDailyInput.receive(.init(message: message, keyboard: keyboard), state: state)
            }
        }
    }
}
