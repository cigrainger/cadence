// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

@testable import Cadence

final class TriadIntegrationTests: XCTestCase {
    @MainActor func prepared() throws -> AppState {
        let state = AppState(
            storageOverride: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let folder = state.storage
        addTeardownBlock {
            await MainActor.run {
                state.audio.stop()
                state.microphone.stop()
                state.midi.shutdown()
            }
            try? FileManager.default.removeItem(at: folder)
        }
        let doc = try TriadChecks.document()
        state.editor.documents.append(doc)
        XCTAssertTrue(state.save())
        try state.beginTriads(
            piece: .init(source: .score(doc)), scope: .init(partID: "P1", staff: 1, from: 0, through: 3), group: 0)
        return state
    }
    @MainActor func testAtomicSaveFailureRetainsPendingAndDoesNotAdvance() throws {
        let state = try prepared()
        let before = state.practiceState
        let url = state.stores.practice.url
        let bytes = try Data(contentsOf: state.stores.practice.url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        state.triadInput.submit(.inversion(state.triadPractice.active!.material.route[0].inversion), state: state)
        XCTAssertNotNil(state.triadInput.pending)
        XCTAssertEqual(state.practiceState, before)
        try FileManager.default.removeItem(at: url)
        try bytes.write(to: url)
        state.triadInput.save(state)
        state.triadInput.save(state)
        XCTAssertNil(state.triadInput.pending)
        XCTAssertEqual(state.triadPractice.active?.cursor, 1)
        XCTAssertEqual(state.journal.attempts.count, 1)
        let restored = AppState(storageOverride: state.storage)
        defer { restored.midi.shutdown() }
        XCTAssertEqual(restored.triadPractice, state.triadPractice)
    }
    @MainActor func testSourceChangesRejectPendingAndNewSessionUsesNewRevision() throws {
        let state = try prepared()
        let old = state.triadPractice.active!
        let pending = TriadInput.Pending(expected: old, action: .skip, date: Date())
        let i = state.editor.documents.firstIndex { "score:" + $0.id.uuidString == old.material.pieceID }!
        state.editor.documents[i].harmonies[0].symbol = try .parse("D")
        XCTAssertFalse(state.triadCurrent(old.material))
        XCTAssertThrowsError(try state.saveTriadAction(pending))
        try state.beginTriads(
            piece: .init(source: .score(state.editor.documents[i])), scope: old.material.scope, group: 0)
        XCTAssertEqual(state.triadPractice.sessions.count, 2)
        XCTAssertNotEqual(state.triadPractice.active?.material.fingerprint, old.material.fingerprint)
    }
    @MainActor func testLocalMicrophoneStopsAtTwoNotesAndDoesNotGradePlayback() throws {
        let state = try prepared()
        state.triadInput.submit(.skip, state: state)
        state.triadInput.submit(.connected, state: state)
        let notes = state.triadPractice.active!.material.earNotes
        let input = state.triadInput
        input.arm(state)
        for (i, note) in notes.enumerated() {
            for offset in [0.0, 0.2, 0.4] {
                input.receive(
                    DetectedPitch(frequency: 440 * pow(2, Double(note - 69) / 12), confidence: 0.99),
                    at: Double(i) + offset, state: state)
            }
        }
        XCTAssertEqual(input.notes, notes)
        XCTAssertFalse(input.listening)
        input.submit(.microphone(input.notes), state: state)
        XCTAssertEqual(state.triadPractice.active?.stage, .create)
        XCTAssertEqual(state.journal.attempts.last?.input, .microphone)
        try state.resumeTriads(state.triadPractice.active!.id, restart: true)
        input.submit(.skip, state: state)
        input.submit(.skip, state: state)
        input.arm(state)
        state.audio.isPlaying = true
        input.receive(DetectedPitch(frequency: 440, confidence: 1), at: 4, state: state)
        XCTAssertFalse(input.listening)
        XCTAssertTrue(input.notes.isEmpty)
        state.audio.isPlaying = false
    }
    @MainActor func testCreativeDocumentReopensWithoutDuplicatesAndKeepsSource() throws {
        let state = try prepared()
        for _ in 0..<3 { state.triadInput.submit(.skip, state: state) }
        let material = state.triadPractice.active!.material
        try state.openTriadAnswer()
        let id = state.editor.activeID
        try state.openTriadAnswer()
        XCTAssertEqual(state.editor.activeID, id)
        XCTAssertEqual(state.editor.documents.filter { $0.triadSource?.id == material.id }.count, 1)
        XCTAssertEqual(state.editor.active.triadSource, material)
        XCTAssertEqual(state.destination, .editor)
        let restored = AppState(storageOverride: state.storage)
        defer { restored.midi.shutdown() }
        XCTAssertEqual(restored.editor.documents.first { $0.id == id }?.triadSource, material)
    }
    @MainActor func testSupportedReviewAndExistingSelectionAreResumable() throws {
        let state = try prepared()
        let old = state.triadPractice.active!
        try state.beginTriads(
            piece: state.libraryPieces.first { $0.id == old.material.pieceID }!, scope: old.material.scope, group: 0)
        XCTAssertEqual(state.triadPractice.sessions.count, 1)
        for _ in 0..<4 { state.triadInput.submit(.skip, state: state) }
        let now = Date().addingTimeInterval(1300)
        XCTAssertTrue(state.practiceReviews(now: now).contains { $0.id == old.material.id })
        XCTAssertFalse(state.practiceReviews().contains { $0.id == old.material.id })
        try state.resumeTriads(old.id, restart: true)
        XCTAssertEqual(state.triadPractice.active?.stage, .find)
        XCTAssertEqual(state.triadPractice.active?.review.lastGrade, .supported)
    }
}
