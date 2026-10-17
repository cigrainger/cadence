// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

extension AppState {
    var currentRehearsal: PieceRehearsal? { rehearsalKey.flatMap { rehearsals.records[$0] } }
    func rehearsalCurrent(_ record: PieceRehearsal) -> Bool {
        guard record.valid, let piece = libraryPieces.first(where: { $0.id == record.pieceID }) else { return false }
        return
            ([record.opening, record.focus, record.context, record.flow?.plan].compactMap { $0 }
            + record.focusResults.compactMap(\.flowSource)).allSatisfy { RehearsalSource.current($0, in: piece) }
    }
    func openPieceRehearsal(_ piece: LibraryPiece, key: String? = nil) {
        do {
            guard !rehearsalSession.timing.hasUnsavedResult || rehearsalSession.sourcePlan?.source?.pieceID == piece.id
            else { throw MusicError.invalid("Save or discard the pending piece-practice pass first.") }
            _ = try RehearsalSource.whole(piece)
            audio.stop()
            microphone.stop()
            scoreEarInput.pause()
            earInput.pause()
            playAlongSession.timing.cancel()
            rehearsalSession.stop()
            rehearsalPieceID = piece.id
            rehearsalKey =
                rehearsalSession.timing.hasUnsavedResult
                ? rehearsalSession.key
                : key
                    ?? rehearsals.records.values.filter { $0.pieceID == piece.id && rehearsalCurrent($0) }.sorted {
                        $0.lastExposure > $1.lastExposure
                    }.first?.key
            // A resumed independent return must not carry old corrective marks.
            // Persisted summaries remain in the record; only transient display
            // feedback is cleared. A failed save must always remain recoverable.
            if !rehearsalSession.timing.hasUnsavedResult { rehearsalSession.timing.discard() }
            if currentRehearsal?.stage == .review { rehearsalSession.shaping = false }
            if !rehearsalTakes.contains(where: { $0.id == rehearsalSession.selectedTakeID }) {
                rehearsalSession.selectedTakeID = rehearsalTakes.first?.id
                rehearsalSession.comparisonTakeID = nil
            }
            practicePage = .rehearsal
            destination = .practice
        } catch { message = error.localizedDescription }
    }
    func beginRehearsal(_ piece: LibraryPiece, scope: PassageScope, tempo: Int, now: Date = Date()) throws {
        guard !rehearsalSession.timing.busy, !rehearsalSession.timing.hasUnsavedResult else {
            throw MusicError.invalid("Finish or save the current pass first.")
        }
        let plan = try RehearsalSource.plan(piece, scope: scope, tempo: tempo)
        let record = try PieceRehearsal(opening: plan, now: now)
        if rehearsals.records[record.key] == nil {
            guard rehearsals.records.count < 64 else {
                throw MusicError.invalid(
                    "Cadence currently keeps up to 64 saved phrases. Your existing sessions have been preserved.")
            }
            var copy = practiceState
            var book = rehearsals
            book.records[record.key] = record
            copy.rehearsal = book
            try commitPractice(copy)
        }
        rehearsalSession.timing.discard()
        rehearsalPieceID = piece.id
        rehearsalKey = record.key
        rehearsalSession.shaping = false
        rehearsalSession.selectedTakeID = rehearsalTakes.first?.id
        rehearsalSession.comparisonTakeID = nil
    }
    func updateRehearsal(_ key: String, _ change: (inout PieceRehearsal) throws -> Void) throws {
        guard var record = rehearsals.records[key], rehearsalCurrent(record) else {
            throw MusicError.invalid(
                "The source changed or needs review. Open the current piece and choose a reviewed phrase.")
        }
        try change(&record)
        var copy = practiceState
        var book = rehearsals
        book.records[key] = record
        copy.rehearsal = book
        try commitPractice(copy)
    }
    func configureRehearsalFlow(_ settings: FlowSettings?) throws {
        guard let record = currentRehearsal, !rehearsalSession.timing.busy, !rehearsalSession.timing.hasUnsavedResult,
            !rehearsalSession.takePlayer.busy, !audio.isPlaying, !audio.isPreparing,
            let piece = libraryPieces.first(where: { $0.id == record.pieceID }),
            settings.map({ RehearsalSource.current($0.plan, in: piece) }) ?? true
        else {
            throw MusicError.invalid("Finish, stop or save this pass before changing Make it flow.")
        }
        try updateRehearsal(record.key) { try $0.configureFlow(settings) }
        rehearsalSession.timing.discard()
    }
    func enableRehearsalFlow() throws {
        guard let record = currentRehearsal, let piece = libraryPieces.first(where: { $0.id == record.pieceID }) else {
            return
        }
        guard FlowPractice.contains(record.opening, in: record.opening) else {
            throw MusicError.invalid(
                "Make it flow needs complete bars. Choose a phrase after the pickup or use the existing focused exercises."
            )
        }
        let plan = try FlowPractice.joins(piece: piece, record: record).first?.plan ?? record.opening
        var settings = FlowSettings(plan: plan, tempo: max(40, record.opening.tempo - 15))
        if !settings.valid(in: record.opening) { settings.tempo = record.opening.tempo }
        try configureRehearsalFlow(settings)
    }
    func startRehearsal(
        exercise: RehearsalExercise, tempo: Int, input: TimedInput, loops: Int = 1, playPartner: Bool = true
    ) throws {
        guard let record = currentRehearsal, rehearsalCurrent(record) else {
            throw MusicError.invalid("Choose a reviewed opening phrase first.")
        }
        guard !rehearsalSession.takePlayer.busy, !rehearsalSession.timing.busy else {
            throw MusicError.invalid("Stop the take playback before recording a pass.")
        }
        let flow = record.stage == .focus ? record.flow : nil
        let tempo = flow?.tempo ?? tempo
        let playPartner = flow?.partner ?? playPartner
        let sourcePlan =
            record.stage == .focus
            ? try PieceRehearsal.exercisePlan(record.activePlan, exercise: exercise, tempo: tempo) : record.activePlan
        guard let piece = libraryPieces.first(where: { $0.id == record.pieceID }) else {
            throw MusicError.invalid("This piece is no longer in the library.")
        }
        let material: PianoPhrase?
        if !sourcePlan.rhythmOnly {
            let whole = try RehearsalSource.whole(piece, partID: sourcePlan.source?.scope.partID)
            material =
                PianoPhrase.isPiano(piece, part: whole.part) ? try PianoPhrase(piece: piece, plan: sourcePlan) : nil
        } else {
            material = nil
        }
        let partnerStaff =
            record.stage == .focus && playPartner ? PianoHands.partner(in: record.activePlan, exercise: exercise) : nil
        let partner = try partnerStaff.map { try PianoHands.accompaniment(piece, solo: sourcePlan, partnerStaff: $0) }
        if material != nil {
            guard midi.keyboard.pedals.isEmpty else {
                throw MusicError.invalid(
                    "Release the sustain pedal before the count-in so this take starts with a clear piano.")
            }
            guard pianoTakes.takes.count < PianoTakeBook.limit else {
                throw MusicError.invalid(
                    "Your 256 piano takes are saved. Delete an older take in Shape the phrase before recording another."
                )
            }
        }
        let plan = try rehearsalSession.prepare(
            record, exercise: exercise, tempo: tempo, input: input, held: midi.keyboard.downNotes,
            pianoPhrase: material, playPartner: playPartner)
        if record.stage == .focus && exercise == .connected {
            try updateRehearsal(record.key) { $0.phraseIntention = .connectedMelody }
        }
        if record.stage == .review { try updateRehearsal(record.key) { try $0.startReviewPass() } }
        audio.stop()
        microphone.stop()
        timedSession.cancel()
        playAlongSession.timing.cancel()
        rehearsalSession.loopsRemaining = record.stage == .focus ? max(0, min(2, loops - 1)) : 0
        let conditions = rehearsalSession.timing.conditions
        let render: (@Sendable () throws -> [Float])? =
            (partner != nil || conditions.flowPulse != nil)
            ? {
                @Sendable in
                try HandPracticeAudio.render(
                    plan, click: conditions.click, partner: partner, flowPulse: conditions.flowPulse)
            } : nil
        rehearsalSession.timing.start(
            plan, conditions: conditions, held: midi.keyboard.downNotes, recordPiano: material != nil, render: render)
    }
    func saveRehearsalPass() {
        let session = rehearsalSession
        session.timing.save { pass in
            guard let key = session.key, var record = rehearsals.records[key], record.id == session.recordID,
                rehearsalCurrent(record), let piece = libraryPieces.first(where: { $0.id == record.pieceID })
            else {
                throw MusicError.invalid(
                    "The source changed. This pass is kept here but cannot be applied to different notes.")
            }
            if journal.attempts.contains(where: { $0.id == pass.id }) { return }
            guard record.stage == session.stage else {
                throw MusicError.invalid("This session has moved to another step. The pending pass has been kept.")
            }
            let now = Date()
            switch record.stage {
            case .opening:
                try record.recordOpening(
                    pass, focus: RehearsalSource.focus(piece, opening: pass),
                    context: RehearsalSource.context(piece, opening: record.opening), now: now)
            case .focus:
                try record.recordFocus(pass, exercise: session.exercise, flowSource: session.flowSource, now: now)
            case .context: try record.recordContext(pass, now: now)
            case .review: try record.recordReview(pass, now: now)
            case .complete: throw MusicError.invalid("This session is already complete.")
            }
            var copy = practiceState
            var book = rehearsals
            book.records[key] = record
            copy.rehearsal = book
            let independent = session.stage == .review && record.reviews.last?.independent == true
            let report = pass.report
            var attempt = PracticeAttempt(
                sessionID: record.id, activityID: record.key,
                title: record.title + " · " + (session.stage?.title ?? "Practice"),
                skills: session.exercise == .rhythm ? ["Rhythm in a piece"] : ["Score reading", "Pitch", "Timing"],
                input: pass.conditions.input.journalInput,
                outcome: report.clean ? .correct : .incorrect, assisted: !independent,
                selectedChoice:
                    "\(session.stage?.rawValue ?? "practice") · \(pass.plan.source?.scope.staff.map { "staff \($0)" } ?? "both staves") · partner \(pass.conditions.partnerStaff.map { "staff \($0)" } ?? "off") · click \(pass.conditions.flowPulse?.rawValue ?? (pass.conditions.click ? "every beat" : "off")) · \(report.matchedPitch)/\(report.notes.count) pitches · \(report.timedEntrances(tolerance:pass.plan.tolerance))/\(report.notes.count) entrances on time · \(report.extras.count) extras",
                tempo: Double(pass.plan.tempo), date: pass.date)
            attempt.id = pass.id
            attempt.pieceID = record.pieceID
            attempt.scoreFingerprint = record.fingerprint
            attempt.passageScope = pass.plan.source?.scope ?? session.sourcePlan?.source?.scope
            guard attempt.valid else { throw MusicError.invalid("This practice summary could not be saved.") }
            copy.journal.append(attempt)
            if let phrase = session.pianoPhrase {
                guard let recording = session.timing.pianoRecording else {
                    throw MusicError.invalid("The piano recording is missing. This pass has been kept here.")
                }
                let take = PianoTake(
                    rehearsalKey: record.key, phase: session.stage ?? .opening, intention: record.phraseIntention,
                    phrase: phrase, pass: pass, recording: recording)
                var takes = pianoTakes
                try takes.append(take)
                copy.pianoTakes = takes
            }
            try commitPractice(copy)
            if session.pianoPhrase != nil {
                session.selectedTakeID = pass.id
                if session.exercise == .connected { session.shaping = true }
            }
        }
    }
    func rehearsalEvidence(_ piece: LibraryPiece) -> String {
        rehearsals.records.values.filter { $0.pieceID == piece.id && rehearsalCurrent($0) }.sorted {
            $0.lastExposure > $1.lastExposure
        }.prefix(3).map { record in
            let scope = record.opening.source!.scope
            let summary =
                record.reviews.last.map { result in
                    let report = result.pass.report
                    return
                        "Last return: \(result.independent ? "independent first pass" : "supported/restarted"); \(report.matchedPitch)/\(report.notes.count) pitches and \(report.timedEntrances(tolerance:result.pass.plan.tolerance))/\(report.notes.count) entrances on time at \(result.pass.plan.tempo) bpm."
                } ?? "No independent return yet. Opening and focused practice are supported evidence."
            return
                "Practise this piece · bars \(scope.from+1)–\(scope.through+1), \(scope.staff.map { "staff \($0)" } ?? "both hands"). Stage: \(record.stage.rawValue). "
                + summary
                + " Musical intention: \(record.phraseIntention?.rawValue ?? "none chosen"). Make it flow reflection: \(record.flowReflection?.rawValue ?? "none"). Piano take reflections are learner observations, not expression grades. Do not infer physical technique or mastery from MIDI entrances."
        }.joined(separator: "\n")
    }
    var rehearsalReviews: [PieceRehearsal] {
        rehearsals.records.values.filter { $0.stage == .complete && rehearsalCurrent($0) }.sorted {
            $0.lastExposure < $1.lastExposure
        }
    }
    func listenToRehearsal(loop: Bool, tempo: Int) throws {
        guard let record = currentRehearsal, rehearsalCurrent(record), !rehearsalSession.timing.busy,
            !rehearsalSession.timing.hasUnsavedResult, !rehearsalSession.takePlayer.busy,
            let piece = libraryPieces.first(where: { $0.id == record.pieceID }), let source = record.activePlan.source
        else { throw MusicError.invalid("Finish or save the current pass before listening.") }
        var study = try RehearsalSource.whole(piece, partID: source.scope.partID)
        study.from = source.scope.from
        study.through = source.scope.through
        study.staff = source.scope.staff
        study.document.tempo = Double(tempo)
        study.speed = 1
        study.countIn = true
        let plan = try StudyPlaybackPlan(study: study)
        try updateRehearsal(record.key) { try $0.expose() }
        audio.playStudy(plan, loop: loop)
    }
}
