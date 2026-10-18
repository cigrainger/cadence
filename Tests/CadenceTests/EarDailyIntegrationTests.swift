// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

@testable import Cadence

final class EarDailyIntegrationTests: XCTestCase {
    @MainActor func testOriginalGuitarTransferFixtureCreatesAValidTabAnswerBeforeReturn() throws {
        let state = AppState(preview: true)
        defer {
            state.stopAllPlayback()
            state.midi.shutdown()
        }
        try EarDailyChecks.preview(state, arguments: ["--daily-guitar", "--daily-transfer"])
        XCTAssertEqual(state.earDailySession?.mode, .transfer)
        XCTAssertEqual(state.earDailySession?.stage, .hear)
        XCTAssertFalse(state.earDailySession!.assisted)
        XCTAssertTrue(EarDailyDiagnostics.checks.values.allSatisfy { $0 })
        XCTAssertNoThrow(try state.editor.validated())
    }

    @MainActor func testDailyStudioPreviewEnablesActualEditorAssertionsWithoutChangingNormalRendering() {
        XCTAssertTrue(EditorRenderer.Coordinator.verifiesPreview(arguments: ["--ear-daily-preview"]))
        XCTAssertFalse(EditorRenderer.Coordinator.verifiesPreview(arguments: ["--snapshot", "original.png"]))
    }

    @MainActor func testMainSessionRecommendationOffersRecallBeforeNewGuidedPractice() throws {
        let now = Date()
        let state = try fixture(now: now)
        _ = try complete(state, now: now)
        let journey = try XCTUnwrap(state.selectedSongJourney)
        let due = try XCTUnwrap(state.earDailyReturnDate(journey.material, instrument: .piano))
        XCTAssertEqual(state.earDailyRecommendation(journey, now: due.addingTimeInterval(-1)).mode, .learning)
        XCTAssertEqual(state.earDailyRecommendation(journey, now: due).mode, .recall)
        XCTAssertFalse(state.earDailyRecommendation(journey, now: due).reason.isEmpty)
    }

    @MainActor func testArchivingCompletedCoordinatorRetainsCanonicalProgressAnswerAndCutoff() throws {
        let now = Date()
        let state = try fixture(now: now)
        let completed = try complete(state, now: now)
        let journey = try XCTUnwrap(state.selectedSongJourney)
        try state.openEarDaily(journey, now: now.addingTimeInterval(10))
        let current = try XCTUnwrap(state.earDailySession?.id)
        let cutoff = state.earDailyReturnDate(journey.material, instrument: .piano)
        let history = state.history
        let checked = state.journal.checked
        try state.archiveEarDailyCompleted()
        XCTAssertEqual(state.earDailySession?.id, current)
        XCTAssertFalse(state.earDailyPractice.sessions.contains { $0.id == completed.id })
        XCTAssertEqual(state.history, history)
        XCTAssertEqual(state.journal.checked, checked)
        XCTAssertEqual(state.earDailyReturnDate(journey.material, instrument: .piano), cutoff)
        XCTAssertTrue(state.hasCompletedEarDaily(journey))
        XCTAssertTrue(state.editor.documents.contains { $0.id == completed.answerID })
        XCTAssertEqual(state.songEvidence(journey)[.hear]?.latest?.id, checked.last?.id)
    }

