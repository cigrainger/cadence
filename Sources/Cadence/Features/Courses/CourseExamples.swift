// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

@MainActor enum CourseExamples {
    struct Score: Decodable {
        struct Note: Decodable {
            var midi: Int
            var ticks: Int
        }
        var title: String
        var bars: [[Note]]
    }
    static func asset() throws -> PDFImportAsset {
        try PDFImportAsset(
            data: Data(contentsOf: PDFImportExamples.url("chapter")), filename: "Notes, pulse and space.pdf")
    }
    static func scores(book: CourseBook) throws -> [EditorDocument] {
        let url = PDFImportExamples.url("chapter").deletingLastPathComponent().appendingPathComponent(
            "chapter-scores.json")
        let examples = try JSONDecoder().decode([Score].self, from: Data(contentsOf: url))
        return try examples.enumerated().map { index, item in
            var events: [EditorEvent] = []
            for (bar, notes) in item.bars.enumerated() {
                events += notes.map {
                    EditorEvent(
                        bar: bar, rhythm: EditorRhythm($0.ticks), pitches: $0.midi < 0 ? [] : [EditorPitch($0.midi)])
                }
                events.append(EditorEvent(bar: bar, staff: 2, rhythm: EditorRhythm(1920)))
            }
            var score = EditorDocument(title: item.title, instrument: .piano, events: events)
            score.barCount = item.bars.count
            score.tempo = 60
            score.pdfSource = PDFScoreSource(
                fileID: book.fileID, filename: book.filename, page: index + 2, model: "Cadence original example",
                warnings: ["Compare this original example with its printed page before approving it for practice."])
            return try score.validated()
        }
    }
    static func chapter(book: CourseBook) -> CourseChapter {
        let a = CourseLesson(
            title: "Find a comfortable pulse", source: .init(book: book, from: 1, through: 1), kind: .explanation,
            instrument: .piano,
            bookSummary: "Count evenly through four beats, then keep counting as you imagine the taps.",
            goal: "Keep a quiet, even pulse.",
            practice:
                "Count 1, 2, 3, 4. Tap each number, then leave the taps out for one bar. A metronome can help you begin.",
            readyWhen: "You can keep counting through a bar of silence.", skills: [.pulse, .listening])
        let b = CourseLesson(
            title: "Small steps, steady pulse", source: .init(book: book, from: 2, through: 2), instrument: .piano,
            bookSummary: "A four-bar right-hand melody in C, with quarter notes and a resting left hand.",
            goal: "Connect the written notes to the piano keys, then keep the pulse.",
            practice:
                "Listen once. Locate the first note, middle C. Try Follow the notes without time pressure, then Play in time at a comfortable tempo. Added suggestion: change the last note and describe its effect.",
            readyWhen: "You can find the notes and describe where the pulse still needs attention.",
            passage: "Exercise 1: Small steps, steady pulse. Both systems, all four bars.",
            skills: [.reading, .pulse, .expression], prerequisites: [a.id])
        let c = CourseLesson(
            title: "Make room for the spaces", source: .init(book: book, from: 3, through: 3), instrument: .piano,
            bookSummary: "Quarter notes, half notes and rests share a four-bar phrase.",
            goal: "Keep counting through longer notes and silence.",
            practice:
                "Count the four beats aloud. Notice where a half note lasts two beats. Play the right hand and keep counting during each rest.",
            readyWhen: "You can keep the pulse through the rests and identify a bar to revisit.",
            passage: "Exercise 2: Make room for the spaces. Both systems, all four bars.", skills: [.reading, .pulse],
            prerequisites: [b.id])
        return CourseChapter(
            title: "Notes, pulse and space", source: .init(book: book, from: 1, through: 3),
            summary: "A small piano chapter: find a pulse, read a phrase, then make room for silence.",
            origin: "Cadence original example · editable teaching suggestions", lessons: [a, b, c])
    }
    @discardableResult static func install(state: AppState) throws -> UUID {
        let asset = try asset()
        if let existing = state.courses.courses.first(where: { $0.chapter.origin.hasPrefix("Cadence original example") }
        ) {
            let book = try state.courseBook(existing)
            try installScores(state: state, course: existing, book: book)
            state.showCourse(existing.id)
            return existing.id
        }
        let id = try state.createCourse(
            asset: asset, title: "Cadence: first steps", author: "Cadence", edition: "Original example",
            chapterTitle: "Notes, pulse and space", from: 1, through: 3, instrument: .piano)
        let book = try state.courseBook(state.course(id))
        let chapter = chapter(book: book)
        try state.changeCourse(id) { course in
            course.revise(chapter)
            course.exercises = chapter.lessons.filter { $0.kind == .music }.map {
                CourseExerciseLink(lesson: $0, scoreID: UUID())
            }
        }
        try installScores(state: state, course: state.course(id), book: book)
        state.showCourse(id, lessonID: chapter.lessons[0].id)
        return id
    }
    private static func installScores(state: AppState, course: CourseDefinition, book: CourseBook) throws {
        var editor = state.editor
        let examples = try scores(book: book)
        let originals = chapter(book: book).lessons.filter { $0.kind == .music }
        for lesson in course.chapter.lessons where lesson.kind == .music {
            guard let i = originals.firstIndex(where: { $0.musicIdentity == lesson.musicIdentity }), i < examples.count,
                let link = course.link(lesson), !editor.documents.contains(where: { $0.id == link.scoreID })
            else { continue }
            var score = examples[i]
            score.id = link.scoreID
            editor.documents.append(score)
        }
        _ = try editor.validated()
        if !state.isPreview { try state.stores.editor.save(editor) }
        state.editor = editor
        state.reconcileLibrary()
    }
    static func preview(state: AppState, ready: Bool) throws {
        let asset = try asset()
        let book = CourseBook(
            data: asset.data, filename: asset.filename, pageCount: 3, title: "Cadence: first steps",
            author: "Cadence")
        var chapter = chapter(book: book)
        if ready { chapter.review() }
        var course = CourseDefinition(chapter: chapter)
        for (index, var score) in try scores(book: book).enumerated() {
            score.pdfSource?.reviewed = ready
            state.editor.documents.append(score)
            let lesson = chapter.lessons[index + 1]
            var link = CourseExerciseLink(lesson: lesson, scoreID: score.id)
            if ready {
                link.approval = .init(
                    fingerprint: LibraryPiece(source: .score(score)).fingerprint, from: 0, through: 3, staff: 1)
            }
            course.exercises.append(link)
        }
        state.courses.books = [book]
        state.courses.courses = [course]
        state.showCourse(course.id, lessonID: chapter.lessons[ready ? 1 : 0].id)
    }
}
