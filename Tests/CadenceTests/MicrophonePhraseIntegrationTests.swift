// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation
import MusicCore
import XCTest

@testable import Cadence

@MainActor private final class AcousticTestFault {
    var fail = true
    var writes = 0
}
@MainActor private final class AcousticTestClock { var value = 100.0 }
@MainActor private final class AcousticTestRoute {
    var value: MicrophoneAudioRoute? = .init(id: "synthetic-wired-route", sampleRate: 12000)
}
@MainActor private final class AcousticTestInput: MicrophoneInput {
    var handler: MicrophoneBufferHandler?
    var starts = 0
    var stops = 0
    func start(forTuner: Bool, receive: @escaping MicrophoneBufferHandler) throws {
        handler = receive
        starts += 1
    }
    func stop() {
        handler = nil
        stops += 1
    }
}
@MainActor private final class AcousticTestOutput: AcousticCountInOutput {
    let clock: AcousticTestClock
    var origin = 0.0
    var samples: [Float] = []
    var starts = 0
    var invalidClock = false
    init(clock: AcousticTestClock) { self.clock = clock }
    func schedule(render: @escaping @Sendable () throws -> [Float], ready: @escaping (Result<Double, Error>) -> Void) {
        starts += 1
        origin = clock.value + 0.2
        do {
            samples = try render()
            ready(.success(invalidClock ? .nan : origin))
        } catch { ready(.failure(error)) }
    }
    func stop() {}
}

@MainActor private final class AcousticTestHarness {
    let clock = AcousticTestClock()
    let route = AcousticTestRoute()
    let input = AcousticTestInput()
    let notifications = NotificationCenter()
    let output: AcousticTestOutput
    let microphone: Microphone
    let session: MicrophonePhraseSession
    init(permission: Bool = true) {
        output = AcousticTestOutput(clock: clock)
        microphone = Microphone(input: input, permission: { permission })
        let clock = clock
        let route = route
        session = MicrophonePhraseSession(
            output: output, clock: { clock.value }, route: { route.value },
            notifications: notifications, workspaceNotifications: NotificationCenter())
    }
    func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw MusicError.invalid("Synthetic acoustic workflow timed out: \(session.error ?? "no error")")
    }
    func calibrate(offset: Double = 0.080) async throws {
        session.calibrate(microphone: microphone)
        try await wait { session.phase == .calibrating || session.error != nil }
        guard let handler = input.handler else {
            throw MusicError.invalid(session.error ?? "No synthetic microphone handler")
        }
        let origin = output.origin
        let onsets = AcousticCalibration.pulseOffsets.map { (origin - clock.value + $0 + offset, 1000.0) }
        let signal = AcousticTestAudio.signal(duration: onsets.last!.0 + 0.35, onsets: onsets, gain: 0.18, length: 0.1)
        try await AcousticTestAudio.feed(
            handler, samples: signal, host: clock.value, analyzed: { self.microphone.phraseAnalyzedBlocks })
        clock.value = origin + AcousticCalibration.pulseOffsets.last! + 1.1
        try await wait { !session.busy }
        guard session.calibration != nil else {
            throw MusicError.invalid(session.error ?? "Calibration was not produced")
        }
    }
    func play(
        _ plan: MicrophonePhrasePlan, firstDelta: Double = 0,
        pitchOnly: Bool = false, dailyOwnerID: UUID? = nil,
        interrupted: @escaping @MainActor (Date) throws -> Void = { _ in },
        validate: @escaping @MainActor () throws -> Void = {}
    ) async throws {
        clock.value = 200
        session.start(
            plan, microphone: microphone, pitchOnly: pitchOnly, dailyOwnerID: dailyOwnerID, interrupted: interrupted,
            validate: validate)
        try await wait { session.phase == .countIn || session.error != nil }
        guard let handler = input.handler else { throw MusicError.invalid(session.error ?? "No phrase handler") }
        let origin = output.origin
        let offset = pitchOnly ? 0 : session.calibration!.offsetMS / 1000
        let onsets = plan.timed.targets.enumerated().map { index, target in
            (
                origin - clock.value + plan.timed.countIn + target.beat * plan.timed.secondsPerBeat + offset
                    + (index == 0 ? firstDelta : 0),
                440 * pow(2, Double(target.pitch - 69) / 12)
            )
        }
        let duration = origin - clock.value + plan.timed.countIn + plan.timed.duration + 1.4
        let signal = AcousticTestAudio.signal(duration: duration, onsets: onsets, length: 0.25)
        try await AcousticTestAudio.feed(
            handler, samples: signal, host: clock.value, analyzed: { self.microphone.phraseAnalyzedBlocks })
        clock.value = origin + plan.timed.countIn + plan.timed.duration + 1.5
        try await wait { !session.busy }
    }
}

