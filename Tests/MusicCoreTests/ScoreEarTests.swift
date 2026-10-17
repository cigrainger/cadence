// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class ScoreEarTests: XCTestCase {
    func document() throws -> EditorDocument {
        var d = try EditorDocument.blank(instrument: .piano)
        d.title = "An evening turn"
        d.tempo = 84
        d.events.removeAll { $0.staff == 1 }
        for (bar, notes) in [[62, 65], [67, 71], [72, 71], [67, 64]].enumerated() {
            d.events += notes.map { EditorEvent(bar: bar, rhythm: EditorRhythm(960), pitches: [EditorPitch($0)]) }
        }
        d.harmonies = try ["Dm7", "G7", "Cmaj7", "Cmaj7"].enumerated().map {
            EditorHarmony(bar: $0.offset, symbol: try ChordSymbol.parse($0.element))
        }
        d.events = d.events.filter { $0.staff == 1 } + d.events.filter { $0.staff == 2 }
        return try d.validated()
    }
    func material(_ doc: EditorDocument? = nil, from: Int = 1, through: Int = 4, staff: Int = 1, voice: String = "1")
        throws -> ScoreEarMaterial
    {
        try ScoreEarMaterial(
            piece: LibraryPiece(source: .score(try doc ?? document())),
            scope: .init(fromBar: from, throughBar: through, partID: "P1", partName: "Piano"), staff: staff,
            voice: voice)
    }
    func finish(_ s: inout EarSession, at date: Date, skip: Bool = false) throws {
        if try s.projection().stage == .hear { try s.append(.init(.heard, date: date)) }
        try s.append(.init(.imagined, date: date))
        for _ in 0..<2 {
            try s.append(.init(.answer, notes: skip ? [] : s.opening.notes, skipped: skip, date: date))
            try s.append(.init(.next, date: date))
        }
        try s.append(.init(.next, date: date))
    }
    func testSelectionKeepsRhythmSpellingKeyAndChordSymbols() throws {
        let d = try document()
        let m = try material(d)
        XCTAssertTrue(m.valid)
        XCTAssertTrue(m.isCurrent(in: LibraryPiece(source: .score(d))))
        XCTAssertEqual(m.melody.map(\.midi), [62, 65, 67, 71, 72, 71, 67, 64])
        XCTAssertEqual(m.melody.map(\.start), [0, 2, 4, 6, 8, 10, 12, 14])
        XCTAssertEqual(m.tones.map(\.solfege), ["Re", "Fa", "Sol", "Ti", "Do", "Ti", "Sol", "Mi"])
        XCTAssertEqual(m.chords.map(\.symbol.label), ["Dm7", "G7", "Cmaj7", "Cmaj7"])
        XCTAssertNil(m.accompanimentIssue)
        let phrase = EarPhrase(material: m)
        XCTAssertEqual(
            phrase.score.notes.dropFirst().filter { $0.midi >= 0 }.map(\.start), [2, 4, 6, 8, 10, 12, 14, 16])
        XCTAssertEqual(phrase.score.notes[0].midi, 60)
        XCTAssertTrue(phrase.matches(phrase.notes.map { $0 - 12 }, input: .singing))
        XCTAssertFalse(phrase.matches(phrase.notes.map { $0 + 12 }, input: .midi))
        XCTAssertNotEqual(phrase.activity(.singing), phrase.activity(.midi))
    }
    func testRestsAndInternalTiesPreservedBoundaryTiesRejected() throws {
        var d = try document()
        d.events[0].pitches = []
        let m = try material(d)
        XCTAssertEqual(m.melody.first?.start, 2)
        d.events[7].pitches = []
        XCTAssertEqual(EarPhrase(material: try material(d)).score.length, 18)
        d = try document()
        d.events[1].pitches = d.events[0].pitches.map { EditorPitch($0.midi) }
        d.events[0].tieNext = true
        XCTAssertEqual(try material(d).melody.count, 7)
        XCTAssertEqual(try material(d).melody.first?.duration, 4)
        d = try document()
        d.events[2].pitches = [EditorPitch(65)]
        d.events[1].tieNext = true
        XCTAssertNoThrow(try material(d))
        XCTAssertThrowsError(try material(d, through: 1))
        XCTAssertThrowsError(try material(d, from: 2))
    }
    func testChordsEmptyVoicesAndOversizedMelodiesAreNotReduced() throws {
        var d = try document()
        d.events[0].pitches.append(EditorPitch(69))
        XCTAssertThrowsError(try material(d))
        XCTAssertThrowsError(try material(staff: 2))
        XCTAssertThrowsError(try material(voice: "99"))
        XCTAssertThrowsError(try material(.pianoExample))
        XCTAssertNoThrow(try material(.pianoExample, through: 2))
        XCTAssertThrowsError(try material(from: 0))
        XCTAssertThrowsError(try material(through: 5))
    }
    func testMinorSolfègeAndGuitarSoundingOctave() throws {
        var d = try document()
        d.minor = true
        d.events[0].pitches = [EditorPitch(60)]
        XCTAssertEqual(try material(d).tones.first?.solfege, "Me")
        let guitar = EditorDocument.guitarExample
        let m = try material(guitar, through: 2)
        XCTAssertEqual(m.melody.first?.midi, 60)
        XCTAssertEqual(m.tones.first?.solfege, "Do")
    }
    func testRenameKeepsIdentityMusicAndPageChangesInvalidate() throws {
        var d = try document()
        let m = try material(d)
        d.title = "A different title"
        XCTAssertTrue(m.isCurrent(in: LibraryPiece(source: .score(d))))
        d.events[0].pitches = [EditorPitch(64)]
        XCTAssertFalse(m.isCurrent(in: LibraryPiece(source: .score(d))))
        XCTAssertNotEqual(m.id, try material(d).id)
        d = try document()
        d.pdfSource = PDFScoreSource(filename: "Original.pdf", page: 2, model: "fixture", reviewed: true)
        let imported = try material(d)
        d.pdfSource?.page = 3
        XCTAssertFalse(imported.isCurrent(in: LibraryPiece(source: .score(d))))
    }
    func testPDFReviewRevocationAndReplacementAreChecked() throws {
        var d = try document()
        d.pdfSource = PDFScoreSource(filename: "Original.pdf", page: 2, model: "fixture")
        XCTAssertThrowsError(try material(d))
        d.pdfSource?.reviewed = true
        let m = try material(d)
        XCTAssertEqual(m.sourcePages, [2])
        d.pdfSource?.reviewed = false
        XCTAssertFalse(m.isCurrent(in: LibraryPiece(source: .score(d))))
        var page = PDFImportPage(page: 2, model: "fixture")
        page.barCount = 4
        page.reviewed = true
        page.status = .ready
        d.pdfSource?.pages = [page]
        XCTAssertNoThrow(try material(d))
        d.pdfSource?.pages?[0].status = .reading
        XCTAssertThrowsError(try material(d))
        d.pdfSource?.pages?[0].status = .ready
        d.pdfSource?.pages?[0].replacement = PDFPageReplacement(
            document: try document(), model: "fixture", warnings: [])
        XCTAssertThrowsError(try material(d))
    }
    func testMissingPDFPageInsideSelectionIsNeverBridged() throws {
        var d = try document()
        d.pdfSource = PDFScoreSource(filename: "Original.pdf", page: 2, model: "fixture")
        var a = PDFImportPage(page: 2, model: "fixture")
        a.barCount = 2
        a.reviewed = true
        a.status = .ready
        let b = PDFImportPage(page: 3, model: "fixture")
        var c = a
        c.page = 4
        d.pdfSource?.pages = [a, b, c]
        XCTAssertThrowsError(try material(d))
        XCTAssertEqual(try material(d, through: 2).sourcePages, [2])
        XCTAssertEqual(try material(d, from: 3).sourcePages, [4])
    }
    func testNoInventedHarmonyAndNonFourFourRemainEarOnly() throws {
        var d = try document()
        d.harmonies = []
        let m = try material(d)
        XCTAssertNotNil(m.accompanimentIssue)
        XCTAssertTrue(m.valid)
        XCTAssertThrowsError(try ScoreAccompaniment(material: m).lanes())
        d = try document()
        d.harmonies.removeFirst()
        XCTAssertNotNil(try material(d).accompanimentIssue)
        var waltz = try EditorDocument.blank(instrument: .piano, bars: 1, meter: EditorMeter(3, 4))
        waltz.events[0].pitches = [EditorPitch(60)]
        XCTAssertNotNil(try material(waltz, through: 1).accompanimentIssue)
    }
    func testCarriedHarmonyMidBarChangesSlashBassAndNC() throws {
        var d = try document()
        d.harmonies = try [
            EditorHarmony(bar: 0, symbol: ChordSymbol.parse("C/E")),
            EditorHarmony(bar: 1, tick: 720, symbol: ChordSymbol.parse("N.C.")),
            EditorHarmony(bar: 2, symbol: ChordSymbol.parse("G7")),
        ]
        let m = try material(d, from: 2)
        let plan = ScoreAccompaniment(material: m, options: .init(tempo: 60, loops: 1))
        XCTAssertEqual(m.chords[0].start, 0)
        XCTAssertEqual(m.chords[0].end, 1.5)
        let lanes = try plan.lanes()
        XCTAssertEqual(lanes[1].notes.first?.midi, 40)
        XCTAssertTrue(lanes[0].notes.filter { $0.start < 5.5 }.allSatisfy { $0.start + $0.duration <= 5.5 })
        XCTAssertTrue(lanes[0].notes.filter { $0.start >= 5.5 && $0.start < 8 }.isEmpty)
        XCTAssertTrue(lanes[1].notes.filter { $0.start >= 5.5 && $0.start < 8 }.isEmpty)
        XCTAssertFalse(lanes[2].notes.filter { $0.start >= 5.5 && $0.start < 8 }.isEmpty)
    }
    func testAccompanimentCountsLoopsMuteAndMelodyUseExactScope() throws {
        let m = try material(from: 2, through: 3)
        for style in GrooveStyle.allCases {
            for loops in 1...4 {
                let p = ScoreAccompaniment(
                    material: m, options: .init(tempo: 60, style: style, loops: loops), includeMelody: true)
                let lanes = try p.lanes()
                XCTAssertEqual(lanes.count, 4)
                XCTAssertEqual(lanes[3].notes.count, m.melody.count * loops)
                XCTAssertTrue(lanes.flatMap(\.notes).allSatisfy { $0.start + $0.duration <= p.endBeat })
                XCTAssertEqual(p.bar(at: 4), 2)
                XCTAssertEqual(p.bar(at: 8), 3)
                XCTAssertNil(p.bar(at: p.endBeat))
                XCTAssertNoThrow(try Score(tempo: 60, notes: lanes.flatMap(\.notes)).validated())
            }
        }
        let silent = try ScoreAccompaniment(material: m, options: .init(piano: false, bass: false, drums: false))
            .lanes()
        XCTAssertTrue(silent[0].notes.isEmpty)
        XCTAssertTrue(silent[1].notes.isEmpty)
        XCTAssertEqual(silent[2].notes.count, 4)
        XCTAssertThrowsError(try ScoreAccompaniment(material: m, options: .init(tempo: 300)).lanes())
    }
    func testLearningAndEarlyReturnNeverBecomeIndependent() throws {
        let m = try material()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var book = ScoreEarPractice()
        try book.open(m, now: date)
        try finish(&book.sessions[0], at: date)
        XCTAssertTrue(try book.sessions[0].projection().results.allSatisfy(\.assisted))
        try book.open(m, now: date.addingTimeInterval(3600))
        let p = try XCTUnwrap(book.active).projection()
        XCTAssertTrue(p.isReturn)
        XCTAssertFalse(p.delayed)
        XCTAssertTrue(p.assisted)
        XCTAssertEqual(p.stage, .imagine)
        try finish(&book.sessions[1], at: date.addingTimeInterval(3600))
        XCTAssertNoThrow(try book.validated())
        XCTAssertTrue(try book.sessions[1].projection().results.allSatisfy(\.assisted))
    }
    func testDelayedReturnTonicAndHintsHaveDistinctEffects() throws {
        let m = try material()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for hint in [false, true] {
            var book = ScoreEarPractice()
            try book.open(m, now: date)
            try finish(&book.sessions[0], at: date)
            try book.open(m, now: date.addingTimeInterval(86400))
            XCTAssertEqual(try book.sessions[1].projection().stage, .imagine)
            try book.sessions[1].append(.init(.tonic, date: date.addingTimeInterval(86400)))
            XCTAssertFalse(try book.sessions[1].projection().assisted)
            if hint { try book.sessions[1].append(.init(.hint, date: date.addingTimeInterval(86400))) }
            try finish(&book.sessions[1], at: date.addingTimeInterval(86400))
            let p = try book.sessions[1].projection()
            XCTAssertTrue(p.delayed)
            XCTAssertEqual(p.results.map(\.assisted), [hint, hint])
            XCTAssertEqual(p.roundTitle, hint ? "Return · with support" : "Independent return")
            XCTAssertNoThrow(try book.validated())
        }
    }
    func testSourceRevealAfterSingingStillSupportsKeyboard() throws {
        var s = EarSession(phrase: EarPhrase(material: try material()))
        s.startedAt = Date()
        s.returnReadyAt = .distantPast
        try s.append(.init(.imagined))
        try s.append(.init(.answer, notes: s.opening.notes))
        try s.append(.init(.hint))
        try s.append(.init(.next))
        try s.append(.init(.answer, notes: s.opening.notes))
        XCTAssertEqual(try s.projection().results.map(\.assisted), [false, true])
    }
    func testBandIsPostCheckAndDoesNotCreateGrades() throws {
        var s = EarSession(phrase: EarPhrase(material: try material()))
        XCTAssertThrowsError(try s.append(.init(.accompaniment)))
        try s.append(.init(.heard))
        try s.append(.init(.imagined))
        for _ in 0..<2 {
            try s.append(.init(.answer, skipped: true))
            try s.append(.init(.next))
        }
        try s.append(.init(.accompaniment))
        XCTAssertEqual(try s.projection().accompanimentVisits, 1)
        XCTAssertTrue(try s.projection().results.allSatisfy { $0.outcome == .skipped })
        try s.append(.init(.next))
        XCTAssertThrowsError(try s.append(.init(.accompaniment)))
    }
    func testSavedSessionsMigrateResumeAndRejectForgedHistory() throws {
        let m = try material()
        var book = ScoreEarPractice()
        try book.open(m)
        let id = book.selectedID
        try book.open(m)
        XCTAssertEqual(book.selectedID, id)
        XCTAssertEqual(book.sessions.count, 1)
        XCTAssertEqual(
            try JSONDecoder().decode(PracticeState.self, from: JSONEncoder().encode(PracticeState(scoreEar: book)))
                .validated().scoreEar, book)
        var corrupt = book
        corrupt.sessions[0].returnReadyAt = .distantPast
        XCTAssertThrowsError(try corrupt.validated())
        corrupt = book
        corrupt.sessions[0].opening.material?.melody[0].midi = 999
        XCTAssertThrowsError(try corrupt.validated())
        corrupt = book
        corrupt.sessions.append(corrupt.sessions[0])
        XCTAssertThrowsError(try corrupt.validated())
        corrupt = book
        corrupt.selectedID = UUID()
        XCTAssertThrowsError(try corrupt.validated())
        var old = PracticeState()
        old.schemaVersion = 6
        XCTAssertEqual(try old.validated().schemaVersion, 16)
        var unsupported = old
        unsupported.schemaVersion = 17
        XCTAssertThrowsError(try unsupported.validated())
    }
    func testLongSourceTitleStillProducesValidEvidence() throws {
        var d = try document()
        d.title = String(repeating: "A", count: 500)
        var session = EarSession(phrase: EarPhrase(material: try material(d)))
        try finish(&session, at: Date())
        XCTAssertTrue(try session.projection().results.allSatisfy { $0.attempt(sessionID: session.id).valid })
    }
    func testIndependentCardsAndSourceIdentitySurviveJournalRoundtrip() throws {
        let m = try material()
        var session = EarSession(phrase: EarPhrase(material: m))
        session.startedAt = Date()
        session.returnReadyAt = .distantPast
        try finish(&session, at: Date())
        var journal = PracticeJournal()
        var history = PracticeProgress()
        for r in try session.projection().results {
            journal.append(r.attempt(sessionID: session.id))
            history.record(r, sessionID: session.id)
        }
        XCTAssertEqual(journal.attempts.count, 2)
        XCTAssertTrue(journal.attempts.allSatisfy { $0.pieceID == m.pieceID && $0.scoreFingerprint == m.fingerprint })
        XCTAssertEqual(history.cards.count, 2)
        XCTAssertTrue(history.cards.values.allSatisfy { $0.review.intervalDays == 1 })
    }
}