    @MainActor func testRetiringPitchDetailsIsAtomicAndRetainsSummaryJournalAndCutoff() throws {
        let now = Date()
        let state = try fixture(.guitar, now: now)
        let first = try playStep(state, now: now)
        let plan = try state.earDailyMicrophonePlan(first)
        var book = state.microphonePhrases
        try book.open(plan)
        var snapshot = state.practiceState
        snapshot.microphonePhrases = book
        try state.commitPractice(snapshot)
        for index in 0..<4 {
            let date = now.addingTimeInterval(Double(2 + 2 * index))
            var take = MicrophonePhraseChecks.take(plan, date: date, clean: true)
            take.calibration = nil
            if index == 0 { take.disputedTargets = [0] }
            _ = try state.saveEarDailyMicrophone(take)
            if index < 3 { try state.updateEarDaily(first.id) { try $0.retry(now: date.addingTimeInterval(1)) } }
        }
        let before = state.practiceState
        let cutoff = state.earDailyReturnDate(first.material, instrument: .guitar)
        let url = state.stores.practice.url
        let bytes = try Data(contentsOf: url)
        try Data("external conflict".utf8).write(to: url)
        XCTAssertThrowsError(try state.retireEarDailyDetails(first.id))
        XCTAssertEqual(state.practiceState, before)
        try bytes.write(to: url)
        XCTAssertEqual(try state.retireEarDailyDetails(first.id), 2)
        XCTAssertEqual(state.microphonePhrases.active?.takes.count, 2)
        XCTAssertEqual(state.journal.checked, before.journal.checked)
        XCTAssertEqual(state.journal.attempts.filter { $0.outcome == .skipped }.count, 1)
        XCTAssertEqual(state.earDailyReturnDate(first.material, instrument: .guitar), cutoff)
    }

    @MainActor func testToolbarCoachOnTransferChapterRecordsExposureBeforeFirstTransfer() throws {
        let now = Date().addingTimeInterval(-2 * 86400)
        let state = try fixture(now: now)
        _ = try complete(state, now: now)
        let journey = try XCTUnwrap(state.selectedSongJourney)
        state.openSongJourney(journey.id)
        state.songLesson = .independent
        state.openContextCoach()
        XCTAssertTrue(state.contextCoach.presented)
        state.contextCoach.presented = false
        XCTAssertThrowsError(try state.openEarDaily(journey, mode: .transfer, now: Date().addingTimeInterval(60)))
        XCTAssertTrue(state.contextCoach.lines.isEmpty)
    }

    @MainActor func testTransferFeedsMainMapAndCanFinishWithoutAnotherComposition() throws {
        let now = Date()
        let state = try fixture(now: now)
        _ = try complete(state, now: now)
        let journey = try XCTUnwrap(state.selectedSongJourney)
        let due = try XCTUnwrap(state.earDailyReturnDate(journey.material, instrument: .piano))
        let count = state.editor.documents.count
        try state.openEarDaily(journey, mode: .transfer, now: due)
        let id = try XCTUnwrap(state.earDailySession?.id)
        try state.hearEarDaily(id, now: due, play: { _ in })
        try state.updateEarDaily(id) { try $0.imagined(now: due.addingTimeInterval(1)) }
        let session = try XCTUnwrap(state.earDailySession)
        try state.saveEarDailyAttempt(
            session.midiAttempt(notes: session.expectedNotes, now: due.addingTimeInterval(2)), expected: session)
        XCTAssertTrue(state.songEvidence(journey)[.independent]!.independentSuccess)
        try state.finishEarDailyReview(id, now: due.addingTimeInterval(3))
        XCTAssertEqual(state.earDailySession?.stage, .complete)
        XCTAssertEqual(state.editor.documents.count, count)
    }

    @MainActor func testVersionSeventeenLoadsAndUpgradesWithoutInventedDailyProgress() throws {
        let state = try fixture()
        var legacy = state.practiceState
        legacy.schemaVersion = 17
        legacy.earDaily = nil
        try JSONEncoder().encode(legacy).write(to: state.stores.practice.url)
        let restored = AppState(storageOverride: state.storage)
        defer { restored.midi.shutdown() }
        XCTAssertEqual(restored.practiceState.schemaVersion, 18)
        XCTAssertTrue(restored.earDailyPractice.sessions.isEmpty)
        XCTAssertEqual(restored.journal, legacy.journal)
        XCTAssertEqual(restored.history, legacy.history)
        XCTAssertNil(restored.stores.practiceError)
        try restored.practiceWorkspace.save()
        let saved = try JSONDecoder().decode(PracticeState.self, from: Data(contentsOf: restored.stores.practice.url))
        XCTAssertEqual(saved.schemaVersion, 18)
    }

