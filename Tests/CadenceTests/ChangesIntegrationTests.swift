// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

@testable import Cadence

final class ChangesIntegrationTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    @MainActor private func prepare() throws -> AppState {
        let state = AppState(storageOverride: try folder())
        state.save()
        return state
    }
    @MainActor private func send(
        _ message: MIDIMessage, _ state: AppState, _ keys: inout MIDIKeyboardState, active: Bool = true
    ) {
        keys.receive(message)
        state.changesSession.receive(MIDIUpdate(message: message, keyboard: keys), state: state, active: active)
    }
    @MainActor private func gesture(_ notes: [Int], _ state: AppState, _ keys: inout MIDIKeyboardState) {
        for n in notes { send(.noteOn(channel: 0, note: n, velocity: 90), state, &keys) }
        for n in notes { send(.noteOff(channel: 0, note: n), state, &keys) }
    }
    @MainActor func testCompletePassPersistsMissesHintsAndOctaveDoublings() throws {
        let state = try prepare()
        let session = state.changesSession
        var keys = MIDIKeyboardState()
        try session.start(plan: .example, mode: .guides, held: [])
        session.listen(held: [])
        gesture([60], state, &keys)
        XCTAssertEqual(session.practice?.cursor, 0)
        session.reveal()
        gesture([53, 60, 72], state, &keys)
        gesture([53, 59], state, &keys)
        gesture([52, 59], state, &keys)
        XCTAssertTrue(session.practice?.finished == true)
        XCTAssertFalse(session.listening)
        let restored = AppState(storageOverride: state.storage)
        XCTAssertEqual(restored.journal.attempts.count, 4)
        XCTAssertEqual(restored.journal.attempts.map(\.outcome), [.incorrect, .correct, .correct, .correct])
        XCTAssertEqual(restored.journal.attempts.map(\.assisted), [false, true, false, false])
        XCTAssertEqual(restored.journal.attempts[1].ordinal, 2)
        XCTAssertEqual(Set(restored.journal.attempts.map(\.sessionID)).count, 1)
    }
    @MainActor func testFailedSaveRetainsExactAnswerAndDoesNotAdvanceOrDuplicate() throws {
        let state = try prepare()
        let session = state.changesSession
        var keys = MIDIKeyboardState()
        try session.start(plan: .example, mode: .roots, held: [])
        session.listen(held: [])
        let url = state.storage.appendingPathComponent("practice-state.json")
        let data = try Data(contentsOf: url)
        let before = state.practiceState
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        gesture([62], state, &keys)
        let pending = try XCTUnwrap(session.pending)
        XCTAssertEqual(session.practice?.cursor, 0)
        XCTAssertEqual(state.practiceState, before)
        XCTAssertFalse(session.listening)
        XCTAssertThrowsError(try session.start(plan: .example, mode: .guides, held: []))
        try FileManager.default.removeItem(at: url)
        try data.write(to: url)
        session.savePending(state: state)
        session.savePending(state: state)
        XCTAssertNil(session.pending)
        XCTAssertEqual(session.practice?.cursor, 1)
        XCTAssertEqual(state.journal.attempts, [pending])
        XCTAssertEqual(AppState(storageOverride: state.storage).journal.attempts, [pending])
    }
    @MainActor func testPauseFocusLossAndHeldKeysDoNotEnterGhostAnswers() throws {
        let state = try prepare()
        let session = state.changesSession
        var keys = MIDIKeyboardState()
        keys.receive(.noteOn(channel: 0, note: 62, velocity: 90))
        try session.start(plan: .example, mode: .roots, held: keys.downNotes)
        session.listen(held: keys.downNotes)
        send(.noteOff(channel: 0, note: 62), state, &keys)
        XCTAssertTrue(state.journal.attempts.isEmpty)
        send(.noteOn(channel: 0, note: 62, velocity: 90), state, &keys)
        send(.noteOff(channel: 0, note: 62), state, &keys, active: false)
        XCTAssertFalse(session.listening)
        XCTAssertTrue(state.journal.attempts.isEmpty)
        session.listen(held: [])
        gesture([62], state, &keys)
        XCTAssertEqual(session.practice?.cursor, 1)
        session.pause(held: [])
        gesture([67], state, &keys)
        XCTAssertEqual(session.practice?.cursor, 1)
    }
    @MainActor func testSustainDoesNotJoinAnswersAndPanicDoesNotGrade() throws {
        let state = try prepare()
        let session = state.changesSession
        var keys = MIDIKeyboardState()
        try session.start(plan: .example, mode: .guides, held: [])
        session.listen(held: [])
        send(.control(channel: 0, number: 64, value: 127), state, &keys)
        gesture([53, 60], state, &keys)
        gesture([53, 59], state, &keys)
        XCTAssertEqual(session.practice?.cursor, 2)
        send(.noteOn(channel: 0, note: 52, velocity: 90), state, &keys)
        send(.reset, state, &keys)
        XCTAssertEqual(state.journal.attempts.count, 2)
        gesture([52, 59], state, &keys)
        XCTAssertTrue(session.practice?.finished == true)
    }
    @MainActor func testOwnPieceLinksEvidenceAndStaleOrDeletedSourceIsRejected() throws {
        let state = try prepare()
        var doc = EditorDocument.leadSheetExample
        state.editor.documents.append(doc)
        let piece = LibraryPiece(source: .score(doc))
        let plan = try ChangesSource(piece: piece, from: 0, through: 1).plan(staff: 1)
        state.openChanges(plan)
        XCTAssertEqual(state.destination, .chords)
        XCTAssertTrue(state.showChanges)
        let session = state.changesSession
        var keys = MIDIKeyboardState()
        try session.start(plan: plan, mode: .guides, held: [])
        session.listen(held: [])
        gesture([53, 60], state, &keys)
        XCTAssertEqual(state.journal.attempts.last?.pieceID, piece.id)
        XCTAssertTrue(state.piecePracticeEvidence(piece).contains("untimed MIDI pitch collections"))
        doc.title = "Renamed"
        state.editor.replace(doc)
        XCTAssertNoThrow(try state.validateChangesPlan(plan))
        doc.harmonies[0].symbol = try ChordSymbol.parse("Am7")
        state.editor.replace(doc)
        XCTAssertThrowsError(try state.validateChangesPlan(plan))
        XCTAssertTrue(state.changesEvidence(LibraryPiece(source: .score(doc))).isEmpty)
        gesture([53, 59], state, &keys)
        XCTAssertEqual(state.journal.attempts.count, 1)
        XCTAssertFalse(session.listening)
        state.editor.documents.removeAll { $0.id == doc.id }
        XCTAssertThrowsError(try state.validateChangesPlan(plan))
    }
    @MainActor func testDiscardPendingAndReopenDoNotLoseCommittedHistory() throws {
        let state = try prepare()
        let session = state.changesSession
        var keys = MIDIKeyboardState()
        try session.start(plan: .example, mode: .roots, held: [])
        session.listen(held: [])
        gesture([62], state, &keys)
        state.openChanges()
        XCTAssertEqual(session.practice?.cursor, 1)
        XCTAssertFalse(session.listening)
        session.discardPending()
        XCTAssertNil(session.practice)
        XCTAssertEqual(state.journal.attempts.count, 1)
        try session.start(plan: .example, mode: .shells, held: [])
        XCTAssertEqual(session.practice?.cursor, 0)
    }
    @MainActor func testPracticeCopyResolvesToParentAndRejectsStaleMusic() throws {
        let state = try prepare()
        var doc = EditorDocument.leadSheetExample
        state.editor.documents.append(doc)
        let study = try ComposePractice.make(doc, from: 0, through: 1)
        state.studies.add(study)
        let plan = try state.changesSource(
            piece: LibraryPiece(source: .study(study)), from: 0, through: 1, partID: study.partID
        ).plan(staff: 1)
        XCTAssertEqual(plan.pieceID, LibraryPiece(source: .score(doc)).id)
        XCTAssertNoThrow(try state.validateChangesPlan(plan))
        doc.harmonies[0].symbol = try ChordSymbol.parse("Am7")
        state.editor.replace(doc)
        XCTAssertThrowsError(
            try state.changesSource(
                piece: LibraryPiece(source: .study(study)), from: 0, through: 1, partID: study.partID))
        state.openChanges()
        state.useChord(harmonize(root: Pitch(0), scale: .major)[0])
        XCTAssertFalse(state.showChanges)
    }
}
