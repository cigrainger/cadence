// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class TriadPathwayTests: XCTestCase {
    func document() throws -> EditorDocument {
        var doc = try EditorDocument.blank(instrument: .guitar, bars: 4, meter: .init(4, 4))
        doc.title = "Three changes"
        doc.harmonies = try ["Dm7", "G7", "Cmaj7", "Cmaj7"].enumerated().map {
            EditorHarmony(bar: $0.offset, symbol: try ChordSymbol.parse($0.element))
        }
        return doc
    }
    func material(group: Int = 0) throws -> TriadMaterial {
        try TriadMaterial(
            piece: .init(source: .score(document())), scope: .init(partID: "P1", staff: 1, from: 0, through: 3),
            tuning: .presets[0], capo: 0, group: group)
    }
    func testExtendedAndAlteredChordReductionsPreserveSpelling() throws {
        XCTAssertEqual(try TriadNeck.tones(.parse("Dm9")).map(\.name), ["D", "F", "A"])
        XCTAssertEqual(try TriadNeck.tones(.parse("F#dim7")).map(\.name), ["F♯", "A", "C"])
        XCTAssertEqual(try TriadNeck.tones(.parse("Cmaj7/E")).map(\.pc), [0, 4, 7])
        XCTAssertEqual(try TriadNeck.tones(.parse("G7(#5)")).map(\.pc), [7, 11, 3])
    }
    func testUnsupportedHarmonyNeverGuessed() throws {
        for symbol in ["N.C.", "Csus4", "Csus2", "C5", "C7(no3)", "C7(no5)", "C7(b5,#5)"] {
            XCTAssertThrowsError(try TriadNeck.tones(ChordSymbol.parse(symbol)), symbol)
        }
    }
    func testAllKeysSetsAndInversionsSoundExactlyThreeTones() throws {
        for root in 0..<12 {
            for kind in [HarmonyKind.major, .minor, .diminished, .augmented] {
                let tones = try TriadNeck.tones(.init(root: Pitch.spelled(root), kind: kind))
                for group in 0...3 {
                    let shapes = TriadNeck.shapes(tones, tuning: .presets[0], capo: 0, group: group)
                    XCTAssertFalse(shapes.isEmpty)
                    for shape in shapes {
                        XCTAssertEqual(Set(shape.notes.map { mod($0) }), Set(tones.map(\.pc)))
                        XCTAssertEqual(
                            shape.frets.enumerated().filter { $0.element >= 0 }.map(\.offset),
                            Array((3 - group)...(5 - group)))
                        XCTAssertEqual(mod(shape.notes.min()!), tones[shape.inversion.rawValue].pc)
                    }
                }
            }
        }
        let shapes = TriadNeck.shapes(try TriadNeck.tones(.parse("C")), tuning: .presets[0], capo: 0, group: 0)
        XCTAssertEqual(Set(shapes.map(\.inversion)), Set(TriadInversion.allCases))
    }
    func testCapoAndReentrantTuningUseActualLowestSoundingNote() throws {
        let tones = try TriadNeck.tones(.parse("C"))
        let tuning = Tuning("Reentrant", [40, 45, 50, 76, 59, 64])
        let shapes = TriadNeck.shapes(tones, tuning: tuning, capo: 2, group: 0)
        XCTAssertFalse(shapes.isEmpty)
        for shape in shapes {
            XCTAssertEqual(
                shape.notes,
                shape.frets.enumerated().filter { $0.element >= 0 }.map { tuning.pitches[$0.offset] + 2 + $0.element })
            XCTAssertEqual(mod(shape.notes.min()!), tones[shape.inversion.rawValue].pc)
        }
        XCTAssertTrue(TriadNeck.shapes(tones, tuning: tuning, capo: 10, group: 0).isEmpty)
        XCTAssertTrue(TriadNeck.shapes(tones, tuning: tuning, capo: 0, group: 4).isEmpty)
        XCTAssertTrue(TriadNeck.shapes(tones, tuning: Tuning("Invalid", [40]), capo: 0, group: 0).isEmpty)
        XCTAssertTrue(TriadNeck.shapes([Pitch(0), Pitch(0), Pitch(0)], tuning: tuning, capo: 0, group: 0).isEmpty)
    }
    func testRouteIsGlobalMinimumPerStringMovement() throws {
        let chords = try ["Dm", "G", "C"].map { try TriadNeck.tones(.parse($0)) }
        let choices = chords.map { TriadNeck.shapes($0, tuning: .presets[0], capo: 0, group: 0) }
        let route = try TriadNeck.route(choices)
        let actual = TriadNeck.movement(route[0], route[1]) + TriadNeck.movement(route[1], route[2])
        var minimum = Int.max
        for a in choices[0] {
            for b in choices[1] {
                for c in choices[2] { minimum = min(minimum, TriadNeck.movement(a, b) + TriadNeck.movement(b, c)) }
            }
        }
        XCTAssertEqual(actual, minimum)
        XCTAssertEqual(try TriadNeck.route([choices[0]]).count, 1)
        XCTAssertThrowsError(try TriadNeck.route([]))
        XCTAssertThrowsError(try TriadNeck.route([[]]))
    }
    func testMaterialIdentityIncludesSourceRangeSetAndTuning() throws {
        let doc = try document()
        let piece = LibraryPiece(source: .score(doc))
        let scope = PassageScope(partID: "P1", staff: 1, from: 0, through: 3)
        let m = try TriadMaterial(piece: piece, scope: scope, tuning: .presets[0], capo: 0, group: 0)
        XCTAssertTrue(m.valid)
        XCTAssertTrue(m.current(in: piece))
        XCTAssertNotEqual(
            m.id, try TriadMaterial(piece: piece, scope: scope, tuning: .presets[0], capo: 2, group: 0).id)
        XCTAssertNotEqual(
            m.id, try TriadMaterial(piece: piece, scope: scope, tuning: .presets[0], capo: 0, group: 1).id)
        var changed = doc
        changed.harmonies[0].symbol = try .parse("D")
        XCTAssertFalse(m.current(in: .init(source: .score(changed))))
        var corrupt = m
        corrupt.route[0].frets[0] = 0
        XCTAssertFalse(corrupt.valid)
        corrupt = m
        corrupt.group = 99
        XCTAssertFalse(corrupt.valid)
        corrupt = m
        corrupt.changes[1].bar = 0
        XCTAssertFalse(corrupt.valid)
    }
    func testCarriedHarmonyAndMissingChordPassages() throws {
        var doc = try document()
        doc.harmonies.removeAll { $0.bar > 0 }
        let m = try TriadMaterial(
            piece: .init(source: .score(doc)), scope: .init(partID: "P1", staff: 1, from: 1, through: 2),
            tuning: .presets[0], capo: 0, group: 2)
        XCTAssertTrue(m.changes[0].carried)
        XCTAssertEqual(m.changes[0].bar, 0)
        XCTAssertTrue(m.valid)
        doc.harmonies = []
        XCTAssertThrowsError(
            try TriadMaterial(piece: .init(source: .score(doc)), scope: m.scope, tuning: m.tuning, capo: 0, group: 0))
    }
    func testWrongAnswersRetryAndEvidenceTypesStaySeparate() throws {
        var session = TriadSession(material: try material())
        let wrong = TriadInversion.allCases.first { $0 != session.material.route[0].inversion }!
        let miss = try session.apply(.inversion(wrong))
        XCTAssertEqual(miss.outcome, .incorrect)
        XCTAssertEqual(miss.input, .choice)
        XCTAssertEqual(session.cursor, 0)
        while session.stage == .find {
            _ = try session.apply(.inversion(session.material.route[session.cursor].inversion))
        }
        let connection = try session.apply(.connected)
        XCTAssertEqual(connection.input, .selfReport)
        XCTAssertEqual(connection.outcome, .revealed)
        let mismatch = try session.apply(.microphone(session.material.earNotes.map { $0 + 12 }))
        XCTAssertEqual(mismatch.outcome, .incorrect)
        XCTAssertEqual(session.stage, .ear)
        let match = try session.apply(.microphone(session.material.earNotes))
        XCTAssertEqual(match.input, .microphone)
        XCTAssertTrue(match.assisted)
        XCTAssertEqual(session.stage, .create)
        let finish = try session.apply(.finish)
        XCTAssertEqual(finish.input, .selfReport)
        XCTAssertEqual(session.stage, .complete)
        XCTAssertEqual(session.review.lastGrade, .supported)
        XCTAssertEqual(session.review.intervalDays, 0)
        XCTAssertTrue([miss, connection, mismatch, match, finish].allSatisfy(\.valid))
        XCTAssertThrowsError(try session.apply(.finish))
        let id = session.id
        let review = session.review
        session.restart()
        XCTAssertNotEqual(id, session.id)
        XCTAssertEqual(session.stage, .find)
        XCTAssertEqual(session.review, review)
    }
    func testSkipIsExplicitAndInvalidActionsCannotAdvance() throws {
        var session = TriadSession(material: try material())
        XCTAssertThrowsError(try session.apply(.microphone([60, 64])))
        XCTAssertEqual(session.stage, .find)
        XCTAssertEqual(try session.apply(.skip).outcome, .skipped)
        _ = try session.apply(.skip)
        XCTAssertThrowsError(try session.apply(.microphone([])))
        XCTAssertThrowsError(try session.apply(.microphone([-1, 64])))
        _ = try session.apply(.skip)
        _ = try session.apply(.skip)
        XCTAssertEqual(session.stage, .complete)
    }
    func testCompositionIsBlankEditableGuitarWithDurableOriginalLink() throws {
        let m = try material()
        let doc = try m.answerDocument()
        XCTAssertEqual(doc.barCount, 2)
        XCTAssertEqual(doc.instrument, .guitar)
        XCTAssertEqual(doc.triadSource, m)
        XCTAssertTrue(doc.events.allSatisfy(\.isRest))
        XCTAssertEqual(doc.harmonies.map(\.symbol), Array(m.changes.prefix(2).map(\.symbol)))
        XCTAssertEqual(try JSONDecoder().decode(EditorDocument.self, from: JSONEncoder().encode(doc)), doc)
        var playable = doc
        try playable.setPitch(playable.events[0].id, midi: m.earNotes[0])
        _ = try StudyImport.read(Data(EditorXML.encode(playable).utf8))
    }
    func testPracticeValidationMigrationAndLimits() throws {
        var book = TriadPractice()
        let session = TriadSession(material: try material())
        book.sessions = [session]
        book.activeID = session.id
        var state = PracticeState(triads: book)
        XCTAssertEqual(try state.validated().schemaVersion, 16)
        XCTAssertEqual(try JSONDecoder().decode(PracticeState.self, from: JSONEncoder().encode(state)), state)
        state.schemaVersion = 12
        XCTAssertEqual(try state.validated().schemaVersion, 16)
        state.schemaVersion = 17
        XCTAssertThrowsError(try state.validated())
        book.sessions.append(session)
        XCTAssertThrowsError(try book.validated())
        book.sessions = [session]
        book.activeID = UUID()
        XCTAssertThrowsError(try book.validated())
    }
    func testPluckedGuitarFundamentalsSurviveHarmonicsAndDecay() throws {
        for midi in [40, 48, 55, 64, 72] {
            let rate = 12000.0
            let frequency = 440 * pow(2, Double(midi - 69) / 12)
            let samples: [Float] = (0..<2048).map { (i: Int) -> Float in
                let t = Double(i) / rate
                let phase = 2 * Double.pi * frequency * t
                let fundamental: Double = 0.4 * sin(phase)
                let secondHarmonic: Double = 0.2 * sin(2.0 * phase)
                let thirdHarmonic: Double = 0.1 * sin(3.0 * phase)
                let envelope: Double = exp(-3.0 * t)
                return Float(envelope * (fundamental + secondHarmonic + thirdHarmonic))
            }
            let pitch = try XCTUnwrap(PitchDetector.detect(samples, sampleRate: rate))
            XCTAssertEqual(pitch.midi, midi)
            XCTAssertLessThan(abs(pitch.cents), 10)
        }
        XCTAssertNil(PitchDetector.detect(Array(repeating: 0, count: 2048), sampleRate: 12000))
    }
    func testUnreviewedAndMissingOriginalPagesBlockCarriedHarmony() throws {
        var doc = try document()
        doc.pdfSource = PDFScoreSource(filename: "Original.pdf", page: 2, model: "fixture")
        let make: (EditorDocument, Int) throws -> TriadMaterial = { doc, from in
            try TriadMaterial(
                piece: .init(source: .score(doc)), scope: .init(partID: "P1", staff: 1, from: from, through: 3),
                tuning: .presets[0], capo: 0, group: 0)
        }
        XCTAssertThrowsError(try make(doc, 0))
        doc.pdfSource?.reviewed = true
        XCTAssertTrue(try make(doc, 0).valid)
        var first = PDFImportPage(page: 2, model: "fixture")
        first.barCount = 2
        first.reviewed = true
        first.status = .ready
        var last = first
        last.page = 4
        doc.pdfSource?.pages = [first, PDFImportPage(page: 3, model: "fixture"), last]
        XCTAssertThrowsError(try make(doc, 0))
        XCTAssertTrue(try make(doc, 2).valid)
        doc.harmonies.removeAll { $0.bar >= 2 }
        XCTAssertThrowsError(try make(doc, 2))
    }

}
