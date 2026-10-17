// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

#if canImport(FoundationXML)
    import FoundationXML
#endif

/// A separate adapter keeps harmony parsing out of the note/voice importer.
enum HarmonyXML {
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func encode(_ entry: EditorHarmony) -> String {
        let s = entry.symbol
        func pitch(_ p: Pitch, prefix: String) -> String {
            "<\(prefix)><\(prefix)-step>\(Pitch.letters[p.letter])</\(prefix)-step><\(prefix)-alter>\(p.accidental)</\(prefix)-alter></\(prefix)>"
        }
        var xml = "<harmony placement=\"above\">"
        xml += s.root.map { pitch($0, prefix: "root") } ?? "<root><root-step text=\"\">C</root-step></root>"
        let text = s.kind == .none ? "N.C." : s.kindText
        xml += "<kind" + (text.map { " text=\"\(escape($0))\"" } ?? "") + ">\(s.kind.rawValue)</kind>"
        if let bass = s.bass { xml += pitch(bass, prefix: "bass") }
        for d in s.degrees {
            xml +=
                "<degree print-object=\"\(d.hidden ? "no" : "yes")\"><degree-value>\(d.value)</degree-value><degree-alter>\(d.alter)</degree-alter><degree-type>\(d.type.rawValue)</degree-type></degree>"
        }
        return xml + "<offset>\(entry.tick)</offset><staff>\(entry.staff)</staff></harmony>"
    }
    static func decode(_ xml: String, partID: String? = nil) throws -> [EditorHarmony] {
        let tree = try XMLDocument(xmlString: xml, options: [.nodeLoadExternalEntitiesNever])
        let unsupported = MusicError.invalid(
            "This harmony marking uses a chord structure Compose cannot preserve yet. Keep the original and open it in Studies, or simplify its chord symbols before importing."
        )
        var results: [EditorHarmony] = []
        var divisions = 1.0
        func text(_ e: XMLElement, _ name: String) -> String? {
            e.elements(forName: name).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func number(_ text: String?) throws -> Double {
            guard let text, let value = Double(text), value.isFinite, abs(value) < 1_000_000 else { throw unsupported }
            return value
        }
        func integer(_ text: String?, fallback: Int? = nil) throws -> Int {
            if text == nil, let fallback { return fallback }
            let n = try number(text)
            guard n.rounded() == n else { throw unsupported }
            return Int(n)
        }
        func pitch(_ element: XMLElement?, _ prefix: String) throws -> Pitch {
            guard let element, let name = text(element, prefix + "-step"),
                let letter = Pitch.letters.firstIndex(of: name), element.elements(forName: prefix + "-step").count == 1
            else { throw unsupported }
            let alter = try integer(text(element, prefix + "-alter"), fallback: 0)
            guard (-2...2).contains(alter) else { throw unsupported }
            return Pitch(letter, alter)
        }
        guard
            let part = tree.rootElement()?.elements(forName: "part").first(where: {
                partID == nil || $0.attribute(forName: "id")?.stringValue == partID
            })
        else { return [] }
        for (bar, measure) in part.elements(forName: "measure").enumerated() {
            var cursor = 0.0
            for node in measure.children ?? [] {
                guard let element = node as? XMLElement else { continue }
                switch element.name {
                case "attributes":
                    if let value = text(element, "divisions") {
                        divisions = try number(value)
                        guard divisions > 0 else { throw unsupported }
                    }
                case "note":
                    if element.elements(forName: "chord").isEmpty && element.elements(forName: "grace").isEmpty {
                        cursor += try number(text(element, "duration")) * 480 / divisions
                    }
                case "backup": cursor -= try number(text(element, "duration")) * 480 / divisions
                case "forward": cursor += try number(text(element, "duration")) * 480 / divisions
                case "harmony":
                    guard results.count < 2048,
                        element.elements(forName: "root").count == 1, element.elements(forName: "kind").count == 1,
                        element.elements(forName: "bass").count <= 1,
                        element.attribute(forName: "print-object")?.stringValue != "no",
                        element.attribute(forName: "placement")?.stringValue != "below",
                        [nil, "explicit", "implied"].contains(element.attribute(forName: "type")?.stringValue),
                        (element.children ?? []).compactMap({ $0 as? XMLElement }).allSatisfy({
                            ["root", "kind", "bass", "degree", "offset", "staff"].contains($0.name ?? "")
                        }),
                        let kindElement = element.elements(forName: "kind").first,
                        let kind = text(element, "kind").flatMap(HarmonyKind.init(rawValue:))
                    else { throw unsupported }
                    let root = kind == .none ? nil : try pitch(element.elements(forName: "root").first, "root")
                    let bass = try element.elements(forName: "bass").first.map { try pitch($0, "bass") }
                    let degrees = try element.elements(forName: "degree").map { d -> HarmonyDegree in
                        guard let type = text(d, "degree-type").flatMap(HarmonyDegreeType.init(rawValue:)) else {
                            throw unsupported
                        }
                        return try HarmonyDegree(
                            integer(text(d, "degree-value")), alter: integer(text(d, "degree-alter")), type: type,
                            hidden: d.attribute(forName: "print-object")?.stringValue == "no")
                    }
                    let offset = try text(element, "offset").map { try number($0) * 480 / divisions } ?? 0
                    let tick = cursor + offset
                    guard tick.isFinite, abs(tick) < 100000, abs(tick.rounded() - tick) < 0.00001 else {
                        throw unsupported
                    }
                    let symbol = ChordSymbol(
                        root: root, kind: kind, bass: bass, degrees: degrees,
                        kindText: kind == .none ? nil : kindElement.attribute(forName: "text")?.stringValue)
                    guard symbol.valid else { throw unsupported }
                    results.append(
                        EditorHarmony(
                            bar: bar, tick: Int(tick.rounded()),
                            staff: try integer(text(element, "staff"), fallback: 1), symbol: symbol))
                default: break
                }
            }
        }
        return results
    }
    static func context(_ study: MusicStudy) -> String {
        guard study.document.originalXML.contains("<harmony") else { return "No chord symbols supplied." }
        guard let harmonies = try? decode(study.document.originalXML, partID: study.partID) else {
            return
                "Some printed harmony could not be interpreted. Ask the learner to review the original; do not invent the missing chord symbols."
        }
        let selected = harmonies.filter { (study.from...study.through).contains($0.bar) }
        let entries = selected.prefix(256).map {
            "bar \($0.bar+1), zero-based quarter-beat \(Double($0.tick)/480), staff \($0.staff): \($0.symbol.label)"
        }
        return "Chord symbols supplied in the score (not inferred from the notes): " + entries.joined(separator: "; ")
            + (selected.count > 256 ? ". Only the first 256 symbols are included." : "")
            + ". Distinguish written harmony from your own harmonic interpretation. PDF-derived labels may still need correction."
    }
}
