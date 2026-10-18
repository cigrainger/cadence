// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class PickingTests: XCTestCase {
    func material(bars: Int = 4) throws -> PickingMaterial {
        var score = try EditorDocument.blank(instrument: .guitar, bars: bars, meter: .init(4, 4))
        score.harmonies = try ["C", "Am", "F", "G"].prefix(bars).enumerated().map {
            .init(bar: $0.offset, symbol: try .parse($0.element))
        }
        return try PickingMaterial(
            piece: .init(source: .score(score)), scope: .init(partID: "P1", staff: 1, from: 0, through: bars - 1),
            tuning: .presets[0], capo: 0)
    }
    func testThreeStylesShareScoreTabPlaybackAndDistinctRhythms() throws {
        let material = try material()
        XCTAssertTrue(material.frets.allSatisfy { ($0.max() ?? 99) <= 3 }, "Keep these familiar changes near the nut")
        var fingerprints = Set<String>()
        for style in PickingStyle.allCases {
            let document = try material.document(style: style)
            XCTAssertEqual(document.events.count, 32)
            XCTAssertEqual(document.pickingSource, material)
            let xml = try EditorXML.encode(document)
            XCTAssertTrue(xml.contains("<sign>TAB</sign>"))
            XCTAssertTrue(xml.contains("<words font-size="))
            XCTAssertTrue(xml.contains("<string>"))
            let score = document.playback()
            XCTAssertFalse(score.notes.isEmpty)
            XCTAssertEqual(Set(score.notes.map(\.midi)), Set(document.events.flatMap(\.pitches).map(\.midi)))
            XCTAssertEqual(score.notes.count, document.events.flatMap(\.pitches).count)
            XCTAssertTrue(score.notes.allSatisfy { $0.start < 16 && $0.duration > 0 })
            fingerprints.insert(ScoreRevision.digest(score.notes.map { "\($0.midi):\($0.start)" }.joined()))
            XCTAssertEqual(
                try JSONDecoder().decode(EditorDocument.self, from: JSONEncoder().encode(document)), document)
        }
        XCTAssertEqual(fingerprints.count, 3)
    }
    func testStrummingRestsAndTravisBassOnBeats() throws {
        let m = try material(bars: 1)
        let strum = try m.document(style: .strumming)
        XCTAssertEqual(strum.events.indices.filter { strum.events[$0].isRest }, [1, 4])
        XCTAssertEqual(strum.events.compactMap(\.picking), ["↓", "↓", "↑", "↑", "↓", "↑"])
        let travis = try m.document(style: .travis)
        let bass = m.frets[0].indices.first { m.frets[0][$0] >= 0 }!
        let alternate = m.frets[0].indices.first { $0 > bass && m.frets[0][$0] >= 0 }!
        XCTAssertEqual(
            [0, 2, 4, 6].map { travis.events[$0].pitches.first!.string }, [bass, alternate, bass, alternate])
    }
    func testBadStringsRangesCueAndSourceAreRejected() throws {
        var m = try material()
        m.frets[0][0] = 200
        XCTAssertFalse(m.valid)
        XCTAssertThrowsError(try m.document(style: .travis))
        m = try material()
        m.scope.through = Int.max
        XCTAssertFalse(m.valid)
        var d = try material().document(style: .classical)
        d.events[0].picking = "<script>"
        XCTAssertThrowsError(try d.validated())
        XCTAssertThrowsError(try EditorXML.encode(d))
    }
    func testMidbarAndWrongMeterDoNotGetSilentlyConverted() throws {
        var d = try EditorDocument.blank(instrument: .piano, bars: 1, meter: .init(4, 4))
        d.harmonies = [try .init(bar: 0, tick: 480, symbol: .parse("C"))]
        let scope = PassageScope(partID: "P1", staff: 1, from: 0, through: 0)
        XCTAssertThrowsError(
            try PickingMaterial(piece: .init(source: .score(d)), scope: scope, tuning: .presets[0], capo: 0))
        d = try EditorDocument.blank(instrument: .guitar, bars: 1, meter: .init(3, 4))
        d.harmonies = [try .init(bar: 0, symbol: .parse("C"))]
        XCTAssertThrowsError(
            try PickingMaterial(piece: .init(source: .score(d)), scope: scope, tuning: .presets[0], capo: 0))
    }
    func testGradualPassAndIndependentSelfReportStayDistinct() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var session = try PickingSession(material: material(), style: .travis)
        for _ in 0..<5 { XCTAssertTrue(try session.apply(.tried, now: start).assisted) }
        XCTAssertEqual(session.stage, .complete)
        XCTAssertEqual(session.review.lastGrade, .supported)
        session.beginReturn()
        XCTAssertEqual(session.stage, .independent)
        let answer = try session.apply(.tried, now: start.addingTimeInterval(86400))
        XCTAssertFalse(answer.assisted)
        XCTAssertEqual(answer.input, .selfReport)
        XCTAssertEqual(answer.outcome, .revealed)
        XCTAssertEqual(session.review.lastInput, .selfReport)
        XCTAssertEqual(session.review.lastGrade, .good)
        XCTAssertThrowsError(try session.apply(.tried, now: start))
        session.beginReturn()
        _ = try session.apply(.reveal, now: start.addingTimeInterval(172800))
        XCTAssertTrue(try session.apply(.tried, now: start.addingTimeInterval(172801)).assisted)
        XCTAssertEqual(session.review.lastGrade, .supported)
    }
    func testOneChordAndAccentAdaptationPreserveOriginalMaterial() throws {
        let m = try material()
        let held = try m.document(style: .classical, oneChord: true)
        XCTAssertTrue(held.harmonies.allSatisfy { $0.symbol == m.chords[0] })
        let adapted = try m.document(style: .travis, strongerBackbeat: true)
        XCTAssertEqual(adapted.events.filter(\.accent).count, 8)
        XCTAssertEqual(adapted.harmonies.map(\.symbol), m.chords)
    }
}

