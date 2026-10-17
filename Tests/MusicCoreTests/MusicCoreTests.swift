// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class MusicCoreTests: XCTestCase {
    func testScaleSpelling() {
        XCTAssertEqual(Scale.major.notes(Pitch(3, 1)).map(\.name), ["F♯", "G♯", "A♯", "B", "C♯", "D♯", "E♯"])
        XCTAssertEqual(Scale.dorian.notes(Pitch(1)).map(\.name), ["D", "E", "F", "G", "A", "B", "C"])
        XCTAssertEqual(Scale.major.notes(Pitch(1, -1)).map(\.name), ["D♭", "E♭", "F", "G♭", "A♭", "B♭", "C"])
        XCTAssertEqual(Scale.harmonicMinor.notes(Pitch(5)).map(\.name), ["A", "B", "C", "D", "E", "F", "G♯"])
        XCTAssertEqual(Scale.minorPentatonic.formula, ["1", "♭3", "4", "5", "♭7"])
        XCTAssertEqual(Scale.blues.formula, ["1", "♭3", "4", "♭5", "5", "♭7"])
    }
    func testAllScalesHaveCorrectPitchesAndDegrees() {
        for root in Pitch.roots {
            for scale in Scale.allCases {
                let notes = scale.notes(root)
                XCTAssertEqual(
                    notes.map(\.pc), scale.intervals.map { mod(root.pc + $0) }, "\(root.name) \(scale.rawValue)")
                XCTAssertEqual(notes.count, scale.formula.count)
                XCTAssertEqual(Set(notes.map(\.pc)).count, notes.count)
            }
        }
    }
    func testModalSignaturesAndRelativeKeys() {
        XCTAssertEqual(Scale.dorian.signature(Pitch(1)), 0)
        XCTAssertEqual(Scale.lydian.signature(Pitch(3)), 0)
        XCTAssertEqual(Scale.mixolydian.signature(Pitch(4)), 0)
        XCTAssertEqual(Scale.minor.signature(Pitch(5)), 0)
        XCTAssertEqual(Scale.major.signature(Pitch(3, 1)), 6)
        for major in Pitch.fifths {
            let minor = major.transposed(semitones: 9, steps: 5)
            XCTAssertEqual(Scale.major.signature(major), Scale.minor.signature(minor))
            XCTAssertTrue(Pitch.roots.contains(minor), "Circle minor \(minor.name) must be selectable")
        }
    }
    func testDiatonicChordsAndEnharmonics() {
        let chords = harmonize(root: Pitch(0), scale: .major)
        XCTAssertEqual(chords.map { $0.root.name + $0.quality.symbol }, ["C", "Dm", "Em", "F", "G", "Am", "Bdim"])
        XCTAssertEqual(chords.map(\.degree), ["I", "ii", "iii", "IV", "V", "vi", "vii°"])
        XCTAssertEqual(ChordQuality.diminished.notes(Pitch(6)).map(\.name), ["B", "D", "F"])
        XCTAssertEqual(ChordQuality.augmented.notes(Pitch(0, 1)).map(\.name), ["C♯", "E♯", "G♯♯"])
        XCTAssertTrue(harmonize(root: Pitch(0), scale: .majorPentatonic).isEmpty)
    }
    func testPlayableVoicingsAndCommonShapes() {
        let tuning = Tuning.presets[0]
        let c = Guitar.voicings(root: Pitch(0), quality: .major, tuning: tuning)
        XCTAssertFalse(c.isEmpty)
        XCTAssertEqual(c.first?.frets, [-1, 3, 2, 0, 1, 0])
        let combinations: [(Pitch, ChordQuality, Tuning, Int)] = [
            (Pitch(0), .major, tuning, 0), (Pitch(3), .major, tuning, 0), (Pitch(5), .minor, tuning, 0),
            (Pitch(1), .min7, tuning, 2), (Pitch(4), .dominant7, Tuning.presets[1], 0),
        ]
        for (root, quality, tuning, capo) in combinations {
            let voicings = Guitar.voicings(root: root, quality: quality, tuning: tuning, capo: capo)
            XCTAssertFalse(voicings.isEmpty)
            for voicing in voicings {
                XCTAssertEqual(Set(voicing.pitches.map { mod($0) }), Set(quality.intervals.map { mod(root.pc + $0) }))
                XCTAssertEqual(
                    voicing.pitches,
                    voicing.frets.enumerated().filter { $0.element >= 0 }.map {
                        tuning.pitches[$0.offset] + capo + $0.element
                    })
                let fretted = voicing.frets.filter { $0 > 0 }
                XCTAssertLessThanOrEqual((fretted.max() ?? 0) - (fretted.min() ?? 0), 3)
            }
        }
        let triads = Guitar.voicings(root: Pitch(0), quality: .major, tuning: tuning, triads: true)
        XCTAssertFalse(triads.isEmpty)
        XCTAssertTrue(triads.allSatisfy { $0.pitches.count == 3 })
    }
    func testGuitarPositionsRespectCapoAndPitch() {
        let positions = Guitar.positions(midi: 64, tuning: Tuning.presets[0], capo: 2)
        for position in positions { XCTAssertEqual(Tuning.presets[0].pitches[position.string] + 2 + position.fret, 64) }
        XCTAssertTrue(Guitar.positions(midi: 30, tuning: Tuning.presets[0]).isEmpty)
    }
    func testTriadStringSetsAndCustomTuning() {
        for group in 0...3 {
            let shapes = Guitar.voicings(
                root: Pitch(0), quality: .major, tuning: Tuning.presets[0], triads: true, stringGroup: group)
            XCTAssertFalse(shapes.isEmpty)
            XCTAssertTrue(
                shapes.allSatisfy {
                    Set($0.frets.enumerated().filter { $0.element >= 0 }.map(\.offset))
                        == Set((3 - group)...(5 - group))
                })
        }
        let custom = Tuning("All fourths", [40, 45, 50, 55, 60, 65])
        let shapes = Guitar.voicings(root: Pitch(1), quality: .minor, tuning: custom, capo: 2)
        XCTAssertFalse(shapes.isEmpty)
        XCTAssertTrue(shapes.allSatisfy { Set($0.pitches.map { mod($0) }) == Set([2, 5, 9]) })
    }
    func testQuestionDecks() {
        for exercise in Exercise.allCases {
            let deck = QuestionFactory.deck(exercise, root: Pitch(1), scale: .dorian)
            XCTAssertFalse(deck.isEmpty)
            XCTAssertEqual(Set(deck.map(\.id)).count, deck.count)
            for question in deck {
                XCTAssertTrue(question.choices.indices.contains(question.answer))
                XCTAssertEqual(Set(question.choices).count, question.choices.count)
                XCTAssertFalse(question.explanation.isEmpty)
                if let audio = question.audio { XCTAssertNoThrow(try audio.validated()) }
            }
        }
        let degrees = QuestionFactory.deck(.functional, root: Pitch(0), scale: .major)
        for (index, question) in degrees.enumerated() {
            XCTAssertEqual(question.answer, index)
            XCTAssertEqual(question.target, 60 + Scale.major.intervals[index])
            XCTAssertEqual(question.audio?.notes.last?.midi, question.target)
        }
        XCTAssertTrue(QuestionFactory.rhythmValues.allSatisfy { $0.reduce(0, +) == 4 })
    }
    func testSpacedReviewsAndRewards() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let deck = QuestionFactory.deck(.functional, root: Pitch(0), scale: .major)
        let question = deck[0]
        var progress = PracticeProgress()
        XCTAssertEqual(progress.record(question, correct: true, firstTry: true, revealed: false, now: now), 10)
        XCTAssertEqual(progress.xp, 10)
        XCTAssertEqual(progress.cards[question.id]?.due, now.addingTimeInterval(86400))
        XCTAssertEqual(progress.record(question, correct: false, firstTry: true, revealed: false, now: now), 0)
        XCTAssertEqual(progress.cards[question.id]?.misses, 1)
        XCTAssertEqual(progress.record(question, correct: true, firstTry: false, revealed: false, now: now), 4)
        XCTAssertEqual(progress.cards[question.id]?.due, now.addingTimeInterval(1200))
        XCTAssertEqual(progress.record(deck[1], correct: true, firstTry: false, revealed: true, now: now), 0)
        XCTAssertEqual(progress.days.count, 1)
        XCTAssertEqual(progress.dueCount(in: deck, now: now.addingTimeInterval(1300)), 2)
        XCTAssertNotEqual(progress.next(in: deck, avoiding: question.id, now: now)?.id, question.id)
        let saved = try JSONEncoder().encode(progress)
        let restored = try JSONDecoder().decode(PracticeProgress.self, from: saved)
        XCTAssertEqual(restored.xp, 14)
        XCTAssertEqual(restored.cards[question.id]?.due, progress.cards[question.id]?.due)
    }
    func testPitchDetectionAndSilence() {
        let rate = 12000.0
        for frequency in [82.4069, 110, 220, 440, 659.255, 1046.5] {
            let signal: [Float] = (0..<2048).map { index in
                let phase = 2 * Double.pi * frequency * Double(index) / rate
                return Float(0.4 * sin(phase) + 0.15 * sin(phase * 2) + 0.05 * sin(phase * 3))
            }
            guard let pitch = PitchDetector.detect(signal, sampleRate: rate) else {
                XCTFail("Missing pitch \(frequency)")
                continue
            }
            XCTAssertEqual(pitch.frequency, frequency, accuracy: frequency * 0.01)
            XCTAssertGreaterThan(pitch.confidence, 0.85)
        }
        XCTAssertNil(PitchDetector.detect([Float](repeating: 0, count: 2048), sampleRate: rate))
        var random: UInt64 = 42
        let noise: [Float] = (0..<2048).map { _ in
            random = random &* 6_364_136_223_846_793_005 &+ 1
            return Float(Int(random >> 48) - 32768) / 65536
        }
        XCTAssertNil(PitchDetector.detect(noise, sampleRate: rate))
    }
    func testScoreValidationAndMusicXMLRoundTrip() throws {
        let score = Score(
            title: "A & B",
            notes: [
                ScoreNote(midi: 60, start: 0, duration: 6, spelling: Pitch(0)),
                ScoreNote(midi: 64, start: 0, duration: 1), ScoreNote(midi: -1, start: 7, duration: 1),
            ])
        let xml = MusicXML.encode(score)
        XCTAssertTrue(xml.contains("A &amp; B"))
        let restored = try MusicXML.decode(Data(xml.utf8))
        XCTAssertEqual(restored.title, score.title)
        XCTAssertEqual(restored.notes.filter { $0.midi == 60 }.first?.duration, 6)
        XCTAssertEqual(restored.notes.filter { $0.midi == 64 }.first?.start, 0)
        var invalid = score
        invalid.tempo = 0
        XCTAssertThrowsError(try invalid.validated())
        invalid = score
        invalid.notes[0].start = .nan
        XCTAssertThrowsError(try invalid.validated())
        let midi = MIDIFile.encode(score)
        XCTAssertEqual(String(data: midi.prefix(4), encoding: .ascii), "MThd")
    }
}
