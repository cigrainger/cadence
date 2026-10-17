// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class MIDITests: XCTestCase {
    func testUMPDecodesNotesVelocityZeroControlsAndChannels() {
        XCTAssertEqual(
            MIDIWords.decode([0x2091_3c64, 0x2091_3c00, 0x2081_3d40, 0x20b1_407f]),
            [
                .noteOn(channel: 1, note: 60, velocity: 100), .noteOff(channel: 1, note: 60),
                .noteOff(channel: 1, note: 61), .control(channel: 1, number: 64, value: 127),
            ])
    }
    func testUMPUnknownAndSysExPacketsDoNotBecomeKeyboardNotes() {
        XCTAssertEqual(
            MIDIWords.decode([0x3000_0000, 0x2090_3c64, 0x2090_4064]), [.noteOn(channel: 0, note: 64, velocity: 100)])
        XCTAssertTrue(MIDIWords.decode([0x4000_0000]).isEmpty)
        XCTAssertEqual(MIDIWords.decode([0x10ff_0000]), [.reset])
    }
    func testSustainIsSeparateFromPhysicalKeysAndChannelScoped() {
        var s = MIDIKeyboardState()
        s.receive(.control(channel: 0, number: 64, value: 127))
        s.receive(.noteOn(channel: 0, note: 60, velocity: 90))
        s.receive(.noteOff(channel: 0, note: 60))
        XCTAssertTrue(s.downNotes.isEmpty)
        XCTAssertEqual(s.soundingNotes, [60])
        s.receive(.control(channel: 1, number: 64, value: 0))
        XCTAssertEqual(s.soundingNotes, [60])
        s.receive(.control(channel: 0, number: 64, value: 0))
        XCTAssertTrue(s.soundingNotes.isEmpty)
    }
    func testUnmatchedReleaseAndRepeatedNoteOnDoNotLeaveStuckKeys() {
        var s = MIDIKeyboardState()
        s.receive(.noteOff(channel: 0, note: 60))
        s.receive(.noteOn(channel: 0, note: 60, velocity: 90))
        s.receive(.noteOn(channel: 0, note: 60, velocity: 80))
        s.receive(.noteOff(channel: 0, note: 60))
        XCTAssertTrue(s.downNotes.isEmpty)
        s.receive(.noteOn(channel: 1, note: 60, velocity: 90))
        s.receive(.noteOn(channel: 0, note: 60, velocity: 90))
        s.receive(.noteOff(channel: 0, note: 60))
        XCTAssertEqual(s.downNotes, [60])
        s.receive(.reset)
        XCTAssertTrue(s.soundingNotes.isEmpty)
    }
    func testGestureCommitsWholeChordExactlyOnceOnFinalPhysicalRelease() {
        var s = MIDIKeyboardState()
        var capture = MIDIStepCapture()
        var results: [[Int]] = []
        for message in [
            MIDIMessage.noteOn(channel: 0, note: 60, velocity: 90), .noteOn(channel: 0, note: 64, velocity: 90),
            .noteOn(channel: 0, note: 67, velocity: 90), .noteOff(channel: 0, note: 60), .noteOff(channel: 0, note: 64),
            .noteOff(channel: 0, note: 67), .noteOff(channel: 0, note: 67),
        ] {
            s.receive(message)
            if let result = capture.receive(message, state: s) { results.append(result) }
        }
        XCTAssertEqual(results, [[60, 64, 67]])
    }
    func testArmingWithHeldKeysWaitsAndPedalNeverJoinsSuccessiveEntries() {
        var s = MIDIKeyboardState()
        var capture = MIDIStepCapture()
        s.receive(.noteOn(channel: 0, note: 60, velocity: 90))
        capture.reset(held: s.downNotes)
        s.receive(.noteOff(channel: 0, note: 60))
        XCTAssertNil(capture.receive(.noteOff(channel: 0, note: 60), state: s))
        s.receive(.control(channel: 0, number: 64, value: 127))
        for note in [62, 64] {
            let on = MIDIMessage.noteOn(channel: 0, note: note, velocity: 90)
            let off = MIDIMessage.noteOff(channel: 0, note: note)
            s.receive(on)
            XCTAssertNil(capture.receive(on, state: s))
            s.receive(off)
            XCTAssertEqual(capture.receive(off, state: s), [note])
        }
        XCTAssertEqual(s.soundingNotes, [62, 64])
    }
    func testPanicAndAllNotesOffCancelWithoutCommitting() {
        for panic in [
            MIDIMessage.reset, .control(channel: 0, number: 123, value: 0), .control(channel: 0, number: 120, value: 0),
        ] {
            var s = MIDIKeyboardState()
            var capture = MIDIStepCapture()
            let on = MIDIMessage.noteOn(channel: 0, note: 60, velocity: 90)
            s.receive(on)
            _ = capture.receive(on, state: s)
            s.receive(panic)
            XCTAssertNil(capture.receive(panic, state: s))
            XCTAssertTrue(capture.notes.isEmpty)
        }
    }
    func testMIDIEntryIsAtomicPreservesOtherVoiceAndAdvancesInLowerVoice() throws {
        var doc = EditorDocument.innerVoiceExample
        let first = doc.inBar(0, staff: 1, voice: 2)[0]
        let oldUpper = doc.ordered(staff: 1)
        let oldLeft = doc.ordered(staff: 2)
        let next = try doc.enterMIDI([60, 64, 67], eventID: first.id, rhythm: EditorRhythm(480))
        XCTAssertEqual(doc.events.first { $0.id == first.id }?.pitches.map(\.midi), [60, 64, 67])
        XCTAssertEqual(doc.events.first { $0.id == next }?.voice, 2)
        XCTAssertEqual(doc.ordered(staff: 1), oldUpper)
        XCTAssertEqual(doc.ordered(staff: 2), oldLeft)
        let saved = doc
        XCTAssertThrowsError(try doc.enterMIDI([60, 64], eventID: first.id, rhythm: EditorRhythm(960)))
        XCTAssertEqual(doc, saved)
        XCTAssertThrowsError(try doc.enterMIDI([0], eventID: first.id, rhythm: EditorRhythm(480)))
        XCTAssertEqual(doc, saved)
    }
    func testMIDIEntryAtLastBarInLowerPianoVoiceAppendsAllStaffs() throws {
        var doc = try EditorDocument.blank(instrument: .piano, bars: 1)
        try doc.addVoice(staff: 1)
        let first = doc.inBar(0, staff: 1, voice: 2)[0]
        let next = try doc.enterMIDI([48, 55], eventID: first.id, rhythm: EditorRhythm(1920))
        XCTAssertEqual(doc.barCount, 2)
        XCTAssertEqual(doc.events.first { $0.id == next }?.bar, 1)
        XCTAssertEqual(doc.events.first { $0.id == next }?.voice, 2)
        _ = try doc.validated()
    }
    func testGuitarEntryProducesLinkedPositionsAndRejectsImpossibleChordAtomically() throws {
        var doc = EditorDocument.guitarExample
        let id = doc.events[0].id
        _ = try doc.enterMIDI([60, 64, 67], eventID: id, rhythm: EditorRhythm(480))
        _ = try doc.validated()
        let original = doc
        XCTAssertThrowsError(try doc.enterMIDI([21, 22, 23], eventID: id, rhythm: EditorRhythm(480)))
        XCTAssertEqual(doc, original)
        let copied = try EditorXML.decode(Data(EditorXML.encode(doc).utf8))
        XCTAssertEqual(copied.events[0].pitches.map(\.midi), [60, 64, 67])
    }
    func testChordChecksAllQualitiesInversionsRegistersAndDoublings() {
        for quality in [ChordQuality.major, .minor, .diminished, .augmented, .dominant7, .maj7, .min7] {
            for pc in 0..<12 {
                for inversion in 0..<quality.intervals.count {
                    let root = Pitch.spelled(60 + pc, flats: false)
                    let chord = PlayedChord(root: root, quality: quality, inversion: inversion)
                    XCTAssertTrue(chord.judge(chord.reference).correct)
                    XCTAssertTrue(chord.judge(chord.reference.map { $0 - 12 } + [chord.reference.last! + 12]).correct)
                    XCTAssertFalse(chord.judge(Array(chord.reference.dropLast())).correct)
                }
            }
        }
    }
    func testChordFeedbackSeparatesMissingExtraAndWrongBass() {
        let chord = PlayedChord(root: Pitch(0), quality: .major, inversion: 1)
        let wrong = chord.judge([48, 64, 67, 70])
        XCTAssertTrue(wrong.missing.isEmpty)
        XCTAssertEqual(wrong.extra, [10])
        XCTAssertFalse(wrong.bassCorrect)
        XCTAssertEqual(chord.judge([64, 67]).missing, [0])
        XCTAssertFalse(chord.judge([]).correct)
    }
    func testPracticeJournalPreservesContextAndKeepsModalitiesAssistanceDistinct() throws {
        var journal = PracticeJournal()
        let session = UUID()
        for input in PracticeInput.allCases {
            journal.append(
                PracticeAttempt(
                    sessionID: session, activityID: "third", title: "Third", skills: ["Intervals"], input: input,
                    outcome: .correct, assisted: input == .midi, played: [60, 64], target: [60, 64]))
        }
        journal.append(
            PracticeAttempt(
                sessionID: session, activityID: "third", title: "Third", skills: ["Intervals"], input: .choice,
                outcome: .revealed, assisted: true))
        XCTAssertEqual(journal.checked.count, PracticeInput.allCases.count)
        XCTAssertEqual(journal.unassistedCorrect, PracticeInput.allCases.count - 1)
        XCTAssertEqual(journal.sessionCount, 1)
        XCTAssertEqual(journal.observations(skill: "Intervals", input: .midi).count, 1)
        XCTAssertEqual(journal.observations(skill: "Intervals", input: .tapping).count, 1)
        let copy = try JSONDecoder().decode(PracticeJournal.self, from: JSONEncoder().encode(journal)).restored()
        XCTAssertEqual(copy, journal)
    }
    func testPracticeJournalRejectsInvalidEvidenceDeduplicatesAndBoundsHistory() throws {
        var journal = PracticeJournal()
        let a = PracticeAttempt(
            sessionID: UUID(), activityID: "a", title: "A", skills: ["A"], input: .midi, outcome: .incorrect)
        journal.append(a)
        journal.append(a)
        XCTAssertEqual(journal.attempts.count, 1)
        var invalid = a
        invalid.id = UUID()
        invalid.played = [200]
        journal.append(invalid)
        XCTAssertEqual(journal.attempts.count, 1)
        for i in 0..<10002 {
            journal.append(
                PracticeAttempt(
                    sessionID: a.sessionID, activityID: "\(i)", title: "A", skills: ["A"], input: .choice,
                    outcome: .skipped))
        }
        XCTAssertEqual(journal.attempts.count, 10000)
        XCTAssertEqual(journal.attempts.first?.activityID, "2")
    }
    func testPracticeEvidenceDistinguishesFirstTryRetriesAndRevealedAnswers() throws {
        var journal = PracticeJournal()
        let session = UUID()
        for (ordinal, assisted, outcome) in [
            (1, false, PracticeOutcome.incorrect), (2, false, .correct), (1, true, .correct), (1, false, .correct),
        ] {
            journal.append(
                PracticeAttempt(
                    sessionID: session, activityID: "triad", title: "C major", skills: ["Chord spelling"],
                    input: .choice, outcome: outcome, assisted: assisted, ordinal: ordinal, selectedChoice: "C E G",
                    expectedChoice: "C E G"))
        }
        XCTAssertEqual(journal.firstTryCorrect, 1)
        XCTAssertEqual(journal.unassistedCorrect, 2)
        let copy = try JSONDecoder().decode(PracticeJournal.self, from: JSONEncoder().encode(journal)).restored()
        XCTAssertEqual(copy, journal)
        XCTAssertEqual(copy.attempts.last?.selectedChoice, "C E G")
        var invalid = journal.attempts[0]
        invalid.id = UUID()
        invalid.ordinal = 0
        journal.append(invalid)
        XCTAssertEqual(journal.attempts.count, 4)
        invalid.ordinal = 1
        invalid.responseSeconds = -.infinity
        journal.append(invalid)
        XCTAssertEqual(journal.attempts.count, 4)
    }
    func testEarlierDetailedHistoryWithoutOptionalEvidenceFieldsStillLoads() throws {
        let attempt = PracticeAttempt(
            sessionID: UUID(), activityID: "triad", title: "C major", skills: ["Chord spelling"], input: .choice,
            outcome: .correct)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(attempt)) as? [String: Any])
        for field in ["ordinal", "responseSeconds", "selectedChoice", "expectedChoice"] {
            fields.removeValue(forKey: field)
        }
        let decoded = try JSONDecoder().decode(
            PracticeAttempt.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertTrue(decoded.valid)
        XCTAssertNil(decoded.ordinal)
        var journal = PracticeJournal()
        journal.append(decoded)
        XCTAssertEqual(journal.firstTryCorrect, 0)
    }
}
