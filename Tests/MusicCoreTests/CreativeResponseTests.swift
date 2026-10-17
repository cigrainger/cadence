// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class CreativeResponseTests: XCTestCase {
    func source(_ instrument: EditorInstrument = .piano) throws -> (LibraryPiece, ScoreEarMaterial) {
        let doc = instrument == .piano ? EditorDocument.pianoExample : EditorDocument.guitarExample
        let piece = LibraryPiece(source: .score(doc))
        let material = try ScoreEarMaterial(
            piece: piece, scope: .init(fromBar: 1, throughBar: 1, partID: "P1", partName: instrument.rawValue),
            staff: 1, voice: "1")
        return (piece, material)
    }
    func testBlankAnswerRetainsInstrumentKeyAndSourceButNeverSourceNotes() throws {
        for instrument in EditorInstrument.allCases {
            let (piece, material) = try source(instrument)
            let link = CreativeResponse(material: material, sessionID: UUID())
            let answer = try link.makeDocument(piece: piece)
            XCTAssertEqual(answer.instrument, instrument)
            XCTAssertEqual(answer.barCount, 1)
            XCTAssertTrue(answer.events.allSatisfy(\.isRest))
            XCTAssertNil(answer.pdfSource)
            XCTAssertEqual(answer.responseSource, link)
            XCTAssertEqual(LibraryPiece(source: .score(answer)).defaultKind, .composition)
            XCTAssertEqual(answer.fifths, material.fifths)
            XCTAssertEqual(try JSONDecoder().decode(EditorDocument.self, from: JSONEncoder().encode(answer)), answer)
        }
    }
    func testChangesAreCopiedAsSuggestionsAndIndependent() throws {
        var doc = EditorDocument.guitarExample
        doc.harmonies = [EditorHarmony(bar: 0, symbol: try ChordSymbol.parse("Cmaj7"))]
        let piece = LibraryPiece(source: .score(doc))
        let material = try ScoreEarMaterial(
            piece: piece, scope: .init(fromBar: 1, throughBar: 1, partID: "P1", partName: "Guitar"), staff: 1,
            voice: "1")
        var answer = try CreativeResponse(material: material, sessionID: UUID()).makeDocument(piece: piece)
        XCTAssertEqual(answer.harmonies.first?.symbol, doc.harmonies.first?.symbol)
        answer.harmonies = []
        XCTAssertEqual(doc.harmonies.count, 1)
    }
    func testRejectsChangedSourceAndMalformedLinks() throws {
        let (piece, material) = try source()
        var link = CreativeResponse(material: material, sessionID: UUID())
        guard case .score(var doc) = piece.source else { return }
        doc.tempo += 1
        XCTAssertThrowsError(try link.makeDocument(piece: LibraryPiece(source: .score(doc))))
        link.listenedFingerprint = "bad"
        XCTAssertFalse(link.valid)
        link.listenedFingerprint = nil
        link.savedAt = Date()
        XCTAssertFalse(link.valid)
        link.savedAt = nil
        link.createdAt = Date(timeIntervalSince1970: .infinity)
        XCTAssertFalse(link.valid)
    }
    func testFinishedRevisionDoesNotSurviveChangedMusic() throws {
        let (piece, material) = try source()
        var doc = try CreativeResponse(material: material, sessionID: UUID()).makeDocument(piece: piece)
        let revision = LibraryPiece(source: .score(doc)).fingerprint
        doc.responseSource?.savedAt = Date()
        doc.responseSource?.listenedFingerprint = revision
        XCTAssertTrue(doc.responseSource!.isFinished(doc))
        doc.title = "My reply"
        XCTAssertTrue(doc.responseSource!.isFinished(doc))
        doc.tempo += 1
        XCTAssertFalse(doc.responseSource!.isFinished(doc))
    }
    func testBandPositionCountInLoopsEndAndBadValues() throws {
        func pos(_ time: Double) -> ScoreBandPosition? {
            .init(seconds: time, tempo: 60, beats: 8, loops: 2, sourceStart: 20)
        }
        XCTAssertNil(pos(-1))
        XCTAssertNil(pos(.nan))
        XCTAssertNil(pos(.infinity))
        XCTAssertTrue(try XCTUnwrap(pos(0)).head.isCountIn)
        XCTAssertEqual(pos(3)?.head.countInRemaining, 1)
        XCTAssertEqual(pos(4)?.head.sourceBeat, 20)
        XCTAssertFalse(try XCTUnwrap(pos(4)).head.isCountIn)
        XCTAssertEqual(pos(8)?.fraction, 0.5)
        XCTAssertEqual(pos(12)?.head.sourceBeat, 20)
        XCTAssertEqual(pos(12)?.round, 2)
        XCTAssertNil(pos(20))
        XCTAssertNil(ScoreBandPosition(seconds: 0, tempo: .nan, beats: 8, loops: 1, sourceStart: 0))
        XCTAssertNil(ScoreBandPosition(seconds: 0, tempo: 60, beats: 0, loops: 1, sourceStart: 0))
        XCTAssertNil(ScoreBandPosition(seconds: 0, tempo: 60, beats: 8, loops: 5, sourceStart: 0))
    }
    func testFullPlaybackIsExplicitAndBoundedByDuration() throws {
        var score = try EditorDocument.blank(instrument: .piano, bars: 20)
        score.tempo = 120
        try score.setPitch(score.events[0].id, midi: 60)
        var study = MusicStudy(
            document: try StudyImport.read(Data(EditorXML.encode(score).utf8)), filename: "Full score")
        study.from = 0
        study.through = 19
        XCTAssertThrowsError(try StudyPlaybackPlan(study: study))
        XCTAssertEqual(try StudyPlaybackPlan(study: study, wholePiece: true).cycleBeats, 80)
        study.speed = 0.25
        study.document.tempo = 20
        XCTAssertThrowsError(try StudyPlaybackPlan(study: study, wholePiece: true))
    }
}
