// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import XCTest

@testable import Cadence

final class MusicalPathwayIntegrationTests: XCTestCase {
    @MainActor private func state() throws -> AppState {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let state = AppState(storageOverride: folder)
        addTeardownBlock {
            await MainActor.run { state.midi.shutdown() }
            try? FileManager.default.removeItem(at: folder)
        }
        return state
    }
    @MainActor private func assets() throws -> (BookAsset, BookAsset) {
        let url = PDFImportExamples.url("chapter").deletingLastPathComponent().appendingPathComponent("pathway.epub")
        let bytes = try Data(contentsOf: url)
        let epub = try EPUBDocument(data: bytes)
        return (
            .init(data: bytes, filename: "Original pathway.epub", epub: epub), .init(pdf: try CourseExamples.asset())
        )
    }
    @MainActor private func install(_ state: AppState) throws -> MusicalPathway {
        let (song, jazz) = try assets()
        let id = try state.installSmoothPathway(
            songAsset: song, jazzAsset: jazz, inversions: 1, songwriting: 2, jazzPage: 1)
        return try XCTUnwrap(state.courses.musicalPathways?.first { $0.id == id })
    }
    @MainActor func testEPUBChapterPersistsOriginalAndStableSectionAnchors() async throws {
        let state = try state()
        let (song, _) = try assets()
        let id = try state.createBookCourse(
            asset: song, title: "My book", author: "Cadence", edition: "test", chapterTitle: "Inversions", from: 1,
            through: 1, instrument: .piano)
        let course = try state.course(id)
        let book = try state.courseBook(course)
        XCTAssertTrue(book.isEPUB)
        XCTAssertEqual(course.chapter.source.epubHrefs, ["Book/inversions.xhtml"])
        XCTAssertEqual(try Data(contentsOf: state.courseBookURL(book)), song.data)
        let loaded = try await state.loadBook(book)
        XCTAssertEqual(loaded.epub?.sections.count, 3)
        let restored = AppState(storageOverride: state.storage)
        defer { restored.midi.shutdown() }
        XCTAssertEqual(try restored.course(id), course)
        var lesson = course.chapter.lessons[0]
        lesson.title = "Changed goal"
        try state.saveCourseLesson(courseID: id, lesson: lesson)
        XCTAssertTrue(try state.course(id).chapter.lessons[0].source.belongs(to: book))
    }
    @MainActor func testPathwayInstallsIdempotentlyAndUsesSeparateCollections() throws {
        let state = try state()
        let pathway = try install(state)
        let count = state.editor.documents.count
        XCTAssertEqual(try install(state).id, pathway.id)
        XCTAssertEqual(state.editor.documents.count, count)
        XCTAssertEqual(state.courses.books.count, 2)
        XCTAssertEqual(state.courses.courses.count, 3)
        let (course, lesson) = try state.pathwayLesson(pathway.steps[0])
        XCTAssertThrowsError(try state.openCoursePractice(courseID: course.id, lessonID: lesson.id, mode: .guided))
        let link = try XCTUnwrap(course.link(lesson))
        let score = try XCTUnwrap(state.editor.documents.first { $0.id == link.scoreID })
        XCTAssertEqual(state.pieceRecord(LibraryPiece(source: .score(score))).kind, .sheetMusic)
        let compositionID = try state.openPathwayComposition(pathway.id)
        let after = state.editor.documents.count
        XCTAssertEqual(try state.openPathwayComposition(pathway.id), compositionID)
        XCTAssertEqual(state.editor.documents.count, after)
        XCTAssertEqual(state.pieceRecord(LibraryPiece(source: .score(state.editor.active))).kind, .composition)
        XCTAssertEqual(state.courseReturn?.lessonID, pathway.steps.last?.lessonID)
    }
    @MainActor func testApprovalAndVirtualMIDIProduceExactSourceSpacedEvidence() throws {
        let state = try state()
        let pathway = try install(state)
        let step = pathway.steps[0]
        try state.reviewChapter(step.courseID)
        try state.approveCourseScore(courseID: step.courseID, lessonID: step.lessonID, from: 0, through: 3, staff: 1)
        let (course, lesson) = try state.pathwayLesson(step)
        let (score, _) = try state.readyCourseScore(course, lesson)
        var study = try ComposePractice.make(score, from: 0, through: 3)
        study.staff = 1
        state.studies.add(study)
        let plan = try state.guidedPassage(study)
        var follower = GuidedFollower(plan: plan)
        var keyboard = MIDIKeyboardState()
        for event in plan.steps {
            for note in event.notes {
                let message = MIDIMessage.noteOn(channel: 0, note: note, velocity: 90)
                keyboard.receive(message)
                _ = follower.receive(message, keyboard: keyboard)
            }
            for note in event.notes {
                let message = MIDIMessage.noteOff(channel: 0, note: note)
                keyboard.receive(message)
                _ = follower.receive(message, keyboard: keyboard)
            }
        }
        var result = try follower.result(id: UUID())
        result.date = Date().addingTimeInterval(-90000)
        try state.saveGuidedResult(result)
        XCTAssertEqual(state.courseEvidence(course, lesson).count, 1)
        XCTAssertEqual(state.musicalSession(pathway).first?.stepID, step.id)
        XCTAssertNotNil(state.musicalSession(pathway).first?.evidenceID)
        let reviewID = try XCTUnwrap(state.musicalSession(pathway).first?.evidenceID)
        XCTAssertThrowsError(
            try state.openMusicalReview(pathwayID: pathway.id, stepID: pathway.steps[1].id, evidenceID: reviewID))
        try state.openMusicalReview(pathwayID: pathway.id, stepID: step.id, evidenceID: reviewID)
        XCTAssertEqual(state.courseReturn?.lessonID, step.lessonID)
        XCTAssertEqual(state.guidedStudyID, state.studies.active?.id)
        XCTAssertEqual(state.studies.active?.staff, 1)
        var changed = score
        changed.events[0].pitches[0].midi += 1
        state.editor.replace(changed)
        XCTAssertTrue(state.courseEvidence(course, lesson).isEmpty)
        XCTAssertNil(state.musicalSession(pathway).first?.evidenceID)
        XCTAssertThrowsError(try state.openMusicalReview(pathwayID: pathway.id, stepID: step.id, evidenceID: reviewID))
    }
    @MainActor func testCompositionReflectionNeedsMusicAndRemembersItsVersion() throws {
        let state = try state()
        let pathway = try install(state)
        let id = try state.openPathwayComposition(pathway.id)
        XCTAssertThrowsError(try state.saveCompositionReflection(pathway.id, text: "Blank", listened: true))
        var score = state.editor.active
        score.events[0].pitches = [60, 64, 67].map { EditorPitch($0) }
        state.editor.replace(score)
        try state.saveCompositionReflection(pathway.id, text: "The top note connects the phrase.", listened: true)
        let saved = try XCTUnwrap(state.courses.musicalPathways?.first)
        XCTAssertEqual(saved.compositionID, id)
        XCTAssertEqual(saved.compositionReviewedFingerprint, LibraryPiece(source: .score(score)).fingerprint)
        let practiceBefore = state.practiceState
        score.events[0].pitches[0].midi = 62
        state.editor.replace(score)
        XCTAssertNotEqual(saved.compositionReviewedFingerprint, LibraryPiece(source: .score(score)).fingerprint)
        XCTAssertEqual(state.practiceState, practiceBefore)
        let restored = AppState(storageOverride: state.storage)
        defer { restored.midi.shutdown() }
        XCTAssertEqual(restored.courses.musicalPathways?.first?.compositionReflection, saved.compositionReflection)
    }
    @MainActor func testFailedScoreSaveCanRepairSamePathwayWithoutDuplication() throws {
        let state = try state()
        let url = state.stores.editor.url
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try install(state))
        let saved = try XCTUnwrap(state.courses.musicalPathways?.first)
        let ids = state.courses.courses.flatMap(\.exercises).map(\.scoreID)
        XCTAssertEqual(state.courses.musicalPathways?.count, 1)
        XCTAssertTrue(state.hasMissingPathwayStudies(saved))
        try FileManager.default.removeItem(at: url)
        // A restart can restore the intended IDs directly from the overview,
        // without reopening setup or requiring the original Downloads paths.
        let reopened = AppState(storageOverride: state.storage)
        defer { reopened.midi.shutdown() }
        XCTAssertTrue(reopened.hasMissingPathwayStudies(saved))
        try reopened.repairSmoothScores(saved)
        XCTAssertFalse(reopened.hasMissingPathwayStudies(saved))
        XCTAssertTrue(ids.allSatisfy { id in reopened.editor.documents.contains { $0.id == id } })
        XCTAssertEqual(try install(reopened).id, saved.id)
        XCTAssertEqual(reopened.courses.musicalPathways?.count, 1)
    }
    @MainActor func testPathwayPreferencesAreDurableAndSaveFailuresDoNotPublish() throws {
        let state = try state()
        let pathway = try install(state)
        try state.changeMusicalPathway(pathway.id) {
            $0.minutes = 25
            $0.focus = .writing
        }
        let saved = state.courses
        let url = state.stores.courses.url
        let data = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try state.changeMusicalPathway(pathway.id) { $0.minutes = 10 })
        XCTAssertEqual(state.courses, saved)
        try FileManager.default.removeItem(at: url)
        try data.write(to: url)
        let restored = AppState(storageOverride: state.storage)
        defer { restored.midi.shutdown() }
        XCTAssertEqual(restored.courses.musicalPathways?.first?.minutes, 25)
        XCTAssertEqual(restored.courses.musicalPathways?.first?.focus, .writing)
    }
    @MainActor func testSelectedEPUBIllustrationsUseExistingQueueWithoutSendingOrCopyingWholeBook() throws {
        let state = try state()
        let (song, _) = try assets()
        let id = try state.createBookCourse(
            asset: song, title: "Original", author: "Cadence", edition: "", chapterTitle: "Music", from: 1, through: 1,
            instrument: .piano)
        var lesson = try state.course(id).chapter.lessons[0]
        lesson.kind = .music
        lesson.passage = "Selected chord illustration"
        try state.saveCourseLesson(courseID: id, lesson: lesson)
        try state.reviewChapter(id)
        let images = song.images(in: lesson.source)
        XCTAssertEqual(images.count, 1)
        XCTAssertThrowsError(try song.imageExcerpt(["outside.png"], source: lesson.source))
        try state.prepareEPUBExercise(
            courseID: id, lessonID: lesson.id, asset: song, selected: images.map(\.path), model: .sol)
        let course = try state.course(id)
        let link = try XCTUnwrap(course.link(lesson))
        let score = try XCTUnwrap(state.editor.documents.first { $0.id == link.scoreID })
        XCTAssertEqual(score.pdfSource?.pages?.count, 1)
        XCTAssertEqual(score.pdfSource?.pages?.first?.attempts, 0)
        XCTAssertNotEqual(score.pdfSource?.fileID, try state.courseBook(course).fileID)
        let before = state.editor.documents.count
        try state.prepareEPUBExercise(
            courseID: id, lessonID: lesson.id, asset: song, selected: images.map(\.path), model: .sol)
        XCTAssertEqual(state.editor.documents.count, before)
        XCTAssertThrowsError(
            try state.approveCourseScore(courseID: id, lessonID: lesson.id, from: 0, through: 0, staff: 1))
    }
    @MainActor func testPreviewKeepsBooksInMemoryAndNeverWritesUserSources() throws {
        let state = AppState(preview: true)
        let (song, jazz) = try assets()
        let id = try state.installSmoothPathway(
            songAsset: song, jazzAsset: jazz, inversions: 1, songwriting: 2, jazzPage: 1)
        XCTAssertNotNil(state.courses.musicalPathways?.first { $0.id == id })
        XCTAssertEqual(state.previewBooks.count, 2)
        for book in state.courses.books {
            let url = state.storage.appendingPathComponent(book.isEPUB ? "EPUB Sources" : "PDF Sources")
                .appendingPathComponent(book.fileID.uuidString + (book.isEPUB ? ".epub" : ".pdf"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
        state.midi.shutdown()
    }
}
