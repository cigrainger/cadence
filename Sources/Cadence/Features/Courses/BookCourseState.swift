// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

extension AppState {
    @discardableResult func createBookCourse(
        asset: BookAsset, title: String, author: String, edition: String, chapterTitle: String, from: Int, through: Int,
        instrument: EditorInstrument
    ) throws -> UUID {
        if let pdf = asset.pdf {
            return try createCourse(
                asset: pdf, title: title, author: author, edition: edition, chapterTitle: chapterTitle, from: from,
                through: through, instrument: instrument)
        }
        let book =
            courses.books.first { $0.digest == CourseBook.digest(asset.data) }
            ?? asset.book(title: title, author: author, edition: edition)
        let source = CourseSourceAnchor(book: book, from: from, through: through)
        let lesson = CourseLesson(
            title: chapterTitle, source: source, kind: .explanation, instrument: instrument,
            goal: "Find one musical idea you want to try.",
            practice:
                "Read the linked section and explore its illustrations. Add your own lessons or request a proposed outline.",
            readyWhen: "You can describe a small musical goal for this section.")
        let chapter = try CourseChapter(
            title: chapterTitle, source: source, summary: "A section of your book, ready to explore.",
            origin: "Your EPUB outline", lessons: [lesson]
        ).validated(book: book)
        var copy = courses
        if !copy.books.contains(where: { $0.id == book.id }) { copy.books.append(book) }
        let course = CourseDefinition(chapter: chapter)
        copy.courses.append(course)
        try storeBook(asset, book: book)
        try commitCourses(copy)
        showCourse(course.id, lessonID: lesson.id)
        return course.id
    }
    func loadBook(_ book: CourseBook) async throws -> BookAsset {
        if isPreview, let asset = previewBooks[book.id] { return asset }
        return try await BookAsset.read(courseBookURL(book))
    }
    func storeBook(_ asset: BookAsset, book: CourseBook) throws {
        guard book.valid, CourseBook.digest(asset.data) == book.digest, asset.pageCount == book.pageCount else {
            throw MusicError.invalid("This source no longer matches the book.")
        }
        if isPreview {
            previewBooks[book.id] = asset
            return
        }
        let url = courseBookURL(book)
        if FileManager.default.fileExists(atPath: url.path) {
            guard try Data(contentsOf: url) == asset.data else {
                throw MusicError.invalid("The saved original has changed. Restore it before continuing.")
            }
        } else {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try asset.data.write(to: url, options: .atomic)
        }
    }
    func startBookOutline(_ id: UUID, asset: BookAsset, instrument: EditorInstrument, model: PDFImportModel) throws {
        if let pdf = asset.pdf {
            try startCourseOutline(id, asset: pdf, instrument: instrument, model: model)
            return
        }
        let course = try course(id)
        let book = try courseBook(course)
        let key = try aiSettings.requestKey()
        guard let epub = asset.epub, CourseBook.digest(asset.data) == book.digest else {
            throw MusicError.invalid("Open the original EPUB first.")
        }
        _ = try epub.outlineSections(from: course.chapter.source.fromPage, through: course.chapter.source.throughPage)
        try startCourseRequest(id, model: model, instrument: instrument) {
            try await CourseOutlineClient().outline(
                pdf: Data(), source: course.chapter.source, book: book, instrument: instrument, model: model,
                apiKey: key, epub: epub)
        }
    }
    func prepareEPUBExercise(
        courseID: UUID, lessonID: UUID, asset: BookAsset, selected: [String], model: PDFImportModel
    ) throws {
        var course = try course(courseID)
        let book = try courseBook(course)
        guard course.chapter.reviewed, book.isEPUB, CourseBook.digest(asset.data) == book.digest,
            let lesson = course.chapter.lessons.first(where: { $0.id == lessonID }), lesson.kind == .music
        else { throw MusicError.invalid("Review the lesson and its EPUB source first.") }
        if course.link(lesson) == nil {
            try changeCourse(courseID) { $0.exercises.append(.init(lesson: lesson, scoreID: UUID())) }
            course = try self.course(courseID)
        }
        let link = course.link(lesson)!
        if !editor.documents.contains(where: { $0.id == link.scoreID }) {
            let excerpt = try asset.imageExcerpt(selected, source: lesson.source)
            _ = try createPDFBatch(
                asset: excerpt, pages: Array(1...excerpt.pageCount), instrument: lesson.instrument, model: model,
                passage: lesson.passage
                    + ". These are selected EPUB illustrations; keyboard diagrams may lack octave or rhythm. Report ambiguities rather than claiming exact transcription.",
                documentID: link.scoreID)
        }
        courseReturn = .init(courseID: courseID, lessonID: lessonID)
        pdfImportScoreID = link.scoreID
        showPDFImport = true
    }
}
