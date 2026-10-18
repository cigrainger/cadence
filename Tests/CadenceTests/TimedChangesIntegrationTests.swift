// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

@testable import Cadence

final class TimedChangesIntegrationTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func plan() throws -> TimedChangesPlan {
        try TimedChangesPlan(changes: .example, mode: .guides, tempo: 80, loops: 1)
    }
    private func events(_ plan: TimedChangesPlan) throws -> [ChordKeyEvent] {
        var held = Set<Int>()
        var events: [ChordKeyEvent] = []
        for cue in plan.cues {
            let next = Set(try cue.target(plan.mode)?.pianoVoicings(previous: Array(held).sorted()).first ?? [])
            events += held.subtracting(next).map {
                .init(seconds: cue.beat * plan.secondsPerBeat, note: $0, down: false)
            }
            events += next.subtracting(held).map {
                .init(seconds: cue.beat * plan.secondsPerBeat, note: $0, down: true)
            }
            held = next
        }
        return events
    }
    @MainActor private func send(_ events: [ChordKeyEvent], to session: TimedChangesSession, offset: Double = 0) {
        var keyboard = MIDIKeyboardState()
        for event in events {
            let message: MIDIMessage =
                event.down
                ? .noteOn(channel: event.channel, note: event.note, velocity: 90)
                : .noteOff(channel: event.channel, note: event.note)
            keyboard.receive(message)
            session.receive(
                MIDIUpdate(
                    message: message, keyboard: keyboard, timestamp: 100 + event.seconds + offset,
                    arrivalTimestamp: event.arrivalTimestamp))
        }
    }
    @MainActor func testSourceTimestampsOffsetHeldCommonTonesAndDelayedDelivery() throws {
        var now = 99.0
        let p = try plan()
        let session = TimedChangesSession(clock: { now })
        XCTAssertFalse(session.prepare(p, conditions: .init(), held: [60]))
        XCTAssertTrue(session.prepare(p, conditions: .init(offsetMS: 50), held: []))
        session.begin(at: 100)
        XCTAssertEqual(session.countInRemaining, 2)
        now = 110  // queued events keep their native source time
        send(try events(p).reversed(), to: session, offset: 0.05)
        session.tick()
        XCTAssertNil(session.result)
        now = 113
        session.tick()
        XCTAssertTrue(session.result?.report.clean == true)
        XCTAssertFalse(session.busy)
        XCTAssertEqual(session.result?.events.count, 6)
    }
    @MainActor func testCountInHeldNotesCannotMasqueradeAsOnTimeAndPedalIgnored() throws {
        let p = try plan()
        let session = TimedChangesSession(clock: { 113 })
        session.prepare(p, conditions: .init(), held: [])
        session.begin(at: 100)
        var input = try events(p)
        for i in input.indices where input[i].seconds == 0 { input[i].seconds = -2 }
        send(input, to: session)
        session.receive(
            MIDIUpdate(message: .control(channel: 0, number: 64, value: 127), keyboard: .init(), timestamp: 104))
        session.tick()
        XCTAssertEqual(session.result?.report.changes[0].timing, .early)
        XCTAssertEqual(session.result?.events.count, input.count)
    }
    @MainActor func testResetsCancellationDemoAndBadInputLeavePassUngraded() throws {
        let p = try plan()
        let session = TimedChangesSession(clock: { 113 })
        for message: MIDIMessage in [
            .reset, .control(channel: 0, number: 120, value: 0), .control(channel: 0, number: 123, value: 0),
        ] {
            session.prepare(p, conditions: .init(), held: [])
            session.begin(at: 100)
            session.receive(MIDIUpdate(message: message, keyboard: .init(), timestamp: 101))
            session.tick()
            XCTAssertFalse(session.busy)
            XCTAssertNil(session.result)
        }
        session.prepare(p, conditions: .init(), held: [], demonstration: true)
        session.begin(at: 100)
        send(try events(p), to: session)
        session.tick()
        XCTAssertNil(session.result)
        XCTAssertTrue(session.events.isEmpty)
        session.prepare(p, conditions: .init(), held: [])
        session.begin(at: 100)
        session.receive(
            MIDIUpdate(message: .noteOn(channel: 19, note: 60, velocity: 90), keyboard: .init(), timestamp: 100))
        session.receive(
            MIDIUpdate(message: .noteOn(channel: 0, note: 60, velocity: 190), keyboard: .init(), timestamp: 100))
        session.receive(
            MIDIUpdate(message: .noteOn(channel: 0, note: 60, velocity: 90), keyboard: .init(), timestamp: .nan))
        XCTAssertTrue(session.events.isEmpty)
        session.cancel("Focus changed")
        session.tick()
        XCTAssertNil(session.result)
        XCTAssertFalse(session.prepare(p, conditions: .init(offsetMS: 300), held: []))
    }
    @MainActor func testFailedAtomicSaveSurvivesNavigationAndRetriesExactlyOnce() throws {
        let state = AppState(storageOverride: try folder())
        let session = state.timedChangesSession
        let p = try plan()
        state.save()
        session.prepare(p, conditions: .init(), held: [])
        session.begin(at: PracticeClock.now() - p.duration - 1)
        session.tick()
        let result = try XCTUnwrap(session.result)
        let before = state.practiceState
        let url = state.storage.appendingPathComponent("practice-state.json")
        let bytes = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        session.save { try state.saveTimedChanges($0) }
        XCTAssertTrue(session.hasUnsavedResult)
        XCTAssertEqual(state.practiceState, before)
        XCTAssertFalse(session.prepare(p, conditions: .init(), held: []))
        session.cancel()
        state.destination = .practice
        XCTAssertEqual(session.result, result)
        let doc = EditorDocument.leadSheetExample
        state.editor.documents.append(doc)
        let other = try ChangesSource(piece: .init(source: .score(doc)), from: 0, through: 3).plan(staff: 1)
        state.openChanges(other)
        XCTAssertEqual(state.changesPlan, .example)
        state.openTimedChangesReview(result)
        XCTAssertNil(state.changesReview)
        try FileManager.default.removeItem(at: url)
        try bytes.write(to: url)
        session.save { try state.saveTimedChanges($0) }
        session.save { try state.saveTimedChanges($0) }
        XCTAssertTrue(session.saved)
        let restored = AppState(storageOverride: state.storage)
        XCTAssertEqual(restored.journal.attempts.count, 1)
        XCTAssertEqual(restored.journal.attempts[0].id, result.id)
        XCTAssertEqual(restored.history.timedChanges?[result.practiceID]?.latest, result)
        XCTAssertEqual(restored.history.timedChanges?[result.practiceID]?.review.encounters, 1)
        session.discard()
        XCTAssertNil(session.result)
        XCTAssertFalse(session.hasUnsavedResult)
    }
    @MainActor func testPieceRevisionRenameEvidenceReviewAndForgedPlan() throws {
        let state = AppState(storageOverride: try folder())
        var doc = EditorDocument.leadSheetExample
        state.editor.documents.append(doc)
        let piece = LibraryPiece(source: .score(doc))
        let changes = try ChangesSource(piece: piece, from: 0, through: 3).plan(staff: 1)
        let p = try TimedChangesPlan(changes: changes, mode: .guides, tempo: 75, loops: 2, focus: [1, 2])
        var result = TimedChangesResult(plan: p, conditions: .init(bass: true), events: [])
        result.date = Date().addingTimeInterval(-700)
        var forged = result
        forged.plan.cues[0].symbol = try ChordSymbol.parse("Am7")
        XCTAssertThrowsError(try state.saveTimedChanges(forged))
        try state.saveTimedChanges(result)
        XCTAssertEqual(state.timedChangesReviews.count, 1)
        XCTAssertTrue(state.piecePracticeEvidence(piece).contains("Timed chord transitions"))
        state.openTimedChangesReview(result)
        XCTAssertEqual(state.destination, .chords)
        XCTAssertTrue(state.showTimedChanges)
        XCTAssertEqual(state.changesReview?.plan.focus, [1, 2])
        XCTAssertEqual(state.changesPlan.id, changes.id)
        doc.title = "A new title"
        state.editor.replace(doc)
        XCTAssertNoThrow(try state.validateTimedChanges(p))
        doc.harmonies[0].symbol = try ChordSymbol.parse("Am7")
        state.editor.replace(doc)
        XCTAssertThrowsError(try state.saveTimedChanges(result))
        XCTAssertTrue(state.timedChangesReviews.isEmpty)
        XCTAssertTrue(state.timedChangesEvidence(.init(source: .score(doc))).isEmpty)
        state.editor.documents.removeAll { $0.id == doc.id }
        XCTAssertThrowsError(try state.validateTimedChanges(p))
        var example = try plan()
        example.cues[0].symbol = try ChordSymbol.parse("Em7")
        XCTAssertThrowsError(try state.validateTimedChanges(example))
    }
    @MainActor func testImmediateRepeatDoesNotAdvanceSpacingAndConditionsStaySeparate() throws {
        let state = AppState(storageOverride: try folder())
        let p = try plan()
        var result = TimedChangesResult(plan: p, conditions: .init(), events: try events(p))
        try state.saveTimedChanges(result)
        let due = state.history.timedChanges?[result.practiceID]?.review.due
        result.id = UUID()
        result.date = result.date.addingTimeInterval(60)
        try state.saveTimedChanges(result)
        XCTAssertEqual(state.history.timedChanges?[result.practiceID]?.review.due, due)
        result.id = UUID()
        result.conditions.bass = true
        try state.saveTimedChanges(result)
        XCTAssertEqual(state.history.timedChanges?.count, 2)
        XCTAssertEqual(state.history.timedChanges?[result.practiceID]?.review.lastGrade, .supported)
        XCTAssertTrue(state.journal.attempts.last?.assisted == true)
        result.id = UUID()
        result.conditions = .init(offsetMS: 50)
        try state.saveTimedChanges(result)
        XCTAssertEqual(state.history.timedChanges?.count, 3)
    }
    @MainActor func testFormatThreeMigrationPreservesBytesAndNewResults() throws {
        let directory = try folder()
        let url = directory.appendingPathComponent("practice-state.json")
        var old = PracticeState()
        old.schemaVersion = 3
        let bytes = try JSONEncoder().encode(old)
        try bytes.write(to: url)
        let state = AppState(storageOverride: directory)
        let p = try plan()
        let result = TimedChangesResult(plan: p, conditions: .init(), events: try events(p))
        try state.saveTimedChanges(result)
        XCTAssertEqual(try Data(contentsOf: url.appendingPathExtension("previous")), bytes)
        let restored = AppState(storageOverride: directory)
        XCTAssertEqual(restored.practiceState.schemaVersion, 17)
        XCTAssertEqual(restored.history.timedChanges?[result.practiceID]?.latest, result)
    }
}
