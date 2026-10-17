// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

@testable import Cadence

final class HandsTogetherIntegrationTests: XCTestCase {
    @MainActor func prepared() throws -> (AppState, LibraryPiece) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let state = AppState(storageOverride: folder)
        let doc = try HandsTogetherChecks.document()
        let piece = LibraryPiece(source: .score(doc))
        addTeardownBlock {
            await MainActor.run {
                state.midi.shutdown()
                state.audio.stop()
                state.rehearsalSession.stop()
            }
            try? FileManager.default.removeItem(at: folder)
        }
        state.editor.documents.append(doc)
        XCTAssertTrue(state.save())
        state.openPieceRehearsal(piece)
        try state.beginRehearsal(
            piece, scope: .init(partID: "P1", staff: nil, from: 4, through: 7), tempo: 80,
            now: Date().addingTimeInterval(-30))
        try HandsTogetherChecks.capture(state: state)
        XCTAssertTrue(state.rehearsalSession.timing.saved)
        return (state, piece)
    }
    @MainActor func testEitherHandPartnerAndTogetherPersistWithTheirOwnTakes() throws {
        let (state, piece) = try prepared()
        try HandsTogetherChecks.capture(state: state, exercise: .rightHand)
        try HandsTogetherChecks.capture(state: state, exercise: .leftHand, partner: false)
        try HandsTogetherChecks.capture(state: state)
        XCTAssertEqual(state.pianoTakes.takes.count, 4)
        XCTAssertEqual(state.journal.attempts.count, 4)
        XCTAssertEqual(state.pianoTakes.takes.map { $0.pass.conditions.partnerStaff }, [nil, 2, nil, nil])
        XCTAssertEqual(state.pianoTakes.takes.map { $0.pass.plan.source?.scope.staff }, [nil, 1, 2, nil])
        XCTAssertTrue(state.journal.attempts.allSatisfy(\.assisted))
        XCTAssertEqual(state.journal.attempts.map { $0.passageScope?.staff }, [nil, 1, 2, nil])
        let last = try XCTUnwrap(state.currentRehearsal)
        try state.updateRehearsal(last.key) { try $0.returnToPhrase() }
        try HandsTogetherChecks.capture(state: state)
        XCTAssertEqual(state.currentRehearsal?.stage, .complete)
        XCTAssertNotNil(state.currentRehearsal?.nextReview)
        let restored = AppState(storageOverride: state.storage)
        defer { restored.midi.shutdown() }
        restored.openPieceRehearsal(piece)
        XCTAssertEqual(restored.pianoTakes, state.pianoTakes)
        XCTAssertEqual(restored.currentRehearsal, state.currentRehearsal)
        XCTAssertEqual(restored.practiceState.schemaVersion, 16)
    }
    @MainActor func testActualStartFreezesOnlyPartnerAndBothHandsForcePartnerOff() throws {
        let (state, _) = try prepared()
        let session = state.rehearsalSession
        try state.startRehearsal(exercise: .leftHand, tempo: 65, input: .midi)
        XCTAssertEqual(session.timing.conditions.partnerStaff, 1)
        XCTAssertEqual(session.timing.plan?.source?.scope.staff, 2)
        XCTAssertEqual(session.pianoPhrase?.plan, session.timing.plan)
        XCTAssertTrue(session.timing.preparing)
        session.stop()
        XCTAssertFalse(session.timing.busy)
        XCTAssertNil(session.timing.result)
        try state.startRehearsal(exercise: .notes, tempo: 65, input: .midi)
        XCTAssertNil(session.timing.conditions.partnerStaff)
        XCTAssertEqual(session.timing.plan?.handStaves, [1, 2])
        session.stop()
        try state.startRehearsal(exercise: .rightHand, tempo: 65, input: .midi, playPartner: false)
        XCTAssertNil(session.timing.conditions.partnerStaff)
        XCTAssertFalse(session.partnerEnabled)
        session.stop()
    }
    @MainActor func testFailedSaveRetainsTheHandConditionRecordingAndPlanOnRetry() throws {
        let (state, _) = try prepared()
        let url = state.stores.practice.url
        let before = state.practiceState
        let bytes = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try HandsTogetherChecks.capture(state: state, exercise: .leftHand)
        let session = state.rehearsalSession
        let pending = session.timing.result
        let recording = session.timing.pianoRecording
        XCTAssertTrue(session.timing.hasUnsavedResult)
        XCTAssertEqual(state.practiceState, before)
        XCTAssertEqual(pending?.conditions.partnerStaff, 1)
        XCTAssertThrowsError(try state.startRehearsal(exercise: .rightHand, tempo: 65, input: .midi))
        XCTAssertEqual(session.timing.result, pending)
        XCTAssertEqual(session.timing.pianoRecording, recording)
        try FileManager.default.removeItem(at: url)
        try bytes.write(to: url)
        state.saveRehearsalPass()
        state.saveRehearsalPass()
        XCTAssertEqual(state.pianoTakes.takes.count, 2)
        XCTAssertEqual(state.pianoTakes.takes.last?.pass, pending)
        XCTAssertEqual(state.pianoTakes.takes.last?.recording, recording)
    }
    @MainActor func testChangingThePartnerStaffInvalidatesStartAndPendingResult() throws {
        let (state, piece) = try prepared()
        try HandsTogetherChecks.capture(state: state, exercise: .rightHand, save: false)
        let i = try XCTUnwrap(state.editor.documents.firstIndex { "score:" + $0.id.uuidString == piece.id })
        let event = try XCTUnwrap(state.editor.documents[i].events.firstIndex { $0.staff == 2 })
        state.editor.documents[i].events[event].pitches = [EditorPitch(40)]
        state.saveRehearsalPass()
        XCTAssertTrue(state.rehearsalSession.timing.hasUnsavedResult)
        XCTAssertEqual(state.pianoTakes.takes.count, 1)
        XCTAssertThrowsError(try state.startRehearsal(exercise: .rightHand, tempo: 65, input: .midi))
    }
    @MainActor func testRecordedHandContainsOnlyLearnerInputAndCannotCompareAcrossHands() throws {
        let (state, _) = try prepared()
        try HandsTogetherChecks.capture(state: state, exercise: .rightHand)
        try HandsTogetherChecks.capture(state: state, exercise: .leftHand)
        let right = state.pianoTakes.takes[1]
        let left = state.pianoTakes.takes[2]
        XCTAssertTrue(right.recording.notes.allSatisfy { $0.pitch >= 60 })
        XCTAssertTrue(left.recording.notes.allSatisfy { $0.pitch < 60 })
        XCTAssertFalse(right.comparable(to: left))
        XCTAssertEqual(right.recording.notes.count, right.pass.plan.targets.count)
        XCTAssertEqual(right.pass.grade, .supported)
    }
    @MainActor func testCalibrationOffsetSurvivesPartnerAndResetStopsTheWholePass() throws {
        let (state, _) = try prepared()
        let session = state.rehearsalSession
        let calibration = TimedPracticePlan.calibration()
        let calibrationOrigin = PracticeClock.now() - calibration.duration - 1
        XCTAssertTrue(session.timing.prepare(calibration, conditions: .init(), held: [], calibration: true))
        session.timing.begin(at: calibrationOrigin)
        for target in calibration.targets {
            session.timing.attack(at: calibrationOrigin + target.beat * calibration.secondsPerBeat + 0.08)
        }
        session.timing.tick()
        session.applyCalibration()
        XCTAssertEqual(session.offsetMS, 80)
        try state.startRehearsal(exercise: .rightHand, tempo: 65, input: .midi)
        XCTAssertEqual(session.timing.conditions.offsetMS, 80)
        let origin = PracticeClock.now()
        session.timing.begin(at: origin)
        var keys = MIDIKeyboardState()
        let message = MIDIMessage.noteOn(channel: 0, note: 64, velocity: 90)
        keys.receive(message)
        session.timing.receive(.init(message: message, keyboard: keys, timestamp: origin + 0.12))
        XCTAssertEqual(try XCTUnwrap(session.timing.attacks.first).seconds, 0.04, accuracy: 0.001)
        session.invalidateTiming("Keyboard disconnected")
        XCTAssertFalse(session.timing.busy)
        XCTAssertNil(session.timing.result)
        XCTAssertEqual(state.pianoTakes.takes.count, 1)
    }
    @MainActor func testSingleStaffCannotStartHandPartnerExerciseAndTogetherCannotUseConnectedMelody() throws {
        let (state, piece) = try prepared()
        XCTAssertThrowsError(try state.startRehearsal(exercise: .connected, tempo: 65, input: .midi))
        try state.beginRehearsal(
            piece, scope: .init(partID: "P1", staff: 1, from: 4, through: 7), tempo: 80,
            now: Date().addingTimeInterval(-30))
        try ShapePhraseChecks.capture(state: state)
        XCTAssertThrowsError(try state.startRehearsal(exercise: .leftHand, tempo: 65, input: .midi))
    }
    @MainActor func testPartnerRenderPreservesCountInSilenceThenSoundsAtWrittenEntrance() throws {
        let (_, piece) = try prepared()
        let both = try RehearsalSource.plan(
            piece, scope: .init(partID: "P1", staff: nil, from: 4, through: 4), tempo: 80)
        let right = try PianoHands.solo(both, exercise: .rightHand)
        let partner = try PianoHands.accompaniment(piece, solo: right, partnerStaff: 2)
        let mixed = try HandPracticeAudio.render(right, click: false, partner: partner)
        let click = try TimedClickTrack.render(right, click: false)
        let boundary = Int((right.countIn * 44100).rounded())
        XCTAssertEqual(Array(mixed[..<boundary]), Array(click[..<boundary]))
        let energy = mixed[(boundary + 1000)..<(boundary + 5000)].reduce(0) { $0 + Double($1 * $1) }
        XCTAssertGreaterThan(energy, 0.001)
        XCTAssertTrue(mixed.allSatisfy(\.isFinite))
        XCTAssertLessThanOrEqual(mixed.map(abs).max() ?? 1, 0.98)
        var wrongTempo = partner
        wrongTempo.tempo = 40
        XCTAssertThrowsError(try HandPracticeAudio.render(right, click: true, partner: wrongTempo))
    }
}
