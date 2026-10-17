// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class SingingTests: XCTestCase {
    private func interval(_ semitones: Int) throws -> SingingInterval {
        try XCTUnwrap(
            IntervalSingingFactory.deck(root: Pitch(0), scale: .major, set: .chromatic).first {
                $0.singingInterval?.semitones == semitones
            }?.singingInterval)
    }
    func testMovableDoAndDoBasedMinor() {
        XCTAssertEqual(
            Solfege.notes(root: Pitch(1), scale: .major).map(\.solfege), ["Do", "Re", "Mi", "Fa", "Sol", "La", "Ti"])
        XCTAssertEqual(
            Solfege.notes(root: Pitch(5), scale: .minor).map(\.solfege), ["Do", "Re", "Me", "Fa", "Sol", "Le", "Te"])
        XCTAssertEqual(
            Solfege.notes(root: Pitch(1), scale: .dorian).map(\.solfege), ["Do", "Re", "Me", "Fa", "Sol", "La", "Te"])
        XCTAssertEqual(
            Solfege.notes(root: Pitch(3), scale: .lydian).map(\.solfege), ["Do", "Re", "Mi", "Fi", "Sol", "La", "Ti"])
        XCTAssertEqual(
            Solfege.notes(root: Pitch(6), scale: .locrian).map(\.solfege), ["Do", "Ra", "Me", "Fa", "Se", "Le", "Te"])
        XCTAssertEqual(
            Solfege.notes(root: Pitch(0), scale: .blues).map(\.solfege), ["Do", "Me", "Fa", "Se", "Sol", "Te"])
    }
    func testSyllablesFollowSpellingAndOctavesAreCorrect() {
        XCTAssertEqual(Solfege.syllable(degree: 4, alteration: 1), "Fi")
        XCTAssertEqual(Solfege.syllable(degree: 5, alteration: -1), "Se")
        XCTAssertEqual(Solfege.noteName(midi: 59, pitch: Pitch(0, -1)), "C♭4")
        XCTAssertEqual(Solfege.noteName(midi: 60, pitch: Pitch(6, 1)), "B♯3")
        for root in Pitch.roots {
            for scale in Scale.allCases {
                let notes = Solfege.notes(root: root, scale: scale, octave: 3)
                XCTAssertEqual(notes.map { $0.pitch.pc }, scale.notes(root).map(\.pc))
                XCTAssertEqual(notes.map(\.degreeLabel), scale.formula)
                XCTAssertTrue(notes.allSatisfy { mod($0.midi) == $0.pitch.pc })
                XCTAssertFalse(notes.contains { $0.solfege.isEmpty })
            }
        }
    }
    func testChromaticIntervalsHaveTwoOrderedNotesInBothDirections() throws {
        for root in Pitch.roots {
            let questions = IntervalSingingFactory.deck(root: root, scale: .major, set: .chromatic)
            XCTAssertEqual(questions.count, 24)
            XCTAssertEqual(Set(questions.map(\.id)).count, 24)
            XCTAssertEqual(
                Set(questions.compactMap { $0.singingInterval?.semitones }), Set(Array(-12 ... -1) + Array(1...12)))
            for question in questions {
                let interval = try XCTUnwrap(question.singingInterval)
                let score = try XCTUnwrap(question.audio)
                XCTAssertNoThrow(try score.validated())
                XCTAssertEqual(score.notes.map(\.midi), [interval.first.midi, interval.second.midi])
                XCTAssertLessThan(score.notes[0].start + score.notes[0].duration, score.notes[1].start)
                XCTAssertEqual(question.target, interval.second.midi)
                XCTAssertEqual(question.singingNotes, [interval.first, interval.second])
            }
        }
    }
    func testScaleIntervalsFollowModesAndDirectionFilters() {
        let questions = IntervalSingingFactory.deck(root: Pitch(1), scale: .dorian, direction: .ascending)
        XCTAssertEqual(questions.compactMap { $0.singingInterval?.semitones }, [2, 3, 5, 7, 9, 10, 12])
        XCTAssertEqual(
            questions.compactMap { $0.singingInterval?.second.singingLabel },
            ["Re", "Me", "Fa", "Sol", "La", "Te", "Do′"])
        let descending = IntervalSingingFactory.deck(root: Pitch(1), scale: .dorian, direction: .descending)
        XCTAssertEqual(descending.compactMap { $0.singingInterval?.semitones }, [-2, -3, -5, -7, -9, -10, -12])
        XCTAssertTrue(descending.allSatisfy { $0.singingInterval?.second.solfege == "Do" })
    }
    func testChecksDistanceBetweenBothNotesRatherThanLastPitch() throws {
        let fifth = try interval(7)
        var attempt = IntervalEchoAttempt()
        XCTAssertEqual(attempt.hear(61, for: fifth), .firstNote(61))
        XCTAssertEqual(attempt.hear(67, for: fifth), .wrongInterval(6))
        XCTAssertFalse(attempt.complete)
        XCTAssertEqual(attempt.hear(68, for: fifth), .correct)
        XCTAssertTrue(attempt.complete)
    }
    func testAllowsTranspositionAndChecksDirectionAndCompoundDistance() throws {
        var attempt = IntervalEchoAttempt()
        let third = try interval(4)
        XCTAssertEqual(attempt.hear(57, for: third), .firstNote(57))
        XCTAssertEqual(attempt.hear(61, for: third), .correct)
        attempt.reset()
        _ = attempt.hear(60, for: third)
        XCTAssertEqual(attempt.hear(56, for: third), .wrongInterval(-4))
        XCTAssertEqual(attempt.hear(76, for: third), .wrongInterval(16))
        attempt.reset()
        let descending = try interval(-4)
        _ = attempt.hear(64, for: descending)
        XCTAssertEqual(attempt.hear(60, for: descending), .correct)
    }
    func testOneHeldNoteCannotCountAsTwoAndCompletionCannotRepeat() throws {
        let octave = try interval(12)
        var attempt = IntervalEchoAttempt()
        XCTAssertEqual(attempt.hear(60, for: octave), .firstNote(60))
        XCTAssertEqual(attempt.hear(60, for: octave), .ignored)
        XCTAssertFalse(attempt.complete)
        XCTAssertEqual(attempt.hear(72, for: octave), .correct)
        XCTAssertEqual(attempt.hear(72, for: octave), .ignored)
        XCTAssertEqual(attempt.hear(84, for: octave), .ignored)
    }
    func testReferenceMatchingAcceptsSharedOctaveShift() throws {
        let third = try interval(4)
        var attempt = IntervalEchoAttempt()
        XCTAssertEqual(attempt.hear(61, for: third, matchReference: true), .wrongReference(61))
        XCTAssertNil(attempt.firstHeard)
        XCTAssertEqual(attempt.hear(60, for: third, matchReference: true), .firstNote(60))
        XCTAssertEqual(attempt.hear(64, for: third, matchReference: true), .correct)
    }
    func testSyntheticTwoNotePitchDetectionFeedsIntervalCheck() throws {
        let third = try interval(4)
        var attempt = IntervalEchoAttempt()
        var results: [IntervalEchoResult] = []
        for midi in [48, 52] {
            let frequency = 440 * pow(2, Double(midi - 69) / 12)
            let samples: [Float] = (0..<4096).map { index in
                let phase = 2 * Double.pi * frequency * Double(index) / 12000
                return Float(0.35 * sin(phase) + 0.12 * sin(phase * 2) + 0.04 * sin(phase * 3))
            }
            let pitch = try XCTUnwrap(PitchDetector.detect(samples, sampleRate: 12000))
            XCTAssertEqual(pitch.midi, midi)
            results.append(attempt.hear(pitch.midi, for: third))
        }
        XCTAssertEqual(results, [.firstNote(48), .correct])
    }
    func testFunctionalQuestionsHaveCorrectSingingLabels() {
        for scale in [Scale.major, .minor] {
            let questions = QuestionFactory.deck(.functional, root: Pitch(1), scale: scale)
            for question in questions {
                XCTAssertEqual(question.singingNotes?.count, question.choices.count)
                XCTAssertEqual(question.singingNotes?[question.answer].midi, question.target)
            }
        }
        XCTAssertEqual(PathwayTool.singIntervals.exercise, .intervals)
    }
}