    @MainActor private func fixture(_ instrument: EditorInstrument = .piano, now: Date = Date()) throws -> AppState {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let state = AppState(storageOverride: folder)
        addTeardownBlock {
            await MainActor.run {
                state.stopAllPlayback()
                state.midi.shutdown()
            }
            try? FileManager.default.removeItem(at: folder)
        }
        try state.startSongJourney(instrument: instrument)
        try state.openEarDaily(XCTUnwrap(state.selectedSongJourney), now: now)
        return state
    }
    @MainActor private func playStep(_ state: AppState, now: Date) throws -> EarDailySession {
        let id = try XCTUnwrap(state.earDailySession?.id)
        try state.hearEarDaily(id, now: now, play: { _ in })
        try state.updateEarDaily(id) { try $0.imagined(now: now.addingTimeInterval(1)) }
        return try XCTUnwrap(state.earDailySession)
    }
    @MainActor private func send(_ notes: [Int], state: AppState) {
        var keyboard = MIDIKeyboardState()
        for note in notes {
            for message in [MIDIMessage.noteOn(channel: 0, note: note, velocity: 80), .noteOff(channel: 0, note: note)]
            {
                keyboard.receive(message)
                state.earDailyInput.receive(.init(message: message, keyboard: keyboard), state: state)
            }
        }
    }
    @MainActor private func complete(_ state: AppState, now: Date) throws -> EarDailySession {
        let session = try playStep(state, now: now)
        let attempt = try session.midiAttempt(notes: session.expectedNotes, now: now.addingTimeInterval(2))
        try state.saveEarDailyAttempt(attempt, expected: session)
        let answerID = try state.openEarDailyAnswer(session.id, now: now.addingTimeInterval(3))
        var scores = state.editor
        let index = try XCTUnwrap(scores.documents.firstIndex { $0.id == answerID })
        scores.documents[index].events[0].pitches = [EditorPitch(session.expectedNotes[0])]
        try state.commitScores(scores)
        let score = try XCTUnwrap(state.editor.documents.first { $0.id == answerID })
        try state.finishCreativeAnswer(
            answerID, listenedFingerprint: LibraryPiece(source: .score(score)).fingerprint,
            now: now.addingTimeInterval(4))
        try state.resumeEarDaily(session.id)
        try state.finishEarDaily(session.id, now: now.addingTimeInterval(5))
        return try XCTUnwrap(state.earDailySession)
    }
    @MainActor func testPianoSessionSavesSourceLinkedAnswerAndResumesWithoutDuplicatingIt() throws {
        let now = Date()
        let state = try fixture(now: now)
        let journey = try XCTUnwrap(state.selectedSongJourney)
        let session = try complete(state, now: now)
        XCTAssertEqual(session.stage, .complete)
        XCTAssertTrue(state.songEvidence(journey)[.hear]!.latest!.assisted)
        XCTAssertFalse(state.songEvidence(journey)[.arrange]!.hasArtifact)
        let count = state.editor.documents.count
        XCTAssertEqual(try state.openEarDailyAnswer(session.id, now: now.addingTimeInterval(6)), session.answerID)
        XCTAssertEqual(state.editor.documents.count, count)
        let restored = AppState(storageOverride: state.storage)
        defer { restored.midi.shutdown() }
        XCTAssertEqual(restored.earDailySession?.id, session.id)
        XCTAssertEqual(restored.earDailySession?.stage, .complete)
        XCTAssertEqual(restored.practiceState.schemaVersion, 18)
        XCTAssertTrue(
            restored.editor.documents.contains {
                $0.id == session.answerID && $0.responseSource?.sessionID == session.id
            })
    }
    @MainActor func testMIDICaptureRecordsReleasedNotesAndCheckIsExplicit() throws {
        let now = Date()
        let state = try fixture(now: now)
        let session = try playStep(state, now: now)
        try state.earDailyInput.arm(state: state, now: now.addingTimeInterval(2))
        send(session.expectedNotes, state: state)
        XCTAssertTrue(state.journal.attempts.isEmpty)
        state.earDailyInput.submit(state: state, now: now.addingTimeInterval(3))
        XCTAssertEqual(state.earDailyLatestAttempt?.played, session.expectedNotes)
        XCTAssertEqual(state.earDailyLatestAttempt?.outcome, .correct)
        XCTAssertEqual(state.earDailySession?.stage, .review)
        XCTAssertEqual(state.journal.attempts.count, 1)
    }
    @MainActor func testResetAndNavigationCannotSubmitRetainedMatchingPrefix() throws {
        let now = Date()
        let state = try fixture(now: now)
        let session = try playStep(state, now: now)
        try state.earDailyInput.arm(state: state, now: now.addingTimeInterval(2))
        send(session.expectedNotes, state: state)
        state.earDailyInput.receive(.init(message: .reset, keyboard: .init()), state: state)
        state.earDailyInput.submit(state: state, now: now.addingTimeInterval(3))
        XCTAssertTrue(state.journal.attempts.isEmpty)
        try state.earDailyInput.arm(state: state, now: now.addingTimeInterval(4))
        send(session.expectedNotes, state: state)
        state.navigate(to: .library)
        state.earDailyInput.submit(state: state, now: now.addingTimeInterval(5))
        XCTAssertTrue(state.journal.attempts.isEmpty)
        XCTAssertNil(state.earDailyInput.pending)
    }
    @MainActor func testHeldKeysChordAndTypingCannotBecomeEarAnswers() throws {
        let now = Date()
        let state = try fixture(now: now)
        _ = try playStep(state, now: now)
        state.contextCoach.typing = true
        XCTAssertThrowsError(try state.earDailyInput.arm(state: state, now: now.addingTimeInterval(2)))
        state.contextCoach.typing = false
        try state.earDailyInput.arm(state: state, now: now.addingTimeInterval(3))
        var keys = MIDIKeyboardState()
        for message in [
            MIDIMessage.noteOn(channel: 0, note: 60, velocity: 80), .noteOn(channel: 0, note: 64, velocity: 80),
            .noteOff(channel: 0, note: 60), .noteOff(channel: 0, note: 64),
        ] {
            keys.receive(message)
            state.earDailyInput.receive(.init(message: message, keyboard: keys), state: state)
        }
        XCTAssertFalse(state.earDailyInput.listening)
        state.earDailyInput.submit(state: state, now: now.addingTimeInterval(4))
        XCTAssertTrue(state.journal.attempts.isEmpty)
    }
    @MainActor func testMIDISaveConflictRetainsExactPendingAnswerAndRetriesOnce() throws {
        let now = Date()
        let state = try fixture(now: now)
        let session = try playStep(state, now: now)
        try state.earDailyInput.arm(state: state, now: now.addingTimeInterval(2))
        send(session.expectedNotes, state: state)
        let url = state.stores.practice.url
        let bytes = try Data(contentsOf: url)
        try Data("external conflict".utf8).write(to: url)
        state.earDailyInput.submit(state: state, now: now.addingTimeInterval(3))
        let pending = try XCTUnwrap(state.earDailyInput.pending)
        XCTAssertTrue(state.journal.attempts.isEmpty)
        XCTAssertNil(state.history.cards[session.activityID])
        XCTAssertEqual(state.earDailySession?.stage, .play)
        state.navigate(to: .library)
        XCTAssertEqual(state.earDailyInput.pending?.attempt.id, pending.attempt.id)
        try bytes.write(to: url)
        state.earDailyInput.save(state: state)
        state.earDailyInput.save(state: state)
        XCTAssertNil(state.earDailyInput.pending)
        XCTAssertEqual(state.journal.attempts.map(\.id), [pending.attempt.id])
        XCTAssertEqual(state.earDailySession?.attemptIDs, [pending.attempt.id])
    }
    @MainActor func testForgedOutcomeAndStaleSourceCannotReceiveCredit() throws {
        let now = Date()
        let state = try fixture(now: now)
        let session = try playStep(state, now: now)
        var attempt = try session.midiAttempt(notes: [1], now: now.addingTimeInterval(2))
        attempt.outcome = .correct
        XCTAssertThrowsError(try state.saveEarDailyAttempt(attempt, expected: session))
        var scores = state.editor
        let index = try XCTUnwrap(
            scores.documents.firstIndex { "score:" + $0.id.uuidString == session.material.pieceID })
        scores.documents[index].events[0].pitches = [EditorPitch(62)]
        try state.commitScores(scores)
        let original = try session.midiAttempt(notes: session.expectedNotes, now: now.addingTimeInterval(3))
        XCTAssertThrowsError(try state.saveEarDailyAttempt(original, expected: session))
        XCTAssertTrue(state.journal.attempts.isEmpty)
        XCTAssertNil(state.history.cards[session.activityID])
    }
    @MainActor func testFocusedCorrectRetryStaysSupportedAndRequiresWholePhrase() throws {
        let now = Date()
        let state = try fixture(now: now)
        let session = try playStep(state, now: now)
        var wrong = session.expectedNotes
        wrong[2] += 1
        try state.saveEarDailyAttempt(
            session.midiAttempt(notes: wrong, now: now.addingTimeInterval(2)), expected: session)
        XCTAssertEqual(state.earDailyFocusBar(try XCTUnwrap(state.earDailySession)), 2)
        try state.updateEarDaily(session.id) { try $0.retry(bar: 2, now: now.addingTimeInterval(3)) }
        let focused = try XCTUnwrap(state.earDailySession)
        XCTAssertEqual(focused.expectedNotes.count, 2)
        try state.saveEarDailyAttempt(
            focused.midiAttempt(notes: focused.expectedNotes, now: now.addingTimeInterval(4)), expected: focused)
        XCTAssertTrue(try XCTUnwrap(state.earDailyLatestAttempt).assisted)
        XCTAssertEqual(state.earDailyLatestAttempt?.passageScope?.from, 1)
        try state.updateEarDaily(session.id) { try $0.retry(now: now.addingTimeInterval(5)) }
        XCTAssertNil(state.earDailySession?.focusBar)
        XCTAssertEqual(state.earDailySession?.expectedNotes, session.expectedNotes)
        XCTAssertTrue(state.earDailySession!.assisted)
    }
    @MainActor func testPitchOnlyGuitarEvidenceIsCanonicalAndTimingIsNotCredited() throws {
        let now = Date()
        let state = try fixture(.guitar, now: now)
        let session = try playStep(state, now: now)
        let plan = try state.earDailyMicrophonePlan(session)
        var book = state.microphonePhrases
        try book.open(plan)
        var snapshot = state.practiceState
        snapshot.microphonePhrases = book
        try state.commitPractice(snapshot)
        var take = MicrophonePhraseChecks.take(plan, date: now.addingTimeInterval(2), clean: true)
        take.calibration = nil
        XCTAssertFalse(take.report.conclusive)
        _ = try state.saveEarDailyMicrophone(take)
        XCTAssertEqual(state.earDailyLatestAttempt?.input, .microphone)
        XCTAssertEqual(state.earDailyLatestAttempt?.outcome, .correct)
        XCTAssertNil(state.earDailyLatestAttempt?.timedPracticeID)
        XCTAssertEqual(state.microphonePhrases.active?.latest?.id, take.id)
        XCTAssertEqual(state.earDailySession?.attemptIDs, [take.id])
        XCTAssertEqual(state.journal.attempts.count, 1)
    }
    @MainActor func testDisputedGuitarTakeIsKeptWithoutInventingWeaknessOrReviewGrade() throws {
        let now = Date()
        let state = try fixture(.guitar, now: now)
        let session = try playStep(state, now: now)
        let plan = try state.earDailyMicrophonePlan(session)
        var book = state.microphonePhrases
        try book.open(plan)
        var snapshot = state.practiceState
        snapshot.microphonePhrases = book
        try state.commitPractice(snapshot)
        var take = MicrophonePhraseChecks.take(plan, date: now.addingTimeInterval(2), clean: true)
        take.disputedTargets = [0]
        _ = try state.saveEarDailyMicrophone(take)
        XCTAssertEqual(state.earDailySession?.stage, .review)
        XCTAssertNil(state.earDailyLatestAttempt)
        XCTAssertNil(state.earDailyFocusBar(try XCTUnwrap(state.earDailySession)))
        XCTAssertNil(state.history.cards[session.activityID])
        XCTAssertTrue(state.journal.attempts.isEmpty)
        XCTAssertEqual(state.microphonePhrases.active?.takes.count, 1)
    }
    @MainActor func testAnswerMustBeSavedAndListenedToBeforeSessionCompletion() throws {
        let now = Date()
        let state = try fixture(now: now)
        let session = try playStep(state, now: now)
        XCTAssertThrowsError(try state.finishEarDaily(session.id, now: now.addingTimeInterval(2)))
        try state.updateEarDaily(session.id) { try $0.skip(now: now.addingTimeInterval(3)) }
        let answer = try state.openEarDailyAnswer(session.id, now: now.addingTimeInterval(4))
        XCTAssertThrowsError(try state.finishEarDaily(session.id, now: now.addingTimeInterval(5)))
        XCTAssertThrowsError(
            try state.finishCreativeAnswer(answer, listenedFingerprint: "", now: now.addingTimeInterval(6)))
        XCTAssertTrue(state.journal.checked.isEmpty)
    }
    @MainActor func testIndependentReturnHonoursDelayAndSourceRevealMakesSupportSticky() throws {
        let now = Date()
        let state = try fixture(now: now)
        let completed = try complete(state, now: now)
        let journey = try XCTUnwrap(state.selectedSongJourney)
        let due = try XCTUnwrap(state.earDailyReturnDate(journey.material, instrument: .piano))
        XCTAssertThrowsError(try state.openEarDaily(journey, mode: .recall, now: due.addingTimeInterval(-1)))
        try state.openEarDaily(journey, mode: .recall, now: due)
        let recall = try XCTUnwrap(state.earDailySession)
        XCTAssertNotEqual(recall.id, completed.id)
        XCTAssertEqual(recall.stage, .imagine)
        XCTAssertFalse(recall.assisted)
        try state.noteEarDailySourceExposure(journey.material.pieceID, now: due.addingTimeInterval(1))
        XCTAssertTrue(state.earDailySession!.assisted)
        try state.resumeEarDaily(recall.id)
        XCTAssertTrue(state.earDailySession!.assisted)
    }
    @MainActor func testTransferHasOneNewStimulusAndItsOwnSourceAndReviewIdentity() throws {
        let now = Date()
        let state = try fixture(now: now)
        _ = try complete(state, now: now)
        let journey = try XCTUnwrap(state.selectedSongJourney)
        let due = try XCTUnwrap(state.earDailyReturnDate(journey.material, instrument: .piano))
        try state.openEarDaily(journey, mode: .transfer, now: due)
        let transfer = try XCTUnwrap(state.earDailySession)
        XCTAssertEqual(transfer.material.id, journey.transfer.id)
        XCTAssertEqual(transfer.stage, .hear)
        XCTAssertFalse(transfer.assisted)
        try state.hearEarDaily(transfer.id, now: due, play: { _ in })
        XCTAssertFalse(state.earDailySession!.assisted)
        try state.hearEarDaily(transfer.id, now: due.addingTimeInterval(1), play: { _ in })
        XCTAssertTrue(state.earDailySession!.assisted)
    }
    @MainActor func testReviewQueueRetainsThreeDayMicrophoneSpacing() throws {
        let state = try fixture(.guitar)
        let now = Date()
        let session = try playStep(state, now: now)
        let plan = try state.earDailyMicrophonePlan(session)
        var book = state.microphonePhrases
        try book.open(plan)
        var baseline = MicrophonePhraseChecks.take(plan, date: now, clean: true)
        _ = try book.record(baseline)
        var returning = try plan.whole(mode: .independent)
        baseline = MicrophonePhraseChecks.take(returning, date: now.addingTimeInterval(86400), clean: true)
        _ = try book.record(baseline)
        returning = try plan.whole(mode: .independent)
        baseline = MicrophonePhraseChecks.take(returning, date: now.addingTimeInterval(3 * 86400), clean: true)
        _ = try book.record(baseline)
        var snapshot = state.practiceState
        snapshot.microphonePhrases = book
        try state.commitPractice(snapshot)
        let progress = try XCTUnwrap(state.microphonePhrases.active)
        let cutoff = try XCTUnwrap(book.returnDate(progress.id))
        let due = try XCTUnwrap(progress.review.due)
        XCTAssertGreaterThan(due, cutoff)
        XCTAssertFalse(state.practiceReviews(now: cutoff).contains { $0.id == "microphone:" + progress.id })
        XCTAssertTrue(state.practiceReviews(now: due).contains { $0.id == "microphone:" + progress.id })
    }

