// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

@testable import Cadence

final class PickingIntegrationTests: XCTestCase {
    @MainActor private func prepared() throws -> AppState {
        let state = AppState(
            storageOverride: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let directory = state.storage
        addTeardownBlock {
            await MainActor.run {
                state.stopAllPlayback()
                state.midi.shutdown()
            }
            try? FileManager.default.removeItem(at: directory)
        }
        let document = try PickingChecks.document()
        state.editor.documents.append(document)
        XCTAssertTrue(state.save())
        try state.beginPicking(
            piece: .init(source: .score(document)), scope: .init(partID: "P1", staff: 1, from: 0, through: 3),
            style: .travis)
        return state
    }
    @MainActor func testFailedSaveKeepsPendingAndRetriesExactlyOnce() throws {
        let state = try prepared()
        let before = state.practiceState
        let url = state.stores.practice.url
        let bytes = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        state.pickingInput.submit(.tried, state: state)
        XCTAssertNotNil(state.pickingInput.pending)
        XCTAssertEqual(state.practiceState, before)
        try FileManager.default.removeItem(at: url)
        try bytes.write(to: url)
        state.pickingInput.save(state)
        state.pickingInput.save(state)
        XCTAssertNil(state.pickingInput.pending)
        XCTAssertEqual(state.pickingPractice.active?.stage, .muted)
        XCTAssertEqual(state.journal.attempts.count, 1)
        let restored = AppState(storageOverride: state.storage)
        defer { restored.midi.shutdown() }
        XCTAssertEqual(restored.pickingPractice, state.pickingPractice)
    }
    @MainActor func testSourceEditsRejectStaleResultAndPreserveOldWork() throws {
        let state = try prepared()
        let old = state.pickingPractice.active!
        let pending = PickingInput.Pending(expected: old, action: .tried, date: Date())
        let index = state.editor.documents.firstIndex { "score:" + $0.id.uuidString == old.material.pieceID }!
        state.editor.documents[index].harmonies[0].symbol = try .parse("D")
        XCTAssertFalse(state.pickingCurrent(old.material))
        XCTAssertThrowsError(try state.savePickingAction(pending))
        try state.beginPicking(
            piece: .init(source: .score(state.editor.documents[index])), scope: old.material.scope, style: old.style)
        XCTAssertEqual(state.pickingPractice.sessions.count, 2)
    }
    @MainActor func testCreativeSaveReopensRenamedEditedArrangementAndPreservesOriginal() throws {
        let state = try prepared()
        let original = state.pickingPractice.active!.material
        for _ in 0..<4 { state.pickingInput.submit(.tried, state: state) }
        let count = state.editor.documents.count
        try state.savePickingArrangement(style: .classical, tempo: 68, backbeat: true)
        let id = state.editor.activeID
        let index = state.editor.documents.firstIndex { $0.id == id }!
        state.editor.documents[index].title = "My own accompaniment"
        state.editor.documents[index].tempo = 88
        XCTAssertTrue(state.save())
        try state.savePickingArrangement(style: .classical, tempo: 72, backbeat: false)
        XCTAssertEqual(state.editor.documents.count, count + 1)
        XCTAssertEqual(state.editor.activeID, id)
        XCTAssertEqual(state.editor.active.title, "My own accompaniment")
        XCTAssertEqual(state.editor.active.tempo, 88)
        XCTAssertEqual(state.editor.active.pickingSource, original)
        XCTAssertTrue(state.pickingCurrent(original))
    }
    @MainActor func testCaptureCannotAttributePlaybackOrAnotherTaskAndCoachPinsTake() throws {
        let state = try prepared()
        for _ in 0..<2 { state.pickingInput.submit(.tried, state: state) }
        let input = state.pickingInput
        input.arm(state)
        for index in 0..<5 {
            input.receive(
                .init(
                    sampleTime: Int64(index * 4096), hostSeconds: nil, sampleRate: 48000, frameCount: 4096,
                    rms: 0.1, clippedFraction: 0, frequency: 130.81, confidence: 0.99), state: state)
        }
        input.finish(state)
        XCTAssertEqual(state.pickingPractice.active?.takes.count, 1)
        XCTAssertEqual(state.journal.attempts.last?.input, .microphone)
        XCTAssertEqual(state.journal.attempts.last?.outcome, .revealed)
        let context = state.currentCoachContext
        XCTAssertTrue(context.reference.contains("Selected local take"))
        XCTAssertTrue(context.reference.contains("No onset alignment"))
        input.arm(state)
        state.audio.isPlaying = true
        input.receive(
            .init(
                sampleTime: 0, hostSeconds: nil, sampleRate: 48000, frameCount: 4096, rms: 0.1, clippedFraction: 0,
                frequency: 110, confidence: 1), state: state)
        XCTAssertFalse(input.recording)
        XCTAssertTrue(input.frames.isEmpty)
        state.audio.isPlaying = false
        input.arm(state)
        state.practicePage = .home
        input.finish(state)
        XCTAssertEqual(state.pickingPractice.active?.takes.count, 1)
        XCTAssertFalse(context.reference.contains("raw audio"))
    }
    @MainActor func testReviewIsSourceLinkedAndIndependentReturnDoesNotInventMeasurement() throws {
        let state = try prepared()
        let session = state.pickingPractice.active!
        for _ in 0..<5 { state.pickingInput.submit(.tried, state: state) }
        XCTAssertTrue(state.practiceReviews(now: Date().addingTimeInterval(1300)).contains { $0.id == session.key })
        try state.resumePicking(session.id, independent: true)
        XCTAssertFalse(state.pickingPractice.active!.supported)
        state.pickingInput.submit(.tried, state: state)
        XCTAssertEqual(state.journal.attempts.last?.input, .selfReport)
        XCTAssertFalse(state.journal.attempts.last!.assisted)
        XCTAssertEqual(state.pickingPractice.active?.review.lastInput, .selfReport)
    }
}

extension PickingIntegrationTests {
    @MainActor func testShorterSelectionResetsFocusedJoinAndClampsLateControls() throws {
        let state = try prepared()
        let previous = state.pickingPractice.active!
        state.pickingInput.join = 2
        let piece = try XCTUnwrap(state.libraryPieces.first { $0.id == previous.material.pieceID })
        try state.beginPicking(piece: piece, scope: .init(partID: "P1", staff: 1, from: 0, through: 1), style: .travis)
        XCTAssertEqual(state.pickingInput.join, 0)
        XCTAssertEqual(state.pickingInput.focusedBars(2), 0...1)
        state.pickingInput.join = Int.max
        XCTAssertEqual(state.pickingInput.focusedBars(2), 0...1)
        state.pickingInput.join = Int.min
        XCTAssertEqual(state.pickingInput.focusedBars(4), 0...1)
        XCTAssertEqual(state.pickingInput.focusedBars(1), 0...0)
        XCTAssertEqual(state.pickingInput.focusedBars(Int.min), 0...0)
        state.pickingInput.join = 1
        try state.resumePicking(previous.id, independent: false)
        XCTAssertEqual(state.pickingInput.join, 0)
    }
    @MainActor func testAdaptedArrangementReturnsToItsSourceAndPrefersMatchingStyle() throws {
        let state = try prepared()
        let original = state.pickingPractice.active!
        for _ in 0..<4 { state.pickingInput.submit(.tried, state: state) }
        try state.savePickingArrangement(style: .classical, tempo: 72, backbeat: false)
        let arrangement = state.editor.active
        let piece = try XCTUnwrap(state.libraryPieces.first { $0.id == original.material.pieceID })
        try state.beginPicking(
            piece: piece, scope: .init(partID: "P1", staff: 1, from: 0, through: 1), style: .strumming)
        try state.returnToPicking(from: arrangement)
        XCTAssertEqual(state.pickingPractice.activeID, original.id)
        try state.beginPicking(piece: piece, scope: original.material.scope, style: .classical)
        let exact = state.pickingPractice.activeID
        try state.resumePicking(original.id, independent: false)
        try state.returnToPicking(from: arrangement)
        XCTAssertEqual(state.pickingPractice.activeID, exact)
        XCTAssertThrowsError(try state.returnToPicking(from: .guitarExample))
    }
}
