// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import ZIPFoundation

#if canImport(FoundationXML)
    import FoundationXML
#endif

public struct EPUBSectionReference: Codable, Equatable, Sendable {
    public var href: String
    public var title: String
    public init(href: String, title: String) {
        self.href = href
        self.title = title
    }
    public var valid: Bool { EPUBDocument.safePath(href) && !title.isEmpty && title.count <= 300 }
}
public struct EPUBNavigation: Equatable, Sendable {
    public var title: String
    public var section: Int
    public var fragment: String
}
public struct EPUBImage: Equatable, Sendable {
    public var path: String
    public var mediaType: String
    public var data: Data
}
public struct EPUBSection: Equatable, Sendable {
    public var reference: EPUBSectionReference
    public var text: String
    public var html: String
    public var images: [String]
}

/// Reads publication resources in memory. Book markup is data: no scripts,
/// external entities, remote resources, archive paths on disk or publisher CSS.
public struct EPUBDocument: Sendable {
    public var title: String
    public var author: String
    public var sections: [EPUBSection]
    public var navigation: [EPUBNavigation]
    public var images: [String: EPUBImage]
    public var notices: [String]
    public static let maximumBytes = 50 * 1024 * 1024

    public static func safePath(_ path: String) -> Bool {
        !path.isEmpty && path.count <= 1000 && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":")
            && !path.contains("\0")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                $0 == ".." || $0 == "." || $0.isEmpty
            })
    }
    static func resolve(_ href: String, relativeTo file: String) throws -> (String, String) {
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard let decoded = String(parts[0]).removingPercentEncoding, !decoded.hasPrefix("/"), !decoded.contains(":"),
            !decoded.contains("\\"), !decoded.contains("?")
        else { throw MusicError.invalid("The EPUB contains an unsupported resource link.") }
        var components = file.split(separator: "/").dropLast().map(String.init)
        if decoded.isEmpty {
            components = file.split(separator: "/").map(String.init)
        } else {
            for part in decoded.split(separator: "/") {
                if part == "." { continue }
                if part == ".." {
                    guard !components.isEmpty else { throw MusicError.invalid("The EPUB resource escapes its book.") }
                    components.removeLast()
                } else {
                    components.append(String(part))
                }
            }
        }
        let path = components.joined(separator: "/")
        guard safePath(path) else { throw MusicError.invalid("The EPUB has an invalid resource path.") }
        return (path, parts.count == 2 ? String(parts[1]).removingPercentEncoding ?? "" : "")
    }
    public init(data: Data) throws {
        guard data.count <= Self.maximumBytes, data.starts(with: Data([0x50, 0x4b])) else {
            throw MusicError.invalid("Choose an EPUB smaller than 50 MB.")
        }
        let archive = try Archive(data: data, accessMode: .read)
        var paths = Set<String>()
        var expanded: UInt64 = 0
        for entry in archive {
            guard paths.count < 5000, entry.type != .symlink, paths.insert(entry.path).inserted,
                Self.safePath(entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path),
                entry.uncompressedSize <= 20 * 1024 * 1024
            else { throw MusicError.invalid("This EPUB has unsafe, duplicate or oversized archive entries.") }
            expanded += entry.uncompressedSize
            guard expanded <= 150 * 1024 * 1024 else {
                throw MusicError.invalid("This EPUB expands beyond the supported size.")
            }
        }
        func read(_ path: String, limit: Int = 1_500_000) throws -> Data {
            guard Self.safePath(path), let entry = archive[path], entry.type == .file,
                entry.uncompressedSize <= UInt64(limit)
            else { throw MusicError.invalid("The EPUB is missing a supported resource: \(path).") }
            var bytes = Data()
            let crc = try archive.extract(entry) { chunk in
                guard bytes.count + chunk.count <= limit else {
                    throw MusicError.invalid("The EPUB resource is too large.")
                }
                bytes.append(chunk)
            }
            guard crc == entry.checksum else { throw MusicError.invalid("The EPUB failed its integrity check.") }
            return bytes
        }
        guard
            String(decoding: try read("mimetype", limit: 100), as: UTF8.self).trimmingCharacters(
                in: .whitespacesAndNewlines) == "application/epub+zip"
        else { throw MusicError.invalid("This ZIP file is not an EPUB publication.") }
        let container = try BookXML.read(read("META-INF/container.xml", limit: 65536))
        guard let package = container.descendants("rootfile").first?.attributes["full-path"], Self.safePath(package)
        else { throw MusicError.invalid("The EPUB has no valid publication package.") }
        let opf = try BookXML.read(read(package))
        guard ["2.0", "3.0", "3.1", "3.2", "3.3"].contains(opf.attributes["version"] ?? "") else {
            throw MusicError.invalid("Use an EPUB 2 or EPUB 3 book.")
        }
        let items = opf.descendants("manifest").first?.children.filter { $0.name == "item" } ?? []
        var manifest: [String: (String, String)] = [:]
        var byPath: [String: String] = [:]
        for item in items {
            guard let id = item.attributes["id"], !id.isEmpty, manifest[id] == nil, let href = item.attributes["href"],
                let mime = item.attributes["media-type"]
            else { throw MusicError.invalid("The EPUB manifest is incomplete or duplicated.") }
            // Remote optional resources are never fetched.
            guard let (path, _) = try? Self.resolve(href, relativeTo: package) else { continue }
            manifest[id] = (path, mime)
            byPath[path] = mime
        }
        if paths.contains("META-INF/encryption.xml") {
            let encryption = try BookXML.read(read("META-INF/encryption.xml"))
            for node in encryption.descendants("EncryptedData") {
                let algorithm = node.descendants("EncryptionMethod").first?.attributes["Algorithm"] ?? ""
                guard ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"].contains(algorithm)
                else {
                    throw MusicError.invalid(
                        "This EPUB has encrypted content. Choose an unencrypted edition; Cadence does not remove DRM.")
                }
                let uri = node.descendants("CipherReference").first?.attributes["URI"] ?? ""
                guard let mime = byPath[uri], mime.contains("font") || mime.contains("opentype") else {
                    throw MusicError.invalid("The EPUB encrypts content other than optional fonts.")
                }
            }
        }
        let spine = opf.descendants("spine").first
        let refs = spine?.children.filter { $0.name == "itemref" } ?? []
        guard (1...1000).contains(refs.count) else {
            throw MusicError.invalid("The EPUB needs 1–1,000 reading sections.")
        }
        title = String(
            (opf.descendants("metadata").first?.descendants("title").first?.text ?? "Untitled book").prefix(200))
        author = String((opf.descendants("metadata").first?.descendants("creator").first?.text ?? "").prefix(200))
        sections = []
        images = [:]
        navigation = []
        notices = []
        var textBytes = 0
        var imageBytes = 0
        var sectionNodes: [BookXML] = []
        for ref in refs {
            guard let id = ref.attributes["idref"], let (path, mime) = manifest[id], mime == "application/xhtml+xml"
            else {
                throw MusicError.invalid(
                    "This edition contains an unsupported reading section. XHTML EPUB 2 and 3 editions are supported.")
            }
            let bytes = try read(path)
            textBytes += bytes.count
            guard textBytes <= 15_000_000 else {
                throw MusicError.invalid("This EPUB contains too much text to index at once.")
            }
            sectionNodes.append(try BookXML.read(bytes))
            sections.append(
                .init(
                    reference: .init(href: path, title: "Section \(sections.count+1)"), text: "", html: "", images: []))
        }
        if let navItem = items.first(where: {
            ($0.attributes["properties"] ?? "").split(separator: " ").contains("nav")
        }), let id = navItem.attributes["id"], let (path, _) = manifest[id] {
            let tree = try BookXML.read(read(path))
            let toc = tree.descendants("nav").first {
                ($0.attributes["epub:type"] ?? $0.attributes["type"] ?? "").split(separator: " ").contains("toc")
            }
            for node in toc?.descendants("a") ?? [] {
                if let href = node.attributes["href"] { addNavigation(node.text, href: href, file: path) }
            }
        } else if let id = spine?.attributes["toc"], let (path, _) = manifest[id] {
            let tree = try BookXML.read(read(path))
            for node in tree.descendants("navPoint") {
                if let href = node.children.first(where: { $0.name == "content" })?.attributes["src"],
                    let label = node.children.first(where: { $0.name == "navLabel" })?.text
                {
                    addNavigation(label, href: href, file: path)
                }
            }
        }
        for i in sections.indices {
            let tree = sectionNodes[i]
            let file = sections[i].reference.href
            let body = tree.descendants("body").first ?? tree
            let heading = body.descendants("h1").first ?? body.descendants("h2").first ?? body.descendants("h3").first
            sections[i].reference.title = String(
                (navigation.first(where: { $0.section == i && $0.fragment.isEmpty })?.title ?? heading?.text
                    ?? navigation.first(where: { $0.section == i })?.title ?? "Section \(i+1)").prefix(300))
            sections[i].text = body.readableText
            var sectionImages: [String] = []
            func render(_ node: BookXML, depth: Int = 0) throws -> String {
                if ["script", "style", "iframe", "object", "embed", "form", "head", "svg", "audio", "video"].contains(
                    node.name)
                {
                    return ""
                }
                if node.name == "img" {
                    guard let src = node.attributes["src"], let (path, _) = try? Self.resolve(src, relativeTo: file),
                        let mime = byPath[path], ["image/jpeg", "image/png", "image/gif", "image/webp"].contains(mime)
                    else { return "<p class='notice'>An unsupported illustration is omitted.</p>" }
                    if images[path] == nil {
                        let bytes = try read(path, limit: 8_000_000)
                        imageBytes += bytes.count
                        guard imageBytes <= 64_000_000 else {
                            throw MusicError.invalid("The EPUB's illustrations exceed the reading limit.")
                        }
                        images[path] = .init(path: path, mediaType: mime, data: bytes)
                    }
                    if !sectionImages.contains(path) { sectionImages.append(path) }
                    return
                        "<img alt='\(Self.escape(node.attributes["alt"] ?? "Book illustration"))' src='cadence-image:\(Self.escape(path))'>"
                }
                let allowed = [
                    "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "em", "strong", "b", "i", "sup", "sub",
                    "blockquote", "table", "thead", "tbody", "tr", "td", "th", "br", "hr", "figure", "figcaption",
                    "div", "span",
                ]
                let tag = allowed.contains(node.name) ? node.name : "div"
                let id = node.attributes["id"].map { " id='\(Self.escape($0))'" } ?? ""
                var html = ""
                for part in node.content {
                    switch part {
                    case .text(let t): html += Self.escape(t)
                    case .node(let child): html += try render(child, depth: depth + 1)
                    }
                }
                return "<\(tag)\(id)>\(html)</\(tag)>"
            }
            sections[i].html = try render(body)
            sections[i].images = sectionImages
        }
        if opf.descendants("meta").contains(where: {
            $0.attributes["property"] == "rendition:layout" && $0.text == "pre-paginated"
        }) {
            notices.append(
                "This fixed-layout edition is presented in Cadence's reading layout. Compare diagrams with the original edition when reviewing exercises."
            )
        }
        notices.append(
            "Reading layout preserves text and supported images. Publisher styling, scripts, audio, video and SVG artwork are not included."
        )
    }
    private mutating func addNavigation(_ title: String, href: String, file: String) {
        guard navigation.count < 2000, let (path, fragment) = try? Self.resolve(href, relativeTo: file),
            let index = sections.firstIndex(where: { $0.reference.href == path }), !title.isEmpty
        else { return }
        navigation.append(
            .init(title: String(title.prefix(300)), section: index, fragment: String(fragment.prefix(500))))
    }
    public func outlineSections(from: Int, through: Int) throws -> [EPUBSection] {
        guard from > 0, through >= from, through <= sections.count, through - from < 8 else {
            throw MusicError.invalid("Choose up to eight existing EPUB reading sections.")
        }
        let selected = Array(sections[(from - 1)..<through])
        let paths = Set(selected.flatMap(\.images))
        guard paths.count <= 12, paths.compactMap({ images[$0]?.data.count }).reduce(0, +) <= 8_000_000,
            selected.map({ $0.text.utf8.count }).reduce(0, +) <= 60_000
        else {
            throw MusicError.invalid(
                "Choose a smaller EPUB excerpt: up to 12 images and 60,000 text bytes per outline.")
        }
        return selected
    }
    public func readingHTML(section: Int) throws -> String {
        guard sections.indices.contains(section) else { throw MusicError.invalid("This book section is unavailable.") }
        var body = sections[section].html
        for path in sections[section].images {
            if let image = images[path] {
                body = body.replacingOccurrences(
                    of: "cadence-image:" + Self.escape(path),
                    with: "data:\(image.mediaType);base64," + image.data.base64EncodedString())
            }
        }
        return """
            <!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline';"><style>
            :root{color-scheme:light}body{margin:0;padding:26px 30px 60px;background:#fbfaf6;color:#283735;font:17px/1.7 Georgia,serif;overflow-wrap:anywhere}h1,h2,h3{font-weight:500;line-height:1.25;color:#315f51}h1{font-size:27px}h2{font-size:23px}h3{font-size:20px}img{display:block;max-width:100%;height:auto;margin:20px auto}p{margin:0 0 16px}table{max-width:100%;border-collapse:collapse}td,th{padding:5px;border:1px solid #ddd}blockquote{margin:15px;border-left:2px solid #bacbbd;padding-left:15px}.notice{font:13px system-ui;color:#777}
            </style></head><body>\(body)</body></html>
            """
    }
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

