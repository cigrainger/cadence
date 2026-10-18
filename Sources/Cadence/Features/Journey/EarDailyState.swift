// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

extension AppState {
    var earDailyPractice: EarDailyPractice { practiceState.earDaily ?? .init() }
    var earDailySession: EarDailySession? { earDailyPractice.active }

    func validateEarDaily(_ session: EarDailySession) throws {
        guard session.valid,
            let journey = songJourneys.first(where: { $0.id == session.journeyID }),
            journey.instrument == session.instrument,
            session.material == (session.mode == .transfer ? journey.transfer : journey.material)
        else { throw MusicError.invalid("This daily session no longer matches its pathway.") }
        try validateSongJourney(journey)
    }

    /// Activity schedules retain their own intervals. This additional gate keeps
    /// an early retry, a demonstration or an overlapping passage out of recall.
    func earDailyReturnDate(_ material: ScoreEarMaterial, instrument: EditorInstrument, includeSchedule: Bool = true)
        -> Date?
    {
        var dates = [earDailyPractice.returnDate(material: material), scoreEarPractice.returnDate(material.id)]
            .compactMap { $0 }
        if let microphone = microphonePhrases.returnDate(material.id) { dates.append(microphone) }
        let activity = material.id + ":daily-ear:" + instrument.rawValue
        if includeSchedule, let due = history.cards[activity]?.review.due { dates.append(due) }
        let related = journal.attempts.filter {
            $0.pieceID == material.pieceID
                && ($0.input != .selfReport || $0.activityID.hasSuffix(":daily-ear-exposure")
                    || $0.activityID.hasSuffix(":daily-ear-completed"))
                && ($0.passageScope.map {
                    $0.partID == material.scope.partID && ($0.staff == nil || $0.staff == material.staff)
                        && $0.from < material.scope.throughBar && $0.through >= material.scope.fromBar - 1
                } ?? true)
        }.map(\.date).max()
        if let related { dates.append(related.addingTimeInterval(86400)) }
        return dates.max()
    }

    func earDailyTransferDate(_ journey: SongJourney) -> Date? {
        [
            earDailyReturnDate(journey.material, instrument: journey.instrument, includeSchedule: false),
            earDailyReturnDate(journey.transfer, instrument: journey.instrument),
        ].compactMap { $0 }.max()
    }

    func earDailyRecommendation(_ journey: SongJourney, now: Date = Date()) -> EarDailyRecommendation {
        let activity = journey.material.id + ":daily-ear:" + journey.instrument.rawValue
        let latest = journal.attempts.filter {
            $0.pathwayID == journey.id && $0.activityID == activity && $0.outcome != .skipped
        }.max { $0.date < $1.date }
        return .choose(
            completed: hasCompletedEarDaily(journey),
            independentFamiliar: latest.map { $0.outcome == .correct && !$0.assisted } == true,
            familiarDue: earDailyReturnDate(journey.material, instrument: journey.instrument),
            transferDue: earDailyTransferDate(journey), now: now)
    }

    func openEarDaily(_ journey: SongJourney, mode: EarDailyMode = .learning, now: Date = Date()) throws {
        try validateSongJourney(journey)
        guard earDailyInput.pending == nil, !microphonePhraseSession.hasUnsavedTake else {
            throw MusicError.invalid("Keep or discard the waiting take before starting another daily session.")
        }
        stopAllPlayback()
        try flushMicrophoneExposure()
        var book = earDailyPractice
        if let active = book.active, active.stage != .complete, (try? validateEarDaily(active)) != nil {
            guard active.journeyID == journey.id, active.mode == mode else {
                throw MusicError.invalid("Finish the current daily session or return to it before starting another.")
            }
            try validateEarDaily(active)
            if active.mode != .learning {
                var resumed = active
                try resumed.noteExposure(now: max(now, resumed.lastExposure))
                try book.replace(resumed)
                var snapshot = practiceState
                snapshot.earDaily = book
                try commitPractice(snapshot)
            }
        } else {
            let material = mode == .transfer ? journey.transfer : journey.material
            var ready: Date?
            if mode != .learning {
                // Transfer follows a completed familiar encounter, and stays
                // distinct from rehearsing that same phrase again.
                guard hasCompletedEarDaily(journey) else {
                    throw MusicError.invalid("Finish a familiar daily session before its independent return.")
                }
                ready =
                    mode == .transfer
                    ? earDailyTransferDate(journey)
                    : earDailyReturnDate(journey.material, instrument: journey.instrument)
                guard let ready, now >= ready else {
                    throw MusicError.invalid(
                        "Leave time away before an independent return. Guided practice stays open.")
                }
            }
            var session = try EarDailySession(
                journeyID: journey.id, material: material, instrument: journey.instrument, mode: mode,
                reviewReadyAt: ready, now: now)
            if contextCoach.presented { try session.noteExposure(now: now) }
            if session.instrument == .guitar { _ = try earDailyMicrophonePlan(session) }
            try book.open(session)
            var snapshot = practiceState
            snapshot.earDaily = book
            try commitPractice(snapshot)
        }
        songJourneyID = journey.id
        songLesson = mode == .transfer ? .independent : .hear
        practicePage = .earDaily
        destination = .practice
    }

