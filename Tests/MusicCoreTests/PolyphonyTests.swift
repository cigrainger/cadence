// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class PolyphonyTests: XCTestCase {
    func testOldEventsMigrateToVoiceOneWithoutChangingIdentities() throws {
        let original = EditorDocument.pianoExample
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json["schemaVersion"] = 2
        json["events"] = (json["events"] as! [[String: Any]]).map { item in
            var v = item
            for key in ["voice", "stem", "staccato", "accent", "dynamic", "slurTo"] { v.removeValue(forKey: key) }
            return v
        }
        let migrated = try JSONDecoder().decode(EditorDocument.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(migrated, original)
        XCTAssertEqual(migrated.schemaVersion, 8)
        _ = try migrated.validated()
    }
    func testOriginalStudiesRoundTripVoicesExpressionAndExactGuitarPositions() throws {
        for doc in [EditorDocument.fingerstyleExample, .innerVoiceExample] {
            _ = try doc.validated()
            let xml = try EditorXML.encode(doc)
            let copy = try EditorXML.decode(Data(xml.utf8))
            XCTAssertTrue(xml.contains("<stem>up</stem>"))
            XCTAssertTrue(xml.contains("<stem>down</stem>"))
            for staff in 1...doc.staffCount {
                for voice in doc.voices(staff: staff) {
                    let a = doc.ordered(staff: staff, voice: voice)
                    let b = copy.ordered(staff: staff, voice: voice)
                    XCTAssertEqual(a.map(\.rhythm), b.map(\.rhythm))
                    XCTAssertEqual(a.map { $0.pitches.map(\.midi) }, b.map { $0.pitches.map(\.midi) })
                    XCTAssertEqual(a.map(\.staccato), b.map(\.staccato))
                    XCTAssertEqual(a.map(\.accent), b.map(\.accent))
                    XCTAssertEqual(a.map(\.dynamic), b.map(\.dynamic))
                    XCTAssertEqual(a.compactMap(\.slurTo).count, b.compactMap(\.slurTo).count)
                    if doc.instrument == .guitar {
                        XCTAssertEqual(a.flatMap(\.pitches).map(\.string), b.flatMap(\.pitches).map(\.string))
                        XCTAssertEqual(a.flatMap(\.pitches).map(\.fret), b.flatMap(\.pitches).map(\.fret))
                    }
                }
            }
            XCTAssertEqual(doc.playback().notes.map(\.performance), copy.playback().notes.map(\.performance))
        }
    }
    func testVoiceTwoHasIndependentOnsetsRhythmEditsAndTies() throws {
        var doc = try EditorDocument.blank(instrument: .piano, bars: 2)
        try doc.addVoice(staff: 1)
        let upper = doc.inBar(0, staff: 1)[0]
        let lower = doc.inBar(0, staff: 1, voice: 2)[0]
        try doc.setRhythm(upper.id, EditorRhythm(240))
        try doc.setPitch(upper.id, midi: 72)
        try doc.setRhythm(lower.id, EditorRhythm(960))
        try doc.setPitch(lower.id, midi: 60)
        let next = try XCTUnwrap(doc.nextEvent(doc.events.first { $0.id == lower.id }!))
        XCTAssertEqual(next.voice, 2)
        XCTAssertEqual(doc.onset(next), 960)
        try doc.setPitch(next.id, midi: 60)
        doc.events[doc.events.firstIndex { $0.id == lower.id }!].tieNext = true
        _ = try doc.validated()
        XCTAssertEqual(doc.inBar(0, staff: 1).first?.rhythm, EditorRhythm(240))
        XCTAssertEqual(doc.playback().notes.first { $0.midi == 60 }?.duration, 4)
        let study = try StudyImport.read(Data(EditorXML.encode(doc).utf8))
        XCTAssertEqual(study.parts[0].soundingNotes().filter { $0.midi == 60 }.count, 1)
    }
    func testVoiceAddRemoveAndIncompleteVoiceValidation() throws {
        var doc = EditorDocument.pianoExample
        var original = doc
        try doc.addVoice(staff: 2)
        XCTAssertEqual(doc.voices(staff: 2), [1, 2])
        XCTAssertEqual(doc.voices(staff: 1), [1])
        try doc.removeSecondVoice(staff: 2)
        XCTAssertEqual(doc, original)
        try doc.addVoice(staff: 1)
        original = doc
        doc.events.removeAll { $0.bar == 2 && $0.staff == 1 && $0.voice == 2 }
        XCTAssertThrowsError(try doc.validated())
        doc = original
        doc.events[0].voice = 3
        XCTAssertThrowsError(try doc.validated())
    }
    func testGuitarHeldBassReservesItsStringAcrossMovingVoice() throws {
        var doc = try EditorDocument.blank(instrument: .guitar, bars: 1)
        try doc.addVoice(staff: 1)
        let bass = doc.inBar(0, staff: 1, voice: 2)[0].id
        let melody = doc.inBar(0, staff: 1)[0].id
        try doc.setPitch(bass, midi: 52)
        let bassIndex = doc.events.firstIndex { $0.id == bass }!
        doc.events[bassIndex].pitches = [EditorPitch(52, string: 0, fret: 12)]
        try doc.setRhythm(melody, EditorRhythm(480))
        try doc.setPitch(melody, midi: 55)
        let p = try XCTUnwrap(doc.events.first { $0.id == melody }?.pitches.first)
        XCTAssertNotEqual(p.string, 0)
        XCTAssertThrowsError(try doc.setFingering(melody, pitchID: p.id, string: 0, fret: 15))
        let index = doc.events.firstIndex { $0.id == melody }!
        doc.events[index].pitches[0].string = 0
        doc.events[index].pitches[0].fret = 15
        XCTAssertThrowsError(try doc.validated())
    }
    func testCopyPasteRemapsSlursAndFillsMissingVoicesOutsidePassage() throws {
        let source = EditorDocument.innerVoiceExample
        let excerpt = try source.excerpt(0...1)
        var target = EditorDocument.pianoExample
        try target.paste(excerpt, at: 1, inserting: true)
        _ = try target.validated()
        XCTAssertEqual(target.barCount, 6)
        XCTAssertEqual(target.voices(staff: 1), [1, 2])
        XCTAssertTrue(target.inBar(0, staff: 1, voice: 2).allSatisfy(\.isRest))
        let pasted = target.ordered(staff: 1).filter { (1...2).contains($0.bar) }
        for event in pasted where event.slurTo != nil {
            XCTAssertTrue(pasted.contains { $0.id == event.slurTo })
            XCTAssertFalse(source.events.contains { $0.id == event.slurTo })
        }
        try target.deleteBars(1...2)
        _ = try target.validated()
        XCTAssertTrue(target.events.filter { $0.voice == 2 }.allSatisfy(\.isRest))
        try target.setMeter(EditorMeter(5, 4))
        _ = try target.validated()
        for staff in 1...2 {
            for voice in target.voices(staff: staff) {
                for bar in 0..<4 {
                    XCTAssertEqual(
                        target.inBar(bar, staff: staff, voice: voice).reduce(0) { $0 + $1.rhythm.ticks }, 2400)
                }
            }
        }
    }
    func testSlursClipAtExcerptAndDeletedEndpointsButStayWithinVoice() throws {
        var doc = EditorDocument.innerVoiceExample
        let source = doc.inBar(0, staff: 1)[0].id
        let endpoint = doc.inBar(1, staff: 1)[1].id
        doc.events[doc.events.firstIndex { $0.id == source }!].slurTo = endpoint
        doc.events[doc.events.firstIndex { $0.id == doc.inBar(1, staff: 1)[0].id }!].slurTo = nil
        _ = try doc.validated()
        XCTAssertNil(try doc.excerpt(0...0).events.first { $0.id == source }?.slurTo)
        try doc.deleteBars(1...1)
        XCTAssertNil(doc.events.first { $0.id == source }?.slurTo)
        doc.events[doc.events.firstIndex { $0.id == source }!].slurTo = doc.inBar(0, staff: 1, voice: 2)[1].id
        XCTAssertThrowsError(try doc.validated())
    }
    func testExpressionDrivesStudyPlaybackAndMIDIVelocitiesGatesAndChannels() throws {
        let doc = EditorDocument.innerVoiceExample
        let imported = try StudyImport.read(Data(EditorXML.encode(doc).utf8))
        var study = MusicStudy(document: imported, filename: "fixture")
        study.countIn = false
        let plan = try StudyPlaybackPlan(study: study)
        let upper = try XCTUnwrap(plan.cycle.notes.first { $0.midi == 76 && $0.start == 0 })
        let inner = try XCTUnwrap(plan.cycle.notes.first { $0.midi == 60 && $0.start == 0 })
        XCTAssertEqual(upper.performance?.gate, 1.03)
        XCTAssertEqual(upper.performance?.velocity, 68)
        XCTAssertEqual(inner.performance?.velocity, 56)
        XCTAssertNotEqual(upper.channel, inner.channel)
        XCTAssertEqual(plan.cycle.notes.first { $0.start == 8 && $0.midi == 59 }?.performance?.gate, 0.45)
        let bytes = Array(MIDIFile.encode(doc.playback()))
        let on = [UInt8(0x90 + upper.channel!), UInt8(76), UInt8(68)]
        XCTAssertTrue((0...(bytes.count - 3)).contains { Array(bytes[$0..<($0 + 3)]) == on })
        XCTAssertTrue(study.reference.context.contains("staccato"))
        XCTAssertTrue(study.reference.context.contains("slur begins"))
    }
    func testPracticeSingingCanChooseUpperOrLowerVoiceWithoutDuplicateTAB() throws {
        for doc in [EditorDocument.fingerstyleExample, .innerVoiceExample] {
            let study = try ComposePractice.make(doc, from: 0, through: 3)
            let voices = SingingVoice.choices(study)
            XCTAssertEqual(voices.count, doc.instrument == .guitar ? 2 : 3)
            let upper = try PassageMelody(study: study, voice: voices.first { $0.staff == 1 && $0.voice == "1" }!)
            let lower = try PassageMelody(study: study, voice: voices.first { $0.staff == 1 && $0.voice == "2" }!)
            XCTAssertNotEqual(upper.notes.map(\.tone.midi), lower.notes.map(\.tone.midi))
            XCTAssertFalse(upper.reducedChords)
        }
    }
    func testUnsupportedExpressionIsRejectedRatherThanDiscarded() throws {
        let xml = try EditorXML.encode(.innerVoiceExample)
        for replacement in ["<tenuto/>", "<strong-accent/>"] {
            XCTAssertThrowsError(
                try EditorXML.decode(Data(xml.replacingOccurrences(of: "<staccato/>", with: replacement).utf8)))
        }
        XCTAssertThrowsError(try EditorXML.decode(Data(xml.replacingOccurrences(of: "<mp/>", with: "<sfz/>").utf8)))
        XCTAssertThrowsError(
            try EditorXML.decode(
                Data(
                    xml.replacingOccurrences(of: "type=\"stop\" number=\"1\"", with: "type=\"continue\" number=\"1\"")
                        .utf8)))
    }
    func testExplicitStemAndExpressionJSONSurviveSave() throws {
        var doc = EditorDocument.innerVoiceExample
        doc.events[0].stem = .down
        let saved = try JSONDecoder().decode(EditorDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(saved, doc)
        let imported = try EditorXML.decode(Data(EditorXML.encode(doc).utf8))
        XCTAssertEqual(imported.events[0].stem, .down)
    }
    func testChordExpressionAppliesToEveryToneAndExcerptCarriesDynamic() throws {
        var doc = EditorDocument.pianoExample
        let chord = doc.events.firstIndex { $0.staff == 2 && $0.bar == 0 }!
        doc.events[chord].staccato = true
        doc.events[chord].accent = true
        doc.events[chord].dynamic = .p
        let notes = doc.playback().notes.filter { $0.start == 0 && $0.midi < 60 }
        XCTAssertEqual(notes.count, 3)
        XCTAssertTrue(notes.allSatisfy { $0.performance?.gate == 0.45 && $0.performance?.velocity == 74 })
        let excerpt = try doc.excerpt(2...3)
        XCTAssertEqual(excerpt.inBar(0, staff: 2)[0].dynamic, .p)
        XCTAssertEqual(excerpt.playback().notes.first { $0.midi < 60 }?.performance?.velocity, 56)
    }
    func testBeamsFollowBeatGroupsAndBothVoicesSurviveClear() throws {
        var doc = EditorDocument.fingerstyleExample
        let first = doc.inBar(0, staff: 1)
        XCTAssertEqual(doc.beams(first[0]).map(\.1), ["begin"])
        XCTAssertEqual(doc.beams(first[1]).map(\.1), ["end"])
        try doc.clearBars(0...3)
        XCTAssertEqual(doc.voices(staff: 1), [1, 2])
        XCTAssertTrue(doc.events.allSatisfy(\.isRest))
        _ = try doc.validated()
        var compound = try EditorDocument.blank(instrument: .piano, bars: 1, meter: EditorMeter(6, 8))
        for _ in 0..<6 {
            let rest = compound.inBar(0, staff: 1).first { $0.isRest }!
            try compound.setRhythm(rest.id, EditorRhythm(240))
            try compound.setPitch(rest.id, midi: 60)
        }
        let events = compound.inBar(0, staff: 1)
        XCTAssertEqual(
            events.map { compound.beams($0).first!.1 }, ["begin", "continue", "end", "begin", "continue", "end"])
    }
    func testLinkedTabVoiceLabelsCanDifferFromStandardVoiceLabels() throws {
        let doc = EditorDocument.fingerstyleExample
        let xml = try EditorXML.encode(doc).replacingOccurrences(of: "<voice>3</voice>", with: "<voice>1</voice>")
            .replacingOccurrences(of: "<voice>4</voice>", with: "<voice>2</voice>")
        let imported = try EditorXML.decode(Data(xml.utf8))
        for voice in [1, 2] {
            XCTAssertEqual(
                imported.ordered(staff: 1, voice: voice).flatMap(\.pitches).map(\.fret),
                doc.ordered(staff: 1, voice: voice).flatMap(\.pitches).map(\.fret))
        }
    }
    func testLegacyStudyEnrichesExpressionWithoutChangingNoteIDs() throws {
        let source = try ComposePractice.make(.innerVoiceExample, from: 0, through: 3)
        var old = source
        for p in old.document.parts.indices {
            old.document.parts[p].dynamics = nil
            for n in old.document.parts[p].notes.indices { old.document.parts[p].notes[n].expression = nil }
        }
        let restored = try old.restored()
        XCTAssertEqual(restored.document.parts[0].notes.map(\.id), old.document.parts[0].notes.map(\.id))
        XCTAssertEqual(
            restored.document.parts[0].notes.map(\.expression), source.document.parts[0].notes.map(\.expression))
        XCTAssertEqual(restored.document.parts[0].dynamics, source.document.parts[0].dynamics)
        XCTAssertEqual(restored.part.soundingNotes().map(\.performance), source.part.soundingNotes().map(\.performance))
    }
    func testSimultaneousCrossBarSlursOnBothStaffsRoundTripIndependently() throws {
        var doc = EditorDocument.pianoExample
        for staff in [1, 2] {
            let start = doc.inBar(0, staff: staff)[0]
            let end = doc.inBar(1, staff: staff)[0]
            doc.events[doc.events.firstIndex { $0.id == start.id }!].slurTo = end.id
        }
        let imported = try EditorXML.decode(Data(EditorXML.encode(doc).utf8))
        for staff in [1, 2] {
            let first = imported.inBar(0, staff: staff)[0]
            let end = imported.inBar(1, staff: staff)[0]
            XCTAssertEqual(first.slurTo, end.id)
        }
    }
}