final class MicrophonePhraseIntegrationTests: XCTestCase {
    @MainActor private func daily(_ harness: AcousticTestHarness) throws -> AppState {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let state = AppState(storageOverride: directory, microphoneSession: harness.session)
        addTeardownBlock {
            await MainActor.run {
                state.stopAllPlayback()
                state.midi.shutdown()
            }
            try? FileManager.default.removeItem(at: directory)
        }
        try state.startSongJourney(instrument: .guitar)
        try state.openEarDaily(XCTUnwrap(state.selectedSongJourney))
        let id = try XCTUnwrap(state.earDailySession?.id)
        try state.hearEarDaily(id, play: { _ in })
        try state.updateEarDaily(id) { try $0.imagined() }
        var book = state.microphonePhrases
        try book.open(state.earDailyMicrophonePlan(XCTUnwrap(state.earDailySession)))
        var snapshot = state.practiceState
        snapshot.microphonePhrases = book
        try state.commitPractice(snapshot)
        return state
    }

    @MainActor func testDailyPCMOwnerReturnsToDailyAndSavesOnePitchOnlyResult() async throws {
        let harness = AcousticTestHarness()
        let state = try daily(harness)
        let session = try XCTUnwrap(state.earDailySession)
        let plan = try state.earDailyMicrophonePlan(session)
        try await harness.play(plan, pitchOnly: true, dailyOwnerID: session.id)
        XCTAssertTrue(harness.session.hasUnsavedTake)
        XCTAssertEqual(harness.session.dailyOwnerID, session.id)
        state.showMicrophonePhrases()
        XCTAssertEqual(state.practicePage, .earDaily)
        harness.session.save(using: state.saveMicrophoneTake)
        XCTAssertNil(harness.session.pending)
        XCTAssertNil(harness.session.dailyOwnerID)
        XCTAssertEqual(state.earDailySession?.stage, .review)
        XCTAssertEqual(state.earDailyLatestAttempt?.input, .microphone)
        XCTAssertEqual(state.earDailyLatestAttempt?.outcome, .correct)
        XCTAssertNil(state.earDailyLatestAttempt?.timedPracticeID)
        XCTAssertEqual(state.journal.checked.count, 1)
    }

    @MainActor func testCancelledDailyCountInCannotOwnOrdinaryCoachedCapture() async throws {
        let harness = AcousticTestHarness()
        let state = try daily(harness)
        let session = try XCTUnwrap(state.earDailySession)
        let plan = try state.earDailyMicrophonePlan(session)
        harness.session.start(
            plan, microphone: harness.microphone, pitchOnly: true, dailyOwnerID: session.id, validate: {})
        try await harness.wait { harness.session.phase == .countIn }
        harness.session.cancel()
        XCTAssertNil(harness.session.dailyOwnerID)
        state.showMicrophonePhrases()
        XCTAssertEqual(state.practicePage, .microphonePhrase)
        try await harness.play(plan, pitchOnly: true)
        harness.session.save(using: state.saveMicrophoneTake)
        XCTAssertEqual(state.earDailySession?.stage, .play)
        XCTAssertTrue(state.earDailySession!.attemptIDs.isEmpty)
        XCTAssertNil(state.earDailyLatestAttempt)
    }

