// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import CryptoKit
import Foundation

public enum CourseSkill: String, Codable, CaseIterable, Sendable {
    case reading = "Reading"
    case pulse = "Pulse & rhythm"
    case listening = "Listening"
    case harmony = "Harmony"
    case recall = "Recall"
    case
        expression = "Musical choices"
}
public enum CourseLessonKind: String, Codable, CaseIterable, Sendable {
    case explanation = "Read & explore"
    case music = "Playable exercise"
}
public struct CourseBook: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var fileID: UUID
    public var digest: String
    public var filename: String
    public var pageCount: Int
    public var epubSections: [EPUBSectionReference]?
    public var isEPUB: Bool { epubSections != nil }
    public var title: String
    public var author: String
    public var edition: String
    public init(
        fileID: UUID = UUID(), data: Data, filename: String, pageCount: Int, title: String, author: String = "",
        edition: String = "", epubSections: [EPUBSectionReference]? = nil
    ) {
        self.epubSections = epubSections
        self.fileID = fileID
        digest = Self.digest(data)
        self.filename = filename
        self.pageCount = pageCount
        self.title = title
        self.author = author
        self.edition = edition
    }
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public var valid: Bool {
        ScoreRevision.valid(digest) && (1...1000).contains(pageCount) && courseText(title, 200)
            && courseText(filename, 300) && author.count <= 200 && edition.count <= 200
            && (epubSections.map {
                $0.count == pageCount && $0.allSatisfy(\.valid) && Set($0.map(\.href)).count == $0.count
            } ?? true)
    }
}
public struct CourseSourceAnchor: Codable, Equatable, Sendable {
    public var bookID: UUID
    public var digest: String
    public var fromPage: Int
    public var throughPage: Int
    public var printedLabel: String
    public var epubHrefs: [String]?
    public init(book: CourseBook, from: Int, through: Int, printedLabel: String = "") {
        bookID = book.id
        digest = book.digest
        fromPage = from
        throughPage = through
        self.printedLabel = printedLabel
        if let sections = book.epubSections, from > 0, through >= from, through <= sections.count {
            epubHrefs = sections[(from - 1)..<through].map(\.href)
        }
    }
    public var pages: [Int] { valid ? Array(fromPage...throughPage) : [] }
    public var valid: Bool {
        ScoreRevision.valid(digest) && (1...1000).contains(fromPage) && throughPage >= fromPage && throughPage <= 1000
            && throughPage - fromPage < 8 && printedLabel.count <= 120
            && (epubHrefs.map { $0.count == throughPage - fromPage + 1 && $0.allSatisfy(EPUBDocument.safePath) } ?? true)
    }
    public var label: String {
        (epubHrefs == nil ? "PDF page" : "Section")
            + "\(fromPage == throughPage ? " " + String(fromPage) : "s \(fromPage)–\(throughPage)")"
            + (printedLabel.isEmpty ? "" : " · " + printedLabel)
    }
    public func belongs(to book: CourseBook) -> Bool {
        book.valid && valid && bookID == book.id && digest == book.digest && throughPage <= book.pageCount
            && (book.isEPUB
                ? epubHrefs == Array(book.epubSections![(fromPage - 1)..<throughPage]).map(\.href) : epubHrefs == nil)
    }
    public func contains(_ other: Self) -> Bool {
        valid && other.valid && bookID == other.bookID && digest == other.digest && other.fromPage >= fromPage
            && other.throughPage <= throughPage
            && ((epubHrefs == nil && other.epubHrefs == nil)
                || (epubHrefs != nil && other.epubHrefs != nil && Set(other.epubHrefs!).isSubset(of: Set(epubHrefs!))))
    }
}
public struct CourseLesson: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var title: String
    public var source: CourseSourceAnchor
    public var kind: CourseLessonKind
    public var instrument: EditorInstrument
    public var bookSummary: String
    public var goal: String
    public var practice: String
    public var readyWhen: String
    public var passage: String
    public var skills: [CourseSkill]
    public var prerequisites: [UUID]
    public var uncertainties: [String]
    public init(
        title: String, source: CourseSourceAnchor, kind: CourseLessonKind = .music,
        instrument: EditorInstrument = .guitar,
        bookSummary: String = "", goal: String = "", practice: String = "", readyWhen: String = "",
        passage: String = "",
        skills: [CourseSkill] = [.reading], prerequisites: [UUID] = [], uncertainties: [String] = []
    ) {
        self.title = title
        self.source = source
        self.kind = kind
        self.instrument = instrument
        self.bookSummary = bookSummary
        self.goal = goal
        self.practice = practice
        self.readyWhen = readyWhen
        self.passage = passage
        self.skills = skills
        self.prerequisites = prerequisites
        self.uncertainties = uncertainties
    }
    public var valid: Bool {
        courseText(title, 160) && source.valid && bookSummary.count <= 2000 && courseText(goal, 1000)
            && courseText(practice, 2000) && courseText(readyWhen, 1000) && passage.count <= 500
            && (kind != .music || (courseText(passage, 500) && source.throughPage - source.fromPage < 4))
            && (1...6).contains(skills.count) && Set(skills).count == skills.count && prerequisites.count <= 11
            && Set(prerequisites).count == prerequisites.count && !prerequisites.contains(id)
            && uncertainties.count <= 6 && uncertainties.allSatisfy { courseText($0, 600) }
    }
    /// Source/exercise edits never relabel an earlier transcription as the new exercise.
    public var musicIdentity: String {
        ScoreRevision.digest(
            "\(source.bookID)|\(source.digest)|\(source.fromPage):\(source.throughPage)|\(kind)|\(instrument)|\(passage)"
        )
    }
    public var learningIdentity: String {
        ScoreRevision.digest(String(decoding: (try? JSONEncoder.sorted.encode(self)) ?? Data(), as: UTF8.self))
    }
}
public struct CourseChapter: Codable, Equatable, Sendable {
    public var revision = 1
    public var title: String
    public var source: CourseSourceAnchor
    public var summary: String
    public var origin: String
    public var lessons: [CourseLesson]
    public var caveats: [String]
    public var reviewedIdentity: String?
    public var reviewedAt: Date?
    public init(
        title: String, source: CourseSourceAnchor, summary: String, origin: String, lessons: [CourseLesson],
        caveats: [String] = []
    ) {
        self.title = title
        self.source = source
        self.summary = summary
        self.origin = origin
        self.lessons = lessons
        self.caveats = caveats
    }
    public var identity: String {
        var copy = self
        copy.reviewedIdentity = nil
        copy.reviewedAt = nil
        return ScoreRevision.digest(String(decoding: (try? JSONEncoder.sorted.encode(copy)) ?? Data(), as: UTF8.self))
    }
    public var reviewed: Bool { reviewedIdentity == identity && reviewedAt != nil }
    public mutating func review(now: Date = Date()) {
        reviewedIdentity = identity
        reviewedAt = now
    }
    public func validated(book: CourseBook) throws -> Self {
        guard (1...10000).contains(revision), source.belongs(to: book), courseText(title, 200),
            courseText(summary, 3000), courseText(origin, 300),
            (1...12).contains(lessons.count), Set(lessons.map(\.id)).count == lessons.count,
            lessons.allSatisfy({ $0.valid && $0.source.belongs(to: book) && source.contains($0.source) }),
            caveats.count <= 10, caveats.allSatisfy({ courseText($0, 1000) }),
            reviewedIdentity.map(ScoreRevision.valid) ?? true, reviewedAt?.timeIntervalSince1970.isFinite ?? true,
            (reviewedIdentity == nil) == (reviewedAt == nil), reviewedIdentity == nil || reviewed
        else {
            throw MusicError.invalid("Review the chapter's text, page links and exercise selections before saving.")
        }
        let ids = Set(lessons.map(\.id))
        guard lessons.allSatisfy({ Set($0.prerequisites).isSubset(of: ids) }) else {
            throw MusicError.invalid("A prerequisite refers to a lesson outside this chapter.")
        }
        let dependencies = Dictionary(uniqueKeysWithValues: lessons.map { ($0.id, $0.prerequisites) })
        var visited = Set<UUID>()
        var visiting = Set<UUID>()
        func visit(_ id: UUID) -> Bool {
            if visiting.contains(id) { return false }
            if visited.contains(id) { return true }
            visiting.insert(id)
            for dependency in dependencies[id] ?? [] { if !visit(dependency) { return false } }
            visiting.remove(id)
            visited.insert(id)
            return true
        }
        guard lessons.allSatisfy({ visit($0.id) }) else {
            throw MusicError.invalid("These prerequisites form a circle. Remove one dependency.")
        }
        return self
    }
}
public struct CourseScoreApproval: Codable, Equatable, Sendable {
    public var fingerprint: String
    public var from: Int
    public var through: Int
    public var staff: Int?
    public var date: Date
    public init(fingerprint: String, from: Int, through: Int, staff: Int?, date: Date = Date()) {
        self.fingerprint = fingerprint
        self.from = from
        self.through = through
        self.staff = staff
        self.date = date
    }
    public var valid: Bool {
        ScoreRevision.valid(fingerprint) && (0..<128).contains(from) && through >= from && through < 128
            && through - from < 16 && (staff.map { (1...2).contains($0) } ?? true)
            && date.timeIntervalSince1970.isFinite
    }
}
public struct CourseExerciseLink: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var lessonID: UUID
    public var musicIdentity: String
    public var scoreID: UUID
    public var approval: CourseScoreApproval?
    public init(lesson: CourseLesson, scoreID: UUID) {
        lessonID = lesson.id
        musicIdentity = lesson.musicIdentity
        self.scoreID = scoreID
    }
    public var valid: Bool { ScoreRevision.valid(musicIdentity) && (approval?.valid ?? true) }
}
public struct CourseDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var chapter: CourseChapter
    public var history: [CourseChapter] = []
    public var exercises: [CourseExerciseLink] = []
    public var outlineJob: CourseOutlineJob?
    public var createdAt = Date()
    public init(chapter: CourseChapter) { self.chapter = chapter }
    public func link(_ lesson: CourseLesson) -> CourseExerciseLink? {
        exercises.last { $0.lessonID == lesson.id && $0.musicIdentity == lesson.musicIdentity }
    }
    public mutating func revise(_ incoming: CourseChapter) {
        if incoming == chapter { return }
        history.append(chapter)
        history = Array(history.suffix(20))
        chapter = incoming
        chapter.revision = history.last!.revision + 1
        chapter.reviewedIdentity = nil
        chapter.reviewedAt = nil
    }
    public func validated(book: CourseBook) throws -> Self {
        _ = try chapter.validated(book: book)
        guard history.count <= 20, exercises.count <= 128, outlineJob?.valid ?? true,
            Set(exercises.map(\.id)).count == exercises.count, exercises.allSatisfy(\.valid),
            createdAt.timeIntervalSince1970.isFinite
        else { throw MusicError.invalid("This course has invalid exercise links or revisions.") }
        for old in history { _ = try old.validated(book: book) }
        let revisions = history.map(\.revision) + [chapter.revision]
        guard zip(revisions, revisions.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw MusicError.invalid("The chapter revision history is out of order.")
        }
        return self
    }
}
public struct CourseReflection: Codable, Equatable, Sendable {
    public var introduced = false
    public var note = ""
    public var date = Date()
    public init(introduced: Bool = false, note: String = "", date: Date = Date()) {
        self.introduced = introduced
        self.note = note
        self.date = date
    }
    public var valid: Bool { note.count <= 3000 && date.timeIntervalSince1970.isFinite }
}
/// Content/provenance and learner reflections are separate. Measured practice and
/// spacing remain in the existing PracticeState; there is no second course SRS.
public struct CourseLibrary: Codable, Equatable, Sendable {
    public var schemaVersion = 3
    public var books: [CourseBook] = []
    public var courses: [CourseDefinition] = []
    public var reflections: [String: CourseReflection] = [:]
    public var musicalPathways: [MusicalPathway]?
    public var songJourneys: [SongJourney]?
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, books, courses, reflections, musicalPathways, songJourneys
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard [1, 2, 3].contains(version) else {
            throw MusicError.invalid("This course library needs a newer Cadence.")
        }
        books = try c.decode([CourseBook].self, forKey: .books)
        courses = try c.decode([CourseDefinition].self, forKey: .courses)
        reflections = try c.decode([String: CourseReflection].self, forKey: .reflections)
        musicalPathways = try c.decodeIfPresent([MusicalPathway].self, forKey: .musicalPathways)
        songJourneys = try c.decodeIfPresent([SongJourney].self, forKey: .songJourneys)
        schemaVersion = 3
    }
    public func restored() throws -> Self {
        var copy = try validated()
        for i in copy.courses.indices where copy.courses[i].outlineJob?.status == .reading {
            copy.courses[i].outlineJob?.status = .stopped
            copy.courses[i].outlineJob?.error =
                "Interrupted request. No automatic retry was made; work already sent may have been charged."
        }
        return copy
    }
    public func validated() throws -> Self {
        guard schemaVersion == 3, books.count <= 50, courses.count <= 100, reflections.count <= 2000,
            Set(books.map(\.id)).count == books.count, Set(courses.map(\.id)).count == courses.count,
            books.allSatisfy(\.valid), reflections.allSatisfy({ ScoreRevision.valid($0.key) && $0.value.valid })
        else { throw MusicError.invalid("This course library is damaged or needs a newer Cadence.") }
        guard (musicalPathways?.count ?? 0) <= 100,
            Set((musicalPathways ?? []).map(\.id)).count == (musicalPathways?.count ?? 0)
        else { throw MusicError.invalid("The saved pathways are invalid.") }
        guard (songJourneys?.count ?? 0) <= 100,
            Set((songJourneys ?? []).map(\.id)).count == (songJourneys?.count ?? 0),
            (songJourneys ?? []).allSatisfy(\.valid)
        else { throw MusicError.invalid("The saved song journeys are invalid.") }
        for pathway in musicalPathways ?? [] { try pathway.validate(in: self) }
        for course in courses {
            guard let book = books.first(where: { $0.id == course.chapter.source.bookID }) else {
                throw MusicError.invalid("A chapter has lost its book reference.")
            }
            _ = try course.validated(book: book)
        }
        return self
    }
}
func courseText(_ text: String, _ limit: Int) -> Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= limit
}
extension JSONEncoder {
    fileprivate static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}
