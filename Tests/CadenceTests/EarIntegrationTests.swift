// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

@testable import Cadence

final class EarIntegrationTests: XCTestCase {
    @MainActor private func prepared(stage: EarStage = .sing) throws -> AppState {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let state = AppState(storageOverride: folder)
        addTeardownBlock {
            await MainActor.run { state.midi.shutdown() }
            try? FileManager.default.removeItem(at: folder)
        }
        state.openEarPathway()
        XCTAssertEqual(state.practicePage, .ear)
        state.earInput.submit(.init(.heard), state: state)
        state.earInput.submit(.init(.imagined), state: state)
        if stage == .play {
            state.earInput.submit(.init(.answer, skipped: true), state: state)
            state.earInput.submit(.init(.next), state: state)
        }
        return state
    }
    @MainActor private func play(_ notes: [Int], state: AppState) {
        var keys = MIDIKeyboardState()
        for note in notes {
            for message in [MIDIMessage.noteOn(channel: 0, note: note, velocity: 80), .noteOff(channel: 0, note: note)]
            {
                keys.receive(message)
                state.earInput.receive(.init(message: message, keyboard: keys), state: state)
            }
        }
    }
    @MainActor func testVirtualKeyboardRepeatedNotesAndExplicitSubmit() throws {
        let state = try prepared(stage: .play)
        state.earInput.arm(state: state)
        play([60, 60, 62, 60], state: state)
        XCTAssertEqual(state.earInput.notes, [60, 60, 62, 60])
        XCTAssertEqual(state.journal.attempts.count, 1)
        state.earInput.submit(.init(.answer, notes: state.earInput.notes), state: state)
        XCTAssertEqual(state.journal.attempts.last?.input, .midi)
        XCTAssertEqual(state.journal.attempts.last?.outcome, .incorrect)
        XCTAssertEqual(state.history.attempts, 1)
    }
    @MainActor func testSungPitchFramesShareTheProductionCapturePath() throws {
        let state = try prepared()
        state.earInput.arm(state: state)
        for (index, note) in [60, 62, 60].enumerated() {
            let frequency = 440 * pow(2, Double(note - 69) / 12)
            let detection = try XCTUnwrap(
                PitchDetector.detect(
                    (0..<4096).map { Float(sin(2 * Double.pi * frequency * Double($0) / 12000)) }, sampleRate: 12000))
            state.earInput.receivePitch(detection, at: Double(index), state: state)
            state.earInput.receivePitch(detection, at: Double(index) + 0.4, state: state)
        }
        XCTAssertEqual(state.earInput.notes, [60, 62, 60])
        state.earInput.submit(.init(.answer, notes: state.earInput.notes), state: state)
        XCTAssertEqual(state.journal.attempts.last?.input, .singing)
        XCTAssertEqual(state.journal.attempts.last?.outcome, .correct)
    }
    @MainActor func testChordGestureInvalidatesWholeTake() throws {
        let state = try prepared(stage: .play)
        state.earInput.arm(state: state)
        play([60, 62, 60], state: state)
        var keys = MIDIKeyboardState()
        for message in [
            MIDIMessage.noteOn(channel: 0, note: 64, velocity: 80), .noteOn(channel: 0, note: 67, velocity: 80),
            .noteOff(channel: 0, note: 64), .noteOff(channel: 0, note: 67),
        ] {
            keys.receive(message)
            state.earInput.receive(.init(message: message, keyboard: keys), state: state)
        }
        XCTAssertTrue(state.earInput.invalidTake)
        XCTAssertFalse(state.earInput.listening)
        state.earInput.submit(.init(.answer, notes: state.earInput.notes), state: state)
        XCTAssertEqual(state.history.attempts, 0)
        state.earInput.arm(state: state)
        XCTAssertFalse(state.earInput.invalidTake)
        XCTAssertTrue(state.earInput.notes.isEmpty)
    }
    @MainActor func testNavigationAndPanicNeverSubmit() throws {
        let state = try prepared(stage: .play)
        state.earInput.arm(state: state)
        play([60], state: state)
        state.showPracticeHome()
        play([62, 60], state: state)
        XCTAssertFalse(state.earInput.listening)
        XCTAssertEqual(state.history.attempts, 0)
        state.openEarPathway()
        state.earInput.arm(state: state)
        state.earInput.receive(.init(message: .reset, keyboard: MIDIKeyboardState()), state: state)
        XCTAssertFalse(state.earInput.listening)
    }
    @MainActor func testSaveFailureRecoveryAndRestart() throws {
        let state = try prepared()
        let before = state.practiceState
        let url = state.stores.practice.url
        state.earInput.arm(state: state)
        let bytes = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        state.earInput.submit(.init(.answer, notes: [60, 62, 60]), state: state)
        XCTAssertEqual(state.practiceState, before)
        XCTAssertNotNil(state.earInput.pending)
        let pending = try XCTUnwrap(state.earInput.pending)
        try FileManager.default.removeItem(at: url)
        try bytes.write(to: url)
        state.earInput.save(state: state)
        XCTAssertNil(state.earInput.pending)
        XCTAssertEqual(state.journal.attempts.first?.id, pending.event.id)
        try state.saveEarEvent(pending)
        XCTAssertEqual(state.journal.attempts.count, 1)
        let restored = AppState(storageOverride: state.storage)
        defer { restored.midi.shutdown() }
        XCTAssertEqual(restored.practiceState, state.practiceState)
        XCTAssertFalse(restored.earInput.listening)
        restored.openEarPathway()
        XCTAssertEqual(restored.earPractice.active?.id, pending.expected.id)
    }
    @MainActor func testStalePlaybackOrAnswerCannotChangeNewStage() throws {
        let state = try prepared()
        let old = try XCTUnwrap(state.earPractice.active)
        state.earInput.submit(.init(.hint), state: state)
        XCTAssertThrowsError(try state.saveEarEvent(.init(expected: old, event: .init(.heard))))
        XCTAssertThrowsError(try state.saveEarEvent(.init(expected: old, event: .init(.answer, notes: [60, 62, 60]))))
        XCTAssertEqual(state.history.attempts, 0)
    }
    @MainActor func testPrematurePlaybackStopNeverSignalsCompletedListen() async throws {
        let audio = AudioPlayer()
        audio.play(EarPhrase().score)
        let id = audio.playbackID
        audio.stop()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(audio.completedPlayback)
        XCTAssertNotEqual(audio.playbackID, id)
        XCTAssertFalse(audio.isPlaying)
    }
}
