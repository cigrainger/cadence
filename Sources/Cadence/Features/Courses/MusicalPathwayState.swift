// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

extension AppState {
    var selectedMusicalPathway: MusicalPathway? {
        courses.musicalPathways?.first { $0.id == musicalPathwaySelection } ?? courses.musicalPathways?.first
    }
    func pathwayLesson(_ step: MusicalPathway.Step) throws -> (CourseDefinition, CourseLesson) {
        let course = try course(step.courseID)
        guard let lesson = course.chapter.lessons.first(where: { $0.id == step.lessonID }) else {
            throw MusicError.invalid("This pathway lesson is unavailable.")
        }
        return (course, lesson)
    }
    func changeMusicalPathway(_ id: UUID, change: (inout MusicalPathway) throws -> Void) throws {
        var copy = courses
        guard let index = copy.musicalPathways?.firstIndex(where: { $0.id == id }) else {
            throw MusicError.invalid("This pathway is unavailable.")
        }
        try change(&copy.musicalPathways![index])
        try commitCourses(copy)
    }
    func openMusicalStep(_ step: MusicalPathway.Step) {
        musicalPathwayStep = step.id
        courseSelection = step.courseID
        courseLessonSelection = step.lessonID
        learningShelf = "Pathways"
        libraryCourses = true
        destination = .library
    }
    func musicalObservations(_ pathway: MusicalPathway) -> [PathwayObservation] {
        pathway.steps.compactMap { step in
            guard let (course, lesson) = try? pathwayLesson(step) else { return nil }
            return .init(
                stepID: step.id,
                ready: lesson.kind == .explanation
                    ? course.chapter.reviewed : (try? readyCourseScore(course, lesson)) != nil,
                introduced: courses.reflections[lesson.learningIdentity]?.introduced == true,
                evidence: courseEvidence(course, lesson))
        }
    }
    func musicalSession(_ pathway: MusicalPathway, now: Date = Date()) -> [PathwaySessionItem] {
        MusicalSessionPlanner.session(pathway: pathway, observations: musicalObservations(pathway), now: now)
    }
    func hasMissingPathwayStudies(_ pathway: MusicalPathway) -> Bool {
        pathway.recipe == SmoothChangesRecipe.identifier
            && pathway.steps.filter { $0.role != .compose }.contains { step in
                guard let (course, lesson) = try? pathwayLesson(step), let link = course.link(lesson) else {
                    return false
                }
                return !editor.documents.contains { $0.id == link.scoreID }
            }
    }
    func openMusicalReview(pathwayID: UUID, stepID: UUID, evidenceID: String) throws {
        guard let pathway = courses.musicalPathways?.first(where: { $0.id == pathwayID }),
            let step = pathway.steps.first(where: { $0.id == stepID })
        else { throw MusicError.invalid("This pathway activity is unavailable.") }
        let (course, lesson) = try pathwayLesson(step)
        guard let evidence = courseEvidence(course, lesson).first(where: { $0.practiceID == evidenceID }) else {
            throw MusicError.invalid(
                "This review no longer matches the approved study. Open the lesson and review its current music.")
        }
        musicalPathwaySelection = pathway.id
        musicalPathwayStep = step.id
        try openCoursePractice(courseID: course.id, lessonID: lesson.id, mode: evidence.mode, evidenceID: evidenceID)
    }

