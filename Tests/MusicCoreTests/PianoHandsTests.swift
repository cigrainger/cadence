// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class PianoHandsTests: XCTestCase {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    func document() throws -> EditorDocument {
        var doc = try EditorDocument.blank(instrument: .piano, bars: 4)
        doc.events = []
        doc.title = "Two parts, one phrase"
        for bar in 0..<4 {
            for pitch in [64 + bar, 67 + bar] {
                doc.events.append(.init(bar: bar, rhythm: .init(960), pitches: [EditorPitch(pitch)]))
            }
            doc.events.append(.init(bar: bar, staff: 2, rhythm: .init(1920), pitches: [EditorPitch(48 + bar)]))
        }
        return try doc.validated()
    }
    func piece() throws -> LibraryPiece { LibraryPiece(source: .score(try document())) }
    func plan(_ piece: LibraryPiece? = nil) throws -> TimedPracticePlan {
        try RehearsalSource.plan(
            try piece ?? self.piece(), scope: .init(partID: "P1", staff: nil, from: 0, through: 3), tempo: 80)
    }
    func pass(_ p: TimedPracticePlan, click: Bool = false, partner: Int? = nil, at: Date? = nil) -> TimedPracticeResult
    {
        .init(
            date: at ?? date.addingTimeInterval(1), plan: p, conditions: .init(click: click, partnerStaff: partner),
            attacks: p.targets.map { .init(seconds: $0.beat * p.secondsPerBeat, pitch: $0.pitch) })
    }
    func focused() throws -> PieceRehearsal {
        let piece = try piece()
        let p = try plan(piece)
        let opening = pass(p)
        var r = try PieceRehearsal(opening: p, now: date)
        try r.recordOpening(
            opening, focus: RehearsalSource.focus(piece, opening: opening),
            context: RehearsalSource.context(piece, opening: p), now: date.addingTimeInterval(1))
        return r
    }
    func testCombinedAndSoloTargetsAreSourceLinkedWithNoKeyboardSplit() throws {
        let piece = try piece()
        let p = try plan(piece)
        XCTAssertTrue(p.valid)
        XCTAssertEqual(p.handStaves, [1, 2])
        XCTAssertEqual(p.targets.count, 12)
        for exercise in [RehearsalExercise.rightHand, .leftHand] {
            let solo = try PianoHands.solo(p, exercise: exercise)
            XCTAssertTrue(RehearsalSource.current(solo, in: piece))
            XCTAssertNil(solo.handStaves)
            XCTAssertTrue(solo.targets.allSatisfy { $0.staves == nil })
            XCTAssertEqual(solo.source?.scope.staff, exercise == .rightHand ? 1 : 2)
        }
        var crossed = try document()
        crossed.events[0].pitches = [EditorPitch(36)]
        crossed.events[2].pitches = [EditorPitch(84)]
        let highLeft = try PianoHands.solo(plan(LibraryPiece(source: .score(crossed))), exercise: .leftHand)
        XCTAssertEqual(highLeft.targets.first?.pitch, 84)
    }
    func testSharedUnisonCountsOnePhysicalKeyAndRetainsBothOwners() throws {
        var doc = try document()
        doc.events[2].pitches = [EditorPitch(64)]
        let piece = LibraryPiece(source: .score(doc))
        let p = try plan(piece)
        let unison = p.targets.first { $0.beat == 0 && $0.pitch == 64 }
        XCTAssertEqual(unison?.staves, [1, 2])
        XCTAssertEqual(p.targets.count, 11)
        XCTAssertTrue(pass(p).report.clean)
        let phrase = try PianoPhrase(piece: piece, plan: p)
        XCTAssertTrue(phrase.valid)
        XCTAssertFalse(phrase.singleVoice)
        XCTAssertTrue(phrase.joins.isEmpty)
        XCTAssertEqual(phrase.notes.first { $0.pitch == 64 && $0.beat == 0 }?.duration, 4)
    }
    func testOverlappingSameKeyAcrossHandsIsExplicitlyUnsupported() throws {
        var doc = try document()
        doc.events[2].pitches = [EditorPitch(67)]
        XCTAssertThrowsError(try plan(LibraryPiece(source: .score(doc))))
    }
    func testPartnerContainsOnlyOtherStaffAndPreservesRestsTempoAndDurations() throws {
        var doc = try document()
        doc.events.removeAll { $0.bar == 0 && $0.staff == 2 }
        doc.events.append(.init(bar: 0, staff: 2, rhythm: .init(960)))
        doc.events.append(.init(bar: 0, staff: 2, rhythm: .init(960), pitches: [EditorPitch(48)]))
        let piece = LibraryPiece(source: .score(try doc.validated()))
        let both = try plan(piece)
        let solo = try PianoHands.solo(both, exercise: .rightHand)
        let partner = try PianoHands.accompaniment(piece, solo: solo, partnerStaff: 2)
        XCTAssertEqual(partner.notes.map(\.midi), [48, 49, 50, 51])
        XCTAssertEqual(partner.notes.first?.start, 2)
        XCTAssertEqual(partner.notes.first?.duration, 2)
        XCTAssertEqual(partner.tempo, 80)
        XCTAssertThrowsError(try PianoHands.accompaniment(piece, solo: solo, partnerStaff: 1))
        XCTAssertThrowsError(try PianoHands.accompaniment(piece, solo: solo, partnerStaff: 3))
        XCTAssertThrowsError(try PianoHands.accompaniment(piece, solo: both, partnerStaff: 2))
    }
    func testTiesInEitherHandCannotBeClippedByACombinedSelection() throws {
        var doc = try document()
        doc.events[5].pitches = doc.events[2].pitches.map { EditorPitch($0.midi) }
        doc.events[2].tieNext = true
        let piece = LibraryPiece(source: .score(try doc.validated()))
        let p = try plan(piece)
        XCTAssertEqual(p.targets.filter { $0.staves == [2] }.count, 3)
        XCTAssertThrowsError(
            try RehearsalSource.plan(piece, scope: .init(partID: "P1", staff: nil, from: 1, through: 3), tempo: 80))
        let focus = try RehearsalSource.focus(piece, opening: pass(p))
        XCTAssertEqual(focus.source?.scope.from, 0)
        XCTAssertEqual(focus.source?.scope.through, 1)
    }
    func testMissingStaffEmptyHandUnsupportedPartAndMalformedOwnershipRejected() throws {
        var doc = try document()
        for event in doc.events.filter({ $0.staff == 2 }) {
            if let i = doc.events.firstIndex(where: { $0.id == event.id }) { doc.events[i].pitches = [] }
        }
        XCTAssertThrowsError(try plan(LibraryPiece(source: .score(doc))))
        XCTAssertThrowsError(try PianoHands.solo(plan(), exercise: .rhythm))
        var p = try plan()
        p.handStaves = [2, 1]
        XCTAssertFalse(p.valid)
        p = try plan()
        p.targets[0].staves = [3]
        XCTAssertFalse(p.valid)
        p = try plan()
        p.targets[0].staves = [1, 1]
        XCTAssertFalse(p.valid)
        p = try plan()
        p.targets[0].staves = nil
        XCTAssertFalse(p.valid)
        p = try plan()
        p.source?.scope.staff = 1
        XCTAssertFalse(p.valid)
        p = try plan()
        p.handStaves = nil
        XCTAssertFalse(p.valid)
        var study = try RehearsalSource.whole(piece())
        study.document.parts[0].name = "Violin duo"
        XCTAssertThrowsError(try plan(LibraryPiece(source: .study(study))))
    }
    func testHandPracticeNeedsTogetherAttemptBeforeContextAndKeepsSupportDistinct() throws {
        var r = try focused()
        let focus = try XCTUnwrap(r.focus)
        let right = try PieceRehearsal.exercisePlan(focus, exercise: .rightHand, tempo: 60)
        let withPartner = pass(right, click: true, partner: 2, at: date.addingTimeInterval(2))
        XCTAssertEqual(withPartner.grade, .supported)
        try r.recordFocus(withPartner, exercise: .rightHand, now: date.addingTimeInterval(2))
        XCTAssertThrowsError(try r.returnToPhrase())
        XCTAssertTrue(r.valid)
        let left = try PieceRehearsal.exercisePlan(focus, exercise: .leftHand, tempo: 60)
        try r.recordFocus(
            pass(left, click: true, at: date.addingTimeInterval(3)), exercise: .leftHand,
            now: date.addingTimeInterval(3))
        XCTAssertNil(r.focusResults.last?.pass.conditions.partnerStaff)
        try r.recordFocus(
            pass(focus, click: true, at: date.addingTimeInterval(4)), exercise: .notes, now: date.addingTimeInterval(4))
        try r.returnToPhrase()
        XCTAssertEqual(r.stage, .context)
        XCTAssertTrue(r.valid)
        XCTAssertEqual(r.activePlan.handStaves, [1, 2])
        XCTAssertEqual(r.activePlan.source?.scope, r.opening.source?.scope)
    }
    func testWrongPartnerStaffAndInjectedSupportCannotBeSavedAsIndependent() throws {
        var r = try focused()
        let focus = try XCTUnwrap(r.focus)
        let right = try PianoHands.solo(focus, exercise: .rightHand)
        XCTAssertThrowsError(
            try r.recordFocus(
                pass(right, click: true, partner: 3), exercise: .rightHand, now: date.addingTimeInterval(2)))
        XCTAssertThrowsError(
            try r.recordFocus(
                pass(right, click: true, partner: 1), exercise: .rightHand, now: date.addingTimeInterval(2)))
        XCTAssertThrowsError(
            try r.recordFocus(pass(focus, click: true, partner: 2), exercise: .notes, now: date.addingTimeInterval(2)))
        try r.recordFocus(
            pass(focus, click: true, at: date.addingTimeInterval(2)), exercise: .notes, now: date.addingTimeInterval(2))
        try r.returnToPhrase()
        XCTAssertThrowsError(try r.recordContext(pass(r.activePlan, partner: 2), now: date.addingTimeInterval(3)))
        try r.recordContext(pass(r.activePlan, at: date.addingTimeInterval(3)), now: date.addingTimeInterval(3))
        let due = try XCTUnwrap(r.nextReview)
        try r.beginReview(now: due)
        try r.startReviewPass(now: due)
        try r.recordReview(pass(r.activePlan, at: due), now: due)
        XCTAssertTrue(r.reviews.last!.independent)
        XCTAssertEqual(r.review.intervalDays, 1)
        XCTAssertTrue(r.valid)
    }
    func testPartnerConditionChangesIdentityAndLegacyDataMigratesWithoutIt() throws {
        let p = try PianoHands.solo(plan(), exercise: .rightHand)
        XCTAssertNotEqual(p.identity(.init()), p.identity(.init(partnerStaff: 2)))
        XCTAssertTrue(pass(try plan()).evidence.contains("both notation staves"))
        var legacy = p
        legacy.source?.scope.staff = nil
        XCTAssertTrue(pass(legacy).evidence.contains("selected notation staff"))
        let plain = pass(p)
        let data = try JSONEncoder().encode(plain)
        let decoded = try JSONDecoder().decode(TimedPracticeResult.self, from: data)
        XCTAssertNil(decoded.conditions.partnerStaff)
        XCTAssertEqual(decoded, plain)
        var state = PracticeState()
        state.schemaVersion = 10
        XCTAssertEqual(try state.validated().schemaVersion, 17)
        state.schemaVersion = 18
        XCTAssertThrowsError(try state.validated())
        XCTAssertFalse(TimedConditions(partnerStaff: 17).valid)
    }
    func testTwoStaffRecordingAndPartnerConditionSurviveRoundTrip() throws {
        let piece = try piece()
        let p = try plan(piece)
        let r = try PieceRehearsal(opening: p, now: date)
        let phrase = try PianoPhrase(piece: piece, plan: p)
        let take = PianoTake(
            rehearsalKey: r.key, phase: .opening, intention: nil, phrase: phrase, pass: pass(p),
            recording: .init(events: [], end: p.duration + 0.4))
        XCTAssertTrue(take.valid)
        XCTAssertEqual(try JSONDecoder().decode(PianoTake.self, from: JSONEncoder().encode(take)), take)
        let solo = try PianoHands.solo(p, exercise: .rightHand)
        let material = try PianoPhrase(piece: piece, plan: solo)
        var supported = PianoTake(
            rehearsalKey: r.key, phase: .focus, intention: nil, phrase: material,
            pass: pass(solo, click: true, partner: 2), recording: .init(events: [], end: solo.duration + 0.4))
        let comparison = supported
        supported.pass.conditions.partnerStaff = nil
        XCTAssertFalse(supported.comparable(to: comparison))
        XCTAssertTrue(comparison.valid)
    }
    func testPartnerDoesNotSupplyMissingLearnerNotesAndBothHandsMatchIndependentEntrances() throws {
        let p = try plan()
        let right = try PianoHands.solo(p, exercise: .rightHand)
        var soloPass = pass(right, partner: 2)
        soloPass.attacks = []
        XCTAssertEqual(soloPass.report.missed, right.targets.count)
        var bothPass = pass(p)
        bothPass.attacks = bothPass.attacks.filter { $0.pitch >= 60 }
        XCTAssertEqual(bothPass.report.missed, 4)
        XCTAssertEqual(bothPass.report.matchedPitch, 8)
        XCTAssertEqual(bothPass.report.extras.count, 0)
    }
}
