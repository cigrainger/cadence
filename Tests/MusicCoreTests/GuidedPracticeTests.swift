// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class GuidedPracticeTests: XCTestCase {
    private func note(
        _ midi: Int, _ start: Double, _ duration: Double = 1, staff: Int = 1, tieStart: Bool = false,
        tieStop: Bool = false
    ) -> StudyNote {
        StudyNote(
            midi: midi, start: start, duration: duration, measure: Int(start / 4), voice: "1", staff: staff,
            tieStart: tieStart, tieStop: tieStop)
    }
    private func study(_ notes: [StudyNote], bars: Int = 1, staff: Int? = nil) -> MusicStudy {
        let measures = (0..<bars).map {
            StudyMeasure(
                index: $0, label: String($0 + 1), start: Double($0 * 4), duration: 4, beats: 4, beatUnit: 4, fifths: 0)
        }
        let part = StudyPart(id: "P1", name: "Piano", measures: measures, notes: notes, tabStaves: [])
        var study = MusicStudy(
            document: StudyDocument(
                title: "Fixture", composer: "", tempo: 84, originalXML: StudyExamples.smallSteps, parts: [part],
                notices: []), filename: "fixture.xml")
        study.staff = staff
        return study
    }
    private func plan(_ study: MusicStudy) throws -> GuidedPassage {
        try GuidedPassage(
            study: study, pieceID: "study:" + study.id.uuidString, fingerprint: String(repeating: "a", count: 64))
    }
    @discardableResult private func send(
        _ message: MIDIMessage, _ follower: inout GuidedFollower, _ keyboard: inout MIDIKeyboardState
    ) -> GuidedInputResult {
        keyboard.receive(message)
        return follower.receive(message, keyboard: keyboard)
    }
    private func on(_ note: Int) -> MIDIMessage { .noteOn(channel: 0, note: note, velocity: 90) }
    private func off(_ note: Int) -> MIDIMessage { .noteOff(channel: 0, note: note) }

    func testPianoHandsRemainDistinctAndOtherHandIsScopedToStep() throws {
        let both = study([note(60, 0), note(62, 1), note(48, 0, 4, staff: 2)])
        XCTAssertEqual(try plan(both).steps.map(\.notes), [[48, 60], [62]])
        var right = both
        right.staff = 1
        let rightPlan = try plan(right)
        XCTAssertEqual(rightPlan.steps.map(\.notes), [[60], [62]])
        XCTAssertEqual(rightPlan.otherHand(at: 1)?.notes.map(\.midi), [48])
        XCTAssertEqual(rightPlan.otherHand(at: 1)?.notes[0].start, 0)
        XCTAssertEqual(rightPlan.otherHand(at: 1)?.notes[0].duration, 3)
        XCTAssertNotEqual(try plan(both).id, rightPlan.id)
        var left = both
        left.staff = 2
        XCTAssertEqual(try plan(left).steps.map(\.notes), [[48]])
        XCTAssertNil(try plan(both).otherHand(at: 0))
        XCTAssertNil(rightPlan.otherHand(at: 100))
    }
    func testTiesCarryAcrossAttacksAndClipIntoSelectedBar() throws {
        var source = study(
            [
                note(48, 0, 4, staff: 2, tieStart: true), note(48, 4, 4, staff: 2, tieStop: true), note(60, 0),
                note(62, 4), note(64, 5),
            ], bars: 2)
        let full = try plan(source)
        XCTAssertEqual(full.steps.map(\.notes), [[48, 60], [62], [64]])
        XCTAssertTrue(full.steps[1].carried.contains(48))
        source.select(from: 1, through: 1)
        let clipped = try plan(source)
        XCTAssertEqual(clipped.steps.first?.notes, [48, 62])
        XCTAssertEqual(clipped.steps.first?.beat, 4)
        XCTAssertEqual(clipped.steps.first?.bar, 1)
    }
    func testRestsNeverRequireInputAndRepeatedNotesDoRequireNewAttack() throws {
        let p = try plan(study([note(-1, 0), note(60, 1), note(-1, 2), note(60, 3)]))
        XCTAssertEqual(p.steps.map(\.beat), [1, 3])
        var f = GuidedFollower(plan: p)
        var keys = MIDIKeyboardState()
        XCTAssertEqual(send(on(60), &f, &keys), .advanced)
        XCTAssertEqual(send(on(60), &f, &keys), .ignored)
        XCTAssertEqual(f.index, 1)
        send(off(60), &f, &keys)
        XCTAssertEqual(send(on(60), &f, &keys), .complete)
    }
    func testChordMustBePresentTogetherAndPedalCannotSupplyMissingKey() throws {
        var f = GuidedFollower(plan: try plan(study([note(60, 0), note(64, 0), note(67, 0)])))
        var keys = MIDIKeyboardState()
        send(.control(channel: 0, number: 64, value: 127), &f, &keys)
        send(on(60), &f, &keys)
        send(off(60), &f, &keys)
        send(on(64), &f, &keys)
        send(on(67), &f, &keys)
        XCTAssertEqual(f.index, 0)
        XCTAssertEqual(keys.soundingNotes, [60, 64, 67])
        XCTAssertEqual(send(on(60), &f, &keys), .complete)
    }
    func testWrongNotesAndWrongOctaveWaitAndRecordOnlyFreshPresses() throws {
        var f = GuidedFollower(plan: try plan(study([note(60, 0)])))
        var keys = MIDIKeyboardState()
        XCTAssertEqual(send(on(72), &f, &keys), .correction(72))
        send(on(72), &f, &keys)
        XCTAssertEqual(f.mistakes, [1])
        send(on(60), &f, &keys)
        XCTAssertFalse(f.complete)
        XCTAssertEqual(send(off(72), &f, &keys), .complete)
        let result = try f.result(id: UUID())
        XCTAssertEqual(result.firstPass, 0)
        XCTAssertEqual(result.difficultBars, [0])
        XCTAssertEqual(result.grade, .again)
        XCTAssertTrue(result.valid)
    }
    func testHeldBassDoesNotRequireReattackButExpiredKeysMustRelease() throws {
        var f = GuidedFollower(plan: try plan(study([note(48, 0, 4), note(60, 0), note(62, 1)])))
        var keys = MIDIKeyboardState()
        send(on(48), &f, &keys)
        send(on(60), &f, &keys)
        XCTAssertEqual(f.index, 1)
        send(on(62), &f, &keys)
        XCTAssertEqual(f.index, 1)
        XCTAssertEqual(send(off(60), &f, &keys), .complete)
        XCTAssertEqual(f.mistakes, [0, 0])
    }
    func testArmingPauseAndResetRequireReleaseAndDiscardPartialChord() throws {
        let p = try plan(study([note(60, 0), note(64, 0)]))
        var keys = MIDIKeyboardState()
        keys.receive(on(60))
        var f = GuidedFollower(plan: p, held: keys.downNotes)
        send(on(64), &f, &keys)
        XCTAssertFalse(f.complete)
        send(off(60), &f, &keys)
        send(off(64), &f, &keys)
        send(on(60), &f, &keys)
        f.resume(held: keys.downNotes)
        send(on(64), &f, &keys)
        XCTAssertFalse(f.complete)
        send(.reset, &f, &keys)
        send(on(64), &f, &keys)
        XCTAssertFalse(f.complete)
        XCTAssertEqual(send(on(60), &f, &keys), .complete)
    }
    func testMalformedInputAndChannelDuplicatesCannotInventAttacks() throws {
        var f = GuidedFollower(plan: try plan(study([note(60, 0), note(60, 1)])))
        var keys = MIDIKeyboardState()
        send(.noteOn(channel: 99, note: 60, velocity: 90), &f, &keys)
        send(on(Int.max), &f, &keys)
        XCTAssertEqual(f.index, 0)
        send(on(60), &f, &keys)
        send(.noteOn(channel: 1, note: 60, velocity: 90), &f, &keys)
        send(off(60), &f, &keys)
        XCTAssertFalse(f.complete)
        send(.noteOff(channel: 1, note: 60), &f, &keys)
        XCTAssertEqual(send(on(60), &f, &keys), .complete)
    }
    func testHintAndCompletionAreExplicitAndResultRoundTrips() throws {
        var f = GuidedFollower(plan: try plan(study([note(60, 0)])))
        var keys = MIDIKeyboardState()
        XCTAssertThrowsError(try f.result(id: UUID()))
        f.hint()
        send(on(60), &f, &keys)
        let result = try f.result(id: UUID(), date: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(result.grade, .supported)
        XCTAssertEqual(result.firstPass, 0)
        XCTAssertTrue(result.evidence.contains("rhythm, duration, fluency"))
        XCTAssertEqual(result, try JSONDecoder().decode(GuidedPassageResult.self, from: JSONEncoder().encode(result)))
        XCTAssertEqual(send(off(60), &f, &keys), .ignored)
    }
    func testEmptyOversizedAndTabOnlySelectionsFailWithNoInventedTargets() throws {
        XCTAssertThrowsError(try plan(study([note(-1, 0, 4)])))
        XCTAssertThrowsError(try plan(study((21...31).map { note($0, 0) })))
        var source = study([note(60, 0)])
        source.document.parts[0].tabStaves = [1]
        source.staff = 1
        XCTAssertThrowsError(try plan(source))
        source.staff = 16
        XCTAssertThrowsError(try plan(source))
        XCTAssertThrowsError(try plan(study(Array(repeating: note(60, 0), count: 513))))
    }
    func testGuitarTabDuplicateAndSoundingOctaveAreRespected() throws {
        let source = try ComposePractice.make(.guitarExample, from: 0, through: 3)
        let p = try plan(source)
        XCTAssertEqual(p.steps.first?.notes, [EditorDocument.guitarExample.events[0].pitches[0].midi])
        XCTAssertEqual(p.steps.count, Set(source.selectedNotes.map(\.start)).count)
    }
    func testScoreAndScopeChangesProduceSeparateReviewIdentities() throws {
        var source = study([note(60, 0), note(62, 4)], bars: 2)
        let original = try plan(source)
        source.select(from: 1, through: 1)
        XCTAssertNotEqual(try plan(source).id, original.id)
        let changed = try GuidedPassage(
            study: source, pieceID: original.pieceID, fingerprint: String(repeating: "b", count: 64))
        XCTAssertNotEqual(changed.id, try plan(source).id)
    }
    func testMalformedResultCannotEnterPracticeSnapshot() throws {
        var f = GuidedFollower(plan: try plan(study([note(60, 0)])))
        var keys = MIDIKeyboardState()
        send(on(60), &f, &keys)
        var result = try f.result(id: UUID())
        result.steps[0].corrections = -1
        XCTAssertFalse(result.valid)
        var state = PracticeState()
        state.history.guidedPassages = [result.practiceID: GuidedPassageProgress(result: result)]
        XCTAssertThrowsError(try state.validated())
    }
}
