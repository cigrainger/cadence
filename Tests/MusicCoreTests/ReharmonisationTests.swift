// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class ReharmonisationTests: XCTestCase {
    func source(_ doc: EditorDocument? = nil, from: Int = 0) throws -> ReharmSource {
        try .init(
            piece: .init(source: .score(doc ?? ReharmSource.example())),
            scope: .init(partID: "P1", staff: 1, from: from, through: 3), tonic: Pitch(0))
    }
    func session() throws -> ReharmSession { .init(source: try source(), instrument: .piano, substituteSlot: 1) }
    func take() throws -> ReharmTake {
        let s = try session()
        return .init(
            sessionID: s.id, source: s.source, version: .substitute, tempo: 84, offsetMS: 0,
            recording: .init(
                events: [
                    PianoEvent(.noteOn(channel: 0, note: 64, velocity: 80), seconds: 6)!,
                    PianoEvent(.noteOff(channel: 0, note: 64), seconds: 7)!,
                ], end: s.source.length * 60 / 84))
    }
    func testOriginalExampleAndSharedGuideToneRoles() throws {
        let s = try source()
        XCTAssertTrue(s.valid)
        XCTAssertEqual(s.pair, 1)
        XCTAssertEqual(s.substitute.label, "D♭7")
        XCTAssertEqual(s.length, 16)
        let a = try ChordRealization(s.dominant).tones
        let b = try ChordRealization(s.substitute).tones
        XCTAssertEqual(a.first { $0.degree == 3 }?.pitch.pc, b.first { $0.degree == 7 }?.pitch.pc)
        XCTAssertEqual(a.first { $0.degree == 7 }?.pitch.pc, b.first { $0.degree == 3 }?.pitch.pc)
        XCTAssertEqual(b.first { $0.degree == 7 }?.pitch.name, "C♭")
    }
    func testControlledComparisonOnlyChangesBassAndKeepsAllTiming() throws {
        let s = try source()
        let a = try s.accompaniment(.original)
        let b = try s.accompaniment(.substitute)
        XCTAssertEqual(a.notes.count, b.notes.count)
        XCTAssertEqual(zip(a.notes, b.notes).filter { $0.midi != $1.midi }.count, 1)
        for (x, y) in zip(a.notes, b.notes) {
            XCTAssertEqual(x.start, y.start)
            XCTAssertEqual(x.duration, y.duration)
        }
        let bass = try s.accompaniment(.substitute, layer: .bass).notes
        XCTAssertEqual(bass[s.pair].midi, bass[s.pair + 1].midi + 1)
        XCTAssertEqual(try s.guideVoicings(.original), try s.guideVoicings(.substitute))
        XCTAssertEqual(try s.accompaniment(.original, layer: .guides).notes.count, 6)
        XCTAssertThrowsError(try s.accompaniment(.original, tempo: 0))
    }
    func testAllTwelveRootRelationshipsAndBassCrossingOctave() throws {
        for pc in 0..<12 {
            var d = try ReharmSource.example()
            let root = Pitch.spelled(pc, flats: true)
            let dom = root.transposed(semitones: 7, steps: 4)
            d.harmonies = [
                .init(bar: 0, symbol: .init(root: dom, kind: .dominant)),
                .init(bar: 1, symbol: .init(root: root, kind: .majorSeventh)),
            ]
            let s = try source(d)
            let bass = try s.accompaniment(.substitute, layer: .bass).notes
            XCTAssertEqual(mod(s.substitute.root!.pc - root.pc), 1)
            XCTAssertEqual(bass[0].midi, bass[1].midi + 1)
        }
    }
    func testIneligibleAndCorruptSourcesFailWithoutTraps() throws {
        for chord in ["Gmaj7", "Gsus4", "N.C.", "G"] {
            var doc = try ReharmSource.example()
            doc.harmonies[1].symbol = try .parse(chord)
            XCTAssertThrowsError(try source(doc))
        }
        let s = try source()
        for corrupt: (inout ReharmSource) -> Void in [
            { $0.pair = Int.max }, { $0.scope.from = Int.min }, { $0.scope.through = Int.max },
            { $0.barTicks = [Int.max] }, { $0.changes[0].symbol.root?.letter = 99 }, { $0.tonic.letter = 99 },
            { $0.changes[1].bar = 999 }, { $0.changes[1].tick = 5000 }, { $0.changes[1] = $0.changes[0] },
            { $0.barTicks = [] },
        ] {
            var bad = s
            corrupt(&bad)
            XCTAssertFalse(bad.valid)
            XCTAssertThrowsError(try bad.accompaniment(.original))
        }
    }
    func testReviewedGateIncludesCarriedChordAndReplacementStartsAtSelection() throws {
        var doc = try ReharmSource.example()
        doc.harmonies = try ["G7", "Cmaj7"].enumerated().map {
            .init(bar: $0.offset * 2, symbol: try .parse($0.element))
        }
        doc.pdfSource = .init(filename: "Source.pdf", page: 2, model: "fixture")
        XCTAssertThrowsError(try source(doc, from: 1))
        doc.pdfSource?.reviewed = true
        let s = try source(doc, from: 1)
        let alternative = try s.alternative(in: .init(source: .score(doc)))
        XCTAssertEqual(s.beat(0), 0)
        XCTAssertEqual(s.beat(1), 4)
        XCTAssertEqual(alternative.harmonies.first { $0.bar == 0 }?.symbol.label, "G7")
        XCTAssertEqual(alternative.harmonies.first { $0.bar == 1 }?.symbol.label, "D♭7")
    }
    func testSaveAlternativePreservesFullScoreNotesAndOriginal() throws {
        let doc = try ReharmSource.example()
        let piece = LibraryPiece(source: .score(doc))
        let s = try source(doc)
        let answer = try s.alternative(in: piece)
        XCTAssertEqual(answer.events, doc.events)
        XCTAssertEqual(answer.barCount, doc.barCount)
        XCTAssertNotEqual(answer.id, doc.id)
        XCTAssertEqual(answer.harmonies.map(\.symbol.label), ["Dm7", "D♭7", "Cmaj7"])
        XCTAssertEqual(doc.harmonies[1].symbol.label, "G7")
        XCTAssertEqual(answer.reharmSource, s)
        XCTAssertEqual(try JSONDecoder().decode(EditorDocument.self, from: JSONEncoder().encode(answer)), answer)
    }
    func testImportedMusicXMLKeepsNotesInEditableAlternative() throws {
        let doc = try ReharmSource.example()
        let study = MusicStudy(
            document: try StudyImport.read(Data(EditorXML.encode(doc).utf8)), filename: "Example.musicxml")
        let piece = LibraryPiece(source: .study(study))
        let s = try ReharmSource(
            piece: piece, scope: .init(partID: study.partID, staff: 1, from: 0, through: 3), tonic: Pitch(0))
        let copy = try s.alternative(in: piece)
        XCTAssertEqual(copy.barCount, 4)
        XCTAssertEqual(copy.events.filter { $0.staff == 1 }.flatMap(\.pitches).map(\.midi), [65, 65, 64, 71])
        XCTAssertEqual(copy.harmonies[1].symbol.label, "D♭7")
    }
    func testMelodyAndRevisionAreBoundToOriginal() throws {
        var doc = try ReharmSource.example()
        let s = try source(doc)
        let piece = LibraryPiece(source: .score(doc))
        XCTAssertEqual(try s.writtenMelody(in: piece).map(\.midi), [65, 65, 64, 71])
        doc.title = "Renamed"
        XCTAssertTrue(s.current(in: .init(source: .score(doc))))
        doc.harmonies[0].symbol = try .parse("Dm9")
        XCTAssertFalse(s.current(in: .init(source: .score(doc))))
        XCTAssertThrowsError(try s.alternative(in: .init(source: .score(doc))))
        XCTAssertThrowsError(try s.writtenMelody(in: .init(source: .score(doc))))
    }
    func testExtendedSourceIsPreservedExceptExplicitSubstitution() throws {
        var doc = try ReharmSource.example()
        doc.harmonies[1].symbol = try .parse("G7b9/B")
        let s = try source(doc)
        let alt = try s.alternative(in: .init(source: .score(doc)))
        XCTAssertEqual(s.dominant, doc.harmonies[1].symbol)
        XCTAssertEqual(alt.harmonies[1].symbol, s.substitute)
        XCTAssertNil(alt.harmonies[1].symbol.bass)
        XCTAssertTrue(alt.harmonies[1].symbol.degrees.isEmpty)
    }
    func testHearingRequiresBothAndRetriesStaySupported() throws {
        var s = try session()
        s.beginReview(.hearing)
        s.substituteSlot = 1
        XCTAssertThrowsError(try s.apply(.hearing(1)))
        XCTAssertThrowsError(try s.apply(.heard(2)))
        _ = try s.apply(.heard(0))
        _ = try s.apply(.heard(1))
        XCTAssertEqual(try s.apply(.hearing(0))?.outcome, .incorrect)
        XCTAssertFalse(s.completed)
        XCTAssertTrue(try s.apply(.hearing(1))!.assisted)
        XCTAssertTrue(s.completed)
        XCTAssertEqual(s.reviews[TheorySkill.hearing.rawValue]?.lastGrade, .again)
    }
    func testFourSkillsStaySeparateAndIndependentReturnAdvancesOnlyOne() throws {
        var s = try session()
        for _ in 0..<4 { _ = try s.apply(.skip, now: Date(timeIntervalSince1970: 1000)) }
        let before = s.reviews
        s.beginReview(.explaining, now: Date(timeIntervalSince1970: 100000))
        let evidence = try s.apply(.explanation(0), now: Date(timeIntervalSince1970: 100001))!
        XCTAssertFalse(evidence.assisted)
        XCTAssertEqual(s.reviews[TheorySkill.explaining.rawValue]?.intervalDays, 1)
        for skill in [TheorySkill.hearing, .playing, .creating] {
            XCTAssertEqual(s.reviews[skill.rawValue], before[skill.rawValue])
        }
        XCTAssertThrowsError(try s.apply(.skip))
    }
    func testGuideToneExerciseAcceptsInversionsAndDoublingButRejectsExtraTone() throws {
        var s = try session()
        _ = try s.apply(.skip)
        _ = try s.apply(.skip)
        XCTAssertThrowsError(try s.apply(.guides([])))
        XCTAssertThrowsError(try s.apply(.guides(Array(repeating: Array(repeating: 65, count: 9), count: 3))))
        XCTAssertEqual(try s.apply(.guides([[65, 72], [65, 71, 67], [64, 71]]))?.outcome, .incorrect)
        let result = try s.apply(.guides([[72, 65, 77], [71, 65], [83, 76]]))!
        XCTAssertEqual(result.outcome, .correct)
        XCTAssertTrue(result.assisted)
        XCTAssertEqual(s.skill, .creating)
        XCTAssertEqual(result.pieceID, s.source.pieceID)
        XCTAssertEqual(result.scoreFingerprint, s.source.fingerprint)
    }
    func testHintsAndSelfReportsNeverAdvanceIndependentMastery() throws {
        var s = try session()
        s.beginReview(.explaining)
        _ = try s.apply(.reveal)
        XCTAssertTrue(try s.apply(.explanation(0))!.assisted)
        XCTAssertEqual(s.reviews[TheorySkill.explaining.rawValue]?.intervalDays, 0)
        s.instrument = .guitar
        s.beginReview(.playing)
        XCTAssertEqual(try s.apply(.guitarReport)?.input, .selfReport)
        XCTAssertEqual(s.reviews[TheorySkill.playing.rawValue]?.lastGrade, .supported)
        s.beginReview(.creating)
        XCTAssertThrowsError(try s.apply(.creation(" \n")))
        XCTAssertThrowsError(try s.apply(.creation(String(repeating: "x", count: 2001))))
        XCTAssertEqual(try s.apply(.creation("I left space before the arrival."))?.outcome, .revealed)
    }
    func testRawRecordingRoundTripPedalAndObservations() throws {
        var t = try take()
        XCTAssertTrue(t.valid)
        XCTAssertTrue(t.observation.contains("destination’s third"))
        t.recording.events.insert(PianoEvent(.control(channel: 0, number: 64, value: 127), seconds: 6.2)!, at: 1)
        XCTAssertTrue(t.valid)
        XCTAssertEqual(t.recording.notes.first?.soundEnd, t.recording.end)
        XCTAssertEqual(try JSONDecoder().decode(ReharmTake.self, from: JSONEncoder().encode(t)), t)
        t.recording.events[0].note = 66
        XCTAssertTrue(t.observation.contains("what note"))
    }
    func testTakeBoundsAndDuplicateSaveAreDefensive() throws {
        let t = try take()
        var book = ReharmPractice()
        book.sessions = [.init(source: t.source, instrument: .piano)]
        try book.append(t)
        try book.append(t)
        XCTAssertEqual(book.takes.count, 1)
        _ = try book.validated()
        var conflict = t
        conflict.tempo = 100
        XCTAssertThrowsError(try book.append(conflict))
        for corrupt: (inout ReharmTake) -> Void in [
            { $0.tempo = 0 }, { $0.offsetMS = Int.max }, { $0.recording.end = .infinity }, { $0.recording.events = [] },
            { $0.recording.events[0].seconds = -1 },
        ] {
            var bad = t
            corrupt(&bad)
            XCTAssertFalse(bad.valid)
            XCTAssertThrowsError(try book.append(bad))
        }
        book.sessions = []
        XCTAssertThrowsError(try book.validated())
    }
    func testStorageMigrationAndUnknownVersions() throws {
        let s = try session()
        var book = ReharmPractice()
        book.sessions = [s]
        book.activeID = s.id
        var state = PracticeState(reharm: book)
        XCTAssertEqual(
            try JSONDecoder().decode(PracticeState.self, from: JSONEncoder().encode(state)).validated(), state)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        json.removeValue(forKey: "reharm")
        json["schemaVersion"] = 14
        let old = try JSONDecoder().decode(PracticeState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.reharm)
        XCTAssertEqual(try old.validated().schemaVersion, 16)
        state.schemaVersion = 17
        XCTAssertThrowsError(try state.validated())
        book.sessions.append(s)
        XCTAssertThrowsError(try book.validated())
        var doc =
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(ReharmSource.example())) as! [String: Any]
        doc["schemaVersion"] = 7
        doc.removeValue(forKey: "reharmSource")
        let migrated = try JSONDecoder().decode(EditorDocument.self, from: JSONSerialization.data(withJSONObject: doc))
        XCTAssertNil(migrated.reharmSource)
        XCTAssertEqual(migrated.schemaVersion, 9)
    }
}
