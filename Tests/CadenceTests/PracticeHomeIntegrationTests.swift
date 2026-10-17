// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

@testable import Cadence

final class PracticeHomeIntegrationTests: XCTestCase {
    @MainActor private func state(pathway: Bool = false) throws -> AppState {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let state = AppState(storageOverride: folder)
        addTeardownBlock {
            await MainActor.run { state.midi.shutdown() }
            try? FileManager.default.removeItem(at: folder)
        }
        if pathway {
            let url = PDFImportExamples.url("chapter").deletingLastPathComponent().appendingPathComponent(
                "pathway.epub")
            let bytes = try Data(contentsOf: url)
            let song = BookAsset(data: bytes, filename: "Original.epub", epub: try EPUBDocument(data: bytes))
            try state.installSmoothPathway(
                songAsset: song, jazzAsset: BookAsset(pdf: try CourseExamples.asset()), inversions: 1, songwriting: 2,
                jazzPage: 1)
        }
        return state
    }
    @MainActor private func piecePath(_ state: AppState) throws -> LearningPathway {
        let piece = LibraryPiece(source: .score(state.editor.active))
        let snapshot = try PieceSnapshot(piece: piece, from: 0, through: 3)
        return try PiecePathwayFactory.make(
            piece: piece, snapshot: snapshot, record: state.pieceRecord(piece), profile: state.learning.profile)
    }
    @MainActor func testFreshHomeOffersActivitiesWithoutInventingProgress() throws {
        let state = try state()
        XCTAssertEqual(state.destination, .practice)
        XCTAssertEqual(state.practicePage, .songJourney)
        XCTAssertNil(state.homePathway)
        XCTAssertNil(state.homeComposition)
        XCTAssertFalse(state.canResumeAdaptive)
        XCTAssertTrue(state.practiceReviews().isEmpty)
        XCTAssertThrowsError(try state.beginHomeSession())
        state.openPractice(.rhythm)
        XCTAssertEqual(state.practicePage, .exercises)
        XCTAssertEqual(state.practiceExercise, .rhythm)
        state.openPractice(.chords, chords: true)
        XCTAssertTrue(state.practiceMIDIExercise)
        state.openPractice(.intervals)
        XCTAssertFalse(state.practiceMIDIExercise)
        state.navigate(to: .practice)
        XCTAssertEqual(state.practicePage, .exercises)
        state.navigate(to: .explore)
        XCTAssertEqual(state.destination, .explore)
        XCTAssertTrue(state.journal.attempts.isEmpty)
    }
    @MainActor func testSessionStartsAtHomeAndResumesTheSameAttempt() throws {
        let state = try state(pathway: true)
        try state.beginHomeSession()
        let initial = try XCTUnwrap(state.smoothPractice.active)
        XCTAssertEqual(state.practicePage, .adaptive)
        XCTAssertEqual(state.destination, .practice)
        XCTAssertTrue(state.adaptiveFromPractice)
        XCTAssertTrue(state.canResumeAdaptive)
        state.adaptiveInput.submit(initial.current!.solutions[0], state: state, input: .choice)
        let saved = state.smoothPractice.active
        state.showPracticeHome()
        try state.beginHomeSession()
        XCTAssertEqual(state.smoothPractice.active, saved)
        XCTAssertEqual(state.smoothPractice.active?.id, initial.id)
        XCTAssertFalse(state.adaptiveInput.listening)
        XCTAssertEqual(state.journal.attempts.count, 1)
    }
    @MainActor func testUnsavedAnswerSurvivesHomeAndCanBeRecoveredExactlyOnce() throws {
        let state = try state(pathway: true)
        try state.beginHomeSession()
        let url = state.stores.practice.url
        let bytes = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        state.adaptiveInput.submit([60, 65, 69], state: state, input: .choice)
        let id = try XCTUnwrap(state.adaptiveInput.pending?.id)
        state.showPracticeHome()
        try state.beginHomeSession()
        XCTAssertEqual(state.adaptiveInput.pending?.id, id)
        XCTAssertTrue(state.journal.attempts.isEmpty)
        try FileManager.default.removeItem(at: url)
        try bytes.write(to: url)
        state.adaptiveInput.save(state: state)
        state.adaptiveInput.save(state: state)
        XCTAssertNil(state.adaptiveInput.pending)
        XCTAssertEqual(state.journal.attempts.map(\.id), [id])
    }
    @MainActor func testCompositionReturnsToThePracticeSessionWithoutResettingIt() throws {
        let state = try state(pathway: true)
        try state.beginHomeSession()
        let session = try XCTUnwrap(state.smoothPractice.active)
        try state.openPathwayComposition(session.pathwayID)
        let location = try XCTUnwrap(state.courseReturn)
        XCTAssertEqual(state.destination, .editor)
        state.returnToCourse(location)
        XCTAssertEqual(state.destination, .practice)
        XCTAssertEqual(state.practicePage, .adaptive)
        XCTAssertEqual(state.smoothPractice.active, session)
        state.showPathways()
        state.returnToCourse(location)
        XCTAssertEqual(state.destination, .courses)
    }
    @MainActor func testMissingSessionPathwayDoesNotSilentlyCreateAnotherSession() throws {
        let state = try state(pathway: true)
        try state.beginHomeSession()
        let before = state.smoothPractice
        state.courses.musicalPathways = []
        XCTAssertNil(state.homePathway)
        XCTAssertFalse(state.canResumeAdaptive)
        XCTAssertThrowsError(try state.beginHomeSession())
        XCTAssertThrowsError(try state.showAdaptiveWorkspace(inPractice: true))
        XCTAssertEqual(state.smoothPractice, before)
    }
    @MainActor func testReviewQueueMixesDueAndNewAndRejectsPausedOrChangedMusic() throws {
        let state = try state()
        let now = Date()
        var path = try piecePath(state)
        path.piecePractice!.tasks[0].review.record(
            .again, episode: UUID(), input: .choice, now: now.addingTimeInterval(-1200))
        path.piecePractice!.tasks[1].review.record(.good, episode: UUID(), input: .choice, now: now)
        try state.savePiecePathway(path)
        let items = state.practiceReviews(now: now)
        XCTAssertEqual(items.first?.review.lastGrade, .again)
        XCTAssertFalse(items.contains { $0.id.hasSuffix(path.piecePractice!.tasks[1].id.uuidString) })
        XCTAssertTrue(items.contains { $0.review.encounters == 0 })
        let old = try XCTUnwrap(items.first)
        state.learning.pathways[0].piecePractice!.paused = true
        XCTAssertTrue(state.practiceReviews().isEmpty)
        state.openPracticeReview(old)
        XCTAssertNotNil(state.message)
        XCTAssertNil(state.pathwaySession)
        state.learning.pathways[0].piecePractice!.paused = false
        state.message = nil
        try state.editor.documents[0].setPitch(state.editor.documents[0].events[0].id, midi: 61)
        XCTAssertTrue(state.practiceReviews().isEmpty)
        state.openPracticeReview(old)
        XCTAssertNotNil(state.message)
        XCTAssertNil(state.pathwaySession)
    }
    @MainActor func testPieceAndRhythmReviewLinksBypassHomeAndKeepTheirScope() throws {
        let state = try state()
        let path = try piecePath(state)
        try state.savePiecePathway(path)
        let item = try XCTUnwrap(state.practiceReviews().first)
        state.openPracticeReview(item)
        XCTAssertEqual(state.practicePage, .exercises)
        XCTAssertEqual(state.pathwaySession?.pathwayID, path.id)
        let plan = TimedPracticePlan(rhythm: .rests, tempo: 80)
        var result = TimedPracticeResult(plan: plan, conditions: TimedConditions(input: .space), attacks: [])
        result.date = Date().addingTimeInterval(-700)
        try state.saveTimedResult(result)
        state.showPracticeHome()
        let rhythm = try XCTUnwrap(state.practiceReviews().first { $0.id == "timed:" + result.practiceID })
        state.openPracticeReview(rhythm)
        XCTAssertEqual(state.destination, .practice)
        XCTAssertEqual(state.practicePage, .exercises)
        XCTAssertEqual(state.rhythmReview?.plan, plan)
        XCTAssertNil(state.pathwaySession)
    }
    @MainActor func testReviewClockDoesNotShowFutureReviewsEarly() throws {
        let state = try state()
        let now = Date()
        let plan = TimedPracticePlan(rhythm: .pulse, tempo: 80)
        var result = TimedPracticeResult(plan: plan, conditions: TimedConditions(input: .space), attacks: [])
        result.date = now
        try state.saveTimedResult(result)
        XCTAssertTrue(state.practiceReviews(now: now).isEmpty)
        XCTAssertEqual(state.practiceReviews(now: now.addingTimeInterval(601)).count, 1)
    }
    func testNotationAndMovementNeverRevealAnIndependentAnswer() throws {
        var session = try SmoothSession(pathwayID: UUID(), minutes: 15)
        XCTAssertNil(AdaptivePresentation.answer(session))
        try session.reveal()
        XCTAssertEqual(AdaptivePresentation.answer(session), session.current?.solutions.first)
        var independent = try SmoothSession(pathwayID: UUID(), minutes: 15)
        _ = try independent.answer([53, 57, 60], input: .choice)
        XCTAssertEqual(AdaptivePresentation.answer(independent), [53, 57, 60])
        try independent.advance()
        XCTAssertNil(AdaptivePresentation.answer(independent))
    }
}
