// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import XCTest
import ZIPFoundation

@testable import MusicCore

final class StudyTests: XCTestCase {
    private func score(_ bars: String, attributes: String = "", name: String = "Piano") -> String {
        "<score-partwise><work><work-title>Fixture study</work-title></work><part-list><score-part id=\"P1\"><part-name>\(name)</part-name></score-part></part-list><part id=\"P1\"><measure number=\"1\"><attributes><divisions>4</divisions><key><fifths>0</fifths></key><time><beats>4</beats><beat-type>4</beat-type></time>\(attributes)</attributes>\(bars)</part></score-partwise>"
    }
    private func note(_ step: String = "C", octave: Int = 4, duration: Int = 4, extra: String = "", before: String = "")
        -> String
    {
        "<note>\(before)<pitch><step>\(step)</step><octave>\(octave)</octave></pitch><duration>\(duration)</duration>\(extra)</note>"
    }
    private func read(_ xml: String) throws -> StudyDocument { try StudyImport.read(Data(xml.utf8)) }
    private func example() throws -> MusicStudy {
        MusicStudy(document: try read(StudyExamples.smallSteps), filename: "example.musicxml")
    }
    func testOriginalExampleHasTwoVoicesAndGuitarSoundingPitches() throws {
        let study = try example()
        XCTAssertEqual(study.document.title, "Small steps in C")
        XCTAssertEqual(study.document.tempo, 84)
        XCTAssertEqual(study.part.measures.map(\.duration), [4, 4, 4, 4])
        XCTAssertEqual(study.part.notes[0].writtenMidi, 76)
        XCTAssertEqual(study.part.notes[0].midi, 64)
        XCTAssertEqual(study.part.soundingNotes().count, 20)
        XCTAssertEqual(Set(study.part.notes.map(\.voice)), ["1", "2"])
    }
    func testBackupAndChordsHaveIndependentOnsets() throws {
        let xml = score(
            note(duration: 16, extra: "<voice>1</voice>") + "<backup><duration>16</duration></backup>"
                + note("E", extra: "<voice>2</voice>") + note("G", extra: "<voice>2</voice>", before: "<chord/>")
                + note("F", extra: "<voice>2</voice>") + "</measure>")
        let part = try read(xml).parts[0]
        XCTAssertEqual(part.notes.map(\.start), [0, 0, 0, 1])
        XCTAssertEqual(part.measures[0].duration, 4)
    }
    func testPickupAndRegularUnderfilledBarsAndMeterChange() throws {
        let xml = score(
            note() + "</measure><measure number=\"2\">" + note("D")
                + "</measure><measure number=\"3\"><attributes><time><beats>6</beats><beat-type>8</beat-type></time><key><fifths>-2</fifths></key></attributes>"
                + note("E", duration: 12) + "</measure>")
        let bars = try read(xml).parts[0].measures
        XCTAssertEqual(bars.map(\.start), [0, 1, 5])
        XCTAssertEqual(bars.map(\.duration), [1, 4, 3])
        XCTAssertEqual(bars[2].fifths, -2)
    }
    func testSoundTiesMergeOnlySameVoiceAndStaff() throws {
        let xml = score(
            note(duration: 16, extra: "<voice>1</voice><tie type=\"start\"/>") + "</measure><measure number=\"2\">"
                + note(duration: 16, extra: "<voice>1</voice><tie type=\"stop\"/>")
                + "<backup><duration>16</duration></backup>" + note(duration: 16, extra: "<voice>2</voice>")
                + "</measure>")
        let part = try read(xml).parts[0]
        let events = part.soundingNotes()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].duration, 8)
        XCTAssertEqual(events[0].id, part.notes[0].id)
        XCTAssertEqual(events[1].start, 4)
    }
    func testTabDuplicateIsNotPlayedTwiceAndTechnicalFingeringIsRetained() throws {
        let xml = score(
            note("E", extra: "<staff>1</staff>") + "<backup><duration>4</duration></backup>"
                + note(
                    "E",
                    extra:
                        "<staff>2</staff><notations><technical><string>1</string><fret>0</fret></technical></notations>"
                ) + "</measure>",
            attributes:
                "<staves>2</staves><clef number=\"1\"><sign>G</sign><line>2</line></clef><clef number=\"2\"><sign>TAB</sign><line>5</line></clef>"
        )
        let part = try read(xml).parts[0]
        XCTAssertEqual(part.tabStaves, [2])
        XCTAssertEqual(part.soundingNotes().count, 1)
        XCTAssertEqual(part.soundingNotes()[0].string, 5)
        XCTAssertEqual(part.soundingNotes()[0].fret, 0)
        XCTAssertEqual(part.soundingNotes(staff: 2).count, 1)
    }
    func testTupletDurationComesFromDivisionsRatherThanVisualType() throws {
        let xml = score(
            note(
                duration: 1,
                extra:
                    "<type>eighth</type><time-modification><actual-notes>3</actual-notes><normal-notes>2</normal-notes></time-modification>"
            ) + "</measure>"
        ).replacingOccurrences(of: "<divisions>4</divisions>", with: "<divisions>3</divisions>")
        XCTAssertEqual(try read(xml).parts[0].notes[0].duration, 1.0 / 3, accuracy: 0.000001)
    }
    func testGraceRepeatAndPercussionHaveExplicitPlaybackLimits() throws {
        let xml = score(
            "<note><grace/><pitch><step>D</step><octave>4</octave></pitch><type>eighth</type></note>" + note()
                + "<note><unpitched/><duration>4</duration></note><barline><repeat direction=\"backward\"/></barline></measure>"
        )
        let document = try read(xml)
        XCTAssertEqual(document.parts[0].soundingNotes().count, 1)
        XCTAssertEqual(document.notices.count, 3)
        XCTAssertEqual(document.parts[0].notes.last?.midi, -1)
    }
    func testRejectsUnsupportedOrMalformedMusicXML() {
        let bad = [
            "", "<score-timewise/>",
            score(note() + "</measure>").replacingOccurrences(of: "<beats>4</beats>", with: "<beats>3+2</beats>"),
            score(note() + "</measure>").replacingOccurrences(
                of: "<octave>4</octave>", with: "<octave>999999</octave>"),
            score("<backup><duration>4</duration></backup>" + note() + "</measure>"),
            "<!DOCTYPE x [<!ENTITY boom 'expanded'>]>" + score(note() + "</measure>"),
        ]
        for xml in bad { XCTAssertThrowsError(try read(xml), xml.prefix(100).description) }
    }
    func testCompressedMusicXMLContainerAndMissingRoot() throws {
        func archive(root: String, score: Data) throws -> Data {
            let zip = try Archive(accessMode: .create)
            let container = Data(
                "<container><rootfiles><rootfile full-path=\"\(root)\" media-type=\"application/vnd.recordare.musicxml+xml\"/></rootfiles></container>"
                    .utf8)
            for (path, data) in [("META-INF/container.xml", container), ("score.musicxml", score)] {
                try zip.addEntry(
                    with: path, type: .file, uncompressedSize: Int64(data.count),
                    provider: { position, size in
                        data.subdata(in: Int(position)..<min(data.count, Int(position) + size))
                    })
            }
            return try XCTUnwrap(zip.data)
        }
        let data = try archive(root: "score.musicxml", score: Data(StudyExamples.smallSteps.utf8))
        XCTAssertEqual(try StudyImport.read(data).parts[0].notes.count, 20)
        XCTAssertThrowsError(
            try StudyImport.read(archive(root: "../score.musicxml", score: Data(StudyExamples.smallSteps.utf8))))
        XCTAssertThrowsError(try StudyImport.read(archive(root: "missing.musicxml", score: Data())))
    }
    func testPassageClipsTiesAtBothEdgesAndOmitsOtherBars() throws {
        var study = try example()
        study.document.parts[0].notes[0].start = 3
        study.document.parts[0].notes[0].duration = 7
        study.select(from: 1, through: 1)
        study.countIn = false
        let plan = try StudyPlaybackPlan(study: study)
        XCTAssertEqual(plan.cycleBeats, 4)
        XCTAssertTrue(plan.cycle.notes.allSatisfy { $0.start >= 0 && $0.start + $0.duration <= 4 })
        let clipped = try XCTUnwrap(plan.cycle.notes.first { $0.id == study.document.parts[0].notes[0].id })
        XCTAssertEqual(clipped.start, 0)
        XCTAssertEqual(clipped.duration, 4)
        XCTAssertEqual(plan.sourceStart, 4)
    }
    func testPracticeTempoCountInMetronomeAndLoopPosition() throws {
        var study = try example()
        study.select(from: 1, through: 1)
        study.speed = 0.5
        study.metronome = true
        let plan = try StudyPlaybackPlan(study: study)
        XCTAssertEqual(plan.tempo, 42)
        XCTAssertEqual(plan.introBeats, 4)
        XCTAssertEqual(plan.intro.notes.count, 4)
        XCTAssertEqual(plan.cycle.notes.count, 10)  // five melody notes + bass + four clicks
        let intro = plan.position(seconds: 2 * 60 / 42, loop: true)
        XCTAssertTrue(intro.isCountIn)
        XCTAssertEqual(intro.countInRemaining, 2, accuracy: 0.00001)
        let looped = plan.position(seconds: 13 * 60 / 42, loop: true)
        XCTAssertEqual(looped.cycle, 2)
        XCTAssertEqual(looped.sourceBeat, 5, accuracy: 0.00001)
        let ended = plan.position(seconds: 13 * 60 / 42, loop: false)
        XCTAssertEqual(ended.sourceBeat, 8, accuracy: 0.00001)
    }
    func testFingeringsReserveStringsForSustainedVoices() {
        let notes = [
            ScoreNote(midi: 64, start: 0, duration: 4, string: 5, fret: 0), ScoreNote(midi: 65, start: 1),
            ScoreNote(midi: 67, start: 2), ScoreNote(midi: 10, start: 3),
        ]
        let result = Score(notes: notes).fingered(tuning: Tuning.presets[0], capo: 0).notes
        XCTAssertEqual(result[0].string, 5)
        XCTAssertNotEqual(result[1].string, 5)
        XCTAssertNotEqual(result[2].string, 5)
        XCTAssertNil(result[3].string)
        for note in result where note.string != nil {
            XCTAssertEqual(Tuning.presets[0].pitches[note.string!] + note.fret!, note.midi)
        }
    }
    func testLibraryRoundTripAndRestorationClampsSelection() throws {
        var study = try example()
        study.from = -20
        study.through = 100
        study.speed = .infinity
        study.staff = 9
        let fixed = try study.restored()
        XCTAssertEqual(fixed.from, 0)
        XCTAssertEqual(fixed.through, 3)
        XCTAssertEqual(fixed.speed, 1)
        XCTAssertNil(fixed.staff)
        var library = StudyLibrary()
        library.add(fixed)
        XCTAssertEqual(try JSONDecoder().decode(StudyLibrary.self, from: JSONEncoder().encode(library)), library)
    }
    func testReferenceContainsOnlySelectedNotesAndPreservesPathwayLink() throws {
        var study = try example()
        study.select(from: 1, through: 1)
        study.notes = "Keep the bass ringing."
        let reference = study.reference
        XCTAssertTrue(reference.context.contains("Bars") == false)
        XCTAssertTrue(reference.context.contains("Bar 2"))
        XCTAssertTrue(reference.context.contains("F4"))
        XCTAssertFalse(reference.context.contains("bar 1, quarter-beat"))
        XCTAssertFalse(reference.context.contains("<score-partwise"))
        XCTAssertTrue(reference.context.contains("Keep the bass ringing."))
        let outline = PathwayOutline(
            title: "Study", summary: "Work on the passage", sourceNotes: "Imported notes", questions: [], steps: [])
        let path = LearningPathway(brief: LearningBrief(target: "A study"), outline: outline, study: reference)
        XCTAssertTrue(path.coachContext.contains(reference.context))
        let restored = try JSONDecoder().decode(LearningPathway.self, from: JSONEncoder().encode(path))
        XCTAssertEqual(restored.study, reference)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(path)) as? [String: Any])
        legacy.removeValue(forKey: "study")
        XCTAssertNil(
            try JSONDecoder().decode(LearningPathway.self, from: JSONSerialization.data(withJSONObject: legacy)).study)
    }
    func testCompoundMeterCountInUsesNotatedPulses() throws {
        var study = try example()
        study.select(from: 0, through: 0)
        study.document.parts[0].measures[0].beats = 6
        study.document.parts[0].measures[0].beatUnit = 8
        let plan = try StudyPlaybackPlan(study: study)
        XCTAssertEqual(plan.introBeats, 3)
        XCTAssertEqual(plan.intro.notes.count, 6)
        XCTAssertEqual(plan.position(seconds: 0, loop: true).countInRemaining, 6)
        XCTAssertEqual(plan.position(seconds: 0.5 * 60 / 84, loop: true).countInRemaining, 5, accuracy: 0.00001)
    }
    func testReferenceIncludesHeldNotesAndSourceFingerings() throws {
        var study = try example()
        study.document.parts[0].notes[0].duration = 6
        study.select(from: 1, through: 1)
        XCTAssertTrue(study.reference.context.contains("Held into the first selected bar: E4, for 2 quarter beats"))
        XCTAssertTrue(study.reference.context.contains("source technical fingering: string 1, fret 1"))
    }
    func testSelectionBoundsAndSlowTempoRemainUsable() throws {
        var study = try example()
        study.select(from: 100, through: -1)
        XCTAssertEqual(study.from, 3)
        XCTAssertEqual(study.through, 3)
        study.document.tempo = 20
        study.speed = 0.25
        XCTAssertEqual(try StudyPlaybackPlan(study: study).tempo, 5)
        study.speed = .nan
        XCTAssertThrowsError(try StudyPlaybackPlan(study: study))
    }

}
