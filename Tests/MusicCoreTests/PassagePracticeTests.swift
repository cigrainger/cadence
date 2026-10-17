// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class PassagePracticeTests: XCTestCase {
    private func study(_ instrument: EditorInstrument = .guitar) throws -> MusicStudy {
        try ComposePractice.make(instrument == .guitar ? .guitarExample : .pianoExample, from: 1, through: 2)
    }
    func testComposeCopyRetainsWholeScoreAndExactPassageAndSource() throws {
        var score = EditorDocument.guitarExample
        score.fifths = -2
        score.minor = true
        try score.setGuitar(tuning: Tuning("Drop D", [38, 45, 50, 55, 59, 64]), capo: 2)
        let study = try ComposePractice.make(score, from: 1, through: 2)
        XCTAssertEqual(study.sourceEditor?.scoreID, score.id)
        XCTAssertEqual(study.sourceEditor?.tuning, score.tuning)
        XCTAssertEqual(study.sourceEditor?.capo, 2)
        XCTAssertEqual(study.from, 1)
        XCTAssertEqual(study.through, 2)
        XCTAssertEqual(study.part.measures.count, 4)
        XCTAssertEqual(study.part.measures[1].minor, true)
        XCTAssertEqual(study.part.soundingNotes().map(\.midi), score.playback().notes.map(\.midi))
        let snapshot = study.document.originalXML
        try score.setPitch(score.events[0].id, midi: 61)
        XCTAssertEqual(study.document.originalXML, snapshot)
        XCTAssertNotEqual(try EditorXML.encode(score), snapshot)
    }
    func testComposeBoundsAndEmptyScoreAreRejected() throws {
        let blank = try EditorDocument.blank(instrument: .piano)
        XCTAssertThrowsError(try ComposePractice.make(blank, from: 0, through: 3))
        XCTAssertThrowsError(try ComposePractice.make(.guitarExample, from: 0, through: 4))
        var score = EditorDocument.guitarExample
        try score.insertBars(at: 4, count: 20)
        XCTAssertThrowsError(try ComposePractice.make(score, from: 0, through: 16))
    }
    func testTempoProgressIsScopedToPartStaffAndBars() throws {
        var study = try study(.piano)
        var book = PassagePracticeBook()
        var first = book.progress(for: study)
        first.targetBPM = 120
        try first.record(70)
        book.set(first)
        study.select(from: 0, through: 0)
        XCTAssertTrue(book.progress(for: study).comfortable.isEmpty)
        study.select(from: 1, through: 2)
        study.staff = 2
        XCTAssertTrue(book.progress(for: study).comfortable.isEmpty)
        study.staff = nil
        XCTAssertEqual(book.progress(for: study).bestBPM, 70)
        XCTAssertEqual(book.progress(for: study).targetBPM, 120)
    }
    func testTempoMarksAreSelfReportedBoundedAndDoNotAutomaticallyAdvance() throws {
        let study = try study()
        var progress = PassageTempoProgress(study: study)
        progress.targetBPM = 100
        progress.increment = 5
        XCTAssertEqual(progress.nextBPM(current: 70, sourceTempo: 90), 75)
        for i in 0..<205 { try progress.record(Double(60 + i % 20), date: Date(timeIntervalSince1970: Double(i))) }
        XCTAssertEqual(progress.comfortable.count, 200)
        XCTAssertEqual(progress.bestBPM, 79)
        XCTAssertEqual(study.speed, 1)
        XCTAssertFalse(progress.reachedTarget)
        try progress.record(100)
        XCTAssertTrue(progress.reachedTarget)
        XCTAssertEqual(progress.nextBPM(current: 99, sourceTempo: 90), 100)
        progress.targetBPM = 200
        XCTAssertEqual(progress.nextBPM(current: 134, sourceTempo: 90), 135)
        XCTAssertThrowsError(try progress.record(.infinity))
        XCTAssertThrowsError(try progress.record(451))
    }
    func testProgressAndPracticeSourceSurviveSaveAndLegacyStudiesStillDecode() throws {
        var study = try study()
        var book = PassagePracticeBook()
        var progress = PassageTempoProgress(study: study)
        progress.targetBPM = 115
        try progress.record(67.5)
        book.set(progress)
        study.practiceBook = book
        let restored = try JSONDecoder().decode(MusicStudy.self, from: JSONEncoder().encode(study)).restored()
        XCTAssertEqual(restored, study)
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(study)) as? [String: Any])
        data.removeValue(forKey: "practiceBook")
        data.removeValue(forKey: "sourceEditor")
        var document = data["document"] as! [String: Any]
        var parts = document["parts"] as! [[String: Any]]
        for i in parts.indices {
            parts[i]["measures"] = (parts[i]["measures"] as! [[String: Any]]).map {
                var measure = $0
                measure.removeValue(forKey: "minor")
                measure.removeValue(forKey: "keyMode")
                return measure
            }
        }
        document["parts"] = parts
        data["document"] = document
        let legacy = try JSONDecoder().decode(MusicStudy.self, from: JSONSerialization.data(withJSONObject: data))
            .restored()
        XCTAssertNil(legacy.practiceBook)
        XCTAssertNil(legacy.sourceEditor)
        XCTAssertEqual(legacy.selectedNotes.map(\.midi), study.selectedNotes.map(\.midi))
    }
    func testRestoreDiscardsInvalidProgressWithoutDiscardingScore() throws {
        var study = try study()
        var book = PassagePracticeBook()
        var progress = PassageTempoProgress(study: study)
        progress.targetBPM = .infinity
        book.tempos = [progress]
        study.practiceBook = book
        XCTAssertEqual(try study.restored().practiceBook?.tempos.count, 0)
        progress.targetBPM = 100
        progress.scope.from = -1
        book.tempos = [progress]
        study.practiceBook = book
        XCTAssertEqual(try study.restored().practiceBook?.tempos.count, 0)
    }
    func testCoachReferenceContainsActualPassageAndHonestTempoContext() throws {
        var study = try study()
        var book = PassagePracticeBook()
        var progress = PassageTempoProgress(study: study)
        progress.targetBPM = 105
        try progress.record(67.5)
        book.set(progress)
        study.practiceBook = book
        XCTAssertTrue(study.reference.context.contains("Self-reported comfortable tempos: 67.5"))
        XCTAssertTrue(study.reference.context.contains("not an assessment of audio"))
        XCTAssertTrue(study.reference.context.contains("Learner-set target: 105"))
        XCTAssertTrue(study.reference.context.contains("bar 2"))
        XCTAssertTrue(study.reference.context.contains("key mode major"))
        study.select(from: 0, through: 0)
        XCTAssertFalse(study.reference.context.contains("Self-reported comfortable tempos: 67.5"))
    }
    func testSingingVoicesExcludeDuplicateTabButKeepIndependentPianoHands() throws {
        let guitar = try study()
        XCTAssertEqual(SingingVoice.choices(guitar).map(\.staff), [1])
        let piano = try study(.piano)
        XCTAssertEqual(SingingVoice.choices(piano).map(\.staff), [1, 2])
        let voices = SingingVoice.choices(piano)
        let right = try PassageMelody(study: piano, voice: voices[0])
        let left = try PassageMelody(study: piano, voice: voices[1])
        XCTAssertEqual(right.notes.count, 8)
        XCTAssertEqual(left.notes.count, 2)
        XCTAssertTrue(left.reducedChords)
        XCTAssertFalse(right.reducedChords)
        XCTAssertEqual(left.notes.map { $0.tone.midi }, [52, 57])
    }
    func testSolfègeFollowsMinorAndEnharmonicSpelling() throws {
        let root = ScoreKey.tonic(fifths: 0, minor: true)
        XCTAssertEqual(root, Pitch(5))
        XCTAssertEqual(ScoreKey.tone(midi: 60, pitch: Pitch(0), tonic: root).solfege, "Me")
        XCTAssertEqual(ScoreKey.tone(midi: 66, pitch: Pitch(3, 1), tonic: Pitch(0)).solfege, "Fi")
        XCTAssertEqual(ScoreKey.tone(midi: 66, pitch: Pitch(4, -1), tonic: Pitch(0)).solfege, "Se")
        for fifths in -7...7 {
            for minor in [false, true] {
                let root = ScoreKey.tonic(fifths: fifths, minor: minor)
                let scale: Scale = minor ? .minor : .major
                let expected =
                    minor ? ["Do", "Re", "Me", "Fa", "Sol", "Le", "Te"] : ["Do", "Re", "Mi", "Fa", "Sol", "La", "Ti"]
                XCTAssertEqual(
                    scale.notes(root).map { ScoreKey.tone(midi: 60 + $0.pc, pitch: $0, tonic: root).solfege }, expected)
            }
        }
    }
    func testSingingGuideJoinsTiesAndClipsHeldNoteAtPassageStart() throws {
        var score = EditorDocument.guitarExample
        let i = 3
        let j = 4
        try score.setPitch(score.events[j].id, midi: score.events[i].pitches[0].midi)
        score.events[i].tieNext = true
        let study = try ComposePractice.make(score, from: 1, through: 1)
        let voice = SingingVoice.choices(study)[0]
        let melody = try PassageMelody(study: study, voice: voice)
        XCTAssertEqual(melody.notes.count, 4)
        XCTAssertEqual(melody.notes[0].start, 4)
        XCTAssertEqual(melody.notes[0].duration, 1)
        let whole = try ComposePractice.make(score, from: 0, through: 3)
        let wholeMelody = try PassageMelody(study: whole, voice: SingingVoice.choices(whole)[0])
        XCTAssertEqual(wholeMelody.notes.count, 14)
        XCTAssertEqual(wholeMelody.notes[3].duration, 2)
    }
    func testReferenceAudioPreservesGapsAndShiftsWholeOctaves() throws {
        var score = EditorDocument.guitarExample
        try score.setRhythm(score.events[0].id, EditorRhythm(240))
        let study = try ComposePractice.make(score, from: 0, through: 0)
        let melody = try PassageMelody(study: study, voice: SingingVoice.choices(study)[0])
        let audio = melody.audio(tempo: 60, octaves: -1)
        XCTAssertEqual(audio.notes.map(\.midi), melody.notes.map { $0.tone.midi - 12 })
        XCTAssertEqual(audio.notes[1].start, 1)
        XCTAssertEqual(audio.notes[0].duration, 0.5)
        XCTAssertEqual(audio.tempo, 60)
    }
    func testMelodyChecksWholeSequenceAndAllowsOneConsistentTransposition() {
        var echo = MelodyEchoAttempt()
        let targets = [60, 64, 62, 67]
        XCTAssertEqual(echo.hear(55, targets: targets, matchReference: false), .matched(1))
        XCTAssertEqual(echo.hear(59, targets: targets, matchReference: false), .matched(2))
        XCTAssertEqual(echo.hear(56, targets: targets, matchReference: false), .wrong(expected: 57, heard: 56))
        XCTAssertEqual(echo.hear(57, targets: targets, matchReference: false), .matched(3))
        XCTAssertEqual(echo.hear(62, targets: targets, matchReference: false), .complete)
        XCTAssertEqual(echo.hear(67, targets: targets, matchReference: false), .ignored)
    }
    func testRepeatedNotesNeedReleaseAndTiesCannotDoubleCount() {
        var echo = MelodyEchoAttempt()
        let targets = [60, 60, 62]
        XCTAssertEqual(echo.hear(60, targets: targets, matchReference: true), .matched(1))
        XCTAssertEqual(echo.hear(60, targets: targets, matchReference: true), .ignored)
        XCTAssertEqual(echo.hear(nil, targets: targets, matchReference: true), .ignored)
        XCTAssertEqual(echo.hear(60, targets: targets, matchReference: true), .matched(2))
        XCTAssertEqual(echo.hear(62, targets: targets, matchReference: true), .complete)
    }
    func testMatchingReferenceAcceptsSharedOctaveButRejectsChangingOctavesMidPhrase() {
        var echo = MelodyEchoAttempt()
        let targets = [60, 64, 67]
        XCTAssertEqual(echo.hear(61, targets: targets, matchReference: true), .wrong(expected: 60, heard: 61))
        XCTAssertEqual(echo.hear(48, targets: targets, matchReference: true), .matched(1))
        XCTAssertEqual(echo.hear(64, targets: targets, matchReference: true), .wrong(expected: 52, heard: 64))
        XCTAssertEqual(echo.hear(52, targets: targets, matchReference: true), .matched(2))
        XCTAssertEqual(echo.hear(55, targets: targets, matchReference: true), .complete)
    }
    func testSyntheticHeldPitchesCanDriveWholeMelody() throws {
        let targets = [60, 62, 64, 60]
        var echo = MelodyEchoAttempt()
        for midi in targets {
            let frequency = 440 * pow(2, Double(midi - 12 - 69) / 12)
            let samples = (0..<4096).map { Float(0.4 * sin(2 * Double.pi * frequency * Double($0) / 12000)) }
            let detection = try XCTUnwrap(PitchDetector.detect(samples, sampleRate: 12000))
            _ = echo.hear(nil, targets: targets, matchReference: true)
            _ = echo.hear(detection.midi, targets: targets, matchReference: true)
        }
        XCTAssertEqual(echo.matched, 4)
    }
    func testNonOctaveTransposingPartDoesNotGiveIncorrectSolfège() throws {
        let xml = try EditorXML.encode(.pianoExample).replacingOccurrences(
            of: "</attributes>",
            with: "<transpose><diatonic>-1</diatonic><chromatic>-2</chromatic></transpose></attributes>")
        let study = MusicStudy(document: try StudyImport.read(Data(xml.utf8)), filename: "transposing.xml")
        XCTAssertThrowsError(try PassageMelody(study: study, voice: SingingVoice.choices(study)[0]))
        XCTAssertFalse(study.selectedNotes.isEmpty)
    }
    func testExplicitOtherModesArePreservedAndRequireAnInterpretation() throws {
        let xml = try EditorXML.encode(.pianoExample).replacingOccurrences(
            of: "<mode>major</mode>", with: "<mode>dorian</mode>")
        let study = MusicStudy(document: try StudyImport.read(Data(xml.utf8)), filename: "mode.xml")
        XCTAssertEqual(study.selectedMeasures[0].keyMode, "dorian")
        XCTAssertTrue(study.reference.context.contains("key mode dorian"))
        XCTAssertThrowsError(try PassageMelody(study: study, voice: SingingVoice.choices(study)[0]))
    }
    func testOldStudyRecoversMinorKeyMetadataWithoutReplacingNoteIdentities() throws {
        var score = EditorDocument.pianoExample
        score.minor = true
        var old = try ComposePractice.make(score, from: 0, through: 1)
        let ids = old.part.notes.map(\.id)
        for p in old.document.parts.indices {
            for m in old.document.parts[p].measures.indices {
                old.document.parts[p].measures[m].minor = nil
                old.document.parts[p].measures[m].keyMode = nil
            }
        }
        let restored = try old.restored()
        XCTAssertEqual(restored.part.notes.map(\.id), ids)
        XCTAssertEqual(restored.selectedMeasures[0].minor, true)
        XCTAssertEqual(restored.selectedMeasures[0].keyMode, "minor")
        let melody = try PassageMelody(study: restored, voice: SingingVoice.choices(restored)[0])
        XCTAssertEqual(melody.notes.first?.tone.solfege, "Sol")
    }

}
