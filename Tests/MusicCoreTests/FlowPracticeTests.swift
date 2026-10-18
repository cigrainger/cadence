// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class FlowPracticeTests: XCTestCase {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    func piece() throws -> LibraryPiece {
        var doc = try EditorDocument.blank(instrument: .piano, bars: 4)
        doc.events = []
        for bar in 0..<4 {
            for pitch in [60, 62, 64, 65] {
                doc.events.append(.init(bar: bar, rhythm: .init(480), pitches: [EditorPitch(pitch + bar)]))
            }
            doc.events.append(.init(bar: bar, staff: 2, rhythm: .init(1920), pitches: [EditorPitch(48 + bar)]))
        }
        return LibraryPiece(source: .score(try doc.validated()))
    }
    func pass(_ plan: TimedPracticePlan, at: Int, pulse: FlowPulse? = nil, partner: Int? = nil) -> TimedPracticeResult {
        .init(
            date: date.addingTimeInterval(Double(at)), plan: plan,
            conditions: .init(click: pulse?.click ?? false, partnerStaff: partner, flowPulse: pulse),
            attacks: plan.targets.map { .init(seconds: $0.beat * plan.secondsPerBeat, pitch: $0.pitch) })
    }
    func focused(both: Bool = false) throws -> (LibraryPiece, PieceRehearsal) {
        let piece = try piece()
        let plan = try RehearsalSource.plan(
            piece, scope: .init(partID: "P1", staff: both ? nil : 1, from: 0, through: 3), tempo: 80)
        var record = try PieceRehearsal(opening: plan, now: date)
        var opening = pass(plan, at: 1)
        if let i = opening.attacks.firstIndex(where: { $0.seconds == 8 * plan.secondsPerBeat }) {
            opening.attacks[i].seconds += 0.15
        }
        try record.recordOpening(
            opening, focus: RehearsalSource.focus(piece, opening: opening), context: plan,
            now: date.addingTimeInterval(1))
        let join = try XCTUnwrap(FlowPractice.joins(piece: piece, record: record).first)
        try record.configureFlow(.init(plan: join.plan, tempo: 65))
        return (piece, record)
    }
    func attempt(
        _ record: inout PieceRehearsal, at: Int, exercise: RehearsalExercise = .notes,
        transform: (inout TimedPracticeResult) -> Void = { _ in }
    ) throws {
        let flow = try XCTUnwrap(record.flow)
        let plan = try PieceRehearsal.exercisePlan(flow.plan, exercise: exercise, tempo: flow.tempo)
        var result = pass(
            plan, at: at, pulse: flow.pulse,
            partner: flow.partner ? PianoHands.partner(in: flow.plan, exercise: exercise) : nil)
        transform(&result)
        try record.recordFocus(
            result, exercise: exercise, flowSource: flow.plan, now: date.addingTimeInterval(Double(at)))
    }
    func advice(_ record: PieceRehearsal, exercise: RehearsalExercise = .notes) -> FlowAdvice {
        FlowPractice.advice(record, exercise: exercise, now: date.addingTimeInterval(20))
    }
    func testJoinUsesBothSidesAndRanksObservedEntranceWithoutInferringTechnique() throws {
        let (piece, record) = try focused()
        let joins = try FlowPractice.joins(piece: piece, record: record)
        XCTAssertEqual(joins.count, 3)
        XCTAssertEqual(joins.first?.bar, 2)
        XCTAssertEqual(record.flow?.plan.source?.scope.from, 1)
        XCTAssertEqual(record.flow?.plan.source?.scope.through, 2)
        XCTAssertTrue(joins.first!.reason.contains("was late"))
        XCTAssertFalse(joins.first!.reason.contains("fingering"))
        XCTAssertTrue(
            joins.allSatisfy {
                RehearsalSource.current($0.plan, in: piece) && FlowPractice.contains($0.plan, in: record.opening)
            })
    }
    func testJoinExpandsToPreserveTiesAndOneBarHasNoJoin() throws {
        guard case .score(var doc) = try piece().source else { return XCTFail("Expected a score") }
        let left = doc.events.indices.filter { doc.events[$0].staff == 2 }
        doc.events[left[1]].pitches = [EditorPitch(48)]
        doc.events[left[0]].tieNext = true
        let piece = LibraryPiece(source: .score(try doc.validated()))
        let opening = try RehearsalSource.plan(
            piece, scope: .init(partID: "P1", staff: nil, from: 0, through: 3), tempo: 80)
        let record = try PieceRehearsal(opening: opening, now: date)
        let join = try XCTUnwrap(FlowPractice.joins(piece: piece, record: record).first { $0.bar == 2 })
        XCTAssertEqual(join.plan.source?.scope.from, 0)
        XCTAssertEqual(join.plan.source?.scope.through, 2)
        let single = try RehearsalSource.plan(
            piece, scope: .init(partID: "P1", staff: 1, from: 2, through: 2), tempo: 80)
        XCTAssertTrue(try FlowPractice.joins(piece: piece, record: .init(opening: single, now: date)).isEmpty)
    }
    func testTempoSuggestionNeedsTwoComparablePassesAndToleratesOneMissedEntrance() throws {
        var (_, record) = try focused()
        try attempt(&record, at: 2) { $0.attacks.removeLast() }
        XCTAssertNil(advice(record).settings)
        try attempt(&record, at: 3) { $0.attacks.removeLast() }
        XCTAssertEqual(advice(record).settings?.tempo, 70)
        XCTAssertEqual(record.flow?.tempo, 65, "Suggestions never change settings automatically")
        XCTAssertEqual(record.review.encounters, 0)
    }
    func testSettingChangesInterruptTheComparablePair() throws {
        var (_, record) = try focused()
        try attempt(&record, at: 2)
        try attempt(&record, at: 3)
        var flow = record.flow!
        flow.pulse = .bars
        try record.configureFlow(flow)
        XCTAssertNil(advice(record).settings)
        try attempt(&record, at: 4)
        XCTAssertNil(advice(record).settings)
        try attempt(&record, at: 5)
        XCTAssertEqual(advice(record).settings?.tempo, 70)
        flow.tempo = 70
        try record.configureFlow(flow)
        XCTAssertNil(advice(record).settings)
    }
    func testFallbackTimestampsAndOldEvidenceDoNotAdvanceTempo() throws {
        var (_, record) = try focused()
        try attempt(&record, at: 2)
        try attempt(&record, at: 3) { $0.attacks[0].arrivalTimestamp = true }
        XCTAssertNil(advice(record).settings)
        XCTAssertNil(FlowPractice.advice(record, exercise: .notes, now: date.addingTimeInterval(90000)).settings)
        XCTAssertNil(FlowPractice.advice(record, exercise: .notes, now: date).settings)
    }
    func testDifferentTimingOffsetsCannotFormComparablePair() throws {
        var (_, record) = try focused()
        try attempt(&record, at: 2)
        try attempt(&record, at: 3) { $0.conditions.offsetMS = 20 }
        XCTAssertNil(advice(record).settings)
    }
    func testRepeatedDifficultySuggestsSlowerTempoOrMorePulseAtFloor() throws {
        var (_, record) = try focused()
        try attempt(&record, at: 2) { $0.attacks = [] }
        try attempt(&record, at: 3) { $0.attacks = [] }
        XCTAssertEqual(advice(record).settings?.tempo, 60)
        var flow = record.flow!
        flow.tempo = 40
        flow.pulse = .gaps
        try record.configureFlow(flow)
        try attempt(&record, at: 4) { $0.attacks = [] }
        try attempt(&record, at: 5) { $0.attacks = [] }
        XCTAssertEqual(advice(record).settings?.pulse, .beats)
    }
    func testSupportFadesOnlyAfterOpeningTempoAndHandEvidenceStaysSeparate() throws {
        var (_, record) = try focused(both: true)
        var flow = record.flow!
        flow.tempo = 80
        try record.configureFlow(flow)
        try attempt(&record, at: 2, exercise: .rightHand)
        try attempt(&record, at: 3, exercise: .rightHand)
        XCTAssertFalse(advice(record, exercise: .rightHand).settings!.partner)
        XCTAssertNil(advice(record, exercise: .leftHand).settings)
        flow.partner = false
        try record.configureFlow(flow)
        try attempt(&record, at: 4, exercise: .rightHand)
        try attempt(&record, at: 5, exercise: .rightHand)
        XCTAssertEqual(advice(record, exercise: .rightHand).settings?.pulse, .bars)
    }
    func testAllPulseStagesAndFinalSuggestionAreSupportedPractice() throws {
        var (_, record) = try focused()
        var flow = record.flow!
        flow.tempo = 80
        try record.configureFlow(flow)
        var second = 2
        for pulse in FlowPulse.allCases {
            flow.pulse = pulse
            try record.configureFlow(flow)
            try attempt(&record, at: second)
            try attempt(&record, at: second + 1)
            second += 2
            XCTAssertEqual(record.focusResults.last?.pass.grade, .supported)
            XCTAssertEqual(advice(record).settings?.pulse, pulse.next)
        }
        XCTAssertTrue(advice(record).title.contains("music"))
        XCTAssertEqual(record.review.encounters, 0)
        XCTAssertTrue(record.valid)
    }
    func testTamperedTargetsSourceSupportAndMissingFlowMarkerAreRejected() throws {
        var (_, record) = try focused()
        var flow = record.flow!
        flow.plan.targets[0].pitch = 100
        XCTAssertThrowsError(try record.configureFlow(flow))
        flow = record.flow!
        flow.plan.source?.scope.partID = "other"
        XCTAssertThrowsError(try record.configureFlow(flow))
        flow = record.flow!
        flow.tempo = 85
        XCTAssertThrowsError(try record.configureFlow(flow))
        let plan = try PieceRehearsal.exercisePlan(record.activePlan, exercise: .notes, tempo: 65)
        XCTAssertThrowsError(
            try record.recordFocus(pass(plan, at: 2, pulse: .beats), exercise: .notes, now: date.addingTimeInterval(2)))
        XCTAssertThrowsError(
            try record.recordFocus(
                pass(plan, at: 2, pulse: .off), exercise: .notes, flowSource: record.activePlan,
                now: date.addingTimeInterval(2)))
        XCTAssertFalse(TimedConditions(click: false, flowPulse: .gaps).valid)
        XCTAssertFalse(TimedConditions(click: true, flowPulse: .off).valid)
    }
    func testDifferentJoinsPersistWithExactSourcesAndLegacyFocusStillWorks() throws {
        var (piece, record) = try focused()
        try attempt(&record, at: 2)
        let first = record.flow!.plan
        var flow = record.flow!
        flow.plan = try FlowPractice.joins(piece: piece, record: record).last!.plan
        try record.configureFlow(flow)
        try attempt(&record, at: 3)
        XCTAssertEqual(record.focusResults.first?.flowSource, first)
        XCTAssertTrue(record.valid)
        try record.configureFlow(nil)
        var old = pass(record.activePlan, at: 4)
        old.conditions.click = true
        try record.recordFocus(old, exercise: .notes, now: date.addingTimeInterval(4))
        XCTAssertNil(record.focusResults.last?.flowSource)
        XCTAssertTrue(record.valid)
        XCTAssertEqual(try JSONDecoder().decode(PieceRehearsal.self, from: JSONEncoder().encode(record)), record)
    }
    func testIndependentReturnCannotCarryFlowConditionsAndReflectionDoesNotChangeSchedule() throws {
        var (_, record) = try focused(both: true)
        try attempt(&record, at: 2, exercise: .rightHand)
        XCTAssertThrowsError(try record.returnToPhrase())
        try attempt(&record, at: 3)
        try record.returnToPhrase()
        XCTAssertEqual(record.activePlan, record.opening)
        XCTAssertThrowsError(
            try record.recordContext(pass(record.activePlan, at: 4, pulse: .off), now: date.addingTimeInterval(4)))
        try record.recordContext(pass(record.activePlan, at: 4), now: date.addingTimeInterval(4))
        let due = record.nextReview
        record.flowReflection = .easier
        XCTAssertEqual(record.nextReview, due)
        XCTAssertTrue(record.valid)
        let time = try XCTUnwrap(due)
        try record.beginReview(now: time)
        try record.startReviewPass(now: time)
        var result = pass(record.activePlan, at: 5)
        result.date = time
        try record.recordReview(result, now: time)
        XCTAssertTrue(record.reviews.last!.independent)
        try record.practiseAgain(now: time)
        XCTAssertNil(record.flowReflection)
        XCTAssertTrue(record.valid)
    }
    func testPulseAudioKeepsFullCountInAndSilencesExactlyTheChosenBeats() throws {
        let (_, record) = try focused()
        let plan = record.activePlan
        let rate = 8000.0
        let plain = try TimedClickTrack.render(plan, click: true, sampleRate: rate)
        for pulse in FlowPulse.allCases {
            let audio = try TimedClickTrack.render(plan, click: pulse.click, sampleRate: rate, flowPulse: pulse)
            let boundary = Int((plan.countIn * rate).rounded())
            XCTAssertEqual(Array(audio[..<boundary]), Array(plain[..<boundary]))
            for beat in 0..<Int(plan.length) {
                let index = Int(((plan.countIn + Double(beat) * plan.secondsPerBeat) * rate).rounded())
                let energy = audio[index..<(index + 280)].reduce(0) { $0 + abs($1) }
                XCTAssertEqual(energy > 0, pulse.sounds(at: beat, beatsPerBar: 4))
            }
        }
        XCTAssertThrowsError(try TimedClickTrack.render(plan, click: true, flowPulse: .off))
        XCTAssertFalse(FlowPulse.gaps.sounds(at: -1, beatsPerBar: 4))
        XCTAssertFalse(FlowPulse.bars.sounds(at: 0, beatsPerBar: 0))
    }
    func testLegacyConditionIdentityAndMigrationRemainCompatible() throws {
        let (_, record) = try focused()
        let plan = record.activePlan
        let legacy = try JSONDecoder().decode(
            TimedConditions.self, from: Data("{\"input\":\"MIDI keyboard\",\"click\":true,\"offsetMS\":0}".utf8))
        XCTAssertNil(legacy.flowPulse)
        XCTAssertEqual(plan.identity(legacy), plan.identity(.init()))
        XCTAssertEqual(Set(FlowPulse.allCases.map { plan.identity(.init(click: $0.click, flowPulse: $0)) }).count, 4)
        var snapshot = PracticeState()
        snapshot.schemaVersion = 11
        XCTAssertEqual(try snapshot.validated().schemaVersion, 18)
        snapshot.schemaVersion = 19
        XCTAssertThrowsError(try snapshot.validated())
    }
    func testSparsePulseRejectsPartialBarGeometryAndForgedHistory() throws {
        var (_, record) = try focused()
        var altered = record.flow!.plan
        altered.length -= 0.5
        XCTAssertTrue(altered.valid)
        XCTAssertFalse(FlowPractice.contains(altered, in: record.opening))
        altered = record.flow!.plan
        altered.source?.startBeat += 0.5
        XCTAssertFalse(FlowPractice.contains(altered, in: record.opening))
        try attempt(&record, at: 2)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        var results = try XCTUnwrap(json["focusResults"] as? [[String: Any]])
        results[0].removeValue(forKey: "flowSource")
        json["focusResults"] = results
        let restored = try JSONDecoder().decode(PieceRehearsal.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(restored.valid)
    }
    func testMixedAttemptsStayOptionalAndSingleBarSkipsSilentBarStage() throws {
        var (piece, record) = try focused()
        try attempt(&record, at: 2)
        try attempt(&record, at: 3) { $0.attacks.removeFirst(3) }
        XCTAssertNil(advice(record).settings)
        XCTAssertTrue(advice(record).title.contains("Stay"))
        let single = try RehearsalSource.plan(
            piece, scope: .init(partID: "P1", staff: 1, from: 0, through: 0), tempo: 80)
        try record.configureFlow(.init(plan: single, tempo: 80, pulse: .bars))
        try attempt(&record, at: 4)
        try attempt(&record, at: 5)
        XCTAssertEqual(advice(record).settings?.pulse, .off)
    }
}
