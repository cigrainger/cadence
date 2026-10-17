// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class CourseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func fixture() -> (CourseBook, CourseChapter) {
        let book = CourseBook(
            data: Data("%PDF-book".utf8), filename: "Method.pdf", pageCount: 100, title: "A method",
            author: "A teacher", edition: "Second")
        let source = CourseSourceAnchor(book: book, from: 20, through: 23, printedLabel: "Chapter 3")
        let intro = CourseLesson(
            title: "Pulse", source: .init(book: book, from: 20, through: 20), kind: .explanation,
            bookSummary: "Count four beats.", goal: "Keep a pulse", practice: "Tap four beats",
            readyWhen: "Keep counting in silence", skills: [.pulse])
        let music = CourseLesson(
            title: "Melody", source: .init(book: book, from: 21, through: 22), bookSummary: "A short melody",
            goal: "Read a phrase", practice: "Listen and play", readyWhen: "Find the notes",
            passage: "Exercise 4, both systems", skills: [.reading, .pulse], prerequisites: [intro.id])
        return (
            book,
            CourseChapter(
                title: "First phrases", source: source, summary: "A small chapter", origin: "Your outline",
                lessons: [intro, music])
        )
    }
    private func outline() -> CourseOutline {
        CourseOutline(
            title: "First phrases", summary: "Read, listen and play",
            lessons: [
                .init(
                    title: "Pulse", fromPage: 20, throughPage: 20, kind: .explanation, bookSummary: "Four beats",
                    goal: "Count evenly", practice: "Tap and count", readyWhen: "Keep counting", passage: "",
                    skills: [.pulse], prerequisites: [], uncertainties: []),
                .init(
                    title: "Exercise 4", fromPage: 21, throughPage: 22, kind: .music, bookSummary: "A melody",
                    goal: "Read the phrase", practice: "Listen, then play", readyWhen: "Find each note",
                    passage: "Exercise 4, both systems", skills: [.reading], prerequisites: [1],
                    uncertainties: ["Check the exercise boundary"]),
            ], caveats: ["Review before using as a course"])
    }
    func testChapterRoundTripKeepsBookProvenanceAndSeparateReview() throws {
        var (book, chapter) = fixture()
        _ = try chapter.validated(book: book)
        XCTAssertFalse(chapter.reviewed)
        chapter.review(now: now)
        XCTAssertTrue(chapter.reviewed)
        var library = CourseLibrary()
        library.books = [book]
        library.courses = [CourseDefinition(chapter: chapter)]
        library.reflections[chapter.lessons[0].learningIdentity] = .init(
            introduced: true, note: "I can count through silence", date: now)
        XCTAssertEqual(
            try JSONDecoder().decode(CourseLibrary.self, from: JSONEncoder().encode(library)).validated(), library)
        XCTAssertEqual(chapter.source.pages, [20, 21, 22, 23])
        XCTAssertEqual(chapter.source.label, "PDF pages 20–23 · Chapter 3")
        XCTAssertTrue(library.courses[0].exercises.isEmpty)
    }
    func testPageBoundsAndAnotherEditionCannotMasqueradeAsTheSource() throws {
        let (book, chapter) = fixture()
        for (from, to) in [(0, 1), (2, 1), (1, 9), (1000, 1001)] {
            let anchor = CourseSourceAnchor(book: book, from: from, through: to)
            XCTAssertFalse(anchor.valid)
            XCTAssertTrue(anchor.pages.isEmpty)
        }
        var other = book
        other.digest = CourseBook.digest(Data("new edition".utf8))
        XCTAssertFalse(chapter.source.belongs(to: other))
        XCTAssertThrowsError(try chapter.validated(book: other))
        var changed = chapter
        changed.lessons[0].source.fromPage = 19
        XCTAssertThrowsError(try changed.validated(book: book))
        changed = chapter
        changed.lessons[1].source.throughPage = 25
        XCTAssertThrowsError(try changed.validated(book: book))
        var short = book
        short.pageCount = 21
        XCTAssertFalse(chapter.source.belongs(to: short))
        XCTAssertEqual(CourseSourceAnchor(book: book, from: 1, through: 1).label, "PDF page 1")
    }
    func testPrerequisiteCyclesSelfReferencesDuplicatesAndMissingTargetsRejected() throws {
        let (book, chapter) = fixture()
        var c = chapter
        c.lessons[0].prerequisites = [c.lessons[1].id]
        XCTAssertThrowsError(try c.validated(book: book))
        c = chapter
        c.lessons[1].prerequisites = [c.lessons[1].id]
        XCTAssertThrowsError(try c.validated(book: book))
        c = chapter
        c.lessons[1].prerequisites = [UUID()]
        XCTAssertThrowsError(try c.validated(book: book))
        c = chapter
        c.lessons[1].prerequisites += c.lessons[1].prerequisites
        XCTAssertThrowsError(try c.validated(book: book))
        c = chapter
        c.lessons.append(c.lessons[0])
        XCTAssertThrowsError(try c.validated(book: book))
        c = chapter
        c.lessons[1].skills = []
        XCTAssertThrowsError(try c.validated(book: book))
    }
    func testRevisionInvalidatesApprovalButKeepsPriorOutlineAndMatchingMusicLink() throws {
        var (book, chapter) = fixture()
        chapter.review(now: now)
        var course = CourseDefinition(chapter: chapter)
        var link = CourseExerciseLink(lesson: chapter.lessons[1], scoreID: UUID())
        link.approval = .init(fingerprint: ScoreRevision.digest("notes"), from: 0, through: 3, staff: 1, date: now)
        course.exercises = [link]
        course.revise(chapter)
        XCTAssertTrue(course.history.isEmpty)
        let identity = chapter.lessons[1].learningIdentity
        chapter.lessons[1].goal = "Read with a quiet pulse"
        course.revise(chapter)
        XCTAssertFalse(course.chapter.reviewed)
        XCTAssertTrue(course.history[0].reviewed)
        XCTAssertEqual(course.chapter.revision, 2)
        XCTAssertEqual(course.link(course.chapter.lessons[1]), link)
        XCTAssertNotEqual(course.chapter.lessons[1].learningIdentity, identity)
        var changed = course.chapter
        changed.lessons[1].passage = "Exercise 5"
        course.revise(changed)
        XCTAssertNil(course.link(course.chapter.lessons[1]))
        XCTAssertEqual(course.exercises, [link])
        for i in 0..<25 {
            var revision = course.chapter
            revision.summary = "Revision \(i)"
            course.revise(revision)
        }
        XCTAssertEqual(course.history.count, 20)
        _ = try course.validated(book: book)
        course.history.reverse()
        XCTAssertThrowsError(try course.validated(book: book))
    }
    func testInvalidApprovalsCorruptionAndFutureCourseFormatAreRejected() throws {
        let (book, chapter) = fixture()
        var library = CourseLibrary()
        library.books = [book]
        library.courses = [.init(chapter: chapter)]
        var bad = library
        bad.schemaVersion = 3
        XCTAssertThrowsError(try bad.validated())
        bad = library
        bad.books.append(book)
        XCTAssertThrowsError(try bad.validated())
        bad = library
        bad.books = []
        XCTAssertThrowsError(try bad.validated())
        bad = library
        bad.reflections["invalid"] = CourseReflection()
        XCTAssertThrowsError(try bad.validated())
        bad = library
        bad.courses[0].chapter.reviewedIdentity = ScoreRevision.digest("not reviewed")
        bad.courses[0].chapter.reviewedAt = now
        XCTAssertThrowsError(try bad.validated())
        for approval in [
            CourseScoreApproval(fingerprint: "fake", from: 0, through: 3, staff: 1),
            .init(fingerprint: ScoreRevision.digest("a"), from: 0, through: 16, staff: nil),
            .init(fingerprint: ScoreRevision.digest("a"), from: 0, through: 3, staff: 3),
            .init(fingerprint: ScoreRevision.digest("a"), from: 3, through: 2, staff: nil),
        ] { XCTAssertFalse(approval.valid) }
        var reflection = CourseReflection()
        reflection.note = String(repeating: "x", count: 3001)
        XCTAssertFalse(reflection.valid)
    }
    func testInterruptedOutlineRestoresStoppedWithoutChangingCourseOrCost() throws {
        let (book, chapter) = fixture()
        var library = CourseLibrary()
        library.books = [book]
        library.courses = [.init(chapter: chapter)]
        var job = CourseOutlineJob(model: PDFImportModel.sol.rawValue)
        job.costUSD = 0.04
        library.courses[0].outlineJob = job
        let restored = try library.restored()
        XCTAssertEqual(restored.courses[0].chapter, chapter)
        XCTAssertEqual(restored.courses[0].outlineJob?.status, .stopped)
        XCTAssertEqual(restored.courses[0].outlineJob?.costUSD, 0.04)
        XCTAssertEqual(restored.courses[0].outlineJob?.unpricedAttempts, 1)
        XCTAssertTrue(restored.courses[0].outlineJob?.error?.contains("No automatic retry") == true)
        let next = CourseOutlineJob(model: "other", previous: job)
        XCTAssertEqual(next.attempts, 2)
        XCTAssertEqual(next.unpricedAttempts, 2)
        var bad = next
        bad.costUSD = -.infinity
        XCTAssertFalse(bad.valid)
    }
    func testOutlineCannotSetApprovalAndMustStayInsideSelectedChapter() throws {
        let (book, chapter) = fixture()
        let proposal = outline()
        let result = try proposal.chapter(source: chapter.source, book: book, instrument: .piano, origin: "AI proposal")
        XCTAssertFalse(result.reviewed)
        XCTAssertEqual(result.lessons[1].prerequisites, [result.lessons[0].id])
        XCTAssertEqual(result.lessons[1].instrument, .piano)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(proposal)) as? [String: Any])
        json["reviewed"] = true
        json["mastery"] = 1
        let decoded = try CourseOutline.decode(
            String(decoding: JSONSerialization.data(withJSONObject: json), as: UTF8.self))
        XCTAssertFalse(
            try decoded.chapter(source: chapter.source, book: book, instrument: .piano, origin: "proposal").reviewed)
        var bad = proposal
        bad.lessons[1].fromPage = 1
        XCTAssertThrowsError(try bad.chapter(source: chapter.source, book: book, instrument: .piano, origin: "AI"))
        bad = proposal
        bad.lessons[1].prerequisites = [9]
        XCTAssertThrowsError(try bad.chapter(source: chapter.source, book: book, instrument: .piano, origin: "AI"))
        bad = proposal
        bad.lessons[0].prerequisites = [2]
        XCTAssertThrowsError(try bad.chapter(source: chapter.source, book: book, instrument: .piano, origin: "AI"))
        bad = proposal
        bad.lessons = []
        XCTAssertThrowsError(try bad.chapter(source: chapter.source, book: book, instrument: .piano, origin: "AI"))
        XCTAssertThrowsError(try CourseOutline.decode("no outline"))
        XCTAssertThrowsError(try CourseOutline.decode(String(repeating: "x", count: 100001)))
    }
    func testPlannerCombinesDueReviewNewLessonAndApplicationWithoutInventingMastery() throws {
        var (_, chapter) = fixture()
        chapter.review(now: now)
        let a = chapter.lessons[0].id
        let b = chapter.lessons[1].id
        var review = ReviewSchedule()
        review.record(.again, episode: UUID(), input: .midi, now: now.addingTimeInterval(-700))
        let evidence = CourseEvidence(
            lessonID: b, practiceID: "timed:1", mode: .timed, date: now.addingTimeInterval(-700), review: review,
            summary: "Pitch matched", timingOnlyDifficulty: true)
        let result = CourseSessionPlanner.suggestions(
            chapter: chapter, ready: [b], introduced: [], evidence: [evidence], now: now)
        XCTAssertEqual(result.map(\.kind), [.review, .new])
        XCTAssertEqual(result[0].lessonID, b)
        XCTAssertTrue(result[0].reason.contains("entrances"))
        XCTAssertEqual(result[1].lessonID, a)
        XCTAssertEqual(review.encounters, 1)
        let stale = CourseSessionPlanner.suggestions(
            chapter: chapter, ready: [], introduced: [a], evidence: [evidence], now: now)
        XCTAssertEqual(stale.map(\.kind), [.new])
        XCTAssertEqual(stale[0].lessonID, b)
        var good = review
        good.record(.good, episode: UUID(), input: .midi, now: now)
        var played = evidence
        played.review = good
        let apply = CourseSessionPlanner.suggestions(
            chapter: chapter, ready: [b], introduced: [a], evidence: [played], now: now)
        XCTAssertEqual(apply.map(\.kind), [.apply])
        XCTAssertTrue(apply[0].reason.contains("variation"))
    }
    func testUnreviewedChapterHasNoPlanAndPrerequisitesRemainRecommendations() {
        var (_, chapter) = fixture()
        XCTAssertTrue(
            CourseSessionPlanner.suggestions(chapter: chapter, ready: [], introduced: [], evidence: []).isEmpty)
        chapter.lessons.reverse()
        chapter.review(now: now)
        let plan = CourseSessionPlanner.suggestions(chapter: chapter, ready: [], introduced: [], evidence: [], now: now)
        XCTAssertEqual(plan[0].lessonID, chapter.lessons[1].id)
        chapter.lessons.removeLast()
        chapter.review(now: now)
        let fallback = CourseSessionPlanner.suggestions(
            chapter: chapter, ready: [], introduced: [], evidence: [], now: now)
        XCTAssertTrue(fallback[0].reason.contains("open this now"))
    }
    func testOutlineRequestUsesBoundedExcerptHighReasoningZDRAndUntrustedSourcePrompt() async throws {
        let (book, chapter) = fixture()
        let proposal = outline()
        let pdf = Data("%PDF-selected-chapter".utf8)
        for model in PDFImportModel.allCases {
            let client = CourseOutlineClient { request in
                let body = try XCTUnwrap(request.httpBody)
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("fixture-secret"))
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret")
                XCTAssertEqual(json["model"] as? String, model.rawValue)
                XCTAssertEqual(json["max_tokens"] as? Int, 12000)
                let provider = try XCTUnwrap(json["provider"] as? [String: Any])
                XCTAssertEqual(provider["zdr"] as? Bool, true)
                XCTAssertEqual(provider["allow_fallbacks"] as? Bool, false)
                XCTAssertEqual(provider["data_collection"] as? String, "deny")
                if model != .astra {
                    XCTAssertEqual((json["reasoning"] as? [String: Any])?["effort"] as? String, "high")
                }
                XCTAssertEqual(
                    (json["response_format"] as? [String: Any])?["type"] as? String,
                    model.usesStrictSchema ? "json_schema" : "json_object")
                let content = try XCTUnwrap(
                    (json["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
                let prompt = content[0]["text"] as? String ?? ""
                XCTAssertTrue(prompt.contains("20...23"))
                XCTAssertTrue(prompt.contains("untrusted source data"))
                XCTAssertTrue(prompt.contains("no review status"))
                XCTAssertEqual(
                    (content[1]["file"] as? [String: Any])?["file_data"] as? String,
                    "data:application/pdf;base64," + pdf.base64EncodedString())
                return try self.response(request, outline: proposal, cost: 0.02)
            }
            let reply = try await client.outline(
                pdf: pdf, source: chapter.source, book: book, instrument: .piano, model: model, apiKey: "fixture-secret"
            )
            XCTAssertEqual(reply.outline, proposal)
            XCTAssertEqual(reply.costUSD, 0.02)
        }
    }
    func testOutlineInvalidInputNeverSendsAndBadOutputDoesNotRetry() async throws {
        let (book, chapter) = fixture()
        var calls = 0
        let client = CourseOutlineClient { request in
            calls += 1
            var bad = self.outline()
            bad.lessons[1].throughPage = 40
            return try self.response(request, outline: bad, cost: 0.03)
        }
        for (data, key) in [
            (Data("%PDF-ok".utf8), ""), (Data("not a pdf".utf8), "key"),
            (Data("%PDF-".utf8) + Data(repeating: 0, count: 12_000_001), "key"),
        ] {
            do {
                _ = try await client.outline(
                    pdf: data, source: chapter.source, book: book, instrument: .piano, apiKey: key)
                XCTFail()
            } catch {}
        }
        XCTAssertEqual(calls, 0)
        do {
            _ = try await client.outline(
                pdf: Data("%PDF-ok".utf8), source: chapter.source, book: book, instrument: .piano, apiKey: "key")
            XCTFail()
        } catch { XCTAssertTrue(error.localizedDescription.contains("US$0.0300")) }
        XCTAssertEqual(calls, 1)
    }
    func testOutlineFailureRedactsKeyAndTimeoutIsBounded() async throws {
        let (book, chapter) = fixture()
        var calls = 0
        let client = CourseOutlineClient { request in
            calls += 1
            return (
                Data(#"{"error":{"message":"Rejected fixture-secret"}}"#.utf8),
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            )
        }
        do {
            _ = try await client.outline(
                pdf: Data("%PDF-ok".utf8), source: chapter.source, book: book, instrument: .guitar,
                apiKey: "fixture-secret")
            XCTFail()
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("fixture-secret"))
            XCTAssertTrue(error.localizedDescription.contains("redacted"))
        }
        XCTAssertEqual(calls, 1)
        let slow = CourseOutlineClient(deadline: 0.01) { _ in
            try await Task.sleep(nanoseconds: 1_000_000_000)
            throw CancellationError()
        }
        do {
            _ = try await slow.outline(
                pdf: Data("%PDF-ok".utf8), source: chapter.source, book: book, instrument: .guitar, apiKey: "fixture")
            XCTFail()
        } catch { XCTAssertTrue(error.localizedDescription.contains("not retried")) }
    }
    private func response(_ request: URLRequest, outline: CourseOutline, cost: Double) throws -> (Data, HTTPURLResponse)
    {
        let text = String(decoding: try JSONEncoder().encode(outline), as: UTF8.self)
        return (
            try JSONSerialization.data(withJSONObject: [
                "model": "resolved/model", "usage": ["cost": cost],
                "choices": [["finish_reason": "stop", "message": ["content": text]]],
            ]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
    }
}
