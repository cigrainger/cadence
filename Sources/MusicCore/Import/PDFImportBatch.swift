// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum PDFPageRanges {
    public static func parse(_ text: String, pageCount: Int) throws -> [Int] {
        guard (1...1000).contains(pageCount), text.count <= 256 else {
            throw MusicError.invalid("Choose pages inside this PDF.")
        }
        let normal = text.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
        var pages = Set<Int>()
        for part in normal.split(separator: ",", omittingEmptySubsequences: false) {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard (1...2).contains(bounds.count), bounds.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
                let first = Int(bounds[0]), let last = Int(bounds.last!), first >= 1, last >= first, last <= pageCount
            else {
                throw MusicError.invalid(
                    "Use page numbers or ranges, such as 29–32, 35. Pages must be inside this PDF.")
            }
            guard last - first < 16 else {
                throw MusicError.invalid("Choose up to 16 pages per combined score, with up to 128 bars in total.")
            }
            pages.formUnion(first...last)
            guard pages.count <= 16 else {
                throw MusicError.invalid("Choose up to 16 pages per combined score, with up to 128 bars in total.")
            }
        }
        guard !pages.isEmpty else { throw MusicError.invalid("Choose at least one page.") }
        return pages.sorted()
    }
}

public enum PDFPageStatus: String, Codable, Sendable { case pending, reading, ready, failed, stopped, removed }
public struct PDFPageReplacement: Codable, Equatable, Sendable {
    public var document: EditorDocument
    public var model: String
    public var warnings: [String]
    public init(document: EditorDocument, model: String, warnings: [String]) {
        self.document = document
        self.model = model
        self.warnings = warnings
    }
}
public struct PDFImportPage: Codable, Equatable, Identifiable, Sendable {
    public var id: Int { page }
    public var page: Int
    public var barCount = 0
    public var status = PDFPageStatus.pending
    public var passage: String
    public var model: String
    public var warnings: [String] = []
    public var error: String?
    public var reviewed = false
    public var attempts = 0
    public var costUSD = 0.0
    public var unpricedAttempts = 0
    public var replacement: PDFPageReplacement?
    public init(page: Int, model: String, passage: String = "") {
        self.page = page
        self.model = model
        self.passage = passage
    }
    public var valid: Bool {
        (1...1000).contains(page) && (0...128).contains(barCount) && passage.count <= 500 && model.count <= 200
            && !model.isEmpty && warnings.count <= 100 && warnings.allSatisfy { $0.count <= 1000 }
            && (error?.count ?? 0) <= 4000 && (0...10000).contains(attempts)
            && (0...attempts).contains(unpricedAttempts) && costUSD.isFinite && (0...10000).contains(costUSD)
            && (replacement.map {
                $0.document.pdfSource == nil && (try? $0.document.validated()) != nil && $0.warnings.count <= 100
                    && $0.warnings.allSatisfy { $0.count <= 1000 } && $0.model.count <= 200
            } ?? true)
    }
    public var label: String {
        if status == .reading { return "Reading…" }
        if replacement != nil { return "Replacement to review" }
        if barCount > 0 { return reviewed ? "Reviewed" : "Ready to review" }
        switch status {
        case .pending: return "Waiting"
        case .failed: return "Needs retry"
        case .stopped: return "Stopped"
        case .removed: return "Removed from score"
        default: return "Waiting"
        }
    }
}

