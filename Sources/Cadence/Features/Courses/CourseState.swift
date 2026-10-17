// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

struct CourseLocation: Equatable {
    var courseID: UUID
    var lessonID: UUID
}

extension AppState {
    func course(_ id: UUID) throws -> CourseDefinition {
        guard let value = courses.courses.first(where: { $0.id == id }) else {
            throw MusicError.invalid("This chapter is no longer available.")
        }
        return value
    }
    func courseBook(_ course: CourseDefinition) throws -> CourseBook {
        guard let book = courses.books.first(where: { $0.id == course.chapter.source.bookID }) else {
            throw MusicError.invalid("The chapter's original book is unavailable.")
        }
        return book
    }
    func courseBookURL(_ book: CourseBook) -> URL {
        if isPreview && !book.isEPUB && book.filename == "Notes, pulse and space.pdf" {
            return PDFImportExamples.url("chapter")
        }
        return storage.appendingPathComponent(book.isEPUB ? "EPUB Sources" : "PDF Sources").appendingPathComponent(
            book.fileID.uuidString + (book.isEPUB ? ".epub" : ".pdf"))
    }
    func commitCourses(_ copy: CourseLibrary) throws {
        _ = try copy.validated()
        if !isPreview { try stores.courses.save(copy) }
        courses = copy
        saveErrors.removeValue(forKey: "courses")
    }
    func changeCourse(_ id: UUID, _ change: (inout CourseDefinition) throws -> Void) throws {
        var copy = courses
        guard let i = copy.courses.firstIndex(where: { $0.id == id }) else {
            throw MusicError.invalid("This chapter is unavailable.")
        }
        try change(&copy.courses[i])
        try commitCourses(copy)
    }
    @discardableResult func createCourse(
        asset: PDFImportAsset, title: String, author: String, edition: String, chapterTitle: String, from: Int,
        through: Int, instrument: EditorInstrument
    ) throws -> UUID {
        let digest = CourseBook.digest(asset.data)
        let existing = courses.books.first { $0.digest == digest }
        let book =
            existing
            ?? CourseBook(
                data: asset.data, filename: asset.filename, pageCount: asset.pageCount, title: title, author: author,
                edition: edition)
        guard book.valid else { throw MusicError.invalid("Add a short book title and choose a supported PDF.") }
        let source = CourseSourceAnchor(book: book, from: from, through: through)
        let lesson = CourseLesson(
            title: "Explore this chapter", source: source, kind: .explanation, instrument: instrument,
            bookSummary: "Add a brief summary after checking the original pages.",
            goal: "Identify what this chapter will help you do.",
            practice: "Read the selected pages. Add one lesson for each idea or playable exercise you want to work on.",
            readyWhen: "You can describe one musical idea you want to try.")
        let chapter = try CourseChapter(
            title: chapterTitle, source: source, summary: "A chapter to review and make your own.",
            origin: "Your outline", lessons: [lesson]
        ).validated(book: book)
        let course = CourseDefinition(chapter: chapter)
        var copy = courses
        if existing == nil { copy.books.append(book) }
        copy.courses.append(course)
        _ = try copy.validated()
        let url = courseBookURL(book)
        let existed = FileManager.default.fileExists(atPath: url.path)
        if existed {
            guard (try? Data(contentsOf: url)) == asset.data else {
                throw MusicError.invalid("The saved book PDF has changed. Restore the original before continuing.")
            }
        } else {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try asset.data.write(to: url, options: .atomic)
        }
        do { try commitCourses(copy) } catch {
            if !existed { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        showCourse(course.id, lessonID: lesson.id)
        return course.id
    }
    func showCourse(_ id: UUID, lessonID: UUID? = nil) {
        if let pathway = courses.musicalPathways?.first(where: {
            $0.steps.contains { $0.courseID == id && (lessonID == nil || $0.lessonID == lessonID) }
        }) {
            musicalPathwaySelection = pathway.id
            musicalPathwayStep =
                pathway.steps.first { $0.courseID == id && (lessonID == nil || $0.lessonID == lessonID) }?.id
            learningShelf = "Pathways"
        } else {
            learningShelf = "Book chapters"
        }
        audio.stop()
        microphone.stop()
        courseSelection = id
        courseLessonSelection = lessonID
        libraryCourses = true
        destination = .library
    }
    func saveCourseLesson(courseID: UUID, lesson: CourseLesson) throws {
        var lesson = lesson
        let current = try course(courseID)
        let book = try courseBook(current)
        lesson.source = CourseSourceAnchor(
            book: book, from: lesson.source.fromPage, through: lesson.source.throughPage,
            printedLabel: lesson.source.printedLabel)
        try changeCourse(courseID) { course in
            guard course.outlineJob?.status != .reading else {
                throw MusicError.invalid("Stop the outline request before editing its lessons.")
            }
            var chapter = course.chapter
            if let i = chapter.lessons.firstIndex(where: { $0.id == lesson.id }) {
                chapter.lessons[i] = lesson
            } else {
                chapter.lessons.append(lesson)
            }
            course.revise(chapter)
        }
        courseLessonSelection = lesson.id
    }
    func removeCourseLesson(courseID: UUID, lessonID: UUID) throws {
        try changeCourse(courseID) { course in
            guard course.outlineJob?.status != .reading else {
                throw MusicError.invalid("Stop the outline request before editing its lessons.")
            }
            var chapter = course.chapter
            chapter.lessons.removeAll { $0.id == lessonID }
            for i in chapter.lessons.indices { chapter.lessons[i].prerequisites.removeAll { $0 == lessonID } }
            course.revise(chapter)
        }
    }
    func reviewChapter(_ id: UUID) throws {
        try changeCourse(id) { course in
            guard course.outlineJob?.status != .reading else {
                throw MusicError.invalid("Wait for or stop the outline request first.")
            }
            course.chapter.review()
        }
    }
    func reflectOnLesson(courseID: UUID, lessonID: UUID, introduced: Bool, note: String) throws {
        let course = try course(courseID)
        guard let lesson = course.chapter.lessons.first(where: { $0.id == lessonID }) else {
            throw MusicError.invalid("This lesson changed.")
        }
        var copy = courses
        copy.reflections[lesson.learningIdentity] = CourseReflection(introduced: introduced, note: note)
        if copy.reflections.count > 2000,
            let oldest = copy.reflections.filter({ $0.key != lesson.learningIdentity }).min(by: {
                $0.value.date < $1.value.date
            })?.key
        {
            copy.reflections.removeValue(forKey: oldest)
        }
        try commitCourses(copy)
    }
    func startCourseOutline(
        _ id: UUID, asset: PDFImportAsset, instrument: EditorInstrument, model: PDFImportModel,
        request: ((Data) async throws -> CourseOutlineReply)? = nil
    ) throws {
        let course = try course(id)
        let book = try courseBook(course)
        let source = course.chapter.source
        guard !book.isEPUB, CourseBook.digest(asset.data) == book.digest else {
            throw MusicError.invalid("The chapter source has changed.")
        }
        let excerpt = try asset.excerptPDF(source.pages)
        let key = request == nil ? try aiSettings.requestKey() : ""
        try startCourseRequest(id, model: model, instrument: instrument) {
            if let request { return try await request(excerpt) }
            return try await CourseOutlineClient().outline(
                pdf: excerpt, source: source, book: book, instrument: instrument, model: model, apiKey: key)
        }
    }
    func startCourseRequest(
        _ id: UUID, model: PDFImportModel, instrument: EditorInstrument,
        operation: @escaping () async throws -> CourseOutlineReply
    ) throws {
        guard !courseOutline.busy, courseOutline.pending == nil else {
            throw MusicError.invalid("Finish or save the current chapter reply first.")
        }
        let course = try course(id)
        let book = try courseBook(course)
        let source = course.chapter.source
        let job = CourseOutlineJob(model: model.rawValue, previous: course.outlineJob)
        try changeCourse(id) { $0.outlineJob = job }
        courseOutline.run { [weak self] in
            do {
                return try await operation()
            } catch {
                if let self {
                    try? self.changeCourse(id) { current in
                        guard current.outlineJob?.id == job.id, current.outlineJob?.status == .reading else { return }
                        current.outlineJob?.status = Task.isCancelled ? .stopped : .failed
                        current.outlineJob?.error = String(error.localizedDescription.prefix(4000))
                    }
                }
                throw error
            }
        } commit: { [weak self] reply in
            guard let self else { return }
            try self.changeCourse(id) { current in
                guard current.outlineJob?.id == job.id, current.outlineJob?.status == .reading,
                    current.chapter.identity == course.chapter.identity
                else {
                    throw MusicError.invalid(
                        "This outline belongs to an earlier chapter. It has not replaced your current work.")
                }
                let proposal = try reply.outline.chapter(
                    source: source, book: book, instrument: instrument, origin: "AI proposal · " + reply.model)
                current.revise(proposal)
                current.outlineJob?.status = .ready
                current.outlineJob?.error = nil
                if let cost = reply.costUSD {
                    guard cost.isFinite, (0...10000).contains(cost) else {
                        throw MusicError.invalid("Invalid reported request cost.")
                    }
                    current.outlineJob?.costUSD += cost
                    current.outlineJob?.unpricedAttempts -= 1
                }
            }
        }
    }
    func stopCourseOutline(_ id: UUID) {
        guard courseOutline.pending == nil else { return }
        courseOutline.cancel()
        do {
            try changeCourse(id) {
                if $0.outlineJob?.status == .reading {
                    $0.outlineJob?.status = .stopped
                    $0.outlineJob?.error = "Stopped. Work already sent may still be charged. No retry was made."
                }
            }
        } catch { message = error.localizedDescription }
    }
    /// Save the intended score ID before creating its independent score file. A
    /// failed score save can resume this same link; it cannot create paid duplicates.
    @discardableResult func prepareCourseExercise(
        courseID: UUID, lessonID: UUID, asset: PDFImportAsset, model: PDFImportModel
    ) throws -> UUID {
        var course = try course(courseID)
        guard course.chapter.reviewed, let lesson = course.chapter.lessons.first(where: { $0.id == lessonID }),
            lesson.kind == .music
        else { throw MusicError.invalid("Review the chapter outline and select a playable lesson first.") }
        let book = try courseBook(course)
        guard CourseBook.digest(asset.data) == book.digest else {
            throw MusicError.invalid("The original PDF is missing or changed.")
        }
        if course.link(lesson) == nil {
            let link = CourseExerciseLink(lesson: lesson, scoreID: UUID())
            try changeCourse(courseID) { $0.exercises.append(link) }
            course = try self.course(courseID)
        }
        let link = course.link(lesson)!
        if !editor.documents.contains(where: { $0.id == link.scoreID }) {
            _ = try createPDFBatch(
                asset: asset, pages: lesson.source.pages, instrument: lesson.instrument, model: model,
                passage: lesson.passage, documentID: link.scoreID, sourceID: book.fileID)
        }
        courseReturn = .init(courseID: courseID, lessonID: lessonID)
        pdfImportScoreID = link.scoreID
        showPDFImport = true
        return link.scoreID
    }
    func attachCourseScore(courseID: UUID, lessonID: UUID, scoreID: UUID) throws {
        let course = try course(courseID)
        guard course.chapter.reviewed, let lesson = course.chapter.lessons.first(where: { $0.id == lessonID }),
            lesson.kind == .music,
            let score = editor.documents.first(where: { $0.id == scoreID }), score.instrument == lesson.instrument
        else { throw MusicError.invalid("Choose an editable score for this instrument after reviewing the chapter.") }
        try changeCourse(courseID) { $0.exercises.append(CourseExerciseLink(lesson: lesson, scoreID: scoreID)) }
    }
    func approveCourseScore(courseID: UUID, lessonID: UUID, from: Int, through: Int, staff: Int?) throws {
        let course = try course(courseID)
        guard course.chapter.reviewed, let lesson = course.chapter.lessons.first(where: { $0.id == lessonID }),
            let link = course.link(lesson),
            let score = editor.documents.first(where: { $0.id == link.scoreID }), score.instrument == lesson.instrument
        else { throw MusicError.invalid("Review the chapter and attach this lesson's score first.") }
        _ = try score.validated()
        let approval = CourseScoreApproval(
            fingerprint: LibraryPiece(source: .score(score)).fingerprint, from: from, through: through, staff: staff)
        guard approval.valid, through < score.barCount, staff.map({ $0 <= score.staffCount }) ?? true else {
            throw MusicError.invalid("Choose up to 16 existing bars and an available staff.")
        }
        if let source = score.pdfSource {
            guard
                source.pages?.allSatisfy({
                    $0.barCount > 0 && $0.reviewed && $0.replacement == nil && $0.status != .reading
                }) ?? source.reviewed
            else {
                throw MusicError.invalid(
                    "Review every imported page against the original in Compose first. Missing pages or pending replacements still need attention."
                )
            }
        }
        // The score edits must be durable before the course claims they were reviewed.
        try libraryWorkspace.saveScores()
        try changeCourse(courseID) { current in
            guard let i = current.exercises.firstIndex(where: { $0.id == link.id }) else {
                throw MusicError.invalid("The exercise link changed.")
            }
            current.exercises[i].approval = approval
        }
    }
    func readyCourseScore(_ course: CourseDefinition, _ lesson: CourseLesson) throws -> (
        EditorDocument, CourseScoreApproval
    ) {
        guard course.chapter.reviewed, course.chapter.lessons.contains(lesson), let link = course.link(lesson),
            let approval = link.approval,
            let score = editor.documents.first(where: { $0.id == link.scoreID }), score.instrument == lesson.instrument,
            approval.fingerprint == LibraryPiece(source: .score(score)).fingerprint, approval.through < score.barCount,
            score.pdfSource.map({
                $0.pages?.allSatisfy({
                    $0.barCount > 0 && $0.reviewed && $0.replacement == nil && $0.status != .reading
                }) ?? $0.reviewed
            }) ?? true
        else {
            throw MusicError.invalid("Review this lesson's current notation and source before using it as an exercise.")
        }
        return (score, approval)
    }
    func courseEvidence(_ course: CourseDefinition, _ lesson: CourseLesson) -> [CourseEvidence] {
        guard let (score, approval) = try? readyCourseScore(course, lesson) else { return [] }
        let piece = LibraryPiece(source: .score(score))
        let from = approval.from
        let through = approval.through
        func scope(_ scope: PassageScope) -> Bool {
            scope.partID == "P1" && scope.from == from && scope.through == through && scope.staff == approval.staff
        }
        var evidence: [CourseEvidence] = []
        for progress in (history.guidedPassages ?? [:]).values
        where progress.latest.pieceID == piece.id && progress.latest.fingerprint == piece.fingerprint
            && scope(progress.latest.scope)
        {
            let r = progress.latest
            evidence.append(
                .init(
                    lessonID: lesson.id, practiceID: r.practiceID, mode: .guided, date: r.date, review: progress.review,
                    summary: r.evidence))
        }
        for progress in (history.timedPassages ?? [:]).values
        where progress.latest.plan.source?.pieceID == piece.id
            && progress.latest.plan.source?.fingerprint == piece.fingerprint
        {
            let r = progress.latest
            guard let source = r.plan.source, scope(source.scope) else { continue }
            let report = r.report
            evidence.append(
                .init(
                    lessonID: lesson.id, practiceID: r.practiceID, mode: .timed, date: r.date, review: progress.review,
                    summary: r.evidence,
                    timingOnlyDifficulty: report.matchedPitch == report.notes.count && report.wrong == 0
                        && report.extras.isEmpty && report.onTime < report.notes.count))
        }
        for path in learning.pathways
        where path.piecePractice?.pieceID == piece.id && path.piecePractice?.fingerprint == piece.fingerprint {
            guard let practice = path.piecePractice, practice.scope.fromBar == from + 1,
                practice.scope.throughBar == through + 1
            else { continue }
            for task in practice.tasks where task.review.encounters > 0 {
                evidence.append(
                    .init(
                        lessonID: lesson.id, practiceID: "pathway:" + task.id.uuidString, mode: .recall,
                        date: task.review.lastReview ?? .distantPast, review: task.review,
                        summary:
                            "\(task.kind.rawValue) · \(task.scope.label) · \(task.review.lastGrade?.label ?? "Recorded") via \(task.review.lastInput?.rawValue ?? "unknown"). \(task.kind == .passage ? "Your own report; no automatic performance assessment." : "A source-based exercise, not a whole-piece performance grade.")"
                    ))
            }
        }
        return evidence.sorted { $0.date > $1.date }
    }
    func courseSuggestions(_ course: CourseDefinition, now: Date = Date()) -> [CourseSuggestion] {
        let ready = Set(course.chapter.lessons.filter { (try? readyCourseScore(course, $0)) != nil }.map(\.id))
        let introduced = Set(
            course.chapter.lessons.filter { courses.reflections[$0.learningIdentity]?.introduced == true }.map(\.id))
        return CourseSessionPlanner.suggestions(
            chapter: course.chapter, ready: ready, introduced: introduced,
            evidence: course.chapter.lessons.flatMap { courseEvidence(course, $0) }, now: now)
    }
    func openCoursePractice(courseID: UUID, lessonID: UUID, mode: CoursePracticeMode, evidenceID: String? = nil) throws
    {
        let course = try course(courseID)
        guard let lesson = course.chapter.lessons.first(where: { $0.id == lessonID }) else {
            throw MusicError.invalid("The lesson is unavailable.")
        }
        let (score, approval) = try readyCourseScore(course, lesson)
        let piece = LibraryPiece(source: .score(score))
        courseReturn = .init(courseID: courseID, lessonID: lessonID)
        if mode == .listen {
            audio.play(score.playback(from: approval.from, through: approval.through))
            return
        }
        if mode == .recall {
            let snapshot = try PieceSnapshot(piece: piece, from: approval.from, through: approval.through)
            var path = learning.pathways.first {
                $0.piecePractice?.pieceID == piece.id && $0.piecePractice?.fingerprint == piece.fingerprint
                    && $0.piecePractice?.scope == snapshot.scope
            }
            if path == nil {
                var record = pieceRecord(piece)
                record.goal = lesson.goal
                path = try PiecePathwayFactory.make(
                    piece: piece, snapshot: snapshot, record: record, profile: learning.profile)
                try savePiecePathway(path!)
            }
            guard let path,
                let task = path.piecePractice?.tasks.first(where: { "pathway:" + $0.id.uuidString == evidenceID })
                    ?? path.piecePractice?.queue().first ?? path.piecePractice?.tasks.first
            else { throw MusicError.invalid("No recall tasks are available for this music.") }
            startPathwayTask(path.id, taskID: task.id)
            return
        }
        var study = try ComposePractice.make(score, from: approval.from, through: approval.through)
        study.staff = approval.staff
        if mode == .timed {
            _ = try TimedPracticePlan(
                study: study, guided: GuidedPassage(study: study, pieceID: piece.id, fingerprint: piece.fingerprint),
                tempo: min(160, max(40, Int(score.tempo))))
        } else {
            _ = try GuidedPassage(study: study, pieceID: piece.id, fingerprint: piece.fingerprint)
        }
        practiseEditor(score, from: approval.from, through: approval.through)
        guard destination == .studies, let active = studies.active, active.sourceEditor?.scoreID == score.id else {
            throw MusicError.invalid(message ?? "The practice copy could not be opened.")
        }
        editStudy(active.id) { $0.staff = approval.staff }
        guidedStudyID = mode == .guided ? active.id : nil
        timedStudyID = mode == .timed ? active.id : nil
        if mode == .timed { rhythmReview = nil }
        if mode == .timed, let evidenceID, var result = history.timedPassages?[evidenceID]?.latest {
            result.plan.source?.studyID = active.id
            rhythmReview = result
        }
    }
}