    @MainActor func testDailyPendingTakeArchivesWhenOnlyTransferSourceChanged() async throws {
        let harness = AcousticTestHarness()
        let state = try daily(harness)
        let session = try XCTUnwrap(state.earDailySession)
        try await harness.play(state.earDailyMicrophonePlan(session), pitchOnly: true, dailyOwnerID: session.id)
        let take = try XCTUnwrap(harness.session.pending)
        let journey = try XCTUnwrap(state.selectedSongJourney)
        var scores = state.editor
        let index = try XCTUnwrap(
            scores.documents.firstIndex { "score:" + $0.id.uuidString == journey.transfer.pieceID })
        let position = Guitar.positions(
            midi: 55, tuning: scores.documents[index].tuning, capo: scores.documents[index].capo)[0]
        scores.documents[index].events[0].pitches = [EditorPitch(55, string: position.string, fret: position.fret)]
        try state.commitScores(scores)
        XCTAssertNoThrow(try state.validateMicrophonePhrase(take.plan))
        XCTAssertThrowsError(try state.validateEarDaily(session))
        try state.resumeEarDaily(session.id)
        harness.session.save(using: state.saveMicrophoneTake)
        XCTAssertNil(harness.session.pending)
        XCTAssertEqual(state.microphonePhrases.active?.latest?.isArchivalOnly, true)
        XCTAssertTrue(state.journal.checked.isEmpty)
        XCTAssertTrue(state.earDailySession!.attemptIDs.isEmpty)
    }

