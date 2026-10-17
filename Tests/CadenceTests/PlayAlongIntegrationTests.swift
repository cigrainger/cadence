// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

@testable import Cadence

final class PlayAlongIntegrationTests: XCTestCase {
    @MainActor func prepared() throws -> (AppState, PlayAlongPlan) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let state = AppState(storageOverride: folder)
        let doc = try ScoreEarChecks.document()
        addTeardownBlock {
            await MainActor.run {
                state.midi.shutdown()
                state.audio.stop()
                state.playAlongSession.timing.cancel()
            }
            try? FileManager.default.removeItem(at: folder)
        }
        state.editor.documents.append(doc)
        XCTAssertTrue(state.save())
        let plan = try state.playAlongPlan(ScoreEarChecks.material(doc), setup: .init())
        return (state, plan)
    }
    func result(_ plan: PlayAlongPlan, date: Date = Date()) -> PlayAlongResult {
        .init(
            plan: plan,
            pass: .init(
                date: date, plan: plan.timed, conditions: .init(input: .midi, click: false),
                attacks: plan.timed.targets.map { .init(seconds: $0.beat * plan.timed.secondsPerBeat, pitch: $0.pitch) }
            ))
    }
    @MainActor func testAtomicSaveRestartReviewAndCoachEvidence() throws {
        let (state, p) = try prepared()
        let r = result(p, date: Date().addingTimeInterval(-172800))
        try state.savePlayAlong(r)
        try state.savePlayAlong(r)
        XCTAssertEqual(state.journal.attempts.count, 1)
        XCTAssertEqual(state.history.playAlong?[r.practiceID]?.review.lastGrade, .good)
        XCTAssertEqual(state.journal.attempts.first?.scoreFingerprint, p.material.fingerprint)
        XCTAssertFalse(try XCTUnwrap(state.journal.attempts.first).assisted)
        XCTAssertTrue(state.practiceReviews().contains { $0.id == r.practiceID })
        let piece = try XCTUnwrap(state.libraryPieces.first { $0.id == p.material.pieceID })
        XCTAssertTrue(state.playAlongEvidence(piece).contains("8/8 pitches"))
        let restored = AppState(storageOverride: state.storage)
        defer { restored.midi.shutdown() }
        XCTAssertEqual(restored.history.playAlong?[r.practiceID]?.latest, r)
        let item = try XCTUnwrap(restored.practiceReviews().first { $0.id == r.practiceID })
        restored.openPracticeReview(item)
        XCTAssertEqual(restored.playAlongMaterial?.id, p.material.id)
        XCTAssertEqual(restored.playAlongSession.setup, p.setup)
        XCTAssertEqual(restored.playAlongSession.offsetMS, 0)
    }
    @MainActor func testSaveFailureRetainsCompletedPassAndRetryIsExactlyOnce() throws {
        let (state, p) = try prepared()
        var clock = 100.0
        let session = PlayAlongSession(clock: { clock })
        XCTAssertTrue(session.prepare(p, held: []))
        session.timing.begin(at: 100)
        for t in p.timed.targets { session.timing.attack(at: 100 + t.beat * p.timed.secondsPerBeat, pitch: t.pitch) }
        clock += p.timed.duration + 1
        session.timing.tick()
        let resultID = session.result?.pass.id
        let before = state.practiceState
        let url = state.stores.practice.url
        let bytes = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        session.save { try state.savePlayAlong($0) }
        XCTAssertTrue(session.timing.hasUnsavedResult)
        XCTAssertEqual(state.practiceState, before)
        XCTAssertFalse(session.prepare(p, held: []))
        XCTAssertEqual(session.result?.pass.id, resultID)
        session.timing.cancel()
        XCTAssertEqual(session.result?.pass.id, resultID)
        try FileManager.default.removeItem(at: url)
        try bytes.write(to: url)
        session.save { try state.savePlayAlong($0) }
        session.save { try state.savePlayAlong($0) }
        XCTAssertFalse(session.timing.hasUnsavedResult)
        XCTAssertEqual(state.journal.attempts.filter { $0.id == resultID }.count, 1)
    }
    @MainActor func testForgedSourceChangedDeletedAndReviewRevokedCannotSave() throws {
        let (state, p) = try prepared()
        var forged = p
        forged.material.melody[0].midi += 12
        XCTAssertThrowsError(try state.savePlayAlong(result(forged)))
        forged = p
        forged.sourceStart += 4
        XCTAssertThrowsError(try state.savePlayAlong(result(forged)))
        let index = try XCTUnwrap(
            state.editor.documents.firstIndex { "score:" + $0.id.uuidString == p.material.pieceID })
        state.editor.documents[index].title = "Renamed"
        XCTAssertNoThrow(try state.validatePlayAlong(p))
        state.editor.documents[index].events[0].pitches = [EditorPitch(80)]
        XCTAssertThrowsError(try state.savePlayAlong(result(p)))
        state.editor.documents.remove(at: index)
        XCTAssertThrowsError(try state.savePlayAlong(result(p)))
        XCTAssertTrue(state.playAlongReviews.isEmpty)
    }
    @MainActor func testIndependentReturnNotSameDayRepetitionAdvancesSpacing() throws {
        let (state, p) = try prepared()
        let now = Date()
        let first = result(p, date: now)
        try state.savePlayAlong(first)
        let initial = try XCTUnwrap(state.history.playAlong?[first.practiceID]?.review.intervalDays)
        try state.savePlayAlong(result(p, date: now.addingTimeInterval(30)))
        XCTAssertEqual(state.history.playAlong?[first.practiceID]?.review.intervalDays, initial)
        try state.savePlayAlong(result(p, date: now.addingTimeInterval(86400 * 2)))
        XCTAssertGreaterThan(try XCTUnwrap(state.history.playAlong?[first.practiceID]?.review.intervalDays), initial)
        var guided = p
        guided.setup.guide = true
        try state.savePlayAlong(result(guided, date: now))
        XCTAssertEqual(state.history.playAlong?.count, 2)
        XCTAssertEqual(state.history.playAlong?[guided.identity(offsetMS: 0)]?.review.lastGrade, .supported)
    }
    @MainActor func testCalibrationAppliedOnceAndInvalidatedWithoutLosingResult() throws {
        var clock = 100.0
        let session = PlayAlongSession(clock: { clock })
        let p = TimedPracticePlan.calibration()
        XCTAssertTrue(session.timing.prepare(p, conditions: .init(), held: [], calibration: true))
        session.timing.begin(at: 100)
        for t in p.targets { session.timing.attack(at: 100 + t.beat * p.secondsPerBeat + 0.07) }
        clock += p.duration + 1
        session.timing.tick()
        session.applyCalibration()
        session.applyCalibration()
        XCTAssertEqual(session.offsetMS, 70)
        XCTAssertTrue(session.calibrated)
        XCTAssertNil(session.result)
        let (_, plan) = try prepared()
        XCTAssertTrue(session.prepare(plan, held: []))
        session.timing.begin(at: clock)
        let origin = clock
        for t in plan.timed.targets {
            session.timing.attack(at: origin + t.beat * plan.timed.secondsPerBeat + 0.07, pitch: t.pitch)
        }
        clock += plan.timed.duration + 1
        session.timing.tick()
        XCTAssertTrue(try XCTUnwrap(session.result).pass.report.clean)
        let id = session.result?.pass.id
        session.invalidateTiming("Output changed")
        XCTAssertEqual(session.offsetMS, 0)
        XCTAssertFalse(session.calibrated)
        XCTAssertEqual(session.result?.pass.id, id)
        XCTAssertEqual(session.result?.pass.conditions.offsetMS, 70)
    }
    @MainActor func testFallbackCalibrationIsNeverAppliedAndResetCancelsPass() throws {
        var clock = 0.0
        let session = PlayAlongSession(clock: { clock })
        let p = TimedPracticePlan.calibration()
        XCTAssertTrue(session.timing.prepare(p, conditions: .init(), held: [], calibration: true))
        session.timing.begin(at: 0)
        for t in p.targets { session.timing.attack(at: t.beat * p.secondsPerBeat + 0.08, arrivalTimestamp: true) }
        clock = p.duration + 1
        session.timing.tick()
        session.applyCalibration()
        XCTAssertFalse(session.calibrated)
        XCTAssertEqual(session.offsetMS, 0)
        let (_, plan) = try prepared()
        XCTAssertTrue(session.prepare(plan, held: []))
        session.timing.begin(at: clock)
        session.timing.receive(.init(message: .reset, keyboard: MIDIKeyboardState()))
        XCTAssertFalse(session.timing.busy)
        XCTAssertNil(session.result)
    }
    @MainActor func testHeldRepeatedAndPedalInputCannotCreateFreeHits() throws {
        var clock = 100.0
        let session = PlayAlongSession(clock: { clock })
        let (_, p) = try prepared()
        XCTAssertFalse(session.prepare(p, held: [62]))
        XCTAssertTrue(session.prepare(p, held: []))
        session.timing.begin(at: 100)
        var keyboard = MIDIKeyboardState()
        func send(_ message: MIDIMessage, _ time: Double) {
            keyboard.receive(message)
            session.timing.receive(.init(message: message, keyboard: keyboard, timestamp: time))
        }
        send(.noteOn(channel: 0, note: 62, velocity: 90), 100)
        send(.noteOn(channel: 0, note: 62, velocity: 90), 100.05)
        send(.control(channel: 0, number: 64, value: 127), 100.1)
        XCTAssertEqual(session.timing.attacks.count, 1)
        send(.noteOff(channel: 0, note: 62), 100.2)
        send(.noteOn(channel: 0, note: 62, velocity: 90), 100.25)
        XCTAssertEqual(session.timing.attacks.count, 2)
        clock = 100 + p.timed.duration + 1
        session.timing.tick()
        XCTAssertEqual(session.result?.pass.report.extras.count, 1)
        XCTAssertEqual(session.result?.grade, .again)
    }
    @MainActor func testCanceledPassAndCalibrationDoNotEnterPracticeHistory() throws {
        let (state, p) = try prepared()
        let before = state.practiceState
        XCTAssertTrue(state.playAlongSession.prepare(p, held: []))
        state.playAlongSession.timing.begin(at: PracticeClock.now())
        state.playAlongSession.timing.attack(at: PracticeClock.now(), pitch: 62)
        state.playAlongSession.timing.cancel()
        state.playAlongSession.save { try state.savePlayAlong($0) }
        XCTAssertEqual(state.practiceState, before)
        XCTAssertNil(state.playAlongSession.result)
    }
    @MainActor func testNewPassageCannotOverwritePendingPassAndChangedSourcesLeaveReviewQueue() throws {
        let (state, p) = try prepared()
        try state.savePlayAlong(result(p))
        var second = try ScoreEarChecks.document()
        second.title = "Second piece"
        state.editor.documents.append(second)
        let m = try ScoreEarChecks.material(second)
        let t = state.playAlongSession.timing
        let origin = PracticeClock.now() - p.timed.duration - 1
        XCTAssertTrue(state.playAlongSession.prepare(p, held: []))
        t.begin(at: origin)
        t.tick()
        state.openPlayAlong(m)
        XCTAssertNotNil(state.message)
        XCTAssertEqual(state.playAlongSession.plan, p)
        state.editor.documents.removeAll { "score:" + $0.id.uuidString == p.material.pieceID }
        XCTAssertTrue(state.playAlongReviews.isEmpty)
    }
    @MainActor func testKeyboardChangeInvalidatesCalibrationWithoutAnOpenView() throws {
        var clock = 0.0
        let session = PlayAlongSession(clock: { clock })
        let midi = MIDIKeyboard(preview: true)
        midi.installPreview()
        session.connect(midi)
        let plan = TimedPracticePlan.calibration()
        XCTAssertTrue(session.timing.prepare(plan, conditions: .init(), held: [], calibration: true))
        session.timing.begin(at: 0)
        for target in plan.targets { session.timing.attack(at: target.beat * plan.secondsPerBeat + 0.06) }
        clock = plan.duration + 1
        session.timing.tick()
        session.applyCalibration()
        XCTAssertEqual(session.offsetMS, 60)
        midi.choose(-101)
        XCTAssertEqual(session.offsetMS, 0)
        XCTAssertFalse(session.calibrated)
        XCTAssertNil(session.timing.calibrationReport)
        session.applyCalibration()
        XCTAssertEqual(session.offsetMS, 0)
        XCTAssertFalse(session.calibrated)
    }
    @MainActor func testPDFReviewRevocationBlocksSavedEvidence() throws {
        let (state, _) = try prepared()
        var doc = try ScoreEarChecks.document()
        doc.pdfSource = PDFScoreSource(filename: "Original.pdf", page: 2, model: "fixture", reviewed: true)
        state.editor.documents.append(doc)
        let plan = try state.playAlongPlan(ScoreEarChecks.material(doc), setup: .init())
        let index = try XCTUnwrap(state.editor.documents.firstIndex { $0.id == doc.id })
        state.editor.documents[index].pdfSource?.reviewed = false
        XCTAssertThrowsError(try state.savePlayAlong(result(plan)))
        XCTAssertNil(state.history.playAlong)
    }

}