    func resumeEarDaily(_ id: UUID) throws {
        guard let session = earDailyPractice.sessions.first(where: { $0.id == id }),
            earDailyInput.pending == nil || earDailyInput.pending?.session.id == id,
            !microphonePhraseSession.hasUnsavedTake || earDailyPractice.selectedID == id
        else { throw MusicError.invalid("Save the waiting take before changing daily sessions.") }
        let ownsPending = earDailyInput.pending?.session.id == id || microphonePhraseSession.dailyOwnerID == id
        if !ownsPending { try validateEarDaily(session) }
        stopAllPlayback()
        var book = earDailyPractice
        book.selectedID = id
        if contextCoach.presented || session.mode != .learning, !ownsPending, session.stage != .complete {
            var supported = session
            try supported.noteExposure(now: max(Date(), session.lastExposure))
            try book.replace(supported)
        }
        var snapshot = practiceState
        snapshot.earDaily = book
        try commitPractice(snapshot)
        songJourneyID = session.journeyID
        songLesson = session.mode == .transfer ? .independent : .hear
        practicePage = .earDaily
        destination = .practice
    }

    func updateEarDaily(_ id: UUID, _ change: (inout EarDailySession) throws -> Void) throws {
        guard var session = earDailyPractice.active, session.id == id,
            earDailyInput.pending == nil, !microphonePhraseSession.hasUnsavedTake
        else { throw MusicError.invalid("Save or discard the waiting take before changing this session.") }
        try validateEarDaily(session)
        try change(&session)
        var book = earDailyPractice
        try book.replace(session)
        var snapshot = practiceState
        snapshot.earDaily = book
        try commitPractice(snapshot)
    }

    func hearEarDaily(_ id: UUID, now: Date = Date(), play: ((Score) -> Void)? = nil) throws {
        stopAllPlayback()
        try updateEarDaily(id) { try $0.heard(now: now) }
        guard let session = earDailySession else { return }
        let phrase = EarPhrase(material: session.material)
        if let play {
            play(phrase.score)
        } else if !(isPreview && CommandLine.arguments.contains("--daily-ax")) {
            audio.play(phrase.score)
        }
    }

    func earDailyMicrophonePlan(_ session: EarDailySession) throws -> MicrophonePhrasePlan {
        guard let piece = libraryPieces.first(where: { $0.id == session.material.pieceID }) else {
            throw MusicError.invalid("This source is no longer in your library.")
        }
        let tempo = session.invitationTempo
        var plan = try MicrophonePhrasePlan(material: session.material, tempo: tempo, source: piece)
        if let bar = session.focusBar {
            plan = try plan.focused(around: bar)
            guard plan.fromBar == bar, plan.throughBar == bar else {
                throw MusicError.invalid("A tie crosses this bar. Retry the whole phrase so it stays complete.")
            }
        }
        return plan
    }

    func startEarDailyMicrophone(_ id: UUID, now: Date = Date()) throws {
        guard let before = earDailySession, before.id == id, before.stage == .play,
            before.instrument == .guitar
        else { throw MusicError.invalid("Return to the guitar playing step first.") }
        stopAllPlayback()
        try flushMicrophoneExposure()
        try updateEarDaily(id) { try $0.beganAttempt(now: now) }
        guard let expected = earDailySession else { return }
        let plan = try earDailyMicrophonePlan(expected)
        var book = microphonePhrases
        try book.open(plan)
        var snapshot = practiceState
        snapshot.microphonePhrases = book
        try commitPractice(snapshot)
        try microphonePhraseSession.select(plan, dailyOwnerID: id)
        // Ear recall assesses pitch/order only. Calibration is required by the
        // separate timed workflow, never inferred from this count-in.
        microphonePhraseSession.start(
            plan, microphone: microphone, pitchOnly: true, dailyOwnerID: id,
            interrupted: { [weak self] date in
                try self?.recordEarDailyExposure(id, at: date)
            }
        ) { [weak self] in
            guard let self, self.earDailySession == expected, self.practicePage == .earDaily,
                self.destination == .practice
            else { throw MusicError.invalid("This daily session moved or changed.") }
            try self.validateEarDaily(expected)
        }
    }

