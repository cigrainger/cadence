// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class ReliabilityTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testStoreCannotOverwriteUnreadableOrFutureData() throws {
        for bytes in [
            Data("broken".utf8), Data(#"{"schemaVersion":99,"documents":[],"engine":"OpenSheetMusicDisplay"}"#.utf8),
        ] {
            let url = try folder().appendingPathComponent("scores.json")
            try bytes.write(to: url)
            let store = JSONFileStore<EditorLibrary>(url: url, validate: { try $0.validated() })
            _ = store.load(default: EditorLibrary())
            XCTAssertNotNil(store.loadError)
            XCTAssertThrowsError(try store.save(EditorLibrary()))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }
    func testStoreKeepsPreviousGenerationAndRejectsExternalWriter() throws {
        let url = try folder().appendingPathComponent("scores.json")
        let store = JSONFileStore<EditorLibrary>(url: url, validate: { try $0.validated() })
        var value = store.load(default: EditorLibrary())
        try store.save(value)
        let first = try Data(contentsOf: url)
        value.documents[0].title = "Second version"
        try store.save(value)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("previous")), first)
        let external = Data("another application owns this change".utf8)
        try external.write(to: url)
        XCTAssertThrowsError(try store.save(value))
        XCTAssertEqual(try Data(contentsOf: url), external)
    }
    func testInterruptedAtomicCommitKeepsOldStateAndCanRetry() throws {
        let url = try folder().appendingPathComponent("practice.json")
        var fail = false
        let store = JSONFileStore<PracticeState>(
            url: url, validate: { try $0.validated() },
            write: { data, destination in
                if fail && destination == url { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: destination, options: .atomic)
            })
        var state = store.load(default: PracticeState())
        try store.save(state)
        let before = try Data(contentsOf: url)
        let question = QuestionFactory.deck(.functional, root: Pitch(0), scale: .major)[0]
        state.history.record(question, correct: true, firstTry: true, revealed: false)
        state.journal.append(
            PracticeAttempt(
                sessionID: UUID(), activityID: question.id, title: question.title, skills: [], input: .choice,
                outcome: .correct))
        fail = true
        XCTAssertThrowsError(try store.save(state))
        XCTAssertEqual(try Data(contentsOf: url), before)
        fail = false
        try store.save(state)
        let reopened = JSONFileStore<PracticeState>(url: url, validate: { try $0.validated() }).load(
            default: PracticeState())
        XCTAssertEqual(reopened, state)
    }
    func testPartiallyInvalidLibrariesRejectWholeSnapshot() throws {
        var editor = EditorLibrary()
        editor.documents[1].events[0].rhythm.base = Int.max
        XCTAssertThrowsError(try editor.restored())
        var studies = StudyLibrary()
        studies.add(
            MusicStudy(document: try StudyImport.read(Data(StudyExamples.smallSteps.utf8)), filename: "test.xml"))
        var invalid = studies.studies[0]
        invalid.id = UUID()
        invalid.document.parts[0].notes[0].duration = -1
        studies.add(invalid)
        XCTAssertThrowsError(try studies.restored())
        studies.studies.removeFirst()
        studies.schemaVersion = 99
        XCTAssertThrowsError(try studies.restored())
    }
    func testOldLibrarySchemasMigrateAndEmptyScoreLibraryStaysEmpty() throws {
        for old in [true, false] {
            var library = EditorLibrary()
            library.documents = []
            if old { library.schemaVersion = nil }
            let restored = try JSONDecoder().decode(EditorLibrary.self, from: JSONEncoder().encode(library)).restored()
            XCTAssertTrue(restored.documents.isEmpty)
            XCTAssertEqual(restored.schemaVersion, 1)
        }
    }
    func testRenameDoesNotInvalidateMusicButNotesRhythmAndSourceMapDo() throws {
        var score = EditorDocument.guitarExample
        let initial = LibraryPiece(source: .score(score)).fingerprint
        score.title = "A new title & credit"
        XCTAssertEqual(initial, LibraryPiece(source: .score(score)).fingerprint)
        try score.setPitch(score.events[0].id, midi: 61)
        XCTAssertNotEqual(initial, LibraryPiece(source: .score(score)).fingerprint)
        score = .guitarExample
        try score.setRhythm(score.events[0].id, EditorRhythm(240))
        XCTAssertNotEqual(initial, LibraryPiece(source: .score(score)).fingerprint)
        score = .guitarExample
        score.pdfSource = PDFScoreSource(filename: "source.pdf", page: 1, model: "test")
        XCTAssertNotEqual(initial, LibraryPiece(source: .score(score)).fingerprint)
        let firstPage = LibraryPiece(source: .score(score)).fingerprint
        score.pdfSource?.page = 2
        XCTAssertNotEqual(firstPage, LibraryPiece(source: .score(score)).fingerprint)
    }
    func testStudyRevisionIgnoresMetadataButRetainsMusicalMarkup() {
        let xml = StudyExamples.smallSteps
        let renamed = xml.replacingOccurrences(of: "Small steps", with: "Renamed study")
        XCTAssertNotEqual(xml, renamed)
        XCTAssertEqual(
            ScoreRevision.fingerprint(xml: xml, sourceMap: ""), ScoreRevision.fingerprint(xml: renamed, sourceMap: ""))
        XCTAssertNotEqual(
            ScoreRevision.fingerprint(xml: xml, sourceMap: ""),
            ScoreRevision.fingerprint(
                xml: xml.replacingOccurrences(of: "<step>C</step>", with: "<step>D</step>"), sourceMap: ""))
    }
    func testLegacyRevisionMigrationPreservesCurrentAndStaleHistories() throws {
        let piece = LibraryPiece(source: .score(.guitarExample))
        let snapshot = try PieceSnapshot(piece: piece, from: 0, through: 3)
        var path = try PiecePathwayFactory.make(
            piece: piece, snapshot: snapshot, record: PieceRecord(kind: .composition), profile: LearnerProfile())
        path.piecePractice!.fingerprint = piece.legacyFingerprint
        path.piecePractice!.tasks[0].review.record(.good, episode: UUID(), input: .choice)
        var stale = path
        stale.id = UUID()
        stale.piecePractice!.fingerprint = String(repeating: "a", count: 64)
        var learning = LearningLibrary()
        learning.add(path)
        learning.add(stale)
        var notebook = PieceNotebook()
        var record = PieceRecord(kind: .composition)
        let outline = PieceAnalysisOutline(
            summary: "A short phrase",
            observations: [PieceObservation(title: "Melody", detail: "Follow the notes", fromBar: 1, throughBar: 2)],
            practice: [
                PiecePracticeStep(
                    title: "Read", instructions: "Play slowly", readyWhen: "Comfortable", fromBar: 1, throughBar: 2)
            ], caveats: [])
        var analysis = SavedPieceAnalysis(snapshot: snapshot, model: "test", goal: "Read", outline: outline)
        analysis.fingerprint = piece.legacyFingerprint
        var exchange = PieceExchange(
            snapshot: snapshot, model: "test", question: "Where to start?", answer: "Read bar one slowly.")
        exchange.fingerprint = piece.legacyFingerprint
        var oldAnalysis = analysis
        oldAnalysis.id = UUID()
        oldAnalysis.fingerprint = String(repeating: "b", count: 64)
        record.analyses = [analysis, oldAnalysis]
        record.conversation = [exchange]
        notebook.records[piece.id] = record
        ScoreRevision.migrate(learning: &learning, notebook: &notebook, pieces: [piece])
        XCTAssertEqual(learning.pathways[1].piecePractice!.fingerprint, piece.fingerprint)
        XCTAssertEqual(learning.pathways[1].piecePractice!.tasks[0].review, path.piecePractice!.tasks[0].review)
        XCTAssertEqual(learning.pathways[0], stale)
        XCTAssertEqual(notebook.records[piece.id]?.analyses[0].fingerprint, piece.fingerprint)
        XCTAssertEqual(notebook.records[piece.id]?.analyses[0].outline, outline)
        XCTAssertEqual(notebook.records[piece.id]?.analyses[1], oldAnalysis)
        XCTAssertEqual(notebook.records[piece.id]?.conversation[0].fingerprint, piece.fingerprint)
        XCTAssertEqual(notebook.records[piece.id]?.conversation[0].answer, exchange.answer)
        XCTAssertNoThrow(try learning.validated())
        XCTAssertNoThrow(try notebook.validated())
    }
    func testImmediateRevisitsUseSamePolicyInBothPracticeModes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let question = QuestionFactory.deck(.functional, root: Pitch(0), scale: .major)[0]
        var history = PracticeProgress()
        var piece = ReviewSchedule()
        for _ in 0..<100 {
            let episode = UUID()
            history.record(question, correct: true, firstTry: true, revealed: false, now: now, episode: episode)
            piece.record(.good, episode: episode, input: .choice, now: now)
        }
        XCTAssertEqual(history.cards[question.id]?.schedule, piece)
        XCTAssertEqual(piece.intervalDays, 1)
        XCTAssertEqual(piece.due, now.addingTimeInterval(86400))
    }
    func testRetryCannotEraseMissAndClockRollbackCannotAdvanceReview() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let episode = UUID()
        let question = QuestionFactory.deck(.functional, root: Pitch(0), scale: .major)[0]
        var history = PracticeProgress()
        history.record(question, correct: false, firstTry: true, revealed: false, now: now, episode: episode)
        history.record(
            question, correct: true, firstTry: false, revealed: false, now: now.addingTimeInterval(5), episode: episode)
        XCTAssertEqual(history.cards[question.id]?.schedule?.lastGrade, .again)
        XCTAssertEqual(history.cards[question.id]?.due, now.addingTimeInterval(600))
        history.record(
            question, correct: true, firstTry: true, revealed: false, now: now.addingTimeInterval(-100 * 86400))
        XCTAssertEqual(history.cards[question.id]?.due, now.addingTimeInterval(600))
        XCTAssertNoThrow(try history.validated())
        history.record(question, correct: true, firstTry: true, revealed: false, now: now.addingTimeInterval(-1000))
        XCTAssertEqual(history.cards[question.id]?.schedule?.intervalDays, 0)
        XCTAssertEqual(history.cards[question.id]?.due, now.addingTimeInterval(600))
    }
    func testLegacyReviewRetainsCountsDueAndDoesNotJumpOnEarlyPractice() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let question = QuestionFactory.deck(.functional, root: Pitch(0), scale: .major)[0]
        var card = ReviewCard()
        card.correct = 8
        card.misses = 2
        card.interval = 7 * 86400
        card.due = now.addingTimeInterval(86400)
        var history = PracticeProgress()
        history.correct = 8
        history.attempts = 10
        history.cards[question.id] = card
        history = try JSONDecoder().decode(PracticeProgress.self, from: JSONEncoder().encode(history))
        history.record(question, correct: true, firstTry: true, revealed: false, now: now)
        XCTAssertEqual(history.cards[question.id]?.correct, 9)
        XCTAssertEqual(history.cards[question.id]?.misses, 2)
        XCTAssertEqual(history.cards[question.id]?.due, card.due)
        XCTAssertEqual(history.cards[question.id]?.schedule?.intervalDays, 7)
    }
    func testGlobalAndPieceQueueShareMissPriorityAndMixing() {
        let now = Date()
        var old = ReviewSchedule()
        var missed = ReviewSchedule()
        old.record(.good, episode: UUID(), input: .choice, now: now.addingTimeInterval(-172800))
        missed.record(.again, episode: UUID(), input: .midi, now: now.addingTimeInterval(-700))
        let queue = ReviewQueue.ordered([(0, old), (1, ReviewSchedule()), (2, missed)], now: now, review: { $0.1 }) {
            $0.0 < $1.0
        }
        XCTAssertEqual(queue.map(\.0), [2, 0, 1])
    }
    func testEditorHistoryRejectsFailedEditsAndInvalidatesRedoOnNewBranch() throws {
        var session = EditorSession()
        var doc = EditorDocument.pianoExample
        let original = doc
        XCTAssertThrowsError(try session.edit(doc) { $0.events.removeAll() })
        XCTAssertFalse(session.canUndo)
        doc = try session.edit(doc) { $0.title = "Renamed" }
        let renamed = doc
        doc = try XCTUnwrap(session.undo(doc))
        XCTAssertEqual(doc, original)
        doc = try XCTUnwrap(session.redo(doc))
        XCTAssertEqual(doc, renamed)
        doc = try XCTUnwrap(session.undo(doc))
        doc = try session.edit(doc) { try $0.setPitch($0.events[0].id, midi: 62) }
        XCTAssertFalse(session.canRedo)
        XCTAssertNotEqual(doc, original)
    }
    func testEditorUndoCannotOverwriteExternalPageReplacementOrAnotherScore() throws {
        var session = EditorSession()
        var doc = EditorDocument.pianoExample
        doc = try session.edit(doc) { $0.title = "Renamed" }
        doc.tempo += 1
        XCTAssertNil(session.undo(doc))
        XCTAssertFalse(session.canUndo)
        XCTAssertNil(session.redo(.guitarExample))
    }
    func testSeededEditorSequencesPreserveExactUndoAndScoreValidity() throws {
        var seed: UInt64 = 17
        var session = EditorSession()
        var doc = EditorDocument.pianoExample
        for _ in 0..<80 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            let index = Int(seed % UInt64(doc.events.count))
            let original = doc
            let midi = 48 + Int((seed >> 16) % 36)
            doc = try session.edit(doc) { try $0.setPitch($0.events[index].id, midi: midi) }
            XCTAssertNoThrow(try doc.validated())
            if doc != original {
                let changed = doc
                doc = try XCTUnwrap(session.undo(doc))
                XCTAssertEqual(doc, original)
                doc = try XCTUnwrap(session.redo(doc))
                XCTAssertEqual(doc, changed)
            }
        }
    }
    func testSharedProviderPrivacyAndErrorRedaction() throws {
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(OpenRouterPrivacy())) as? NSDictionary
        XCTAssertEqual(encoded, OpenRouterTransport.privacy as NSDictionary)
        XCTAssertEqual(encoded?["zdr"] as? Bool, true)
        XCTAssertEqual(encoded?["data_collection"] as? String, "deny")
        XCTAssertEqual(encoded?["allow_fallbacks"] as? Bool, false)
        XCTAssertEqual(encoded?["require_parameters"] as? Bool, true)
        let failure = OpenRouterTransport.failure(
            status: 401, detail: "Rejected test-secret-key", key: "test-secret-key")
        XCTAssertFalse(failure.localizedDescription.contains("test-secret-key"))
        XCTAssertTrue(failure.localizedDescription.contains("[redacted]"))
    }
}
