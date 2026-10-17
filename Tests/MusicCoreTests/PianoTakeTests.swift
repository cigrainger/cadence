// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class PianoTakeTests: XCTestCase {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    func piece() throws -> LibraryPiece {
        var doc = try EditorDocument.blank(instrument: .piano, bars: 2)
        doc.title = "A connected line"
        doc.events.removeAll { $0.staff == 1 }
        for (i, pitch) in [60, 62, 64, 65, 67, 65, 64, 60].enumerated() {
            doc.events.append(EditorEvent(bar: i / 4, rhythm: .init(480), pitches: [EditorPitch(pitch)]))
        }
        return LibraryPiece(source: .score(try doc.validated()))
    }
    func phrase(_ piece: LibraryPiece? = nil, tempo: Int = 80) throws -> PianoPhrase {
        let piece = try piece ?? self.piece()
        return try PianoPhrase(
            piece: piece,
            plan: RehearsalSource.plan(piece, scope: .init(partID: "P1", staff: 1, from: 0, through: 1), tempo: tempo))
    }
    func event(_ message: MIDIMessage, _ time: Double, fallback: Bool = false) -> PianoEvent {
        PianoEvent(message, seconds: time, arrivalTimestamp: fallback)!
    }
    func take(gap: Double = 0.08, pedal: Bool = false) throws -> PianoTake {
        let phrase = try phrase()
        let plan = phrase.plan
        var events: [PianoEvent] = []
        if pedal { events.append(event(.control(channel: 0, number: 64, value: 127), -0.1)) }
        for n in phrase.notes {
            events.append(event(.noteOn(channel: 0, note: n.pitch, velocity: 85), n.beat * plan.secondsPerBeat))
            events.append(event(.noteOff(channel: 0, note: n.pitch), (n.beat + n.duration) * plan.secondsPerBeat - gap))
        }
        if pedal { events.append(event(.control(channel: 0, number: 64, value: 0), plan.duration)) }
        let pass = TimedPracticeResult(
            date: date, plan: plan, conditions: .init(),
            attacks: plan.targets.map { .init(seconds: $0.beat * plan.secondsPerBeat, pitch: $0.pitch) })
        let record = try PieceRehearsal(opening: plan, now: date)
        return PianoTake(
            rehearsalKey: record.key, phase: .focus, intention: .connectedMelody, phrase: phrase, pass: pass,
            recording: .init(events: events, end: plan.duration + 0.4))
    }
    func testSavedTakeRoundTripKeepsTimingVelocityReleasePedalAndIntention() throws {
        var take = try take(pedal: true)
        take.listenedAt = date
        take.reflection = .uneven
        take.note = "Let the line arrive."
        XCTAssertTrue(take.valid)
        let restored = try JSONDecoder().decode(PianoTake.self, from: JSONEncoder().encode(take))
        XCTAssertEqual(restored, take)
        XCTAssertEqual(restored.recording.notes.count, 8)
        XCTAssertEqual(restored.recording.notes[0].velocity, 85)
        XCTAssertEqual(restored.recording.notes[0].release!, 0.67, accuracy: 0.0001)
        XCTAssertGreaterThan(restored.recording.notes[0].soundEnd, 0.75)
    }
    func testGapsOverlapsAndPedalBridgesAreDistinctAndNeverGrades() throws {
        let gap = try take()
        let connected = try take(gap: -0.03)
        let pedalled = try take(pedal: true)
        XCTAssertEqual(gap.joins.count, 7)
        XCTAssertTrue(gap.joins.allSatisfy { abs($0.gap - 0.08) < 0.00001 && !$0.pedalBridged })
        XCTAssertTrue(connected.joins.allSatisfy { abs($0.gap + 0.03) < 0.00001 && !$0.pedalBridged })
        XCTAssertTrue(pedalled.joins.allSatisfy(\.pedalBridged))
        XCTAssertEqual(gap.pass.report, connected.pass.report)
    }
    func testRestsRepeatedNotesStaccatoAndPolyphonyAreExcluded() throws {
        var phrase = try phrase()
        XCTAssertEqual(phrase.joins.count, 7)
        phrase.notes[0].duration = 0.5
        XCTAssertFalse(phrase.joins.contains(0))
        phrase.notes[2].detached = true
        XCTAssertFalse(phrase.joins.contains(2))
        phrase.notes[4].pitch = phrase.notes[5].pitch
        phrase.plan.targets[4].pitch = phrase.notes[4].pitch
        XCTAssertFalse(phrase.joins.contains(4))
        XCTAssertTrue(phrase.valid)
        phrase.singleVoice = false
        XCTAssertTrue(phrase.joins.isEmpty)
        phrase.singleVoice = true
        phrase.notes[0].duration = 1.2
        XCTAssertTrue(phrase.joins.isEmpty)
    }
    func testMissingWrongAndInterveningNotesDoNotInventJoinEvidence() throws {
        var take = try take()
        take.pass.attacks.remove(at: 1)
        XCTAssertFalse(take.joins.contains { $0.id == 0 || $0.id == 1 })
        take = try self.take()
        take.pass.attacks[1].pitch = 63
        XCTAssertFalse(take.joins.contains { $0.id == 0 || $0.id == 1 })
        take = try self.take()
        take.recording = .init(
            events: take.recording.events + [event(.noteOn(channel: 1, note: 90, velocity: 75), 0.3)],
            end: take.recording.end)
        XCTAssertFalse(take.joins.contains { $0.id == 0 })
        XCTAssertEqual(take.joins.count, 6)
    }
    func testMissingReleasesAndFallbackTimestampsWithholdMeasurements() throws {
        var take = try take()
        take.recording.events.removeAll { $0.kind == .release && $0.note == 60 }
        XCTAssertTrue(take.recording.notes[0].clipped)
        XCTAssertNil(take.recording.notes[0].release)
        XCTAssertFalse(take.joins.contains { $0.id == 0 })
        take = try self.take()
        take.recording.events[1].arrivalTimestamp = true
        XCTAssertTrue(take.valid)
        XCTAssertTrue(take.joins.isEmpty)
    }
    func testChannelsPedalUpAndControllerResetKeepReleaseSeparate() throws {
        let events = [
            event(.control(channel: 1, number: 64, value: 127), 0),
            event(.noteOn(channel: 0, note: 60, velocity: 70), 0),
            event(.noteOn(channel: 1, note: 60, velocity: 100), 0.1), event(.noteOff(channel: 0, note: 60), 0.3),
            event(.noteOff(channel: 1, note: 60), 0.4), event(.control(channel: 1, number: 121, value: 0), 1),
        ]
        let r = PianoRecording(events: events, end: 2)
        let notes = r.notes
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0].soundEnd, 0.3)
        XCTAssertEqual(notes[1].release, 0.4)
        XCTAssertEqual(notes[1].soundEnd, 1)
        XCTAssertTrue(notes.allSatisfy { !$0.clipped })
    }
    func testRepressAndEqualTimestampOrderingRemainFaithful() throws {
        let e = [
            event(.noteOn(channel: 0, note: 60, velocity: 80), 0), event(.noteOff(channel: 0, note: 60), 1),
            event(.noteOn(channel: 0, note: 60, velocity: 90), 1), event(.noteOff(channel: 0, note: 60), 2),
        ]
        let r = PianoRecording(events: e, end: 3)
        XCTAssertEqual(r.events, e)
        XCTAssertEqual(r.notes.map(\.release), [1, 2])
        XCTAssertEqual(r.notes.map(\.velocity), [80, 90])
        let duplicate = PianoRecording(events: [e[0], e[2], e[3]], end: 3)
        XCTAssertNil(duplicate.notes[0].release)
        XCTAssertTrue(duplicate.notes[0].clipped)
        XCTAssertEqual(duplicate.notes[0].soundEnd, 1)
    }
    func testPedalBeforePassAndHeldAtBoundaryArePreserved() throws {
        let r = PianoRecording(
            events: [
                event(.control(channel: 0, number: 64, value: 127), -2),
                event(.noteOn(channel: 0, note: 60, velocity: 80), -0.1), event(.noteOff(channel: 0, note: 60), 0.3),
            ], end: 2)
        XCTAssertEqual(r.start, -0.1)
        XCTAssertEqual(r.duration, 2.1)
        XCTAssertEqual(r.notes[0].release, 0.3)
        XCTAssertEqual(r.notes[0].soundEnd, 2)
        XCTAssertTrue(r.notes[0].clipped)
        XCTAssertEqual(PianoRecording(events: [], end: 2).start, 0)
    }
    func testMalformedEventsDurationsAndOversizedRecordingsAreRejected() throws {
        for message in [
            MIDIMessage.noteOn(channel: 16, note: 60, velocity: 90), .noteOn(channel: 0, note: 128, velocity: 90),
            .noteOn(channel: 0, note: 60, velocity: 128), .control(channel: 0, number: 7, value: 127), .reset,
        ] { XCTAssertNil(PianoEvent(message, seconds: 0)) }
        XCTAssertNil(PianoEvent(.noteOff(channel: 0, note: 60), seconds: .nan))
        XCTAssertEqual(PianoEvent(.noteOn(channel: 0, note: 60, velocity: 0), seconds: 0)?.kind, .release)
        var r = try take().recording
        r.end = .infinity
        XCTAssertFalse(r.valid)
        XCTAssertTrue(r.notes.isEmpty)
        r = try take().recording
        r.events.reverse()
        XCTAssertFalse(r.valid)
        r = .init(events: [event(.noteOn(channel: 0, note: 60, velocity: 80), 2)], end: 1)
        XCTAssertFalse(r.valid)
        r = .init(events: Array(repeating: event(.noteOff(channel: 0, note: 60), 0), count: 8193), end: 1)
        XCTAssertFalse(r.valid)
    }
    func testCursorUsesPerformedEntrancesAndNonzeroSourceOrigin() throws {
        var take = try take()
        take.pass.plan.source?.startBeat = 16
        take.phrase.plan = take.pass.plan
        XCTAssertEqual(take.sourceBeat(at: 0), 16)
        XCTAssertEqual(take.sourceBeat(at: 0.75), 17)
        XCTAssertEqual(take.sourceBeat(at: 0.375)!, 16.5, accuracy: 0.0001)
        XCTAssertLessThan(take.sourceBeat(at: 100)!, 24)
        XCTAssertNil(take.sourceBeat(at: .nan))
        // A late entrance shifts the corresponding cursor anchor as well.
        take.pass.attacks[1].seconds += 0.15
        let i = take.recording.events.firstIndex { $0.kind == .press && $0.note == 62 }!
        take.recording.events[i].seconds += 0.15
        XCTAssertEqual(take.sourceBeat(at: 0.9), 17)
    }
    func testUnmatchedAndAmbiguousPerformancesDoNotInventCursorAnchors() throws {
        var take = try take()
        take.pass.attacks = []
        XCTAssertNil(take.sourceBeat(at: 1))
        XCTAssertTrue(take.matchedNotes.isEmpty)
        take = try self.take()
        let additional = take.recording.events.filter { $0.kind == .press }.map { e in
            var e = e
            e.channel = 2
            return e
        }
        take.recording = .init(events: take.recording.events + additional, end: take.recording.end)
        XCTAssertTrue(take.matchedNotes.isEmpty)
        XCTAssertNil(take.sourceBeat(at: 2))
    }
    func testComparisonsRequireSameRevisionBarsAndStaffButAllowDifferentTempo() throws {
        let a = try take()
        var b = a
        b.pass.plan.tempo = 65
        b.phrase.plan.tempo = 65
        XCTAssertTrue(a.comparable(to: b))
        b.phrase.plan.source?.scope.staff = 2
        XCTAssertFalse(a.comparable(to: b))
        b = a
        b.phrase.plan.source?.fingerprint = ScoreRevision.digest("changed")
        XCTAssertFalse(a.comparable(to: b))
        b = a
        b.phrase.plan.source?.scope.from = 1
        XCTAssertFalse(a.comparable(to: b))
        b = a
        b.phrase.notes[0].duration = 0.5
        XCTAssertFalse(a.comparable(to: b))
    }
    func testTakeValidationProtectsReflectionSourceAndPlan() throws {
        var t = try take()
        t.reflection = .connected
        XCTAssertFalse(t.valid)
        t.listenedAt = date
        XCTAssertTrue(t.valid)
        t.listenedAt = date.addingTimeInterval(-1)
        XCTAssertFalse(t.valid)
        t = try take()
        t.note = String(repeating: "a", count: 1001)
        XCTAssertFalse(t.valid)
        t = try take()
        t.phase = .complete
        XCTAssertFalse(t.valid)
        t = try take()
        t.recording.end += 1
        XCTAssertFalse(t.valid)
        t = try take()
        t.phrase.notes.removeLast()
        XCTAssertFalse(t.valid)
        t = try take()
        t.phrase.notes[0].duration = .nan
        XCTAssertFalse(t.valid)
        t = try take()
        t.pass.plan.tempo = 100
        XCTAssertFalse(t.valid)
    }
    func testPianoPartRecognitionAndChangedSourcesFailClearly() throws {
        let piece = try piece()
        let p = try phrase(piece)
        var study = try RehearsalSource.whole(piece)
        study.document.parts[0].name = "Grand Piano"
        let imported = LibraryPiece(source: .study(study))
        XCTAssertNoThrow(try phrase(imported))
        study.document.parts[0].name = "Guitar"
        XCTAssertThrowsError(try phrase(LibraryPiece(source: .study(study))))
        if case .score(var doc) = piece.source {
            doc.events[0].pitches = [EditorPitch(80)]
            XCTAssertThrowsError(try PianoPhrase(piece: LibraryPiece(source: .score(doc)), plan: p.plan))
        }
        var plan = p.plan
        plan.source = nil
        XCTAssertThrowsError(try PianoPhrase(piece: piece, plan: plan))
    }
    func testBookIsIdempotentBoundedAndRejectsInvalidSavedData() throws {
        let take = try take()
        var book = PianoTakeBook()
        try book.append(take)
        try book.append(take)
        XCTAssertEqual(book.takes.count, 1)
        for _ in 1..<PianoTakeBook.limit {
            var t = take
            t.pass.id = UUID()
            try book.append(t)
        }
        var t = take
        t.pass.id = UUID()
        XCTAssertThrowsError(try book.append(t))
        XCTAssertEqual(book.takes.count, 256)
        XCTAssertNoThrow(try book.validated())
        book.takes.append(take)
        XCTAssertThrowsError(try book.validated())
        book = PianoTakeBook()
        t.note = String(repeating: "a", count: 1001)
        XCTAssertThrowsError(try book.append(t))
    }
    func testLegacyPracticeAndRehearsalDecodeWithoutTakesOrIntention() throws {
        var state = PracticeState()
        state.schemaVersion = 9
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        object.removeValue(forKey: "pianoTakes")
        let migrated = try JSONDecoder().decode(
            PracticeState.self, from: JSONSerialization.data(withJSONObject: object)
        ).validated()
        XCTAssertEqual(migrated.schemaVersion, 16)
        XCTAssertNil(migrated.pianoTakes)
        let rehearsal = try PieceRehearsal(opening: phrase().plan)
        let restored = try JSONDecoder().decode(PieceRehearsal.self, from: JSONEncoder().encode(rehearsal))
        XCTAssertNil(restored.phraseIntention)
        XCTAssertTrue(restored.valid)
        var book = PianoTakeBook()
        try book.append(take())
        state.pianoTakes = book
        XCTAssertEqual(
            try JSONDecoder().decode(PracticeState.self, from: JSONEncoder().encode(state)).validated().pianoTakes, book
        )
        state.schemaVersion = 17
        XCTAssertThrowsError(try state.validated())
    }
    func testRecordingEventBudgetAndIdentityCollisionCannotOverwriteExistingTakes() throws {
        let take = try take()
        var book = PianoTakeBook()
        try book.append(take)
        var changed = take
        changed.note = "A different object with the same identity"
        XCTAssertThrowsError(try book.append(changed))
        XCTAssertEqual(book.takes, [take])
        var large = take
        large.recording.events += Array(
            repeating: event(.control(channel: 0, number: 64, value: 0), large.recording.end),
            count: 8192 - large.recording.events.count)
        book = PianoTakeBook()
        for _ in 0..<30 {
            large.pass.id = UUID()
            try book.append(large)
        }
        large.pass.id = UUID()
        XCTAssertThrowsError(try book.append(large))
        XCTAssertEqual(book.takes.count, 30)
        XCTAssertNoThrow(try book.validated())
        book.takes.append(large)
        XCTAssertThrowsError(try book.validated())
    }
    func testConnectedFocusCarriesIntentionThroughContextAndReviewWithoutExpressionGrade() throws {
        var record = try PieceRehearsalTests().focused()
        record.phraseIntention = .connectedMelody
        let result = PieceRehearsalTests().pass(
            record.activePlan, at: PieceRehearsalTests().date.addingTimeInterval(2), click: true)
        try record.recordFocus(result, exercise: .connected, now: result.date)
        try record.returnToPhrase()
        XCTAssertTrue(record.valid)
        XCTAssertEqual(record.phraseIntention, .connectedMelody)
        let context = PieceRehearsalTests().pass(record.activePlan, at: result.date.addingTimeInterval(1))
        try record.recordContext(context, now: context.date)
        XCTAssertEqual(record.review.intervalDays, 0)
        XCTAssertEqual(record.phraseIntention, .connectedMelody)
        try record.beginReview(now: record.nextReview!)
        XCTAssertTrue(record.valid)
    }
}
