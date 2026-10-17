// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

@testable import Cadence

final class CreativeIntegrationTests: XCTestCase {
    @MainActor func prepared(review: Bool = true) throws -> (AppState, ScoreEarMaterial, UUID) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let state = AppState(storageOverride: folder)
        let doc = try ScoreEarChecks.document()
        addTeardownBlock {
            await MainActor.run {
                state.midi.shutdown()
                state.audio.stop()
            }
            try? FileManager.default.removeItem(at: folder)
        }
        state.editor.documents.append(doc)
        XCTAssertTrue(state.save())
        let m = try ScoreEarChecks.material(doc)
        try state.openScoreEar(m)
        if review {
            for kind: EarEvent.Kind in [.heard, .imagined, .answer, .next, .answer, .next] {
                try state.saveScoreEarEvent(
                    .init(
                        expected: try XCTUnwrap(state.scoreEarPractice.active),
                        event: .init(kind, skipped: kind == .answer)))
            }
        }
        return (state, m, try XCTUnwrap(state.scoreEarPractice.selectedID))
    }
    @MainActor func testCreationResumesSameCompositionAfterRestartWithoutGrading() throws {
        let (state, m, id) = try prepared()
        let before = state.practiceState
        let scoreID = try state.openCreativeAnswer(id)
        XCTAssertEqual(try state.openCreativeAnswer(id), scoreID)
        XCTAssertEqual(state.practiceState, before)
        XCTAssertEqual(state.editor.documents.filter { $0.responseSource != nil }.count, 1)
        let answer = try XCTUnwrap(state.creativeAnswer(m.id))
        XCTAssertEqual(state.pieceRecord(LibraryPiece(source: .score(answer))).kind, .composition)
        XCTAssertEqual(answer.responseSource?.material, m)
        XCTAssertTrue(state.editorPassageFocus?.wholePiece == true)
        let restored = AppState(storageOverride: state.storage)
        defer { restored.midi.shutdown() }
        XCTAssertEqual(try restored.openCreativeAnswer(id), scoreID)
    }
    @MainActor func testDraftCreationSaveFailureDoesNotPublishOrDuplicate() throws {
        let (state, _, id) = try prepared()
        let before = state.editor
        let url = state.stores.editor.url
        let bytes = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try state.openCreativeAnswer(id))
        XCTAssertEqual(state.editor, before)
        try FileManager.default.removeItem(at: url)
        try bytes.write(to: url)
        let first = try state.openCreativeAnswer(id)
        XCTAssertEqual(try state.openCreativeAnswer(id), first)
    }
    @MainActor func testFinishRequiresNotesAndLatestHeardRevisionAndSurvivesMissingSource() throws {
        let (state, m, id) = try prepared()
        let scoreID = try state.openCreativeAnswer(id)
        XCTAssertThrowsError(
            try state.finishCreativeAnswer(
                scoreID, listenedFingerprint: LibraryPiece(source: .score(state.editor.active)).fingerprint))
        var answer = state.editor.active
        try answer.setPitch(answer.events[0].id, midi: 64)
        state.editor.replace(answer)
        let fingerprint = LibraryPiece(source: .score(answer)).fingerprint
        XCTAssertThrowsError(try state.finishCreativeAnswer(scoreID, listenedFingerprint: "wrong"))
        try state.finishCreativeAnswer(scoreID, listenedFingerprint: fingerprint)
        XCTAssertTrue(try XCTUnwrap(state.editor.active.responseSource).isFinished(state.editor.active))
        state.editor.documents.removeAll { "score:" + $0.id.uuidString == m.pieceID }
        XCTAssertEqual(try state.openCreativeAnswer(id), scoreID)
        answer = state.editor.active
        try answer.setPitch(answer.events[0].id, midi: 65)
        state.editor.replace(answer)
        XCTAssertFalse(try XCTUnwrap(answer.responseSource).isFinished(answer))
        XCTAssertThrowsError(try state.finishCreativeAnswer(scoreID, listenedFingerprint: fingerprint))
    }
    @MainActor func testFinishSaveFailureKeepsDraftAndCanRetry() throws {
        let (state, _, id) = try prepared()
        let scoreID = try state.openCreativeAnswer(id)
        var answer = state.editor.active
        try answer.setPitch(answer.events[0].id, midi: 60)
        state.editor.replace(answer)
        let fingerprint = LibraryPiece(source: .score(answer)).fingerprint
        let url = state.stores.editor.url
        let bytes = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try state.finishCreativeAnswer(scoreID, listenedFingerprint: fingerprint))
        XCTAssertNil(state.editor.active.responseSource?.savedAt)
        try FileManager.default.removeItem(at: url)
        try bytes.write(to: url)
        try state.finishCreativeAnswer(scoreID, listenedFingerprint: fingerprint)
        let restored = AppState(storageOverride: state.storage)
        defer { restored.midi.shutdown() }
        let saved = try XCTUnwrap(restored.editor.documents.first { $0.id == scoreID })
        XCTAssertTrue(saved.responseSource?.isFinished(saved) == true)
    }
    @MainActor func testOpeningAndChangedSourceCannotCreateAnAnswer() throws {
        let (state, _, id) = try prepared(review: false)
        XCTAssertThrowsError(try state.openCreativeAnswer(id))
        XCTAssertNil(state.editor.active.responseSource)
        for kind: EarEvent.Kind in [.heard, .imagined, .answer, .next, .answer, .next] {
            try state.saveScoreEarEvent(
                .init(
                    expected: try XCTUnwrap(state.scoreEarPractice.active), event: .init(kind, skipped: kind == .answer)
                ))
        }
        state.editor.documents[state.editor.documents.count - 1].tempo += 1
        XCTAssertThrowsError(try state.openCreativeAnswer(id))
    }
    @MainActor func testLibraryOpensFullScoreAndExplicitPassagesStillFocus() throws {
        let state = AppState(preview: true)
        defer { state.midi.shutdown() }
        var doc = try EditorDocument.blank(instrument: .piano, bars: 24)
        try doc.setPitch(doc.events[0].id, midi: 60)
        state.editor.documents.append(doc)
        state.openLibraryPiece(LibraryPiece(source: .score(doc)))
        XCTAssertEqual(state.editor.active.barCount, 24)
        XCTAssertTrue(state.editorPassageFocus?.wholePiece == true)
        state.openLibraryPiece(LibraryPiece(source: .score(doc)), from: 8, through: 11)
        XCTAssertFalse(state.editorPassageFocus?.wholePiece ?? true)
        XCTAssertEqual(state.editorPassageFocus?.from, 8)
        XCTAssertEqual(state.editorPassageFocus?.through, 11)
        let study = MusicStudy(
            document: try StudyImport.read(Data(EditorXML.encode(doc).utf8)), filename: "Piece.musicxml")
        state.studies.add(study)
        state.openLibraryPiece(LibraryPiece(source: .study(study)))
        XCTAssertTrue(state.studyWholePiece)
        state.openLibraryPiece(LibraryPiece(source: .study(study)), from: 12, through: 15)
        XCTAssertFalse(state.studyWholePiece)
        XCTAssertEqual(state.studies.active?.from, 12)
    }
    @MainActor func testStudyCompletionEvidenceRequiresNaturalEnd() async throws {
        let audio = AudioPlayer()
        defer { audio.stop() }
        let doc = try ScoreEarChecks.document()
        let study = MusicStudy(document: try StudyImport.read(Data(EditorXML.encode(doc).utf8)), filename: "Check")
        var plan = try StudyPlaybackPlan(study: study)
        plan.introBeats = 0
        plan.cycleBeats = 0.1
        plan.cycle.notes = []
        plan.cycle.tempo = 120
        audio.playStudy(plan, loop: false)
        let id = audio.playbackID
        for _ in 0..<150 {
            if audio.completedPlayback == id { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(audio.completedPlayback, id)
        XCTAssertFalse(audio.isPlaying)
        audio.playStudy(plan, loop: false)
        audio.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(audio.completedPlayback)
    }
}
