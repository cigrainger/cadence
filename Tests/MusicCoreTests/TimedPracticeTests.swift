// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class TimedPracticeTests: XCTestCase {
    private func note(
        midi: Int, start: Double, duration: Double, measure: Int, voice: String = "1", staff: Int = 1,
        tieStart: Bool = false, tieStop: Bool = false
    ) -> StudyNote {
        StudyNote(
            midi: midi, start: start, duration: duration, measure: measure, voice: voice, staff: staff,
            tieStart: tieStart, tieStop: tieStop)
    }
    private func played(_ plan: TimedPracticePlan, delta: Double = 0) -> [TimedAttack] {
        plan.targets.map { TimedAttack(seconds: $0.beat * plan.secondsPerBeat + delta, pitch: $0.pitch) }
    }
    private func piano(_ notes: [StudyNote]? = nil, bars: Int = 2) throws -> (MusicStudy, GuidedPassage) {
        let measures = (0..<bars).map {
            StudyMeasure(
                index: $0, label: "\($0+1)", start: Double($0 * 4), duration: 4, beats: 4, beatUnit: 4, fifths: 0)
        }
        let notes =
            notes ?? [
                note(midi: 60, start: 0, duration: 1, measure: 0), note(midi: 64, start: 0, duration: 1, measure: 0),
                note(midi: 67, start: 0, duration: 1, measure: 0), note(midi: 62, start: 1, duration: 1, measure: 0),
                note(midi: 64, start: 4, duration: 1, measure: 1),
            ]
        let part = StudyPart(id: "P1", name: "Piano", measures: measures, notes: notes, tabStaves: [])
        var study = MusicStudy(
            document: StudyDocument(
                title: "Timing fixture", composer: "", tempo: 80, originalXML: StudyExamples.smallSteps, parts: [part],
                notices: []), filename: "test.xml")
        study.staff = 1
        study.select(from: 0, through: bars - 1)
        let guide = try GuidedPassage(
            study: study, pieceID: "study:test", fingerprint: String(repeating: "a", count: 64))
        return (study, guide)
    }
    func testAllRhythmsHaveIndependentValidPlansAndClearInstructions() throws {
        for exercise in RhythmExercise.allCases {
            let plan = TimedPracticePlan(rhythm: exercise, tempo: 80)
            XCTAssertTrue(plan.valid)
            XCTAssertFalse(exercise.instruction.isEmpty)
            let report = try TimedMatcher.assess(plan, attacks: played(plan))
            XCTAssertTrue(report.clean)
            XCTAssertEqual(report.onTime, plan.targets.count)
            XCTAssertEqual(report.medianOffset!, 0, accuracy: 0.000001)
            XCTAssertTrue(report.difficultBars.isEmpty)
        }
    }
    func testEarlyLatePitchAndMissRemainDistinct() throws {
        let (study, guided) = try piano()
        let plan = try TimedPracticePlan(study: study, guided: guided, tempo: 80)
        var events = played(plan)
        events[0].seconds -= 0.12
        events[1].seconds += 0.14
        events[2].pitch = 66
        events.remove(at: 3)
        let report = try TimedMatcher.assess(plan, attacks: events)
        XCTAssertEqual(report.early, 1)
        XCTAssertEqual(report.late, 1)
        XCTAssertEqual(report.wrong, 1)
        XCTAssertEqual(report.missed, 1)
        XCTAssertEqual(report.onTime, 1)
        XCTAssertEqual(report.matchedPitch, 3)
        XCTAssertEqual(report.difficultBars, [0])
        XCTAssertEqual(report.extras.count, 0)
    }
    func testMissingExtraAndWrongNotesDoNotCascade() throws {
        let plan = TimedPracticePlan(rhythm: .pulse, tempo: 80)
        var events = played(plan)
        events.remove(at: 2)
        events.append(TimedAttack(seconds: 2.5 * plan.secondsPerBeat))
        let report = try TimedMatcher.assess(plan, attacks: events)
        XCTAssertEqual(report.onTime, 7)
        XCTAssertEqual(report.missed, 1)
        XCTAssertEqual(report.extras.count, 1)
        XCTAssertEqual(report.notes.last?.verdict, .onTime)
    }
    func testChordPermutationAndStrayNoteCannotStealCorrectPitches() throws {
        let (study, guide) = try piano()
        let plan = try TimedPracticePlan(study: study, guided: guide, tempo: 90)
        var events = Array(played(plan).reversed())
        events.insert(TimedAttack(seconds: 0, pitch: 61), at: 0)
        let report = try TimedMatcher.assess(plan, attacks: events)
        XCTAssertEqual(report.onTime, 5)
        XCTAssertEqual(report.wrong, 0)
        XCTAssertEqual(report.extras.map(\.pitch), [61])
    }
    func testTiedNotesAndLeadingRestsUseOnlyWrittenEntrances() throws {
        let notes = [
            note(midi: -1, start: 0, duration: 1, measure: 0),
            note(midi: 60, start: 1, duration: 3, measure: 0, tieStart: true),
            note(midi: 60, start: 4, duration: 1, measure: 1, tieStop: true),
            note(midi: 60, start: 6, duration: 1, measure: 1),
        ]
        let (study, guide) = try piano(notes)
        let plan = try TimedPracticePlan(study: study, guided: guide, tempo: 80)
        XCTAssertEqual(plan.targets.map(\.beat), [1, 6])
        XCTAssertEqual(plan.length, 8)
        let report = try TimedMatcher.assess(plan, attacks: played(plan) + [TimedAttack(seconds: 0)])
        XCTAssertEqual(report.onTime, 2)
        XCTAssertEqual(report.extras.count, 1)
        var selected = study
        selected.select(from: 1, through: 1)
        let sliced = try TimedPracticePlan(
            study: selected,
            guided: GuidedPassage(
                study: selected, pieceID: "study:test", fingerprint: String(repeating: "a", count: 64)), tempo: 80)
        XCTAssertEqual(sliced.targets.map(\.beat), [0, 2])
        XCTAssertEqual(sliced.source?.startBeat, 4)
    }
    func testFastSubdivisionsUseNarrowerToleranceAndDisjointWindows() throws {
        let plan = TimedPracticePlan(rhythm: .eighths, tempo: 160)
        XCTAssertEqual(plan.tolerance, 0.0375, accuracy: 0.000001)
        let report = try TimedMatcher.assess(plan, attacks: played(plan, delta: 0.06))
        XCTAssertEqual(report.late, plan.targets.count)
        XCTAssertEqual(report.missed, 0)
    }
    func testBoundaryToleranceAndSilentPass() throws {
        let plan = TimedPracticePlan(rhythm: .pulse, tempo: 80)
        XCTAssertTrue(try TimedMatcher.assess(plan, attacks: played(plan, delta: plan.tolerance)).clean)
        XCTAssertEqual(try TimedMatcher.assess(plan, attacks: played(plan, delta: -plan.tolerance - 0.001)).early, 8)
        let silent = try TimedMatcher.assess(plan, attacks: [])
        XCTAssertEqual(silent.missed, 8)
        XCTAssertNil(silent.medianOffset)
        XCTAssertNil(silent.calibrationOffsetMS)
    }
    func testCalibrationRequiresEnoughConsistentTaps() throws {
        let plan = TimedPracticePlan.calibration()
        let consistent = try TimedMatcher.assess(plan, attacks: played(plan, delta: 0.09))
        XCTAssertEqual(consistent.calibrationOffsetMS, 90)
        XCTAssertNil(try TimedMatcher.assess(plan, attacks: Array(played(plan).prefix(5))).calibrationOffsetMS)
        var events = played(plan)
        for i in events.indices { events[i].seconds += i % 2 == 0 ? 0.15 : -0.15 }
        XCTAssertNil(try TimedMatcher.assess(plan, attacks: events).calibrationOffsetMS)
        XCTAssertNil(
            try TimedMatcher.assess(plan, attacks: played(plan) + [TimedAttack(seconds: 0)]).calibrationOffsetMS)
    }
    func testResultsIncludeConditionsAndApproximateTimingCannotEarnCleanReview() throws {
        let plan = TimedPracticePlan(rhythm: .pulse, tempo: 80)
        var result = TimedPracticeResult(plan: plan, conditions: TimedConditions(input: .space), attacks: played(plan))
        XCTAssertTrue(result.valid)
        XCTAssertEqual(result.grade, .good)
        XCTAssertTrue(result.evidence.contains("Note lengths"))
        let original = result.practiceID
        result.conditions.input = .midi
        XCTAssertNotEqual(result.practiceID, original)
        result.conditions.click = false
        XCTAssertNotEqual(result.practiceID, plan.identity(TimedConditions()))
        result.conditions.offsetMS = 30
        XCTAssertNotEqual(result.practiceID, original)
        result.attacks[0].arrivalTimestamp = true
        XCTAssertEqual(result.grade, .supported)
        XCTAssertTrue(result.evidence.contains("1 presses used callback-arrival timing"))
        XCTAssertEqual(try JSONDecoder().decode(TimedPracticeResult.self, from: JSONEncoder().encode(result)), result)
    }
    func testSavedProgressValidationAndLegacyDecoding() throws {
        let plan = TimedPracticePlan(rhythm: .pulse, tempo: 80)
        let result = TimedPracticeResult(plan: plan, conditions: TimedConditions(), attacks: played(plan))
        var history = PracticeProgress()
        history.timedPassages = [result.practiceID: TimedPracticeProgress(result: result)]
        XCTAssertNoThrow(try history.validated())
        history.timedPassages = ["wrong": TimedPracticeProgress(result: result)]
        XCTAssertThrowsError(try history.validated())
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PracticeProgress())) as! [String: Any]
        object.removeValue(forKey: "timedPassages")
        let restored = try JSONDecoder().decode(
            PracticeProgress.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(restored.timedPassages)
    }
    func testInvalidAndHostilePlansAreRejectedWithoutAllocatingAudio() throws {
        let original = TimedPracticePlan(rhythm: .pulse, tempo: 80)
        var cases: [TimedPracticePlan] = []
        var p = original
        p.tempo = 0
        cases.append(p)
        p = original
        p.length = .infinity
        cases.append(p)
        p = original
        p.targets[0].beat = .nan
        cases.append(p)
        p = original
        p.targets[0].pitch = 128
        cases.append(p)
        p = original
        p.targets.append(p.targets[0])
        cases.append(p)
        p = original
        p.targets.reverse()
        cases.append(p)
        p = original
        p.targets[1].beat = 0.0001
        cases.append(p)
        p = original
        p.rhythmID = nil
        cases.append(p)
        p = original
        p.targets = []
        cases.append(p)
        p = original
        p.beatsPerBar = 99
        cases.append(p)
        for plan in cases {
            XCTAssertFalse(plan.valid)
            XCTAssertThrowsError(try TimedMatcher.assess(plan, attacks: []))
            XCTAssertThrowsError(try TimedClickTrack.render(plan, click: true))
        }
        XCTAssertThrowsError(try TimedMatcher.assess(original, attacks: [TimedAttack(seconds: .nan)]))
        XCTAssertThrowsError(try TimedMatcher.assess(original, attacks: [TimedAttack(seconds: 100)]))
        XCTAssertThrowsError(
            try TimedMatcher.assess(original, attacks: Array(repeating: TimedAttack(seconds: 0), count: 2049)))
        var invalid = TimedPracticeResult(plan: original, conditions: TimedConditions(offsetMS: 251), attacks: [])
        XCTAssertFalse(invalid.valid)
        XCTAssertEqual(invalid.grade, .again)
        invalid.plan = .calibration()
        XCTAssertFalse(invalid.valid)
        invalid.plan = cases[0]
        XCTAssertFalse(invalid.report.clean)
    }
    func testUnsupportedPassagesAskForSmallerSelectionAndOneHand() throws {
        let (study, guide) = try piano()
        var both = study
        both.staff = nil
        both.document.parts[0].notes.append(note(midi: 48, start: 0, duration: 1, measure: 0, staff: 2))
        XCTAssertThrowsError(try TimedPracticePlan(study: both, guided: guide, tempo: 80))
        var compound = study
        compound.document.parts[0].measures[0].beatUnit = 8
        XCTAssertThrowsError(try TimedPracticePlan(study: compound, guided: guide, tempo: 80))
        let (long, longGuide) = try piano(bars: 9)
        XCTAssertThrowsError(try TimedPracticePlan(study: long, guided: longGuide, tempo: 80))
        XCTAssertThrowsError(try TimedPracticePlan(study: study, guided: guide, tempo: 200))
        var plan = try TimedPracticePlan(study: study, guided: guide, tempo: 80)
        XCTAssertFalse(TimedPracticeResult(plan: plan, conditions: TimedConditions(input: .space), attacks: []).valid)
        plan.source?.fingerprint = "bad"
        XCTAssertFalse(plan.valid)
    }
    func testClickBufferHasExactSampleSpacingAndQuietPassageWhenClickOff() throws {
        let plan = TimedPracticePlan(rhythm: .offbeats, tempo: 80)
        let rate = 8000.0
        let silent = try TimedClickTrack.render(plan, click: false, sampleRate: rate)
        let click = try TimedClickTrack.render(plan, click: true, sampleRate: rate)
        let demo = try TimedClickTrack.render(plan, click: false, demonstration: true, sampleRate: rate)
        XCTAssertEqual(silent.count, Int(((plan.countIn + plan.duration + 0.6) * rate).rounded()))
        let start = Int(plan.countIn * rate)
        XCTAssertTrue(silent[start...].allSatisfy { $0 == 0 })
        for beat in 0..<8 {
            let index = start + Int(Double(beat) * plan.secondsPerBeat * rate)
            XCTAssertTrue(click[index..<(index + 100)].contains { abs($0) > 0.02 })
        }
        let offbeat = start + Int(1.5 * plan.secondsPerBeat * rate)
        XCTAssertTrue(demo[offbeat..<(offbeat + 100)].contains { abs($0) > 0.02 })
        XCTAssertTrue(click[offbeat..<(offbeat + 100)].allSatisfy { $0 == 0 })
        XCTAssertThrowsError(try TimedClickTrack.render(plan, click: true, sampleRate: .nan))
    }
}
