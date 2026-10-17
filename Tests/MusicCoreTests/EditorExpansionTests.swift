// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class EditorExpansionTests: XCTestCase {
    func testVersionOneSketchMigratesWithoutChangingNotesOrIdentities() throws {
        let original = EditorDocument.guitarExample
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json["schemaVersion"] = 1
        json.removeValue(forKey: "barCount")
        json.removeValue(forKey: "meter")
        json.removeValue(forKey: "minor")
        let migrated = try JSONDecoder().decode(EditorDocument.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(migrated, original)
        XCTAssertEqual(migrated.schemaVersion, 9)
        _ = try migrated.validated()
        json["schemaVersion"] = 99
        XCTAssertThrowsError(
            try JSONDecoder().decode(EditorDocument.self, from: JSONSerialization.data(withJSONObject: json)))
    }
    func testAllMetersRoundTripCompleteBarsForBothInstruments() throws {
        for meter in EditorMeter.choices {
            for instrument in EditorInstrument.allCases {
                var doc = try EditorDocument.blank(instrument: instrument, bars: 7, meter: meter)
                let first = doc.events[0].id
                try doc.setRhythm(first, EditorRhythm(240))
                try doc.setPitch(first, midi: 60)
                _ = try doc.validated()
                let imported = try EditorXML.decode(Data(EditorXML.encode(doc).utf8))
                XCTAssertEqual(imported.barCount, 7)
                XCTAssertEqual(imported.meter, meter)
                XCTAssertEqual(imported.playback().notes.map(\.midi), doc.playback().notes.map(\.midi))
                for staff in 1...doc.staffCount {
                    for bar in 0..<7 {
                        XCTAssertEqual(
                            imported.inBar(bar, staff: staff).map(\.rhythm), doc.inBar(bar, staff: staff).map(\.rhythm))
                    }
                }
            }
        }
    }
    func testInsertAndDeleteShiftBothHandsAndKeepInternalIdentities() throws {
        var doc = EditorDocument.pianoExample
        let original = doc
        try doc.insertBars(at: 1, count: 3)
        XCTAssertEqual(doc.barCount, 7)
        for event in original.events {
            let moved = try XCTUnwrap(doc.events.first { $0.id == event.id })
            XCTAssertEqual(moved.bar, event.bar + (event.bar >= 1 ? 3 : 0))
        }
        XCTAssertTrue(doc.events.filter { (1...3).contains($0.bar) }.allSatisfy(\.isRest))
        try doc.deleteBars(1...3)
        XCTAssertEqual(doc, original)
    }
    func testCopyPasteIncludesBothHandsAndRegeneratesEveryIdentity() throws {
        var doc = EditorDocument.pianoExample
        let passage = try doc.excerpt(0...1)
        let original = doc
        try doc.paste(passage, at: 2, inserting: true)
        XCTAssertEqual(doc.barCount, 6)
        for staff in 1...2 {
            let source = passage.ordered(staff: staff)
            let pasted = doc.ordered(staff: staff).filter { (2...3).contains($0.bar) }
            XCTAssertEqual(source.map(\.rhythm), pasted.map(\.rhythm))
            XCTAssertEqual(source.map { $0.pitches.map(\.midi) }, pasted.map { $0.pitches.map(\.midi) })
            XCTAssertTrue(Set(source.map(\.id)).isDisjoint(with: Set(pasted.map(\.id))))
            XCTAssertTrue(
                Set(source.flatMap(\.pitches).map(\.id)).isDisjoint(with: Set(pasted.flatMap(\.pitches).map(\.id))))
        }
        XCTAssertEqual(doc.events.first { $0.id == original.events[8].id }?.bar, 4)
    }
    func testReplacePasteExtendsAndRefingersWithoutChangingSoundingPitches() throws {
        var target = try EditorDocument.blank(instrument: .guitar, bars: 2)
        try target.setGuitar(tuning: Tuning("Drop D", [38, 45, 50, 55, 59, 64]), capo: 2)
        let source = EditorDocument.guitarExample
        try target.paste(source, at: 1, inserting: false)
        XCTAssertEqual(target.barCount, 5)
        XCTAssertEqual(
            target.events.filter { $0.bar > 0 }.flatMap(\.pitches).map(\.midi),
            source.events.flatMap(\.pitches).map(\.midi))
        _ = try target.validated()
    }
    func testIncompatiblePasteAndBarLimitsAreAtomic() throws {
        var doc = EditorDocument.guitarExample
        let original = doc
        XCTAssertThrowsError(try doc.paste(.pianoExample, at: 1, inserting: true))
        XCTAssertEqual(doc, original)
        let waltz = try EditorDocument.blank(instrument: .guitar, meter: EditorMeter(3, 4))
        XCTAssertThrowsError(try doc.paste(waltz, at: 1, inserting: true))
        XCTAssertEqual(doc, original)
        XCTAssertThrowsError(try doc.insertBars(at: 0, count: Int.max))
        XCTAssertEqual(doc, original)
        try doc.insertBars(at: 4, count: 124)
        XCTAssertEqual(doc.barCount, 128)
        let full = doc
        XCTAssertThrowsError(try doc.insertBars(at: 128))
        XCTAssertEqual(doc, full)
        XCTAssertThrowsError(try doc.deleteBars(0...127))
        XCTAssertEqual(doc, full)
    }
    func testMeterChangesKeepOnsetsAndNeverRemoveSoundingNotes() throws {
        var doc = EditorDocument.pianoExample
        var original = doc
        XCTAssertThrowsError(try doc.setMeter(EditorMeter(3, 4)))
        XCTAssertEqual(doc, original)
        try doc.setMeter(EditorMeter(5, 4))
        for event in original.events {
            XCTAssertEqual(doc.onset(event), original.onset(event))
            XCTAssertEqual(doc.events.first { $0.id == event.id }?.pitches, event.pitches)
        }
        XCTAssertTrue(doc.inBar(0, staff: 1).last!.isRest)
        try doc.setMeter(EditorMeter(4, 4))
        XCTAssertEqual(doc, original)
        original = try EditorDocument.blank(instrument: .piano)
        doc = original
        try doc.setMeter(EditorMeter(6, 8))
        XCTAssertEqual(doc.meter, EditorMeter(6, 8))
        XCTAssertTrue(doc.events.allSatisfy(\.isRest))
        _ = try doc.validated()
    }
    func testClearPassagePreservesOtherBarsAndBothStaffsRemainComplete() throws {
        var doc = EditorDocument.pianoExample
        let outside = doc.events.filter { !(1...2).contains($0.bar) }
        try doc.clearBars(1...2)
        XCTAssertEqual(doc.events.filter { !(1...2).contains($0.bar) }, outside)
        XCTAssertTrue(doc.events.filter { (1...2).contains($0.bar) }.allSatisfy(\.isRest))
        _ = try doc.validated()
    }
    func testTransposeChangesBothHandsAndUnplayableGuitarEditIsAtomic() throws {
        var doc = EditorDocument.pianoExample
        let original = doc
        try doc.transpose(1...2, semitones: 1)
        for event in original.events {
            let edited = try XCTUnwrap(doc.events.first { $0.id == event.id })
            XCTAssertEqual(
                edited.pitches.map(\.midi), event.pitches.map { $0.midi + ((1...2).contains(event.bar) ? 1 : 0) })
        }
        doc = .guitarExample
        let guitar = doc
        XCTAssertThrowsError(try doc.transpose(0...3, semitones: -24))
        XCTAssertEqual(doc, guitar)
        try doc.transpose(0...3, semitones: 1)
        _ = try doc.validated()
    }
    func testExcerptRetainsSelectionIDsAndClipsTiesAtItsBoundary() throws {
        var doc = EditorDocument.pianoExample
        let last = doc.events.firstIndex { $0.bar == 0 && $0.staff == 1 && doc.onset($0) == 1440 }!
        doc.events[last + 1].pitches[0].midi = doc.events[last].pitches[0].midi
        doc.events[last + 1].pitches[0].spelling = doc.events[last].pitches[0].spelling
        doc.events[last].tieNext = true
        _ = try doc.validated()
        let excerpt = try doc.excerpt(0...0)
        XCTAssertEqual(excerpt.barCount, 1)
        XCTAssertFalse(excerpt.events.first { $0.id == doc.events[last].id }!.tieNext)
        XCTAssertTrue(doc.events[last].tieNext)
        XCTAssertTrue(
            try EditorXML.encode(try doc.excerpt(2...3), firstBarNumber: 3).contains("<measure number=\"3\">"))
    }
    func testDeleteClearsOnlyBoundaryTieAndKeepsInternalTies() throws {
        var doc = EditorDocument.guitarExample
        try doc.insertBars(at: 4)
        let before = doc.events.filter(\.tieNext).map(\.id)
        try doc.deleteBars(4...4)
        XCTAssertEqual(doc.events.filter(\.tieNext).map(\.id), before)
    }
    func testCompoundMeterPlaybackUsesGlobalBarPositionsAndCorrectCountIn() throws {
        var doc = try EditorDocument.blank(instrument: .piano, bars: 8, meter: EditorMeter(6, 8))
        let event = doc.inBar(4, staff: 1)[0]
        try doc.setPitch(event.id, midi: 69)
        XCTAssertEqual(doc.playback().notes.first?.start, 12)
        XCTAssertEqual(doc.playback(from: 4, through: 5).notes.first?.start, 0)
        let imported = try StudyImport.read(Data(EditorXML.encode(doc).utf8))
        var study = MusicStudy(document: imported, filename: "fixture")
        study.select(from: 4, through: 5)
        study.countIn = true
        study.metronome = true
        let plan = try StudyPlaybackPlan(study: study)
        XCTAssertEqual(plan.sourceStart, 12)
        XCTAssertEqual(plan.cycleBeats, 6)
        XCTAssertEqual(plan.introBeats, 3)
        XCTAssertEqual(plan.intro.notes.count, 6)
        XCTAssertEqual(plan.cycle.notes.filter { $0.midi == 69 }.count, 1)
        XCTAssertEqual(plan.position(seconds: 3, loop: true).sourceBeat, 13.5)
    }
    func testUnsupportedTempoChangesAreRejected() throws {
        let xml = try EditorXML.encode(.pianoExample).replacingOccurrences(
            of: "<measure number=\"2\">", with: "<measure number=\"2\"><direction><sound tempo=\"120\"/></direction>")
        XCTAssertThrowsError(try EditorXML.decode(Data(xml.utf8)))
    }
    func testPagedAndFullXMLAgreeOnGuitarPitchesAndFingerings() throws {
        var doc = EditorDocument.guitarExample
        let copy = try doc.excerpt(0...3)
        try doc.paste(copy, at: 4, inserting: true)
        let page = try doc.excerpt(4...7)
        let decoded = try EditorXML.decode(Data(EditorXML.encode(page, firstBarNumber: 5).utf8))
        XCTAssertEqual(page.playback().notes.map(\.midi), decoded.playback().notes.map(\.midi))
        XCTAssertEqual(page.events.flatMap(\.pitches).map(\.fret), decoded.events.flatMap(\.pitches).map(\.fret))
        XCTAssertEqual(doc.playback().notes.count, 30)
    }
    func testMinorKeyAndNonstandardClefHandling() throws {
        var doc = EditorDocument.pianoExample
        doc.fifths = -2
        doc.minor = true
        let xml = try EditorXML.encode(doc)
        let decoded = try EditorXML.decode(Data(xml.utf8))
        XCTAssertTrue(decoded.minor)
        XCTAssertEqual(decoded.fifths, -2)
        let alto = xml.replacingOccurrences(of: "<sign>G</sign><line>2</line>", with: "<sign>C</sign><line>3</line>")
        XCTAssertThrowsError(try EditorXML.decode(Data(alto.utf8)))
        let decimal = xml.replacingOccurrences(of: "90", with: "90.5")
        XCTAssertThrowsError(try EditorXML.decode(Data(decimal.utf8)))
    }

    func testMIDIExportCarriesMeterKeyInstrumentAndTrailingEmptyBars() throws {
        var doc = try EditorDocument.blank(instrument: .guitar, bars: 8, meter: EditorMeter(6, 8))
        doc.fifths = -2
        doc.minor = true
        try doc.setPitch(doc.events[0].id, midi: 60)
        let bytes = Array(MIDIFile.encode(doc.playback(), endBeat: 24, program: 24, minor: true))
        XCTAssertTrue(
            (0...(bytes.count - 7)).map { bytes[$0..<($0 + 7)] }.contains { Array($0) == [0xff, 0x58, 4, 6, 3, 36, 8] })
        XCTAssertTrue(
            (0...(bytes.count - 5)).map { bytes[$0..<($0 + 5)] }.contains { Array($0) == [0xff, 0x59, 2, 254, 1] })
        XCTAssertTrue((0...(bytes.count - 2)).map { bytes[$0..<($0 + 2)] }.contains { Array($0) == [0xc0, 24] })
        // First note ends at 1,440 ticks; eight 6/8 bars end at 11,520.
        // The remaining 10,080 ticks are encoded as the end-of-track delta.
        XCTAssertEqual(Array(bytes.suffix(5)), [0xce, 0x60, 0xff, 0x2f, 0])
    }

    func testTiedGuitarUnisonsKeepBothStringsAndSoundDurations() throws {
        var doc = try EditorDocument.blank(instrument: .guitar, bars: 1)
        let id = doc.events[0].id
        try doc.setRhythm(id, EditorRhythm(480))
        try doc.setPitch(id, midi: 64)
        let index = doc.events.firstIndex { $0.id == id }!
        doc.events[index].pitches = [EditorPitch(64, string: 5, fret: 0), EditorPitch(64, string: 4, fret: 5)]
        let next = doc.events[index + 1].id
        try doc.setRhythm(next, EditorRhythm(480))
        let nextIndex = doc.events.firstIndex { $0.id == next }!
        doc.events[nextIndex].pitches = [EditorPitch(64, string: 5, fret: 0), EditorPitch(64, string: 4, fret: 5)]
        doc.events[index].tieNext = true
        _ = try doc.validated()
        XCTAssertEqual(doc.playback().notes.map(\.duration), [2, 2])
        let xml = Data(try EditorXML.encode(doc).utf8)
        let imported = try EditorXML.decode(xml)
        XCTAssertEqual(imported.events.flatMap(\.pitches).map(\.string), doc.events.flatMap(\.pitches).map(\.string))
        XCTAssertEqual(imported.events.flatMap(\.pitches).map(\.fret), doc.events.flatMap(\.pitches).map(\.fret))
        XCTAssertEqual(try StudyImport.read(xml).parts[0].soundingNotes().map(\.duration), [2, 2])
    }
    func testDottedWholeFitsTwelveEightAndRoundTrips() throws {
        var doc = try EditorDocument.blank(instrument: .piano, bars: 1, meter: EditorMeter(12, 8))
        XCTAssertEqual(doc.events[0].rhythm, EditorRhythm(1920, dotted: true))
        try doc.setPitch(doc.events[0].id, midi: 60)
        let decoded = try EditorXML.decode(Data(EditorXML.encode(doc).utf8))
        XCTAssertEqual(decoded.events[0].rhythm, EditorRhythm(1920, dotted: true))
        XCTAssertEqual(decoded.playback().notes.first?.duration, 6)
    }

}
