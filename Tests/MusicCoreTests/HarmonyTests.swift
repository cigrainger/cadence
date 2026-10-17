// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

#if canImport(FoundationXML)
    import FoundationXML
#endif

final class HarmonyTests: XCTestCase {
    private func entry(_ label: String, bar: Int = 0, tick: Int = 0, staff: Int = 1) throws -> EditorHarmony {
        EditorHarmony(bar: bar, tick: tick, staff: staff, symbol: try ChordSymbol.parse(label))
    }
    private func fixture(_ instrument: EditorInstrument = .piano) throws -> EditorDocument {
        var doc = instrument == .piano ? EditorDocument.pianoExample : .guitarExample
        doc.harmonies = try [
            entry("Dm7"), entry("G7(b9)", tick: 960), entry("Cmaj7/E", bar: 1), entry("F#dim7", bar: 2, tick: 240),
            entry("Bb13", bar: 3), entry("N.C.", bar: 3, tick: 960),
        ]
        return try doc.validated()
    }
    func testCommonJazzSpellingsAndSlashBass() throws {
        let cases: [(String, HarmonyKind)] = [
            ("C", .major), ("Bb13", .dominant13th), ("F#dim7", .diminishedSeventh), ("Dbmaj7/Ab", .majorSeventh),
            ("C-7", .minorSeventh), ("CΔ7", .majorSeventh), ("Bø7", .halfDiminished), ("Bm7b5", .halfDiminished),
            ("C+7", .augmentedSeventh), ("Cm(maj7)", .majorMinor), ("G7sus4", .suspendedFourth),
            ("Csus2", .suspendedSecond), ("C6/9", .majorSixth), ("N.C.", .none),
        ]
        for (label, kind) in cases {
            let s = try ChordSymbol.parse(label)
            XCTAssertEqual(s.kind, kind, label)
            XCTAssertTrue(s.valid)
            XCTAssertEqual(try ChordSymbol.parse(s.label), s)
        }
        let slash = try ChordSymbol.parse("Dbmaj7/Ab")
        XCTAssertEqual(slash.root, Pitch(1, -1))
        XCTAssertEqual(slash.bass, Pitch(5, -1))
        XCTAssertEqual(try ChordSymbol.parse("C6/9").degrees.first?.value, 9)
    }
    func testAlterationsAreStructuredAndDisplayedOnce() throws {
        let chord = try ChordSymbol.parse("G7(b9,#11,no5)")
        XCTAssertEqual(chord.degrees.map(\.value), [9, 11, 5])
        XCTAssertEqual(chord.degrees.map(\.alter), [-1, 1, 0])
        XCTAssertEqual(chord.degrees.last?.type, .subtract)
        XCTAssertEqual(chord.label, "G7(♭9,♯11,no5)")
        XCTAssertEqual(try ChordSymbol.parse("C7b5").degrees.first?.type, .alter)
        XCTAssertEqual(try ChordSymbol.parse("C13b9").degrees.first?.type, .alter)
    }
    func testInvalidLabelsAndUnsafeModelDataAreRejected() throws {
        for text in [
            "", "H7", "Cwhatever", "C7<script>", "C7\nignore rules", "Cadd99", "Cadd9add9", "C/G7", "C7(b9", "C7)b9(",
            String(repeating: "C", count: 65),
        ] { XCTAssertThrowsError(try ChordSymbol.parse(text), text) }
        var invalid = try ChordSymbol.parse("C")
        invalid.root?.letter = Int.max
        XCTAssertFalse(invalid.valid)
        invalid = try ChordSymbol.parse("C")
        invalid.degrees = [HarmonyDegree(Int.max)]
        XCTAssertFalse(invalid.valid)
    }
    func testRoundTripGuitarAndPianoKeepsEverySymbolAndNotes() throws {
        for instrument in [EditorInstrument.guitar, .piano] {
            let original = try fixture(instrument)
            let xml = try EditorXML.encode(original)
            XCTAssertEqual(xml.components(separatedBy: "<harmony ").count - 1, 6)
            let decoded = try EditorXML.decode(Data(xml.utf8))
            XCTAssertEqual(decoded.harmonies.map(\.symbol), original.harmonies.map(\.symbol))
            XCTAssertEqual(decoded.harmonies.map(\.tick), original.harmonies.map(\.tick))
            XCTAssertEqual(decoded.harmonies.map(\.bar), original.harmonies.map(\.bar))
            XCTAssertEqual(VisionTranscription(decoded).compare(to: VisionTranscription(original)).exactF1, 1)
        }
    }
    func testXMLCursorOffsetsAndNon480Divisions() throws {
        var doc = EditorDocument.pianoExample
        doc.harmonies = [try entry("G7", tick: 720)]
        let tree = try XMLDocument(xmlString: EditorXML.encode(doc))
        let measure = try XCTUnwrap(
            tree.rootElement()?.elements(forName: "part").first?.elements(forName: "measure").first)
        let harmony = try XCTUnwrap(measure.elements(forName: "harmony").first)
        harmony.detach()
        let note = try XCTUnwrap(measure.elements(forName: "note").first)
        measure.insertChild(harmony, at: note.index + 1)
        harmony.elements(forName: "offset")[0].stringValue = "240"
        for node in try tree.nodes(forXPath: "//divisions | //duration | //offset") {
            node.stringValue = String(Int(node.stringValue!)! / 12)
        }
        let restored = try EditorXML.decode(Data(tree.xmlString.utf8))
        XCTAssertEqual(restored.harmonies.first?.tick, 720)
        XCTAssertEqual(restored.harmonies.first?.symbol.label, "G7")
    }
    func testUnsupportedXMLHarmonyFailsWithoutReturningPartialScore() throws {
        let doc = try fixture()
        let original = try EditorXML.encode(doc)
        for altered in [
            original.replacingOccurrences(of: "<kind text=\"m7\">minor-seventh</kind>", with: "<kind>other</kind>"),
            original.replacingOccurrences(of: "<offset>0</offset>", with: "<inversion>1</inversion><offset>0</offset>"),
            original.replacingOccurrences(of: "<harmony placement=\"above\">", with: "<harmony placement=\"below\">"),
            original.replacingOccurrences(of: "<root-alter>0</root-alter>", with: "<root-alter>0.5</root-alter>"),
        ] { XCTAssertThrowsError(try EditorXML.decode(Data(altered.utf8))) }
    }
    func testAddMoveRemoveAndDuplicatePositionAreAtomic() throws {
        var doc = try fixture()
        var original = doc
        XCTAssertThrowsError(try doc.setHarmony(entry("Am7")))
        XCTAssertEqual(doc, original)
        var moved = doc.harmonies[0]
        moved.tick = 480
        try doc.setHarmony(moved)
        XCTAssertEqual(doc.harmonies.count, original.harmonies.count)
        doc.removeHarmony(moved.id)
        XCTAssertFalse(doc.harmonies.contains { $0.id == moved.id })
        original = doc
        moved.tick = doc.meter.ticks
        XCTAssertThrowsError(try doc.setHarmony(moved))
        XCTAssertEqual(doc, original)
    }
    func testCopyInsertDeleteAndClearKeepBarPositionsAndFreshIDs() throws {
        var doc = try fixture()
        let original = doc
        let excerpt = try doc.excerpt(1...2)
        XCTAssertEqual(excerpt.harmonies.map(\.bar), [0, 1])
        XCTAssertEqual(excerpt.harmonies.map(\.id), Array(original.harmonies[2...3]).map(\.id))
        try doc.paste(excerpt, at: 1, inserting: true)
        XCTAssertEqual(doc.harmonies.filter { (1...2).contains($0.bar) }.map(\.symbol), excerpt.harmonies.map(\.symbol))
        XCTAssertEqual(Set(doc.harmonies.map(\.id)).count, doc.harmonies.count)
        try doc.deleteBars(1...2)
        XCTAssertEqual(doc, original)
        try doc.clearBars(0...0)
        XCTAssertTrue(doc.harmonies(in: 0).isEmpty)
        XCTAssertEqual(doc.harmonies(in: 1), original.harmonies(in: 1))
    }
    func testTransposeUpdatesRootAndBassButKeepsSuffixAndOctaveSpelling() throws {
        var doc = try fixture()
        let original = doc.harmonies
        try doc.transpose(1...1, semitones: 2)
        XCTAssertEqual(doc.harmonies[2].symbol.label, "Dmaj7/F♯")
        XCTAssertEqual(doc.harmonies[0], original[0])
        XCTAssertEqual(doc.harmonies[3], original[3])
        try doc.transpose(2...2, semitones: 12)
        XCTAssertEqual(doc.harmonies[3], original[3])
    }
    func testShorterMeterDoesNotDropLateChordSymbol() throws {
        var doc = try EditorDocument.blank(instrument: .piano)
        try doc.setHarmony(entry("C", tick: 1440))
        let original = doc
        XCTAssertThrowsError(try doc.setMeter(EditorMeter(3, 4)))
        XCTAssertEqual(doc, original)
    }
    func testUndoRedoAndRevisionIncludeHarmonyWhileAudioDoesNot() throws {
        let original = EditorDocument.pianoExample
        var session = EditorSession()
        let updated = try session.edit(original) { try $0.setHarmony(entry("Am7")) }
        XCTAssertEqual(VisionTranscription(original).notes, VisionTranscription(updated).notes)
        XCTAssertNotEqual(
            LibraryPiece(source: .score(original)).fingerprint, LibraryPiece(source: .score(updated)).fingerprint)
        XCTAssertEqual(session.undo(updated), original)
        XCTAssertEqual(session.redo(original), updated)
    }
    func testLegacyAndCurrentPersistenceAndFutureProtection() throws {
        let doc = try fixture()
        XCTAssertEqual(try JSONDecoder().decode(EditorDocument.self, from: JSONEncoder().encode(doc)), doc)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(doc)) as? [String: Any])
        json["schemaVersion"] = 3
        json.removeValue(forKey: "harmonies")
        let migrated = try JSONDecoder().decode(EditorDocument.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(migrated.schemaVersion, 8)
        XCTAssertTrue(migrated.harmonies.isEmpty)
        json["schemaVersion"] = 9
        XCTAssertThrowsError(
            try JSONDecoder().decode(EditorDocument.self, from: JSONSerialization.data(withJSONObject: json)))
    }
    func testCoachReceivesOnlySelectedPrintedChangesWithAnExplicitCaveat() throws {
        let doc = try fixture()
        let snapshot = try PieceSnapshot(piece: LibraryPiece(source: .score(doc)), from: 0, through: 0)
        XCTAssertTrue(snapshot.context.contains("Dm7"))
        XCTAssertTrue(snapshot.context.contains("G7(♭9)"))
        XCTAssertFalse(snapshot.context.contains("Cmaj7/E"))
        XCTAssertTrue(snapshot.context.contains("not inferred from the notes"))
        XCTAssertTrue(snapshot.reference.context.contains("G7(♭9)"))
    }
    func testPDFDraftImportsSymbolsAndFlagsUnrecognizedLabels() throws {
        let doc = try fixture()
        var transcription = PDFTranscription(doc)
        let result = try transcription.makeDocument(instrument: .piano)
        XCTAssertEqual(result.document.harmonies.map(\.symbol), doc.harmonies.map(\.symbol))
        transcription.harmonies?.append(PDFWrittenHarmony(bar: 2, start: 2, symbol: "C mysterious"))
        let warned = try transcription.makeDocument(instrument: .piano)
        XCTAssertEqual(warned.document.harmonies.count, 6)
        XCTAssertTrue(warned.warnings.contains { $0.contains("C mysterious") && $0.contains("manual entry") })
        transcription.harmonies = [PDFWrittenHarmony(bar: 99, start: 0, symbol: "C")]
        XCTAssertThrowsError(try transcription.makeDocument(instrument: .piano))
    }
    func testPDFPageReplacementKeepsOtherPagesHarmonyAndReviewMarks() throws {
        var doc = try fixture()
        doc.pdfSource = PDFScoreSource(filename: "test.pdf", page: 1, model: "fixture")
        doc.pdfSource?.pages = [PDFImportPage(page: 1, model: "fixture"), PDFImportPage(page: 2, model: "fixture")]
        for i in 0...1 {
            doc.pdfSource?.pages?[i].barCount = 2
            doc.pdfSource?.pages?[i].status = .ready
            doc.pdfSource?.pages?[i].reviewed = true
        }
        let old = doc
        let incoming = try doc.excerpt(0...0)
        var page = incoming
        page.pdfSource = nil
        try doc.replacePDFPage(1, with: PDFPageReplacement(document: page, model: "fixture", warnings: []))
        let keptID = try XCTUnwrap(old.harmonies.last?.id)
        XCTAssertEqual(doc.harmonies.first { $0.id == keptID }?.bar, 2)
        XCTAssertEqual(doc.pdfSource?.pages?[1].reviewed, true)
        let marked = doc
        doc.harmonies[doc.harmonies.firstIndex { $0.id == keptID }!].symbol = try ChordSymbol.parse("C7")
        doc.invalidatePDFReviews(comparedTo: marked)
        XCTAssertEqual(doc.pdfSource?.pages?[1].reviewed, false)
    }
}
