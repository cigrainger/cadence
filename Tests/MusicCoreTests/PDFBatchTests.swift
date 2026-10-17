// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class PDFBatchTests: XCTestCase {
    private func queued(_ pages: [Int] = [2, 4, 7], instrument: EditorInstrument = .guitar) throws -> EditorDocument {
        var doc = try EditorDocument.blank(instrument: instrument, bars: 1)
        var source = PDFScoreSource(filename: "Book.pdf", page: pages[0], model: PDFImportModel.sol.rawValue)
        source.pages = pages.map { PDFImportPage(page: $0, model: PDFImportModel.sol.rawValue) }
        doc.pdfSource = source
        return try doc.validated()
    }
    private func candidate(_ bars: Int = 2, instrument: EditorInstrument = .guitar, midi: Int = 60) throws
        -> PDFPageReplacement
    {
        var doc = try EditorDocument.blank(instrument: instrument, bars: bars)
        try doc.setPitch(doc.events[0].id, midi: midi)
        return PDFPageReplacement(
            document: doc, model: PDFImportModel.sol.rawValue, warnings: ["Review the page join."])
    }
    func testPageRangesNormalizeDeduplicateAndKeepBookOrder() throws {
        XCTAssertEqual(try PDFPageRanges.parse(" 29–32, 35, 30, 2—3 ", pageCount: 512), [2, 3, 29, 30, 31, 32, 35])
        XCTAssertEqual(try PDFPageRanges.parse("1-16", pageCount: 20), Array(1...16))
        for value in ["", "0", "-1", "1,", "1,,2", "3-2", "1-2-3", "2.5", "two", "1-17", "20-21"] {
            XCTAssertThrowsError(try PDFPageRanges.parse(value, pageCount: 20), value)
        }
        XCTAssertThrowsError(try PDFPageRanges.parse("1-16,18", pageCount: 20))
    }
    func testOutOfOrderResultsFormOneScoreAndMissingPagesStayExplicit() throws {
        var doc = try queued()
        try doc.replacePDFPage(7, with: candidate(3, midi: 67))
        let laterIDs = doc.events.map(\.id)
        XCTAssertEqual(doc.pdfSource?.range(for: 7), 0..<3)
        XCTAssertEqual(doc.pdfSource?.pages?.filter { $0.barCount == 0 }.map(\.page), [2, 4])
        try doc.replacePDFPage(2, with: candidate(2, midi: 60))
        XCTAssertEqual(doc.barCount, 5)
        XCTAssertEqual(doc.pdfSource?.range(for: 7), 2..<5)
        XCTAssertEqual(doc.events.filter { $0.bar >= 2 }.map(\.id), laterIDs)
        try doc.replacePDFPage(4, with: candidate(1, midi: 64))
        XCTAssertEqual(doc.barCount, 6)
        XCTAssertEqual(doc.pdfSource?.range(for: 4), 2..<3)
        XCTAssertEqual(doc.pdfSource?.page(at: 3)?.page, 7)
        XCTAssertEqual(doc.pdfSource?.reference(at: 3).page, 7)
        XCTAssertEqual(doc.pdfSource?.importedPageCount, 3)
        XCTAssertNoThrow(try doc.validated())
    }
    func testLengthChangingReplacementPreservesOtherPagesCorrectionsAndReviews() throws {
        var doc = try queued([1, 2])
        try doc.replacePDFPage(1, with: candidate())
        try doc.replacePDFPage(2, with: candidate())
        let id = doc.inBar(2, staff: 1)[0].id
        try doc.setPitch(id, midi: 65)
        doc.pdfSource?.setReviewed(true, page: 1)
        doc.pdfSource?.setReviewed(true, page: 2)
        let original = doc.events.filter { $0.bar >= 2 }
        try doc.replacePDFPage(1, with: candidate(3))
        let shifted = doc.events.filter { $0.bar >= 3 }.map { item in
            var item = item
            item.bar -= 1
            return item
        }
        XCTAssertEqual(shifted, original)
        XCTAssertEqual(doc.pdfSource?.pages?.map(\.reviewed), [false, true])
        XCTAssertEqual(doc.pdfSource?.range(for: 2), 3..<5)
        XCTAssertEqual(doc.events.first { $0.id == id }?.pitches.first?.midi, 65)
    }
    func testIncompatibleOrOversizedPagesLeaveScoreUntouched() throws {
        var doc = try queued([1, 2])
        try doc.replacePDFPage(1, with: candidate(100))
        let before = doc
        var wrong = try candidate()
        wrong.document.fifths = 2
        XCTAssertThrowsError(try doc.replacePDFPage(2, with: wrong))
        XCTAssertEqual(doc, before)
        wrong = try candidate(instrument: .piano)
        XCTAssertThrowsError(try doc.replacePDFPage(2, with: wrong))
        XCTAssertEqual(doc, before)
        wrong = try candidate()
        wrong.document = try EditorDocument.blank(instrument: .guitar, bars: 2, meter: EditorMeter(3, 4))
        XCTAssertThrowsError(try doc.replacePDFPage(2, with: wrong))
        XCTAssertEqual(doc, before)
        XCTAssertThrowsError(try doc.replacePDFPage(2, with: candidate(29)))
        XCTAssertEqual(doc, before)
        wrong = try candidate()
        wrong.document.pdfSource = PDFScoreSource(filename: "Other.pdf", page: 1, model: "test")
        XCTAssertThrowsError(try doc.replacePDFPage(2, with: wrong))
        XCTAssertEqual(doc, before)
    }
    func testNewVoiceGetsCompleteRestsAcrossEarlierPages() throws {
        var doc = try queued([1, 2], instrument: .piano)
        try doc.replacePDFPage(1, with: candidate(instrument: .piano))
        let poly = PDFPageReplacement(document: .innerVoiceExample, model: "test", warnings: [])
        try doc.replacePDFPage(2, with: poly)
        XCTAssertEqual(doc.voices(staff: 1), [1, 2])
        XCTAssertTrue(doc.inBar(0, staff: 1, voice: 2).allSatisfy(\.isRest))
        XCTAssertEqual(doc.inBar(0, staff: 1, voice: 2).reduce(0) { $0 + $1.rhythm.ticks }, doc.meter.ticks)
        XCTAssertNoThrow(try doc.validated())
    }
    func testOnlyChangedPageLosesReviewUnlessGlobalNotationChanges() throws {
        var doc = try queued([1, 2])
        try doc.replacePDFPage(1, with: candidate())
        try doc.replacePDFPage(2, with: candidate())
        doc.pdfSource?.setReviewed(true, page: 1)
        doc.pdfSource?.setReviewed(true, page: 2)
        var before = doc
        doc.title = "New title"
        doc.invalidatePDFReviews(comparedTo: before)
        XCTAssertEqual(doc.pdfSource?.reviewed, true)
        before = doc
        try doc.setPitch(doc.events[0].id, midi: 62)
        doc.invalidatePDFReviews(comparedTo: before)
        XCTAssertEqual(doc.pdfSource?.pages?.map(\.reviewed), [false, true])
        before = doc
        doc.fifths = 1
        doc.invalidatePDFReviews(comparedTo: before)
        XCTAssertEqual(doc.pdfSource?.pages?.map(\.reviewed), [false, false])
    }
    func testBarEditsAndExcerptsKeepSourceRanges() throws {
        var doc = try queued([1, 2, 3])
        for page in 1...3 { try doc.replacePDFPage(page, with: candidate()) }
        doc.pdfSource?.setReviewed(true, page: 3)
        var before = doc
        try doc.insertBars(at: 1, count: 2)
        doc.invalidatePDFReviews(comparedTo: before)
        XCTAssertEqual(doc.pdfSource?.pages?.map(\.barCount), [4, 2, 2])
        XCTAssertEqual(doc.pdfSource?.pages?.last?.reviewed, true)
        before = doc
        try doc.deleteBars(2...4)
        doc.invalidatePDFReviews(comparedTo: before)
        XCTAssertEqual(doc.pdfSource?.pages?.map(\.barCount), [2, 1, 2])
        XCTAssertEqual(doc.pdfSource?.range(for: 3), 3..<5)
        XCTAssertEqual(doc.pdfSource?.pages?.last?.reviewed, true)
        let excerpt = try doc.excerpt(1...3)
        XCTAssertEqual(excerpt.pdfSource?.pages?.map(\.barCount), [1, 1, 1])
        XCTAssertEqual(excerpt.pdfSource?.range(for: 3), 2..<3)
        try doc.deleteBars(2...2)
        XCTAssertEqual(doc.pdfSource?.pages?[1].status, .removed)
        try doc.replacePDFPage(2, with: candidate(1))
        XCTAssertEqual(doc.pdfSource?.range(for: 2), 2..<3)
    }
    func testQueueAndStagedReplacementRoundTripAndRecoverWithoutRetry() throws {
        var doc = try queued([1, 2])
        try doc.replacePDFPage(1, with: candidate())
        doc.pdfSource!.pages![0].replacement = try candidate(3)
        doc.pdfSource!.pages![0].status = .reading
        doc.pdfSource!.pages![1].status = .reading
        doc.pdfSource!.pages![1].attempts = 1
        doc.pdfSource!.pages![1].unpricedAttempts = 1
        var restored = try JSONDecoder().decode(EditorDocument.self, from: JSONEncoder().encode(doc)).validated()
        XCTAssertEqual(restored, doc)
        restored.recoverPDFQueue()
        XCTAssertEqual(restored.pdfSource?.pages?.map(\.status), [.ready, .stopped])
        XCTAssertEqual(restored.pdfSource?.pages?[1].attempts, 1)
        XCTAssertEqual(restored.pdfSource?.pages?[0].replacement, doc.pdfSource?.pages?[0].replacement)
        var malformed = restored
        malformed.pdfSource!.pages![0].barCount = 1
        XCTAssertThrowsError(try malformed.validated())
        malformed = restored
        malformed.pdfSource!.pages![1].page = 1
        XCTAssertThrowsError(try malformed.validated())
        malformed = restored
        malformed.pdfSource!.pages![1].costUSD = .infinity
        XCTAssertThrowsError(try malformed.validated())
    }
}
