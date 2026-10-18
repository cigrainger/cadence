// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class MicrophonePhraseTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private let origin = 1000.0
    private let route = "isolated-test-route"

    private func pitch(_ midi: Int) -> EditorPitch {
        let position = Guitar.positions(midi: midi, tuning: Tuning.presets[0], capo: 0).min { $0.fret < $1.fret }!
        return EditorPitch(midi, string: position.string, fret: position.fret)
    }

    private func document(meter: EditorMeter = EditorMeter(4, 4)) throws -> EditorDocument {
        let rhythm: EditorRhythm
        switch (meter.beats, meter.unit) {
        case (2, 4): rhythm = EditorRhythm(480)
        case (3, 4), (6, 8): rhythm = EditorRhythm(480, dotted: true)
        default: rhythm = EditorRhythm(960)
        }
        let events = (0..<4).flatMap { bar in
            [52 + bar * 2, 55 + bar * 2].map {
                EditorEvent(bar: bar, rhythm: rhythm, pitches: [pitch($0)])
            }
        }
        var value = EditorDocument(title: "A small guitar return", instrument: .guitar, events: events)
        value.meter = meter
        return try value.validated()
    }

    private func material(_ document: EditorDocument, from: Int = 1, through: Int = 4) throws -> ScoreEarMaterial {
        try ScoreEarMaterial(
            piece: LibraryPiece(source: .score(document)),
            scope: PieceScope(fromBar: from, throughBar: through, partID: "P1", partName: "Guitar"),
            staff: 1, voice: "1")
    }

    private func plan(
        _ document: EditorDocument? = nil, from: Int = 1, through: Int = 4, tempo: Int = 80
    ) throws -> MicrophonePhrasePlan {
        let document = try document ?? self.document()
        return try MicrophonePhrasePlan(
            material: material(document, from: from, through: through), tempo: tempo,
            source: LibraryPiece(source: .score(document)))
    }

    private func frequency(_ midi: Int, cents: Double = 0) -> Double {
        440 * pow(2, (Double(midi) - 69 + cents / 100) / 12)
    }

    private func calibration(at date: Date, offset: Double = 120) -> AcousticCalibration {
        AcousticCalibration(
            routeID: route, sampleRate: 48000, offsetMS: offset, jitterMS: 5, date: date, matchedPulses: 8,
            clockEvidence: mapping(firstHostSeconds: origin - 100, frameCount: 384000))
    }

    private func mapping(
        firstHostSeconds: Double? = nil, sampleRate: Double = 48000, frameCount: Int = 672000,
        residualMS: Double = 2
    ) -> AcousticClockEvidence {
        AcousticClockEvidence(
            firstSampleTime: 4800, firstHostSeconds: firstHostSeconds ?? origin - 0.5, sampleRate: sampleRate,
            frameCount: frameCount, maximumHostResidualMS: residualMS)
    }

    private func annotate(_ attacks: [AcousticAttack], using mapping: AcousticClockEvidence) -> [AcousticAttack] {
        attacks.map { original in
            var attack = original
            attack.sampleTime = mapping.sampleTime(at: attack.hostSeconds)
            attack.sampleRate = mapping.sampleRate
            return attack
        }
    }

    private func reanchor(_ take: inout MicrophonePhraseTake, using mapping: AcousticClockEvidence? = nil) {
        let mapping = mapping ?? take.clockEvidence!
        take.clockEvidence = mapping
        take.attacks = annotate(take.attacks, using: mapping)
    }

    private func take(
        _ plan: MicrophonePhrasePlan, at date: Date? = nil, delta: Double = 0, calibrated: Bool = true
    ) -> MicrophonePhraseTake {
        let date = date ?? self.date
        let offset = calibrated ? 0.120 : 0
        let mapping = mapping(frameCount: Int(ceil((plan.timed.duration + 2) * 48000)))
        let attacks = plan.timed.targets.map {
            AcousticAttack(
                hostSeconds: origin + $0.beat * plan.timed.secondsPerBeat + offset + delta,
                frequency: frequency($0.pitch), confidence: 0.98, rms: 0.1, clippedFraction: 0,
                onsetUncertaintyMS: 10)
        }
        return MicrophonePhraseTake(
            date: date, plan: plan, originHostSeconds: origin,
            calibration: calibrated ? calibration(at: date) : nil, routeID: route, sampleRate: 48000,
            attacks: annotate(attacks, using: mapping), clock: .sharedHost, clockEvidence: mapping)
    }

    func testWholeReviewedGuitarPhraseNeedsNoHarmonyAndKeepsSource() throws {
        let p = try plan()
        XCTAssertTrue(p.valid)
        XCTAssertNotNil(p.material.accompanimentIssue)
        XCTAssertTrue(p.material.chords.isEmpty)
        XCTAssertEqual(p.key, p.material.id)
        XCTAssertEqual(p.timed.targets.map(\.pitch), p.material.melody.map(\.midi))
        XCTAssertEqual(p.timed.targets.map(\.beat), [0, 2, 4, 6, 8, 10, 12, 14])
        let result = take(p)
        XCTAssertTrue(result.valid)
        XCTAssertTrue(result.report.conclusive)
        XCTAssertTrue(result.report.clean)
        XCTAssertNil(result.report.focusBar)
        XCTAssertEqual(result.scoreFeedback.count, 8)
        XCTAssertTrue(result.scoreFeedback.allSatisfy { $0.assessment.verdict == .onTime })
        XCTAssertEqual(result.report, result.report)
        XCTAssertTrue(result.evidence.contains("Durations, bends, technique and polyphony are not assessed"))
        XCTAssertLessThanOrEqual(result.evidence.count, 5000)
    }

    func testMeterMustBeVerifiedRatherThanInferredFromTotalBeats() throws {
        for beats in 2...4 {
            let p = try plan(document(meter: EditorMeter(beats, 4)))
            XCTAssertEqual(p.beatsPerBar, beats)
            XCTAssertTrue(p.valid)
        }
        // Both unsupported meters have the same quarter-beat totals as supported ones.
        for meter in [EditorMeter(6, 8), EditorMeter(2, 2)] {
            let d = try document(meter: meter)
            let m = try material(d)
            XCTAssertTrue(m.valid)
            XCTAssertThrowsError(try MicrophonePhrasePlan(material: m, source: LibraryPiece(source: .score(d))))
        }
        XCTAssertThrowsError(try MicrophonePhrasePlan(material: plan().material))
    }

    func testMixedMeterWithSupportedAverageIsRejected() throws {
        let d = try document()
        var study = try StudyImport.read(Data(try EditorXML.encode(d).utf8))
        // Keep total duration 16; an average of four beats cannot establish 4/4.
        study.parts[0].measures[0].beats = 3
        let source = LibraryPiece(source: .study(MusicStudy(document: study, filename: "mixed.xml")))
        let m = try ScoreEarMaterial(
            piece: source, scope: .init(fromBar: 1, throughBar: 4, partID: "P1", partName: "Guitar"),
            staff: 1, voice: "1")
        XCTAssertThrowsError(try MicrophonePhrasePlan(material: m, source: source))
    }

    func testPitchAndTimingAreSeparateAndMissesDoNotShiftLaterMatches() throws {
        let p = try plan()
        var result = take(p)
        result.attacks[0].frequency = frequency(p.timed.targets[0].pitch + 1)
        result.attacks[1].hostSeconds += 0.14
        result.attacks.remove(at: 2)
        result.attacks.append(
            AcousticAttack(
                hostSeconds: origin + 0.120 + 0.7, frequency: frequency(64), confidence: 0.98, rms: 0.1,
                clippedFraction: 0, onsetUncertaintyMS: 10))
        reanchor(&result)
        let r = result.report
        XCTAssertEqual(r.notes[0].pitch, .wrong)
        XCTAssertEqual(r.notes[0].timing, .onTime)
        XCTAssertEqual(r.notes[1].pitch, .matched)
        XCTAssertEqual(r.notes[1].timing, .late)
        XCTAssertEqual(r.notes[2].pitch, .missing)
        XCTAssertEqual(r.notes[2].timing, .missing)
        XCTAssertTrue(r.notes.dropFirst(3).allSatisfy(\.clean))
        XCTAssertEqual(r.extras.count, 1)
        XCTAssertTrue(r.conclusive)
        XCTAssertFalse(r.clean)
        XCTAssertEqual(r.focusBar, 1)
    }

    func testOffsetIsAppliedExactlyOnceAndOnlyDisplayEstimatesAreRounded() throws {
        let p = try plan()
        let result = take(p, delta: 0.03)
        XCTAssertEqual(result.attacks[0].hostSeconds, origin + 0.15, accuracy: 0.000001)
        XCTAssertEqual(result.report.notes[0].deltaMS, 30)
        XCTAssertEqual(result.report.notes[0].uncertaintyMS, 20)
        XCTAssertEqual(result.report.notes[0].toleranceMS, 80)
        XCTAssertEqual(try XCTUnwrap(result.scoreFeedback[0].assessment.attack).seconds, 0.03, accuracy: 0.000001)
        XCTAssertTrue(result.report.clean)
        XCTAssertTrue(take(p, delta: 0.015).report.clean)
        XCTAssertEqual(take(p, delta: 0.09).report.notes[0].timing, .late)
    }

    func testJournalDoesNotTurnADifferentPitchIntoATimingFailure() throws {
        let p = try plan()
        var result = take(p)
        result.attacks[0].frequency = frequency(p.timed.targets[0].pitch + 1)
        var practice = MicrophonePhrasePractice()
        try practice.open(p)
        let attempt = try XCTUnwrap(practice.record(result))
        XCTAssertEqual(attempt.outcome, .incorrect)
        XCTAssertTrue(attempt.skills.contains("microphone-pitch"))
        XCTAssertFalse(attempt.skills.contains("microphone-onset"))
        var latePractice = MicrophonePhrasePractice()
        try latePractice.open(p)
        let late = try XCTUnwrap(latePractice.record(take(p, delta: 0.14)))
        XCTAssertTrue(late.skills.contains("microphone-onset"))
        XCTAssertFalse(late.skills.contains("microphone-pitch"))
    }

    func testPitchToleranceUsesSoundingPitchAndNeverAcceptsAnOctave() throws {
        let p = try plan()
        for (cents, verdict) in [(40.0, MicrophonePhrasePitchVerdict.matched), (46.0, .wrong), (1200.0, .wrong)] {
            var result = take(p)
            result.attacks[0].frequency = frequency(p.timed.targets[0].pitch, cents: cents)
            XCTAssertEqual(result.report.notes[0].pitch, verdict)
            XCTAssertEqual(result.report.notes[0].timing, .onTime)
        }
    }

    func testMissingCalibrationRetainsPitchWithoutOnTimeFeedbackOrAGrade() throws {
        let p = try plan()
        let result = take(p, calibrated: false)
        XCTAssertTrue(result.valid)
        XCTAssertEqual(result.report.matchedPitch, 8)
        XCTAssertTrue(result.report.notes.allSatisfy { $0.timing == .uncalibrated && $0.deltaMS == nil })
        XCTAssertFalse(result.report.conclusive)
        XCTAssertFalse(result.report.clean)
        XCTAssertTrue(result.scoreFeedback.isEmpty)
        var practice = MicrophonePhrasePractice()
        try practice.open(p)
        let attempt = try XCTUnwrap(practice.record(result))
        XCTAssertEqual(attempt.outcome, .skipped)
        XCTAssertEqual(practice.active?.review, ReviewSchedule())
    }

    func testSilenceNoiseDropoutAndClippingAbstain() throws {
        let p = try plan()
        var silence = take(p)
        silence.attacks = []
        var noise = take(p)
        for index in noise.attacks.indices {
            noise.attacks[index].confidence = 0.2
            noise.attacks[index].frequency = nil
        }
        var clipping = take(p)
        for index in clipping.attacks.indices { clipping.attacks[index].clippedFraction = 0.02 }
        var dropout = take(p)
        dropout.signalIssue = "Input dropout"
        for result in [silence, noise, clipping, dropout] {
            XCTAssertTrue(result.valid)
            XCTAssertFalse(result.report.conclusive)
            XCTAssertFalse(result.report.clean)
            XCTAssertEqual(result.report.missing, 0)
            XCTAssertTrue(result.report.notes.allSatisfy { $0.pitch == .uncertain })
            XCTAssertTrue(result.scoreFeedback.isEmpty)
            var practice = MicrophonePhrasePractice()
            try practice.open(p)
            XCTAssertEqual(try practice.record(result)?.outcome, .skipped)
            XCTAssertEqual(practice.active?.review, ReviewSchedule())
            XCTAssertEqual(practice.active?.takes, [result])
        }
    }

    func testUncertainPitchAndOnsetsCannotCountClean() throws {
        let p = try plan()
        var uncertainPitch = take(p)
        uncertainPitch.attacks[2].confidence = 0.3
        XCTAssertEqual(uncertainPitch.report.notes[2].pitch, .uncertain)
        XCTAssertFalse(uncertainPitch.report.conclusive)
        var uncertainOnset = take(p)
        uncertainOnset.attacks[2].onsetUncertaintyMS = 75
        XCTAssertEqual(uncertainOnset.report.notes[2].pitch, .matched)
        XCTAssertEqual(uncertainOnset.report.notes[2].timing, .uncertain)
        XCTAssertFalse(uncertainOnset.report.clean)
        XCTAssertFalse(uncertainOnset.scoreFeedback.contains { $0.assessment.target == p.timed.targets[2] })
    }

    func testDuplicateAndBoundaryCandidatesRemainInconclusiveWithoutCherryPicking() throws {
        let p = try plan()
        var result = take(p)
        var duplicate = result.attacks[1]
        duplicate.id = UUID()
        duplicate.hostSeconds += 0.02
        duplicate.frequency = frequency(p.timed.targets[1].pitch + 1)
        result.attacks.append(duplicate)
        reanchor(&result)
        XCTAssertNil(result.report.notes[1].attack)
        XCTAssertEqual(result.report.notes[1].pitch, .uncertain)
        XCTAssertEqual(result.report.extras.count, 2)
        XCTAssertFalse(result.report.conclusive)
        var boundary = take(p)
        boundary.attacks[1].hostSeconds += 0.395
        reanchor(&boundary)
        XCTAssertEqual(boundary.report.notes[1].timing, .uncertain)
        XCTAssertFalse(boundary.report.clean)
    }

    func testUnknownOrInvalidClocksNeverUseArrivalTime() throws {
        let p = try plan()
        var unknown = take(p)
        unknown.clock = .unknown
        XCTAssertTrue(unknown.valid)
        XCTAssertFalse(unknown.report.conclusive)
        XCTAssertEqual(unknown.report.extras.count, unknown.attacks.count)
        XCTAssertTrue(unknown.scoreFeedback.isEmpty)
        var invalid = take(p)
        invalid.originHostSeconds = .nan
        XCTAssertFalse(invalid.valid)
        XCTAssertFalse(invalid.report.clean)
        invalid = take(p)
        invalid.attacks[0].hostSeconds = -.infinity
        XCTAssertFalse(invalid.valid)
        invalid = take(p)
        invalid.attacks[0].hostSeconds = 0
        XCTAssertFalse(invalid.valid)
        var shuffled = take(p)
        shuffled.attacks.reverse()
        XCTAssertTrue(shuffled.valid)
        XCTAssertTrue(shuffled.report.clean)
    }

    func testCalibrationMustMatchRouteRateAndCaptureDate() throws {
        let p = try plan()
        var result = take(p)
        result.routeID = "changed-route"
        XCTAssertFalse(result.valid)
        result = take(p)
        result.sampleRate = 44100
        XCTAssertFalse(result.valid)
        result = take(p)
        result.calibration?.date = date.addingTimeInterval(1)
        XCTAssertFalse(result.valid)
        result = take(p)
        result.calibration?.date = date.addingTimeInterval(-86401)
        XCTAssertFalse(result.valid)
        result = take(p)
        result.calibration?.jitterMS = 11
        XCTAssertFalse(result.valid)
        XCTAssertTrue(result.scoreFeedback.isEmpty)
    }

    func testTakeClockMappingValidatesRateRawAttackCoverageAndRoundTrips() throws {
        let p = try plan()
        let original = take(p)
        let anchor = mapping(firstHostSeconds: origin + 0.11)
        XCTAssertNil(anchor.sampleTime(at: origin))
        XCTAssertNotNil(anchor.sampleTime(at: original.attacks[0].hostSeconds))
        var result = MicrophonePhraseTake(
            id: original.id, date: original.date, plan: p, originHostSeconds: origin,
            calibration: original.calibration, routeID: route, sampleRate: 48000,
            attacks: annotate(original.attacks, using: anchor),
            clock: .sharedHost, clockEvidence: anchor)
        // Original onsets are captured, but their complete target windows are not.
        XCTAssertTrue(result.valid)
        XCTAssertFalse(result.report.clean)
        XCTAssertEqual(result.report.notes[0].timing, .uncertain)
        XCTAssertTrue(result.report.notes.dropFirst().allSatisfy(\.clean))
        XCTAssertEqual(result.attacks, annotate(original.attacks, using: anchor))
        let data = try JSONEncoder().encode(result)
        let restored = try JSONDecoder().decode(MicrophonePhraseTake.self, from: data)
        XCTAssertEqual(restored, result)
        XCTAssertEqual(restored.report, result.report)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "clockEvidence")
        let legacyTake = try JSONDecoder().decode(
            MicrophonePhraseTake.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(legacyTake.clockEvidence)
        XCTAssertTrue(legacyTake.valid)
        XCTAssertFalse(legacyTake.report.clean)
        XCTAssertTrue(legacyTake.report.notes.allSatisfy { $0.timing == .uncalibrated })

        result.clockEvidence = mapping(sampleRate: 44100)
        XCTAssertFalse(result.valid)
        result.clockEvidence = mapping(frameCount: 10)
        XCTAssertFalse(result.valid)
        result.clockEvidence = anchor
        result.clockEvidence?.firstHostSeconds = .nan
        XCTAssertFalse(result.valid)
        result.clockEvidence = anchor
        result.clockEvidence?.firstSampleTime = .max
        XCTAssertFalse(result.valid)
        XCTAssertFalse(result.report.clean)
    }

    func testUnusableProvidedClockMappingAbstainsAndKeepsRawEvidence() throws {
        let p = try plan()
        var result = take(p)
        result.clockEvidence = mapping(residualMS: 6)
        let attacks = result.attacks
        XCTAssertTrue(try XCTUnwrap(result.clockEvidence).valid)
        XCTAssertFalse(try XCTUnwrap(result.clockEvidence).usable)
        XCTAssertTrue(result.valid)
        XCTAssertFalse(result.report.conclusive)
        XCTAssertFalse(result.report.clean)
        XCTAssertEqual(result.report.missing, 0)
        XCTAssertTrue(result.report.notes.allSatisfy { $0.pitch == .uncertain && $0.deltaMS == nil })
        XCTAssertTrue(result.scoreFeedback.isEmpty)
        XCTAssertEqual(result.attacks, attacks)
        XCTAssertTrue(result.evidence.contains("maximum host residual ≤6 ms (unusable)"))
        var practice = MicrophonePhrasePractice()
        try practice.open(p)
        XCTAssertEqual(try practice.record(result)?.outcome, .skipped)
        XCTAssertEqual(practice.active?.review, ReviewSchedule())
        XCTAssertEqual(practice.active?.latest?.attacks, attacks)

        result.calibration = nil
        XCTAssertTrue(result.valid)
        XCTAssertTrue(result.report.notes.allSatisfy { $0.pitch == .uncertain })
        result.attacks = []
        result.clockEvidence = mapping(frameCount: 0)
        XCTAssertTrue(result.valid)
        XCTAssertFalse(result.report.conclusive)
    }

    func testTruncatedFrameCountCannotTurnUncapturedTargetsIntoMissingNotes() throws {
        let p = try plan()
        var result = take(p)
        result.attacks = Array(result.attacks.prefix(1))
        let fullMapping = try XCTUnwrap(result.clockEvidence)
        result.clockEvidence?.frameCount = 52800  // Through origin + 0.6 s, including the first window only.
        XCTAssertTrue(result.valid)
        XCTAssertTrue(result.report.notes[0].clean)
        XCTAssertTrue(result.report.notes.dropFirst().allSatisfy { $0.pitch == .uncertain && $0.timing == .uncertain })
        XCTAssertEqual(result.report.missing, 0)
        XCTAssertFalse(result.report.conclusive)
        XCTAssertEqual(result.scoreFeedback.count, 1)
        var book = MicrophonePhrasePractice()
        try book.open(p)
        XCTAssertEqual(try book.record(result)?.outcome, .skipped)
        XCTAssertNil(book.active?.baseline)
        XCTAssertEqual(book.active?.review, ReviewSchedule())

        result.clockEvidence = fullMapping
        XCTAssertEqual(result.report.missing, p.timed.targets.count - 1)
        XCTAssertTrue(result.report.conclusive)
    }

    func testMissingFirstTargetNeedsCompleteRawInputWindowIncludingUncertainty() throws {
        let p = try plan()
        var result = take(p)
        result.attacks.removeFirst()
        let radius = TimedMatcher.windowRadius(p.timed, beat: 0)
        // 120 ms input delay, 10 ms native onset, 5 ms jitter, 5 ms calibration anchor.
        let first = origin + 0.120 - radius - 0.020
        reanchor(&result, using: mapping(firstHostSeconds: first))
        XCTAssertTrue(result.valid)
        XCTAssertEqual(result.report.notes[0].pitch, .missing)
        XCTAssertTrue(result.report.conclusive)

        reanchor(&result, using: mapping(firstHostSeconds: first + 1 / 48000))
        XCTAssertTrue(result.valid)
        XCTAssertEqual(result.report.notes[0].pitch, .uncertain)
        XCTAssertEqual(result.report.notes[0].timing, .uncertain)
        XCTAssertFalse(result.report.conclusive)
        XCTAssertFalse(result.scoreFeedback.contains { $0.assessment.target == p.timed.targets[0] })
    }

    func testMissingLastTargetNeedsDelayedWindowEndAndBothMappingAllowances() throws {
        let p = try plan()
        var result = take(p)
        result.attacks.removeLast()
        let target = try XCTUnwrap(p.timed.targets.last)
        let end =
            origin + target.beat * p.timed.secondsPerBeat + 0.120
            + TimedMatcher.windowRadius(p.timed, beat: target.beat) + 0.020
        let first = try XCTUnwrap(result.clockEvidence).firstHostSeconds
        let completeFrames = Int(((end - first) * 48000).rounded())
        // Even a capture reaching the nominal window end misses the uncertainty margin.
        for shortfall in [1, 240, 960, 5760] {
            result.clockEvidence?.frameCount = completeFrames - shortfall
            XCTAssertTrue(result.valid)
            XCTAssertEqual(result.report.notes.last?.pitch, .uncertain)
            XCTAssertEqual(result.report.missing, 0)
            XCTAssertFalse(result.report.conclusive)
        }
        result.clockEvidence?.frameCount = completeFrames
        XCTAssertEqual(result.report.notes.last?.pitch, .missing)
        XCTAssertTrue(result.report.conclusive)
    }

    func testObservedLastAttackDoesNotProveCompleteWindowCoverage() throws {
        let p = try plan()
        var result = take(p)
        let last = try XCTUnwrap(result.attacks.last)
        let first = try XCTUnwrap(result.clockEvidence).firstHostSeconds
        result.clockEvidence?.frameCount = Int(((last.hostSeconds - first + 0.01) * 48000).rounded())
        XCTAssertTrue(result.valid)
        XCTAssertEqual(result.report.notes.last?.pitch, .matched)
        XCTAssertEqual(result.report.notes.last?.timing, .uncertain)
        XCTAssertFalse(result.report.conclusive)
        XCTAssertFalse(result.report.clean)
        XCTAssertEqual(result.scoreFeedback.count, p.timed.targets.count - 1)
    }

    func testEveryTimingProofIsRequiredWhileLegacyEvidenceRemainsArchivable() throws {
        let p = try plan()
        for missingProof in 0..<4 {
            var result = take(p)
            switch missingProof {
            case 0: result.clockEvidence = nil
            case 1: result.calibration?.clockEvidence = nil
            case 2:
                result.attacks[0].sampleTime = nil
                result.attacks[0].sampleRate = nil
            default: result.clock = .unknown
            }
            XCTAssertTrue(result.valid)
            XCTAssertFalse(result.report.conclusive)
            XCTAssertFalse(result.report.clean)
            XCTAssertEqual(result.report.missing, 0)
            XCTAssertTrue(result.report.notes.allSatisfy { $0.timing == .uncalibrated && $0.deltaMS == nil })
            XCTAssertTrue(result.scoreFeedback.isEmpty)
            let restored = try JSONDecoder().decode(MicrophonePhraseTake.self, from: JSONEncoder().encode(result))
            XCTAssertEqual(restored, result)
            XCTAssertFalse(restored.report.conclusive)
        }

        let original = take(p)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        legacy.removeValue(forKey: "clockEvidence")
        legacy.removeValue(forKey: "archivalOnly")
        var oldCalibration = try XCTUnwrap(legacy["calibration"] as? [String: Any])
        oldCalibration.removeValue(forKey: "clockEvidence")
        legacy["calibration"] = oldCalibration
        var oldAttacks = try XCTUnwrap(legacy["attacks"] as? [[String: Any]])
        for index in oldAttacks.indices {
            oldAttacks[index].removeValue(forKey: "sampleTime")
            oldAttacks[index].removeValue(forKey: "sampleRate")
        }
        legacy["attacks"] = oldAttacks
        let restored = try JSONDecoder().decode(
            MicrophonePhraseTake.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(restored.valid)
        XCTAssertNil(restored.archivalOnly)
        XCTAssertFalse(restored.isArchivalOnly)
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.attacks.map(\.hostSeconds), original.attacks.map(\.hostSeconds))
        XCTAssertEqual(restored.report.matchedPitch, p.timed.targets.count)
        XCTAssertFalse(restored.report.conclusive)
        var book = MicrophonePhrasePractice()
        try book.open(p)
        XCTAssertEqual(try book.record(restored)?.outcome, .skipped)
        XCTAssertNil(book.active?.baseline)
        XCTAssertEqual(book.active?.review, ReviewSchedule())
        XCTAssertNoThrow(
            try JSONDecoder().decode(
                MicrophonePhrasePractice.self, from: JSONEncoder().encode(book)
            ).validated())
    }

    func testOriginalAttackSamplesAndRatesMustAgreeWithRetainedAnchor() throws {
        let p = try plan()
        for mismatch in 0..<5 {
            var result = take(p)
            switch mismatch {
            case 0: result.attacks[0].sampleTime = result.attacks[0].sampleTime! + 1
            case 1: result.attacks[0].sampleRate = 44100
            case 2: result.attacks[0].hostSeconds += 0.01
            case 3: result.attacks[0].sampleTime = nil
            default: result.attacks[0].sampleRate = nil
            }
            let raw = result.attacks
            XCTAssertFalse(result.valid)
            XCTAssertFalse(result.report.conclusive)
            XCTAssertTrue(result.scoreFeedback.isEmpty)
            let restored = try JSONDecoder().decode(MicrophonePhraseTake.self, from: JSONEncoder().encode(result))
            XCTAssertEqual(restored.attacks, raw)
            XCTAssertFalse(restored.report.conclusive)
            var book = MicrophonePhrasePractice()
            try book.open(p)
            XCTAssertThrowsError(try book.record(result))
            XCTAssertTrue(try XCTUnwrap(book.active).takes.isEmpty)
        }
    }

    func testSeparateCalibrationMappingAllowanceIsIncludedOnceWithNativeOnsetUncertainty() throws {
        let p = try plan()
        var result = take(p, delta: 0.08)
        result.clockEvidence = mapping()
        // Native capture supplies 5 ms frame resolution plus its own 5 ms mapping.
        for index in result.attacks.indices { result.attacks[index].onsetUncertaintyMS = 10 }
        result.calibration?.clockEvidence = mapping(firstHostSeconds: origin - 100, frameCount: 480000)
        XCTAssertTrue(result.valid)
        // 10 ms native onset + 5 ms jitter + 5 ms SEPARATE calibration anchor.
        XCTAssertEqual(result.report.notes[0].uncertaintyMS, 20)
        XCTAssertEqual(result.report.notes[0].toleranceMS, 80)
        XCTAssertEqual(result.report.notes[0].deltaMS, 80)
        XCTAssertTrue(result.report.clean)
        XCTAssertTrue(result.scoreFeedback.allSatisfy { $0.assessment.verdict == .onTime })
        XCTAssertTrue(result.evidence.contains("Take mapping: sample-host-anchor-v1"))
        XCTAssertTrue(result.evidence.contains("calibration mapping: sample-host-anchor-v1"))
        XCTAssertTrue(result.evidence.contains("maximum host residual ≤2 ms (usable)"))
        XCTAssertLessThanOrEqual(result.evidence.count, 5000)
        var justOutside = take(p, delta: 0.081)
        XCTAssertEqual(justOutside.report.notes[0].timing, .late)
        // Display rounding must not add a second take mapping allowance.
        justOutside.calibration?.clockEvidence = nil
        XCTAssertEqual(justOutside.report.notes[0].timing, .uncalibrated)
        result.calibration?.clockEvidence = nil
        XCTAssertTrue(result.valid)
        XCTAssertEqual(result.report.notes[0].timing, .uncalibrated)
        XCTAssertTrue(result.scoreFeedback.isEmpty)
        XCTAssertFalse(result.report.clean)
    }

    func testDisputesPreserveRawEvidenceAndDoNotProduceCorrectnessCredit() throws {
        let p = try plan()
        let original = take(p)
        var disputed = original
        disputed.disputedTargets = [1, 4]
        XCTAssertTrue(disputed.valid)
        XCTAssertEqual(disputed.attacks, original.attacks)
        XCTAssertEqual(disputed.report.notes[1].attack, original.report.notes[1].attack)
        XCTAssertEqual(disputed.report.notes[1].pitch, .disputed)
        XCTAssertEqual(disputed.report.notes[4].timing, .disputed)
        XCTAssertFalse(disputed.report.conclusive)
        XCTAssertEqual(disputed.scoreFeedback.count, 6)
        XCTAssertTrue(disputed.evidence.contains("[1,4]"))
        var practice = MicrophonePhrasePractice()
        try practice.open(p)
        XCTAssertEqual(try practice.record(disputed)?.outcome, .skipped)
        disputed.disputedTargets = [99]
        XCTAssertFalse(disputed.valid)
        disputed.disputedTargets = [1, 1]
        XCTAssertFalse(disputed.valid)
    }

    func testFocusUsesAbsoluteSourceBarsAndExpandsAcrossCompleteTies() throws {
        var d = try document()
        d.events[2].pitches = [pitch(d.events[1].pitches[0].midi)]
        d.events[1].tieNext = true
        d.events[4].pitches = [pitch(d.events[3].pitches[0].midi)]
        d.events[3].tieNext = true
        let p = try plan(d)
        let focus = try p.focused(around: 2)
        XCTAssertEqual(focus.fromBar, 1)
        XCTAssertEqual(focus.throughBar, 3)
        XCTAssertEqual(focus.mode, .focused)
        XCTAssertEqual(focus.material, p.material)
        XCTAssertEqual(focus.key, p.key)
        let context = try focus.surrounding()
        XCTAssertEqual(context.mode, .context)
        XCTAssertTrue(context.isFullPhrase)
        XCTAssertEqual(context.material, p.material)
        XCTAssertThrowsError(try p.focused(around: 0))
        XCTAssertThrowsError(
            try MicrophonePhrasePlan(
                material: p.material, fromBar: 2, throughBar: 2, mode: .focused,
                source: LibraryPiece(source: .score(d))))
        XCTAssertThrowsError(try material(d, from: 2))
    }

    func testSubrangeRetainsWholeOriginalMaterialAndRelativeTimedBeats() throws {
        let p = try plan(from: 2, through: 4)
        let focus = try p.focused(around: 3)
        XCTAssertEqual(p.sourceStart, 4)
        XCTAssertEqual(focus.material, p.material)
        XCTAssertEqual(focus.timed.targets.map(\.beat), [0, 2])
        XCTAssertEqual(focus.timed.targets.map(\.bar), [2, 2])
        XCTAssertEqual(focus.timed.source?.startBeat, 8)
        XCTAssertEqual(focus.timed.source?.scope.from, 2)
        XCTAssertEqual(focus.timed.length, 4)
        XCTAssertEqual(try focus.surrounding().material, p.material)
        XCTAssertEqual(try focus.configured(tempo: 60).key, p.key)
        XCTAssertThrowsError(try focus.configured(mode: .independent))
        XCTAssertThrowsError(try focus.configured(mode: .opening))
    }

    func testScopePitchTempoAndAttackDensityLimits() throws {
        let d = try document()
        let p = try plan(d)
        for tempo in [49, 141] { XCTAssertThrowsError(try p.configured(tempo: tempo)) }
        XCTAssertNoThrow(try p.configured(tempo: 50))
        XCTAssertNoThrow(try p.configured(tempo: 140))
        for midi in [39, 89] {
            var changed = p
            changed.material.melody[0].midi = midi
            changed.material.melody[0].spelling = Pitch.spelled(midi, flats: false)
            XCTAssertTrue(changed.material.valid)
            XCTAssertFalse(changed.valid)
        }
        for midi in [40, 88] {
            var changed = d
            changed.events[0].pitches = [pitch(midi)]
            XCTAssertNoThrow(try plan(changed))
        }
        var chord = d
        chord.events[0].pitches.append(pitch(64))
        XCTAssertThrowsError(try material(chord))
        var crowded = d
        crowded.events =
            [
                EditorEvent(bar: 0, rhythm: EditorRhythm(120), pitches: [pitch(52)]),
                EditorEvent(bar: 0, rhythm: EditorRhythm(120), pitches: [pitch(54)]),
                EditorEvent(bar: 0, rhythm: EditorRhythm(960, dotted: true), pitches: [pitch(55)]),
                EditorEvent(bar: 0, rhythm: EditorRhythm(240), pitches: []),
            ] + Array(d.events.dropFirst(2))
        XCTAssertThrowsError(try plan(crowded))
        XCTAssertNoThrow(try plan(crowded, tempo: 50))
        var invalid = p
        invalid.fromBar = Int.max
        XCTAssertFalse(invalid.valid)
        XCTAssertFalse(take(invalid).valid)
    }

    func testBaselineFocusContextAndDelayedIndependentReturnShareOneSchedule() throws {
        let p = try plan()
        var practice = MicrophonePhrasePractice()
        try practice.open(p)
        let baseline = take(p)
        let attempt = try XCTUnwrap(practice.record(baseline))
        XCTAssertTrue(attempt.valid)
        XCTAssertEqual(attempt.input, .microphone)
        XCTAssertEqual(attempt.outcome, .correct)
        XCTAssertTrue(attempt.assisted)
        XCTAssertEqual(attempt.id, baseline.id)
        XCTAssertEqual(attempt.pieceID, p.material.pieceID)
        XCTAssertEqual(attempt.scoreFingerprint, p.material.fingerprint)
        XCTAssertEqual(attempt.passageScope, p.timed.source?.scope)
        XCTAssertTrue(attempt.skills.contains("microphone-pitch"))
        XCTAssertTrue(attempt.skills.contains("microphone-onset"))
        let baselineReview = try XCTUnwrap(practice.active).review
        XCTAssertEqual(baselineReview.intervalDays, 0)
        let focus = try p.focused(around: 2)
        var retry = take(focus, at: date.addingTimeInterval(60))
        retry.attacks[0].frequency = frequency(focus.timed.targets[0].pitch + 1)
        XCTAssertEqual(try practice.record(retry)?.outcome, .incorrect)
        XCTAssertEqual(practice.active?.review, baselineReview)
        let context = try focus.surrounding()
        let contextDate = date.addingTimeInterval(120)
        _ = try practice.record(take(context, at: contextDate))
        XCTAssertEqual(practice.active?.review, baselineReview)
        let independent = try p.whole(mode: .independent)
        XCTAssertThrowsError(try practice.record(take(independent, at: contextDate.addingTimeInterval(20 * 3600 - 1))))
        let returnDate = contextDate.addingTimeInterval(20 * 3600)
        XCTAssertEqual(practice.returnDate(p.key), returnDate)
        let returned = try XCTUnwrap(practice.record(take(independent, at: returnDate)))
        XCTAssertEqual(returned.outcome, .correct)
        XCTAssertFalse(returned.assisted)
        XCTAssertEqual(practice.active?.review.intervalDays, 1)
        XCTAssertEqual(practice.active?.review.lastGrade, .good)
        XCTAssertNoThrow(try practice.validated())
    }

    func testIndependentNeedsBaselineAndDelayAfterDemonstrationAndRejectsHintsOrTempoChange() throws {
        let p = try plan()
        let independent = try p.whole(mode: .independent)
        var practice = MicrophonePhrasePractice()
        try practice.open(p)
        XCTAssertThrowsError(try practice.record(take(independent, at: date)))
        _ = try practice.record(take(p))
        let hearing = date.addingTimeInterval(86400)
        try practice.noteDemonstration(materialID: p.key, now: hearing)
        XCTAssertEqual(practice.active?.lastDemonstration, hearing)
        XCTAssertThrowsError(try practice.record(take(independent, at: hearing.addingTimeInterval(3600))))
        let due = hearing.addingTimeInterval(20 * 3600)
        let slower = try independent.configured(tempo: 60)
        XCTAssertThrowsError(try practice.record(take(slower, at: due)))
        var hinted = take(independent, at: due)
        hinted.usedHint = true
        XCTAssertFalse(hinted.valid)
        XCTAssertThrowsError(try practice.record(hinted))
        _ = try practice.record(take(independent, at: due))
        let review = try XCTUnwrap(practice.active).review
        // Later guided/focused/tempo-only practice must not erase the independent return.
        _ = try practice.record(take(p.configured(tempo: 60), at: due.addingTimeInterval(60)))
        XCTAssertEqual(practice.active?.review, review)
        try practice.noteDemonstration(materialID: p.key, now: due.addingTimeInterval(120))
        XCTAssertNoThrow(try practice.validated())
    }

    func testStaleAndForgedPlansCannotRecordAndOldVersionsRoundTrip() throws {
        let d = try document()
        let p = try plan(d)
        var practice = MicrophonePhrasePractice()
        try practice.open(p)
        let old = take(p)
        _ = try practice.record(old)
        var changed = d
        changed.events[0].pitches = [pitch(56)]
        let current = try plan(changed)
        XCTAssertFalse(p.isCurrent(in: LibraryPiece(source: .score(changed))))
        let staleParent = practice
        XCTAssertThrowsError(
            try practice.record(
                take(p, at: date.addingTimeInterval(60)), source: LibraryPiece(source: .score(changed))))
        XCTAssertEqual(practice, staleParent)
        try practice.open(current)
        let before = practice
        XCTAssertThrowsError(try practice.record(take(p, at: date.addingTimeInterval(60))))
        XCTAssertEqual(practice, before)
        var forged = current
        forged.material.melody[0].midi += 1
        forged.material.melody[0].spelling = Pitch.spelled(forged.material.melody[0].midi, flats: false)
        XCTAssertTrue(forged.valid)
        XCTAssertEqual(forged.key, current.key)
        XCTAssertThrowsError(try practice.record(take(forged, at: date.addingTimeInterval(60))))
        XCTAssertThrowsError(try practice.open(forged))
        _ = try practice.record(take(current, at: date.addingTimeInterval(60)))
        practice.selectedID = p.key
        XCTAssertThrowsError(try practice.record(take(p, at: date.addingTimeInterval(120))))
        practice.selectedID = current.key
        let restored = try JSONDecoder().decode(MicrophonePhrasePractice.self, from: JSONEncoder().encode(practice))
        XCTAssertEqual(try restored.validated(), practice)
        XCTAssertEqual(restored.sessions[0].takes, [old])
        XCTAssertEqual(restored.sessions.count, 2)
    }

    func testStaleTakeCanBeArchivedAgainstOriginalSessionWithoutCurrentScoreCredit() throws {
        let d = try document()
        let originalPlan = try plan(d)
        let original = take(originalPlan)
        var book = MicrophonePhrasePractice()
        try book.open(originalPlan)
        var edited = d
        edited.events[0].pitches = [pitch(56)]
        let currentPlan = try plan(edited)
        try book.open(currentPlan)
        let before = book
        XCTAssertThrowsError(try book.record(original, source: LibraryPiece(source: .score(edited))))
        XCTAssertThrowsError(try book.archive(original))
        XCTAssertEqual(book, before)

        var archived = original
        archived.archivalOnly = true
        try book.archive(archived)
        XCTAssertEqual(book.selectedID, currentPlan.key)
        let originalSession = try XCTUnwrap(book.sessions.first { $0.id == originalPlan.key })
        XCTAssertEqual(originalSession.takes, [archived])
        XCTAssertNil(originalSession.baseline)
        XCTAssertEqual(originalSession.review, ReviewSchedule())
        XCTAssertTrue(try XCTUnwrap(book.active).takes.isEmpty)
        XCTAssertEqual(archived.id, original.id)
        XCTAssertEqual(archived.date, original.date)
        XCTAssertEqual(archived.plan, original.plan)
        XCTAssertEqual(archived.attacks, original.attacks)
        XCTAssertEqual(archived.calibration, original.calibration)
        XCTAssertEqual(archived.clockEvidence, original.clockEvidence)
        XCTAssertFalse(archived.report.conclusive)
        XCTAssertFalse(archived.report.clean)
        XCTAssertTrue(archived.report.notes.isEmpty)
        XCTAssertEqual(archived.report.extras, archived.attacks)
        XCTAssertTrue(archived.scoreFeedback.isEmpty)
        XCTAssertTrue(archived.evidence.contains("Earlier-version archive only"))
        let saved = book
        try book.archive(archived)
        XCTAssertEqual(book, saved)
        XCTAssertThrowsError(try book.record(archived))
        var changedEvidence = archived
        changedEvidence.attacks[0].confidence = 0.97
        XCTAssertThrowsError(try book.archive(changedEvidence))
        XCTAssertEqual(book, saved)
        let restored = try JSONDecoder().decode(MicrophonePhrasePractice.self, from: JSONEncoder().encode(book))
        XCTAssertEqual(try restored.validated(), saved)
    }

    func testArchivedIndependentTakeNeedsNoEligibilityAndCannotSupplyABaselineOrReview() throws {
        let p = try plan()
        var book = MicrophonePhrasePractice()
        try book.open(p)
        var baseline = take(p)
        baseline.archivalOnly = true
        try book.archive(baseline)
        let independent = try p.whole(mode: .independent)
        var archivedReturn = take(independent, at: date.addingTimeInterval(60))
        archivedReturn.archivalOnly = true
        try book.archive(archivedReturn)
        XCTAssertNil(book.active?.baseline)
        XCTAssertEqual(book.active?.review, ReviewSchedule())
        XCTAssertNoThrow(try book.validated())
        let saved = book
        XCTAssertThrowsError(try book.record(take(independent, at: date.addingTimeInterval(86400))))
        XCTAssertEqual(book, saved)

        var credited = MicrophonePhrasePractice()
        try credited.open(p)
        _ = try credited.record(take(p))
        let review = try XCTUnwrap(credited.active).review
        try credited.archive(archivedReturn)
        XCTAssertEqual(credited.active?.review, review)
        XCTAssertEqual(credited.active?.baseline?.isArchivalOnly, false)
        XCTAssertNoThrow(try credited.validated())
    }

    func testArchiveRequiresOriginalSessionExactIdentityDateOrderAndAvailableCapacity() throws {
        let p = try plan()
        var result = take(p, at: date.addingTimeInterval(60))
        result.archivalOnly = true
        var book = MicrophonePhrasePractice()
        XCTAssertThrowsError(try book.archive(result))
        try book.open(p)
        book.selectedID = nil
        var forged = result
        forged.plan.material.melody[0].midi += 1
        forged.plan.material.melody[0].spelling = Pitch.spelled(forged.plan.material.melody[0].midi, flats: false)
        XCTAssertTrue(forged.valid)
        XCTAssertThrowsError(try book.archive(forged))
        try book.archive(result)
        XCTAssertNil(book.selectedID)
        let saved = book
        var earlier = take(p)
        earlier.archivalOnly = true
        XCTAssertThrowsError(try book.archive(earlier))
        var malformed = take(p, at: date.addingTimeInterval(120))
        malformed.archivalOnly = true
        malformed.attacks[0].confidence = 2
        XCTAssertThrowsError(try book.archive(malformed))
        XCTAssertEqual(book, saved)
        for index in 1..<16 {
            var next = take(p, at: date.addingTimeInterval(60 + Double(index)))
            next.archivalOnly = true
            try book.archive(next)
        }
        let full = book
        var overflow = take(p, at: date.addingTimeInterval(100))
        overflow.archivalOnly = true
        XCTAssertThrowsError(try book.archive(overflow))
        XCTAssertEqual(book, full)
        XCTAssertEqual(book.sessions[0].review, ReviewSchedule())
        XCTAssertNoThrow(try book.validated())
    }

    func testUnkeptRetriesMoveReturnDateWithoutLosingHistoricalIndependentEligibility() throws {
        let p = try plan()
        let independent = try p.whole(mode: .independent)
        var practice = MicrophonePhrasePractice()
        try practice.open(p)
        _ = try practice.record(take(p))
        let firstReturn = date.addingTimeInterval(20 * 3600)
        _ = try practice.record(take(independent, at: firstReturn))
        let review = try XCTUnwrap(practice.active).review
        for index in 1...100 {
            try practice.notePractice(materialID: p.key, now: firstReturn.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(practice.active?.takes.count, 2)
        XCTAssertEqual(practice.active?.review, review)
        XCTAssertEqual(practice.active?.unkeptPracticeDates.count, 1)
        XCTAssertNil(practice.active?.lastDemonstration)
        XCTAssertEqual(practice.active?.lastPractice, firstReturn.addingTimeInterval(100))
        XCTAssertThrowsError(try practice.record(take(independent, at: firstReturn.addingTimeInterval(20 * 3600))))
        let secondReturn = firstReturn.addingTimeInterval(100 + 20 * 3600)
        _ = try practice.record(take(independent, at: secondReturn))
        try practice.notePractice(materialID: p.key, now: secondReturn.addingTimeInterval(10))
        XCTAssertEqual(practice.active?.unkeptPracticeDates.count, 2)
        XCTAssertEqual(practice.returnDate(p.key), secondReturn.addingTimeInterval(10 + 20 * 3600))
        let restored = try JSONDecoder().decode(MicrophonePhrasePractice.self, from: JSONEncoder().encode(practice))
        XCTAssertEqual(try restored.validated(), practice)
    }

    func testSameSourceRebuiltNoteIDsAndRenamingDoNotCreateAnotherSession() throws {
        var d = try document()
        let p = try plan(d)
        var practice = MicrophonePhrasePractice()
        try practice.open(p)
        d.title = "Renamed source"
        let fresh = try plan(d)
        XCTAssertEqual(fresh.key, p.key)
        try practice.open(fresh)
        XCTAssertEqual(practice.sessions.count, 1)
        XCTAssertNotNil(try practice.record(take(fresh)))
        XCTAssertNoThrow(try practice.validated())
    }

    func testDuplicateIDsAreIdempotentOnlyForExactlyEqualEvidence() throws {
        let p = try plan()
        var practice = MicrophonePhrasePractice()
        try practice.open(p)
        let result = take(p)
        XCTAssertNotNil(try practice.record(result))
        let saved = practice
        XCTAssertNil(try practice.record(result))
        XCTAssertEqual(practice, saved)
        var different = result
        different.disputedTargets = [0]
        XCTAssertThrowsError(try practice.record(different))
        XCTAssertEqual(practice, saved)
        practice.sessions[0].takes.append(result)
        XCTAssertThrowsError(try practice.validated())
    }

    func testAttackTakeSessionAndDemonstrationBoundsPreserveExistingEvidence() throws {
        let p = try plan()
        var oversized = take(p)
        oversized.attacks = (0..<129).map { index in
            AcousticAttack(
                hostSeconds: origin + Double(index) / 100, frequency: frequency(52), confidence: 0.98, rms: 0.1,
                clippedFraction: 0, onsetUncertaintyMS: 5)
        }
        XCTAssertFalse(oversized.valid)
        var practice = MicrophonePhrasePractice()
        try practice.open(p)
        for index in 0..<16 {
            _ = try practice.record(take(p, at: date.addingTimeInterval(Double(index))))
        }
        let saved = practice
        XCTAssertThrowsError(try practice.record(take(p, at: date.addingTimeInterval(17))))
        XCTAssertEqual(practice, saved)
        for index in 0..<64 {
            try practice.noteDemonstration(materialID: p.key, now: date.addingTimeInterval(100 + Double(index)))
        }
        let heard = practice
        XCTAssertThrowsError(try practice.noteDemonstration(materialID: p.key, now: date.addingTimeInterval(200)))
        XCTAssertEqual(practice, heard)
        var sessions = MicrophonePhrasePractice()
        for _ in 0..<32 { try sessions.open(plan()) }
        let full = sessions
        XCTAssertThrowsError(try sessions.open(plan()))
        XCTAssertEqual(sessions, full)
        XCTAssertNoThrow(try sessions.validated())
        sessions.sessions.append(full.sessions[0])
        XCTAssertThrowsError(try sessions.validated())
    }

    func testForgedScheduleSelectionAndMalformedEvidenceAreRejectedTransactionally() throws {
        let p = try plan()
        var practice = MicrophonePhrasePractice()
        try practice.open(p)
        var malformed = take(p)
        malformed.attacks[0].confidence = 2
        XCTAssertThrowsError(try practice.record(malformed))
        XCTAssertTrue(try XCTUnwrap(practice.active).takes.isEmpty)
        _ = try practice.record(take(p))
        practice.sessions[0].review.intervalDays = 60
        XCTAssertThrowsError(try practice.validated())
        practice.sessions[0].review.intervalDays = 0
        practice.selectedID = "missing"
        XCTAssertThrowsError(try practice.validated())
    }
}

extension MicrophonePhraseTests {
    func testPitchOnlyUsesSequenceWithoutPretendingUnknownLatencyIsATimingWindow() throws {
        let p = try plan()
        var result = take(p, delta: 0.7, calibrated: false)
        XCTAssertTrue(result.valid)
        XCTAssertEqual(result.report.matchedPitch, p.timed.targets.count)
        XCTAssertTrue(result.report.notes.allSatisfy { $0.timing == .uncalibrated && $0.deltaMS == nil })
        XCTAssertTrue(result.scoreFeedback.isEmpty)
        XCTAssertFalse(result.report.conclusive)
        result.attacks.remove(at: 2)
        XCTAssertEqual(result.report.missing, 0)
        XCTAssertTrue(result.report.notes.allSatisfy { $0.pitch == .uncertain })
        XCTAssertEqual(result.report.extras.count, result.attacks.count)
    }

    func testCoachEvidenceIncludesSpecificNotesAndRoundedTimingWithUncertainty() throws {
        let p = try plan()
        var result = take(p, delta: 0.14)
        result.attacks[0].frequency = frequency(p.timed.targets[0].pitch + 1)
        let evidence = result.evidence
        XCTAssertTrue(evidence.contains("Per-note evidence:"))
        XCTAssertTrue(evidence.contains("bar 1, target MIDI"))
        XCTAssertTrue(evidence.contains("observed MIDI"))
        XCTAssertTrue(evidence.contains("about 140 ms"))
        XCTAssertTrue(evidence.contains("Source revision: " + p.material.fingerprint))
        XCTAssertLessThanOrEqual(evidence.count, 5000)
    }
    func testInterruptedOldRevisionCanRetainExposureAfterNewRevisionOpens() throws {
        let old = try document()
        let p = try plan(old)
        var book = MicrophonePhrasePractice()
        try book.open(p)
        var changed = old
        changed.events[0].pitches = [pitch(53)]
        let revised = try plan(changed)
        try book.open(revised)
        try book.notePractice(materialID: p.key, now: date)
        XCTAssertEqual(book.returnDate(revised.key), date.addingTimeInterval(20 * 3600))
        XCTAssertNoThrow(try book.validated())
    }

    func testSupersededExposureRecoveryIsIdempotentAfterLaterDemonstration() throws {
        let p = try plan()
        var book = MicrophonePhrasePractice()
        try book.open(p)
        let later = date.addingTimeInterval(60)
        try book.noteDemonstration(materialID: p.key, now: later)
        let expected = book
        try book.notePractice(materialID: p.key, now: date)
        XCTAssertEqual(book, expected)
        XCTAssertEqual(book.returnDate(p.key), later.addingTimeInterval(20 * 3600))
    }

}
