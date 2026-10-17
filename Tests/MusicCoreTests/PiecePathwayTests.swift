// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class PiecePathwayTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func plan(_ document: EditorDocument = .guitarExample) throws -> LearningPathway {
        let piece = LibraryPiece(source: .score(document))
        let snapshot = try PieceSnapshot(piece: piece, from: 0, through: 3)
        return try PiecePathwayFactory.make(
            piece: piece, snapshot: snapshot, record: PieceRecord(kind: .composition), profile: LearnerProfile())
    }
    func testPiecePlanHasBoundedTasksFromActualScoreAndNoPaidDependency() throws {
        let path = try plan()
        let practice = try XCTUnwrap(path.piecePractice)
        XCTAssertEqual(path.outline.steps.count, 3)
        XCTAssertTrue(practice.tasks.contains { $0.kind == .signature })
        XCTAssertTrue(practice.tasks.contains { $0.kind == .interval })
        XCTAssertEqual(practice.tasks.filter { $0.kind == .passage }.count, 2)
        XCTAssertTrue(practice.tasks.allSatisfy { $0.scope.fromBar >= 1 && $0.scope.throughBar <= 4 })
        XCTAssertEqual(practice.origin, "Local starting plan")
        _ = try practice.validated(stepCount: 3)
        var library = LearningLibrary()
        library.add(path)
        XCTAssertEqual(
            try JSONDecoder().decode(LearningLibrary.self, from: JSONEncoder().encode(library)).validated(), library)
    }
    func testSignatureAndNoteAnswersUseSourceSpelling() throws {
        var score = EditorDocument.guitarExample
        score.fifths = -2
        let path = try plan(score)
        let tasks = path.piecePractice!.tasks
        let signature = try XCTUnwrap(tasks.first { $0.kind == .signature })
        XCTAssertEqual(signature.choices[signature.answer!], "2 flats")
        let study = try ComposePractice.make(score, from: 0, through: 3)
        let first = study.part.sourceNotes().filter { $0.midi >= 0 }.sorted {
            $0.start == $1.start ? $0.midi < $1.midi : $0.start < $1.start
        }.first!
        let reading = tasks.first { $0.kind == .reading }!
        XCTAssertEqual(reading.choices[reading.answer!], first.writtenPitch!.name)
    }
    func testIntervalLinkIncludesBothSourceBars() throws {
        var score = try EditorDocument.blank(instrument: .guitar, bars: 4)
        try score.setPitch(score.inBar(0, staff: 1)[0].id, midi: 60)
        try score.setPitch(score.inBar(1, staff: 1)[0].id, midi: 62)
        let task = try XCTUnwrap(try plan(score).piecePractice!.tasks.first { $0.kind == .interval })
        XCTAssertEqual(task.scope.fromBar, 1)
        XCTAssertEqual(task.scope.throughBar, 2)
        XCTAssertEqual(task.audio?.notes.map(\.midi), [60, 62])
    }
    func testChordChecksSourceTonesBassAndAllowsOctaveDoubling() throws {
        var task = PieceTask(
            stage: 0, kind: .chord, title: "Chord", instructions: "Play", readyWhen: "Steady",
            scope: PieceScope(fromBar: 1, throughBar: 1, partID: "P1", partName: "Piano"))
        task.target = [64, 67, 72]
        XCTAssertTrue(task.chordMatches([52, 55, 60, 64]))
        XCTAssertFalse(task.chordMatches([48, 52, 55]))
        XCTAssertFalse(task.chordMatches([52, 55]))
        XCTAssertFalse(task.chordMatches([52, 55, 60, 61]))
        XCTAssertFalse(task.chordMatches([]))
        XCTAssertFalse(task.chordMatches([-1, 52, 55, 60]))
    }
    func testReviewIntervalsAdvanceOnlyOnDueSeparateDays() {
        var review = PieceReview()
        var date = now
        for days in [1, 3, 7, 14, 30, 60, 60] {
            XCTAssertTrue(review.record(.good, episode: UUID(), input: .choice, now: date))
            XCTAssertEqual(review.intervalDays, days)
            XCTAssertEqual(review.due!.timeIntervalSince(date), Double(days) * 86400, accuracy: 0.01)
            date = review.due!
        }
    }
    func testHintsMissesAndRepeatedAnswersCannotPromoteReview() {
        var review = PieceReview()
        let episode = UUID()
        review.record(.again, episode: episode, input: .choice, now: now)
        XCTAssertFalse(review.record(.good, episode: episode, input: .choice, now: now.addingTimeInterval(20)))
        XCTAssertEqual(review.encounters, 1)
        XCTAssertEqual(review.difficult, 1)
        XCTAssertEqual(review.intervalDays, 0)
        XCTAssertEqual(review.due, now.addingTimeInterval(600))
        review.record(.supported, episode: UUID(), input: .choice, now: now.addingTimeInterval(600))
        XCTAssertEqual(review.intervalDays, 0)
        XCTAssertEqual(review.due, now.addingTimeInterval(1800))
        review.record(.good, episode: UUID(), input: .choice, now: now.addingTimeInterval(1800))
        let due = review.due
        review.record(.good, episode: UUID(), input: .choice, now: now.addingTimeInterval(1900))
        XCTAssertEqual(review.intervalDays, 1)
        XCTAssertEqual(review.due, due)
    }
    func testMissAfterHintShortensReviewWithoutCountingAnotherEncounter() {
        var review = PieceReview()
        let episode = UUID()
        review.record(.supported, episode: episode, input: .choice, now: now)
        XCTAssertTrue(review.record(.again, episode: episode, input: .choice, now: now.addingTimeInterval(20)))
        XCTAssertEqual(review.encounters, 1)
        XCTAssertEqual(review.difficult, 1)
        XCTAssertEqual(review.due, now.addingTimeInterval(620))
        XCTAssertFalse(review.record(.good, episode: episode, input: .choice, now: now.addingTimeInterval(30)))
    }
    func testSameDayMissThenSuccessDoesNotAdvanceTwice() {
        var review = PieceReview()
        review.record(.good, episode: UUID(), input: .midi, now: now)
        review.record(.again, episode: UUID(), input: .midi, now: now.addingTimeInterval(60))
        review.record(.good, episode: UUID(), input: .midi, now: now.addingTimeInterval(700))
        XCTAssertEqual(review.intervalDays, 0)
        XCTAssertEqual(review.due, now.addingTimeInterval(86400))
    }
    func testSelfReportIsExplicitInEvidence() throws {
        var plan = try plan().piecePractice!
        let i = plan.tasks.firstIndex { $0.kind == .passage }!
        plan.tasks[i].review.record(.good, episode: UUID(), input: .selfReport, now: now)
        XCTAssertTrue(plan.evidence.contains("selfReport"))
        XCTAssertTrue(plan.tasks[i].review.reason(now: now.addingTimeInterval(86400)).contains("Spaced review"))
    }
    func testQueueMixesTwoReviewsAndOneNewAndPauseKeepsAllExercises() throws {
        var plan = try plan().piecePractice!
        for i in 0..<3 {
            plan.tasks[i].review.record(.again, episode: UUID(), input: .choice, now: now.addingTimeInterval(-1000))
        }
        let queue = plan.queue(now: now)
        XCTAssertGreaterThan(queue[0].review.encounters, 0)
        XCTAssertGreaterThan(queue[1].review.encounters, 0)
        XCTAssertEqual(queue[2].review.encounters, 0)
        XCTAssertFalse(plan.queue(now: now, excluding: queue[0].id).contains { $0.id == queue[0].id })
        plan.paused = true
        XCTAssertTrue(plan.queue(now: now).isEmpty)
        XCTAssertFalse(plan.tasks.isEmpty)
    }
    func testStaleAnalysisIsNotUsedForNewPlanAndStaleSnapshotRejected() throws {
        let score = EditorDocument.guitarExample
        let piece = LibraryPiece(source: .score(score))
        let snap = try PieceSnapshot(piece: piece, from: 0, through: 3)
        var analysis = SavedPieceAnalysis(
            snapshot: snap, model: "fixture", goal: "",
            outline: PieceAnalysisOutline(
                summary: "Custom", observations: [PieceObservation(title: "A", detail: "B", fromBar: 1, throughBar: 1)],
                practice: [
                    PiecePracticeStep(
                        title: "Custom focus", instructions: "Practise the first bar", readyWhen: "Even", fromBar: 1,
                        throughBar: 1)
                ], caveats: []))
        let current = try PiecePathwayFactory.make(
            piece: piece, snapshot: snap, record: PieceRecord(kind: .composition), profile: LearnerProfile(),
            analysis: analysis)
        XCTAssertEqual(current.outline.steps[1].title, "Custom focus")
        analysis.fingerprint = String(repeating: "a", count: 64)
        let fresh = try PiecePathwayFactory.make(
            piece: piece, snapshot: snap, record: PieceRecord(kind: .composition), profile: LearnerProfile(),
            analysis: analysis)
        XCTAssertEqual(fresh.piecePractice?.origin, "Local starting plan")
        var changed = score
        try changed.setPitch(changed.events[0].id, midi: 61)
        XCTAssertThrowsError(
            try PiecePathwayFactory.make(
                piece: LibraryPiece(source: .score(changed)), snapshot: snap, record: PieceRecord(kind: .composition),
                profile: LearnerProfile()))
    }
    func testInvalidTaskFutureSchemaAndDuplicatesAreRejected() throws {
        var path = try plan()
        var library = LearningLibrary()
        library.add(path)
        path.piecePractice!.tasks[0].scope.throughBar = 5
        library.pathways = [path]
        XCTAssertThrowsError(try library.validated())
        library.pathways = [try plan()]
        library.pathways[0].piecePractice!.schemaVersion = 99
        XCTAssertThrowsError(try library.validated())
        library.pathways = [try plan()]
        library.pathways[0].piecePractice!.tasks.append(library.pathways[0].piecePractice!.tasks[0])
        XCTAssertThrowsError(try library.validated())
        library.pathways = [try plan()]
        library.schemaVersion = 99
        XCTAssertThrowsError(try library.validated())
    }
    func testLegacyLibraryAndJournalDecodeWithoutNewFields() throws {
        var library = LearningLibrary()
        library.add(try plan())
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(library)) as! [String: Any]
        json.removeValue(forKey: "schemaVersion")
        var paths = json["pathways"] as! [[String: Any]]
        paths[0].removeValue(forKey: "piecePractice")
        json["pathways"] = paths
        let decoded = try JSONDecoder().decode(LearningLibrary.self, from: JSONSerialization.data(withJSONObject: json))
            .validated()
        XCTAssertNil(decoded.pathways[0].piecePractice)
        XCTAssertEqual(decoded.pathways[0].outline, library.pathways[0].outline)
        let attempt = PracticeAttempt(
            sessionID: UUID(), activityID: "old", title: "Old", skills: [], input: .choice, outcome: .correct)
        let restored = try JSONDecoder().decode(PracticeAttempt.self, from: JSONEncoder().encode(attempt))
        XCTAssertNil(restored.pathwayID)
        XCTAssertTrue(restored.valid)
    }
    func testAIUsesRecordedDifficultiesOnlyWhenExplicitlyIncluded() async throws {
        let piece = LibraryPiece(source: .score(.guitarExample))
        let snap = try PieceSnapshot(piece: piece, from: 0, through: 3)
        let outline = PieceAnalysisOutline(
            summary: "Work in smaller chunks",
            observations: [PieceObservation(title: "Pulse", detail: "Keep it even", fromBar: 1, throughBar: 2)],
            practice: [
                PiecePracticeStep(
                    title: "One bar at a time", instructions: "Slow down and count", readyWhen: "A steady pulse",
                    fromBar: 2, throughBar: 2)
            ], caveats: ["No performance was heard."])
        let reply = String(decoding: try JSONEncoder().encode(outline), as: UTF8.self)
        let calls = RequestProbe()
        let client = CoachClient { request in
            await calls.sent()
            let body = String(decoding: request.httpBody!, as: UTF8.self)
            XCTAssertTrue(body.contains("Difficulty with rhythm"))
            XCTAssertTrue(body.contains("selfReport"))
            XCTAssertTrue(body.contains("zdr"))
            XCTAssertFalse(body.contains("file_data"))
            return (
                try JSONSerialization.data(withJSONObject: [
                    "choices": [["message": ["content": reply], "finish_reason": "stop"]]
                ]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let analysis = try await PieceCoach(client: client).analyse(
            snapshot: snap, record: PieceRecord(kind: .composition),
            profile: "Difficulty with rhythm; selfReport, not a performance assessment.", apiKey: "fixture",
            model: "fixture")
        let path = try PiecePathwayFactory.make(
            piece: piece, snapshot: snap, record: PieceRecord(kind: .composition), profile: LearnerProfile(),
            analysis: analysis)
        await calls.assertCount(1)
        XCTAssertEqual(path.outline.steps[1].title, "One bar at a time")
        XCTAssertTrue(path.outline.sourceNotes.contains("No performance was heard"))
    }
}
