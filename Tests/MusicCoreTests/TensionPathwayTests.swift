// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class TensionPathwayTests: XCTestCase {
    func source() throws -> TensionSource {
        try .init(
            piece: .init(source: .score(TensionSource.example())),
            scope: .init(partID: "P1", staff: 1, from: 0, through: 3), tonic: Pitch(0))
    }
    func session() throws -> TensionSession { .init(source: try source(), instrument: .piano, majorSlot: 1) }
    func testExampleIsValidOriginalWithWrittenMelodyAndHarmony() throws {
        let doc = try TensionSource.example()
        _ = try doc.validated()
        XCTAssertEqual(doc.harmonies.map(\.symbol.label), ["A7", "Dm7", "G7", "Cmaj7"])
        XCTAssertEqual(doc.events.filter { $0.staff == 1 }.map { $0.pitches[0].spelling.name }, ["C♯", "D", "B", "C"])
        let m = try source()
        XCTAssertTrue(m.valid)
        XCTAssertEqual(m.reading.roman, "V7/ii")
        XCTAssertEqual(m.reading.convention, "Jazz / tonal · C major")
        XCTAssertEqual(m.leadingTone.name, "C♯")
        XCTAssertEqual(m.resolution.name, "D")
    }
    func testPrimaryDominantAndUnsupportedPassageAreNotClaimedApplied() throws {
        var doc = try TensionSource.example()
        doc.harmonies = try ["Dm7", "G7", "Cmaj7", "Cmaj7"].enumerated().map {
            .init(bar: $0.offset, symbol: try .parse($0.element))
        }
        XCTAssertThrowsError(
            try TensionSource(
                piece: .init(source: .score(doc)), scope: .init(partID: "P1", staff: 1, from: 0, through: 3),
                tonic: Pitch(0)))
        XCTAssertFalse(HarmonyTheory.resolves(try .parse("Asus4"), to: try .parse("Dm7")))
        XCTAssertFalse(HarmonyTheory.resolves(try .parse("A7"), to: try .parse("Ddim")))
        XCTAssertFalse(HarmonyTheory.resolves(try .parse("A7"), to: try .parse("E7")))
        XCTAssertFalse(HarmonyTheory.isDominant(try .parse("Amaj7")))
        XCTAssertTrue(HarmonyTheory.isDominant(try .parse("A9")))
    }
    func testSpellingInDifferentKeysAndAlterations() throws {
        for (first, next, tonic, label) in [
            ("E7", "Am7", Pitch(4), "V7/ii"), ("F7", "Bbm7", Pitch(5, -1), "V7/ii"), ("D7", "G", Pitch(0), "V7/V"),
        ] {
            XCTAssertEqual(
                HarmonyTheory.suggestion(try .parse(first), next: try .parse(next), tonic: tonic).roman, label)
        }
        XCTAssertEqual(HarmonyTheory.roman(try .parse("Abmaj7"), tonic: Pitch(0)), "♭VImaj7")
        XCTAssertEqual(HarmonyTheory.roman(try .parse("Bm7b5"), tonic: Pitch(0)), "viiø7")
        XCTAssertEqual(HarmonyTheory.roman(try .parse("Bdim7"), tonic: Pitch(0)), "vii°7")
        XCTAssertEqual(HarmonyTheory.roman(try .parse("Dm9"), tonic: Pitch(0)), "ii9")
        XCTAssertEqual(HarmonyTheory.roman(try .parse("N.C."), tonic: Pitch(0)), "N.C.")
        XCTAssertEqual(HarmonyTheory.roman(try .parse("Csus4"), tonic: Pitch(0)), "?")
        XCTAssertEqual(
            HarmonyTheory.suggestion(try .parse("G7"), next: try .parse("C"), tonic: Pitch(0)).function, .dominant)
    }
    func testRevisionAndCorruptMaterialBounds() throws {
        let source = try source()
        var doc = try TensionSource.example()
        XCTAssertTrue(source.current(in: .init(source: .score(doc))))
        doc.title = "Renamed"
        XCTAssertTrue(source.current(in: .init(source: .score(doc))))
        doc.harmonies[0].symbol = try .parse("Am7")
        XCTAssertFalse(source.current(in: .init(source: .score(doc))))
        var bad = source
        bad.pair = 200
        XCTAssertFalse(bad.valid)
        bad = source
        bad.changes[1].bar = 0
        XCTAssertFalse(bad.valid)
        bad = source
        bad.tonic.letter = 100
        XCTAssertFalse(bad.valid)
        bad = source
        bad.changes[0].partID = "other"
        XCTAssertFalse(bad.valid)
        bad = source
        bad.scope.through = Int.max
        XCTAssertFalse(bad.valid)
    }
    func testComparisonChangesOnlyThirdWithEqualTimingAndDynamics() throws {
        let a = try source().comparison(majorThird: false)
        let b = try source().comparison(majorThird: true)
        XCTAssertEqual(a.notes.count, b.notes.count)
        XCTAssertEqual(a.tempo, b.tempo)
        XCTAssertEqual(zip(a.notes, b.notes).filter { $0.midi != $1.midi }.count, 1)
        for (x, y) in zip(a.notes, b.notes) {
            XCTAssertEqual(x.start, y.start)
            XCTAssertEqual(x.duration, y.duration)
        }
    }
    func testHearingRequiresBothVersionsAndWrongAnswerRetries() throws {
        var s = try session()
        XCTAssertThrowsError(try s.apply(.hearChoice(1)))
        XCTAssertThrowsError(try s.apply(.heard(2)))
        XCTAssertNil(try s.apply(.heard(0)))
        XCTAssertNil(try s.apply(.heard(1)))
        let miss = try s.apply(.hearChoice(0))!
        XCTAssertEqual(miss.outcome, .incorrect)
        XCTAssertEqual(s.skill, .hearing)
        let hit = try s.apply(.hearChoice(1))!
        XCTAssertTrue(hit.assisted)
        XCTAssertEqual(s.skill, .explaining)
        XCTAssertEqual(s.reviews[TheorySkill.hearing.rawValue]?.lastGrade, .again)
        XCTAssertThrowsError(try s.apply(.hearChoice(1)))
    }
    func testSeparateLearningEvidenceAndCreativeReport() throws {
        var s = try session()
        _ = try s.apply(.heard(0))
        _ = try s.apply(.heard(1))
        let ear = try s.apply(.hearChoice(1))!
        let explanation = try s.apply(.explanation(0))!
        let playing = try s.apply(.midi([73, 74]))!
        let creation = try s.apply(.creation("I delayed the arrival."))!
        XCTAssertEqual([ear, explanation, playing, creation].map(\.input), [.choice, .choice, .midi, .selfReport])
        XCTAssertEqual(Set([ear, explanation, playing, creation].map(\.activityID)).count, 4)
        XCTAssertTrue(s.completed)
        XCTAssertEqual(s.reviews.count, 4)
        XCTAssertTrue(s.reviews.values.allSatisfy { $0.lastGrade == .supported })
        XCTAssertThrowsError(try s.apply(.skip))
    }
    func testPianoAcceptsAnyOctaveButNotWrongDirectionOrOctaveLeap() throws {
        var s = try session()
        _ = try s.apply(.skip)
        _ = try s.apply(.skip)
        for notes in [[61, 50], [61, 74], [60, 62]] {
            XCTAssertEqual(try s.apply(.midi(notes))?.outcome, .incorrect)
            XCTAssertEqual(s.skill, .playing)
        }
        XCTAssertThrowsError(try s.apply(.midi([])))
        XCTAssertThrowsError(try s.apply(.midi([-1, 0])))
        XCTAssertEqual(try s.apply(.midi([49, 50]))?.outcome, .correct)
    }
    func testIndependentReturnAdvancesOnlyTargetDimension() throws {
        var s = try session()
        for _ in 0..<4 { _ = try s.apply(.skip, now: Date(timeIntervalSince1970: 1000)) }
        let before = s.reviews
        s.beginReview(.explaining, now: Date(timeIntervalSince1970: 100000))
        let attempt = try s.apply(.explanation(0), now: Date(timeIntervalSince1970: 100001))!
        XCTAssertFalse(attempt.assisted)
        XCTAssertTrue(s.completed)
        XCTAssertEqual(s.reviews[TheorySkill.explaining.rawValue]?.intervalDays, 1)
        for skill in [TheorySkill.hearing, .playing, .creating] {
            XCTAssertEqual(s.reviews[skill.rawValue], before[skill.rawValue])
        }
    }
    func testRevealAndRetryCannotEarnIndependentRecall() throws {
        for hint in [true, false] {
            var s = try session()
            s.beginReview(.explaining)
            if hint { _ = try s.apply(.reveal) } else { _ = try s.apply(.explanation(1)) }
            let hit = try s.apply(.explanation(0))!
            XCTAssertTrue(hit.assisted)
            XCTAssertEqual(s.reviews[TheorySkill.explaining.rawValue]?.intervalDays, 0)
        }
    }
    func testGuitarAndCompositionStaySelfReportedEvenOnReturn() throws {
        var s = TensionSession(source: try source(), instrument: .guitar)
        s.beginReview(.playing)
        XCTAssertThrowsError(try s.apply(.midi([61, 62])))
        let report = try s.apply(.guitarReport)!
        XCTAssertEqual(report.input, .selfReport)
        XCTAssertTrue(report.assisted)
        XCTAssertEqual(s.reviews[TheorySkill.playing.rawValue]?.lastGrade, .supported)
        s.beginReview(.creating)
        XCTAssertThrowsError(try s.apply(.creation(" \n ")))
        XCTAssertThrowsError(try s.apply(.creation(String(repeating: "a", count: 2001))))
        let creative = try s.apply(.creation("I made space."))!
        XCTAssertEqual(creative.outcome, .revealed)
        XCTAssertEqual(s.reviews[TheorySkill.creating.rawValue]?.intervalDays, 0)
    }
    func testAnswerIsBlankEditableLinkedAndDoesNotMutateSource() throws {
        let m = try source()
        let original = try TensionSource.example()
        for instrument in EditorInstrument.allCases {
            let answer = try m.answerDocument(instrument: instrument)
            _ = try answer.validated()
            XCTAssertEqual(answer.tensionSource, m)
            XCTAssertEqual(answer.barCount, 2)
            XCTAssertTrue(answer.events.allSatisfy(\.isRest))
            XCTAssertNotEqual(answer.id, original.id)
            XCTAssertEqual(answer.harmonies.map(\.symbol), [m.dominant, m.destination])
            XCTAssertEqual(try JSONDecoder().decode(EditorDocument.self, from: JSONEncoder().encode(answer)), answer)
        }
    }
    func testAnnotationAlternativesAndSafeXMLDisplay() throws {
        let piece = LibraryPiece(source: .score(try TensionSource.example()))
        let m = try source()
        var analysis = ScoreAnalysis(piece: piece)
        var first = HarmonicReading(roman: "V7/ii <script>&", function: .applied, explanation: "An interpretation")
        try analysis.set(.init(anchor: m.changes[0], readings: [first, .init(roman: "VI7", function: .colour)]))
        XCTAssertTrue(analysis.valid)
        XCTAssertEqual(analysis.annotations.count, 1)
        first.roman = "V7/ii"
        try analysis.set(.init(anchor: m.changes[0], readings: [first]))
        XCTAssertEqual(analysis.annotations.count, 1)
        first.roman = "<script>&"
        try analysis.set(.init(anchor: m.changes[0], readings: [first]))
        let displayed = try HarmonyTheory.displayStudy(piece: piece, partID: "P1", analysis: analysis)
        XCTAssertTrue(displayed.document.originalXML.contains("&lt;script&gt;&amp;"))
        XCTAssertFalse(displayed.document.originalXML.contains("<script>"))
        XCTAssertEqual(
            try StudyImport.read(Data(displayed.document.originalXML.utf8)).parts[0].notes.count,
            displayed.document.parts[0].notes.count)
        XCTAssertEqual(piece.fingerprint, LibraryPiece(source: .score(try TensionSource.example())).fingerprint)
    }
    func testAnalysisValidationRejectsDuplicatesAndExcessiveInput() throws {
        let piece = LibraryPiece(source: .score(try TensionSource.example()))
        let m = try source()
        var analysis = ScoreAnalysis(piece: piece)
        var item = HarmonicAnnotation(anchor: m.changes[0], readings: [.init(roman: "V7/ii")])
        item.readings.append(item.readings[0])
        XCTAssertFalse(item.valid)
        XCTAssertThrowsError(try analysis.set(item))
        item.readings = [.init(roman: String(repeating: "I", count: 81))]
        XCTAssertFalse(item.valid)
        item.readings = []
        XCTAssertFalse(item.valid)
        analysis.annotations = [
            .init(anchor: m.changes[0], readings: [.init()]), .init(anchor: m.changes[0], readings: [.init()]),
        ]
        XCTAssertFalse(analysis.valid)
    }
    func testBookRoundTripLegacyAndInvalidSnapshots() throws {
        var state = PracticeState()
        var book = TensionPractice()
        let s = try session()
        book.sessions = [s]
        book.activeID = s.id
        state.tension = book
        XCTAssertEqual(
            try JSONDecoder().decode(PracticeState.self, from: JSONEncoder().encode(state)).validated(), state)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        json.removeValue(forKey: "tension")
        json["schemaVersion"] = 13
        let old = try JSONDecoder().decode(PracticeState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.tension)
        XCTAssertEqual(try old.validated().schemaVersion, 15)
        book.sessions.append(s)
        XCTAssertThrowsError(try book.validated())
        book.sessions = [s]
        book.activeID = UUID()
        XCTAssertThrowsError(try book.validated())
        state.schemaVersion = 99
        XCTAssertThrowsError(try state.validated())
    }
    func testReviewGateAndCarriedSourceAreVerified() throws {
        var doc = try TensionSource.example()
        doc.pdfSource = .init(filename: "Original.pdf", page: 3, model: "fixture")
        doc.harmonies.removeAll { $0.bar == 1 }
        doc.harmonies[1].symbol = try .parse("Dm7")
        let make: (EditorDocument) throws -> TensionSource = {
            try .init(
                piece: .init(source: .score($0)), scope: .init(partID: "P1", staff: 1, from: 1, through: 3),
                tonic: Pitch(0))
        }
        XCTAssertThrowsError(try make(doc))
        doc.pdfSource?.reviewed = true
        let carried = try make(doc)
        XCTAssertEqual(carried.changes[0].bar, 0)
        XCTAssertTrue(carried.valid)
        var first = PDFImportPage(page: 3, model: "fixture")
        first.barCount = 1
        first.status = .ready
        var rest = PDFImportPage(page: 4, model: "fixture")
        rest.barCount = 3
        rest.status = .ready
        rest.reviewed = true
        doc.pdfSource?.pages = [first, rest]
        XCTAssertThrowsError(try make(doc))
        doc.pdfSource?.pages?[0].reviewed = true
        XCTAssertTrue(try make(doc).valid)
    }
    func testDisplayAnnotationsRespectPartDivisionsAndSourceRevision() throws {
        var doc = try TensionSource.example()
        doc.harmonies[0].tick = 480
        let piece = LibraryPiece(source: .score(doc))
        let scope = PassageScope(partID: "P1", staff: 1, from: 0, through: 3)
        let anchor = try HarmonyTheory.anchors(piece: piece, scope: scope)[0]
        var analysis = ScoreAnalysis(piece: piece)
        try analysis.set(.init(anchor: anchor, readings: [.init(roman: "V7/ii")]))
        let shown = try HarmonyTheory.displayStudy(piece: piece, partID: "P1", analysis: analysis)
        let xml = try XMLDocument(xmlString: shown.document.originalXML)
        let words = try xml.nodes(forXPath: "//direction[direction-type/words='V7/ii']/offset")
        let divisions = try xml.nodes(forXPath: "//part/measure/attributes/divisions").first!.stringValue!
        XCTAssertEqual(Double(words[0].stringValue!)!, Double(divisions)!)
        analysis.fingerprint = String(repeating: "a", count: 64)
        let stale = try HarmonyTheory.displayStudy(piece: piece, partID: "P1", analysis: analysis)
        XCTAssertFalse(stale.document.originalXML.contains("V7/ii"))
    }
    func testInvalidInputsAreBoundedAndOlderScoreMigrates() throws {
        XCTAssertEqual(HarmonyTheory.majorTonic(fifths: Int.max), Pitch(0, 1))
        var invalid = Pitch(0)
        invalid.letter = 100
        XCTAssertEqual(HarmonyTheory.roman(try .parse("C"), tonic: invalid), "?")
        XCTAssertThrowsError(
            try TensionSource(
                piece: .init(source: .score(TensionSource.example())),
                scope: .init(partID: "P1", staff: 1, from: Int.min, through: Int.max), tonic: Pitch(0)))
        var data =
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(TensionSource.example())) as! [String: Any]
        data["schemaVersion"] = 6
        data.removeValue(forKey: "tensionSource")
        let migrated = try JSONDecoder().decode(EditorDocument.self, from: JSONSerialization.data(withJSONObject: data))
        XCTAssertEqual(migrated.schemaVersion, 8)
        XCTAssertNil(migrated.tensionSource)
        _ = try migrated.validated()
    }

    func testComparisonSopranoDemonstratesThePractisedResolution() throws {
        let source = try source()
        let score = source.comparison(majorThird: true)
        XCTAssertEqual(score.notes.filter { $0.start == 0 }.map(\.midi).max(), source.melody[0])
        XCTAssertEqual(score.notes.filter { $0.start == 4 }.map(\.midi).max(), source.melody[1])
        XCTAssertEqual(
            score.notes.filter { $0.start == 4 }.map(\.midi),
            source.comparison(majorThird: false).notes.filter { $0.start == 4 }.map(\.midi))
    }

}