extension PickingTests {
    func testUnsupportedPassageAndExtremeRangesFailBeforeIndexing() throws {
        var d = try EditorDocument.blank(instrument: .guitar, bars: 1, meter: .init(4, 4))
        for symbol in ["N.C.", "C"] {
            d.harmonies = [try .init(bar: 0, symbol: .parse(symbol))]
            XCTAssertThrowsError(
                try PickingMaterial(
                    piece: .init(source: .score(d)),
                    scope: .init(partID: "P1", staff: 1, from: Int.min, through: Int.max), tuning: .presets[0], capo: 0)
            )
        }
        d.harmonies = []
        XCTAssertThrowsError(
            try PickingMaterial(
                piece: .init(source: .score(d)), scope: .init(partID: "P1", staff: 1, from: 0, through: 0),
                tuning: .presets[0], capo: 0))
    }
    func testRetrySkipObservationAndBookValidation() throws {
        var session = try PickingSession(material: material(), style: .travis)
        let now = Date()
        _ = try session.apply(.needsWork, now: now)
        XCTAssertEqual(session.stage, .hear)
        XCTAssertEqual(session.review.lastGrade, .again)
        _ = try session.apply(.skip, now: now)
        _ = try session.apply(.tried, now: now)
        XCTAssertEqual(session.stage, .chord)
        let shape = session.material.frets[0]
        let string = shape.indices.first { shape[$0] >= 0 }!
        let target = session.material.tuning.pitches[string] + shape[string]
        let frames = (0..<5).map { i in
            PerformanceObservation(
                sampleTime: Int64(i * 4096), hostSeconds: nil, sampleRate: 48000, frameCount: 4096, rms: 0.1,
                clippedFraction: 0, frequency: 110, confidence: 0.95)
        }
        let take = MonophonicTake(target: target, frames: frames)
        XCTAssertEqual(try session.apply(.observation(take), now: now).input, .microphone)
        XCTAssertEqual(session.stage, .chord)
        _ = try session.apply(.observation(take), now: now)
        XCTAssertEqual(session.takes.count, 1)
        XCTAssertThrowsError(try session.apply(.observation(.init(target: 108, frames: frames)), now: now))
        var book = PickingPractice()
        book.sessions = [session]
        book.activeID = session.id
        XCTAssertNoThrow(try book.validated())
        book.sessions.append(session)
        XCTAssertThrowsError(try book.validated())
        book.sessions = [session]
        book.activeID = UUID()
        XCTAssertThrowsError(try book.validated())
        var legacy = PracticeState()
        legacy.schemaVersion = 15
        XCTAssertNil(try legacy.validated().picking)
        XCTAssertEqual(try legacy.validated().schemaVersion, 18)
        var document = try material().document(style: .travis)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        json["schemaVersion"] = 8
        json.removeValue(forKey: "pickingSource")
        json.removeValue(forKey: "pickingStyle")
        document = try JSONDecoder().decode(EditorDocument.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(document.schemaVersion, 9)
        XCTAssertNil(document.pickingSource)
    }
}

extension PickingTests {
    func testEveryStylePreservesTheWrittenJazzColourTones() throws {
        var score = try EditorDocument.blank(instrument: .guitar, bars: 4, meter: .init(4, 4))
        score.harmonies = try ["Dm7", "G7", "Cmaj7", "Am7"].enumerated().map {
            try .init(bar: $0.offset, symbol: .parse($0.element))
        }
        let material = try PickingMaterial(
            piece: .init(source: .score(score)), scope: .init(partID: "P1", staff: 1, from: 0, through: 3),
            tuning: .presets[0], capo: 0)
        for style in PickingStyle.allCases {
            let document = try material.document(style: style)
            for bar in 0..<4 {
                let actual = Set(document.inBar(bar, staff: 1).flatMap(\.pitches).map { mod($0.midi) })
                let target = try ChordRealization(material.chords[bar]).target(.complete).pitchClasses
                XCTAssertEqual(actual, target, "\(style.rawValue), bar \(bar + 1)")
            }
        }
    }
}