    @MainActor func testHeldExtraMIDINoteMustBeReleasedBeforeCheck() throws {
        let now = Date()
        let state = try fixture(now: now)
        let session = try playStep(state, now: now)
        try state.earDailyInput.arm(state: state, now: now.addingTimeInterval(2))
        send(session.expectedNotes, state: state)
        var keyboard = MIDIKeyboardState()
        let message = MIDIMessage.noteOn(channel: 0, note: 61, velocity: 80)
        keyboard.receive(message)
        state.earDailyInput.receive(.init(message: message, keyboard: keyboard), state: state)
        state.earDailyInput.submit(state: state, now: now.addingTimeInterval(3))
        XCTAssertTrue(state.journal.checked.isEmpty)
        XCTAssertTrue(state.earDailyInput.listening)
        XCTAssertNil(state.earDailyInput.pending)
    }

    @MainActor func testFirstTransferSourceVisitDelaysIndependentAttemptWithoutDailySession() throws {
        let now = Date()
        let state = try fixture(now: now)
        _ = try complete(state, now: now)
        let journey = try XCTUnwrap(state.selectedSongJourney)
        let due = try XCTUnwrap(state.earDailyReturnDate(journey.material, instrument: .piano))
        XCTAssertFalse(state.earDailyPractice.sessions.contains { $0.material.id == journey.transfer.id })
        try state.noteEarDailySourceExposure(journey.transfer.pieceID, now: due)
        XCTAssertThrowsError(try state.openEarDaily(journey, mode: .transfer, now: due.addingTimeInterval(60)))
        XCTAssertNotNil(state.earDailyReturnDate(journey.transfer, instrument: .piano))
    }