extension PDFScoreSource {
    public var importedPageCount: Int { pages?.filter { $0.barCount > 0 }.count ?? 1 }
    public var totalPageBars: Int { pages?.reduce(0) { $0 + $1.barCount } ?? 0 }
    public func range(for page: Int) -> Range<Int>? {
        guard let pages, let index = pages.firstIndex(where: { $0.page == page }), pages[index].barCount > 0 else {
            return nil
        }
        let start = pages.prefix(index).reduce(0) { $0 + $1.barCount }
        return start..<(start + pages[index].barCount)
    }
    public func page(at bar: Int) -> PDFImportPage? { pages?.first { range(for: $0.page)?.contains(bar) == true } }
    public func reference(at bar: Int) -> PDFScoreSource {
        guard let item = page(at: bar) else { return self }
        var copy = self
        copy.page = item.page
        copy.model = item.model
        copy.warnings = item.warnings
        copy.reviewed = item.reviewed
        copy.costUSD = item.costUSD
        return copy
    }
    public mutating func setReviewed(_ value: Bool, page: Int) {
        guard let index = pages?.firstIndex(where: { $0.page == page }) else {
            reviewed = value
            return
        }
        pages![index].reviewed = value
        reviewed = pages!.allSatisfy { $0.barCount > 0 && $0.reviewed }
    }
    public mutating func insertBars(at bar: Int, count: Int) {
        guard let pages, let target = page(at: bar) ?? pages.last(where: { $0.barCount > 0 }),
            let index = pages.firstIndex(where: { $0.page == target.page })
        else { return }
        self.pages![index].barCount += count
        self.pages![index].reviewed = false
        reviewed = false
    }
    public mutating func deleteBars(_ bars: ClosedRange<Int>) {
        guard let pages else { return }
        let original = self
        for index in pages.indices {
            guard let range = original.range(for: pages[index].page) else { continue }
            let count = range.filter { bars.contains($0) }.count
            if count > 0 {
                self.pages![index].barCount -= count
                self.pages![index].reviewed = false
                if self.pages![index].barCount == 0 { self.pages![index].status = .removed }
            }
        }
        reviewed = self.pages!.allSatisfy { $0.barCount > 0 && $0.reviewed }
    }
    public func excerpt(_ bars: ClosedRange<Int>) -> PDFScoreSource {
        guard let pages else { return self }
        var copy = self
        copy.pages = pages.compactMap { item in
            guard let range = range(for: item.page) else { return nil }
            let count = range.filter { bars.contains($0) }.count
            guard count > 0 else { return nil }
            var item = item
            item.barCount = count
            item.status = .ready
            item.replacement = nil
            return item
        }
        if let first = copy.pages?.first {
            copy.page = first.page
            copy.reviewed = copy.pages!.allSatisfy(\.reviewed)
        } else {
            copy.pages = nil
            copy.reviewed = false
        }
        return copy
    }
}

