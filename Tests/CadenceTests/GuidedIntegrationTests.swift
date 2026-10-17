// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

@testable import Cadence

final class GuidedIntegrationTests: XCTestCase {
    private func fixture() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
    @MainActor private func prepare(_ folder: URL) throws -> (AppState, MusicStudy, GuidedPassage) {
        let state = AppState(storageOverride: folder)
        let score = state.editor.documents.first { $0.instrument == .piano }!
        let study = try ComposePractice.make(score, from: 0, through: 3)
        state.studies.add(study)
        state.studies.activeID = study.id
        state.save()
        return (state, study, try state.guidedPassage(study))
    }
    @MainActor private func finish(_ plan: GuidedPassage, mistake: Bool = false) throws -> GuidedPassageResult {
        var follower = GuidedFollower(plan: plan)
        var keys = MIDIKeyboardState()
        func send(_ message: MIDIMessage) {
            keys.receive(message)
            _ = follower.receive(message, keyboard: keys)
        }
        if mistake {
            send(.noteOn(channel: 0, note: 21, velocity: 90))
            send(.noteOff(channel: 0, note: 21))
        }
        for step in plan.steps {
            for note in step.notes { send(.noteOn(channel: 0, note: note, velocity: 90)) }
            for note in step.notes { send(.noteOff(channel: 0, note: note)) }
        }
        return try follower.result(id: UUID())
    }
    @MainActor func testResultReviewAndJournalPersistTogetherAndRetryIsIdempotent() throws {
        let folder = try fixture()
        let (state, _, plan) = try prepare(folder)
        let result = try finish(plan, mistake: true)
        let before = state.practiceState
        let url = folder.appendingPathComponent("practice-state.json")
        let bytes = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try state.saveGuidedResult(result))
        XCTAssertEqual(state.practiceState, before)
        try FileManager.default.removeItem(at: url)
        try bytes.write(to: url)
        try state.saveGuidedResult(result)
        try state.saveGuidedResult(result)
        let restored = AppState(storageOverride: folder)
        XCTAssertEqual(restored.history.guidedPassages?[plan.id]?.latest, result)
        XCTAssertEqual(restored.history.guidedPassages?[plan.id]?.review.encounters, 1)
        XCTAssertEqual(restored.history.guidedPassages?[plan.id]?.review.lastGrade, .again)
        XCTAssertEqual(restored.journal.attempts.count, 1)
        XCTAssertEqual(restored.journal.attempts[0].guidedPracticeID, plan.id)
        XCTAssertTrue(restored.journal.attempts[0].assisted)
        XCTAssertEqual(restored.journal.firstTryCorrect, 0)
    }
    @MainActor func testAlteredResultOrChangedMusicCannotGradeAnotherScore() throws {
        let (state, study, plan) = try prepare(try fixture())
        let result = try finish(plan)
        var forged = result
        forged.steps[0].target = [99]
        XCTAssertThrowsError(try state.saveGuidedResult(forged))
        let i = state.editor.documents.firstIndex { $0.id == study.sourceEditor!.scoreID }!
        state.editor.documents[i].title = "New title"
        XCTAssertEqual(try state.guidedPassage(study).id, plan.id)
        try state.saveGuidedResult(result)
        try state.editor.documents[i].setPitch(state.editor.documents[i].events[0].id, midi: 61)
        XCTAssertThrowsError(try state.guidedPassage(study))
        XCTAssertThrowsError(try state.saveGuidedResult(result))
        XCTAssertTrue(state.guidedReviews.isEmpty)
    }
    @MainActor func testReviewNavigationAndCoachEvidenceKeepTheActualPassage() throws {
        let (state, study, plan) = try prepare(try fixture())
        var result = try finish(plan, mistake: true)
        result.date = Date().addingTimeInterval(-700)
        try state.saveGuidedResult(result)
        let progress = try XCTUnwrap(state.guidedReviews.first)
        state.openGuidedReview(progress)
        XCTAssertEqual(state.destination, .studies)
        XCTAssertEqual(state.guidedStudyID, plan.studyID)
        XCTAssertEqual(state.studies.active?.from, plan.scope.from)
        XCTAssertEqual(state.studies.active?.staff, plan.scope.staff)
        let piece = try XCTUnwrap(state.libraryPieces.first { $0.id == plan.pieceID })
        XCTAssertTrue(state.piecePracticeEvidence(piece).contains("Guided MIDI reading"))
        XCTAssertTrue(state.piecePracticeEvidence(piece).contains("fluency and physical technique were not graded"))
        XCTAssertTrue(
            state.guidedReference(study).context.contains("Recorded practice for this exact score and selection"))
        var otherHand = study
        otherHand.staff = 1
        XCTAssertFalse(
            state.guidedReference(otherHand).context.contains("Recorded practice for this exact score and selection"))
    }
    @MainActor func testSessionPausesResumesAndRetainsAnUnsavedCompletion() throws {
        let (state, _, plan) = try prepare(try fixture())
        let session = GuidedPracticeSession()
        session.configure(plan)
        session.start(held: [])
        var keys = MIDIKeyboardState()
        func send(_ note: Int, on: Bool) {
            let message: MIDIMessage =
                on ? .noteOn(channel: 0, note: note, velocity: 90) : .noteOff(channel: 0, note: note)
            keys.receive(message)
            session.receive(message, keyboard: keys)
        }
        session.pause()
        send(plan.steps[0].notes[0], on: true)
        XCTAssertEqual(session.follower?.index, 0)
        session.start(held: keys.downNotes)
        XCTAssertTrue(session.follower?.waitingForRelease == true)
        send(plan.steps[0].notes[0], on: false)
        for step in plan.steps {
            for note in step.notes { send(note, on: true) }
            for note in step.notes { send(note, on: false) }
        }
        XCTAssertNotNil(session.result)
        XCTAssertFalse(session.listening)
        session.save { _ in throw CocoaError(.fileWriteOutOfSpace) }
        let pending = session.result
        session.configure(plan)
        XCTAssertEqual(session.result, pending)
        XCTAssertTrue(session.hasUnsavedResult)
        session.save { try state.saveGuidedResult($0) }
        XCTAssertTrue(session.saved)
        session.configure(plan)
        XCTAssertNil(session.result)
        XCTAssertEqual(session.follower?.index, 0)
        session.invalidate("Source changed")
        session.start(held: [])
        XCTAssertFalse(session.listening)
        XCTAssertNil(session.plan)
    }
}
