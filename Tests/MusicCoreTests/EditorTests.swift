// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class EditorTests: XCTestCase {
    func testBothExamplesHaveCompleteBarsAndValidFingerings() throws {
        for document in [EditorDocument.guitarExample, .pianoExample] {
            _ = try document.validated()
            for staff in 1...document.staffCount {
                for bar in 0..<4 {
                    XCTAssertEqual(document.inBar(bar, staff: staff).reduce(0) { $0 + $1.rhythm.ticks }, 1920)
                }
            }
        }
    }
    func testChangingFretChangesSoundAndWrittenPitchTogether() throws {
        var doc = EditorDocument.guitarExample
        let event = doc.events[0]
        let note = event.pitches[0]
        try doc.setFingering(event.id, pitchID: note.id, string: 4, fret: 3)
        let changed = doc.events[0].pitches[0]
        XCTAssertEqual(changed.midi, 62)
        XCTAssertEqual(changed.spelling.pc, 2)
        XCTAssertEqual(changed.id, note.id)
        XCTAssertEqual(doc.playback().notes[0].midi, 62)
        _ = try doc.validated()
    }
    func testPitchChangeReassignsTabAndPreservesIdentity() throws {
        var doc = EditorDocument.guitarExample
        let note = doc.events[0].pitches[0]
        try doc.setPitch(doc.events[0].id, pitchID: note.id, midi: 61, spelling: Pitch(0, 1))
        let changed = doc.events[0].pitches[0]
        XCTAssertEqual(changed.id, note.id)
        XCTAssertEqual(changed.spelling, Pitch(0, 1))
        XCTAssertEqual(doc.tuning.pitches[changed.string!] + changed.fret!, 61)
    }
    func testShorteningCreatesExplicitRestsAndPreservesLaterOnsets() throws {
        var doc = EditorDocument.pianoExample
        let second = doc.events[1]
        let onset = doc.onset(second)
        try doc.setRhythm(doc.events[0].id, EditorRhythm(240))
        XCTAssertEqual(doc.onset(second), onset)
        XCTAssertTrue(doc.events[1].isRest)
        XCTAssertEqual(doc.events[1].rhythm.ticks, 240)
        _ = try doc.validated()
    }
    func testLengtheningConsumesOnlyFollowingRests() throws {
        var doc = EditorDocument.guitarExample
        let firstID = doc.events[0].id
        try doc.setRhythm(firstID, EditorRhythm(120))
        try doc.setRhythm(firstID, EditorRhythm(480))
        XCTAssertEqual(doc.events.count, 16)
        _ = try doc.validated()
        XCTAssertThrowsError(try doc.setRhythm(firstID, EditorRhythm(960)))
    }
    func testTripletTimingIsExactAndRoundTrips() throws {
        var doc = EditorDocument.guitarExample
        try doc.setRhythm(doc.events[0].id, EditorRhythm(240, triplet: true))
        XCTAssertEqual(doc.events[0].rhythm.ticks, 160)
        _ = try doc.validated()
        let imported = try EditorXML.decode(Data(EditorXML.encode(doc).utf8))
        XCTAssertEqual(imported.events[0].rhythm, doc.events[0].rhythm)
        XCTAssertEqual(imported.inBar(0, staff: 1).map(\.rhythm), doc.inBar(0, staff: 1).map(\.rhythm))
        let xml = try EditorXML.encode(doc)
        XCTAssertTrue(xml.contains("<tuplet type=\"start\""))
        XCTAssertTrue(xml.contains("<tuplet type=\"stop\""))
    }
    func testEveryShorterRhythmCanFillTheRemainingBeatExactly() throws {
        for rhythm in EditorRhythm.choices where rhythm.ticks < 480 {
            var doc = EditorDocument.pianoExample
            try doc.setRhythm(doc.events[0].id, rhythm)
            _ = try doc.validated()
            XCTAssertEqual(doc.onset(doc.events.first { $0.pitches.first?.midi == 67 }!), 480)
        }
    }
    func testPianoLeftHandIsIndependentAndChordsSoundOnce() throws {
        var doc = EditorDocument.pianoExample
        let left = doc.events.filter { $0.staff == 2 }
        try doc.setPitch(doc.events[0].id, midi: 66)
        XCTAssertEqual(doc.events.filter { $0.staff == 2 }, left)
        let playback = doc.playback()
        XCTAssertEqual(playback.notes.filter { $0.start == 0 }.count, 4)
        XCTAssertEqual(playback.notes.filter { $0.start == 0 && $0.midi == 48 }.count, 1)
    }
    func testTiesMergePlaybackButRemainWrittenEvents() throws {
        let doc = EditorDocument.guitarExample
        let notes = doc.playback().notes
        XCTAssertEqual(notes.count, 15)
        XCTAssertEqual(notes.last?.duration, 2)
        let xml = try EditorXML.encode(doc)
        XCTAssertTrue(xml.contains("<tie type=\"start\"/>"))
        XCTAssertTrue(xml.contains("<tied type=\"stop\"/>"))
        XCTAssertEqual(try EditorXML.decode(Data(xml.utf8)).events.filter(\.tieNext).count, 1)
    }
    func testInvalidTieRejectedAndPitchEditClearsBrokenTie() throws {
        var doc = EditorDocument.guitarExample
        try doc.setPitch(doc.events[15].id, midi: 62)
        XCTAssertFalse(doc.events[14].tieNext)
        doc.events[0].tieNext = true
        XCTAssertThrowsError(try doc.validated())
    }
    func testGuitarXMLHasLinkedAlternateStaffAndNoDoubledAudio() throws {
        let doc = EditorDocument.guitarExample
        let xml = try EditorXML.encode(doc)
        XCTAssertTrue(xml.contains("<staff-type>alternate</staff-type>"))
        let study = try StudyImport.read(Data(xml.utf8))
        XCTAssertEqual(study.parts[0].tabStaves, [2])
        XCTAssertEqual(study.parts[0].soundingNotes().map(\.midi), doc.playback().notes.map(\.midi))
        XCTAssertEqual(study.parts[0].soundingNotes().map(\.duration), doc.playback().notes.map(\.duration))
        XCTAssertEqual(study.parts[0].notes[0].writtenMidi, doc.events[0].pitches[0].midi + 12)
    }
    func testBothMusicXMLRoundTripsPreserveRhythmSpellingAndFingerings() throws {
        for doc in [EditorDocument.guitarExample, .pianoExample] {
            let imported = try EditorXML.decode(Data(EditorXML.encode(doc).utf8))
            for staff in 1...doc.staffCount {
                XCTAssertEqual(imported.ordered(staff: staff).map(\.rhythm), doc.ordered(staff: staff).map(\.rhythm))
                XCTAssertEqual(
                    imported.ordered(staff: staff).map { $0.pitches.map(\.midi) },
                    doc.ordered(staff: staff).map { $0.pitches.map(\.midi) })
                XCTAssertEqual(
                    imported.ordered(staff: staff).map { $0.pitches.map(\.spelling) },
                    doc.ordered(staff: staff).map { $0.pitches.map(\.spelling) })
                XCTAssertEqual(
                    imported.ordered(staff: staff).map { $0.pitches.map(\.string) },
                    doc.ordered(staff: staff).map { $0.pitches.map(\.string) })
            }
        }
    }
    func testRetuningKeepsPitchesAndProducesValidNewTab() throws {
        var doc = EditorDocument.guitarExample
        let pitches = doc.events.flatMap(\.pitches).map(\.midi)
        try doc.setGuitar(tuning: Tuning("Drop D", [38, 45, 50, 55, 59, 64]), capo: 2)
        XCTAssertEqual(doc.events.flatMap(\.pitches).map(\.midi), pitches)
        _ = try doc.validated()
        let imported = try EditorXML.decode(Data(EditorXML.encode(doc).utf8))
        XCTAssertEqual(imported.capo, 2)
        XCTAssertEqual(imported.tuning.pitches, doc.tuning.pitches)
    }
    func testChordTonesUseDifferentStrings() throws {
        var doc = EditorDocument.guitarExample
        try doc.addChordTone(doc.events[0].id)
        XCTAssertEqual(doc.events[0].pitches.count, 2)
        XCTAssertEqual(Set(doc.events[0].pitches.compactMap(\.string)).count, 2)
        _ = try doc.validated()
    }
    func testUnsupportedMusicXMLCannotSilentlyLoseMarks() throws {
        let xml = try EditorXML.encode(.pianoExample).replacingOccurrences(
            of: "</note>", with: "<notations><slur type=\"start\"/></notations></note>")
        XCTAssertThrowsError(try EditorXML.decode(Data(xml.utf8)))
    }
    func testEditableSaveRestoresStableNoteIdentities() throws {
        var library = EditorLibrary()
        library.engine = "Smoosic"
        library.activeID = library.documents[1].id
        let decoded = try JSONDecoder().decode(EditorLibrary.self, from: JSONEncoder().encode(library))
        XCTAssertEqual(decoded, library)
        _ = try decoded.active.validated()
    }
    func testInvalidBarAndDuplicateStringRejected() throws {
        var doc = EditorDocument.guitarExample
        doc.events.removeFirst()
        XCTAssertThrowsError(try doc.validated())
        doc = .guitarExample
        doc.events[0].pitches.append(
            EditorPitch(
                doc.events[0].pitches[0].midi, string: doc.events[0].pitches[0].string,
                fret: doc.events[0].pitches[0].fret))
        XCTAssertThrowsError(try doc.validated())
    }
    func testFailedEditIsAtomicAndMalformedRhythmIsRejected() throws {
        var doc = EditorDocument.guitarExample
        let initial = doc
        XCTAssertThrowsError(try doc.setRhythm(doc.events[0].id, EditorRhythm(960)))
        XCTAssertEqual(doc, initial)
        XCTAssertThrowsError(try doc.setRhythm(doc.events[0].id, EditorRhythm(Int.max, dotted: true)))
        doc.events[0].rhythm = EditorRhythm(Int.max, dotted: true)
        XCTAssertThrowsError(try doc.validated())
    }
    func testMalformedTupletRatioIsRejectedWithoutIntegerOverflow() throws {
        var doc = EditorDocument.guitarExample
        try doc.setRhythm(doc.events[0].id, EditorRhythm(240, triplet: true))
        let xml = try EditorXML.encode(doc).replacingOccurrences(
            of: "<normal-notes>2</normal-notes>", with: "<normal-notes>9223372036854775807</normal-notes>")
        XCTAssertThrowsError(try EditorXML.decode(Data(xml.utf8)))
    }
}
