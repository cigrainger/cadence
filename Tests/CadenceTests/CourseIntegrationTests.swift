// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import PDFKit
import XCTest

@testable import Cadence

final class CourseIntegrationTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    @MainActor private func fixture(approved: Bool = false) throws -> (AppState, UUID, CourseLesson) {
        let state = AppState(storageOverride: try folder())
        let id = try CourseExamples.install(state: state)
        let lesson = try state.course(id).chapter.lessons[1]
        if approved {
            try state.reviewChapter(id)
            let scoreID = try XCTUnwrap(state.course(id).link(lesson)?.scoreID)
            try state.changePDFScore(scoreID) { $0.pdfSource?.reviewed = true }
            try state.approveCourseScore(courseID: id, lessonID: lesson.id, from: 0, through: 3, staff: 1)
        }
        addTeardownBlock { await MainActor.run { state.midi.shutdown() } }
        return (state, id, lesson)
    }
    @MainActor private func proposal(_ state: AppState, _ id: UUID) throws -> CourseOutlineReply {
        let chapter = try state.course(id).chapter
        let items: [[String: Any]] = chapter.lessons.map { lesson in
            [
                "title": lesson.title, "fromPage": lesson.source.fromPage, "throughPage": lesson.source.throughPage,
                "kind": lesson.kind.rawValue, "bookSummary": lesson.bookSummary, "goal": lesson.goal,
                "practice": lesson.practice, "readyWhen": lesson.readyWhen, "passage": lesson.passage,
                "skills": lesson.skills.map(\.rawValue),
                "prerequisites": lesson.prerequisites.compactMap { target in
                    chapter.lessons.firstIndex { $0.id == target }.map { $0 + 1 }
                }, "uncertainties": lesson.uncertainties,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "title": "Reviewed proposal", "summary": chapter.summary, "lessons": items, "caveats": [],
        ])
        return CourseOutlineReply(
            outline: try CourseOutline.decode(String(decoding: data, as: UTF8.self)), model: "fixture/model",
            costUSD: 0.02)
    }
    @MainActor private func wait(_ request: SavedRequest<CourseOutlineReply>) async throws {
        let end = Date().addingTimeInterval(5)
        while request.busy && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(request.busy)
    }
    @MainActor func testOriginalChapterPersistsOnceAndBeginsWithTwoSeparateReviews() throws {
        let (state, id, lesson) = try fixture()
        let course = try state.course(id)
        let book = try state.courseBook(course)
        XCTAssertFalse(course.chapter.reviewed)
        XCTAssertEqual(course.chapter.lessons.count, 3)
        XCTAssertEqual(try Data(contentsOf: state.courseBookURL(book)), try CourseExamples.asset().data)
        let scores = state.editor.documents.filter { $0.pdfSource?.fileID == book.fileID }
        XCTAssertEqual(scores.count, 2)
        XCTAssertEqual(scores.map { $0.pdfSource!.page }, [2, 3])
        XCTAssertThrowsError(try state.openCoursePractice(courseID: id, lessonID: lesson.id, mode: .guided))
        try state.reviewChapter(id)
        XCTAssertThrowsError(
            try state.approveCourseScore(courseID: id, lessonID: lesson.id, from: 0, through: 3, staff: 1))
        let count = state.editor.documents.count
        XCTAssertEqual(try CourseExamples.install(state: state), id)
        XCTAssertEqual(state.editor.documents.count, count)
        let restored = AppState(storageOverride: state.storage)
        defer { restored.midi.shutdown() }
        XCTAssertTrue(try restored.course(id).chapter.reviewed)
        XCTAssertThrowsError(try restored.readyCourseScore(restored.course(id), lesson))
    }
    @MainActor func testChapterExcerptContainsOnlySelectedPagesAndLeavesOriginalIntact() throws {
        let asset = try CourseExamples.asset()
        let original = asset.data
        let excerpt = try XCTUnwrap(PDFDocument(data: asset.excerptPDF([2, 3])))
        XCTAssertEqual(excerpt.pageCount, 2)
        XCTAssertTrue(excerpt.page(at: 0)?.string?.contains("Small steps, steady pulse") == true)
        XCTAssertTrue(excerpt.page(at: 1)?.string?.contains("Make room for the spaces") == true)
        XCTAssertFalse(excerpt.page(at: 0)?.string?.contains("Find a comfortable pulse") == true)
        XCTAssertEqual(asset.data, original)
        XCTAssertEqual(asset.document.pageCount, 3)
        for pages in [[], [0], [4], [2, 1], [1, 1]] { XCTAssertThrowsError(try asset.excerptPDF(pages)) }
        XCTAssertThrowsError(try asset.excerptPDF([1, 2], maximumPages: 1))
        XCTAssertThrowsError(try asset.excerptPDF([1], maximumBytes: 10))
    }
    @MainActor func testCourseSaveFailureDoesNotPublishApprovalOrEraseIndependentPractice() throws {
        let (state, id, lesson) = try fixture(approved: true)
        let old = state.courses
        let url = state.stores.courses.url
        let bytes = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(
            try state.reflectOnLesson(courseID: id, lessonID: lesson.id, introduced: true, note: "Unsaved"))
        XCTAssertEqual(state.courses, old)
        var practice = state.practiceState
        practice.learning.profile.background = "A new musical goal"
        try state.commitPractice(practice)
        XCTAssertEqual(state.practiceState, practice)
        try FileManager.default.removeItem(at: url)
        try bytes.write(to: url)
        try state.reflectOnLesson(courseID: id, lessonID: lesson.id, introduced: true, note: "Saved")
        let restored = AppState(storageOverride: state.storage)
        defer { restored.midi.shutdown() }
        XCTAssertEqual(restored.courses.reflections[lesson.learningIdentity]?.note, "Saved")
        XCTAssertEqual(restored.learning.profile.background, "A new musical goal")
    }
    @MainActor func testOutlineSaveRetryKeepsReplyWithoutAnotherRequest() async throws {
        let (state, id, _) = try fixture()
        let reply = try proposal(state, id)
        let url = state.stores.courses.url
        var calls = 0
        var saved: Data?
        try state.startCourseOutline(id, asset: CourseExamples.asset(), instrument: .piano, model: .sol) { excerpt in
            calls += 1
            XCTAssertEqual(PDFDocument(data: excerpt)?.pageCount, 3)
            saved = try Data(contentsOf: url)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return reply
        }
        try await wait(state.courseOutline)
        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(state.courseOutline.pending)
        XCTAssertEqual(try state.course(id).outlineJob?.status, .reading)
        state.stopCourseOutline(id)
        XCTAssertEqual(try state.course(id).outlineJob?.status, .reading)
        try FileManager.default.removeItem(at: url)
        try XCTUnwrap(saved).write(to: url)
        state.courseOutline.retrySave()
        XCTAssertNil(state.courseOutline.pending)
        XCTAssertEqual(calls, 1)
        let course = try state.course(id)
        XCTAssertEqual(course.outlineJob?.status, .ready)
        XCTAssertEqual(course.outlineJob?.costUSD, 0.02)
        XCTAssertEqual(course.outlineJob?.unpricedAttempts, 0)
        XCTAssertFalse(course.chapter.reviewed)
        XCTAssertEqual(course.chapter.title, "Reviewed proposal")
    }
    @MainActor func testStoppedOutlineNeverAppliesLateReplyAndRestartsNeverSend() async throws {
        let (state, id, lesson) = try fixture()
        let reply = try proposal(state, id)
        let original = try state.course(id).chapter
        try state.startCourseOutline(id, asset: CourseExamples.asset(), instrument: .piano, model: .sol) { _ in
            try? await Task.sleep(nanoseconds: 80_000_000)
            return reply
        }
        XCTAssertThrowsError(try state.saveCourseLesson(courseID: id, lesson: lesson))
        XCTAssertThrowsError(try state.removeCourseLesson(courseID: id, lessonID: lesson.id))
        XCTAssertThrowsError(try state.reviewChapter(id))
        let restarted = AppState(storageOverride: state.storage)
        defer { restarted.midi.shutdown() }
        XCTAssertEqual(try restarted.course(id).outlineJob?.status, .stopped)
        state.stopCourseOutline(id)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(try state.course(id).chapter, original)
        XCTAssertEqual(try state.course(id).outlineJob?.status, .stopped)
        XCTAssertNil(state.courseOutline.pending)
    }
    @MainActor func testPreparationReusesSavedIntentAndOnlyExercisePagesWithOneBookFile() throws {
        let (state, id, varLesson) = try fixture()
        var lesson = varLesson
        lesson.passage = "A different selection on page 2"
        try state.saveCourseLesson(courseID: id, lesson: lesson)
        try state.reviewChapter(id)
        let scoreID = try state.prepareCourseExercise(
            courseID: id, lessonID: lesson.id, asset: CourseExamples.asset(), model: .sol)
        let again = try state.prepareCourseExercise(
            courseID: id, lessonID: lesson.id, asset: CourseExamples.asset(), model: .sol)
        XCTAssertEqual(scoreID, again)
        XCTAssertTrue(state.showPDFImport)
        let score = try XCTUnwrap(state.editor.documents.first { $0.id == scoreID })
        XCTAssertEqual(score.pdfSource?.pages?.map(\.page), [2])
        XCTAssertEqual(score.pdfSource?.pages?.first?.passage, lesson.passage)
        XCTAssertEqual(score.pdfSource?.pages?.first?.attempts, 0)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: state.storage.appendingPathComponent("PDF Sources"), includingPropertiesForKeys: nil
            ).count, 1)
        let book = try state.courseBook(state.course(id))
        try Data("changed".utf8).write(to: state.courseBookURL(book))
        var next = lesson
        next.passage = "another"
        try state.saveCourseLesson(courseID: id, lesson: next)
        try state.reviewChapter(id)
        XCTAssertThrowsError(
            try state.prepareCourseExercise(
                courseID: id, lessonID: lesson.id, asset: CourseExamples.asset(), model: .sol))
    }
    @MainActor func testCurrentScoreApprovalAndGuidedEvidenceAreScopedAndRevisionSafe() throws {
        let (state, id, lesson) = try fixture(approved: true)
        try state.openCoursePractice(courseID: id, lessonID: lesson.id, mode: .guided)
        let study = try XCTUnwrap(state.studies.active)
        let plan = try state.guidedPassage(study)
        XCTAssertEqual(study.staff, 1)
        XCTAssertEqual(state.guidedStudyID, study.id)
        var follower = GuidedFollower(plan: plan)
        var keys = MIDIKeyboardState()
        for step in plan.steps {
            for note in step.notes {
                let message = MIDIMessage.noteOn(channel: 0, note: note, velocity: 90)
                keys.receive(message)
                _ = follower.receive(message, keyboard: keys)
            }
            for note in step.notes {
                let message = MIDIMessage.noteOff(channel: 0, note: note)
                keys.receive(message)
                _ = follower.receive(message, keyboard: keys)
            }
        }
        try state.saveGuidedResult(follower.result(id: UUID()))
        XCTAssertEqual(state.courseEvidence(try state.course(id), lesson).map(\.mode), [.guided])
        XCTAssertEqual(state.courseReturn, .init(courseID: id, lessonID: lesson.id))
        let scoreID = try XCTUnwrap(state.course(id).link(lesson)?.scoreID)
        try state.changePDFScore(scoreID) { $0.title = "A new title" }
        XCTAssertEqual(state.courseEvidence(try state.course(id), lesson).count, 1)
        try state.approveCourseScore(courseID: id, lessonID: lesson.id, from: 1, through: 2, staff: 1)
        XCTAssertTrue(state.courseEvidence(try state.course(id), lesson).isEmpty)
        try state.approveCourseScore(courseID: id, lessonID: lesson.id, from: 0, through: 3, staff: 1)
        try state.changePDFScore(scoreID) { try $0.setPitch($0.events[0].id, midi: 61) }
        XCTAssertThrowsError(try state.readyCourseScore(state.course(id), lesson))
        XCTAssertTrue(state.courseEvidence(try state.course(id), lesson).isEmpty)
        XCTAssertEqual(state.history.guidedPassages?.count, 1)
    }
    @MainActor func testTimedDifficultyReturnsAndRecallReusesExistingSpacing() throws {
        let (state, id, lesson) = try fixture(approved: true)
        try state.openCoursePractice(courseID: id, lessonID: lesson.id, mode: .timed)
        let study = try XCTUnwrap(state.studies.active)
        let plan = try state.timedPlan(study, tempo: 60)
        let attacks = plan.targets.map { TimedAttack(seconds: $0.beat * plan.secondsPerBeat + 0.3, pitch: $0.pitch) }
        let result = TimedPracticeResult(
            date: Date().addingTimeInterval(-700), plan: plan, conditions: TimedConditions(click: false),
            attacks: attacks)
        try state.saveTimedResult(result)
        let evidence = try XCTUnwrap(state.courseEvidence(state.course(id), lesson).first)
        XCTAssertTrue(evidence.timingOnlyDifficulty)
        XCTAssertEqual(evidence.mode, .timed)
        XCTAssertEqual(state.courseSuggestions(try state.course(id)).first?.evidenceID, result.practiceID)
        try state.openCoursePractice(courseID: id, lessonID: lesson.id, mode: .timed, evidenceID: result.practiceID)
        XCTAssertEqual(state.rhythmReview?.practiceID, result.practiceID)
        try state.openCoursePractice(courseID: id, lessonID: lesson.id, mode: .recall)
        let count = state.learning.pathways.count
        try state.openCoursePractice(courseID: id, lessonID: lesson.id, mode: .recall)
        XCTAssertEqual(state.learning.pathways.count, count)
        XCTAssertEqual(count, 1)
    }
    @MainActor func testEditedLessonArchivesOutlineAndKeepsReflectionSeparateFromResults() throws {
        let (state, id, varLesson) = try fixture(approved: true)
        var lesson = varLesson
        try state.reflectOnLesson(courseID: id, lessonID: lesson.id, introduced: true, note: "Try a lighter touch")
        XCTAssertTrue(state.courseEvidence(try state.course(id), lesson).isEmpty)
        let identity = lesson.learningIdentity
        lesson.goal = "Explore another phrase ending"
        try state.saveCourseLesson(courseID: id, lesson: lesson)
        XCTAssertFalse(try state.course(id).chapter.reviewed)
        XCTAssertEqual(state.courses.reflections[identity]?.note, "Try a lighter touch")
        XCTAssertNil(state.courses.reflections[lesson.learningIdentity])
        XCTAssertEqual(try state.course(id).history.last?.lessons[1].id, lesson.id)
        try state.reviewChapter(id)
        XCTAssertNoThrow(try state.readyCourseScore(state.course(id), lesson))
        try state.removeCourseLesson(courseID: id, lessonID: lesson.id)
        XCTAssertFalse(try state.course(id).chapter.lessons.last!.prerequisites.contains(lesson.id))
    }
}
