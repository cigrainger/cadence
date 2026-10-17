// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import CoreMIDI
import MusicCore
import XCTest

@testable import Cadence

final class TimedIntegrationTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func attacks(_ plan: TimedPracticePlan) -> [TimedAttack] {
        plan.targets.map { TimedAttack(seconds: $0.beat * plan.secondsPerBeat, pitch: $0.pitch) }
    }
    @MainActor private func piano(_ state: AppState) throws -> (MusicStudy, TimedPracticePlan) {
        let score = try XCTUnwrap(state.editor.documents.first { $0.instrument == .piano })
        var study = try ComposePractice.make(score, from: 0, through: 3)
        study.staff = 1
        state.studies.add(study)
        state.studies.activeID = study.id
        return (study, try state.timedPlan(study, tempo: 80))
    }
    @MainActor func testClockCountInOffsetAndFinishUseEventTime() throws {
        var clock = 90.0
        let session = TimedPracticeSession(clock: { clock })
        let plan = TimedPracticePlan(rhythm: .pulse, tempo: 80)
        XCTAssertTrue(session.prepare(plan, conditions: TimedConditions(input: .space, offsetMS: 50), held: []))
        session.begin(at: 100)
        XCTAssertGreaterThan(session.countInRemaining, 0)
        session.attack(at: 95)
        XCTAssertTrue(session.attacks.isEmpty)
        // Delivery is deliberately later than source time; event time wins.
        clock = 106
        for attack in attacks(plan) { session.attack(at: 100 + attack.seconds + 0.05) }
        session.tick()
        XCTAssertNil(session.result)
        clock = 107
        session.tick()
        XCTAssertNotNil(session.result)
        XCTAssertTrue(session.result!.report.clean)
        XCTAssertFalse(session.active)
        XCTAssertEqual(session.result?.conditions.offsetMS, 50)
    }
    @MainActor func testHeldNotesDuplicatePacketsPedalAndRearticulation() throws {
        var clock = 100.0
        let session = TimedPracticeSession(clock: { clock })
        let plan = TimedPracticePlan(rhythm: .pulse, tempo: 160)
        XCTAssertFalse(session.prepare(plan, conditions: TimedConditions(), held: [60]))
        XCTAssertTrue(session.prepare(plan, conditions: TimedConditions(), held: []))
        session.begin(at: 100)
        var keys = MIDIKeyboardState()
        func send(_ message: MIDIMessage, _ time: Double) {
            keys.receive(message)
            session.receive(MIDIUpdate(message: message, keyboard: keys, timestamp: time))
        }
        send(.noteOn(channel: 0, note: 60, velocity: 90), 99.625)  // final count-in beat, excluded
        send(.noteOn(channel: 0, note: 60, velocity: 90), 100)  // same held key, excluded
        XCTAssertTrue(session.attacks.isEmpty)
        send(.noteOff(channel: 0, note: 60), 100.01)
        send(.control(channel: 0, number: 64, value: 127), 100.02)
        send(.noteOn(channel: 0, note: 60, velocity: 90), 100.375)
        send(.noteOn(channel: 0, note: 60, velocity: 90), 100.376)
        send(.noteOff(channel: 0, note: 60), 100.4)
        send(.noteOn(channel: 0, note: 60, velocity: 90), 100.75)
        XCTAssertEqual(session.attacks.count, 2)
        clock = 104
        session.tick()
        XCTAssertEqual(session.result?.report.onTime, 2)
        XCTAssertEqual(session.result?.report.missed, 6)
    }
    @MainActor func testResetStopAndDemonstrationNeverSaveAnAssessment() throws {
        var time = 100.0
        let plan = TimedPracticePlan(rhythm: .pulse, tempo: 80)
        let session = TimedPracticeSession(clock: { time })
        session.prepare(plan, conditions: TimedConditions(), held: [])
        session.begin(at: 100)
        session.receive(MIDIUpdate(message: .reset, keyboard: MIDIKeyboardState(), timestamp: 100))
        XCTAssertFalse(session.active)
        time = 110
        session.tick()
        XCTAssertNil(session.result)
        session.prepare(plan, conditions: TimedConditions(), held: [], demonstration: true)
        session.begin(at: 100)
        session.attack(at: 100)
        session.tick()
        XCTAssertNil(session.result)
        XCTAssertTrue(session.attacks.isEmpty)
        session.prepare(plan, conditions: TimedConditions(), held: [])
        session.begin(at: 100)
        session.cancel()
        session.tick()
        XCTAssertNil(session.result)
        session.prepare(plan, conditions: TimedConditions(), held: [])
        session.begin(at: 100)
        session.receive(MIDIUpdate(message: .control(channel: 0, number: 123, value: 0), keyboard: MIDIKeyboardState()))
        XCTAssertFalse(session.active)
    }
    @MainActor func testCalibrationIsNeverAnExerciseResult() throws {
        var time = 100.0
        let plan = TimedPracticePlan.calibration()
        let session = TimedPracticeSession(clock: { time })
        XCTAssertFalse(session.prepare(plan, conditions: TimedConditions(input: .space), held: []))
        XCTAssertTrue(session.prepare(plan, conditions: TimedConditions(input: .space), held: [], calibration: true))
        session.begin(at: 100)
        for attack in attacks(plan) { session.attack(at: 100 + attack.seconds + 0.07) }
        time = 110
        session.tick()
        XCTAssertNil(session.result)
        XCTAssertEqual(session.calibrationReport?.calibrationOffsetMS, 70)
    }
    @MainActor func testFailedSaveRetainedAndAtomicRetryDoesNotDoubleCount() throws {
        let directory = try folder()
        let state = AppState(storageOverride: directory)
        let plan = TimedPracticePlan(rhythm: .rests, tempo: 80)
        let session = TimedPracticeSession(clock: { 110 })
        state.save()
        let url = directory.appendingPathComponent("practice-state.json")
        let bytes = try Data(contentsOf: url)
        let before = state.practiceState
        session.prepare(plan, conditions: TimedConditions(input: .space), held: [])
        session.begin(at: 100)
        for attack in attacks(plan) { session.attack(at: 100 + attack.seconds) }
        session.tick()
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        session.save { try state.saveTimedResult($0) }
        XCTAssertTrue(session.hasUnsavedResult)
        XCTAssertEqual(state.practiceState, before)
        XCTAssertFalse(session.prepare(plan, conditions: TimedConditions(), held: []))
        XCTAssertNotNil(session.result)
        session.cancel()
        XCTAssertTrue(session.hasUnsavedResult)
        try FileManager.default.removeItem(at: url)
        try bytes.write(to: url)
        session.save { try state.saveTimedResult($0) }
        session.save { try state.saveTimedResult($0) }
        XCTAssertTrue(session.saved)
        let restored = AppState(storageOverride: directory)
        let result = try XCTUnwrap(session.result)
        XCTAssertEqual(restored.history.timedPassages?[result.practiceID]?.latest, result)
        XCTAssertEqual(restored.history.timedPassages?[result.practiceID]?.review.encounters, 1)
        XCTAssertEqual(restored.journal.attempts.count, 1)
        XCTAssertEqual(restored.journal.attempts.first?.input, .tapping)
        XCTAssertEqual(restored.journal.attempts.first?.timedPracticeID, result.practiceID)
        session.discard()
        XCTAssertNil(session.result)
    }
    @MainActor func testSourceChangesForgedTargetsAndUnavailableStudiesCannotBeSaved() throws {
        let state = AppState(storageOverride: try folder())
        let (study, plan) = try piano(state)
        let result = TimedPracticeResult(plan: plan, conditions: TimedConditions(), attacks: attacks(plan))
        var bad = result
        bad.plan.targets[0].pitch = 99
        XCTAssertThrowsError(try state.saveTimedResult(bad))
        let index = state.editor.documents.firstIndex { $0.id == study.sourceEditor!.scoreID }!
        state.editor.documents[index].title = "Renamed score"
        XCTAssertNoThrow(try state.saveTimedResult(result))
        try state.editor.documents[index].setPitch(state.editor.documents[index].events[0].id, midi: 75)
        XCTAssertThrowsError(try state.saveTimedResult(result))
        XCTAssertTrue(state.timedReviews.isEmpty)
        state.studies.studies = []
        XCTAssertThrowsError(try state.validateTimedPlan(plan))
        let rhythm = TimedPracticePlan(rhythm: .pulse, tempo: 80)
        var forged = rhythm
        forged.targets[0].beat = 0.1
        XCTAssertThrowsError(try state.validateTimedPlan(forged))
    }
    @MainActor func testReviewsRetainScopeTempoInputAndCoachEvidence() throws {
        let state = AppState(storageOverride: try folder())
        let (study, plan) = try piano(state)
        var result = TimedPracticeResult(plan: plan, conditions: TimedConditions(), attacks: [])
        result.date = Date().addingTimeInterval(-700)
        try state.saveTimedResult(result)
        XCTAssertEqual(state.timedReviews.count, 1)
        state.openTimedReview(result)
        XCTAssertEqual(state.destination, .studies)
        XCTAssertEqual(state.timedStudyID, study.id)
        XCTAssertEqual(state.studies.active?.staff, 1)
        XCTAssertEqual(state.rhythmReview?.plan.tempo, 80)
        XCTAssertTrue(state.guidedReference(study).context.contains("Timed MIDI passage"))
        let piece = try XCTUnwrap(state.libraryPieces.first { $0.id == plan.source?.pieceID })
        XCTAssertTrue(state.piecePracticeEvidence(piece).contains("Timed MIDI passage"))
        var otherHand = study
        otherHand.staff = 2
        XCTAssertFalse(state.guidedReference(otherHand).context.contains("Timed MIDI passage"))
        let rhythm = TimedPracticePlan(rhythm: .offbeats, tempo: 70)
        let rhythmResult = TimedPracticeResult(plan: rhythm, conditions: TimedConditions(input: .space), attacks: [])
        state.openTimedReview(rhythmResult)
        XCTAssertEqual(state.destination, .practice)
        XCTAssertEqual(state.rhythmReview?.conditions.input, .space)
    }
    @MainActor func testImmediateRepeatCannotInflateSpacingOrMergeInputConditions() throws {
        let state = AppState(storageOverride: try folder())
        let plan = TimedPracticePlan(rhythm: .pulse, tempo: 80)
        var result = TimedPracticeResult(plan: plan, conditions: TimedConditions(input: .space), attacks: attacks(plan))
        try state.saveTimedResult(result)
        let due = state.history.timedPassages?[result.practiceID]?.review.due
        result.id = UUID()
        result.date = result.date.addingTimeInterval(60)
        try state.saveTimedResult(result)
        XCTAssertEqual(state.history.timedPassages?[result.practiceID]?.review.due, due)
        result.id = UUID()
        result.conditions.input = .midi
        try state.saveTimedResult(result)
        XCTAssertEqual(state.history.timedPassages?.count, 2)
        result.id = UUID()
        result.plan.tempo = 100
        result.attacks = attacks(result.plan)
        try state.saveTimedResult(result)
        XCTAssertEqual(state.history.timedPassages?.count, 3)
        result.id = UUID()
        result.conditions.click = false
        try state.saveTimedResult(result)
        XCTAssertEqual(state.history.timedPassages?.count, 4)
    }
    func testPacketTimestampsSurviveCopyingAndZeroUsesCallbackArrival() throws {
        var list = MIDIEventList()
        var packet = MIDIEventListInit(&list, MIDIProtocolID._1_0)
        let now = mach_absolute_time()
        let before = now - 100000
        var word: UInt32 = 0x2090_3c64
        packet = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, before, 1, &word)
        word = 0x2080_3c00
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, now, 1, &word)
        let copied = MIDIKeyboard.copyPackets(&list)
        XCTAssertEqual(copied.count, 2)
        XCTAssertEqual(copied[0].timestamp, PracticeClock.seconds(before), accuracy: 0.000000001)
        XCTAssertEqual(copied[1].timestamp, PracticeClock.seconds(now), accuracy: 0.000000001)
        XCTAssertFalse(copied[0].arrivalTimestamp)
        var zero = MIDIEventList()
        let zeroPacket = MIDIEventListInit(&zero, MIDIProtocolID._1_0)
        _ = MIDIEventListAdd(&zero, MemoryLayout<MIDIEventList>.size, zeroPacket, 0, 1, &word)
        let earliest = PracticeClock.now()
        let fallback = MIDIKeyboard.copyPackets(&zero)
        XCTAssertTrue(fallback[0].arrivalTimestamp)
        XCTAssertGreaterThanOrEqual(fallback[0].timestamp, earliest)
    }
    @MainActor func testVersionTwoMigrationPreservesBackupAndProtectsTimedResults() throws {
        let directory = try folder()
        let url = directory.appendingPathComponent("practice-state.json")
        var old = PracticeState()
        old.schemaVersion = 2
        let bytes = try JSONEncoder().encode(old)
        try bytes.write(to: url)
        let state = AppState(storageOverride: directory)
        let plan = TimedPracticePlan(rhythm: .pulse, tempo: 80)
        let result = TimedPracticeResult(plan: plan, conditions: TimedConditions(input: .space), attacks: attacks(plan))
        try state.saveTimedResult(result)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("previous")), bytes)
        XCTAssertEqual(AppState(storageOverride: directory).practiceState.schemaVersion, 15)
        XCTAssertEqual(AppState(storageOverride: directory).history.timedPassages?[result.practiceID]?.latest, result)
    }
}
