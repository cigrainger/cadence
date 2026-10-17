// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

@MainActor enum ShapePhraseDiagnostics { static var checks: [String: Bool] = [:] }
@MainActor enum ShapePhraseChecks {
    /// Deterministic virtual performance uses the real MIDI receiver and commit
    /// path, including physical releases and a pedal across multiple pitches.
    static func capture(
        state: AppState, gap: Double = 0.1, pedal: Bool = false, connected: Bool = false, save: Bool = true
    ) throws {
        guard let record = state.currentRehearsal,
            let piece = state.libraryPieces.first(where: { $0.id == record.pieceID })
        else { throw MusicError.invalid("No piano phrase.") }
        let session = state.rehearsalSession
        let exercise: RehearsalExercise = connected ? .connected : .notes
        let source =
            record.stage == .focus
            ? try PieceRehearsal.exercisePlan(record.activePlan, exercise: exercise, tempo: 65) : record.activePlan
        let phrase = try PianoPhrase(piece: piece, plan: source)
        let plan = try session.prepare(
            record, exercise: exercise, tempo: 65, input: .midi, held: [], pianoPhrase: phrase)
        if connected { try state.updateRehearsal(record.key) { $0.phraseIntention = .connectedMelody } }
        let origin = PracticeClock.now() - plan.duration - 1
        session.timing.begin(at: origin)
        var events: [(Double, MIDIMessage)] = []
        if pedal { events.append((-0.1, .control(channel: 0, number: 64, value: 127))) }
        for (i, note) in phrase.notes.enumerated() {
            events.append(
                (note.beat * plan.secondsPerBeat, .noteOn(channel: 0, note: note.pitch, velocity: 70 + i % 6 * 7)))
            events.append(
                ((note.beat + note.duration) * plan.secondsPerBeat - gap, .noteOff(channel: 0, note: note.pitch)))
        }
        if pedal { events.append((plan.duration + 0.1, .control(channel: 0, number: 64, value: 0))) }
        var keys = MIDIKeyboardState()
        for (time, message) in events.sorted(by: { $0.0 < $1.0 }) {
            keys.receive(message)
            session.timing.receive(.init(message: message, keyboard: keys, timestamp: origin + time))
        }
        session.timing.tick()
        if save { state.saveRehearsalPass() }
    }
    static func preview(state: AppState) throws {
        let doc = try PieceRehearsalChecks.document()
        let piece = LibraryPiece(source: .score(doc))
        state.editor.documents.append(doc)
        state.midi.installPreview()
        state.openPieceRehearsal(piece)
        try state.beginRehearsal(
            piece, scope: .init(partID: "P1", staff: 1, from: 4, through: 7), tempo: 80,
            now: Date().addingTimeInterval(-30))
        var checks = ["fullScore": try RehearsalSource.whole(piece).selectedMeasures.count == 12]
        if !CommandLine.arguments.contains("--shape-empty") {
            try capture(state: state)
            try capture(state: state, gap: 0.12, pedal: true, connected: true)
            try capture(state: state, gap: -0.025, connected: true)
            let takes = state.rehearsalTakes
            let a = takes[0]
            let b = takes[1]
            checks["takesSaved"] = takes.count == 3 && state.journal.attempts.count == 3
            checks["comparable"] = a.comparable(to: b)
            checks["pedalDistinct"] =
                b.joins.contains(where: \.pedalBridged) && a.joins.allSatisfy { $0.gap < 0 && !$0.pedalBridged }
            state.rehearsalSession.selectedTakeID = a.id
            state.rehearsalSession.comparisonTakeID = b.id
            if CommandLine.arguments.contains("--shape-observations") {
                let player = state.rehearsalSession.takePlayer
                player.begin(a, at: PracticeClock.now() - a.recording.duration - 1)
                player.tick()
                try state.finishPianoTakeListening(a.id)
                try state.reflectOnPianoTake(
                    a.id, reflection: .connected, note: "The second note felt like part of the same thought.")
                checks["reflectionSaved"] = state.rehearsalTakes.first?.reflection == .connected
            }
            if CommandLine.arguments.contains("--shape-playing") {
                let player = state.rehearsalSession.takePlayer
                player.begin(a, at: PracticeClock.now() - 1.3)
                player.tick()
                checks["performanceCursor"] = player.playhead?.sourceBeat ?? 0 >= 16
            }
            if CommandLine.arguments.contains("--shape-stale") {
                let index = state.editor.documents.firstIndex { $0.id == doc.id }!
                state.editor.documents[index].events[0].pitches = [EditorPitch(89)]
                do {
                    try state.playPianoTake(a.id)
                    checks["staleBlocked"] = false
                } catch {
                    checks["staleBlocked"] = !state.rehearsalSession.takePlayer.busy
                }
            }
        } else {
            checks["emptyHonest"] = state.pianoTakes.takes.isEmpty
        }
        state.rehearsalSession.shaping = true
        checks["validState"] = (try? state.practiceState.validated()) != nil
        ShapePhraseDiagnostics.checks = checks
    }
}
