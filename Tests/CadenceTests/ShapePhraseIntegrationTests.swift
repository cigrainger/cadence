// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

@testable import Cadence

final class ShapePhraseIntegrationTests: XCTestCase {
    @MainActor func prepared() throws -> (AppState, LibraryPiece) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let state = AppState(storageOverride: folder)
        let piece = LibraryPiece(source: .score(try PieceRehearsalChecks.document()))
        addTeardownBlock {
            await MainActor.run {
                state.midi.shutdown()
                state.audio.stop()
                state.rehearsalSession.stop()
            }
            try? FileManager.default.removeItem(at: folder)
        }
        if case .score(let doc) = piece.source { state.editor.documents.append(doc) }
        XCTAssertTrue(state.save())
        state.openPieceRehearsal(piece)
        try state.beginRehearsal(
            piece, scope: .init(partID: "P1", staff: 1, from: 4, through: 7), tempo: 80,
            now: Date().addingTimeInterval(-30))
        return (state, piece)
    }
    @MainActor func testPianoTakesCommitWithPassAndSurviveRelaunch() throws {
        let (state, piece) = try prepared()
        try ShapePhraseChecks.capture(state: state, pedal: true)
        try ShapePhraseChecks.capture(state: state, connected: true)
        XCTAssertEqual(state.pianoTakes.takes.count, 2)
        XCTAssertEqual(state.journal.attempts.count, 2)
        XCTAssertEqual(state.currentRehearsal?.phraseIntention, .connectedMelody)
        XCTAssertTrue(state.rehearsalSession.shaping)
        let saved = state.pianoTakes
        let key = try XCTUnwrap(state.rehearsalKey)
        let other = AppState(storageOverride: state.storage)
        defer { other.midi.shutdown() }
        other.openPieceRehearsal(piece, key: key)
        XCTAssertEqual(other.pianoTakes, saved)
        XCTAssertEqual(other.currentRehearsal?.phraseIntention, .connectedMelody)
        XCTAssertEqual(saved.takes[0].id, state.journal.attempts[0].id)
        XCTAssertTrue(saved.takes[0].recording.events.contains { $0.kind == .sustain })
    }
    @MainActor func testFailedAtomicSaveRetainsRecordingAndDoesNotDuplicateOnRetry() throws {
        let (state, _) = try prepared()
        let before = state.practiceState
        let url = state.stores.practice.url
        let bytes = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try ShapePhraseChecks.capture(state: state, pedal: true)
        let session = state.rehearsalSession
        let recording = session.timing.pianoRecording
        XCTAssertTrue(session.timing.hasUnsavedResult)
        XCTAssertNotNil(recording)
        XCTAssertEqual(state.practiceState, before)
        state.showPracticeHome()
        XCTAssertEqual(session.timing.pianoRecording, recording)
        XCTAssertThrowsError(try state.startRehearsal(exercise: .notes, tempo: 80, input: .midi))
        try FileManager.default.removeItem(at: url)
        try bytes.write(to: url)
        state.saveRehearsalPass()
        state.saveRehearsalPass()
        XCTAssertTrue(session.timing.saved)
        XCTAssertEqual(state.pianoTakes.takes.count, 1)
        XCTAssertEqual(state.journal.attempts.count, 1)
        XCTAssertEqual(state.pianoTakes.takes.first?.recording, recording)
    }
    @MainActor func testCaptureCancellationResetAndOverflowNeverLeaveHalfATake() throws {
        let (state, _) = try prepared()
        try state.startRehearsal(exercise: .notes, tempo: 80, input: .midi)
        state.rehearsalSession.stop()
        XCTAssertNil(state.rehearsalSession.timing.pianoRecording)
        XCTAssertTrue(state.pianoTakes.takes.isEmpty)
        try ShapePhraseChecks.capture(state: state)
        let r = try XCTUnwrap(state.currentRehearsal)
        let piece = try XCTUnwrap(state.libraryPieces.first { $0.id == r.pieceID })
        let phrase = try PianoPhrase(
            piece: piece, plan: PieceRehearsal.exercisePlan(r.activePlan, exercise: .notes, tempo: 65))
        let session = state.rehearsalSession
        _ = try session.prepare(r, exercise: .notes, tempo: 65, input: .midi, held: [], pianoPhrase: phrase)
        let origin = PracticeClock.now()
        session.timing.begin(at: origin)
        for _ in 0..<8193 {
            session.timing.receive(
                .init(message: .control(channel: 0, number: 64, value: 0), keyboard: .init(), timestamp: origin))
        }
        XCTAssertFalse(session.timing.busy)
        XCTAssertNil(session.timing.result)
        XCTAssertTrue(session.timing.error?.contains("Too many") == true)
        XCTAssertEqual(state.pianoTakes.takes.count, 1)
        _ = try session.prepare(r, exercise: .notes, tempo: 65, input: .midi, held: [], pianoPhrase: phrase)
        session.timing.begin(at: origin)
        session.timing.receive(.init(message: .reset, keyboard: .init(), timestamp: origin))
        XCTAssertNil(session.timing.pianoRecording)
        XCTAssertNil(session.timing.result)
    }
    @MainActor func testSilentPianoPassIsHonestAndRhythmDoesNotCreateATake() throws {
        let (state, piece) = try prepared()
        let r = try XCTUnwrap(state.currentRehearsal)
        let session = state.rehearsalSession
        let phrase = try PianoPhrase(piece: piece, plan: r.opening)
        _ = try session.prepare(r, exercise: .notes, tempo: 80, input: .midi, held: [], pianoPhrase: phrase)
        session.timing.begin(at: PracticeClock.now() - r.opening.duration - 1)
        session.timing.tick()
        state.saveRehearsalPass()
        XCTAssertTrue(session.timing.saved)
        XCTAssertEqual(state.pianoTakes.takes.count, 1)
        XCTAssertTrue(state.pianoTakes.takes[0].recording.notes.isEmpty)
        XCTAssertTrue(state.pianoTakes.takes[0].joins.isEmpty)
        try PieceRehearsalChecks.capture(state: state, exercise: .rhythm, input: .space)
        XCTAssertEqual(state.pianoTakes.takes.count, 1)
        XCTAssertEqual(state.journal.attempts.count, 2)
    }
    @MainActor func testReplayCursorUsesPerformanceTimeAndStopDoesNotMarkListened() throws {
        let (state, _) = try prepared()
        try ShapePhraseChecks.capture(state: state)
        let take = try XCTUnwrap(state.pianoTakes.takes.first)
        var now = 100.0
        let player = PianoTakePlayer(clock: { now })
        player.begin(take, at: 100)
        XCTAssertNotNil(player.playhead)
        now += 1.5
        player.tick()
        XCTAssertEqual(player.playhead?.sourceBeat, 18)
        player.stop()
        XCTAssertFalse(player.busy)
        XCTAssertNil(player.playhead)
        XCTAssertNil(player.completedID)
        player.begin(take, at: 100)
        now = 100 + take.recording.duration + 0.4
        player.tick()
        XCTAssertFalse(player.busy)
        XCTAssertEqual(player.completedID, take.id)
    }
    @MainActor func testReflectionRequiresCompletedListeningAndSavesWithoutChangingSchedule() throws {
        let (state, _) = try prepared()
        try ShapePhraseChecks.capture(state: state)
        let take = try XCTUnwrap(state.pianoTakes.takes.first)
        let player = state.rehearsalSession.takePlayer
        let before = state.rehearsals
        XCTAssertThrowsError(try state.reflectOnPianoTake(take.id, reflection: .connected, note: "Nice"))
        player.begin(take, at: PracticeClock.now())
        player.stop()
        try state.finishPianoTakeListening(take.id)
        XCTAssertNil(state.pianoTakes.takes[0].listenedAt)
        player.begin(take, at: PracticeClock.now() - take.recording.duration - 1)
        player.tick()
        try state.finishPianoTakeListening(take.id)
        try state.reflectOnPianoTake(take.id, reflection: .uneven, note: "Listen to the second join")
        XCTAssertEqual(state.pianoTakes.takes[0].reflection, .uneven)
        XCTAssertEqual(state.rehearsals, before)
        XCTAssertThrowsError(
            try state.reflectOnPianoTake(take.id, reflection: .connected, note: String(repeating: "x", count: 1001)))
        XCTAssertEqual(state.pianoTakes.takes[0].reflection, .uneven)
    }
    @MainActor func testReplayAndOpeningOldFeedbackCountAsReviewSupportAcrossRelaunch() throws {
        let (state, piece) = try prepared()
        try ShapePhraseChecks.capture(state: state)
        let opening = try XCTUnwrap(state.currentRehearsal)
        let early = Date().addingTimeInterval(-172800)
        var record = try PieceRehearsal(opening: opening.opening, now: early)
        func pass(_ p: TimedPracticePlan, _ s: Double, _ click: Bool = false) -> TimedPracticeResult {
            .init(
                date: early.addingTimeInterval(s), plan: p, conditions: .init(click: click),
                attacks: p.targets.map { .init(seconds: $0.beat * p.secondsPerBeat, pitch: $0.pitch) })
        }
        try record.recordOpening(
            pass(record.opening, 1), focus: opening.focus!, context: opening.context!, now: early.addingTimeInterval(1))
        record.phraseIntention = .connectedMelody
        try record.recordFocus(
            pass(record.activePlan, 2, true), exercise: .connected, now: early.addingTimeInterval(2))
        try record.returnToPhrase()
        try record.recordContext(pass(record.activePlan, 3), now: early.addingTimeInterval(3))
        try record.beginReview()
        var copy = state.practiceState
        copy.rehearsal?.records[record.key] = record
        try state.commitPractice(copy)
        state.openPieceRehearsal(piece)
        XCTAssertFalse(state.rehearsalSession.shaping)
        XCTAssertEqual(state.currentRehearsal?.reviewStarts, 0)
        try state.showPhraseShaping(true)
        XCTAssertEqual(state.currentRehearsal?.reviewStarts, 2)
        XCTAssertGreaterThan(state.currentRehearsal!.nextReview!, Date().addingTimeInterval(19 * 3600))
        try state.playPianoTake(state.pianoTakes.takes[0].id)
        state.rehearsalSession.takePlayer.stop()
        let restored = AppState(storageOverride: state.storage)
        defer { restored.midi.shutdown() }
        restored.openPieceRehearsal(piece)
        XCTAssertFalse(restored.rehearsalSession.shaping)
        XCTAssertEqual(restored.currentRehearsal?.reviewStarts, 2)
        XCTAssertEqual(restored.currentRehearsal?.phraseIntention, .connectedMelody)
    }
    @MainActor func testChangedDeletedAndUnrelatedSourcesCannotReplayOrSaveOnNewNotes() throws {
        let (state, piece) = try prepared()
        try ShapePhraseChecks.capture(state: state)
        let take = try XCTUnwrap(state.pianoTakes.takes.first)
        try ShapePhraseChecks.capture(state: state, save: false)
        let i = try XCTUnwrap(state.editor.documents.firstIndex { "score:" + $0.id.uuidString == piece.id })
        state.editor.documents[i].events[0].pitches = [EditorPitch(95)]
        XCTAssertThrowsError(try state.playPianoTake(take.id))
        state.saveRehearsalPass()
        XCTAssertTrue(state.rehearsalSession.timing.hasUnsavedResult)
        XCTAssertEqual(state.pianoTakes.takes.count, 1)
        state.rehearsalSession.timing.discard()
        state.editor.documents.remove(at: i)
        XCTAssertThrowsError(try state.playPianoTake(take.id))
        XCTAssertFalse(state.rehearsalSession.takePlayer.busy)
    }
    @MainActor func testDeleteTakeKeepsJournalAndReviewAndClearsSelections() throws {
        let (state, _) = try prepared()
        try ShapePhraseChecks.capture(state: state)
        let take = try XCTUnwrap(state.pianoTakes.takes.first)
        let before = state.journal
        let records = state.rehearsals
        state.rehearsalSession.comparisonTakeID = take.id
        try state.deletePianoTake(take.id)
        XCTAssertTrue(state.pianoTakes.takes.isEmpty)
        XCTAssertEqual(state.journal, before)
        XCTAssertEqual(state.rehearsals, records)
        XCTAssertNil(state.rehearsalSession.selectedTakeID)
        XCTAssertNil(state.rehearsalSession.comparisonTakeID)
    }
    @MainActor func testConnectedExerciseRejectsUnsupportedPhraseAndStartingDuringReplay() throws {
        let (state, _) = try prepared()
        try ShapePhraseChecks.capture(state: state)
        let record = try XCTUnwrap(state.currentRehearsal)
        XCTAssertThrowsError(
            try state.rehearsalSession.prepare(record, exercise: .connected, tempo: 65, input: .midi, held: []))
        let take = try XCTUnwrap(state.pianoTakes.takes.first)
        state.rehearsalSession.takePlayer.begin(take, at: PracticeClock.now())
        XCTAssertThrowsError(try state.startRehearsal(exercise: .connected, tempo: 65, input: .midi))
        XCTAssertThrowsError(try state.listenToRehearsal(loop: false, tempo: 65))
        XCTAssertThrowsError(try state.deletePianoTake(take.id))
        state.rehearsalSession.invalidateTiming("Output changed")
        XCTAssertFalse(state.rehearsalSession.takePlayer.busy)
        XCTAssertFalse(state.rehearsalSession.timing.busy)
    }
    @MainActor func testNormalStartAutomaticallyRecordsPianoAndRejectsInputDuringPreparation() throws {
        let (state, _) = try prepared()
        let session = state.rehearsalSession
        try state.startRehearsal(exercise: .notes, tempo: 80, input: .midi)
        XCTAssertTrue(session.timing.preparing)
        XCTAssertNotNil(session.pianoPhrase)
        session.timing.receive(.init(message: .control(channel: 0, number: 64, value: 127), keyboard: .init()))
        XCTAssertFalse(session.timing.busy)
        XCTAssertNil(session.timing.result)
        try state.startRehearsal(exercise: .notes, tempo: 80, input: .midi)
        let plan = try XCTUnwrap(session.timing.plan)
        let origin = PracticeClock.now() - plan.duration - 1
        session.timing.begin(at: origin)
        var keys = MIDIKeyboardState()
        for target in plan.targets {
            let press = MIDIMessage.noteOn(channel: 0, note: target.pitch, velocity: 80)
            let release = MIDIMessage.noteOff(channel: 0, note: target.pitch)
            keys.receive(press)
            session.timing.receive(
                .init(message: press, keyboard: keys, timestamp: origin + target.beat * plan.secondsPerBeat))
            keys.receive(release)
            session.timing.receive(
                .init(message: release, keyboard: keys, timestamp: origin + target.beat * plan.secondsPerBeat + 0.5))
        }
        session.timing.tick()
        state.saveRehearsalPass()
        XCTAssertTrue(session.timing.saved)
        XCTAssertEqual(state.pianoTakes.takes.count, 1)
        XCTAssertEqual(state.pianoTakes.takes[0].recording.notes.count, plan.targets.count)
    }
    @MainActor func testStoppedPreparationCannotStartPlaybackLater() async throws {
        let (state, _) = try prepared()
        try ShapePhraseChecks.capture(state: state)
        let player = state.rehearsalSession.takePlayer
        let take = try XCTUnwrap(state.pianoTakes.takes.first)
        player.play(take)
        XCTAssertTrue(player.preparing)
        player.stop()
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(player.busy)
        XCTAssertNil(player.completedID)
        XCTAssertNil(player.playhead)
    }
}
