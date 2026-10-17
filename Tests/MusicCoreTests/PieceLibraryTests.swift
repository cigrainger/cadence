// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class PieceLibraryTests: XCTestCase {
    private var piece: LibraryPiece { LibraryPiece(source: .score(.guitarExample)) }
    private func snapshot(_ piece: LibraryPiece? = nil) throws -> PieceSnapshot {
        try PieceSnapshot(piece: piece ?? self.piece, from: 0, through: 3)
    }
    private var outline: PieceAnalysisOutline {
        PieceAnalysisOutline(
            summary: "A short reading study.",
            observations: [
                PieceObservation(title: "Pulse", detail: "Follow the quarter-note movement.", fromBar: 1, throughBar: 2)
            ],
            practice: [
                PiecePracticeStep(
                    title: "Play slowly", instructions: "Loop these bars at a comfortable tempo.",
                    readyWhen: "Keep an even pulse without tension.", fromBar: 1, throughBar: 2)
            ], caveats: ["This is symbolic notation, not a recording."])
    }
    func testCatalogSeparatesOriginsAndKeepsPracticeCopiesWithParent() throws {
        var score = EditorDocument.guitarExample
        score.pdfSource = PDFScoreSource(filename: "Book.pdf", page: 2, model: "test")
        let copy = try ComposePractice.make(score, from: 0, through: 3)
        let xml = MusicStudy(
            document: try StudyImport.read(Data(StudyExamples.smallSteps.utf8)), filename: "Imported.musicxml")
        let items = LibraryPiece.catalog(scores: [score], studies: [copy, xml])
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items.allSatisfy { $0.defaultKind == .sheetMusic })
        XCTAssertEqual(LibraryPiece.catalog(scores: [], studies: [copy, xml]).count, 2)
        for example in [EditorDocument.guitarExample, .pianoExample, .fingerstyleExample, .innerVoiceExample] {
            XCTAssertEqual(LibraryPiece(source: .score(example)).defaultKind, .example)
        }
        var own = try EditorDocument.blank(instrument: .piano)
        own.title = "My idea"
        XCTAssertEqual(LibraryPiece(source: .score(own)).defaultKind, .composition)
    }
    func testReconciliationIsStableAndKeepsNotesAndClassification() throws {
        let piece = piece
        var library = PieceNotebook()
        library.reconcile([piece])
        library.records[piece.id]!.kind = .composition
        library.records[piece.id]!.notes = "Practise gently"
        let before = library
        library.reconcile([piece])
        XCTAssertEqual(library, before)
        let reopened = try JSONDecoder().decode(PieceNotebook.self, from: JSONEncoder().encode(library)).validated()
        XCTAssertEqual(reopened, before)
        library.reconcile([])
        XCTAssertEqual(library, before)
        library.schemaVersion = 99
        XCTAssertThrowsError(try library.validated())
    }
    func testNotebookRejectsInvalidDataWithoutSilentlyDiscardingHistory() throws {
        let id = piece.id
        var notebook = PieceNotebook()
        notebook.records[id] = PieceRecord(kind: .composition)
        notebook.records[id]!.notes = String(repeating: "x", count: 5001)
        XCTAssertThrowsError(try notebook.validated())
        notebook.records = ["invalid-key": PieceRecord(kind: .composition)]
        XCTAssertThrowsError(try notebook.validated())
    }
    func testFingerprintSurvivesIdentityChangesButTracksMusicOutsidePassage() throws {
        var score = EditorDocument.guitarExample
        let hash = LibraryPiece(source: .score(score)).fingerprint
        score.id = UUID()
        XCTAssertEqual(hash, LibraryPiece(source: .score(score)).fingerprint)
        try score.setPitch(score.events.last!.id, midi: 66)
        XCTAssertNotEqual(hash, LibraryPiece(source: .score(score)).fingerprint)
        var original = EditorDocument.guitarExample
        original.pdfSource = PDFScoreSource(filename: "x.pdf", page: 1, model: "test")
        let before = LibraryPiece(source: .score(original)).fingerprint
        original.pdfSource?.reviewed = true
        XCTAssertEqual(before, LibraryPiece(source: .score(original)).fingerprint)
    }
    func testSnapshotCarriesExactScopeInstrumentAndPartialPDFStatus() throws {
        var score = EditorDocument.guitarExample
        var source = PDFScoreSource(filename: "book.pdf", page: 5, model: "test")
        source.pages = [PDFImportPage(page: 5, model: "test"), PDFImportPage(page: 6, model: "test")]
        source.pages![0].barCount = 4
        source.pages![0].status = .ready
        source.pages![1].status = .failed
        score.pdfSource = source
        let snapshot = try PieceSnapshot(piece: LibraryPiece(source: .score(score)), from: 1, through: 2)
        XCTAssertEqual(snapshot.scope.fromBar, 2)
        XCTAssertEqual(snapshot.scope.throughBar, 3)
        XCTAssertTrue(snapshot.context.contains("PDF page 6: MISSING"))
        XCTAssertTrue(snapshot.context.contains("original PDF is NOT included"))
        XCTAssertTrue(snapshot.context.contains("Tuning (low to high sounding MIDI)"))
        XCTAssertThrowsError(try PieceSnapshot(piece: piece, from: 0, through: 4))
        XCTAssertThrowsError(try PieceSnapshot(piece: piece, from: -1, through: 2))
    }
    func testEmptyDraftCannotBeAnalysed() throws {
        var score = try EditorDocument.blank(instrument: .guitar, bars: 1)
        var source = PDFScoreSource(filename: "book.pdf", page: 1, model: "test")
        source.pages = [PDFImportPage(page: 1, model: "test")]
        score.pdfSource = source
        XCTAssertThrowsError(try PieceSnapshot(piece: LibraryPiece(source: .score(score)), from: 0, through: 0))
    }
    func testAnalysisRejectsInventedBarLinksAndIncompleteReplies() throws {
        let snap = try snapshot()
        let text = String(decoding: try JSONEncoder().encode(outline), as: UTF8.self)
        XCTAssertEqual(try PieceAnalysisOutline.decode("```json\n" + text + "\n```", scope: snap.scope), outline)
        var invalid = outline
        invalid.practice[0].throughBar = 5
        XCTAssertThrowsError(try invalid.validated(scope: snap.scope))
        invalid = outline
        invalid.observations[0].fromBar = 0
        XCTAssertThrowsError(try invalid.validated(scope: snap.scope))
        invalid = outline
        invalid.practice = []
        XCTAssertThrowsError(try invalid.validated(scope: snap.scope))
        XCTAssertThrowsError(try PieceAnalysisOutline.decode("{\"summary\":\"only a summary\"}", scope: snap.scope))
    }
    func testAnalysisRequestIsScopedZDRAndSavesReturnedModelWithoutPDF() async throws {
        let snap = try snapshot()
        let answer = String(decoding: try JSONEncoder().encode(outline), as: UTF8.self)
        let calls = RequestProbe()
        var record = PieceRecord(kind: .composition)
        record.goal = "Even pulse"
        let client = CoachClient { request in
            await calls.sent()
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            XCTAssertEqual(payload["model"] as? String, "chosen/model")
            XCTAssertEqual((payload["provider"] as? [String: Any])?["zdr"] as? Bool, true)
            let body = String(decoding: request.httpBody!, as: UTF8.self)
            XCTAssertTrue(body.contains("Even pulse"))
            XCTAssertTrue(body.contains("bar 1"))
            XCTAssertFalse(body.contains("secret"))
            XCTAssertFalse(body.contains("file_data"))
            return (
                try JSONSerialization.data(withJSONObject: [
                    "choices": [["message": ["content": answer], "finish_reason": "stop"]]
                ]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let result = try await PieceCoach(client: client).analyse(
            snapshot: snap, record: record, apiKey: "secret", model: "chosen/model")
        await calls.assertCount(1)
        XCTAssertEqual(result.outline, outline)
        XCTAssertEqual(result.fingerprint, snap.fingerprint)
        XCTAssertEqual(result.model, "chosen/model")
    }
    func testCoachExcludesOldScopeAndOldScoreConversation() async throws {
        let snap = try snapshot()
        var record = PieceRecord(kind: .composition)
        let current = PieceExchange(
            snapshot: snap, model: "test", question: "Current question", answer: "Current answer")
        var old = current
        old.id = UUID()
        old.fingerprint = String(repeating: "0", count: 64)
        old.question = "STALE QUESTION"
        var other = current
        other.id = UUID()
        other.scope.fromBar = 2
        other.question = "OTHER PASSAGE"
        record.conversation = [old, other, current]
        record.analyses = [SavedPieceAnalysis(snapshot: snap, model: "test", goal: "", outline: outline)]
        let client = CoachClient { request in
            let body = String(decoding: request.httpBody!, as: UTF8.self)
            XCTAssertTrue(body.contains("Current question"))
            XCTAssertTrue(body.contains("Earlier AI interpretation"))
            XCTAssertFalse(body.contains("STALE QUESTION"))
            XCTAssertFalse(body.contains("OTHER PASSAGE"))
            return (
                try JSONSerialization.data(withJSONObject: [
                    "choices": [["message": ["content": "Try a slower pulse."], "finish_reason": "stop"]]
                ]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let response = try await PieceCoach(client: client).ask(
            "How?", snapshot: snap, record: record, apiKey: "test", model: "test")
        XCTAssertEqual(response.question, "How?")
        XCTAssertEqual(response.scope, snap.scope)
    }
    func testCoachDeadlineCancelsActiveTransportWithoutRetry() async throws {
        let calls = RequestProbe()
        let client = CoachClient(deadline: 0.04) { _ in
            await calls.sent()
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw URLError(.badServerResponse)
            } catch {
                await calls.cancellation(Task.isCancelled)
                throw error
            }
        }
        do {
            _ = try await client.complete(messages: [], apiKey: "test", model: "test")
            XCTFail()
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("four minutes"))
        }
        await calls.assertCount(1)
        await calls.assertCancelled()
    }
}
