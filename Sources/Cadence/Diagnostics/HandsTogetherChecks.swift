// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

@MainActor enum HandsTogetherDiagnostics { static var checks: [String: Bool] = [:] }
@MainActor enum HandsTogetherChecks {
    static func document() throws -> EditorDocument {
        var doc = try PieceRehearsalChecks.document()
        doc.events.removeAll { $0.staff == 2 }
        let roots = [50, 43, 48, 48, 52, 45, 50, 43, 50, 43, 48, 48]
        for (bar, root) in roots.enumerated() {
            doc.events.append(.init(bar: bar, staff: 2, rhythm: .init(960), pitches: [EditorPitch(root)]))
            doc.events.append(.init(bar: bar, staff: 2, rhythm: .init(960), pitches: [EditorPitch(root + 7)]))
        }
        return try doc.validated()
    }
    /// Virtual native MIDI events exercise recording, matching and atomic saves.
    static func capture(
        state: AppState, exercise: RehearsalExercise = .notes, partner: Bool = true, live: Bool = false,
        save: Bool = true
    ) throws {
        guard let record = state.currentRehearsal,
            let piece = state.libraryPieces.first(where: { $0.id == record.pieceID })
        else { throw MusicError.invalid("No hands-together phrase.") }
        let session = state.rehearsalSession
        let source =
            record.stage == .focus
            ? try PieceRehearsal.exercisePlan(record.activePlan, exercise: exercise, tempo: 65) : record.activePlan
        let material = try PianoPhrase(piece: piece, plan: source)
        let plan = try session.prepare(
            record, exercise: exercise, tempo: 65, input: .midi, held: [], pianoPhrase: material, playPartner: partner)
        let origin = PracticeClock.now() - (live ? 1.2 : plan.duration + 1)
        session.timing.begin(at: origin)
        var events: [(Double, MIDIMessage)] = []
        for note in material.notes where !live || note.beat * plan.secondsPerBeat < 1.1 {
            events.append((note.beat * plan.secondsPerBeat, .noteOn(channel: 0, note: note.pitch, velocity: 84)))
            events.append(
                ((note.beat + note.duration) * plan.secondsPerBeat - 0.03, .noteOff(channel: 0, note: note.pitch)))
        }
        var keys = MIDIKeyboardState()
        for (time, message) in events.sorted(by: { $0.0 < $1.0 }) {
            keys.receive(message)
            session.timing.receive(.init(message: message, keyboard: keys, timestamp: origin + time))
        }
        session.timing.tick()
        if !live && save { state.saveRehearsalPass() }
    }
    static func preview(state: AppState) throws {
        let doc = try document()
        let piece = LibraryPiece(source: .score(doc))
        state.editor.documents.append(doc)
        state.midi.installPreview()
        state.openPieceRehearsal(piece)
        try state.beginRehearsal(
            piece, scope: .init(partID: "P1", staff: nil, from: 4, through: 7), tempo: 80,
            now: Date().addingTimeInterval(-30))
        var checks = [
            "fullScore": try RehearsalSource.whole(piece).selectedMeasures.count == 12,
            "twoStaffOpening": state.currentRehearsal?.opening.handStaves == [1, 2],
        ]
        if CommandLine.arguments.contains("--hands-setup") {
            state.rehearsalKey = nil
            checks["setupReady"] = true
            checks["validState"] = (try? state.practiceState.validated()) != nil
            HandsTogetherDiagnostics.checks = checks
            return
        }
        try capture(state: state)
        checks["openingSaved"] = state.rehearsalSession.timing.saved && state.pianoTakes.takes.count == 1
        try capture(state: state, exercise: .rightHand)
        checks["rightPartnerSaved"] = state.currentRehearsal?.focusResults.last?.pass.conditions.partnerStaff == 2
        if CommandLine.arguments.contains("--hands-left") || CommandLine.arguments.contains("--hands-together")
            || CommandLine.arguments.contains("--hands-takes") || CommandLine.arguments.contains("--hands-context")
        {
            try capture(state: state, exercise: .leftHand, partner: !CommandLine.arguments.contains("--hands-solo"))
            checks["leftSaved"] = state.currentRehearsal?.focusResults.last?.pass.plan.source?.scope.staff == 2
        }
        if CommandLine.arguments.contains("--hands-together") || CommandLine.arguments.contains("--hands-takes")
            || CommandLine.arguments.contains("--hands-context")
        {
            try capture(state: state)
            checks["togetherSaved"] =
                state.currentRehearsal?.focusResults.last?.pass.plan.handStaves == [1, 2]
                && state.currentRehearsal?.focusResults.last?.pass.conditions.partnerStaff == nil
        }
        if CommandLine.arguments.contains("--hands-context"), let record = state.currentRehearsal {
            try state.updateRehearsal(record.key) { try $0.returnToPhrase() }
            state.rehearsalSession.timing.discard()
            checks["bothReturn"] =
                state.currentRehearsal?.activePlan.handStaves == [1, 2]
                && state.currentRehearsal?.activePlan.source?.scope == record.opening.source?.scope
        }
        if CommandLine.arguments.contains("--hands-live") {
            try capture(state: state, exercise: .rightHand, live: true)
            checks["liveUngraded"] = state.rehearsalSession.timing.result == nil
        }
        if CommandLine.arguments.contains("--hands-takes") { state.rehearsalSession.shaping = true }
        checks["validState"] = (try? state.practiceState.validated()) != nil
        checks["supportDistinct"] = state.journal.attempts.allSatisfy(\.assisted)
        HandsTogetherDiagnostics.checks = checks
    }
}
