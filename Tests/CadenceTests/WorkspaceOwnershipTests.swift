// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import MusicCore
import XCTest

@testable import Cadence

final class WorkspaceOwnershipTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func attempt(assisted: Bool = false) -> PracticeAttempt {
        PracticeAttempt(
            sessionID: UUID(), activityID: "interval", title: "Sing a third", skills: ["Hearing"],
            input: .singing, outcome: .correct, assisted: assisted, played: [60, 64], target: [60, 64])
    }

    @MainActor func testPracticeCommitPublishesOnceAndOnlyAfterDiskWrite() throws {
        let storage = WorkspaceStorage(directory: try folder())
        let owner = PracticeWorkspace(storage: storage)
        owner.load()
        var events = 0
        let observation = owner.objectWillChange.sink {
            events += 1
            XCTAssertTrue(FileManager.default.fileExists(atPath: storage.practice.url.path))
        }
        var copy = owner.state
        copy.journal.append(attempt())
        copy.smooth = SmoothPractice()
        copy.ear = EarPractice()
        copy.scoreEar = ScoreEarPractice()
        copy.rehearsal = PieceRehearsalBook()
        copy.pianoTakes = PianoTakeBook()
        copy.triads = TriadPractice()
        copy.tension = TensionPractice()
        copy.reharm = ReharmPractice()
        try owner.commit(copy)
        XCTAssertEqual(events, 1)
        let reopened = PracticeWorkspace(storage: WorkspaceStorage(directory: storage.directory))
        reopened.load()
        XCTAssertEqual(reopened.state, copy)
        withExtendedLifetime(observation) {}
    }

    @MainActor func testPracticeConflictCannotPublishRewardOrDiscardDraft() throws {
        let storage = WorkspaceStorage(directory: try folder())
        let owner = PracticeWorkspace(storage: storage)
        owner.load()
        try owner.save()
        let before = owner.state
        let otherBytes = Data("another process changed this".utf8)
        try otherBytes.write(to: storage.practice.url)
        var events = 0
        let observation = owner.objectWillChange.sink { events += 1 }
        let question = QuestionFactory.deck(.functional, root: Pitch(0), scale: .major)[0]
        XCTAssertThrowsError(
            try owner.record(attempt(), question: question, correct: true, firstTry: true, revealed: false))
        XCTAssertEqual(owner.state, before)
        XCTAssertEqual(events, 0)
        XCTAssertEqual(try Data(contentsOf: storage.practice.url), otherBytes)
        withExtendedLifetime(observation) {}
    }

    @MainActor func testPracticeInvalidInputAndFutureSchemaDoNotReachDisk() throws {
        let storage = WorkspaceStorage(directory: try folder())
        let owner = PracticeWorkspace(storage: storage)
        owner.load()
        let before = owner.state
        var invalid = attempt()
        invalid.played = [Int.max]
        XCTAssertThrowsError(try owner.record(invalid))
        let question = QuestionFactory.deck(.functional, root: Pitch(0), scale: .major)[0]
        XCTAssertThrowsError(
            try owner.record(invalid, question: question, correct: true, firstTry: true, revealed: false))
        var future = before
        future.schemaVersion = Int.max
        XCTAssertThrowsError(try owner.commit(future))
        XCTAssertEqual(owner.state, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.practice.url.path))
    }

    @MainActor func testPracticeCorruptionRemainsProtectedUntilReopened() throws {
        let storage = WorkspaceStorage(directory: try folder())
        let original = Data("{broken".utf8)
        try original.write(to: storage.practice.url)
        let owner = PracticeWorkspace(storage: storage)
        owner.load()
        XCTAssertNotNil(owner.loadError)
        XCTAssertThrowsError(try owner.record(attempt()))
        XCTAssertThrowsError(try owner.save())
        XCTAssertEqual(try Data(contentsOf: storage.practice.url), original)
    }

    @MainActor func testPracticeLegacyAndAssistedEvidenceSurviveRestart() throws {
        let dir = try folder()
        var old = PracticeState()
        old.schemaVersion = 1
        try JSONEncoder().encode(old).write(to: dir.appendingPathComponent("practice-state.json"))
        let owner = PracticeWorkspace(storage: WorkspaceStorage(directory: dir))
        owner.load()
        try owner.record(attempt(assisted: true))
        try owner.record(attempt())
        let reopened = PracticeWorkspace(storage: WorkspaceStorage(directory: dir))
        reopened.load()
        XCTAssertEqual(reopened.state.schemaVersion, 16)
        XCTAssertEqual(reopened.state.journal.attempts.map(\.assisted), [true, false])
        XCTAssertEqual(reopened.state.history.xp, 0)  // Recording evidence alone doesn't invent a reward.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("practice-state.json.previous").path))
    }

    @MainActor func testEphemeralOwnersValidateWithoutCreatingFiles() throws {
        let dir = try folder()
        let storage = WorkspaceStorage(directory: dir)
        let practice = PracticeWorkspace(storage: storage, ephemeral: true)
        let library = LibraryWorkspace(storage: storage, ephemeral: true)
        try practice.record(attempt())
        try practice.save()
        try library.addComposition(EditorDocument.blank(instrument: .piano))
        let piece = library.pieces.last!
        try library.changePiece(piece.id) { $0.notes = "Hear the bass" }
        try library.saveScores()
        try library.saveStudies()
        try library.saveNotebook()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        XCTAssertEqual(library.record(for: piece).notes, "Hear the bass")
    }

    @MainActor func testLibraryCompositionAndMetadataSurviveRestart() throws {
        let dir = try folder()
        let owner = LibraryWorkspace(storage: WorkspaceStorage(directory: dir))
        owner.load()
        let score = try EditorDocument.blank(instrument: .piano)
        try owner.addComposition(score)
        let piece = owner.pieces.first { $0.id == "score:" + score.id.uuidString }!
        XCTAssertEqual(owner.editor.activeID, score.id)
        XCTAssertEqual(owner.record(for: piece).kind, .composition)
        try owner.changePiece(piece.id) {
            $0.goal = "Connect the melody"
            $0.favorite = true
        }
        try owner.saveScores()
        try owner.saveStudies()
        try owner.saveNotebook()
        let reopened = LibraryWorkspace(storage: WorkspaceStorage(directory: dir))
        reopened.load()
        XCTAssertEqual(reopened.editor, owner.editor)
        XCTAssertEqual(reopened.studies, owner.studies)
        XCTAssertEqual(reopened.notebook, owner.notebook)
    }

    @MainActor func testLibraryMissingPieceCannotAcceptLateAnalysisEvenWithRetainedNotes() throws {
        let owner = LibraryWorkspace(storage: WorkspaceStorage(directory: try folder()))
        owner.load()
        let piece = owner.pieces.first!
        try owner.changePiece(piece.id) { $0.notes = "Keep these historical notes" }
        owner.editor.documents.removeAll()
        let before = owner.notebook
        XCTAssertThrowsError(try owner.changePiece(piece.id) { $0.notes = "Late AI reply" })
        XCTAssertThrowsError(try owner.changePiece("score:" + UUID().uuidString) { $0.favorite = true })
        XCTAssertEqual(owner.notebook, before)
    }

    @MainActor func testLibraryInvalidMetadataAndNotebookConflictKeepOldRecord() throws {
        let storage = WorkspaceStorage(directory: try folder())
        let owner = LibraryWorkspace(storage: storage)
        owner.load()
        let piece = owner.pieces.first!
        try owner.changePiece(piece.id) { $0.notes = "Original" }
        let before = owner.notebook
        XCTAssertThrowsError(try owner.changePiece(piece.id) { $0.notes = String(repeating: "x", count: 5001) })
        let foreign = Data("changed elsewhere".utf8)
        try foreign.write(to: storage.notebook.url)
        XCTAssertThrowsError(try owner.changePiece(piece.id) { $0.notes = "Replacement" })
        XCTAssertEqual(owner.notebook, before)
        XCTAssertEqual(try Data(contentsOf: storage.notebook.url), foreign)
    }

    @MainActor func testLibraryDamagedStoresRemainIndependentAndPreserved() throws {
        for filename in ["editor.json", "studies.json", "library.json"] {
            let dir = try folder()
            let original = Data("unreadable".utf8)
            let url = dir.appendingPathComponent(filename)
            try original.write(to: url)
            let owner = LibraryWorkspace(storage: WorkspaceStorage(directory: dir))
            owner.load()
            switch filename {
            case "editor.json":
                XCTAssertNotNil(owner.editorError)
                XCTAssertTrue(owner.editor.documents.isEmpty)
                XCTAssertThrowsError(try owner.addComposition(EditorDocument.blank(instrument: .guitar)))
                try owner.saveStudies()
            case "studies.json":
                XCTAssertNotNil(owner.studyError)
                XCTAssertThrowsError(try owner.saveStudies())
                try owner.saveScores()
            default:
                XCTAssertNotNil(owner.notebookError)
                XCTAssertThrowsError(try owner.changePiece(owner.pieces.first!.id) { $0.favorite = true })
                owner.reconcile()
                XCTAssertTrue(owner.notebook.records.isEmpty)
                XCTAssertThrowsError(try owner.saveNotebook())
                try owner.saveScores()
            }
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    @MainActor func testScoreLimitDuplicateIdentityAndWriteFailureDoNotSelectUnsavedComposition() throws {
        let storage = WorkspaceStorage(directory: try folder())
        let owner = LibraryWorkspace(storage: storage)
        owner.load()
        try owner.saveScores()
        let before = owner.editor
        XCTAssertThrowsError(try owner.addComposition(before.documents[0]))
        XCTAssertEqual(owner.editor, before)
        let bytes = try Data(contentsOf: storage.editor.url)
        try Data("external edit".utf8).write(to: storage.editor.url)
        XCTAssertThrowsError(try owner.addComposition(EditorDocument.blank(instrument: .piano)))
        XCTAssertEqual(owner.editor, before)
        try bytes.write(to: storage.editor.url)
        try owner.addComposition(EditorDocument.blank(instrument: .piano))
        owner.editor.documents = (0..<100).map { _ in
            var score = EditorDocument.guitarExample
            score.id = UUID()
            return score
        }
        XCTAssertThrowsError(try owner.addComposition(EditorDocument.blank(instrument: .piano)))
        XCTAssertEqual(owner.editor.documents.count, 100)
    }

    @MainActor func testFeatureBindingsStillNotifyAndPersistThroughTheOwners() throws {
        let dir = try folder()
        let state = AppState(storageOverride: dir)
        var events = 0
        let observation = state.objectWillChange.sink { events += 1 }
        state.editor.documents[0].title = "A visible edit"
        state.learning.profile.background = "Understand jazz harmony"
        XCTAssertGreaterThanOrEqual(events, 2)
        XCTAssertEqual(state.libraryWorkspace.editor.documents[0].title, "A visible edit")
        XCTAssertEqual(state.practiceWorkspace.state.learning.profile.background, "Understand jazz harmony")
        XCTAssertTrue(state.save())
        let reopened = AppState(storageOverride: dir)
        XCTAssertEqual(reopened.editor.documents[0].title, "A visible edit")
        withExtendedLifetime(observation) {}
    }
}