extension EditorDocument {
    public mutating func recoverPDFQueue() {
        guard var source = pdfSource, let pages = source.pages else { return }
        for i in pages.indices where pages[i].status == .reading {
            source.pages![i].status = pages[i].barCount > 0 ? .ready : .stopped
            source.pages![i].error =
                "This request was interrupted. Resume or retry explicitly; work already sent may have been charged."
        }
        pdfSource = source
    }
    public mutating func invalidatePDFReviews(comparedTo old: EditorDocument) {
        guard var source = pdfSource else { return }
        let globalChange =
            instrument != old.instrument || meter != old.meter || fifths != old.fifths || minor != old.minor
            || tempo != old.tempo || tuning != old.tuning || capo != old.capo
        guard harmonies != old.harmonies || events != old.events || barCount != old.barCount || globalChange else {
            return
        }
        guard let pages = source.pages else {
            source.reviewed = false
            pdfSource = source
            return
        }
        for i in pages.indices {
            func portion(_ document: EditorDocument) -> [EditorEvent] {
                guard let range = document.pdfSource?.range(for: pages[i].page) else { return [] }
                return document.events.filter { range.contains($0.bar) }.map {
                    var e = $0
                    e.bar -= range.lowerBound
                    return e
                }
            }
            func chords(_ document: EditorDocument) -> [EditorHarmony] {
                guard let range = document.pdfSource?.range(for: pages[i].page) else { return [] }
                return document.harmonies.filter { range.contains($0.bar) }.map {
                    var h = $0
                    h.bar -= range.lowerBound
                    return h
                }
            }
            if globalChange || chords(self) != chords(old) || portion(self) != portion(old) {
                source.pages![i].reviewed = false
            }
        }
        source.reviewed = source.pages!.allSatisfy { $0.barCount > 0 && $0.reviewed }
        pdfSource = source
    }
    /// Replace only this page's bars. Other pages retain note IDs and corrections.
    public mutating func replacePDFPage(_ page: Int, with replacement: PDFPageReplacement) throws {
        guard var source = pdfSource, let index = source.pages?.firstIndex(where: { $0.page == page }) else {
            throw MusicError.invalid("This score has no import queue for that page.")
        }
        let incoming = try replacement.document.validated()
        let oldCount = source.pages![index].barCount
        guard incoming.pdfSource == nil, incoming.instrument == instrument else {
            throw MusicError.invalid("Use the same instrument for all pages.")
        }
        let previousCount = source.totalPageBars
        let otherCount = previousCount - oldCount
        guard otherCount == 0 || (incoming.meter == meter && incoming.fifths == fifths && incoming.minor == minor)
        else {
            throw MusicError.invalid(
                "This page has a different key or meter. A combined score currently needs one key and meter. Choose another passage or import it separately."
            )
        }
        guard otherCount + incoming.barCount <= 128 else {
            throw MusicError.invalid(
                "This page would take the combined score beyond 128 bars. Choose a shorter passage for this page.")
        }
        let start = source.pages!.prefix(index).reduce(0) { $0 + $1.barCount }
        let end = start + oldCount
        let delta = incoming.barCount - oldCount
        var copy = self
        if previousCount == 0 {
            copy.events = []
            copy.harmonies = []
            copy.tempo = incoming.tempo
        } else {
            copy.events.removeAll { (start..<end).contains($0.bar) }
            copy.harmonies.removeAll { (start..<end).contains($0.bar) }
            for i in copy.harmonies.indices where copy.harmonies[i].bar >= end { copy.harmonies[i].bar += delta }
            for i in copy.events.indices where copy.events[i].bar >= end { copy.events[i].bar += delta }
            // Do not create a new tie across a replaced page boundary.
            for staff in 1...staffCount {
                for voice in voices(staff: staff) {
                    if let id = copy.inBar(start - 1, staff: staff, voice: voice).last?.id,
                        let i = copy.events.firstIndex(where: { $0.id == id })
                    {
                        copy.events[i].tieNext = false
                    }
                }
            }
        }
        let ids = Dictionary(uniqueKeysWithValues: incoming.events.map { ($0.id, UUID()) })
        copy.events += incoming.events.map { item in
            var e = item
            e.id = ids[item.id]!
            e.bar += start
            e.slurTo = item.slurTo.flatMap { ids[$0] }
            e.pitches = e.pitches.map {
                var p = $0
                p.id = UUID()
                return p
            }
            return e
        }
        copy.harmonies += incoming.harmonies.map {
            var h = $0
            h.id = UUID()
            h.bar += start
            return h
        }
        copy.barCount = otherCount + incoming.barCount
        if otherCount == 0 {
            copy.meter = incoming.meter
            copy.fifths = incoming.fifths
            copy.minor = incoming.minor
        }
        for staff in 1...copy.staffCount {
            for voice in copy.voices(staff: staff) {
                for bar in 0..<copy.barCount where copy.inBar(bar, staff: staff, voice: voice).isEmpty {
                    let blank = try EditorDocument.blank(instrument: instrument, bars: 1, meter: copy.meter)
                    copy.events += blank.events.filter { $0.staff == staff }.map {
                        var e = $0
                        e.bar = bar
                        e.voice = voice
                        return e
                    }
                }
            }
        }
        copy.events = copy.events.enumerated().sorted { a, b in
            let x = a.element
            let y = b.element
            if x.staff != y.staff { return x.staff < y.staff }
            if x.voice != y.voice { return x.voice < y.voice }
            if x.bar != y.bar { return x.bar < y.bar }
            return a.offset < b.offset
        }.map(\.element)
        source.pages![index].barCount = incoming.barCount
        source.pages![index].status = .ready
        source.pages![index].reviewed = false
        source.pages![index].model = replacement.model
        source.pages![index].warnings = replacement.warnings
        source.pages![index].replacement = nil
        source.pages![index].error = nil
        if previousCount > 0 && incoming.tempo != tempo {
            source.pages![index].warnings.append(
                "This page's detected tempo differs. The combined score keeps its current tempo.")
        }
        source.reviewed = false
        copy.pdfSource = source
        copy.clearInvalidTies()
        if instrument == .guitar { try copy.setGuitar(tuning: tuning, capo: capo) }
        copy.invalidatePDFReviews(comparedTo: self)
        self = try copy.validated()
    }
}