private final class BookXML {
    enum Content {
        case text(String)
        case node(BookXML)
    }
    let name: String
    let attributes: [String: String]
    var content: [Content] = []
    init(_ name: String, _ attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }
    var children: [BookXML] {
        content.compactMap {
            if case .node(let n) = $0 { return n }
            return nil
        }
    }
    var text: String {
        content.map {
            switch $0 {
            case .text(let t): return t
            case .node(let n): return n.text
            }
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var readableText: String {
        if ["script", "style", "head", "iframe", "object", "svg", "form"].contains(name) { return "" }
        return content.map {
            switch $0 {
            case .text(let t): return t
            case .node(let n): return n.readableText
            }
        }.joined(separator: " ").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    func descendants(_ name: String) -> [BookXML] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
    }
    static func read(_ data: Data) throws -> BookXML {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16),
            text.range(of: "<!ENTITY", options: .caseInsensitive) == nil
        else { throw MusicError.invalid("The EPUB uses unsupported text encoding or XML entities.") }
        let reader = BookXMLReader()
        let parser = XMLParser(data: Data(text.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), let root = reader.root else {
            throw MusicError.invalid("An EPUB section is malformed or too deeply nested.")
        }
        return root
    }
}
private final class BookXMLReader: NSObject, XMLParserDelegate {
    var root: BookXML?, stack: [BookXML] = [], count = 0
    func parser(
        _ parser: XMLParser, didStartElement raw: String, namespaceURI: String?, qualifiedName: String?,
        attributes: [String: String]
    ) {
        count += 1
        guard count <= 30000, stack.count < 64 else {
            parser.abortParsing()
            return
        }
        let node = BookXML(String(raw.split(separator: ":").last ?? Substring(raw)), attributes)
        if let parent = stack.last { parent.content.append(.node(node)) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.content.append(.text(string)) }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }
}
