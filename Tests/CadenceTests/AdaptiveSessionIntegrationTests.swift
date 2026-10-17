// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

@testable import Cadence

final class AdaptiveSessionIntegrationTests: XCTestCase {
    @MainActor private func prepared() throws -> AppState {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let state = AppState(storageOverride: folder)
        addTeardownBlock {
            await MainActor.run { state.midi.shutdown() }
            try? FileManager.default.removeItem(at: folder)
        }
        let url = PDFImportExamples.url("chapter").deletingLastPathComponent().appendingPathComponent("pathway.epub")
        let bytes = try Data(contentsOf: url)
        let song = BookAsset(data: bytes, filename: "Original.epub", epub: try EPUBDocument(data: bytes))
        let id = try state.installSmoothPathway(
            songAsset: song, jazzAsset: BookAsset(pdf: try CourseExamples.asset()), inversions: 1, songwriting: 2,
            jazzPage: 1)
        try state.openAdaptiveSession(id)
        return state
    }
    @MainActor private func gesture(_ notes: [Int], state: AppState) {
        var keys = MIDIKeyboardState()
        state.adaptiveInput.listen(held: [])
        for chord in [state.smoothPractice.active!.current!.from, notes] {
            for note in chord {
                let message = MIDIMessage.noteOn(channel: 0, note: note, velocity: 80)
                keys.receive(message)
                state.adaptiveInput.receive(.init(message: message, keyboard: keys), state: state, active: true)
            }
            for note in chord {
                let message = MIDIMessage.noteOff(channel: 0, note: note)
                keys.receive(message)
                state.adaptiveInput.receive(.init(message: message, keyboard: keys), state: state, active: true)
            }
        }
    }
    @MainActor private func finishPlaying(_ state: AppState) throws {
        while let s = state.smoothPractice.active, s.phase != .composition {
            if let prompt = s.current {
                if !s.awaitingAdvance { gesture(prompt.solutions[0], state: state) }
                try state.changeAdaptiveSession {
                    try $0.advance()
                    $0.suggestFocus()
                }
            } else {
                try state.changeAdaptiveSession { try $0.nextPhase() }
            }
        }
    }
    @MainActor func testStartingShapeMustBeObservedBeforeMIDIAnswer() throws {
        let state = try prepared()
        let before = try XCTUnwrap(state.smoothPractice.active)
        state.adaptiveInput.submit([60, 65, 69], state: state, input: .midi)
        XCTAssertTrue(state.journal.attempts.isEmpty)
        XCTAssertNotNil(state.adaptiveInput.error)
        XCTAssertThrowsError(
            try state.saveAdaptiveAnswer(.init(expected: before, notes: [60, 65, 69], input: .midi, skipped: false)))
        state.adaptiveInput.checkHeld([60, 64, 66], state: state)
        XCTAssertNil(state.adaptiveInput.verifiedFrom)
        state.adaptiveInput.checkHeld([60, 64, 67], state: state)
        XCTAssertEqual(state.adaptiveInput.verifiedFrom, [60, 64, 67])
        XCTAssertFalse(state.adaptiveInput.listening)
        state.adaptiveInput.checkHeld([60, 65, 69], state: state)
        XCTAssertEqual(state.journal.attempts.count, 1)
        XCTAssertEqual(state.journal.attempts[0].outcome, .correct)
        XCTAssertNil(state.adaptiveInput.verifiedFrom)
    }
    @MainActor func testInterruptionClearsStartingShapeAndHeldCheckDoesNotDoubleSubmit() throws {
        let state = try prepared()
        state.adaptiveInput.listen(held: [])
        state.adaptiveInput.checkHeld([60, 64, 67], state: state)
        let off = MIDIMessage.noteOff(channel: 0, note: 67)
        state.adaptiveInput.receive(.init(message: off, keyboard: MIDIKeyboardState()), state: state, active: true)
        XCTAssertTrue(state.journal.attempts.isEmpty)
        state.adaptiveInput.pause()
        XCTAssertNil(state.adaptiveInput.verifiedFrom)
        state.adaptiveInput.checkHeld([60, 65, 69], state: state)
        XCTAssertTrue(state.journal.attempts.isEmpty)
        gesture([60, 65, 69], state: state)
        XCTAssertEqual(state.journal.attempts.count, 1)
    }
    @MainActor func testSessionResumesAndDoesNotApproveBookOrAlterItsScore() throws {
        let state = try prepared()
        let id = try XCTUnwrap(state.smoothPractice.active).pathwayID
        let courses = state.courses
        let editor = state.editor
        gesture([60, 65, 69], state: state)
        XCTAssertEqual(state.smoothPractice.active?.responses.count, 1)
        XCTAssertEqual(state.journal.attempts.count, 1)
        XCTAssertEqual(state.courses, courses)
        XCTAssertEqual(state.editor, editor)
        XCTAssertTrue(state.courses.courses.allSatisfy { !$0.chapter.reviewed })
        let reopened = AppState(storageOverride: state.storage)
        defer { reopened.midi.shutdown() }
        XCTAssertEqual(reopened.smoothPractice, state.smoothPractice)
        try reopened.openAdaptiveSession(id)
        XCTAssertTrue(reopened.showAdaptiveSession)
        XCTAssertFalse(reopened.adaptiveInput.listening)
        XCTAssertEqual(reopened.smoothPractice.active?.id, state.smoothPractice.active?.id)
        XCTAssertThrowsError(try reopened.openAdaptiveSession(UUID()))
    }
    @MainActor func testSaveFailureRetainsSameAnswerAndCommitsAllOrNothing() throws {
        let state = try prepared()
        let before = state.practiceState
        let url = state.stores.practice.url
        let data = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        gesture([60, 65, 69], state: state)
        XCTAssertNotNil(state.adaptiveInput.pending)
        XCTAssertNotNil(state.adaptiveInput.error)
        XCTAssertEqual(state.practiceState, before)
        XCTAssertThrowsError(try state.changeAdaptiveSession { try $0.reveal() })
        let pendingID = state.adaptiveInput.pending!.id
        try FileManager.default.removeItem(at: url)
        try data.write(to: url)
        state.adaptiveInput.save(state: state)
        XCTAssertNil(state.adaptiveInput.pending)
        XCTAssertEqual(state.journal.attempts.first?.id, pendingID)
        XCTAssertEqual(state.smoothPractice.active?.responses.first?.id, pendingID)
        XCTAssertEqual(state.history.cards.count, 1)
        state.adaptiveInput.save(state: state)
        XCTAssertEqual(state.journal.attempts.count, 1)
        let reopened = AppState(storageOverride: state.storage)
        defer { reopened.midi.shutdown() }
        XCTAssertEqual(reopened.practiceState, state.practiceState)
    }
    @MainActor func testStaleAndDuplicatePendingAnswersCannotAdvanceAnotherPrompt() throws {
        let state = try prepared()
        let before = try XCTUnwrap(state.smoothPractice.active)
        let pending = AdaptiveSessionInput.Pending(
            expected: before, notes: [60, 65, 69], input: .midi, skipped: false, verifiedFrom: before.current!.from)
        try state.saveAdaptiveAnswer(pending)
        try state.saveAdaptiveAnswer(pending)
        XCTAssertEqual(state.journal.attempts.count, 1)
        try state.changeAdaptiveSession { try $0.advance() }
        var stale = pending
        stale.id = UUID()
        XCTAssertThrowsError(try state.saveAdaptiveAnswer(stale))
        XCTAssertEqual(state.journal.attempts.count, 1)
    }
    @MainActor func testFocusLossHeldKeysAndPanicDoNotSubmitPartialAnswer() throws {
        let state = try prepared()
        var keys = MIDIKeyboardState()
        let on = MIDIMessage.noteOn(channel: 0, note: 60, velocity: 80)
        keys.receive(on)
        state.adaptiveInput.listen(held: [60])
        state.adaptiveInput.receive(.init(message: on, keyboard: keys), state: state, active: true)
        let off = MIDIMessage.noteOff(channel: 0, note: 60)
        keys.receive(off)
        state.adaptiveInput.receive(.init(message: off, keyboard: keys), state: state, active: true)
        XCTAssertTrue(state.journal.attempts.isEmpty)
        keys.receive(on)
        state.adaptiveInput.receive(.init(message: on, keyboard: keys), state: state, active: false)
        XCTAssertFalse(state.adaptiveInput.listening)
        XCTAssertTrue(state.journal.attempts.isEmpty)
        state.adaptiveInput.listen(held: [])
        keys.receive(.reset)
        state.adaptiveInput.receive(.init(message: .reset, keyboard: keys), state: state, active: true)
        XCTAssertTrue(state.journal.attempts.isEmpty)
        gesture([60, 65, 69], state: state)
        XCTAssertEqual(state.journal.attempts.count, 1)
    }
    @MainActor func testRetryReviewAndScreenEvidenceRemainDistinct() throws {
        let state = try prepared()
        gesture([60, 64, 67], state: state)
        try state.changeAdaptiveSession { try $0.retry() }
        gesture([60, 65, 69], state: state)
        XCTAssertEqual(state.journal.attempts.map(\.outcome), [.incorrect, .correct])
        XCTAssertTrue(state.journal.attempts[1].assisted)
        XCTAssertEqual(state.history.cards.values.first?.review.lastGrade, .again)
        try state.changeAdaptiveSession { try $0.retry() }
        state.adaptiveInput.submit([60, 65, 69], state: state, input: .choice)
        XCTAssertEqual(state.journal.attempts.last?.input, .choice)
        XCTAssertEqual(state.history.cards.count, 2)
        XCTAssertTrue(state.history.cards.keys.contains { $0.hasSuffix(":midi") })
        XCTAssertTrue(state.history.cards.keys.contains { $0.hasSuffix(":choice") })
    }
    @MainActor func testCompositionFinishIsLinkedToSavedRevisionAndOptional() throws {
        let state = try prepared()
        try finishPlaying(state)
        XCTAssertEqual(state.smoothPractice.active?.independentTransferCount, 3)
        XCTAssertThrowsError(try state.finishAdaptiveSession(reflection: "No score", includeComposition: true))
        let id = try state.openPathwayComposition(state.smoothPractice.active!.pathwayID)
        XCTAssertThrowsError(try state.finishAdaptiveSession(reflection: "Blank", includeComposition: true))
        var score = state.editor.active
        score.events[0].pitches = [60, 65, 69].map { EditorPitch($0) }
        state.editor.replace(score)
        XCTAssertThrowsError(try state.finishAdaptiveSession(reflection: " ", includeComposition: true))
        try state.finishAdaptiveSession(reflection: "A common note connects the phrase.", includeComposition: true)
        let finished = try XCTUnwrap(state.smoothPractice.active)
        XCTAssertEqual(finished.compositionID, id)
        XCTAssertEqual(finished.compositionFingerprint, LibraryPiece(source: .score(score)).fingerprint)
        XCTAssertEqual(finished.phase, .summary)
        XCTAssertEqual(state.journal.attempts.count, 8)
        let reopened = AppState(storageOverride: state.storage)
        defer { reopened.midi.shutdown() }
        XCTAssertEqual(reopened.smoothPractice.active, finished)
        XCTAssertEqual(reopened.adaptiveComposition(), score)
        try reopened.openAdaptiveSession(finished.pathwayID)
        XCTAssertEqual(reopened.smoothPractice.completed.count, 1)
        try finishPlaying(reopened)
        try reopened.finishAdaptiveSession(reflection: "Tomorrow", includeComposition: false)
        XCTAssertNil(reopened.smoothPractice.active?.compositionID)
    }
    @MainActor func testDueExactVoicingReturnsInNextOpeningCheck() throws {
        let state = try prepared()
        let date = Date().addingTimeInterval(-90000)
        let initial = try XCTUnwrap(state.smoothPractice.active)
        let pending = AdaptiveSessionInput.Pending(
            expected: initial, notes: [60, 64, 67], input: .midi, skipped: false, verifiedFrom: initial.current!.from,
            date: date)
        try state.saveAdaptiveAnswer(pending)
        try finishPlaying(state)
        try state.finishAdaptiveSession(reflection: "", includeComposition: false)
        try state.openAdaptiveSession(initial.pathwayID)
        XCTAssertEqual(state.smoothPractice.active?.openingReview, initial.current)
        XCTAssertEqual(state.smoothPractice.active?.current, initial.current)
    }
    @MainActor func testDueScreenReviewPreservesItsInputMode() throws {
        let state = try prepared()
        let initial = try XCTUnwrap(state.smoothPractice.active)
        let pending = AdaptiveSessionInput.Pending(
            expected: initial, notes: [60, 64, 67], input: .choice, skipped: false,
            date: Date().addingTimeInterval(-90000))
        try state.saveAdaptiveAnswer(pending)
        try finishPlaying(state)
        try state.finishAdaptiveSession(reflection: "", includeComposition: false)
        try state.openAdaptiveSession(initial.pathwayID)
        XCTAssertEqual(state.smoothPractice.active?.openingReview, initial.current)
        XCTAssertEqual(state.smoothPractice.active?.openingReviewInput, .choice)
    }
    @MainActor func testPendingCanBeDiscardedAndNavigationDoesNotLoseSession() throws {
        let state = try prepared()
        let before = state.smoothPractice
        state.destination = .explore
        state.adaptiveInput.pause()
        XCTAssertEqual(state.smoothPractice, before)
        state.adaptiveInput.discard()
        XCTAssertNil(state.adaptiveInput.pending)
        state.adaptiveInput.submit([], state: state, input: .midi, skipped: true)
        XCTAssertEqual(state.journal.attempts.last?.outcome, .skipped)
        XCTAssertTrue(state.history.cards.isEmpty)
        try state.changeAdaptiveSession { try $0.advance() }
        XCTAssertEqual(state.smoothPractice.active?.cursor, 1)
    }
}