    func saveEarDailyAttempt(_ attempt: PracticeAttempt, expected: EarDailySession) throws {
        if journal.attempts.contains(where: { $0.id == attempt.id && $0 == attempt }),
            earDailyPractice.sessions.contains(where: { $0.id == expected.id && $0.attemptIDs.contains(attempt.id) })
        {
            return
        }
        guard earDailySession == expected, attempt.valid, attempt.sessionID == expected.id,
            attempt.activityID == expected.activityID, attempt.pathwayID == expected.journeyID,
            attempt.pieceID == expected.material.pieceID, attempt.scoreFingerprint == expected.material.fingerprint
        else { throw MusicError.invalid("The captured answer no longer matches this daily session.") }
        guard attempt == (try expected.midiAttempt(notes: attempt.played, now: attempt.date, id: attempt.id)) else {
            throw MusicError.invalid("This saved answer does not match the captured MIDI notes.")
        }
        try validateEarDaily(expected)
        var session = expected
        try session.record(attemptID: attempt.id, now: attempt.date)
        var book = earDailyPractice
        try book.replace(session)
        var snapshot = practiceState
        snapshot.earDaily = book
        snapshot.journal.append(attempt)
        try snapshot.history.recordDailyEar(attempt)
        try commitPractice(snapshot)
    }

    func saveEarDailyMicrophone(_ take: MicrophonePhraseTake) throws -> MicrophonePhraseTake {
        if let session = earDailySession, session.attemptIDs.contains(take.id),
            microphonePhrases.sessions.flatMap(\.takes).contains(take)
        {
            return take
        }
        guard let expected = earDailySession, expected.stage == .play else {
            throw MusicError.invalid("Return to the daily session before keeping this take.")
        }
        guard microphonePhraseSession.dailyOwnerID == nil || microphonePhraseSession.dailyOwnerID == expected.id else {
            throw MusicError.invalid("This microphone take belongs to another daily session.")
        }
        try validateEarDaily(expected)
        let attempt = try expected.microphoneAttempt(take)
        var microphoneBook = microphonePhrases
        _ = try microphoneBook.record(take)
        var session = expected
        // An inconclusive take remains inspectable but contributes no grade.
        // The reference still allows a retry or an explicitly skipped check.
        try session.record(attemptID: take.id, now: take.date)
        var book = earDailyPractice
        try book.replace(session)
        var snapshot = practiceState
        snapshot.microphonePhrases = microphoneBook
        snapshot.earDaily = book
        if let attempt {
            snapshot.journal.append(attempt)
            try snapshot.history.recordDailyEar(attempt)
        }
        try commitPractice(snapshot)
        return take
    }

    func discardEarDailyMicrophone() throws {
        guard let take = microphonePhraseSession.pending, var session = earDailySession else { return }
        try session.noteExposure(now: max(Date(), take.date))
        var daily = earDailyPractice
        try daily.replace(session)
        var microphoneBook = microphonePhrases
        try microphoneBook.notePractice(materialID: take.plan.key, now: max(Date(), take.date))
        var snapshot = practiceState
        snapshot.earDaily = daily
        snapshot.microphonePhrases = microphoneBook
        try commitPractice(snapshot)
        microphonePhraseSession.discard()
    }

    @discardableResult func openEarDailyAnswer(_ id: UUID, now: Date = Date()) throws -> UUID {
        guard let session = earDailySession, session.id == id, [.review, .create, .complete].contains(session.stage)
        else { throw MusicError.invalid("Keep a take or skip the playing check before writing your answer.") }
        try validateEarDaily(session)
        guard earDailyInput.pending == nil, !microphonePhraseSession.hasUnsavedTake else {
            throw MusicError.invalid("Save or discard the waiting take before writing an answer.")
        }
        try noteEarDailySourceExposure(session.material.pieceID, now: now)
        if !editor.documents.contains(where: { $0.id == session.answerID }) {
            guard let piece = libraryPieces.first(where: { $0.id == session.material.pieceID }) else {
                throw MusicError.invalid("The source piece is unavailable.")
            }
            var answer = try CreativeResponse(material: session.material, sessionID: session.id, now: now)
                .makeDocument(piece: piece)
            answer.id = session.answerID
            try libraryWorkspace.addComposition(answer)
        }
        if session.stage == .review { try updateEarDaily(id) { try $0.beginAnswer(now: now) } }
        stopAllPlayback()
        returnToCompose(session.answerID)
        return session.answerID
    }

