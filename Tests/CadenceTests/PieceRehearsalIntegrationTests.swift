// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

@testable import Cadence

final class PieceRehearsalIntegrationTests: XCTestCase {
    @MainActor func prepared() throws -> (AppState, LibraryPiece) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let state = AppState(storageOverride: folder)
        let piece = LibraryPiece(source: .score(try PieceRehearsalChecks.document()))
        addTeardownBlock {
            await MainActor.run {
                state.midi.shutdown()
                state.audio.stop()
                state.rehearsalSession.stop()
            }
            try? FileManager.default.removeItem(at: folder)
        }
        if case .score(let doc) = piece.source { state.editor.documents.append(doc) }
        XCTAssertTrue(state.save())
        state.openPieceRehearsal(piece)
        try state.beginRehearsal(
            piece, scope: .init(partID: "P1", staff: 1, from: 4, through: 7), tempo: 80,
            now: Date().addingTimeInterval(-10))
        return (state, piece)
    }
    @MainActor func testOpeningFocusContextSavedAtomicallyAndResumesAfterRelaunch() throws {
        let (state, piece) = try prepared()
        try PieceRehearsalChecks.capture(state: state, imperfect: true)
        var r = try XCTUnwrap(state.currentRehearsal)
        XCTAssertEqual(r.stage, .focus)
        XCTAssertEqual(r.focus?.source?.scope.from, 6)
        XCTAssertEqual(state.journal.attempts.count, 1)
        XCTAssertTrue(state.journal.attempts[0].assisted)
        XCTAssertEqual(state.journal.attempts[0].pieceID, piece.id)
        try PieceRehearsalChecks.capture(state: state, exercise: .rhythm)
        try state.updateRehearsal(r.key) { try $0.returnToPhrase() }
        try PieceRehearsalChecks.capture(state: state)
        r = try XCTUnwrap(state.currentRehearsal)
        XCTAssertEqual(r.stage, .complete)
        XCTAssertEqual(state.journal.attempts.count, 3)
        XCTAssertTrue(state.journal.attempts.allSatisfy(\.assisted))
        XCTAssertEqual(r.review.intervalDays, 0)
        XCTAssertFalse(state.practiceReviews().contains { $0.id == r.key })
        XCTAssertTrue(state.practiceReviews(now: Date().addingTimeInterval(86401)).contains { $0.id == r.key })
        let restored = AppState(storageOverride: state.storage)
        defer { restored.midi.shutdown() }
        XCTAssertEqual(restored.rehearsals, state.rehearsals)
        restored.openPieceRehearsal(piece)
        XCTAssertEqual(restored.currentRehearsal, r)
        XCTAssertEqual(restored.practicePage, .rehearsal)
        XCTAssertEqual(try RehearsalSource.whole(piece).selectedMeasures.count, 12)
    }
    @MainActor func testFailedCommitRetainsPassAndRetrySavesExactlyOnce() throws {
        let (state, _) = try prepared()
        let before = state.practiceState
        let url = state.stores.practice.url
        let bytes = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try PieceRehearsalChecks.capture(state: state, imperfect: true)
        XCTAssertTrue(state.rehearsalSession.timing.hasUnsavedResult)
        XCTAssertEqual(state.practiceState, before)
        let id = state.rehearsalSession.timing.result?.id
        state.showPracticeHome()
        XCTAssertEqual(state.rehearsalSession.timing.result?.id, id)
        XCTAssertThrowsError(try state.startRehearsal(exercise: .notes, tempo: 60, input: .midi))
        try FileManager.default.removeItem(at: url)
        try bytes.write(to: url)
        state.saveRehearsalPass()
        state.saveRehearsalPass()
        XCTAssertTrue(state.rehearsalSession.timing.saved)
        XCTAssertEqual(state.journal.attempts.filter { $0.id == id }.count, 1)
        XCTAssertEqual(state.currentRehearsal?.stage, .focus)
    }
    @MainActor func testChangedAndDeletedSourcesCannotUseOldEvidence() throws {
        let (state, piece) = try prepared()
        try PieceRehearsalChecks.capture(state: state, imperfect: true)
        let r = try XCTUnwrap(state.currentRehearsal)
        let index = try XCTUnwrap(state.editor.documents.firstIndex { "score:" + $0.id.uuidString == piece.id })
        state.editor.documents[index].title = "A new title"
        XCTAssertTrue(state.rehearsalCurrent(r))
        state.editor.documents[index].events.firstIndex { $0.staff == 1 }.map {
            state.editor.documents[index].events[$0].pitches = [EditorPitch(89)]
        }
        XCTAssertFalse(state.rehearsalCurrent(r))
        XCTAssertThrowsError(try state.updateRehearsal(r.key) { try $0.returnToPhrase() })
        XCTAssertThrowsError(try state.startRehearsal(exercise: .notes, tempo: 65, input: .midi))
        state.editor.documents.remove(at: index)
        XCTAssertFalse(state.rehearsalCurrent(r))
        XCTAssertTrue(state.rehearsalReviews.isEmpty)
    }
    @MainActor func testRhythmSpaceTapsKeepSourceBarsAndInputSeparate() throws {
        let (state, _) = try prepared()
        try PieceRehearsalChecks.capture(state: state, imperfect: true)
        let r = try XCTUnwrap(state.currentRehearsal)
        let session = state.rehearsalSession
        let plan = try session.prepare(r, exercise: .rhythm, tempo: 65, input: .space, held: [60])
        let origin = PracticeClock.now() - plan.duration - 1
        session.timing.begin(at: origin)
        for target in plan.targets { session.timing.attack(at: origin + target.beat * plan.secondsPerBeat) }
        session.timing.tick()
        state.saveRehearsalPass()
        XCTAssertTrue(session.timing.saved)
        XCTAssertTrue(try XCTUnwrap(session.timing.result).report.clean)
        XCTAssertEqual(session.feedback.map { $0.assessment.target.bar }, [6, 6])
        XCTAssertEqual(session.sourcePlan?.source?.startBeat, 24)
        XCTAssertEqual(state.journal.attempts.last?.input, .tapping)
        XCTAssertEqual(state.journal.attempts.last?.passageScope?.from, 6)
        XCTAssertEqual(state.journal.attempts.last?.assisted, true)
    }
    @MainActor func testPhysicalReleaseAndResetCancelUngradedCapture() throws {
        let (state, _) = try prepared()
        let r = try XCTUnwrap(state.currentRehearsal)
        let s = state.rehearsalSession
        XCTAssertThrowsError(try s.prepare(r, exercise: .notes, tempo: 80, input: .midi, held: [60]))
        let p = try s.prepare(r, exercise: .notes, tempo: 80, input: .midi, held: [])
        let origin = PracticeClock.now()
        s.timing.begin(at: origin)
        var keys = MIDIKeyboardState()
        let pitch = p.targets[0].pitch
        for message in [
            MIDIMessage.noteOn(channel: 0, note: pitch, velocity: 90), .noteOn(channel: 0, note: pitch, velocity: 90),
            .control(channel: 0, number: 64, value: 127),
        ] {
            keys.receive(message)
            s.timing.receive(.init(message: message, keyboard: keys, timestamp: origin))
        }
        XCTAssertEqual(s.timing.attacks.count, 1)
        s.timing.receive(.init(message: .reset, keyboard: .init(), timestamp: origin))
        state.saveRehearsalPass()
        XCTAssertFalse(s.timing.busy)
        XCTAssertNil(s.timing.result)
        XCTAssertTrue(state.journal.attempts.isEmpty)
    }
    @MainActor func testPendingPassCannotBeReplacedByAnotherPieceOrPhrase() throws {
        let (state, piece) = try prepared()
        let r = try XCTUnwrap(state.currentRehearsal)
        let s = state.rehearsalSession
        let p = try s.prepare(r, exercise: .notes, tempo: 80, input: .midi, held: [])
        let origin = PracticeClock.now() - r.opening.duration - 1
        s.timing.begin(at: origin)
        s.timing.tick()
        XCTAssertNotNil(s.timing.result)
        XCTAssertThrowsError(try state.beginRehearsal(piece, scope: p.source!.scope, tempo: 80))
        let other = LibraryPiece(source: .score(try PieceRehearsalChecks.document()))
        state.openPieceRehearsal(other)
        XCTAssertEqual(state.rehearsalPieceID, piece.id)
        XCTAssertNotNil(state.message)
        state.openPieceRehearsal(piece)
        XCTAssertEqual(state.rehearsalKey, r.key)
        XCTAssertNotNil(s.timing.result)
    }
    @MainActor func testExistingPhraseResumesRatherThanReplacingHistory() throws {
        let (state, piece) = try prepared()
        try PieceRehearsalChecks.capture(state: state)
        let before = state.rehearsals
        let r = try XCTUnwrap(state.currentRehearsal)
        try state.beginRehearsal(piece, scope: r.opening.source!.scope, tempo: 60)
        XCTAssertEqual(state.rehearsals, before)
        XCTAssertEqual(state.currentRehearsal?.opening.tempo, 80)
        XCTAssertNil(state.rehearsalSession.timing.result)
    }
    @MainActor func testIndependentReturnClearsOldFeedbackButPreservesHistory() throws {
        let (state, piece) = try prepared()
        try PieceRehearsalChecks.capture(state: state)
        let key = try XCTUnwrap(state.rehearsalKey)
        try PieceRehearsalChecks.capture(state: state)
        try state.updateRehearsal(key) { try $0.returnToPhrase() }
        try PieceRehearsalChecks.capture(state: state)
        XCTAssertNotNil(state.rehearsalSession.timing.result)
        XCTAssertFalse(state.rehearsalSession.feedback.isEmpty)
        let due = try XCTUnwrap(state.currentRehearsal?.nextReview)
        let history = state.journal
        try state.updateRehearsal(key) { try $0.beginReview(now: due) }
        state.openPieceRehearsal(piece, key: key)
        XCTAssertNil(state.rehearsalSession.timing.result)
        XCTAssertTrue(state.rehearsalSession.feedback.isEmpty)
        XCTAssertEqual(state.journal, history)
        XCTAssertEqual(state.currentRehearsal?.stage, .review)
        XCTAssertEqual(state.currentRehearsal?.reviewStarts, 0)
    }
    @MainActor func testDelayedReviewStartsPersistBeforeCancelledPass() throws {
        let (state, piece) = try prepared()
        let plan = try XCTUnwrap(state.currentRehearsal?.opening)
        let early = Date().addingTimeInterval(-172800)
        var r = try PieceRehearsal(opening: plan, now: early)
        func pass(_ p: TimedPracticePlan, _ seconds: Double, _ click: Bool = false) -> TimedPracticeResult {
            .init(
                date: early.addingTimeInterval(seconds), plan: p, conditions: .init(click: click),
                attacks: p.targets.map { .init(seconds: $0.beat * p.secondsPerBeat, pitch: $0.pitch) })
        }
        let first = pass(plan, 1)
        let focus = try RehearsalSource.focus(piece, opening: first)
        try r.recordOpening(first, focus: focus, context: plan, now: early.addingTimeInterval(1))
        try r.recordFocus(pass(focus, 2, true), exercise: .notes, now: early.addingTimeInterval(2))
        try r.returnToPhrase()
        try r.recordContext(pass(plan, 3), now: early.addingTimeInterval(3))
        var copy = state.practiceState
        copy.rehearsal?.records[r.key] = r
        try state.commitPractice(copy)
        let item = try XCTUnwrap(state.practiceReviews().first { $0.id == r.key })
        state.openPracticeReview(item)
        XCTAssertEqual(state.currentRehearsal?.stage, .review)
        try state.startRehearsal(exercise: .notes, tempo: 80, input: .midi)
        state.rehearsalSession.stop()
        XCTAssertEqual(state.currentRehearsal?.reviewStarts, 1)
        XCTAssertNil(state.rehearsalSession.timing.result)
        let restored = AppState(storageOverride: state.storage)
        defer {
            restored.midi.shutdown()
            restored.rehearsalSession.stop()
        }
        restored.openPieceRehearsal(piece)
        XCTAssertEqual(restored.currentRehearsal?.reviewStarts, 1)
        try restored.updateRehearsal(r.key) { try $0.startReviewPass() }
        try PieceRehearsalChecks.capture(state: restored)
        XCTAssertEqual(restored.currentRehearsal?.reviews.last?.independent, false)
        XCTAssertEqual(restored.currentRehearsal?.review.intervalDays, 0)
        XCTAssertEqual(restored.journal.attempts.last?.assisted, true)
    }
}
