// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class EarPathwayTests: XCTestCase {
    func round(_ s: inout EarSession, singing: [Int]? = nil, midi: [Int]? = nil, hint: Bool = false, skip: Bool = false)
        throws
    {
        let target = try s.projection().phrase.notes
        try s.append(.init(.heard))
        try s.append(.init(.imagined))
        if hint { try s.append(.init(.hint)) }
        try s.append(.init(.answer, notes: skip ? [] : singing ?? target, skipped: skip))
        try s.append(.init(.next))
        try s.append(.init(.answer, notes: skip ? [] : midi ?? target, skipped: skip))
        try s.append(.init(.next))
        try s.append(.init(.next))
    }
    func testOriginalPhraseKeysSolfegeAndOctaves() throws {
        for tonic in [48, 50, 53, 55, 60, 62, 65, 67] {
            for recipe in 0..<6 {
                let p = EarPhrase(recipe: recipe, tonic: tonic)
                XCTAssertTrue(p.valid)
                XCTAssertEqual(p.notes.count, p.solfege.count)
                XCTAssertNoThrow(try p.score.validated())
                XCTAssertTrue(p.matches(p.notes.map { $0 - 12 }, input: .singing))
                XCTAssertFalse(p.matches(p.notes.map { $0 + 12 }, input: .midi))
                XCTAssertFalse(p.matches(p.notes.map { $0 + 1 }, input: .singing))
                XCTAssertFalse(p.matches(p.notes + [tonic], input: .midi))
                XCTAssertFalse(p.matches([], input: .singing))
            }
        }
        XCTAssertEqual(EarPhrase().solfege, ["Do", "Re", "Do"])
        XCTAssertFalse(EarPhrase(recipe: -1).valid)
        XCTAssertTrue(EarPhrase(recipe: 100).notes.isEmpty)
    }
    func testCleanOpeningExtendsThenTransfersWithFreshSupport() throws {
        var s = EarSession()
        try round(&s)
        XCTAssertEqual(try s.projection().phrase.recipe, 1)
        XCTAssertFalse(try s.projection().focused)
        try round(&s, hint: true)
        let transfer = try s.projection()
        XCTAssertEqual(transfer.phrase.tonic, 62)
        XCTAssertFalse(transfer.hinted)
        XCTAssertFalse(transfer.assisted)
        try round(&s)
        XCTAssertEqual(try s.projection().stage, .complete)
        XCTAssertEqual(try s.projection().results.count, 6)
        XCTAssertThrowsError(try s.append(.init(.heard)))
    }
    func testFocusedReturnRetainsModalityAndDoesNotExtendReviewTwice() throws {
        var s = EarSession()
        try round(&s, singing: [60, 61, 60])
        try round(&s)
        let results = try s.projection().results
        XCTAssertEqual(results[0].outcome, .incorrect)
        XCTAssertEqual(results[1].outcome, .correct)
        XCTAssertTrue(results[2].assisted)
        XCTAssertTrue(results[3].assisted)
        var history = PracticeProgress()
        for result in results { history.record(result, sessionID: s.id) }
        XCTAssertEqual(history.cards[s.opening.activity(.singing)]?.review.lastGrade, .again)
        XCTAssertEqual(history.cards[s.opening.activity(.midi)]?.review.intervalDays, 1)
        XCTAssertEqual(history.attempts, 4)
    }
    func testSkippingProducesNoGradeOrSchedule() throws {
        var s = EarSession()
        try round(&s, skip: true)
        var history = PracticeProgress()
        for r in try s.projection().results {
            history.record(r, sessionID: s.id)
            XCTAssertTrue(r.attempt(sessionID: s.id).valid)
        }
        XCTAssertTrue(history.cards.isEmpty)
        XCTAssertEqual(history.attempts, 0)
        XCTAssertTrue(try s.projection().focused)
    }
    func testStageOrderEmptyExtraNotesAndDuplicateEvents() throws {
        var s = EarSession()
        XCTAssertThrowsError(try s.append(.init(.imagined)))
        XCTAssertThrowsError(try s.append(.init(.answer, notes: [60])))
        let heard = EarEvent(.heard)
        try s.append(heard)
        try s.append(heard)
        XCTAssertEqual(s.events.count, 1)
        try s.append(.init(.imagined))
        XCTAssertThrowsError(try s.append(.init(.answer)))
        XCTAssertThrowsError(try s.append(.init(.answer, notes: [128])))
        XCTAssertThrowsError(try s.append(.init(.hint, notes: [60])))
        try s.append(.init(.answer, notes: [60, 62, 60, 62]))
        XCTAssertFalse(try s.projection().results[0].correct)
        XCTAssertThrowsError(try s.append(.init(.answer, notes: [60])))
        XCTAssertThrowsError(try s.append(.init(.next, date: Date(timeIntervalSince1970: .nan))))
        XCTAssertNoThrow(
            try s.append(.init(.next, date: .distantPast)), "Event order remains valid when the wall clock moves back")
    }
    func testHintAndReplayAreStickyWithinRound() throws {
        for event in [EarEvent.Kind.hint, .replay] {
            var s = EarSession()
            try s.append(.init(.heard))
            try s.append(.init(.imagined))
            try s.append(.init(event))
            try s.append(.init(.answer, notes: s.opening.notes))
            try s.append(.init(.next))
            try s.append(.init(.answer, notes: s.opening.notes))
            XCTAssertTrue(try s.projection().results.allSatisfy(\.assisted))
        }
    }
    func testDueReviewKeepsExactKeyAndModeIdentity() throws {
        var history = PracticeProgress()
        var s = EarSession(phrase: .init(recipe: 4, tonic: 53))
        try round(&s, singing: [53, 53, 54, 53])
        let result = try s.projection().results[0]
        history.record(result, sessionID: s.id)
        XCTAssertEqual(EarPhrase.suggested(history: history, now: result.event.date.addingTimeInterval(601)), s.opening)
        XCTAssertNotEqual(s.opening.activity(.singing), s.opening.activity(.midi))
    }
    func testRoundtripAndUnfinishedArchiveRejected() throws {
        var s = EarSession()
        try round(&s)
        try round(&s)
        try round(&s)
        var book = EarPractice()
        book.completed = [s]
        XCTAssertNoThrow(try book.validated())
        let data = try JSONEncoder().encode(PracticeState(ear: book))
        XCTAssertEqual(try JSONDecoder().decode(PracticeState.self, from: data).validated().ear, book)
        book.active = s
        XCTAssertThrowsError(try book.validated())
        book.active = nil
        book.completed = [EarSession()]
        XCTAssertThrowsError(try book.validated())
        var old = PracticeState()
        old.schemaVersion = 5
        XCTAssertEqual(try old.validated().schemaVersion, 15)
    }
    func testSingingStabilityBreathsAndPitchChanges() {
        var c = SungPhraseCapture()
        c.receive(midi: 60, at: 0)
        c.receive(midi: 60, at: 0.36)
        c.receive(midi: 60, at: 1)
        XCTAssertEqual(c.notes, [60])
        c.receive(midi: 60, cents: 45, at: 1.1)
        c.receive(midi: 60, at: 1.2)
        c.receive(midi: 60, at: 1.6)
        XCTAssertEqual(c.notes, [60])
        c.receive(midi: nil, at: 1.7)
        c.receive(midi: nil, at: 1.91)
        c.receive(midi: 60, at: 2)
        c.receive(midi: 60, at: 2.36)
        c.receive(midi: 62, at: 2.4)
        c.receive(midi: 62, at: 2.76)
        XCTAssertEqual(c.notes, [60, 60, 62])
        c.receive(midi: 64, at: 1)
        c.receive(midi: 64, at: .nan)
        XCTAssertEqual(c.notes, [60, 60, 62])
    }
    func testNoisyFramesNeverBecomeValidSinging() {
        var c = SungPhraseCapture()
        for i in 0..<100 { c.receive(midi: i % 2 == 0 ? 60 : 62, at: Double(i) * 0.1) }
        XCTAssertTrue(c.notes.isEmpty)
        c.receive(midi: 60, confidence: 0.5, at: 11)
        c.receive(midi: 60, confidence: 0.5, at: 12)
        c.receive(midi: 999, at: 13)
        c.receive(midi: 999, at: 14)
        XCTAssertTrue(c.notes.isEmpty)
    }
}
