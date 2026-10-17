// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

@testable import Cadence

final class StorageIntegrationTests: XCTestCase {
    @MainActor func testDamagedScoreAndStudyFilesArePreserved() throws {
        for filename in ["editor.json", "studies.json"] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent(filename)
            let original = Data("{damaged original".utf8)
            try original.write(to: url)
            let state = AppState(storageOverride: folder)
            XCTAssertFalse(state.save())
            XCTAssertFalse(state.storageWarnings.isEmpty)
            XCTAssertEqual(state.storageStatus, "Some work is not saved")
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }
}

extension StorageIntegrationTests {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    @MainActor func testFailureInPracticeDoesNotBlockScoreOrPreferenceSaving() throws {
        let folder = try fixture()
        let state = AppState(storageOverride: folder)
        XCTAssertTrue(state.save())
        XCTAssertEqual(state.storageStatus, "Stored on this Mac")
        let url = folder.appendingPathComponent("practice-state.json")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        state.editor.documents[0].title = "A safely saved composition"
        state.capo = 3
        XCTAssertFalse(state.save())
        let reopened = AppState(storageOverride: folder)
        XCTAssertEqual(reopened.editor.documents[0].title, "A safely saved composition")
        XCTAssertEqual(reopened.capo, 3)
        XCTAssertNotNil(reopened.learningStorageError)
        XCTAssertNotNil(state.saveErrors["practice"])
    }
    @MainActor func testPracticeResultAndScheduleCommitTogetherOrNeitherChanges() throws {
        let folder = try fixture()
        let state = AppState(storageOverride: folder)
        let piece = LibraryPiece(source: .score(state.editor.active))
        let snapshot = try PieceSnapshot(piece: piece, from: 0, through: 3)
        let path = try PiecePathwayFactory.make(
            piece: piece, snapshot: snapshot, record: state.pieceRecord(piece), profile: state.learning.profile)
        try state.savePiecePathway(path)
        state.save()
        let task = path.piecePractice!.tasks.first { $0.kind == .signature }!
        state.startPathwayTask(path.id, taskID: task.id)
        let url = folder.appendingPathComponent("practice-state.json")
        let bytes = try Data(contentsOf: url)
        let before = state.practiceState
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try state.recordPathwayResult(.good, input: .choice, outcome: .correct, ordinal: 1))
        XCTAssertEqual(state.practiceState, before)
        try FileManager.default.removeItem(at: url)
        try bytes.write(to: url)
        try state.recordPathwayResult(.good, input: .choice, outcome: .correct, ordinal: 1)
        let reopened = AppState(storageOverride: folder)
        XCTAssertEqual(reopened.journal.attempts.count, 1)
        XCTAssertEqual(
            reopened.learning.pathways[0].piecePractice!.tasks.first { $0.id == task.id }!.review.encounters, 1)
        XCTAssertEqual(reopened.journal.attempts[0].pathwayTaskID, task.id)
    }
    @MainActor func testFreePracticeSaveFailureDoesNotAwardPointsOrRecordAttempt() throws {
        let folder = try fixture()
        let state = AppState(storageOverride: folder)
        state.save()
        let url = folder.appendingPathComponent("practice-state.json")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let question = QuestionFactory.deck(.functional, root: Pitch(0), scale: .major)[0]
        XCTAssertNil(state.record(question, correct: true, firstTry: true, revealed: false))
        XCTAssertEqual(state.history.xp, 0)
        XCTAssertTrue(state.journal.attempts.isEmpty)
        XCTAssertNotNil(state.message)
    }
    @MainActor func testInvalidPracticeEvidenceCannotAdvanceEitherSchedule() throws {
        let folder = try fixture()
        let state = AppState(storageOverride: folder)
        let piece = LibraryPiece(source: .score(state.editor.active))
        let snapshot = try PieceSnapshot(piece: piece, from: 0, through: 3)
        let path = try PiecePathwayFactory.make(
            piece: piece, snapshot: snapshot, record: state.pieceRecord(piece), profile: state.learning.profile)
        try state.savePiecePathway(path)
        let task = path.piecePractice!.tasks.first { $0.kind == .signature }!
        state.startPathwayTask(path.id, taskID: task.id)
        state.save()
        let before = state.practiceState
        let url = folder.appendingPathComponent("practice-state.json")
        let bytes = try Data(contentsOf: url)
        XCTAssertThrowsError(try state.recordPathwayResult(.good, input: .choice, outcome: .correct, played: [Int.max]))
        let question = QuestionFactory.deck(.functional, root: Pitch(0), scale: .major)[0]
        XCTAssertNil(state.record(question, correct: true, firstTry: true, revealed: false, played: [Int.min]))
        XCTAssertEqual(state.practiceState, before)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    @MainActor func testLegacyPracticeMigratesWithoutChangingItsFiles() throws {
        let folder = try fixture()
        let question = QuestionFactory.deck(.functional, root: Pitch(0), scale: .major)[0]
        var history = PracticeProgress()
        history.record(question, correct: true, firstTry: true, revealed: false)
        var journal = PracticeJournal()
        journal.append(
            PracticeAttempt(
                sessionID: UUID(), activityID: question.id, title: question.title, skills: [], input: .choice,
                outcome: .correct))
        let files = [
            "practice.json": try JSONEncoder().encode(history), "attempts.json": try JSONEncoder().encode(journal),
            "learning.json": try JSONEncoder().encode(LearningPreview.library),
        ]
        for (name, bytes) in files { try bytes.write(to: folder.appendingPathComponent(name)) }
        let state = AppState(storageOverride: folder)
        XCTAssertEqual(state.history, history)
        XCTAssertEqual(state.journal, journal)
        XCTAssertTrue(state.save())
        for (name, bytes) in files { XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), bytes) }
        let reopened = AppState(storageOverride: folder)
        XCTAssertEqual(reopened.practiceState, state.practiceState)
        // Once migrated, stale legacy files are not re-imported over newer progress.
        try Data("damaged old migration input".utf8).write(to: folder.appendingPathComponent("attempts.json"))
        XCTAssertEqual(AppState(storageOverride: folder).practiceState, state.practiceState)
    }
    @MainActor func testDamagedLegacyInputBlocksMigrationButNotMusicSaving() throws {
        for name in ["attempts.json", "learning.json", "practice.json"] {
            let folder = try fixture()
            let url = folder.appendingPathComponent(name)
            let data = Data("{broken migration input".utf8)
            try data.write(to: url)
            let state = AppState(storageOverride: folder)
            XCTAssertFalse(state.save())
            XCTAssertNotNil(state.learningStorageError)
            XCTAssertEqual(try Data(contentsOf: url), data)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: folder.appendingPathComponent("practice-state.json").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("editor.json").path))
        }
    }
    @MainActor func testVersionOnePracticeSnapshotMigratesOnSaveAndKeepsOriginalBackup() throws {
        let folder = try fixture()
        let url = folder.appendingPathComponent("practice-state.json")
        let question = QuestionFactory.deck(.functional, root: Pitch(0), scale: .major)[0]
        var original = PracticeState(learning: LearningPreview.library)
        original.schemaVersion = 1
        original.history.record(question, correct: true, firstTry: true, revealed: false)
        original.journal.append(
            PracticeAttempt(
                sessionID: UUID(), activityID: question.id, title: question.title, skills: [], input: .choice,
                outcome: .correct))
        let bytes = try JSONEncoder().encode(original)
        try bytes.write(to: url)
        let state = AppState(storageOverride: folder)
        XCTAssertEqual(state.practiceState.schemaVersion, 15)
        XCTAssertEqual(state.history, original.history)
        XCTAssertEqual(state.journal, original.journal)
        XCTAssertEqual(state.learning, original.learning)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertTrue(state.save())
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("previous")), bytes)
        let saved = try JSONDecoder().decode(PracticeState.self, from: Data(contentsOf: url))
        XCTAssertEqual(saved.schemaVersion, 15)
        XCTAssertEqual(AppState(storageOverride: folder).practiceState, state.practiceState)
    }
    @MainActor func testFuturePracticeSnapshotIsNotReplacedByLegacyFallback() throws {
        let folder = try fixture()
        let url = folder.appendingPathComponent("practice-state.json")
        let data = Data(#"{"schemaVersion":99,"unknown":"future music"}"#.utf8)
        try data.write(to: url)
        try JSONEncoder().encode(PracticeProgress()).write(to: folder.appendingPathComponent("practice.json"))
        let state = AppState(storageOverride: folder)
        state.save()
        XCTAssertNotNil(state.journalStorageError)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
    @MainActor func testOneInvalidScoreIsPreservedAlongsideValidScores() throws {
        let folder = try fixture()
        let url = folder.appendingPathComponent("editor.json")
        var library = EditorLibrary()
        library.documents[1].tempo = 0
        let original = try JSONEncoder().encode(library)
        try original.write(to: url)
        let state = AppState(storageOverride: folder)
        XCTAssertTrue(state.editor.documents.isEmpty)
        state.newLibraryComposition(.piano)
        state.save()
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertNotNil(state.editorStorageError)
    }
    @MainActor func testRenameKeepsPathwayUsableAcrossRestartAndUndoRestoresMusicRevision() throws {
        let folder = try fixture()
        let state = AppState(storageOverride: folder)
        let piece = LibraryPiece(source: .score(state.editor.active))
        let snapshot = try PieceSnapshot(piece: piece, from: 0, through: 3)
        let path = try PiecePathwayFactory.make(
            piece: piece, snapshot: snapshot, record: state.pieceRecord(piece), profile: state.learning.profile)
        try state.savePiecePathway(path)
        state.editor.documents[0].title = "Renamed composition"
        XCTAssertTrue(state.pathwayCurrent(path))
        state.save()
        let reopened = AppState(storageOverride: folder)
        XCTAssertTrue(reopened.pathwayCurrent(reopened.learning.pathways[0]))
        var edits = EditorSession()
        let changed = try edits.edit(state.editor.active) { try $0.setPitch($0.events[0].id, midi: 61) }
        state.editor.replace(changed)
        XCTAssertFalse(state.pathwayCurrent(path))
        state.editor.replace(try XCTUnwrap(edits.undo(changed)))
        XCTAssertTrue(state.pathwayCurrent(path))
    }
    @MainActor func testExistingPieceAndLibraryIntegrationChecks() async throws {
        let folder = try fixture()
        let piece = try PiecePathwayChecks.verify(directory: folder.appendingPathComponent("pathways"))
        for (name, passed) in piece { XCTAssertTrue(passed, name) }
        let library = try await LibraryChecks.verify(directory: folder.appendingPathComponent("library"))
        for (name, passed) in library { XCTAssertTrue(passed, name) }
    }
    @MainActor func testLocalSaveRetryDoesNotRepeatRequestAndCancellationRejectsLateReply() async throws {
        let session = SavedRequest<String>()
        var calls = 0
        let failure = WriteFailure()
        var saved: [String] = []
        session.run(
            request: {
                calls += 1
                return "paid reply"
            },
            commit: { value in
                if failure.enabled { throw CocoaError(.fileWriteOutOfSpace) }
                saved.append(value)
            })
        while session.busy { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(session.pending, "paid reply")
        XCTAssertNotNil(session.error)
        failure.enabled = false
        session.retrySave()
        session.retrySave()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(saved, ["paid reply"])
        XCTAssertNil(session.pending)
        session.run(
            request: {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return "late reply"
            }, commit: { saved.append($0) })
        await Task.yield()
        session.cancel()
        try await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(saved, ["paid reply"])
        XCTAssertNil(session.pending)
    }
}
