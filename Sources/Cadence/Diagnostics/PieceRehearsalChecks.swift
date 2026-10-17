// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

@MainActor enum RehearsalDiagnostics { static var checks: [String: Bool] = [:] }
@MainActor enum PieceRehearsalChecks {
    static func document() throws -> EditorDocument {
        var doc = try EditorDocument.blank(instrument: .piano, bars: 12)
        doc.title = "Room for a little light"
        doc.tempo = 80
        doc.events.removeAll { $0.staff == 1 }
        let melody = [
            [62, 65], [67, 71], [72, 71], [67, 64], [64, 67], [69, 72], [71, 69], [67, 64], [62, 65], [67, 71],
            [72, 67], [64, 60],
        ]
        for (bar, notes) in melody.enumerated() {
            doc.events += notes.map { EditorEvent(bar: bar, rhythm: .init(960), pitches: [EditorPitch($0)]) }
        }
        doc.harmonies = try ["Dm7", "G7", "Cmaj7", "Cmaj7", "Em7", "Am7", "Dm7", "G7", "Dm7", "G7", "Cmaj7", "Cmaj7"]
            .enumerated().map { .init(bar: $0.offset, symbol: try ChordSymbol.parse($0.element)) }
        return try doc.validated()
    }
    static func capture(
        state: AppState, exercise: RehearsalExercise = .notes, input: TimedInput = .midi, imperfect: Bool = false,
        live: Bool = false, save: Bool = true
    ) throws {
        guard let record = state.currentRehearsal else { throw MusicError.invalid("No preview session.") }
        let session = state.rehearsalSession
        let plan = try session.prepare(
            record, exercise: exercise, tempo: record.stage == .focus ? 65 : 80, input: input, held: [])
        let origin = PracticeClock.now() - (live ? 2.5 : plan.duration + 1)
        session.timing.begin(at: origin)
        var keys = MIDIKeyboardState()
        for (i, target) in plan.targets.enumerated() where !live || i < 2 {
            if imperfect && i == 4 { continue }
            let pitch = target.pitch + (imperfect && (i == 5 || (plan.targets.count > 8 && i == 6)) ? 1 : 0)
            let time = origin + target.beat * plan.secondsPerBeat + (imperfect && i == 1 ? 0.14 : 0)
            for message in [
                MIDIMessage.noteOn(channel: 0, note: pitch, velocity: 88), .noteOff(channel: 0, note: pitch),
            ] {
                keys.receive(message)
                session.timing.receive(.init(message: message, keyboard: keys, timestamp: time))
            }
        }
        session.timing.tick()
        if !live && save { state.saveRehearsalPass() }
    }
    static func preview(state: AppState) throws {
        var doc = try document()
        if CommandLine.arguments.contains("--rehearsal-chords"),
            let index = doc.events.firstIndex(where: { $0.staff == 1 && $0.bar == 6 })
        {
            doc.events[index].pitches = [EditorPitch(62), EditorPitch(65), EditorPitch(69)]
        }
        let piece = LibraryPiece(source: .score(doc))
        let earlier = Date().addingTimeInterval(-172800)
        state.editor.documents.append(doc)
        state.midi.installPreview()
        state.openPieceRehearsal(piece)
        try state.beginRehearsal(
            piece, scope: .init(partID: "P1", staff: 1, from: 4, through: 7), tempo: 80, now: earlier)
        var checks = [
            "fullScore": try RehearsalSource.whole(piece).selectedMeasures.count == 12,
            "sourceLinked": state.currentRehearsal?.pieceID == piece.id,
        ]
        if CommandLine.arguments.contains("--rehearsal-opening") {
            checks["openingUngraded"] = state.journal.attempts.isEmpty
        } else {
            try capture(state: state, imperfect: true)
            guard let focused = state.currentRehearsal else { throw MusicError.invalid("Opening was not saved.") }
            checks["focusFromEvidence"] = focused.stage == .focus && focused.focus?.source?.scope.from == 6
            checks["openingSaved"] = state.rehearsalSession.timing.saved && state.journal.attempts.count == 1
            if CommandLine.arguments.contains("--rehearsal-live") {
                try capture(state: state, live: true)
                checks["liveUngraded"] =
                    state.rehearsalSession.timing.result == nil && state.journal.attempts.count == 1
            }
            if CommandLine.arguments.contains("--rehearsal-context")
                || CommandLine.arguments.contains("--rehearsal-review")
                || CommandLine.arguments.contains("--rehearsal-complete")
            {
                try capture(state: state, exercise: .rhythm)
                try state.updateRehearsal(focused.key) { try $0.returnToPhrase() }
                state.rehearsalSession.timing.discard()
                checks["contextRestored"] =
                    state.currentRehearsal?.activePlan.source?.scope == focused.opening.source?.scope
                if !CommandLine.arguments.contains("--rehearsal-context") {
                    // Historical authored fixture makes the independent return
                    // available without changing the system clock or user data.
                    var r = try PieceRehearsal(opening: focused.opening, now: earlier)
                    func pass(_ p: TimedPracticePlan, _ seconds: Double, click: Bool = false) -> TimedPracticeResult {
                        .init(
                            date: earlier.addingTimeInterval(seconds), plan: p, conditions: .init(click: click),
                            attacks: p.targets.map { .init(seconds: $0.beat * p.secondsPerBeat, pitch: $0.pitch) })
                    }
                    try r.recordOpening(
                        pass(focused.opening, 1), focus: focused.focus!, context: focused.context!,
                        now: earlier.addingTimeInterval(1))
                    try r.recordFocus(
                        pass(focused.focus!, 2, click: true), exercise: .notes, now: earlier.addingTimeInterval(2))
                    try r.returnToPhrase()
                    try r.recordContext(pass(focused.context!, 3), now: earlier.addingTimeInterval(3))
                    var copy = state.practiceState
                    copy.rehearsal?.records[r.key] = r
                    try state.commitPractice(copy)
                    checks["dueReturn"] = state.practiceReviews().contains { $0.id == r.key }
                    checks["supportedNoMastery"] = r.review.intervalDays == 0
                    if CommandLine.arguments.contains("--rehearsal-review") {
                        try state.updateRehearsal(r.key) { try $0.beginReview() }
                        checks["independentReady"] =
                            state.currentRehearsal?.reviewStarts == 0 && state.currentRehearsal?.stage == .review
                    }
                }
            }
        }
        if CommandLine.arguments.contains("--rehearsal-stale") {
            try capture(state: state, save: false)
            let index = state.editor.documents.firstIndex { $0.id == doc.id }!
            let event = state.editor.documents[index].events.firstIndex { $0.staff == 1 }!
            state.editor.documents[index].events[event].pitches = [EditorPitch(85)]
            state.saveRehearsalPass()
            let changed = LibraryPiece(source: .score(state.editor.documents[index]))
            state.openPieceRehearsal(changed)
            checks["staleSourceBlocked"] = state.currentRehearsal.map { !state.rehearsalCurrent($0) } == true
            checks["pendingRetained"] = state.rehearsalSession.timing.hasUnsavedResult
        }
        checks["validSavedState"] = (try? state.practiceState.validated()) != nil
        RehearsalDiagnostics.checks = checks
    }
}
