// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

@MainActor enum FlowPracticeDiagnostics { static var checks: [String: Bool] = [:] }
@MainActor enum FlowPracticeChecks {
    static func capture(
        state: AppState, exercise: RehearsalExercise = .notes, imperfect: Bool = false, live: Bool = false,
        save: Bool = true
    ) throws {
        guard let record = state.currentRehearsal,
            let piece = state.libraryPieces.first(where: { $0.id == record.pieceID })
        else { throw MusicError.invalid("No flow phrase.") }
        let session = state.rehearsalSession
        let focused = record.stage == .focus
        let tempo = focused ? record.flow?.tempo ?? 65 : record.activePlan.tempo
        let source =
            focused
            ? try PieceRehearsal.exercisePlan(record.activePlan, exercise: exercise, tempo: tempo) : record.activePlan
        let material = source.rhythmOnly ? nil : try PianoPhrase(piece: piece, plan: source)
        let plan = try session.prepare(
            record, exercise: exercise, tempo: tempo, input: .midi, held: [], pianoPhrase: material)
        let origin = PracticeClock.now() - (live ? 1.2 : plan.duration + 1)
        session.timing.begin(at: origin)
        var events: [(Double, MIDIMessage)] = []
        for (i, target) in plan.targets.enumerated() where !live || target.beat * plan.secondsPerBeat < 1.1 {
            let seconds = target.beat * plan.secondsPerBeat + (imperfect && target.bar == 6 ? 0.17 : 0)
            events.append((seconds, .noteOn(channel: 0, note: target.pitch, velocity: 82 + (i % 3) * 4)))
            let length = material?.notes.first { $0.pitch == target.pitch && $0.beat == target.beat }?.duration ?? 0.2
            events.append((seconds + length * plan.secondsPerBeat - 0.03, .noteOff(channel: 0, note: target.pitch)))
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
        let piece = LibraryPiece(source: .score(try HandsTogetherChecks.document()))
        if case .score(let doc) = piece.source { state.editor.documents.append(doc) }
        state.midi.installPreview()
        state.openPieceRehearsal(piece)
        try state.beginRehearsal(
            piece, scope: .init(partID: "P1", staff: nil, from: 4, through: 7), tempo: 80,
            now: Date().addingTimeInterval(-60))
        try capture(state: state, imperfect: true)
        try state.enableRehearsalFlow()
        var checks = [
            "fullScore": try RehearsalSource.whole(piece).selectedMeasures.count == 12,
            "observedJoin": state.currentRehearsal?.flow?.plan.source?.scope
                == PassageScope(partID: "P1", staff: nil, from: 5, through: 6),
        ]
        let args = CommandLine.arguments
        let hand: RehearsalExercise = args.contains("--flow-hand") ? .rightHand : .notes
        if args.contains("--flow-gaps") {
            var flow = state.currentRehearsal!.flow!
            flow.pulse = .gaps
            flow.tempo = 80
            flow.partner = false
            try state.configureRehearsalFlow(flow)
        }
        try capture(state: state, exercise: hand)
        try capture(state: state, exercise: hand)
        checks["twoPassesSaved"] = state.currentRehearsal?.focusResults.count == 2 && state.pianoTakes.takes.count == 3
        checks["suggestionAvailable"] = FlowPractice.advice(state.currentRehearsal!, exercise: hand).settings != nil
        checks["supportSaved"] =
            state.currentRehearsal?.focusResults.allSatisfy {
                $0.flowSource != nil && $0.pass.conditions.flowPulse != nil && $0.pass.grade == .supported
            } == true
        if args.contains("--flow-live") {
            try capture(state: state, live: true)
            checks["liveUngraded"] = state.rehearsalSession.timing.result == nil
        }
        if args.contains("--flow-context") || args.contains("--flow-complete") {
            try state.updateRehearsal(state.currentRehearsal!.key) { try $0.returnToPhrase() }
            state.rehearsalSession.timing.discard()
            checks["wholeReturn"] = state.currentRehearsal?.activePlan == state.currentRehearsal?.opening
            if args.contains("--flow-complete") {
                try capture(state: state)
                try state.updateRehearsal(state.currentRehearsal!.key) { $0.flowReflection = .easier }
                checks["reflectionSaved"] =
                    state.currentRehearsal?.flowReflection == .easier && state.currentRehearsal?.nextReview != nil
                checks["returnUnassistedAudio"] =
                    state.currentRehearsal?.contextResult?.conditions.flowPulse == nil
                    && state.currentRehearsal?.contextResult?.conditions.partnerStaff == nil
            }
        }
        checks["validState"] = (try? state.practiceState.validated()) != nil
        checks["noPracticeMastery"] = state.journal.attempts.allSatisfy(\.assisted)
        FlowPracticeDiagnostics.checks = checks
    }
}