    @MainActor func testHistoricalExposureAfterSourceEditNeverNeedsCurrentCredit() throws {
        let now = Date()
        let state = try fixture(now: now)
        let session = try playStep(state, now: now)
        var scores = state.editor
        let index = try XCTUnwrap(
            scores.documents.firstIndex { "score:" + $0.id.uuidString == session.material.pieceID })
        scores.documents[index].events[0].pitches = [EditorPitch(62)]
        try state.commitScores(scores)
        XCTAssertThrowsError(try state.validateEarDaily(session))
        try state.recordEarDailyExposure(session.id, at: now.addingTimeInterval(20))
        XCTAssertEqual(state.earDailySession?.lastExposure, now.addingTimeInterval(20))
        XCTAssertTrue(state.journal.checked.isEmpty)
    }

    @MainActor func testEarlyGuidedSuccessKeepsEarnedSpacedInterval() throws {
        let now = Date()
        let state = try fixture(now: now)
        _ = try complete(state, now: now)
        let journey = try XCTUnwrap(state.selectedSongJourney)
        let due = try XCTUnwrap(state.earDailyReturnDate(journey.material, instrument: .piano))
        try state.openEarDaily(journey, mode: .recall, now: due)
        let id = try XCTUnwrap(state.earDailySession?.id)
        try state.updateEarDaily(id) { try $0.imagined(now: due) }
        let recall = try XCTUnwrap(state.earDailySession)
        try state.saveEarDailyAttempt(
            recall.midiAttempt(notes: recall.expectedNotes, now: due.addingTimeInterval(1)), expected: recall)
        let earned = try XCTUnwrap(state.history.cards[recall.activityID]?.review)
        XCTAssertEqual(earned.intervalDays, 1)
        try state.updateEarDaily(id) { try $0.retry(now: due.addingTimeInterval(2)) }
        let retry = try XCTUnwrap(state.earDailySession)
        try state.saveEarDailyAttempt(
            retry.midiAttempt(notes: retry.expectedNotes, now: due.addingTimeInterval(3)), expected: retry)
        XCTAssertEqual(state.history.cards[recall.activityID]?.review, earned)
    }
}
