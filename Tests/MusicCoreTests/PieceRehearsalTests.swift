// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class PieceRehearsalTests: XCTestCase {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    func piece() throws -> LibraryPiece { LibraryPiece(source: .score(try ScoreEarTests().document())) }
    func plan(_ piece: LibraryPiece? = nil, from: Int = 0, through: Int = 3, staff: Int? = 1, tempo: Int = 80) throws
        -> TimedPracticePlan
    {
        try RehearsalSource.plan(
            try piece ?? self.piece(), scope: .init(partID: "P1", staff: staff, from: from, through: through),
            tempo: tempo)
    }
    func pass(
        _ plan: TimedPracticePlan, at: Date? = nil, click: Bool = false, input: TimedInput = .midi, bad: Int? = nil,
        fallback: Bool = false
    ) -> TimedPracticeResult {
        .init(
            date: at ?? date.addingTimeInterval(1), plan: plan, conditions: .init(input: input, click: click),
            attacks: plan.targets.enumerated().map { i, t in
                .init(
                    seconds: t.beat * plan.secondsPerBeat, pitch: t.pitch + (i == bad ? 1 : 0),
                    arrivalTimestamp: fallback)
            })
    }
    func focused() throws -> PieceRehearsal {
        let piece = try piece()
        let p = try plan(piece)
        let opening = pass(p, bad: 4)
        var r = try PieceRehearsal(opening: p, now: date)
        try r.recordOpening(
            opening, focus: RehearsalSource.focus(piece, opening: opening),
            context: RehearsalSource.context(piece, opening: p), now: date.addingTimeInterval(2))
        return r
    }
    func completed() throws -> PieceRehearsal {
        var r = try focused()
        let f = try XCTUnwrap(r.focus)
        let c = try XCTUnwrap(r.context)
        try r.recordFocus(
            pass(f, at: date.addingTimeInterval(2), click: true), exercise: .notes, now: date.addingTimeInterval(2))
        try r.returnToPhrase()
        try r.recordContext(pass(c, at: date.addingTimeInterval(3)), now: date.addingTimeInterval(3))
        return r
    }
    func testWholePieceAndStableCanonicalIdentity() throws {
        let piece = try piece()
        let a = try plan(piece)
        let b = try plan(piece)
        XCTAssertEqual(a, b)
        XCTAssertEqual(try RehearsalSource.whole(piece).selectedMeasures.count, 4)
        XCTAssertEqual(a.source?.studyID, UUID(uuidString: piece.id.replacingOccurrences(of: "score:", with: "")))
        XCTAssertTrue(RehearsalSource.current(a, in: piece))
        XCTAssertThrowsError(try RehearsalSource.whole(piece, partID: "missing"))
        let whole = try RehearsalSource.whole(piece)
        let imported = LibraryPiece(source: .study(whole))
        XCTAssertEqual(try RehearsalSource.whole(imported).id, whole.id)
    }
    func testRangeStaffTempoAndEmptySelectionRejected() throws {
        XCTAssertThrowsError(try plan(from: -1))
        XCTAssertThrowsError(try plan(through: 4))
        XCTAssertThrowsError(try plan(staff: nil))
        XCTAssertThrowsError(try plan(staff: 3))
        XCTAssertThrowsError(try plan(tempo: 10))
        XCTAssertThrowsError(try plan(staff: 2))
        var doc = try EditorDocument.blank(instrument: .guitar)
        doc.events[0].pitches = [EditorPitch(64, string: 1, fret: 0)]
        XCTAssertThrowsError(try plan(LibraryPiece(source: .score(doc)), staff: 2))
    }
    func testWorstBarUsesRateThenWrittenOrderAndPreservesOrigin() throws {
        let piece = try piece()
        let p = try plan(piece)
        let r = pass(p, bad: 4)
        let f = try RehearsalSource.focus(piece, opening: r)
        XCTAssertEqual(f.source?.scope.from, 2)
        XCTAssertEqual(f.source?.scope.through, 2)
        XCTAssertEqual(f.source?.startBeat, 8)
        XCTAssertEqual(f.targets.map(\.bar), [2, 2])
        XCTAssertEqual(f.targets.map(\.beat), [0, 2])
        XCTAssertEqual(try RehearsalSource.focus(piece, opening: pass(p)).source?.scope.from, 0)
    }
    func testContextRestoresOpeningAndExpandsSingleBar() throws {
        let piece = try piece()
        let p = try plan(piece)
        XCTAssertEqual(try RehearsalSource.context(piece, opening: p), p)
        let middle = try RehearsalSource.context(piece, opening: plan(piece, from: 2, through: 2))
        XCTAssertEqual(middle.source?.scope.from, 1)
        XCTAssertEqual(middle.source?.scope.through, 3)
        let first = try RehearsalSource.context(piece, opening: plan(piece, through: 0))
        XCTAssertEqual(first.source?.scope.from, 0)
        XCTAssertEqual(first.source?.scope.through, 1)
    }
    func testExtraPressesChooseTheBarWhereTheyOccurred() throws {
        let piece = try piece()
        let p = try plan(piece)
        var result = pass(p)
        result.attacks.append(.init(seconds: 12 * p.secondsPerBeat + 0.7, pitch: 90))
        XCTAssertEqual(result.report.extras.count, 1)
        XCTAssertEqual(try RehearsalSource.focus(piece, opening: result).source?.scope.from, 3)
    }
    func testOrphanTiesCannotBeAssessedAsOrdinaryNotes() throws {
        var study = try RehearsalSource.whole(piece())
        let index = try XCTUnwrap(study.document.parts[0].notes.firstIndex { $0.staff == 1 && $0.midi >= 0 })
        study.document.parts[0].notes[index].tieStart = true
        XCTAssertThrowsError(try plan(LibraryPiece(source: .study(study))))
        study.document.parts[0].notes[index].tieStart = false
        study.document.parts[0].notes[index].tieStop = true
        XCTAssertThrowsError(try plan(LibraryPiece(source: .study(study))))
    }
    func testTiesExpandFocusAndCannotBeClippedAtEdges() throws {
        var doc = try ScoreEarTests().document()
        doc.events[2].pitches = doc.events[1].pitches.map { EditorPitch($0.midi) }
        doc.events[1].tieNext = true
        let piece = LibraryPiece(source: .score(doc))
        let p = try plan(piece)
        XCTAssertEqual(p.targets.count, 7)
        XCTAssertFalse(p.targets.contains { $0.beat == 4 })
        XCTAssertThrowsError(try plan(piece, through: 0))
        XCTAssertThrowsError(try plan(piece, from: 1))
        let focus = try RehearsalSource.focus(piece, opening: pass(p, bad: 1))
        XCTAssertEqual(focus.source?.scope.from, 0)
        XCTAssertEqual(focus.source?.scope.through, 1)
    }
    func testChordRhythmUsesOneTapPerEntranceAndMapsBackToSource() throws {
        var doc = try ScoreEarTests().document()
        doc.events[4].pitches = [EditorPitch(60), EditorPitch(64), EditorPitch(67)]
        let p = try plan(LibraryPiece(source: .score(doc)), from: 2)
        let tapped = try PieceRehearsal.exercisePlan(p, exercise: .rhythm, tempo: 60)
        XCTAssertTrue(tapped.valid)
        XCTAssertTrue(tapped.rhythmOnly)
        XCTAssertNil(tapped.source)
        XCTAssertEqual(tapped.targets.count, 4)
        XCTAssertEqual(tapped.targets.map(\.bar), [0, 0, 1, 1])
        XCTAssertEqual(tapped.targets.map(\.beat), [0, 2, 4, 6])
        XCTAssertEqual(try PieceRehearsal.exercisePlan(p, exercise: .notes, tempo: 80), p)
        XCTAssertThrowsError(try PieceRehearsal.exercisePlan(p, exercise: .notes, tempo: 0))
        XCTAssertThrowsError(try PieceRehearsal.exercisePlan(tapped, exercise: .rhythm, tempo: 60))
    }
    func testHappyCyclePersistsSupportedPracticeAndTomorrowReturn() throws {
        let r = try completed()
        XCTAssertTrue(r.valid)
        XCTAssertEqual(r.stage, .complete)
        XCTAssertEqual(r.review.intervalDays, 0)
        XCTAssertEqual(r.review.lastGrade, .supported)
        XCTAssertEqual(r.nextReview, date.addingTimeInterval(86403))
        XCTAssertEqual(r.attempts.count, 3)
        let restored = try JSONDecoder().decode(PieceRehearsal.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(restored, r)
        XCTAssertEqual(restored.activePlan, restored.context)
        XCTAssertEqual(restored.reviewSchedule.due, r.nextReview)
    }
    func testCannotSkipStepsOrReplayTheOpeningResult() throws {
        let piece = try piece()
        let p = try plan(piece)
        var r = try PieceRehearsal(opening: p, now: date)
        XCTAssertTrue(r.valid)
        XCTAssertThrowsError(try r.returnToPhrase())
        XCTAssertThrowsError(try r.recordContext(pass(p)))
        XCTAssertThrowsError(try r.recordReview(pass(p)))
        XCTAssertThrowsError(try r.beginReview(now: date))
        XCTAssertThrowsError(try r.practiseAgain(now: date))
        XCTAssertThrowsError(try r.startReviewPass(now: date))
        let opening = pass(p)
        let f = try RehearsalSource.focus(piece, opening: opening)
        let c = try RehearsalSource.context(piece, opening: p)
        try r.recordOpening(opening, focus: f, context: c, now: date.addingTimeInterval(1))
        XCTAssertThrowsError(try r.recordOpening(opening, focus: f, context: c))
        XCTAssertThrowsError(try r.returnToPhrase())
        XCTAssertEqual(r.stage, .focus)
        XCTAssertTrue(r.valid)
    }
    func testWrongPlanInputClickAndFutureResultsRejected() throws {
        var r = try focused()
        let f = try XCTUnwrap(r.focus)
        let now = date.addingTimeInterval(4)
        XCTAssertThrowsError(try r.recordFocus(pass(f, at: now), exercise: .notes, now: now))
        XCTAssertThrowsError(
            try r.recordFocus(pass(f, at: now, click: true, input: .space), exercise: .notes, now: now))
        var fast = f
        fast.tempo += 10
        XCTAssertThrowsError(try r.recordFocus(pass(fast, at: now, click: true), exercise: .notes, now: now))
        XCTAssertThrowsError(
            try r.recordFocus(pass(f, at: now.addingTimeInterval(10), click: true), exercise: .notes, now: now))
        XCTAssertThrowsError(try r.recordFocus(pass(f, at: date, click: true), exercise: .notes, now: now))
        let good = pass(f, at: now, click: true)
        try r.recordFocus(good, exercise: .notes, now: now)
        XCTAssertThrowsError(try r.recordFocus(good, exercise: .notes, now: now))
        XCTAssertTrue(r.valid)
        try r.returnToPhrase()
        XCTAssertThrowsError(try r.recordContext(pass(f, at: now), now: now))
    }
    func testBoundedSupportedRhythmHistoryStillAllowsContext() throws {
        var r = try focused()
        let p = try PieceRehearsal.exercisePlan(XCTUnwrap(r.focus), exercise: .rhythm, tempo: 50)
        for i in 2...20 {
            let now = date.addingTimeInterval(Double(i))
            try r.recordFocus(pass(p, at: now, click: true, input: .space), exercise: .rhythm, now: now)
        }
        XCTAssertEqual(r.focusResults.count, 12)
        XCTAssertTrue(r.valid)
        try r.returnToPhrase()
        XCTAssertEqual(r.stage, .context)
    }
    func testOnlyDelayedFirstIndependentReviewAdvances() throws {
        var r = try completed()
        let due = try XCTUnwrap(r.nextReview)
        let c = try XCTUnwrap(r.context)
        XCTAssertThrowsError(try r.beginReview(now: due.addingTimeInterval(-1)))
        try r.beginReview(now: due)
        XCTAssertEqual(r.stage, .review)
        XCTAssertTrue(r.valid)
        XCTAssertThrowsError(try r.recordReview(pass(c, at: due), now: due))
        try r.startReviewPass(now: due)
        try r.recordReview(pass(c, at: due), now: due)
        XCTAssertTrue(r.valid)
        XCTAssertEqual(r.reviews.last?.independent, true)
        XCTAssertEqual(r.review.intervalDays, 1)
        let next = try XCTUnwrap(r.nextReview)
        try r.beginReview(now: next)
        try r.startReviewPass(now: next)
        try r.recordReview(pass(c, at: next), now: next)
        XCTAssertEqual(r.review.intervalDays, 3)
    }
    func testRestartAndFallbackNeverCountAsIndependent() throws {
        for fallback in [false, true] {
            var r = try completed()
            let due = try XCTUnwrap(r.nextReview)
            let c = try XCTUnwrap(r.context)
            try r.beginReview(now: due)
            try r.startReviewPass(now: due)
            r = try JSONDecoder().decode(PieceRehearsal.self, from: JSONEncoder().encode(r))
            if !fallback { try r.startReviewPass(now: due) }
            try r.recordReview(pass(c, at: due, fallback: fallback), now: due)
            XCTAssertEqual(r.reviews.last?.independent, false)
            XCTAssertEqual(r.review.intervalDays, 0)
            XCTAssertEqual(r.review.lastGrade, .supported)
            XCTAssertTrue(r.valid)
        }
    }
    func testAnIndependentMissSchedulesAnotherReturnWithoutMastery() throws {
        var r = try completed()
        let due = try XCTUnwrap(r.nextReview)
        let c = try XCTUnwrap(r.context)
        try r.beginReview(now: due)
        try r.startReviewPass(now: due)
        try r.recordReview(pass(c, at: due, bad: 2), now: due)
        XCTAssertEqual(r.reviews.last?.independent, true)
        XCTAssertEqual(r.review.lastGrade, .again)
        XCTAssertEqual(r.review.intervalDays, 0)
        XCTAssertEqual(r.nextReview, due.addingTimeInterval(86400))
    }
    func testListeningAndSupportedRestartResetIndependenceNotMastery() throws {
        var r = try completed()
        let due = try XCTUnwrap(r.nextReview)
        try r.expose(now: due.addingTimeInterval(-3600))
        XCTAssertEqual(r.nextReview, due.addingTimeInterval(19 * 3600))
        XCTAssertThrowsError(try r.beginReview(now: due))
        let later = try XCTUnwrap(r.nextReview)
        try r.beginReview(now: later)
        try r.expose(now: later)
        XCTAssertGreaterThanOrEqual(r.reviewStarts, 2)
        try r.practiseAgain(now: later)
        XCTAssertEqual(r.stage, .focus)
        XCTAssertTrue(r.focusResults.isEmpty)
        XCTAssertNil(r.contextResult)
        XCTAssertTrue(r.valid)
        XCTAssertThrowsError(try r.expose(now: date))
        XCTAssertEqual(r.review.intervalDays, 0)
    }
    func testForgedSourceOrScopeAndChangedMusicAreRejected() throws {
        let piece = try piece()
        let p = try plan(piece)
        var forged = p
        forged.targets[0].pitch += 1
        XCTAssertFalse(RehearsalSource.current(forged, in: piece))
        forged = p
        forged.source?.startBeat += 4
        XCTAssertFalse(RehearsalSource.current(forged, in: piece))
        forged = p
        forged.source?.fingerprint = String(repeating: "0", count: 64)
        XCTAssertFalse(RehearsalSource.current(forged, in: piece))
        var d = try ScoreEarTests().document()
        d.id = UUID(uuidString: piece.id.replacingOccurrences(of: "score:", with: ""))!
        d.events[0].pitches = [EditorPitch(80)]
        XCTAssertFalse(RehearsalSource.current(p, in: LibraryPiece(source: .score(d))))
        var r = try PieceRehearsal(opening: p, now: date)
        let opening = pass(p)
        XCTAssertThrowsError(try r.recordOpening(opening, focus: forged, context: p, now: date.addingTimeInterval(2)))
        XCTAssertThrowsError(try PieceRehearsal(opening: .calibration(), now: date))
    }
    func testBookKeysDuplicateIDsAndMalformedSessionRejected() throws {
        let r = try completed()
        var b = PieceRehearsalBook()
        b.records[r.key] = r
        XCTAssertNoThrow(try b.validated())
        b.records["forged"] = r
        XCTAssertThrowsError(try b.validated())
        b.records = [r.key: r]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as? [String: Any])
        for mutation in [
            ("stage", "opening" as Any), ("focus", NSNull() as Any), ("reviewStarts", -1 as Any),
            ("contextResult", NSNull() as Any),
        ] {
            var changed = json
            changed[mutation.0] = mutation.1
            let invalid = try JSONDecoder().decode(
                PieceRehearsal.self, from: JSONSerialization.data(withJSONObject: changed))
            XCTAssertFalse(invalid.valid)
        }
        json["createdAt"] = 1e20
        XCTAssertFalse(
            try JSONDecoder().decode(PieceRehearsal.self, from: JSONSerialization.data(withJSONObject: json)).valid)
    }
    func testPracticeMigrationPreservesOldStateAndRejectsFuture() throws {
        var old = PracticeState()
        old.schemaVersion = 8
        XCTAssertEqual(try old.validated().schemaVersion, 17)
        XCTAssertNil(try old.validated().rehearsal)
        var book = PieceRehearsalBook()
        let r = try completed()
        book.records[r.key] = r
        old.rehearsal = book
        let restored = try JSONDecoder().decode(PracticeState.self, from: JSONEncoder().encode(old)).validated()
        XCTAssertEqual(restored.rehearsal, book)
        old.schemaVersion = 18
        XCTAssertThrowsError(try old.validated())
        old.schemaVersion = 9
        old.rehearsal?.records["bad"] = r
        XCTAssertThrowsError(try old.validated())
    }
}
