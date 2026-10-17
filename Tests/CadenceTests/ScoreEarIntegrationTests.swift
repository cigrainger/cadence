// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

@testable import Cadence

final class ScoreEarIntegrationTests: XCTestCase {
    @MainActor func prepared() throws -> (AppState, ScoreEarMaterial) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let state = AppState(storageOverride: folder)
        let doc = try ScoreEarChecks.document()
        addTeardownBlock {
            await MainActor.run { state.midi.shutdown() }
            try? FileManager.default.removeItem(at: folder)
        }
        state.editor.documents.append(doc)
        XCTAssertTrue(state.save())
        let m = try ScoreEarChecks.material(doc)
        try state.openScoreEar(m)
        return (state, m)
    }
    @MainActor func event(
        _ state: AppState, _ kind: EarEvent.Kind, notes: [Int] = [], skip: Bool = false, date: Date = Date()
    ) throws {
        try state.saveScoreEarEvent(
            .init(
                expected: try XCTUnwrap(state.scoreEarPractice.active),
                event: .init(kind, notes: notes, skipped: skip, date: date)))
    }
    @MainActor func finish(_ state: AppState, _ m: ScoreEarMaterial, at date: Date = Date()) throws {
        if try state.scoreEarPractice.active?.projection().stage == .hear { try event(state, .heard, date: date) }
        try event(state, .imagined, date: date)
        for _ in 0..<2 {
            try event(state, .answer, notes: m.melody.map(\.midi), date: date)
            try event(state, .next, date: date)
        }
        try event(state, .next, date: date)
    }
    @MainActor func testVirtualMIDIUsesSharedCaptureAndExactSourceEvidence() throws {
        let (state, m) = try prepared()
        try event(state, .heard)
        try event(state, .imagined)
        try event(state, .answer, skip: true)
        try event(state, .next)
        state.scoreEarInput.arm(state: state)
        var keys = MIDIKeyboardState()
        for note in m.melody.map(\.midi) {
            for message in [MIDIMessage.noteOn(channel: 0, note: note, velocity: 90), .noteOff(channel: 0, note: note)]
            {
                keys.receive(message)
                state.scoreEarInput.receive(.init(message: message, keyboard: keys), state: state)
            }
        }
        XCTAssertEqual(state.scoreEarInput.notes, m.melody.map(\.midi))
        state.scoreEarInput.submit(.init(.answer, notes: state.scoreEarInput.notes), state: state)
        let a = try XCTUnwrap(state.journal.attempts.last)
        XCTAssertEqual(a.outcome, .correct)
        XCTAssertEqual(a.pieceID, m.pieceID)
        XCTAssertEqual(a.scoreFingerprint, m.fingerprint)
        XCTAssertTrue(a.assisted)
        XCTAssertEqual(state.history.cards.count, 1)
    }
    @MainActor func testSingingFramesUseTheSharedProductionCapture() throws {
        let (state, m) = try prepared()
        try event(state, .heard)
        try event(state, .imagined)
        state.scoreEarInput.arm(state: state)
        for (i, note) in m.melody.map(\.midi).enumerated() {
            let frequency = 440 * pow(2, Double(note - 69) / 12)
            let pitch = try XCTUnwrap(
                PitchDetector.detect(
                    (0..<4096).map { Float(sin(2 * .pi * frequency * Double($0) / 12000)) }, sampleRate: 12000))
            state.scoreEarInput.receivePitch(pitch, at: Double(i), state: state)
            state.scoreEarInput.receivePitch(pitch, at: Double(i) + 0.4, state: state)
        }
        XCTAssertEqual(state.scoreEarInput.notes, m.melody.map(\.midi))
        state.scoreEarInput.submit(.init(.answer, notes: state.scoreEarInput.notes), state: state)
        XCTAssertEqual(state.journal.attempts.last?.outcome, .correct)
    }
    @MainActor func testThirteenthSungNoteInvalidatesTake() throws {
        let (state, _) = try prepared()
        try event(state, .heard)
        try event(state, .imagined)
        state.scoreEarInput.arm(state: state)
        for index in 0..<13 {
            let frequency = index % 2 == 0 ? 440.0 : 493.883
            let pitch = try XCTUnwrap(
                PitchDetector.detect(
                    (0..<4096).map { Float(sin(2 * .pi * frequency * Double($0) / 12000)) }, sampleRate: 12000))
            state.scoreEarInput.receivePitch(pitch, at: Double(index), state: state)
            state.scoreEarInput.receivePitch(pitch, at: Double(index) + 0.4, state: state)
        }
        XCTAssertTrue(state.scoreEarInput.invalidTake)
        XCTAssertFalse(state.scoreEarInput.listening)
        state.scoreEarInput.submit(.init(.answer, notes: state.scoreEarInput.notes), state: state)
        XCTAssertTrue(state.journal.attempts.isEmpty)
    }
    @MainActor func testSaveFailureReturnsToSamePendingActionAndRetriesOnce() throws {
        let (state, m) = try prepared()
        try event(state, .heard)
        try event(state, .imagined)
        state.scoreEarInput.arm(state: state)
        let url = state.stores.practice.url
        let bytes = try Data(contentsOf: url)
        let before = state.practiceState
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        state.scoreEarInput.submit(.init(.answer, notes: m.melody.map(\.midi)), state: state)
        XCTAssertEqual(state.practiceState, before)
        let pending = try XCTUnwrap(state.scoreEarInput.pending)
        state.showPracticeHome()
        XCTAssertNoThrow(try state.openScoreEar(m))
        XCTAssertNotNil(state.scoreEarInput.pending)
        try FileManager.default.removeItem(at: url)
        try bytes.write(to: url)
        state.scoreEarInput.save(state: state)
        XCTAssertNil(state.scoreEarInput.pending)
        try state.saveScoreEarEvent(pending)
        XCTAssertEqual(state.journal.attempts.count, 1)
        let restored = AppState(storageOverride: state.storage)
        defer { restored.midi.shutdown() }
        XCTAssertEqual(restored.scoreEarPractice, state.scoreEarPractice)
        XCTAssertFalse(restored.scoreEarInput.listening)
        try restored.openScoreEar(m)
        XCTAssertEqual(restored.scoreEarPractice.active?.id, pending.expected.id)
    }
    @MainActor func testSourceChangedOrDeletedCannotCaptureOrGradeAndHistoryStays() throws {
        let (state, m) = try prepared()
        try event(state, .heard)
        try event(state, .imagined)
        let original = try XCTUnwrap(state.editor.documents.first { "score:" + $0.id.uuidString == m.pieceID })
        let index = try XCTUnwrap(state.editor.documents.firstIndex { $0.id == original.id })
        state.editor.documents[index].tempo += 1
        XCTAssertFalse(state.scoreEarCurrent(m))
        state.scoreEarInput.arm(state: state)
        XCTAssertFalse(state.scoreEarInput.listening)
        XCTAssertThrowsError(try event(state, .answer, notes: m.melody.map(\.midi)))
        state.editor.documents[index] = original
        try event(state, .answer, notes: m.melody.map(\.midi))
        state.editor.documents.remove(at: index)
        XCTAssertThrowsError(try state.openScoreEar(m))
        XCTAssertEqual(state.journal.attempts.count, 1)
        XCTAssertTrue(state.practiceReviews(now: Date().addingTimeInterval(86400)).filter { $0.id == m.id }.isEmpty)
    }
    @MainActor func testChangedSourcePendingActionRemainsReachableForDiscard() throws {
        let (state, m) = try prepared()
        try event(state, .heard)
        try event(state, .imagined)
        let id = try XCTUnwrap(state.scoreEarPractice.selectedID)
        state.scoreEarInput.arm(state: state)
        state.editor.documents.removeAll { "score:" + $0.id.uuidString == m.pieceID }
        state.scoreEarInput.submit(.init(.answer, notes: m.melody.map(\.midi)), state: state)
        XCTAssertNotNil(state.scoreEarInput.pending)
        state.showPracticeHome()
        try state.resumeScoreEarSession(id)
        XCTAssertEqual(state.practicePage, .scoreEar)
        state.scoreEarInput.discard()
        XCTAssertNil(state.scoreEarInput.pending)
        XCTAssertTrue(state.journal.attempts.isEmpty)
    }
    @MainActor func testDelayedReturnComesHomeHiddenAndModalityCardsStaySeparate() throws {
        let (state, m) = try prepared()
        let now = Date()
        try finish(state, m, at: now)
        XCTAssertFalse(state.practiceReviews(now: now).contains { $0.id == m.id })
        XCTAssertTrue(state.practiceReviews(now: now.addingTimeInterval(86400)).contains { $0.id == m.id })
        try state.openScoreEar(m, now: now.addingTimeInterval(86400))
        let p = try XCTUnwrap(state.scoreEarPractice.active).projection()
        XCTAssertEqual(p.stage, .imagine)
        XCTAssertFalse(p.assisted)
        XCTAssertFalse(p.hinted)
        try finish(state, m, at: now.addingTimeInterval(86400))
        XCTAssertEqual(state.history.cards.count, 2)
        XCTAssertTrue(state.history.cards.values.allSatisfy { $0.review.intervalDays == 1 })
        XCTAssertEqual(state.journal.attempts.filter { !$0.assisted }.count, 2)
    }
    @MainActor func testNavigationAndStalePlaybackCannotAdvanceSession() throws {
        let (state, m) = try prepared()
        let old = try XCTUnwrap(state.scoreEarPractice.active)
        try event(state, .heard)
        try event(state, .imagined)
        state.scoreEarInput.arm(state: state)
        state.showPracticeHome()
        XCTAssertFalse(state.scoreEarInput.listening)
        XCTAssertThrowsError(try state.saveScoreEarEvent(.init(expected: old, event: .init(.heard))))
        try state.openScoreEar(m)
        XCTAssertEqual(try state.scoreEarPractice.active?.projection().stage, .sing)
    }
    @MainActor func testBandVisitsDoNotManufactureSuccessfulPractice() throws {
        let (state, m) = try prepared()
        try event(state, .heard)
        try event(state, .imagined)
        for _ in 0..<2 {
            try event(state, .answer, skip: true)
            try event(state, .next)
        }
        try event(state, .accompaniment)
        XCTAssertEqual(state.journal.checked.count, 0)
        XCTAssertTrue(state.history.cards.isEmpty)
        XCTAssertEqual(
            state.journal.attempts.last?.selectedChoice,
            "Opened a play-along; no performance or completion grade was inferred.")
        try event(state, .next)
        XCTAssertTrue(state.practiceReviews(now: Date().addingTimeInterval(86400)).contains { $0.id == m.id })
    }
    @MainActor func testNativeSampledBandRendersTheSelectedPassage() throws {
        let m = try ScoreEarChecks.material(ScoreEarChecks.document())
        let arrangement = ScoreAccompaniment(material: m, options: .init(tempo: 160, loops: 1), includeMelody: true)
        let audio = try SampledAudio.render(
            lanes: arrangement.lanes(), tempo: 160, endBeat: arrangement.endBeat, tail: 0)
        XCTAssertEqual(audio.count, 330750)
        XCTAssertTrue(audio.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(audio.map(abs).max() ?? 0, 0.01)
    }
}
