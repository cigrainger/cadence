// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore
import PDFKit
import XCTest

@testable import Cadence

final class ImportAssetTests: XCTestCase {
    private func directory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
    @MainActor private func pdf() throws -> PDFImportAsset {
        let data = try Data(contentsOf: AppResources.url("ImportExamples/piano.pdf"))
        let original = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        let document = PDFDocument()
        for index in 0..<3 {
            let page = try XCTUnwrap(original.copy() as? PDFPage)
            page.setBounds(CGRect(x: 0, y: 0, width: 300 + index * 10, height: 500), for: .mediaBox)
            document.insert(page, at: index)
        }
        return try PDFImportAsset(data: XCTUnwrap(document.dataRepresentation()), filename: "Original lesson.pdf")
    }

    @MainActor func testPDFExcerptContainsOnlySelectedOrderedPagesAndDoesNotMutateOriginal() throws {
        let asset = try pdf()
        let original = asset.data
        let excerpt = try XCTUnwrap(PDFDocument(data: asset.excerptPDF([2, 3])))
        XCTAssertEqual(excerpt.pageCount, 2)
        XCTAssertEqual(excerpt.page(at: 0)?.bounds(for: .mediaBox).width, 310)
        XCTAssertEqual(excerpt.page(at: 1)?.bounds(for: .mediaBox).width, 320)
        XCTAssertEqual(asset.pageCount, 3)
        XCTAssertEqual(asset.document.page(at: 0)?.bounds(for: .mediaBox).width, 300)
        XCTAssertEqual(asset.data, original)
        XCTAssertEqual(PDFDocument(data: try asset.pagePDF(3))?.pageCount, 1)
    }

    @MainActor func testPDFRejectsInvalidDuplicateReorderedAndOversizedSelections() throws {
        let asset = try pdf()
        for pages in [[], [0], [-1], [4], [1, 1], [3, 2]] {
            XCTAssertThrowsError(try asset.excerptPDF(pages), "\(pages)")
        }
        XCTAssertThrowsError(try asset.excerptPDF([1, 2], maximumPages: 1))
        XCTAssertThrowsError(try asset.excerptPDF([1], maximumBytes: 1))
        XCTAssertThrowsError(try PDFImportAsset(data: Data("not a PDF".utf8), filename: "bad.pdf"))
        let long = try PDFImportAsset(data: asset.data, filename: String(repeating: "a", count: 400))
        XCTAssertEqual(long.filename.count, 300)
    }

    @MainActor func testPDFBookReadKeepsSourceBytesAndTitle() async throws {
        let url = AppResources.url("ImportExamples/chapter.pdf")
        let asset = try await BookAsset.read(url)
        XCTAssertNotNil(asset.pdf)
        XCTAssertNil(asset.epub)
        XCTAssertEqual(asset.unit, "PDF page")
        XCTAssertEqual(asset.title, "chapter")
        let book = asset.book(title: "My chapter", author: "Original author", edition: "First")
        XCTAssertEqual(book.digest, CourseBook.digest(try Data(contentsOf: url)))
        XCTAssertEqual(book.pageCount, asset.pageCount)
        XCTAssertEqual(book.author, "Original author")
        XCTAssertFalse(book.isEPUB)
    }

    @MainActor func testEPUBReadSupportsUppercaseExtensionAndKeepsSectionProvenance() async throws {
        let folder = try directory()
        let url = folder.appendingPathComponent("Original.EPUB")
        let data = try Data(contentsOf: AppResources.url("ImportExamples/pathway.epub"))
        try data.write(to: url)
        let asset = try await BookAsset.read(url)
        let epub = try XCTUnwrap(asset.epub)
        XCTAssertNil(asset.pdf)
        XCTAssertEqual(asset.unit, "Section")
        XCTAssertEqual(asset.title, epub.title)
        XCTAssertEqual(asset.data, data)
        let book = asset.book(title: asset.title, author: epub.author, edition: "")
        XCTAssertEqual(book.epubSections, epub.sections.map(\.reference))
        XCTAssertEqual(book.pageCount, epub.sections.count)
        XCTAssertTrue(book.valid)
    }

    @MainActor func testSelectedEPUBIllustrationsBecomeSmallPDFWithoutChangingBook() async throws {
        let asset = try await BookAsset.read(AppResources.url("ImportExamples/pathway.epub"))
        let book = asset.book(title: asset.title, author: "Cadence", edition: "")
        let source = CourseSourceAnchor(book: book, from: 1, through: min(8, asset.pageCount))
        let images = asset.images(in: source)
        let first = try XCTUnwrap(images.first)
        XCTAssertEqual(Set(images.map(\.path)).count, images.count)
        let derived = try asset.imageExcerpt([first.path], source: source)
        XCTAssertEqual(derived.pageCount, 1)
        XCTAssertTrue(derived.filename.hasSuffix("selected illustrations.pdf"))
        XCTAssertEqual(asset.data, try Data(contentsOf: AppResources.url("ImportExamples/pathway.epub")))
        XCTAssertEqual(asset.book(title: asset.title, author: "", edition: "").digest, book.digest)
    }

    @MainActor func testIllustrationSelectionRejectsWrongBookInvalidRangesAndUnlistedImages() async throws {
        let asset = try await BookAsset.read(AppResources.url("ImportExamples/pathway.epub"))
        let book = asset.book(title: asset.title, author: "Cadence", edition: "")
        let source = CourseSourceAnchor(book: book, from: 1, through: min(8, asset.pageCount))
        let image = try XCTUnwrap(asset.images(in: source).first)
        for selected in [[], [image.path, image.path], ["outside.png"], Array(repeating: image.path, count: 5)] {
            XCTAssertThrowsError(try asset.imageExcerpt(selected, source: source))
        }
        var other = source
        other.digest = CourseBook.digest(Data("different book".utf8))
        XCTAssertTrue(asset.images(in: other).isEmpty)
        XCTAssertThrowsError(try asset.imageExcerpt([image.path], source: other))
        other = source
        other.fromPage = 0
        XCTAssertTrue(asset.images(in: other).isEmpty)
    }

    @MainActor func testOversizedSparseFilesAreRejectedBeforeReadingIntoMemory() async throws {
        let folder = try directory()
        for (name, size) in [("large.pdf", 100_000_001), ("large.epub", EPUBDocument.maximumBytes + 1)] {
            let url = folder.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            let file = try FileHandle(forWritingTo: url)
            try file.truncate(atOffset: UInt64(size))
            try file.close()
            do {
                _ = try await BookAsset.read(url)
                XCTFail("Oversized source accepted")
            } catch { XCTAssertTrue(error.localizedDescription.contains("smaller")) }
        }
    }

    @MainActor func testCancelledReadsNeverOpenMissingSourceOrPublishAnAsset() async {
        let url = URL(fileURLWithPath: "/nonexistent-cadence-test/source.pdf")
        let pdf = Task { try await PDFImportAsset.read(url) }
        pdf.cancel()
        do {
            _ = try await pdf.value
            XCTFail()
        } catch { XCTAssertTrue(error is CancellationError) }
        let book = Task { try await BookAsset.read(url) }
        book.cancel()
        do {
            _ = try await book.value
            XCTFail()
        } catch { XCTAssertTrue(error is CancellationError) }
    }
}
