// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

@testable import Cadence

final class TensionIntegrationTests: XCTestCase {
    @MainActor func prepared(instrument: EditorInstrument = .piano) throws -> AppState {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let state = AppState(storageOverride: folder)
        addTeardownBlock {
            await MainActor.run {
                state.audio.stop()
                state.midi.shutdown()
            }
            try? FileManager.default.removeItem(at: folder)
        }
        try state.beginTensionExample(instrument: instrument)
        return state
    }
    @MainActor func play(_ notes: [Int], state: AppState) {
        var keys = MIDIKeyboardState()
        for note in notes {
            for message in [MIDIMessage.noteOn(channel: 0, note: note, velocity: 80), .noteOff(channel: 0, note: note)]
            {
                keys.receive(message)
                state.tensionInput.receive(.init(message: message, keyboard: keys), state: state)
            }
        }
    }
    @MainActor func testExampleAndSessionAreIdempotentAndRestore() throws {
        let state = try prepared()
        let id = state.tensionPractice.activeID
        try state.beginTensionExample(instrument: .piano)
        XCTAssertEqual(state.tensionPractice.activeID, id)
        XCTAssertEqual(state.tensionPractice.sessions.count, 1)
        XCTAssertEqual(state.editor.documents.filter { $0.id == (try? TensionSource.example().id) }.count, 1)
        let restored = AppState(storageOverride: state.storage)
        defer { restored.midi.shutdown() }
        XCTAssertEqual(restored.tensionPractice, state.tensionPractice)
    }
    @MainActor func testSaveFailureRetainsExactAnswerAndScheduleUntilRetry() throws {
        let state = try prepared()
        let before = state.practiceState
        let url = state.stores.practice.url
        let bytes = try Data(contentsOf: state.stores.practice.url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        state.tensionInput.submit(.skip, state: state)
        XCTAssertNotNil(state.tensionInput.pending)
        XCTAssertEqual(before, state.practiceState)
        try FileManager.default.removeItem(at: url)
        try bytes.write(to: url)
        state.tensionInput.save(state)
        state.tensionInput.save(state)
        XCTAssertNil(state.tensionInput.pending)
        XCTAssertEqual(state.journal.attempts.count, 1)
        XCTAssertEqual(state.tensionPractice.active?.skill, .explaining)
    }
    @MainActor func testChangedSourceRejectsPendingEvidenceAndReview() throws {
        let state = try prepared()
        let session = state.tensionPractice.active!
        let pending = TensionInput.Pending(expected: state.tensionPractice.active!, action: .skip)
        let i = state.editor.documents.firstIndex { "score:" + $0.id.uuidString == session.source.pieceID }!
        state.editor.documents[i].harmonies[0].symbol = try .parse("Am7")
        XCTAssertFalse(state.tensionCurrent(session.source))
        XCTAssertThrowsError(try state.saveTensionAction(pending))
        XCTAssertTrue(state.journal.attempts.isEmpty)
        XCTAssertThrowsError(try state.resumeTension(session.id, skill: .hearing))
    }
    @MainActor func testMIDIUsesTwoReleasedNotesAndStopsForPlaybackOrNavigation() throws {
        let state = try prepared()
        state.tensionInput.submit(.skip, state: state)
        state.tensionInput.submit(.skip, state: state)
        state.tensionInput.arm(state)
        play([73, 74], state: state)
        XCTAssertEqual(state.tensionPractice.active?.skill, .creating)
        XCTAssertEqual(state.journal.attempts.last?.input, .midi)
        XCTAssertEqual(state.journal.attempts.last?.outcome, .correct)
        try state.resumeTension(state.tensionPractice.active!.id, skill: .playing)
        state.tensionInput.arm(state)
        state.audio.isPlaying = true
        play([61, 62], state: state)
        XCTAssertFalse(state.tensionInput.listening)
        XCTAssertEqual(state.tensionPractice.active?.skill, .playing)
        state.audio.isPlaying = false
        state.tensionInput.arm(state)
        state.destination = .library
        play([61, 62], state: state)
        XCTAssertFalse(state.tensionInput.listening)
    }
    @MainActor func testAnalysisPersistsAlternativesWithoutChangingMusicAndRejectsStaleEditors() throws {
        let state = try prepared()
        let source = state.tensionPractice.active!.source
        let piece = state.libraryPieces.first { $0.id == source.pieceID }!
        var item = HarmonicAnnotation(
            anchor: source.changes[0],
            readings: [
                source.reading,
                .init(
                    roman: "VI7", function: .colour, convention: "Root relation",
                    explanation: "A different descriptive label"),
            ])
        try state.saveHarmonicReading(piece: piece, scope: source.scope, item: item, expected: nil)
        XCTAssertEqual(state.libraryPieces.first { $0.id == piece.id }?.fingerprint, piece.fingerprint)
        XCTAssertEqual(state.savedAnalysis(piece)?.annotations[0].readings.count, 2)
        item.readings[0].roman = "My edit"
        XCTAssertThrowsError(
            try state.saveHarmonicReading(piece: piece, scope: source.scope, item: item, expected: nil))
        let restored = AppState(storageOverride: state.storage)
        defer { restored.midi.shutdown() }
        XCTAssertEqual(restored.savedAnalysis(piece), state.savedAnalysis(piece))
    }
    @MainActor func testBlankEndingCannotCompleteAndSavedAnswerIsReopened() throws {
        let state = try prepared()
        for _ in 0..<3 { state.tensionInput.submit(.skip, state: state) }
        try state.openTensionEnding()
        let id = state.editor.activeID
        try state.openTensionEnding()
        XCTAssertEqual(state.editor.activeID, id)
        let session = state.tensionPractice.active!
        let pending = TensionInput.Pending(expected: session, action: .creation("I resolved the line."))
        XCTAssertThrowsError(try state.saveTensionAction(pending))
        var scores = state.editor
        let index = scores.documents.firstIndex { $0.id == id }!
        try scores.documents[index].setPitch(scores.documents[index].events[0].id, midi: 61)
        try state.commitScores(scores)
        let evidence = try state.saveTensionAction(pending)
        XCTAssertEqual(evidence?.scoreID, id)
        XCTAssertEqual(evidence?.input, .selfReport)
        XCTAssertTrue(state.tensionPractice.active!.completed)
        let restored = AppState(storageOverride: state.storage)
        defer { restored.midi.shutdown() }
        XCTAssertEqual(restored.editor.documents.first { $0.id == id }?.tensionSource, session.source)
    }
    @MainActor func testSeparateSkillReviewQueueRoutesAnIndependentAttempt() throws {
        let state = try prepared()
        for _ in 0..<4 { state.tensionInput.submit(.skip, state: state) }
        let future = Date().addingTimeInterval(1300)
        let items = state.practiceReviews(now: future).filter { $0.id.hasPrefix("tension:") }
        XCTAssertEqual(items.count, 4)
        XCTAssertTrue(state.practiceReviews().filter { $0.id.hasPrefix("tension:") }.isEmpty)
        let s = state.tensionPractice.active!
        try state.resumeTension(s.id, skill: .explaining)
        XCTAssertTrue(state.tensionPractice.active!.independent)
        XCTAssertFalse(state.tensionPractice.active!.assisted)
        state.tensionInput.submit(.explanation(0), state: state)
        XCTAssertTrue(state.tensionPractice.active!.completed)
        XCTAssertEqual(
            state.tensionPractice.active!.reviews[TheorySkill.hearing.rawValue], s.reviews[TheorySkill.hearing.rawValue]
        )
    }
    @MainActor func testUnreviewedPDFCannotSupplyAnalysisOrPractice() throws {
        let state = try prepared()
        var doc = try TensionSource.example()
        doc.id = UUID()
        doc.pdfSource = .init(filename: "Original.pdf", page: 1, model: "fixture")
        state.editor.documents.append(doc)
        let source = state.tensionPractice.active!.source
        let piece = LibraryPiece(source: .score(doc))
        XCTAssertThrowsError(
            try state.beginTension(piece: piece, scope: source.scope, tonic: source.tonic, instrument: .piano))
        XCTAssertThrowsError(
            try state.saveHarmonicReading(
                piece: piece, scope: source.scope, item: .init(anchor: source.changes[0], readings: [source.reading]),
                expected: nil))
    }
    @MainActor func testEditedExampleIsPreservedWhenStartingAOriginalLessonAgain() throws {
        let state = try prepared()
        let originalID = try TensionSource.example().id
        var scores = state.editor
        let index = scores.documents.firstIndex { $0.id == originalID }!
        scores.documents[index].harmonies[0].symbol = try .parse("Am7")
        try state.commitScores(scores)
        let count = state.editor.documents.count
        try state.beginTensionExample(instrument: .piano)
        XCTAssertEqual(state.editor.documents.count, count + 1)
        XCTAssertEqual(state.editor.documents.first { $0.id == originalID }?.harmonies[0].symbol.label, "Am7")
        XCTAssertNotEqual(state.tensionPractice.active?.source.pieceID, "score:" + originalID.uuidString)
        try state.beginTensionExample(instrument: .piano)
        XCTAssertEqual(state.editor.documents.count, count + 1)
    }

}
