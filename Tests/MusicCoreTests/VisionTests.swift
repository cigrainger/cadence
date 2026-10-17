// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class VisionTests: XCTestCase {
    func testCanonicalFixturesReopenAndWrittenGuitarDoesNotDuplicateTab() throws {
        for doc in [EditorDocument.guitarExample, .innerVoiceExample, VisionExamples.compound] {
            _ = try doc.validated()
            _ = try EditorXML.decode(Data(EditorXML.encode(doc).utf8))
            let expected = VisionTranscription(doc)
            _ = try expected.validated()
            XCTAssertEqual(expected.notes.count, doc.events.reduce(0) { $0 + max(1, $1.pitches.count) })
            let comparison = expected.compare(to: expected)
            XCTAssertEqual(comparison.exactF1, 1)
            XCTAssertEqual(comparison.pitchOnsetF1, 1)
            XCTAssertTrue(comparison.meterCorrect)
            XCTAssertTrue(comparison.keyCorrect)
        }
        XCTAssertEqual(VisionTranscription(.guitarExample).notes[0].midi, 72)
    }
    func testComparisonCountsMissingExtraDuplicatesAndRhythmVoiceMistakesSeparately() throws {
        let expected = VisionTranscription(.pianoExample)
        var actual = expected
        actual.notes[0].duration *= 2
        actual.notes[1].voice = 2
        XCTAssertEqual(actual.compare(to: expected).pitchOnsetF1, 1)
        XCTAssertLessThan(actual.compare(to: expected).exactF1, 1)
        actual = expected
        actual.notes.append(actual.notes[0])
        XCTAssertEqual(actual.compare(to: expected).exactMatches, expected.notes.count)
        XCTAssertLessThan(actual.compare(to: expected).exactF1, 1)
        actual.notes.removeFirst(2)
        XCTAssertLessThan(actual.compare(to: expected).pitchOnsetF1, 1)
    }
    func testMalformedModelOutputCannotBecomeValidScore() throws {
        XCTAssertThrowsError(try VisionTranscription.decode("Here is a score"))
        var value = VisionTranscription(.pianoExample)
        value.notes[0].duration = -1
        XCTAssertThrowsError(try value.validated())
        value = VisionTranscription(.pianoExample)
        value.notes[0].midi = 200
        XCTAssertThrowsError(try value.validated())
        let json = String(data: try JSONEncoder().encode(VisionTranscription(.pianoExample)), encoding: .utf8)!
        XCTAssertEqual(try VisionTranscription.decode("```json\n" + json + "\n```"), VisionTranscription(.pianoExample))
    }
}