    @MainActor func testDailyTakeSaveFailureRetainsPCMResultWithoutPublishingReferences() async throws {
        let harness = AcousticTestHarness()
        let state = try daily(harness)
        let session = try XCTUnwrap(state.earDailySession)
        try await harness.play(state.earDailyMicrophonePlan(session), pitchOnly: true, dailyOwnerID: session.id)
        let take = try XCTUnwrap(harness.session.pending)
        let url = state.stores.practice.url
        let bytes = try Data(contentsOf: url)
        try Data("external conflict".utf8).write(to: url)
        harness.session.save(using: state.saveMicrophoneTake)
        XCTAssertEqual(harness.session.pending, take)
        XCTAssertTrue(state.journal.checked.isEmpty)
        XCTAssertTrue(state.earDailySession!.attemptIDs.isEmpty)
        XCTAssertTrue(state.microphonePhrases.active!.takes.isEmpty)
        try bytes.write(to: url)
        harness.session.save(using: state.saveMicrophoneTake)
        XCTAssertNil(harness.session.pending)
        XCTAssertEqual(state.earDailySession?.attemptIDs, [take.id])
        XCTAssertEqual(state.journal.checked.count, 1)
    }

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
        try state.addMicrophoneExample()
        return state
    }

    @MainActor func testMeasuredLoopbackAndPhraseUseOneCorrectionAndSilentPerformance() async throws {
        let state = try prepared()
        let plan = state.microphonePhraseSession.plan!
        let h = AcousticTestHarness()
        defer { h.session.cancel() }
        try await h.calibrate()
        XCTAssertTrue(h.session.calibratedForCurrentRoute())
        XCTAssertEqual(h.session.calibration!.offsetMS, 80, accuracy: 12)
        XCTAssertNotNil(h.session.calibration!.clockEvidence)
        XCTAssertTrue(state.journal.attempts.isEmpty, "Calibration grants no musical credit")
        try await h.play(plan)
        let take = try XCTUnwrap(h.session.pending, h.session.error ?? "Missing take")
        XCTAssertTrue(take.valid)
        XCTAssertTrue(take.report.clean, take.evidence)
        XCTAssertEqual(take.attacks.count, plan.timed.targets.count)
        XCTAssertTrue(take.attacks.allSatisfy { $0.sampleTime != nil && $0.sampleRate == 12000 })
        let endOfCountIn = Int(ceil(plan.timed.countIn * 44100))
        XCTAssertTrue(h.output.samples.dropFirst(endOfCountIn).allSatisfy { $0 == 0 })
        h.session.save(using: state.saveMicrophoneTake)
        XCTAssertNil(h.session.pending)
        XCTAssertEqual(state.microphonePhrases.active?.takes.count, 1)
        XCTAssertEqual(state.journal.attempts.last?.input, .microphone)
        XCTAssertTrue(state.journal.attempts.last?.assisted == true)
        let restored = AppState(storageOverride: state.storage)
        defer { restored.midi.shutdown() }
        XCTAssertEqual(restored.microphonePhrases, state.microphonePhrases)
        XCTAssertEqual(restored.practiceState.schemaVersion, 18)
    }

    @MainActor func testFailedAtomicSaveRetainsExactTakeAndRetryDoesNotRecapture() async throws {
        let state = try prepared()
        let h = AcousticTestHarness()
        defer { h.session.cancel() }
        try await h.calibrate()
        try await h.play(state.microphonePhraseSession.plan!)
        let take = try XCTUnwrap(h.session.pending)
        let previous = state.practiceState
        let url = state.stores.practice.url
        let bytes = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        h.session.save(using: state.saveMicrophoneTake)
        XCTAssertEqual(h.session.pending, take)
        XCTAssertEqual(state.practiceState, previous)
        let starts = h.input.starts
        h.session.cancel()
        XCTAssertEqual(h.session.pending, take, "Navigation/Stop keeps completed unsaved work")
        try FileManager.default.removeItem(at: url)
        try bytes.write(to: url)
        h.session.save(using: state.saveMicrophoneTake)
        h.session.save(using: state.saveMicrophoneTake)
        XCTAssertNil(h.session.pending)
        XCTAssertEqual(h.input.starts, starts)
        XCTAssertEqual(state.microphonePhrases.active?.takes.count, 1)
        XCTAssertEqual(state.journal.attempts.count, 1)
    }

    @MainActor func testChangedSourceArchivesExactEvidenceWithoutCurrentScoreCredit() async throws {
        let state = try prepared()
        let h = AcousticTestHarness()
        defer { h.session.cancel() }
        try await h.calibrate()
        try await h.play(state.microphonePhraseSession.plan!)
        let take = try XCTUnwrap(h.session.pending)
        let index = state.editor.documents.firstIndex { $0.id == MicrophonePhraseExample.id }!
        state.editor.documents[index].events[0].pitches = [.init(53, string: 2, fret: 3)]
        h.session.save(using: state.saveMicrophoneTake)
        XCTAssertNil(h.session.pending)
        XCTAssertNil(h.session.error)
        let archived = try XCTUnwrap(state.microphonePhrases.active?.latest)
        XCTAssertTrue(archived.isArchivalOnly)
        XCTAssertEqual(archived.attacks, take.attacks)
        XCTAssertEqual(archived.plan, take.plan)
        XCTAssertFalse(archived.report.conclusive)
        XCTAssertEqual(h.session.displayedTake, archived)
        XCTAssertFalse(h.session.displayedTake?.report.conclusive ?? true)
        XCTAssertNil(state.microphonePhrases.active?.baseline)
        XCTAssertTrue(state.journal.attempts.isEmpty)
        XCTAssertEqual(state.microphonePhrases.active?.review, ReviewSchedule())
    }

    @MainActor func testPermissionFailureAndUnusableOutputClockCannotStartAssessment() async throws {
        let denied = AcousticTestHarness(permission: false)
        denied.session.calibrate(microphone: denied.microphone)
        try await denied.wait { !denied.session.busy }
        XCTAssertEqual(denied.input.starts, 0)
        XCTAssertEqual(denied.output.starts, 0)
        XCTAssertNotNil(denied.session.error)
        let invalid = AcousticTestHarness()
        invalid.output.invalidClock = true
        invalid.session.calibrate(microphone: invalid.microphone)
        try await invalid.wait { !invalid.session.busy }
        XCTAssertNil(invalid.session.calibration)
        XCTAssertNil(invalid.session.pending)
        XCTAssertFalse(invalid.microphone.listening)
    }

    @MainActor func testRouteChangeInvalidatesMeasurementAndCancelsCapture() async throws {
        let h = AcousticTestHarness()
        try await h.calibrate()
        h.route.value = .init(id: "another-route", sampleRate: 48000)
        h.notifications.post(name: .AVAudioEngineConfigurationChange, object: nil)
        try await h.wait { h.session.calibration == nil }
        XCTAssertFalse(h.session.calibratedForCurrentRoute())
        XCTAssertFalse(h.microphone.listening)
    }

    @MainActor func testIndependentWithoutBaselineIsRejectedBeforePermissionOrCapture() throws {
        let state = try prepared()
        let independent = try state.microphonePhraseSession.plan!.whole(mode: .independent)
        XCTAssertThrowsError(try state.startMicrophoneTake(independent, pitchOnly: false))
        XCTAssertFalse(state.microphone.listening)
        XCTAssertTrue(state.journal.attempts.isEmpty)
    }
    @MainActor func testEngineConfigurationChangeInvalidatesEvenWhenRouteFingerprintMatches() async throws {
        let h = AcousticTestHarness()
        defer { h.session.cancel() }
        try await h.calibrate()
        h.notifications.post(name: .AVAudioEngineConfigurationChange, object: nil)
        try await h.wait { h.session.calibration == nil }
        XCTAssertFalse(h.session.busy)
        h.session.calibrate(microphone: h.microphone)
        try await h.wait { h.session.phase == .calibrating }
        h.notifications.post(name: .AVAudioEngineConfigurationChange, object: nil)
        try await h.wait { !h.session.busy }
        XCTAssertNil(h.session.calibration)
        XCTAssertNil(h.input.handler)
    }

    @MainActor func testChannelChangeInvalidatesTimingAndUnavailableInputNeverStarts() async throws {
        let h = AcousticTestHarness()
        try await h.calibrate()
        h.session.inputChannel = 1
        XCTAssertNil(h.session.calibration)
        XCTAssertFalse(h.session.calibratedForCurrentRoute())
        let invalid = Microphone(input: h.input, permission: { true })
        await invalid.startPhrase(channel: -1)
        XCTAssertFalse(invalid.listening)
        XCTAssertTrue(invalid.error?.contains("channel") == true)
        h.session.cancel()
    }

    @MainActor func testTruncatedPCMDoesNotTurnUncapturedTargetsIntoMistakes() async throws {
        let state = try prepared()
        let plan = state.microphonePhraseSession.plan!
        let h = AcousticTestHarness()
        defer { h.session.cancel() }
        try await h.calibrate()
        h.clock.value = 200
        h.session.start(plan, microphone: h.microphone, pitchOnly: false, validate: {})
        try await h.wait { h.session.phase == .countIn }
        let onset = h.output.origin - h.clock.value + plan.timed.countIn + 0.08
        let firstPitch = plan.timed.targets[0].pitch
        try await AcousticTestAudio.feed(
            h.input.handler!,
            samples: AcousticTestAudio.signal(
                duration: onset + 0.35,
                onsets: [(onset, 440 * pow(2, Double(firstPitch - 69) / 12))]), host: h.clock.value)
        h.clock.value = h.output.origin + plan.timed.countIn + plan.timed.duration + 0.8
        try await h.wait { !h.session.busy }
        let take = try XCTUnwrap(h.session.pending)
        XCTAssertFalse(take.report.conclusive)
        XCTAssertEqual(take.report.missing, 0)
        XCTAssertTrue(take.scoreFeedback.allSatisfy { $0.assessment.verdict != .missed })
    }

    @MainActor func testInterruptedPlayingRecordsExposureAndRetriesOnlyTheFailedSave() async throws {
        let state = try prepared()
        let plan = state.microphonePhraseSession.plan!
        let h = AcousticTestHarness()
        defer { h.session.cancel() }
        try await h.calibrate()
        let fault = AcousticTestFault()
        h.clock.value = 200
        h.session.start(
            plan, microphone: h.microphone, pitchOnly: false,
            interrupted: { date in
                fault.writes += 1
                if fault.fail { throw MusicError.invalid("Synthetic storage conflict") }
                try state.noteMicrophonePractice(plan, at: date)
            }, validate: {})
        try await h.wait { h.session.phase == .countIn }
        h.clock.value = h.output.origin + plan.timed.countIn + 0.1
        h.session.cancel()
        XCTAssertEqual(fault.writes, 1)
        XCTAssertTrue(h.session.needsExposureSave)
        XCTAssertTrue(state.journal.attempts.isEmpty)
        let starts = h.input.starts
        fault.fail = false
        XCTAssertTrue(h.session.retryExposureSave())
        XCTAssertFalse(h.session.needsExposureSave)
        XCTAssertEqual(h.input.starts, starts)
        XCTAssertNotNil(state.microphonePhrases.active?.unkeptPracticeDates.last)
        XCTAssertTrue(state.journal.attempts.isEmpty, "Interrupted practice is exposure, never an invented grade")
        XCTAssertTrue(state.microphonePhrases.returnDate(plan.key)! > Date())
    }

    @MainActor func testEarlyFirstGuitarNoteWithinToleranceIsNotCountInContamination() async throws {
        let state = try prepared()
        let h = AcousticTestHarness()
        defer { h.session.cancel() }
        try await h.calibrate()
        try await h.play(state.microphonePhraseSession.plan!, firstDelta: -0.05)
        let take = try XCTUnwrap(h.session.pending)
        XCTAssertNil(take.signalIssue)
        XCTAssertTrue(take.report.clean, take.evidence)
        let quietStart = Int(((take.plan.timed.countIn - take.plan.timed.secondsPerBeat) * 44100).rounded())
        XCTAssertTrue(h.output.samples.dropFirst(quietStart).allSatisfy { $0 == 0 })
    }

    @MainActor func testFinalValidationFailureRetainsUngradedPracticeExposure() async throws {
        let state = try prepared()
        let plan = state.microphonePhraseSession.plan!
        let h = AcousticTestHarness()
        let fault = AcousticTestFault()
        defer { h.session.cancel() }
        try await h.calibrate()
        try await h.play(
            plan, interrupted: { try state.noteMicrophonePractice(plan, at: $0) },
            validate: {
                fault.writes += 1
                if fault.writes > 1 { throw MusicError.invalid("Synthetic final source change") }
            })
        XCTAssertNil(h.session.pending)
        XCTAssertNotNil(h.session.error)
        XCTAssertNotNil(state.microphonePhrases.active?.unkeptPracticeDates.last)
        XCTAssertTrue(state.journal.attempts.isEmpty)
    }

    @MainActor func testLargeMeasuredDelayCapturesCompleteFinalShortNoteWindow() async throws {
        var doc = try EditorDocument.blank(instrument: .guitar, bars: 1)
        doc.events = [EditorRhythm(960), EditorRhythm(480), EditorRhythm(240, dotted: true), EditorRhythm(120)].map {
            EditorEvent(bar: 0, rhythm: $0, pitches: [.init(52, string: 2, fret: 2)])
        }
        doc = try doc.validated()
        let source = LibraryPiece(source: .score(doc))
        let material = try ScoreEarMaterial(
            piece: source, scope: .init(fromBar: 1, throughBar: 1, partID: "P1", partName: "Guitar"), staff: 1,
            voice: "1")
        let plan = try MicrophonePhrasePlan(material: material, tempo: 50, source: source)
        let h = AcousticTestHarness()
        defer { h.session.cancel() }
        try await h.calibrate(offset: 0.490)
        try await h.play(plan)
        let take = try XCTUnwrap(h.session.pending)
        XCTAssertGreaterThan(take.calibration!.offsetMS, 480)
        XCTAssertTrue(take.report.clean, take.evidence)
    }

    @MainActor func testHearingGuideAfterFailedEncounterSaveCannotWedgeRecovery() async throws {
        let state = try prepared()
        let plan = state.microphonePhraseSession.plan!
        let h = AcousticTestHarness()
        let fault = AcousticTestFault()
        defer { h.session.cancel() }
        try await h.calibrate()
        h.session.start(
            plan, microphone: h.microphone, pitchOnly: false,
            interrupted: { date in
                if fault.fail { throw MusicError.invalid("Synthetic disk conflict") }
                try state.noteMicrophonePractice(plan, at: date)
            }, validate: {})
        try await h.wait { h.session.phase == .countIn }
        h.clock.value = h.output.origin + plan.timed.countIn + 0.1
        h.session.cancel()
        XCTAssertTrue(h.session.needsExposureSave)
        fault.fail = false
        try state.hearMicrophonePhrase(plan, play: { _ in })
        let afterGuide = state.microphonePhrases.returnDate(plan.key)
        XCTAssertTrue(h.session.retryExposureSave())
        XCTAssertFalse(h.session.needsExposureSave)
        XCTAssertEqual(state.microphonePhrases.returnDate(plan.key), afterGuide)
        XCTAssertTrue(state.journal.attempts.isEmpty)
    }

}
