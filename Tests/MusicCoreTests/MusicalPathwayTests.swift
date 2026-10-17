// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest

@testable import MusicCore

final class MusicalPathwayTests: XCTestCase {
    func fixture() throws -> (CourseLibrary, MusicalPathway) {
        let song = CourseBook(
            data: Data([1]), filename: "book.epub", pageCount: 3, title: "Songwriting",
            epubSections: (1...3).map { .init(href: "s\($0).xhtml", title: "Section \($0)") })
        let jazz = CourseBook(data: Data([2]), filename: "book.pdf", pageCount: 30, title: "Jazz")
        let draft = try SmoothChangesRecipe.make(songbook: song, jazzbook: jazz, inversions: 1, songwriting: 2)
        var library = CourseLibrary()
        library.books = [song, jazz]
        library.courses = draft.courses
        library.musicalPathways = [draft.pathway]
        return (try library.validated(), draft.pathway)
    }
    func evidence(step: MusicalPathway.Step, grade: ReviewGrade = .good, timing: Bool = false, now: Date)
        -> CourseEvidence
    {
        var review = ReviewSchedule()
        review.record(grade, episode: UUID(), input: .midi, now: now)
        return .init(
            lessonID: step.lessonID, practiceID: UUID().uuidString, mode: timing ? .timed : .guided, date: now,
            review: review, summary: "Scoped evidence", timingOnlyDifficulty: timing)
    }
    func testRouteLinksTwoBooksAndKeepsApprovalsSeparate() throws {
        let (library, route) = try fixture()
        XCTAssertEqual(route.steps.count, 5)
        XCTAssertEqual(library.courses.count, 3)
        XCTAssertEqual(Set(library.courses.map { $0.chapter.source.bookID }).count, 2)
        XCTAssertTrue(
            library.courses.allSatisfy { !$0.chapter.reviewed && $0.exercises.allSatisfy { $0.approval == nil } })
        XCTAssertEqual(try JSONDecoder().decode(CourseLibrary.self, from: JSONEncoder().encode(library)), library)
    }
    func testStudiesHaveCorrectVoicingsHarmonyBarsAndTransferKey() throws {
        for index in 0..<4 {
            let score = try SmoothChangesRecipe.score(index: index)
            XCTAssertEqual(score.barCount, 4)
            XCTAssertEqual(score.harmonies.count, 4)
            XCTAssertEqual(score.staffCount, 2)
            XCTAssertFalse(score.playback(from: 0, through: 3).notes.isEmpty)
            for harmony in score.harmonies {
                let tones = try ChordRealization(harmony.symbol).tones.map { $0.pitch.pc }
                let played = score.events.filter { $0.bar == harmony.bar }.flatMap(\.pitches).map { $0.midi % 12 }
                XCTAssertTrue(Set(played).isSubset(of: Set(tones)))
            }
        }
        let c = try SmoothChangesRecipe.score(index: 2)
        let f = try SmoothChangesRecipe.score(index: 3)
        XCTAssertNotEqual(LibraryPiece(source: .score(c)).fingerprint, LibraryPiece(source: .score(f)).fingerprint)
        XCTAssertEqual(f.fifths, -1)
        XCTAssertThrowsError(try SmoothChangesRecipe.score(index: 4))
        let composition = try SmoothChangesRecipe.composition()
        XCTAssertTrue(composition.events.allSatisfy { $0.pitches.isEmpty })
        XCTAssertEqual(composition.harmonies.count, 4)
    }
    func testInvalidSourceRangesAndWrongFormatsRejected() throws {
        let (library, _) = try fixture()
        let song = library.books[0]
        let jazz = library.books[1]
        for (a, b, c) in [(0, 2, 26), (1, 3, 26), (1, 2, 30)] {
            XCTAssertThrowsError(
                try SmoothChangesRecipe.make(songbook: song, jazzbook: jazz, inversions: a, songwriting: b, jazzPage: c)
            )
        }
        XCTAssertThrowsError(
            try SmoothChangesRecipe.make(songbook: jazz, jazzbook: song, inversions: 1, songwriting: 1))
    }
    func testNewSessionKeepsCreationAndRespectsSelectedTimeAndFocus() throws {
        let (_, original) = try fixture()
        for time in [10, 15, 25] {
            var route = original
            route.minutes = time
            let items = MusicalSessionPlanner.session(pathway: route, observations: [])
            XCTAssertEqual(items.count, 2)
            XCTAssertEqual(items.map(\.minutes).reduce(0, +), time)
            XCTAssertTrue(items.allSatisfy { $0.minutes > 0 })
            XCTAssertEqual(items.first?.label, "Read, listen & review")
            XCTAssertEqual(items.last?.stepID, route.steps.last?.id)
            let balanced = items.last!.minutes
            route.focus = .writing
            XCTAssertGreaterThan(
                MusicalSessionPlanner.session(pathway: route, observations: []).last!.minutes, balanced)
        }
    }
    func testDueTimingEvidenceSuggestsFocusedRepairAndRetainsCanonicalReview() throws {
        let (_, route) = try fixture()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let item = evidence(step: route.steps[1], grade: .again, timing: true, now: now.addingTimeInterval(-700))
        let observation = PathwayObservation(
            stepID: route.steps[1].id, ready: true, introduced: false, evidence: [item])
        let session = MusicalSessionPlanner.session(pathway: route, observations: [observation], now: now)
        XCTAssertEqual(session.first?.stepID, route.steps[1].id)
        XCTAssertEqual(session.first?.label, "Steady the transition")
        XCTAssertEqual(session.first?.evidenceID, item.practiceID)
        XCTAssertEqual(session.count, 3)
        XCTAssertEqual(item.review.intervalDays, 0)
        XCTAssertEqual(item.review.encounters, 1)
    }
    func testChangedOrUnreviewedMusicCannotSupplyReviewEvidence() throws {
        let (_, route) = try fixture()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let item = evidence(step: route.steps[2], now: now.addingTimeInterval(-100000))
        let session = MusicalSessionPlanner.session(
            pathway: route,
            observations: [.init(stepID: route.steps[2].id, ready: false, introduced: false, evidence: [item])],
            now: now)
        XCTAssertFalse(session.contains { $0.evidenceID != nil })
        XCTAssertEqual(session.first?.stepID, route.steps[0].id)
    }
    func testFamiliarSuccessDoesNotMarkTransferOrCompositionDone() throws {
        let (_, route) = try fixture()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let observations = route.steps.prefix(3).map {
            PathwayObservation(stepID: $0.id, ready: true, introduced: true, evidence: [evidence(step: $0, now: now)])
        }
        let session = MusicalSessionPlanner.session(
            pathway: route,
            observations: observations + [
                .init(stepID: route.steps[3].id, ready: true, introduced: false, evidence: [])
            ], now: now)
        XCTAssertEqual(session.first?.stepID, route.steps[3].id)
        XCTAssertEqual(session.first?.label, "Change the setting")
        XCTAssertEqual(session.last?.stepID, route.steps[4].id)
    }
    func testDanglingLinksDuplicatesAndInvalidSettingsRejected() throws {
        let (base, _) = try fixture()
        var copy = base
        copy.courses.removeFirst()
        XCTAssertThrowsError(try copy.validated())
        copy = base
        copy.musicalPathways![0].steps[0].lessonID = UUID()
        XCTAssertThrowsError(try copy.validated())
        copy = base
        copy.musicalPathways![0].minutes = -5
        XCTAssertThrowsError(try copy.validated())
        copy = base
        copy.musicalPathways! += copy.musicalPathways!
        XCTAssertThrowsError(try copy.validated())
        copy = base
        copy.musicalPathways![0].compositionReviewedFingerprint = "invalid"
        XCTAssertThrowsError(try copy.validated())
    }
    func testLegacyCourseLibraryDecodesWithoutPathwaysOrEPUBFields() throws {
        let bytes = Data(#"{"schemaVersion":1,"books":[],"courses":[],"reflections":{}}"#.utf8)
        let decoded = try JSONDecoder().decode(CourseLibrary.self, from: bytes).validated()
        XCTAssertNil(decoded.musicalPathways)
        XCTAssertTrue(decoded.books.isEmpty)
        XCTAssertEqual(decoded.schemaVersion, 2)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        XCTAssertEqual(saved["schemaVersion"] as? Int, 2)
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                CourseLibrary.self, from: Data(#"{"schemaVersion":3,"books":[],"courses":[],"reflections":{}}"#.utf8)))
    }
    func testChangedIntroducedStudyReturnsForReviewAndForeignEvidenceCannotAdvanceIt() throws {
        let (_, route) = try fixture()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let previous = evidence(step: route.steps[0], now: now)
        let changed = PathwayObservation(
            stepID: route.steps[0].id, ready: false, introduced: true, evidence: [previous])
        let review = MusicalSessionPlanner.session(pathway: route, observations: [changed], now: now)
        XCTAssertEqual(review.first?.stepID, route.steps[0].id)
        XCTAssertEqual(review.first?.label, "Read, listen & review")
        let foreign = PathwayObservation(
            stepID: route.steps[0].id, ready: true, introduced: false,
            evidence: [evidence(step: route.steps[1], now: now)])
        let session = MusicalSessionPlanner.session(pathway: route, observations: [foreign], now: now)
        XCTAssertEqual(session.first?.stepID, route.steps[0].id)
        XCTAssertNil(session.first?.evidenceID)
    }
}