    @discardableResult func installSmoothPathway(
        songAsset: BookAsset, jazzAsset: BookAsset, inversions: Int, songwriting: Int, jazzPage: Int = 26
    ) throws -> UUID {
        if let existing = courses.musicalPathways?.first(where: { $0.recipe == SmoothChangesRecipe.identifier }) {
            try repairSmoothScores(existing)
            musicalPathwaySelection = existing.id
            musicalPathwayStep = nil
            learningShelf = "Pathways"
            libraryCourses = true
            return existing.id
        }
        guard songAsset.epub != nil, jazzAsset.pdf != nil else {
            throw MusicError.invalid("Choose the songwriting EPUB and jazz-piano PDF.")
        }
        let songbook =
            courses.books.first { $0.digest == CourseBook.digest(songAsset.data) }
            ?? songAsset.book(
                title: songAsset.title, author: songAsset.epub?.author ?? "", edition: "Your EPUB edition")
        let jazzbook =
            courses.books.first { $0.digest == CourseBook.digest(jazzAsset.data) }
            ?? jazzAsset.book(title: "The Jazz Piano Book", author: "Mark Levine", edition: "Your PDF edition")
        let draft = try SmoothChangesRecipe.make(
            songbook: songbook, jazzbook: jazzbook, inversions: inversions, songwriting: songwriting, jazzPage: jazzPage
        )
        var copy = courses
        for book in [songbook, jazzbook] where !copy.books.contains(where: { $0.id == book.id }) {
            copy.books.append(book)
        }
        copy.courses += draft.courses
        copy.musicalPathways = (copy.musicalPathways ?? []) + [draft.pathway]
        _ = try copy.validated()
        try storeBook(songAsset, book: songbook)
        try storeBook(jazzAsset, book: jazzbook)
        // Persist intended links first. Retrying after a failed score save repairs
        // the same IDs instead of duplicating the pathway or its compositions.
        try commitCourses(copy)
        try repairSmoothScores(draft.pathway)
        musicalPathwaySelection = draft.pathway.id
        musicalPathwayStep = nil
        learningShelf = "Pathways"
        libraryCourses = true
        destination = .library
        return draft.pathway.id
    }
    func repairSmoothScores(_ pathway: MusicalPathway) throws {
        var editor = self.editor
        for (index, step) in pathway.steps.filter({ $0.role != .compose }).enumerated() {
            let (course, lesson) = try pathwayLesson(step)
            guard let link = course.link(lesson), !editor.documents.contains(where: { $0.id == link.scoreID }) else {
                continue
            }
            var score = try SmoothChangesRecipe.score(index: index)
            score.id = link.scoreID
            editor.documents.append(score)
        }
        try libraryWorkspace.commitScores(editor)
        reconcileLibrary()
        // Authored learning studies belong with sheet music; the composition
        // activity below remains in the learner's own-compositions collection.
        for step in pathway.steps where step.role != .compose {
            if let (course, lesson) = try? pathwayLesson(step), let link = course.link(lesson) {
                let pieceID = "score:" + link.scoreID.uuidString
                if notebook.records[pieceID] != nil { try changePiece(pieceID) { $0.kind = .sheetMusic } }
            }
        }
    }
    @discardableResult func openPathwayComposition(_ id: UUID) throws -> UUID {
        guard var pathway = courses.musicalPathways?.first(where: { $0.id == id }),
            let step = pathway.steps.first(where: { $0.role == .compose })
        else { throw MusicError.invalid("This composition activity is unavailable.") }
        if pathway.compositionID == nil {
            try changeMusicalPathway(id) { $0.compositionID = UUID() }
            pathway = courses.musicalPathways!.first { $0.id == id }!
        }
        let scoreID = pathway.compositionID!
        if !editor.documents.contains(where: { $0.id == scoreID }) {
            var score = try SmoothChangesRecipe.composition()
            score.id = scoreID
            var copy = editor
            copy.documents.append(score)
            _ = try copy.validated()
            try libraryWorkspace.commitScores(copy)
            reconcileLibrary()
        }
        courseReturn = .init(courseID: step.courseID, lessonID: step.lessonID)
        musicalPathwayStep = step.id
        returnToCompose(scoreID, from: 0, through: 3)
        return scoreID
    }
    func saveCompositionReflection(_ id: UUID, text: String, listened: Bool) throws {
        guard let pathway = courses.musicalPathways?.first(where: { $0.id == id }), let scoreID = pathway.compositionID,
            let score = editor.documents.first(where: { $0.id == scoreID }),
            score.events.contains(where: { !$0.pitches.isEmpty })
        else { throw MusicError.invalid("Add some notes to your composition before saving its reflection.") }
        try libraryWorkspace.saveScores()
        try changeMusicalPathway(id) {
            $0.compositionReflection = text
            $0.compositionReviewedFingerprint = listened ? LibraryPiece(source: .score(score)).fingerprint : nil
        }
    }
}
