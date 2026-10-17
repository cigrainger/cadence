// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
import ZIPFoundation

@testable import MusicCore

final class EPUBTests: XCTestCase {
    func archive(_ entries: [(String, Data)], symlink: String? = nil) throws -> Data {
        let archive = try Archive(accessMode: .create)
        for (name, data) in entries {
            try archive.addEntry(
                with: name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate
            ) { offset, count in data.subdata(in: Int(offset)..<(Int(offset) + count)) }
        }
        if let symlink {
            let bytes = Data("/etc/passwd".utf8)
            try archive.addEntry(with: symlink, type: .symlink, uncompressedSize: Int64(bytes.count)) { offset, count in
                bytes.subdata(in: Int(offset)..<(Int(offset) + count))
            }
        }
        return try XCTUnwrap(archive.data)
    }
    func entries(
        version: String = "3.0", body: String = "<h1>Inversions</h1><p>Try C E G.</p><img src='../images/keys.png'/>",
        extras: [(String, String)] = []
    ) -> [(String, Data)] {
        let nav =
            version == "2.0"
            ? "<ncx><navMap><navPoint><navLabel><text>Learn inversions</text></navLabel><content src='text/a.xhtml#first'/></navPoint></navMap></ncx>"
            : "<html xmlns:epub='http://www.idpf.org/2007/ops'><body><nav epub:type='toc'><ol><li><a href='text/a.xhtml#first'>Learn inversions</a></li></ol></nav></body></html>"
        let strings: [(String, String)] = [
            ("mimetype", "application/epub+zip"),
            (
                "META-INF/container.xml",
                "<container><rootfiles><rootfile full-path='Book/book.opf'/></rootfiles></container>"
            ),
            (
                "Book/book.opf",
                "<package version='\(version)'><metadata><title>Original test</title><creator>Cadence</creator></metadata><manifest><item id='a' href='text/a.xhtml' media-type='application/xhtml+xml'/><item id='b' href='text/b.xhtml' media-type='application/xhtml+xml'/><item id='nav' href='nav.xml' media-type='\(version == "2.0" ? "application/x-dtbncx+xml" : "application/xhtml+xml")' \(version == "2.0" ? "" : "properties='nav'")/><item id='img' href='images/keys.png' media-type='image/png'/><item id='font' href='font.otf' media-type='font/otf'/></manifest><spine toc='nav'><itemref idref='a'/><itemref idref='b'/></spine></package>"
            ),
            ("Book/nav.xml", nav), ("Book/text/a.xhtml", "<html><body>\(body)</body></html>"),
            (
                "Book/text/b.xhtml",
                "<html><body><h1>Unselected secret section</h1><p>Never send this when only section one is selected.</p></body></html>"
            ),
        ]
        return (strings + extras).map { ($0.0, Data($0.1.utf8)) } + [("Book/images/keys.png", Data([137, 80, 78, 71]))]
    }
    func replace(_ entries: [(String, Data)], _ path: String, _ value: String) -> [(String, Data)] {
        entries.map { $0.0 == path ? (path, Data(value.utf8)) : $0 }
    }
    func testEPUB2And3PreserveTextImagesContentsAndFragments() throws {
        for version in ["2.0", "3.0"] {
            let book = try EPUBDocument(data: archive(entries(version: version)))
            XCTAssertEqual(book.title, "Original test")
            XCTAssertEqual(book.author, "Cadence")
            XCTAssertEqual(book.sections.count, 2)
            XCTAssertEqual(book.navigation.first?.fragment, "first")
            XCTAssertEqual(book.navigation.first?.section, 0)
            XCTAssertEqual(book.sections[0].reference.title, "Inversions")
            XCTAssertTrue(book.sections[0].text.contains("Try C E G."))
            XCTAssertEqual(book.sections[0].images, ["Book/images/keys.png"])
            XCTAssertTrue(try book.readingHTML(section: 0).contains("data:image/png;base64,"))
            XCTAssertThrowsError(try book.readingHTML(section: 2))
        }
    }
    func testReaderDropsExecutableMarkupLinksAndPublisherStyling() throws {
        let body =
            "<h1 id='first'>Title &amp; care</h1><script>stealSecrets()</script><style>remote.css</style><iframe src='https://example.com'/><form>Send credentials</form><a href='javascript:evil()' onclick='evil()'>Keep readable words</a><img src='https://example.com/track.png'/><p style='background:url(https://example.com)'>A &lt; B</p>"
        let book = try EPUBDocument(data: archive(entries(body: body)))
        let html = try book.readingHTML(section: 0)
        for text in ["stealSecrets", "onclick", "javascript:", "https://example.com", "remote.css", "Send credentials"]
        { XCTAssertFalse(html.contains(text), text) }
        XCTAssertTrue(html.contains("Keep readable words"))
        XCTAssertTrue(html.contains("A &lt; B"))
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertFalse(book.sections[0].text.contains("stealSecrets"))
        XCTAssertTrue(book.images.isEmpty)
    }
    func testRejectsTraversalSymlinksDuplicateEntriesAndWrongMime() throws {
        for path in ["../escape", "/absolute", "Book/../../escape", "Book\\escape", "https:bad"] {
            XCTAssertThrowsError(try EPUBDocument(data: archive(entries() + [(path, Data())])))
        }
        XCTAssertThrowsError(try EPUBDocument(data: archive(entries(), symlink: "Book/link")))
        XCTAssertThrowsError(
            try EPUBDocument(data: archive(entries() + [("Book/text/a.xhtml", Data("duplicate".utf8))])))
        XCTAssertThrowsError(try EPUBDocument(data: archive(replace(entries(), "mimetype", "application/zip"))))
        XCTAssertThrowsError(try EPUBDocument(data: Data("not an epub".utf8)))
        XCTAssertThrowsError(try EPUBDocument(data: Data(repeating: 0, count: EPUBDocument.maximumBytes + 1)))
    }
    func testRejectsEntitiesMalformedDeepAndMissingDocuments() throws {
        let entity = "<!DOCTYPE html [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><html><body>&x;</body></html>"
        for text in [
            entity, "<html><body>broken",
            String(repeating: "<div>", count: 70) + String(repeating: "</div>", count: 70),
        ] { XCTAssertThrowsError(try EPUBDocument(data: archive(replace(entries(), "Book/text/a.xhtml", text)))) }
        XCTAssertThrowsError(try EPUBDocument(data: archive(entries().filter { $0.0 != "Book/text/a.xhtml" })))
        XCTAssertThrowsError(
            try EPUBDocument(
                data: archive(
                    replace(
                        entries(), "META-INF/container.xml", "<container><rootfile full-path='../bad'/></container>"))))
        XCTAssertThrowsError(
            try EPUBDocument(data: archive(replace(entries(), "Book/book.opf", "<package version='4.0'/>"))))
    }
    func testEncryptedContentRejectedButOptionalFontObfuscationAccepted() throws {
        let base =
            "<encryption><EncryptedData><EncryptionMethod Algorithm='%@'/><CipherData><CipherReference URI='Book/font.otf'/></CipherData></EncryptedData></encryption>"
        let allowed = String(format: base, "http://www.idpf.org/2008/embedding")
        XCTAssertNoThrow(try EPUBDocument(data: archive(entries(extras: [("META-INF/encryption.xml", allowed)]))))
        XCTAssertThrowsError(
            try EPUBDocument(
                data: archive(entries(extras: [("META-INF/encryption.xml", String(format: base, "drm/encryption"))]))))
        XCTAssertThrowsError(
            try EPUBDocument(
                data: archive(
                    entries(extras: [
                        (
                            "META-INF/encryption.xml",
                            allowed.replacingOccurrences(of: "Book/font.otf", with: "Book/text/a.xhtml")
                        )
                    ]))))
    }
    func testEntrySizeAndIllustrationLimits() throws {
        var value = entries()
        value.append(("Book/bomb", Data(repeating: 65, count: 20 * 1024 * 1024 + 1)))
        XCTAssertThrowsError(try EPUBDocument(data: archive(value)))
        value = entries().map { $0.0 == "Book/images/keys.png" ? ($0.0, Data(repeating: 1, count: 8_000_001)) : $0 }
        XCTAssertThrowsError(try EPUBDocument(data: archive(value)))
    }
    func testPathsResolveRelativeWithinBookAndRejectOutsideOrRemote() throws {
        XCTAssertEqual(
            try EPUBDocument.resolve("../images/keys.png#label", relativeTo: "Book/text/a.xhtml").0,
            "Book/images/keys.png")
        XCTAssertEqual(try EPUBDocument.resolve("#first", relativeTo: "Book/text/a.xhtml").0, "Book/text/a.xhtml")
        for href in [
            "../../../outside", "https://example.com", "%2fetc/passwd", "..%2f..%2f..%2foutside", "file:foo",
            "a?remote=1",
        ] { XCTAssertThrowsError(try EPUBDocument.resolve(href, relativeTo: "Book/text/a.xhtml")) }
    }
    func testEPUBSourceIdentityValidatesAgainstExactReadingOrder() throws {
        let data = try archive(entries())
        let epub = try EPUBDocument(data: data)
        let book = CourseBook(
            data: data, filename: "book.epub", pageCount: 2, title: epub.title,
            epubSections: epub.sections.map(\.reference))
        let source = CourseSourceAnchor(book: book, from: 1, through: 2)
        XCTAssertTrue(source.belongs(to: book))
        XCTAssertEqual(source.label, "Sections 1–2")
        var wrong = source
        wrong.epubHrefs?.reverse()
        XCTAssertFalse(wrong.belongs(to: book))
        var corrupt = book
        corrupt.epubSections = []
        XCTAssertFalse(source.belongs(to: corrupt))
        var missing = source
        missing.epubHrefs = nil
        XCTAssertFalse(missing.belongs(to: book))
        XCTAssertEqual(try JSONDecoder().decode(CourseBook.self, from: JSONEncoder().encode(book)), book)
    }
    func testEPUBOutlineSendsOnlySelectedTextAndImagesWithZDRAndHighReasoning() async throws {
        let bytes = try archive(entries())
        let epub = try EPUBDocument(data: bytes)
        let book = CourseBook(
            data: bytes, filename: "book.epub", pageCount: 2, title: epub.title,
            epubSections: epub.sections.map(\.reference))
        let source = CourseSourceAnchor(book: book, from: 1, through: 1)
        var calls = 0
        let client = CourseOutlineClient { request in
            calls += 1
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let serialized = String(decoding: body, as: UTF8.self)
            XCTAssertFalse(serialized.contains("Unselected secret section"))
            XCTAssertFalse(serialized.contains("application/pdf"))
            XCTAssertNil(json["plugins"])
            XCTAssertTrue(serialized.contains("Try C E G."))
            XCTAssertTrue(serialized.contains("image_url"))
            XCTAssertTrue(serialized.contains("untrusted source data"))
            XCTAssertEqual((json["provider"] as? [String: Any])?["zdr"] as? Bool, true)
            XCTAssertEqual((json["reasoning"] as? [String: Any])?["effort"] as? String, "high")
            let response =
                #"{"title":"A chapter","summary":"Explore inversions","lessons":[{"title":"Try inversions","fromPage":1,"throughPage":1,"kind":"Read & explore","bookSummary":"An inversion idea","goal":"Try the chord","practice":"Play slowly","readyWhen":"Describe a shape","passage":"","skills":["Harmony"],"prerequisites":[],"uncertainties":[]}],"caveats":[]}"#
            return (
                try JSONSerialization.data(withJSONObject: [
                    "choices": [["finish_reason": "stop", "message": ["content": response]]]
                ]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let reply = try await client.outline(
            pdf: Data(), source: source, book: book, instrument: .piano, apiKey: "fixture-key", epub: epub)
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(
            try reply.outline.chapter(source: source, book: book, instrument: .piano, origin: "test").lessons[0].source
                .belongs(to: book))
        do {
            _ = try await client.outline(
                pdf: Data(), source: source, book: book, instrument: .piano, apiKey: "fixture-key")
            XCTFail()
        } catch {}
        XCTAssertEqual(calls, 1)
    }
    func testOriginalBundledEPUBAndOptionalRealBook() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let original = try EPUBDocument(
            data: Data(contentsOf: root.appendingPathComponent("Resources/ImportExamples/pathway.epub")))
        XCTAssertEqual(original.sections.count, 3)
        XCTAssertEqual(original.images.count, 1)
        if let path = ProcessInfo.processInfo.environment["CADENCE_TEST_EPUB"] {
            let real = try EPUBDocument(data: Data(contentsOf: URL(fileURLWithPath: path)))
            XCTAssertGreaterThan(real.sections.count, 100)
            XCTAssertGreaterThan(real.navigation.count, 100)
            XCTAssertTrue(real.sections.contains { $0.reference.title.contains("INVERSIONS") })
            XCTAssertGreaterThan(real.images.count, 100)
        }
    }
    func testOutlinePreflightBoundsTextImagesAndSections() throws {
        let original = try EPUBDocument(data: archive(entries()))
        XCTAssertEqual(try original.outlineSections(from: 1, through: 1).count, 1)
        for (from, through) in [(0, 1), (1, 3), (2, 1)] {
            XCTAssertThrowsError(try original.outlineSections(from: from, through: through))
        }
        var value = original
        value.sections[0].text = String(repeating: "é", count: 30_001)
        XCTAssertThrowsError(try value.outlineSections(from: 1, through: 1))
        value = original
        value.sections[0].images = (1...13).map { "image\($0).png" }
        XCTAssertThrowsError(try value.outlineSections(from: 1, through: 1))
        value = original
        value.images["Book/images/keys.png"]?.data = Data(repeating: 0, count: 8_000_001)
        XCTAssertThrowsError(try value.outlineSections(from: 1, through: 1))
        value = original
        value.sections = Array(repeating: original.sections[0], count: 9)
        XCTAssertThrowsError(try value.outlineSections(from: 1, through: 9))
    }
}
