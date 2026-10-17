// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class PlayAlongTests: XCTestCase {
    func plan() throws -> PlayAlongPlan {
        try PlayAlongPlan(material: ScoreEarTests().material(), sourceStart: 0, setup: PlayAlongSetup())
    }
    func attacks(_ p: PlayAlongPlan) -> [TimedAttack] {
        p.timed.targets.map { .init(seconds: $0.beat * p.timed.secondsPerBeat, pitch: $0.pitch) }
    }
    func result(_ p: PlayAlongPlan, attacks: [TimedAttack]? = nil, offset: Int = 0) -> PlayAlongResult {
        .init(
            plan: p,
            pass: .init(
                plan: p.timed, conditions: .init(input: .midi, click: false, offsetMS: offset),
                attacks: attacks ?? self.attacks(p)))
    }
    func testExactMelodyAndBandShareCountInTempoAndEnd() throws {
        let p = try plan()
        XCTAssertTrue(p.valid)
        XCTAssertTrue(result(p).valid)
        XCTAssertEqual(p.timed.targets.map(\.pitch), p.material.melody.map(\.midi))
        XCTAssertEqual(p.timed.targets.map(\.beat), p.material.melody.map(\.start))
        XCTAssertEqual(p.timed.countIn + p.timed.duration, p.accompaniment.endBeat * 60 / Double(p.setup.tempo))
        XCTAssertEqual(p.accompaniment.options.loops, 1)
        XCTAssertTrue(result(p).pass.report.clean)
        XCTAssertEqual(result(p).grade, .good)
    }
    func testMissWrongExtraAndEarlyDoNotCascade() throws {
        let p = try plan()
        var a = attacks(p)
        a[1].seconds -= 0.14
        a[2].pitch += 1
        a.remove(at: 3)
        a[3].seconds += 0.13
        a.append(.init(seconds: 0.7, pitch: 90))
        let r = result(p, attacks: a).pass.report
        XCTAssertEqual(
            r.notes.map(\.verdict), [.onTime, .early, .wrongPitch, .missed, .late, .onTime, .onTime, .onTime])
        XCTAssertEqual(r.extras.count, 1)
        XCTAssertEqual(r.matchedPitch, 6)
        XCTAssertEqual(r.timedEntrances(tolerance: p.timed.tolerance), 5)
        XCTAssertFalse(PlayAlongChallenge.clean.met(by: r, tolerance: p.timed.tolerance))
    }
    func testPitchAndPulseChallengesAreIndependentAndNoSpamWins() throws {
        let p = try plan()
        var late = attacks(p)
        var wrong = attacks(p)
        for i in late.indices {
            late[i].seconds += 0.14
            wrong[i].pitch += 1
        }
        let lr = result(p, attacks: late).pass.report
        let wr = result(p, attacks: wrong).pass.report
        XCTAssertTrue(PlayAlongChallenge.notes.met(by: lr, tolerance: p.timed.tolerance))
        XCTAssertFalse(PlayAlongChallenge.pulse.met(by: lr, tolerance: p.timed.tolerance))
        XCTAssertTrue(PlayAlongChallenge.pulse.met(by: wr, tolerance: p.timed.tolerance))
        XCTAssertFalse(PlayAlongChallenge.notes.met(by: wr, tolerance: p.timed.tolerance))
        let spam = result(p, attacks: attacks(p) + [.init(seconds: 0.1, pitch: 42)]).pass.report
        for challenge in PlayAlongChallenge.allCases {
            XCTAssertFalse(challenge.met(by: spam, tolerance: p.timed.tolerance))
        }
        XCTAssertEqual(result(p, attacks: wrong).grade, .again)
    }
    func testLiveFeedbackDoesNotInventMissBeforeWindowAndCanImprove() throws {
        let p = try plan()
        let t = p.timed
        XCTAssertTrue(TimedMatcher.live(t, attacks: [], elapsed: 0.3, offsetMS: 0).isEmpty)
        XCTAssertTrue(TimedMatcher.live(t, attacks: [], elapsed: 0.55, offsetMS: 100).isEmpty)
        let closed = TimedMatcher.live(t, attacks: [], elapsed: 0.65, offsetMS: 100)
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed.first?.assessment.verdict, .missed)
        let wrong = TimedAttack(seconds: 0, pitch: 70)
        let provisional = TimedMatcher.live(t, attacks: [wrong], elapsed: 0.01, offsetMS: 0)
        XCTAssertEqual(provisional.first?.assessment.verdict, .wrongPitch)
        XCTAssertFalse(provisional[0].settled)
        let improved = TimedMatcher.live(t, attacks: [wrong, attacks(p)[0]], elapsed: 0.55, offsetMS: 0)
        XCTAssertEqual(improved[0].assessment.verdict, .onTime)
        XCTAssertTrue(improved[0].settled)
        XCTAssertTrue(TimedMatcher.live(t, attacks: [], elapsed: .nan, offsetMS: 0).isEmpty)
    }
    func testGuideAndFallbackCannotAdvanceAsIndependentEvidence() throws {
        var p = try plan()
        p.setup.guide = true
        XCTAssertEqual(result(p).grade, .supported)
        p.setup.guide = false
        var a = attacks(p)
        a[0].arrivalTimestamp = true
        XCTAssertEqual(result(p, attacks: a).grade, .supported)
        XCTAssertEqual(result(p).grade, .good)
    }
    func testIdentitySeparatesMusicalConditionsButNotChallengeChoice() throws {
        let p = try plan()
        let id = p.identity(offsetMS: 0)
        var changed = p
        changed.setup.challenge = .clean
        XCTAssertEqual(changed.identity(offsetMS: 0), id)
        changed.setup.guide = true
        XCTAssertNotEqual(changed.identity(offsetMS: 0), id)
        changed = p
        changed.setup.tempo += 5
        XCTAssertNotEqual(changed.identity(offsetMS: 0), id)
        changed = p
        changed.setup.drums = false
        XCTAssertNotEqual(changed.identity(offsetMS: 0), id)
        changed = p
        changed.setup.style = .swing
        XCTAssertNotEqual(changed.identity(offsetMS: 0), id)
        XCTAssertNotEqual(p.identity(offsetMS: 70), id)
    }
    func testForgedPassPlanConditionsAndUnsupportedSourcesFailValidation() throws {
        let p = try plan()
        var r = result(p)
        r.pass.plan.targets[0].pitch += 1
        XCTAssertFalse(r.valid)
        r = result(p)
        r.pass.conditions.click = true
        XCTAssertFalse(r.valid)
        r = result(p)
        r.pass.conditions.input = .space
        XCTAssertFalse(r.valid)
        r = result(p, offset: 251)
        XCTAssertFalse(r.valid)
        var bad = p
        bad.setup.tempo = 170
        XCTAssertFalse(bad.valid)
        bad = p
        bad.sourceStart = .nan
        XCTAssertFalse(bad.valid)
        bad = p
        bad.material.accompanimentIssue = "No chord symbols"
        XCTAssertFalse(bad.valid)
        bad = p
        bad.material.beats = 15
        XCTAssertFalse(bad.valid)
    }
    func testCalibrationRejectsMissingErraticExtraAndOutOfRangeInput() throws {
        let p = TimedPracticePlan.calibration()
        let a = p.targets.map { TimedAttack(seconds: $0.beat * p.secondsPerBeat + 0.07) }
        XCTAssertEqual(try TimedMatcher.assess(p, attacks: a).calibrationOffsetMS, 70)
        XCTAssertNil(try TimedMatcher.assess(p, attacks: Array(a.prefix(5))).calibrationOffsetMS)
        XCTAssertNil(try TimedMatcher.assess(p, attacks: a + [.init(seconds: 0.3)]).calibrationOffsetMS)
        let jitter = p.targets.enumerated().map {
            TimedAttack(seconds: $0.element.beat * p.secondsPerBeat + ($0.offset % 2 == 0 ? 0.2 : -0.2))
        }
        XCTAssertNil(try TimedMatcher.assess(p, attacks: jitter).calibrationOffsetMS)
        XCTAssertThrowsError(try TimedMatcher.assess(p, attacks: [.init(seconds: .infinity)]))
    }
    func testRoundTripMigrationAndInvalidHistoryRejected() throws {
        let r = result(try plan())
        var state = PracticeState()
        state.history.playAlong = [r.practiceID: PlayAlongProgress(result: r)]
        XCTAssertEqual(
            try JSONDecoder().decode(PracticeState.self, from: JSONEncoder().encode(state)).validated(), state)
        state.history.playAlong = ["forged": PlayAlongProgress(result: r)]
        XCTAssertThrowsError(try state.validated())
        state = PracticeState()
        state.schemaVersion = 7
        XCTAssertEqual(try state.validated().schemaVersion, 15)
        XCTAssertNil(try state.validated().history.playAlong)
        state.schemaVersion = 16
        XCTAssertThrowsError(try state.validated())
    }
    func testRestAndTieOnlyProduceWrittenAttacksAndSourceBarNumbers() throws {
        var doc = try ScoreEarTests().document()
        doc.events[0].pitches = []
        doc.events[2].pitches = doc.events[1].pitches.map { EditorPitch($0.midi) }
        doc.events[1].tieNext = true
        let m = try ScoreEarTests().material(doc)
        let p = try PlayAlongPlan(material: m, sourceStart: 0, setup: .init())
        XCTAssertEqual(p.timed.targets.first?.beat, 2)
        XCTAssertFalse(p.timed.targets.contains { $0.beat == 4 })
        let sub = try ScoreEarTests().material(from: 3, through: 4)
        let later = try PlayAlongPlan(material: sub, sourceStart: 8, setup: .init())
        XCTAssertEqual(later.timed.targets.map(\.bar), [2, 2, 3, 3])
        XCTAssertEqual(later.timed.source?.startBeat, 8)
    }
}
