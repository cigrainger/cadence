// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

@testable import Cadence

final class FlowPracticeIntegrationTests: XCTestCase {
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
            now: Date().addingTimeInterval(-60))
        try FlowPracticeChecks.capture(state: state, imperfect: true)
        try state.enableRehearsalFlow()
        XCTAssertEqual(state.currentRehearsal?.flow?.plan.source?.scope.from, 5)
        return (state, piece)
    }
    @MainActor func testFlowSettingsTakesAndReflectionPersistWithIndependentContext() throws {
        let (state, piece) = try prepared()
        var flow = state.currentRehearsal!.flow!
        flow.pulse = .gaps
        flow.partner = false
        flow.tempo = 70
        try state.configureRehearsalFlow(flow)
        try FlowPracticeChecks.capture(state: state)
        try FlowPracticeChecks.capture(state: state)
        XCTAssertEqual(state.pianoTakes.takes.count, 3)
        XCTAssertEqual(state.journal.attempts.count, 3)
        XCTAssertEqual(state.currentRehearsal?.focusResults.last?.pass.conditions.flowPulse, .gaps)
        XCTAssertEqual(FlowPractice.advice(state.currentRehearsal!, exercise: .notes).settings?.tempo, 75)
        XCTAssertTrue(state.journal.attempts.last!.selectedChoice!.contains("Alternate bar starts"))
        let restored = AppState(storageOverride: state.storage)
        defer { restored.midi.shutdown() }
        restored.openPieceRehearsal(piece)
        XCTAssertEqual(restored.currentRehearsal, state.currentRehearsal)
        try restored.updateRehearsal(restored.currentRehearsal!.key) { try $0.returnToPhrase() }
        try FlowPracticeChecks.capture(state: restored)
        let due = restored.currentRehearsal?.nextReview
        try restored.updateRehearsal(restored.currentRehearsal!.key) { $0.flowReflection = .mixed }
        XCTAssertEqual(restored.currentRehearsal?.nextReview, due)
        XCTAssertNil(restored.currentRehearsal?.contextResult?.conditions.flowPulse)
        XCTAssertEqual(restored.currentRehearsal?.contextResult?.plan, restored.currentRehearsal?.opening)
        XCTAssertEqual(restored.practiceState.schemaVersion, 16)
        XCTAssertEqual(restored.currentRehearsal?.flowReflection, .mixed)
    }
    @MainActor func testActualStartUsesSavedTempoPulseAndPartnerAndLocksChanges() throws {
        let (state, _) = try prepared()
        let session = state.rehearsalSession
        var flow = state.currentRehearsal!.flow!
        flow.tempo = 60
        flow.pulse = .bars
        flow.partner = false
        try state.configureRehearsalFlow(flow)
        try state.startRehearsal(exercise: .rightHand, tempo: 80, input: .midi, playPartner: true)
        XCTAssertEqual(session.timing.plan?.tempo, 60)
        XCTAssertEqual(session.timing.conditions.flowPulse, .bars)
        XCTAssertNil(session.timing.conditions.partnerStaff)
        XCTAssertEqual(session.flowSource, flow.plan)
        XCTAssertEqual(session.pianoPhrase?.plan, session.timing.plan)
        XCTAssertThrowsError(try state.configureRehearsalFlow(nil))
        session.stop()
        XCTAssertNil(session.timing.result)
        try state.configureRehearsalFlow(nil)
        XCTAssertNil(state.currentRehearsal?.flow)
    }
    @MainActor func testFailedAtomicSaveKeepsFlowSelectionAndTakeForRetry() throws {
        let (state, _) = try prepared()
        let url = state.stores.practice.url
        let before = state.practiceState
        let bytes = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try FlowPracticeChecks.capture(state: state, exercise: .rightHand)
        let pending = state.rehearsalSession.timing.result
        let recording = state.rehearsalSession.timing.pianoRecording
        XCTAssertTrue(state.rehearsalSession.timing.hasUnsavedResult)
        XCTAssertEqual(state.practiceState, before)
        XCTAssertThrowsError(try state.configureRehearsalFlow(nil))
        try FileManager.default.removeItem(at: url)
        try bytes.write(to: url)
        state.saveRehearsalPass()
        state.saveRehearsalPass()
        XCTAssertEqual(state.pianoTakes.takes.count, 2)
        XCTAssertEqual(state.pianoTakes.takes.last?.pass, pending)
        XCTAssertEqual(state.pianoTakes.takes.last?.recording, recording)
        XCTAssertEqual(state.currentRehearsal?.focusResults.count, 1)
    }
    @MainActor func testSourceEditsCannotReassignPendingFlowResult() throws {
        let (state, piece) = try prepared()
        try FlowPracticeChecks.capture(state: state, save: false)
        let index = try XCTUnwrap(state.editor.documents.firstIndex { "score:" + $0.id.uuidString == piece.id })
        let event = try XCTUnwrap(state.editor.documents[index].events.firstIndex { $0.bar == 6 && $0.staff == 2 })
        state.editor.documents[index].events[event].pitches = [EditorPitch(36)]
        state.saveRehearsalPass()
        XCTAssertTrue(state.rehearsalSession.timing.hasUnsavedResult)
        XCTAssertEqual(state.pianoTakes.takes.count, 1)
        XCTAssertFalse(state.rehearsalCurrent(state.currentRehearsal!))
        XCTAssertThrowsError(try state.startRehearsal(exercise: .notes, tempo: 65, input: .midi))
    }
    @MainActor func testMultipleJoinsRetainOriginalSourceMappingsAndLoopParameters() throws {
        let (state, piece) = try prepared()
        try FlowPracticeChecks.capture(state: state)
        let first = state.currentRehearsal!.flow!
        let choices = try FlowPractice.joins(piece: piece, record: state.currentRehearsal!)
        var next = first
        next.plan = choices.last!.plan
        next.pulse = .off
        try state.configureRehearsalFlow(next)
        try state.startRehearsal(exercise: .notes, tempo: 80, input: .midi, loops: 3)
        XCTAssertEqual(state.rehearsalSession.loopsRemaining, 2)
        XCTAssertEqual(state.rehearsalSession.sourcePlan, next.plan)
        XCTAssertFalse(state.rehearsalSession.timing.conditions.click)
        state.rehearsalSession.stop()
        try FlowPracticeChecks.capture(state: state)
        XCTAssertEqual(state.currentRehearsal?.focusResults.first?.flowSource, first.plan)
        XCTAssertEqual(state.currentRehearsal?.focusResults.last?.flowSource, next.plan)
        XCTAssertTrue(state.rehearsalCurrent(state.currentRehearsal!))
        XCTAssertTrue((try? state.practiceState.validated()) != nil)
    }
    @MainActor func testTakeComparisonSeparatesClickConditions() throws {
        let (state, _) = try prepared()
        try FlowPracticeChecks.capture(state: state)
        var flow = state.currentRehearsal!.flow!
        flow.pulse = .gaps
        try state.configureRehearsalFlow(flow)
        try FlowPracticeChecks.capture(state: state)
        XCTAssertFalse(state.pianoTakes.takes[1].comparable(to: state.pianoTakes.takes[2]))
        flow.tempo = 70
        try state.configureRehearsalFlow(flow)
        try FlowPracticeChecks.capture(state: state)
        XCTAssertTrue(state.pianoTakes.takes[2].comparable(to: state.pianoTakes.takes[3]))
    }
    @MainActor func testPartnerAudioAndSparsePulseKeepOneSharedCountIn() throws {
        let (state, piece) = try prepared()
        let flow = state.currentRehearsal!.flow!
        let solo = try PieceRehearsal.exercisePlan(flow.plan, exercise: .rightHand, tempo: 65)
        let partner = try PianoHands.accompaniment(piece, solo: solo, partnerStaff: 2)
        let combined = try HandPracticeAudio.render(solo, click: true, partner: partner, flowPulse: .gaps)
        let pulse = try TimedClickTrack.render(solo, click: true, flowPulse: .gaps)
        let boundary = Int((solo.countIn * 44100).rounded())
        XCTAssertEqual(Array(combined[..<boundary]), Array(pulse[..<boundary]))
        XCTAssertEqual(combined.count, pulse.count)
        XCTAssertTrue(combined.allSatisfy(\.isFinite))
        XCTAssertNotEqual(Array(combined[boundary...]), Array(pulse[boundary...]))
        XCTAssertEqual(try HandPracticeAudio.render(solo, click: true, partner: nil, flowPulse: .gaps), pulse)
    }
    @MainActor func testRhythmFlowMapsFeedbackToOriginalBarsWithoutPianoTake() throws {
        let (state, _) = try prepared()
        try FlowPracticeChecks.capture(state: state, exercise: .rhythm)
        XCTAssertEqual(state.pianoTakes.takes.count, 1)
        XCTAssertTrue(state.currentRehearsal!.focusResults.last!.pass.plan.rhythmOnly)
        XCTAssertEqual(state.rehearsalSession.feedback.first?.assessment.target.bar, 5)
        XCTAssertEqual(state.journal.attempts.last?.passageScope?.from, 5)
    }
}
