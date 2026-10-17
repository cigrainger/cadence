// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

@testable import Cadence

final class ReharmIntegrationTests: XCTestCase {
    @MainActor func prepared(instrument: EditorInstrument = .piano) throws -> AppState {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let state = AppState(storageOverride: folder)
        addTeardownBlock {
            await MainActor.run {
                state.audio.stop()
                state.reharmTransport.stop()
                state.midi.shutdown()
            }
            try? FileManager.default.removeItem(at: folder)
        }
        try state.beginReharmExample(instrument: instrument)
        return state
    }
    @MainActor func creating(_ state: AppState) { for _ in 0..<3 { state.reharmInput.submit(.skip, state: state) } }
    @MainActor func messages(_ notes: [Int], state: AppState) {
        var keyboard = MIDIKeyboardState()
        for note in notes {
            let m = MIDIMessage.noteOn(channel: 0, note: note, velocity: 80)
            keyboard.receive(m)
            state.reharmInput.receive(.init(message: m, keyboard: keyboard), state: state)
        }
        for note in notes {
            let m = MIDIMessage.noteOff(channel: 0, note: note)
            keyboard.receive(m)
            state.reharmInput.receive(.init(message: m, keyboard: keyboard), state: state)
        }
    }
    @MainActor func testExampleAndFullAlternativeAreRepeatSafeAndRestore() throws {
        let state = try prepared()
        let s = state.reharmPractice.active!
        let original = state.libraryPieces.first { $0.id == s.source.pieceID }!
        try state.beginReharmExample(instrument: .piano)
        XCTAssertEqual(state.reharmPractice.sessions.count, 1)
        let a = try state.saveReharmAlternative()
        let b = try state.saveReharmAlternative()
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(state.libraryPieces.first { $0.id == original.id }?.fingerprint, original.fingerprint)
        XCTAssertEqual(a.barCount, 4)
        XCTAssertEqual(a.harmonies[1].symbol.label, "D♭7")
        let restored = AppState(storageOverride: state.storage)
        defer { restored.midi.shutdown() }
        XCTAssertEqual(restored.reharmPractice, state.reharmPractice)
        XCTAssertEqual(restored.reharmAlternative(s.source), a)
    }
    @MainActor func testEditedExampleIsNeverOverwritten() throws {
        let state = try prepared()
        let id = try ReharmSource.example().id
        var copy = state.editor
        let i = copy.documents.firstIndex { $0.id == id }!
        copy.documents[i].harmonies[1].symbol = try .parse("Gmaj7")
        try state.commitScores(copy)
        try state.beginReharmExample(instrument: .piano)
        XCTAssertEqual(state.editor.documents.first { $0.id == id }?.harmonies[1].symbol.label, "Gmaj7")
        XCTAssertNotEqual(state.reharmPractice.active?.source.pieceID, "score:" + id.uuidString)
    }
    @MainActor func testAnswerSaveFailureIsAtomicAndRetriedOnce() throws {
        let state = try prepared()
        let before = state.practiceState
        let url = state.stores.practice.url
        let data = try Data(contentsOf: state.stores.practice.url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        state.reharmInput.submit(.skip, state: state)
        XCTAssertNotNil(state.reharmInput.pending)
        XCTAssertEqual(state.practiceState, before)
        try FileManager.default.removeItem(at: url)
        try data.write(to: url)
        state.reharmInput.save(state)
        state.reharmInput.save(state)
        XCTAssertNil(state.reharmInput.pending)
        XCTAssertEqual(state.journal.attempts.count, 1)
        XCTAssertEqual(state.reharmPractice.active?.skill, .explaining)
    }
    @MainActor func testStaleSourceRejectsEvidenceAndKeepsOldWork() throws {
        let state = try prepared()
        let s = state.reharmPractice.active!
        let pending = ReharmInput.Pending(expected: s, action: .skip)
        let i = state.editor.documents.firstIndex { "score:" + $0.id.uuidString == s.source.pieceID }!
        state.editor.documents[i].harmonies[1].symbol = try .parse("G9")
        XCTAssertFalse(state.reharmCurrent(s.source))
        XCTAssertThrowsError(try state.saveReharmAction(pending))
        XCTAssertThrowsError(try state.resumeReharm(s.id))
        XCTAssertTrue(state.practiceReviews(now: .distantFuture).filter { $0.id.hasPrefix("reharm:") }.isEmpty)
    }
    @MainActor func testMIDIReleasedPairsAndNavigationExclusion() throws {
        let state = try prepared()
        state.reharmInput.submit(.skip, state: state)
        state.reharmInput.submit(.skip, state: state)
        state.reharmInput.arm(state)
        messages([65, 72], state: state)
        messages([65, 71], state: state)
        XCTAssertEqual(state.reharmInput.groups.count, 2)
        XCTAssertEqual(state.reharmPractice.active?.skill, .playing)
        messages([64, 71], state: state)
        XCTAssertEqual(state.reharmPractice.active?.skill, .creating)
        XCTAssertEqual(state.journal.attempts.last?.input, .midi)
        XCTAssertEqual(state.journal.attempts.last?.outcome, .correct)
        try state.resumeReharm(state.reharmPractice.active!.id, skill: .playing)
        state.reharmInput.arm(state)
        state.destination = .library
        messages([65, 72], state: state)
        XCTAssertFalse(state.reharmInput.listening)
    }
    @MainActor func testFreeRecordingTimingPedalAndPendingTakeSurviveSaveFailure() throws {
        let state = try prepared()
        creating(state)
        let s = state.reharmPractice.active!
        // The injected clock exercises the same transport without real-time waits.
        var now = 100.0
        let transport = ReharmTransport(clock: { now })
        XCTAssertTrue(transport.prepareRecording(s, version: .substitute, tempo: 84, offsetMS: 25, held: []))
        transport.begin(at: 100, record: true)
        var keys = MIDIKeyboardState()
        let stream: [(Double, MIDIMessage)] = [
            (100.025, .noteOn(channel: 0, note: 64, velocity: 93)),
            (100.225, .control(channel: 0, number: 64, value: 127)), (101.025, .noteOff(channel: 0, note: 64)),
            (102.025, .control(channel: 0, number: 64, value: 0)),
        ]
        for (time, m) in stream {
            keys.receive(m)
            transport.receive(.init(message: m, keyboard: keys, timestamp: time), state: state)
        }
        now = 100 + s.source.length * 60 / 84 + 1
        transport.tick()
        let take = try XCTUnwrap(transport.pending)
        XCTAssertTrue(take.valid)
        XCTAssertEqual(take.recording.events.count, 4)
        XCTAssertEqual(take.recording.events.first!.seconds, 0, accuracy: 0.000001)
        XCTAssertEqual(take.recording.notes.first!.soundEnd, 2, accuracy: 0.000001)
        transport.stop()
        XCTAssertEqual(transport.pending, take)
        transport.discard()
        XCTAssertNil(transport.pending)
    }
    @MainActor func testRecordGuardRejectsHeldKeysEarlyNotesResetAndStaleSession() throws {
        let state = try prepared()
        creating(state)
        let s = state.reharmPractice.active!
        let t = ReharmTransport(clock: { 100 })
        XCTAssertFalse(t.prepareRecording(s, version: .original, tempo: 84, offsetMS: 0, held: [60]))
        XCTAssertFalse(t.prepareRecording(s, version: .original, tempo: 84, offsetMS: 0, held: [], pedal: true))
        XCTAssertTrue(t.prepareRecording(s, version: .original, tempo: 84, offsetMS: 0, held: []))
        t.receive(
            .init(message: .noteOn(channel: 0, note: 60, velocity: 80), keyboard: .init(), timestamp: 100), state: state
        )
        XCTAssertFalse(t.busy)
        XCTAssertTrue(t.prepareRecording(s, version: .original, tempo: 84, offsetMS: 0, held: []))
        t.begin(at: 100, record: true)
        t.receive(.init(message: .reset, keyboard: .init()), state: state)
        XCTAssertFalse(t.busy)
        XCTAssertNil(t.pending)
        XCTAssertTrue(t.prepareRecording(s, version: .original, tempo: 84, offsetMS: 0, held: []))
        t.begin(at: 100, record: true)
        state.destination = .library
        t.receive(
            .init(message: .noteOn(channel: 0, note: 60, velocity: 80), keyboard: .init(), timestamp: 101), state: state
        )
        XCTAssertFalse(t.busy)
    }
    @MainActor func testCreativeFinishNeedsSavedAlternativeAndNewListenedTake() throws {
        let state = try prepared()
        creating(state)
        let s = state.reharmPractice.active!
        let pending = ReharmInput.Pending(
            expected: s, action: .creation("I repeated the rhythm and changed the last note."))
        XCTAssertThrowsError(try state.saveReharmAction(pending))
        _ = try state.saveReharmAlternative()
        XCTAssertThrowsError(try state.saveReharmAction(pending))
        var take = ReharmTake(
            sessionID: s.id, source: s.source, version: .original, tempo: 84, offsetMS: 0,
            recording: .init(
                events: [PianoEvent(.noteOn(channel: 0, note: 64, velocity: 80), seconds: 6)!],
                end: s.source.length * 60 / 84))
        var copy = state.practiceState
        try copy.reharm?.append(take)
        try state.commitPractice(copy)
        XCTAssertThrowsError(try state.saveReharmAction(pending))
        take.listened = true
        copy.reharm?.takes = [take]
        try state.commitPractice(copy)
        let evidence = try state.saveReharmAction(pending)
        XCTAssertEqual(evidence?.input, .selfReport)
        XCTAssertEqual(evidence?.scoreID, state.reharmAlternative(s.source)?.id)
        try state.resumeReharm(state.reharmPractice.active!.id, skill: .creating)
        XCTAssertThrowsError(
            try state.saveReharmAction(
                .init(expected: state.reharmPractice.active!, action: .creation("Another phrase"))))
    }
    @MainActor func testGuitarCreativeFinishAndSeparateReviewQueue() throws {
        let state = try prepared(instrument: .guitar)
        creating(state)
        _ = try state.saveReharmAlternative()
        state.reharmInput.submit(
            .creation("I sang the guide tones, then found the answer on two strings."), state: state)
        XCTAssertTrue(state.reharmPractice.active!.completed)
        XCTAssertEqual(state.reharmPractice.active!.reviews.count, 4)
        XCTAssertEqual(
            state.practiceReviews(now: Date().addingTimeInterval(1300)).filter { $0.id.hasPrefix("reharm:") }.count, 4)
        let before = state.reharmPractice.active!.reviews
        try state.resumeReharm(state.reharmPractice.active!.id, skill: .explaining)
        state.reharmInput.submit(.explanation(0), state: state)
        XCTAssertFalse(state.journal.attempts.last!.assisted)
        XCTAssertEqual(
            state.reharmPractice.active!.reviews[TheorySkill.hearing.rawValue], before[TheorySkill.hearing.rawValue])
    }
    @MainActor func testUnreviewedOriginalCannotBegin() throws {
        let state = try prepared()
        var doc = try ReharmSource.example()
        doc.id = UUID()
        doc.pdfSource = .init(filename: "original.pdf", page: 1, model: "fixture")
        state.editor.documents.append(doc)
        XCTAssertThrowsError(
            try state.beginReharm(
                piece: .init(source: .score(doc)), scope: .init(partID: "P1", staff: 1, from: 0, through: 3),
                tonic: Pitch(0), instrument: .piano))
    }
    @MainActor func testOwnedRecordingSaveFailureRetriesWithoutDuplicatingTake() throws {
        let state = try prepared()
        creating(state)
        let s = state.reharmPractice.active!
        let transport = state.reharmTransport
        XCTAssertTrue(transport.prepareRecording(s, version: .original, tempo: 84, offsetMS: 0, held: []))
        transport.begin(at: 0, record: true)
        transport.receive(
            .init(message: .noteOn(channel: 0, note: 64, velocity: 87), keyboard: .init(), timestamp: 1), state: state)
        transport.receive(
            .init(message: .noteOff(channel: 0, note: 64), keyboard: .init(), timestamp: 2), state: state)
        transport.tick()
        let take = try XCTUnwrap(transport.pending)
        let before = state.practiceState
        let url = state.stores.practice.url
        let data = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try state.saveReharmTake())
        XCTAssertEqual(state.practiceState, before)
        XCTAssertEqual(transport.pending, take)
        XCTAssertThrowsError(try state.resumeReharm(s.id))
        try FileManager.default.removeItem(at: url)
        try data.write(to: url)
        try state.saveReharmTake()
        XCTAssertNil(transport.pending)
        XCTAssertEqual(state.reharmPractice.takes.count, 1)
        XCTAssertThrowsError(try state.saveReharmTake())
        XCTAssertEqual(state.reharmPractice.takes.count, 1)
        let restored = AppState(storageOverride: state.storage)
        defer { restored.midi.shutdown() }
        XCTAssertEqual(restored.reharmPractice.takes, [take])
        try state.markReharmTakeListened(take.id)
        XCTAssertFalse(state.reharmPractice.takes[0].listened)
        transport.replay(take, over: .substitute)
        transport.begin(at: 0, record: false)
        transport.tick()
        try state.markReharmTakeListened(take.id)
        XCTAssertTrue(state.reharmPractice.takes[0].listened)
        try state.deleteReharmTake(take.id)
        XCTAssertTrue(state.reharmPractice.takes.isEmpty)
    }
    @MainActor func testInterruptedAuditionCannotCountAsHeard() throws {
        let state = try prepared()
        let s = state.reharmPractice.active!
        let t = state.reharmTransport
        var completed = false
        t.audition(s.source, version: .original, tempo: 84, layer: .bass, onFinished: { completed = true })
        t.begin(at: 0, record: false)
        t.stop()
        t.tick()
        XCTAssertFalse(completed)
        t.audition(s.source, version: .original, tempo: 84, layer: .bass, onFinished: { completed = true })
        t.begin(at: 0, record: false)
        t.tick()
        XCTAssertTrue(completed)
    }
    @MainActor func testReviewedPDFAlternativeBelongsToCompositionsAndKeepsOriginalPages() throws {
        let state = try prepared()
        var doc = try ReharmSource.example()
        doc.id = UUID()
        doc.pdfSource = .init(filename: "Source.pdf", page: 2, model: "fixture")
        doc.pdfSource?.reviewed = true
        state.editor.documents.append(doc)
        let piece = LibraryPiece(source: .score(doc))
        try state.beginReharm(
            piece: piece, scope: .init(partID: "P1", staff: 1, from: 0, through: 3), tonic: Pitch(0), instrument: .piano
        )
        let alternative = try state.saveReharmAlternative()
        XCTAssertEqual(LibraryPiece(source: .score(alternative)).defaultKind, .composition)
        XCTAssertEqual(alternative.pdfSource, doc.pdfSource)
        XCTAssertEqual(piece.defaultKind, .sheetMusic)
    }
    func testSampledComparisonAndTakeReplayProduceFiniteAudio() throws {
        let source = try ReharmSource(
            piece: .init(source: .score(ReharmSource.example())),
            scope: .init(partID: "P1", staff: 1, from: 0, through: 3), tonic: Pitch(0))
        let recording = PianoRecording(
            events: [
                PianoEvent(.noteOn(channel: 0, note: 64, velocity: 85), seconds: 0)!,
                PianoEvent(.noteOff(channel: 0, note: 64), seconds: 0.4)!,
            ], end: source.length * 60 / 160)
        let audio = try ReharmAudio.render(source: source, version: .substitute, tempo: 160, take: recording)
        XCTAssertTrue(audio.allSatisfy(\.isFinite))
        XCTAssertTrue(audio.contains { abs($0) > 0.01 })
        XCTAssertGreaterThan(audio.count, Int(recording.end * 44100))
    }
}