    func finishEarDaily(_ id: UUID, now: Date = Date()) throws {
        guard let session = earDailySession, session.id == id,
            let answer = editor.documents.first(where: { $0.id == session.answerID }),
            answer.responseSource?.sessionID == session.id, answer.responseSource?.isFinished(answer) == true
        else {
            throw MusicError.invalid("Add notes, listen and save your musical answer before finishing the session.")
        }
        try updateEarDaily(id) { try $0.finish(now: now) }
    }

    func finishEarDailyReview(_ id: UUID, now: Date = Date()) throws {
        try updateEarDaily(id) { try $0.finishReview(now: now) }
    }

    var earDailyLatestAttempt: PracticeAttempt? {
        guard let session = earDailySession, let id = session.attemptIDs.last else { return nil }
        return journal.attempts.first {
            $0.id == id && $0.sessionID == session.id && $0.activityID == session.activityID
                && [.correct, .incorrect].contains($0.outcome)
        }
    }

    func earDailyFocusBar(_ session: EarDailySession) -> Int? {
        guard let attempt = earDailyLatestAttempt, attempt.outcome == .incorrect else { return nil }
        let expected = session.material.melody
        guard
            let index = zip(attempt.played, attempt.target).enumerated().first(where: { $0.element.0 != $0.element.1 })?
                .offset,
            expected.indices.contains(index)
        else { return nil }
        let beats =
            session.material.beats / Double(session.material.scope.throughBar - session.material.scope.fromBar + 1)
        return session.material.scope.fromBar + Int(expected[index].start / beats)
    }

    func noteEarDailySourceExposure(_ pieceID: String, now: Date = Date()) throws {
        let sessions = earDailyPractice.sessions.filter { $0.material.pieceID == pieceID }
        let sources = songJourneys.flatMap { journey in
            [journey.material, journey.transfer].filter { $0.pieceID == pieceID }.map { (journey.id, $0) }
        }
        guard !sessions.isEmpty || !sources.isEmpty else { return }
        guard earDailyInput.pending == nil, !microphonePhraseSession.hasUnsavedTake else {
            throw MusicError.invalid("Keep or discard your waiting take before opening its source.")
        }
        stopAllPlayback()
        var book = earDailyPractice
        for var session in sessions {
            try session.noteExposure(now: now)
            try book.replace(session)
        }
        var snapshot = practiceState
        snapshot.earDaily = book
        for (journeyID, material) in sources {
            var exposure = PracticeAttempt(
                sessionID: journeyID, activityID: material.id + ":daily-ear-exposure",
                title: material.title, skills: ["Source exposure"], input: .selfReport, outcome: .skipped,
                assisted: true, selectedChoice: "Source or coaching opened; no performance was measured.", date: now)
            exposure.pathwayID = journeyID
            exposure.pieceID = pieceID
            exposure.scoreFingerprint = material.fingerprint
            exposure.passageScope = .init(
                partID: material.scope.partID, staff: material.staff,
                from: material.scope.fromBar - 1, through: material.scope.throughBar - 1)
            snapshot.journal.append(exposure)
        }
        try commitPractice(snapshot)
    }

    /// An interruption belongs to the captured historical session even after
    /// its score changes. It can delay review but cannot grant current credit.
    func recordEarDailyExposure(_ id: UUID, at date: Date) throws {
        var book = earDailyPractice
        guard var session = book.sessions.first(where: { $0.id == id }) else {
            throw MusicError.invalid("The interrupted daily session is missing.")
        }
        try session.noteExposure(now: max(date, session.lastExposure))
        try book.replace(session)
        var snapshot = practiceState
        snapshot.earDaily = book
        try commitPractice(snapshot)
    }

    func hasCompletedEarDaily(_ journey: SongJourney) -> Bool {
        earDailyPractice.sessions.contains {
            $0.journeyID == journey.id && $0.material.id == journey.material.id && $0.stage == .complete
        }
            || journal.attempts.contains {
                $0.pathwayID == journey.id && $0.activityID == journey.material.id + ":daily-ear-completed"
            }
    }

}
