// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class EarDailySessionTests: XCTestCase {
    func testDailyRecommendationOffersDueRecallThenTransferWithoutTurningEarlyPracticeIntoReview() {
        func choose(_ completed: Bool, _ independent: Bool, _ familiar: Date?, _ transfer: Date?, now: Date? = nil)
            -> EarDailyMode
        {
            EarDailyRecommendation.choose(
                completed: completed, independentFamiliar: independent,
                familiarDue: familiar, transferDue: transfer, now: now ?? date
            ).mode
        }
        XCTAssertEqual(choose(false, false, nil, nil), .learning)
        XCTAssertEqual(choose(true, false, date.addingTimeInterval(1), date), .learning)
        XCTAssertEqual(choose(true, false, date, date), .recall)
        XCTAssertEqual(choose(true, true, date.addingTimeInterval(-1), date), .transfer)
        XCTAssertEqual(choose(true, true, date, date.addingTimeInterval(1)), .recall)
        XCTAssertEqual(choose(true, true, date.addingTimeInterval(100), date), .transfer)
        XCTAssertEqual(choose(true, true, date, date, now: Date(timeIntervalSince1970: .nan)), .learning)
    }

    func testRearmingPersistsSupportAndReviewCanFinishWithoutAnotherComposition() throws {
        var recall = try playing(session(mode: .recall))
        try recall.beganAttempt(now: date)
        XCTAssertFalse(recall.assisted)
        recall = try JSONDecoder().decode(EarDailySession.self, from: JSONEncoder().encode(recall))
        try recall.beganAttempt(now: date.addingTimeInterval(1))
        XCTAssertTrue(recall.assisted)
        try recall.record(attemptID: UUID(), now: date.addingTimeInterval(2))
        try recall.finishReview(now: date.addingTimeInterval(3))
        XCTAssertEqual(recall.stage, .complete)
        var learning = try reviewing(session())
        XCTAssertThrowsError(try learning.finishReview(now: date))
        XCTAssertEqual(learning.stage, .review)
    }

    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let origin = 1000.0
    private let route = "daily-ear-fixture"

    private func document(
        instrument: EditorInstrument = .piano, meter: EditorMeter = EditorMeter(4, 4)
    ) throws -> EditorDocument {
        let rhythm: EditorRhythm
        switch meter.beats {
        case 2: rhythm = EditorRhythm(480)
        case 3: rhythm = EditorRhythm(480, dotted: true)
        default: rhythm = EditorRhythm(960)
        }
        var events = (0..<4).flatMap { bar in
            [52 + bar * 2, 55 + bar * 2].map { midi in
                let pitch: EditorPitch
                if instrument == .guitar {
                    let position = Guitar.positions(midi: midi, tuning: Tuning.presets[0], capo: 0).min {
                        $0.fret < $1.fret
                    }!
                    pitch = EditorPitch(midi, string: position.string, fret: position.fret)
                } else {
                    pitch = EditorPitch(midi)
                }
                return EditorEvent(bar: bar, rhythm: rhythm, pitches: [pitch])
            }
        }
        if instrument == .piano {
            let rest = meter.beats == 3 ? EditorRhythm(960, dotted: true) : EditorRhythm(meter.ticks)
            events += (0..<4).map { EditorEvent(bar: $0, staff: 2, rhythm: rest) }
        }
        var document = EditorDocument(title: "An original daily phrase", instrument: instrument, events: events)
        document.meter = meter
        return try document.validated()
    }

    private func material(_ document: EditorDocument, from: Int = 1, through: Int = 4) throws -> ScoreEarMaterial {
        try ScoreEarMaterial(
            piece: LibraryPiece(source: .score(document)),
            scope: PieceScope(fromBar: from, throughBar: through, partID: "P1", partName: document.instrument.rawValue),
            staff: 1, voice: "1")
    }

    private func session(
        _ material: ScoreEarMaterial? = nil, instrument: EditorInstrument = .piano,
        mode: EarDailyMode = .learning
    ) throws -> EarDailySession {
        try EarDailySession(
            journeyID: UUID(), material: material ?? self.material(document(instrument: instrument)),
            instrument: instrument, mode: mode, reviewReadyAt: mode == .learning ? nil : date, now: date)
    }

    private func playing(_ original: EarDailySession) throws -> EarDailySession {
        var session = original
        if session.stage == .hear { try session.heard(now: date) }
        try session.imagined(now: date)
        return session
    }

    private func reviewing(_ original: EarDailySession) throws -> EarDailySession {
        var session = try playing(original)
        try session.record(attemptID: UUID(), now: date)
        return session
    }

    private func completed(_ original: EarDailySession) throws -> EarDailySession {
        var session = try reviewing(original)
        try session.beginAnswer(now: date)
        try session.finish(now: date)
        return session
    }

    private func reject(
        _ original: EarDailySession, file: StaticString = #filePath, line: UInt = #line,
        _ action: (inout EarDailySession) throws -> Void
    ) {
        var session = original
        XCTAssertThrowsError(try action(&session), file: file, line: line)
        XCTAssertEqual(session, original, file: file, line: line)
    }

    private func rejectDates(
        _ session: EarDailySession, file: StaticString = #filePath, line: UInt = #line,
        _ action: (inout EarDailySession, Date) throws -> Void
    ) {
        for now in [
            date.addingTimeInterval(-1), Date(timeIntervalSince1970: .nan),
            Date(timeIntervalSince1970: .infinity), Date(timeIntervalSince1970: -.infinity),
        ] {
            reject(session, file: file, line: line) { try action(&$0, now) }
        }
    }

    private func changed(
        _ session: EarDailySession, _ edit: (inout [String: Any]) -> Void
    ) throws -> EarDailySession {
        try JSONDecoder().decode(EarDailySession.self, from: changedData(session, edit))
    }

    private func changedData(
        _ session: EarDailySession, _ edit: (inout [String: Any]) -> Void
    ) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func frequency(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }

    private func plan(from: Int = 1, through: Int = 4) throws -> MicrophonePhrasePlan {
        let document = try document(instrument: .guitar)
        return try MicrophonePhrasePlan(
            material: material(document, from: from, through: through),
            source: LibraryPiece(source: .score(document)))
    }

    private func take(
        _ plan: MicrophonePhrasePlan, calibrated: Bool = false, delta: Double = 0
    ) -> MicrophonePhraseTake {
        let mapping = AcousticClockEvidence(
            firstSampleTime: 4800, firstHostSeconds: origin - 0.5, sampleRate: 48000,
            frameCount: Int(ceil((plan.timed.duration + 2) * 48000)), maximumHostResidualMS: 2)
        let calibration = AcousticCalibration(
            routeID: route, sampleRate: 48000, offsetMS: 120, jitterMS: 5, date: date, matchedPulses: 8,
            clockEvidence: AcousticClockEvidence(
                firstSampleTime: 4800, firstHostSeconds: origin - 100, sampleRate: 48000,
                frameCount: 384000, maximumHostResidualMS: 2))
        let attacks = plan.timed.targets.map { target in
            let host = origin + target.beat * plan.timed.secondsPerBeat + (calibrated ? 0.120 : 0) + delta
            var attack = AcousticAttack(
                hostSeconds: host, frequency: frequency(target.pitch), confidence: 0.98, rms: 0.1,
                clippedFraction: 0, onsetUncertaintyMS: 10)
            attack.sampleTime = mapping.sampleTime(at: host)
            attack.sampleRate = mapping.sampleRate
            return attack
        }
        return MicrophonePhraseTake(
            date: date, plan: plan, originHostSeconds: origin, calibration: calibrated ? calibration : nil,
            routeID: route, sampleRate: 48000, attacks: attacks, clock: .sharedHost, clockEvidence: mapping)
    }

    func testLearningFollowsExplicitStagesAndEvidenceDoesNotAdvanceIt() throws {
        var session = try session()
        let answer = session.answerID
        XCTAssertEqual(session.stage, .hear)
        XCTAssertTrue(session.assisted)
        XCTAssertTrue(session.valid)
        reject(session) { try $0.imagined(now: date) }
        reject(session) { try $0.finish(now: date) }
        try session.heard(now: date)
        XCTAssertEqual(session.stage, .imagine)
        reject(session) { try $0.beginAnswer(now: date) }
        try session.imagined(now: date)
        let before = session
        let attempt = try session.midiAttempt(notes: session.expectedNotes, now: date)
        XCTAssertEqual(session, before)
        XCTAssertEqual(attempt.outcome, .correct)
        XCTAssertTrue(attempt.assisted)
        try session.record(attemptID: attempt.id, now: date)
        XCTAssertEqual(session.stage, .review)
        XCTAssertEqual(session.attemptIDs, [attempt.id])
        try session.beginAnswer(now: date)
        XCTAssertEqual(session.stage, .create)
        try session.finish(now: date.addingTimeInterval(10))
        XCTAssertEqual(session.stage, .complete)
        XCTAssertEqual(session.answerID, answer)
        XCTAssertEqual(session.completedAt, date.addingTimeInterval(10))
        XCTAssertTrue(session.valid)
        reject(session) { try $0.retry(now: date.addingTimeInterval(10)) }
        reject(session) { try $0.finish(now: date.addingTimeInterval(10)) }
    }

    func testRecallAndTransferRequireFiniteReadyDateAndBeginWithoutSupport() throws {
        let material = try material(document())
        for mode in [EarDailyMode.recall, .transfer] {
            for ready in [
                nil, date.addingTimeInterval(1), Date(timeIntervalSince1970: .nan),
                Date(timeIntervalSince1970: .infinity),
            ] as [Date?] {
                XCTAssertThrowsError(
                    try EarDailySession(
                        journeyID: UUID(), material: material, instrument: .piano, mode: mode,
                        reviewReadyAt: ready, now: date))
            }
            let initial = try session(material, mode: mode)
            XCTAssertEqual(initial.stage, mode == .transfer ? .hear : .imagine)
            XCTAssertFalse(initial.assisted)
            var session = try playing(initial)
            XCTAssertFalse(session.assisted)
            try session.beganAttempt(now: date.addingTimeInterval(1))
            XCTAssertFalse(session.assisted)
            XCTAssertEqual(session.lastExposure, date.addingTimeInterval(1))
            XCTAssertFalse(
                try session.midiAttempt(notes: session.expectedNotes, now: date.addingTimeInterval(1)).assisted)
        }
        var invalid = material
        invalid.melody = []
        XCTAssertThrowsError(try session(invalid))
        for now in [Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity)] {
            XCTAssertThrowsError(
                try EarDailySession(
                    journeyID: UUID(), material: material, instrument: .piano, mode: .learning, now: now))
        }
    }

    func testTransferFirstHearingSuppliesNewStimulusAndOnlyRepeatedHearingAddsSupport() throws {
        let initial = try session(mode: .transfer)
        XCTAssertEqual(initial.stage, .hear)
        XCTAssertFalse(initial.assisted)
        XCTAssertTrue(initial.valid)
        reject(initial) { try $0.imagined(now: date) }
        var heard = initial
        try heard.heard(now: date.addingTimeInterval(1))
        XCTAssertEqual(heard.stage, .imagine)
        XCTAssertFalse(heard.assisted)
        XCTAssertEqual(heard.lastExposure, date.addingTimeInterval(1))
        var imagined = initial
        try imagined.heard(now: date)
        try imagined.imagined(now: date)
        XCTAssertFalse(try imagined.midiAttempt(notes: imagined.expectedNotes, now: date).assisted)
        for original in [heard, try playing(initial), try reviewing(initial)] {
            XCTAssertFalse(original.assisted)
            var replayed = original
            try replayed.heard(now: date.addingTimeInterval(2))
            XCTAssertEqual(replayed.stage, original.stage)
            XCTAssertTrue(replayed.assisted)
            XCTAssertTrue(replayed.valid)
        }
        let restored = try JSONDecoder().decode(EarDailySession.self, from: JSONEncoder().encode(initial))
        XCTAssertEqual(restored, initial)
        let heardRestored = try JSONDecoder().decode(EarDailySession.self, from: JSONEncoder().encode(heard))
        XCTAssertEqual(heardRestored, heard)
    }

    func testEveryEventRejectsLateAndNonfiniteDatesWithoutMutation() throws {
        let hear = try session()
        let imagine = try session(mode: .recall)
        let play = try playing(imagine)
        let review = try reviewing(imagine)
        var create = review
        try create.beginAnswer(now: date)
        let complete = try completed(imagine)
        rejectDates(hear) { try $0.heard(now: $1) }
        rejectDates(imagine) { try $0.imagined(now: $1) }
        rejectDates(play) { try $0.beganAttempt(now: $1) }
        rejectDates(play) { try $0.reveal(now: $1) }
        rejectDates(review) { try $0.retry(bar: 1, now: $1) }
        rejectDates(play) { try $0.record(attemptID: UUID(), now: $1) }
        rejectDates(imagine) { try $0.skip(now: $1) }
        rejectDates(review) { try $0.beginAnswer(now: $1) }
        rejectDates(create) { try $0.finish(now: $1) }
        rejectDates(complete) { try $0.noteExposure(now: $1) }
        reject(hear) { try $0.beganAttempt(now: date) }
        reject(imagine) { try $0.beganAttempt(now: date) }
        reject(review) { try $0.beganAttempt(now: date) }
        XCTAssertThrowsError(try play.midiAttempt(notes: play.expectedNotes, now: date.addingTimeInterval(-1)))
        XCTAssertThrowsError(
            try play.midiAttempt(notes: play.expectedNotes, now: Date(timeIntervalSince1970: .infinity)))
    }

    func testReplayRevealAndSkippingMarkSupportWithoutInventingAttempts() throws {
        let imagine = try session(mode: .recall)
        let play = try playing(imagine)
        let review = try reviewing(imagine)
        for original in [imagine, play, review] {
            var replayed = original
            try replayed.heard(now: date.addingTimeInterval(1))
            XCTAssertEqual(replayed.stage, original.stage)
            XCTAssertTrue(replayed.assisted)
            XCTAssertFalse(replayed.revealed)
            XCTAssertEqual(replayed.attemptIDs, original.attemptIDs)
            var revealed = original
            try revealed.reveal(now: date)
            XCTAssertEqual(revealed.stage, original.stage)
            XCTAssertTrue(revealed.revealed)
            XCTAssertTrue(revealed.assisted)
            var skipped = original
            try skipped.skip(now: date)
            XCTAssertEqual(skipped.stage, .create)
            XCTAssertTrue(skipped.assisted)
            XCTAssertEqual(skipped.attemptIDs, original.attemptIDs)
        }
        reject(try session()) { try $0.skip(now: date) }
        var answer = review
        try answer.beginAnswer(now: date)
        XCTAssertFalse(answer.assisted)
        reject(answer) { try $0.heard(now: date) }
        reject(answer) { try $0.reveal(now: date) }
    }

    func testExposureAtEveryStagePreservesCompletedHistoryAndDelaysReturn() throws {
        let independent = try session(mode: .recall)
        var create = try reviewing(independent)
        try create.beginAnswer(now: date)
        for original in [try session(), independent, try playing(independent), try reviewing(independent), create] {
            var exposed = original
            try exposed.noteExposure(now: date.addingTimeInterval(20))
            XCTAssertEqual(exposed.stage, original.stage)
            XCTAssertEqual(exposed.attemptIDs, original.attemptIDs)
            XCTAssertTrue(exposed.assisted)
            XCTAssertEqual(exposed.lastExposure, date.addingTimeInterval(20))
            XCTAssertTrue(exposed.valid)
        }
        for original in [try completed(independent), try completed(session())] {
            var practice = EarDailyPractice()
            try practice.open(original)
            var exposed = original
            try exposed.noteExposure(now: date.addingTimeInterval(3600))
            XCTAssertEqual(exposed.completedAt, original.completedAt)
            XCTAssertEqual(exposed.assisted, original.assisted)
            XCTAssertTrue(exposed.valid)
            try practice.replace(exposed)
            XCTAssertEqual(practice.returnDate(material: exposed.material), date.addingTimeInterval(25 * 3600))
        }
    }

    func testAbsoluteFocusUsesCompleteMaterialMeterAndNilReturnsToWhole() throws {
        let material = try material(document(meter: EditorMeter(3, 4)), from: 2, through: 4)
        var session = try reviewing(session(material, mode: .recall))
        let activity = session.activityID
        let answer = session.answerID
        reject(session) { try $0.retry(bar: 1, now: date) }
        reject(session) { try $0.retry(bar: 5, now: date) }
        try session.retry(bar: 3, now: date)
        XCTAssertEqual(session.focusBar, 3)
        XCTAssertEqual(session.expectedNotes, [56, 59])
        XCTAssertTrue(session.assisted)
        let focused = try session.midiAttempt(notes: [56, 59], now: date)
        XCTAssertEqual(focused.outcome, .correct)
        XCTAssertEqual(focused.passageScope, PassageScope(partID: "P1", staff: 1, from: 2, through: 2))
        try session.record(attemptID: focused.id, now: date)
        try session.retry(now: date)
        XCTAssertNil(session.focusBar)
        XCTAssertEqual(session.expectedNotes, material.melody.map(\.midi))
        XCTAssertEqual(session.activityID, activity)
        XCTAssertEqual(session.answerID, answer)
        XCTAssertTrue(session.assisted)
    }

    func testRecordBoundsReferencesAndOnlyLatestReviewDuplicateIsIdempotent() throws {
        var session = try playing(session(mode: .recall))
        for index in 0..<32 {
            if index > 0 { try session.retry(now: date) }
            try session.record(attemptID: UUID(), now: date)
        }
        XCTAssertEqual(session.attemptIDs.count, 32)
        let fullReview = session
        try session.record(attemptID: session.attemptIDs.last!, now: date.addingTimeInterval(1))
        XCTAssertEqual(session, fullReview)
        reject(session) { try $0.record(attemptID: session.attemptIDs[0], now: date) }
        reject(session) { try $0.record(attemptID: UUID(), now: date) }
        reject(session) {
            try $0.record(attemptID: session.attemptIDs.last!, now: date.addingTimeInterval(-1))
        }
        try session.retry(now: date)
        reject(session) { try $0.record(attemptID: fullReview.attemptIDs.last!, now: date) }
        reject(session) { try $0.record(attemptID: UUID(), now: date) }
        XCTAssertEqual(session.attemptIDs, fullReview.attemptIDs)
        XCTAssertTrue(session.valid)
    }

    func testMIDIAssessesExactPitchOrderAndLinksOnlyCanonicalPitchEvidence() throws {
        let session = try playing(session(mode: .recall))
        let id = UUID()
        let attempt = try session.midiAttempt(notes: session.expectedNotes, now: date, id: id)
        XCTAssertTrue(attempt.valid)
        XCTAssertEqual(attempt.id, id)
        XCTAssertEqual(attempt.sessionID, session.id)
        XCTAssertEqual(attempt.pathwayID, session.journeyID)
        XCTAssertEqual(attempt.activityID, session.material.id + ":daily-ear:Piano")
        XCTAssertEqual(attempt.title, session.material.title)
        XCTAssertEqual(attempt.skills, ["Play it by ear"])
        XCTAssertEqual(attempt.pieceID, session.material.pieceID)
        XCTAssertEqual(attempt.scoreFingerprint, session.material.fingerprint)
        XCTAssertEqual(attempt.input, .midi)
        XCTAssertEqual(attempt.target, session.expectedNotes)
        XCTAssertFalse(attempt.assisted)
        XCTAssertNil(attempt.tempo)
        XCTAssertNil(attempt.timedPracticeID)
        XCTAssertNil(attempt.responseSeconds)
        for notes in [
            Array(session.expectedNotes.reversed()), session.expectedNotes.map { $0 + 12 },
            Array(session.expectedNotes.dropLast()), session.expectedNotes + [60], [],
        ] {
            XCTAssertEqual(try session.midiAttempt(notes: notes, now: date).outcome, .incorrect)
        }
        for notes in [[-1], [128], Array(repeating: 60, count: 129)] {
            XCTAssertThrowsError(try session.midiAttempt(notes: notes, now: date))
        }
        XCTAssertThrowsError(try self.session().midiAttempt(notes: [60], now: date))
        let guitar = try playing(self.session(instrument: .guitar))
        XCTAssertThrowsError(try guitar.midiAttempt(notes: guitar.expectedNotes, now: date))
        XCTAssertEqual(session.stage, .play)
        XCTAssertTrue(session.attemptIDs.isEmpty)
    }

    func testPitchOnlyMicrophoneOrderCanBeIndependentDespiteOpeningCaptureMode() throws {
        let plan = try plan()
        let take = take(plan)
        let session = try playing(session(plan.material, instrument: .guitar, mode: .recall))
        XCTAssertTrue(take.valid)
        XCTAssertTrue(take.assisted)
        XCTAssertFalse(take.report.conclusive)
        XCTAssertTrue(take.report.notes.allSatisfy { $0.pitch == .matched && $0.timing == .uncalibrated })
        let attempt = try XCTUnwrap(session.microphoneAttempt(take))
        XCTAssertEqual(attempt.id, take.id)
        XCTAssertEqual(attempt.sessionID, session.id)
        XCTAssertEqual(attempt.pathwayID, session.journeyID)
        XCTAssertEqual(attempt.input, .microphone)
        XCTAssertEqual(attempt.outcome, .correct)
        XCTAssertFalse(attempt.assisted)
        XCTAssertEqual(attempt.played, take.attacks.compactMap(\.midi))
        XCTAssertEqual(attempt.target, plan.timed.targets.map(\.pitch))
        XCTAssertEqual(attempt.skills, ["Play it by ear"])
        XCTAssertNil(attempt.tempo)
        XCTAssertNil(attempt.timedPracticeID)
        XCTAssertTrue(take.scoreFeedback.isEmpty)
        XCTAssertEqual(session.stage, .play)
        XCTAssertTrue(session.attemptIDs.isEmpty)
        var hinted = take
        hinted.usedHint = true
        XCTAssertTrue(try XCTUnwrap(session.microphoneAttempt(hinted)).assisted)
        var refreshed = take
        refreshed.plan.material.title = "Renamed source"
        refreshed.plan.material.scope.partName = "Renamed part"
        for index in refreshed.plan.material.melody.indices {
            refreshed.plan.material.melody[index].id = UUID()
        }
        XCTAssertEqual(try XCTUnwrap(session.microphoneAttempt(refreshed)).outcome, .correct)
        let fullFocused = self.take(try plan.configured(mode: .focused))
        XCTAssertFalse(try XCTUnwrap(session.microphoneAttempt(fullFocused)).assisted)
        var exposed = session
        try exposed.noteExposure(now: date)
        XCTAssertTrue(try XCTUnwrap(exposed.microphoneAttempt(take)).assisted)
        let learning = try playing(self.session(plan.material, instrument: .guitar))
        XCTAssertTrue(try XCTUnwrap(learning.microphoneAttempt(take)).assisted)
    }

    func testMicrophoneTimingFailuresNeverBecomeDailyPitchFailures() throws {
        let plan = try plan()
        let session = try playing(session(plan.material, instrument: .guitar, mode: .transfer))
        let late = take(plan, calibrated: true, delta: 0.14)
        XCTAssertTrue(late.valid)
        XCTAssertTrue(late.report.conclusive)
        XCTAssertTrue(late.report.notes.allSatisfy { $0.pitch == .matched && $0.timing == .late })
        let attempt = try XCTUnwrap(session.microphoneAttempt(late))
        XCTAssertEqual(attempt.outcome, .correct)
        XCTAssertEqual(attempt.skills, ["Play it by ear"])
        XCTAssertNil(attempt.tempo)
        var wrong = take(plan)
        wrong.attacks[0].frequency = frequency(plan.timed.targets[0].pitch + 1)
        XCTAssertEqual(wrong.report.notes[0].pitch, .wrong)
        XCTAssertEqual(try XCTUnwrap(session.microphoneAttempt(wrong)).outcome, .incorrect)
        var reordered = take(plan)
        reordered.attacks[0].frequency = frequency(plan.timed.targets[1].pitch)
        reordered.attacks[1].frequency = frequency(plan.timed.targets[0].pitch)
        XCTAssertEqual(try XCTUnwrap(session.microphoneAttempt(reordered)).outcome, .incorrect)
    }

    func testMicrophoneMissingExtraUncertainAndDisputedEvidenceAbstains() throws {
        let plan = try plan()
        let session = try playing(session(plan.material, instrument: .guitar, mode: .recall))
        var missing = take(plan, calibrated: true)
        missing.attacks.remove(at: 1)
        XCTAssertTrue(missing.valid)
        XCTAssertEqual(missing.report.notes[1].pitch, .missing)
        var short = take(plan)
        short.attacks.removeLast()
        var extra = take(plan)
        var extraAttack = extra.attacks[0]
        extraAttack.id = UUID()
        extra.attacks.append(extraAttack)
        var uncertain = take(plan)
        uncertain.attacks[0].confidence = 0.2
        var disputed = take(plan)
        disputed.disputedTargets = [0]
        var unknown = take(plan)
        unknown.clock = .unknown
        var flagged = take(plan)
        flagged.signalIssue = "Capture overflow"
        var silent = take(plan)
        silent.attacks = []
        for take in [missing, short, extra, uncertain, disputed, unknown, flagged, silent] {
            XCTAssertTrue(take.valid)
            XCTAssertNil(try session.microphoneAttempt(take))
        }
    }

    func testMicrophoneRejectsInvalidArchivalStaleAndMismatchedSources() throws {
        let plan = try plan()
        let session = try playing(session(plan.material, instrument: .guitar, mode: .recall))
        let original = take(plan)
        var invalid = original
        invalid.sampleRate = 0
        var archive = original
        archive.archivalOnly = true
        var stale = original
        stale.date = date.addingTimeInterval(-1)
        var changedRevision = original
        changedRevision.plan.material.fingerprint = ScoreRevision.digest("different revision")
        var changedStaff = original
        changedStaff.plan.material.staff = 2
        var changedVoice = original
        changedVoice.plan.material.voice = "2"
        var changedPiece = original
        changedPiece.plan.material.pieceID = "score:" + UUID().uuidString
        var changedPart = original
        changedPart.plan.material.scope.partID = "P2"
        var forgedNotes = original
        forgedNotes.plan.material.melody[0].midi += 1
        forgedNotes.plan.material.melody[0].spelling = Pitch.spelled(forgedNotes.plan.material.melody[0].midi)
        XCTAssertTrue(forgedNotes.valid)
        XCTAssertEqual(forgedNotes.plan.key, original.plan.key)
        for take in [
            invalid, archive, stale, changedRevision, changedStaff, changedVoice, changedPiece,
            changedPart, forgedNotes,
        ] {
            XCTAssertThrowsError(try session.microphoneAttempt(take))
        }
        XCTAssertThrowsError(try self.session(plan.material, instrument: .guitar).microphoneAttempt(original))
        let piano = try playing(self.session(plan.material, mode: .recall))
        XCTAssertThrowsError(try piano.microphoneAttempt(original))
    }

    func testMicrophoneScopeMustMatchDailyFocusAndWholeReturnKeepsIdentity() throws {
        let plan = try plan(from: 2, through: 4)
        let whole = take(plan)
        var session = try playing(session(plan.material, instrument: .guitar, mode: .recall))
        try session.record(attemptID: whole.id, now: date)
        try session.retry(bar: 3, now: date)
        XCTAssertThrowsError(try session.microphoneAttempt(whole))
        let focusPlan = try plan.focused(around: 3)
        let focused = take(focusPlan)
        let attempt = try XCTUnwrap(session.microphoneAttempt(focused))
        XCTAssertEqual(attempt.target, [56, 59])
        XCTAssertEqual(attempt.passageScope, focusPlan.timed.source?.scope)
        XCTAssertEqual(attempt.activityID, session.activityID)
        XCTAssertTrue(attempt.assisted)
        let context = take(try focusPlan.surrounding())
        XCTAssertThrowsError(try session.microphoneAttempt(context))
        try session.record(attemptID: attempt.id, now: date)
        try session.retry(now: date)
        XCTAssertThrowsError(try session.microphoneAttempt(focused))
        let slower = take(try plan.configured(tempo: 60))
        XCTAssertEqual(try XCTUnwrap(session.microphoneAttempt(slower)).outcome, .correct)
        XCTAssertEqual(try XCTUnwrap(session.microphoneAttempt(slower)).activityID, attempt.activityID)
    }

    func testCollectionIsBoundedResumableAndRejectsConflictingOrStaleReplacement() throws {
        let material = try material(document())
        let original = try session(material)
        var practice = EarDailyPractice()
        try practice.open(original)
        XCTAssertEqual(practice.active, original)
        try practice.open(original)
        XCTAssertEqual(practice.sessions.count, 1)
        var updated = original
        try updated.heard(now: date.addingTimeInterval(1))
        try practice.replace(updated)
        XCTAssertEqual(practice.active, updated)
        let before = practice
        XCTAssertThrowsError(try practice.replace(original))
        XCTAssertThrowsError(try practice.open(updatedWithChangedTitle(updated)))
        XCTAssertThrowsError(try practice.replace(updatedWithChangedTitle(updated)))
        XCTAssertThrowsError(try practice.replace(session(material)))
        let differentAnswer = try changed(updated) { $0["answerID"] = UUID().uuidString }
        XCTAssertThrowsError(try practice.replace(differentAnswer))
        XCTAssertEqual(practice, before)
        for _ in 1..<32 { try practice.open(session(material)) }
        XCTAssertEqual(practice.sessions.count, 32)
        let full = practice
        XCTAssertThrowsError(try practice.open(session(material)))
        XCTAssertEqual(practice, full)
        try practice.open(XCTUnwrap(practice.sessions.first { $0.id == original.id }))
        XCTAssertEqual(practice.selectedID, original.id)
        XCTAssertNoThrow(try practice.validated())
    }

    private func updatedWithChangedTitle(_ session: EarDailySession) throws -> EarDailySession {
        try changed(session) {
            var material = $0["material"] as! [String: Any]
            material["title"] = "Different frozen content"
            $0["material"] = material
        }
    }

    func testReturnGateIncludesOverlappingRevisionsAndExcludesOtherSourceDimensions() throws {
        var document = try document()
        let original = try material(document, from: 1, through: 2)
        var first = try completed(session(original))
        try first.noteExposure(now: date.addingTimeInterval(20))
        var practice = EarDailyPractice()
        try practice.open(first)
        document.events[0].pitches = [EditorPitch(60)]
        let overlap = try material(document, from: 2, through: 3)
        XCTAssertNotEqual(overlap.fingerprint, original.fingerprint)
        XCTAssertEqual(practice.returnDate(material: overlap), date.addingTimeInterval(24 * 3600 + 20))
        let disjoint = try material(document, from: 3, through: 4)
        XCTAssertNil(practice.returnDate(material: disjoint))
        for dimension in 0..<4 {
            var other = overlap
            switch dimension {
            case 0: other.pieceID = "score:" + UUID().uuidString
            case 1: other.scope.partID = "P2"
            case 2: other.staff = 2
            default: other.voice = "2"
            }
            XCTAssertTrue(other.valid)
            XCTAssertNil(practice.returnDate(material: other))
        }
        var second = try session(overlap, instrument: .guitar)
        try second.noteExposure(now: date.addingTimeInterval(100))
        try practice.open(second)
        XCTAssertEqual(practice.returnDate(material: original), date.addingTimeInterval(24 * 3600 + 100))
        let tooEarly = try EarDailySession(
            journeyID: UUID(), material: overlap, instrument: .piano, mode: .recall,
            reviewReadyAt: date.addingTimeInterval(3600), now: date.addingTimeInterval(3600))
        let before = practice
        XCTAssertThrowsError(try practice.open(tooEarly))
        XCTAssertEqual(practice, before)
        let ready = try XCTUnwrap(practice.returnDate(material: overlap))
        let recall = try EarDailySession(
            journeyID: UUID(), material: overlap, instrument: .piano, mode: .recall,
            reviewReadyAt: ready, now: ready)
        try practice.open(recall)
        XCTAssertEqual(practice.active, recall)
    }

    func testValidationRejectsCorruptSessionsSelectionsAndDuplicateReferences() throws {
        let original = try reviewing(session(mode: .recall))
        let corruptions: [(inout [String: Any]) -> Void] = [
            { $0["lastExposure"] = self.date.addingTimeInterval(-1).timeIntervalSinceReferenceDate },
            { $0["reviewReadyAt"] = self.date.addingTimeInterval(1).timeIntervalSinceReferenceDate },
            { $0.removeValue(forKey: "reviewReadyAt") },
            { $0["focusBar"] = 0 },
            {
                $0["revealed"] = true
                $0["assisted"] = false
            },
            { $0["stage"] = "complete" },
            { $0["completedAt"] = self.date.timeIntervalSinceReferenceDate },
            { $0["attemptIDs"] = [] },
            { $0["attemptIDs"] = Array(repeating: UUID().uuidString, count: 2) },
            { $0["attemptIDs"] = (0..<33).map { _ in UUID().uuidString } },
        ]
        for corruption in corruptions {
            XCTAssertThrowsError(try changed(original, corruption))
        }
        let recall = try session(mode: .recall)
        XCTAssertThrowsError(try changed(recall) { $0["stage"] = "hear" })
        let learning = try session()
        XCTAssertThrowsError(try changed(learning) { $0["assisted"] = false })
        XCTAssertThrowsError(try changed(learning) { $0["revealed"] = true })
        let transfer = try session(mode: .transfer)
        XCTAssertThrowsError(try changed(transfer) { $0["attemptIDs"] = [UUID().uuidString] })
        XCTAssertThrowsError(try changed(original) { $0["stage"] = "imagine" })
        XCTAssertThrowsError(try changed(recall) { $0["stage"] = "review" })
        XCTAssertThrowsError(try changed(recall) { $0["stage"] = "create" })
        var practice = EarDailyPractice()
        try practice.open(original)
        let before = practice
        var duplicate = try playing(session(original.material))
        try duplicate.record(attemptID: original.attemptIDs[0], now: date)
        XCTAssertThrowsError(try practice.open(duplicate))
        XCTAssertEqual(practice, before)
        practice.sessions.append(original)
        XCTAssertThrowsError(try practice.validated())
        practice = before
        practice.selectedID = UUID()
        XCTAssertThrowsError(try practice.validated())
        practice = before
        practice.sessions = Array(repeating: original, count: 33)
        XCTAssertThrowsError(try practice.validated())
    }

    func testSerializationResumesEveryStageAndRetainsLaterExposure() throws {
        var session = try session()
        var snapshots = [session]
        try session.heard(now: date)
        snapshots.append(session)
        try session.imagined(now: date)
        snapshots.append(session)
        try session.record(attemptID: UUID(), now: date)
        snapshots.append(session)
        try session.retry(bar: 2, now: date)
        snapshots.append(session)
        try session.reveal(now: date)
        try session.record(attemptID: UUID(), now: date)
        try session.beginAnswer(now: date)
        snapshots.append(session)
        try session.finish(now: date)
        try session.noteExposure(now: date.addingTimeInterval(100))
        snapshots.append(session)
        for original in snapshots {
            let decoded = try JSONDecoder().decode(
                EarDailySession.self, from: JSONEncoder().encode(original))
            XCTAssertEqual(decoded, original)
            XCTAssertTrue(decoded.valid)
            XCTAssertEqual(decoded.answerID, session.answerID)
            var practice = EarDailyPractice()
            try practice.open(decoded)
            let restored = try JSONDecoder().decode(
                EarDailyPractice.self, from: JSONEncoder().encode(practice))
            XCTAssertEqual(try restored.validated(), practice)
            XCTAssertEqual(restored.active, original)
        }
        let independent = try completed(self.session(mode: .transfer))
        XCTAssertThrowsError(
            try changed(independent) {
                $0["completedAt"] = self.date.addingTimeInterval(1).timeIntervalSinceReferenceDate
            })
    }
}
