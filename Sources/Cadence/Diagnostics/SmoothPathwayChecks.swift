// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

@MainActor enum SmoothPathwayDiagnostics { static var checks: [String: Bool] = [:] }
@MainActor enum SmoothPathwayChecks {
    static func preview(state: AppState) throws {
        let source = PDFImportExamples.url("chapter").deletingLastPathComponent()
        let epubURL = source.appendingPathComponent("pathway.epub")
        let pdfURL = source.appendingPathComponent("chapter.pdf")
        let bytes = try Data(contentsOf: epubURL)
        let epub = try EPUBDocument(data: bytes)
        let song = BookAsset(data: bytes, filename: epubURL.lastPathComponent, epub: epub)
        let jazz = BookAsset(
            pdf: try PDFImportAsset(data: Data(contentsOf: pdfURL), filename: pdfURL.lastPathComponent))
        let inversions =
            (epub.sections.firstIndex { $0.reference.title.uppercased().contains("THREE CHORDS FROM ONE") } ?? 0) + 1
        let writing = (epub.sections.firstIndex { $0.reference.title.uppercased().contains("SECTION 3") } ?? 1) + 1
        let id = try state.installSmoothPathway(
            songAsset: song, jazzAsset: jazz, inversions: inversions, songwriting: writing, jazzPage: 1)
        do {
            // The distributed workflow fixture is Cadence's own material.
            // Never label it as a reproduction of the learner's books.
            var library = state.courses
            if let index = library.books.firstIndex(where: { !$0.isEPUB }) {
                library.books[index].title = "Cadence: original piano chapter"
                library.books[index].author = "Cadence original example"
            }
            try state.commitCourses(library)
        }
        var pathway = state.courses.musicalPathways!.first { $0.id == id }!
        SmoothPathwayDiagnostics.checks = [
            "twoSources": state.courses.books.count == 2, "fiveSteps": pathway.steps.count == 5,
            "fourStudies": state.courses.courses.flatMap(\.exercises).count == 4,
            "epubReadable": !epub.sections[inversions - 1].text.isEmpty,
            "unreviewedBlocked":
                (try? state.readyCourseScore(
                    state.pathwayLesson(pathway.steps[0]).0, state.pathwayLesson(pathway.steps[0]).1)) == nil,
        ]
        for course in state.courses.courses {
            try state.reviewChapter(course.id)
            for lesson in course.chapter.lessons where lesson.kind == .music {
                try state.approveCourseScore(courseID: course.id, lessonID: lesson.id, from: 0, through: 3, staff: 1)
            }
        }
        let (course, lesson) = try state.pathwayLesson(pathway.steps[0])
        let (score, approval) = try state.readyCourseScore(course, lesson)
        var study = try ComposePractice.make(score, from: approval.from, through: approval.through)
        study.staff = approval.staff
        state.studies.add(study)
        var follower = GuidedFollower(plan: try state.guidedPassage(study))
        var keys = MIDIKeyboardState()
        for step in follower.plan.steps {
            for note in step.notes {
                let message = MIDIMessage.noteOn(channel: 0, note: note, velocity: 85)
                keys.receive(message)
                _ = follower.receive(message, keyboard: keys)
            }
            for note in step.notes {
                let message = MIDIMessage.noteOff(channel: 0, note: note)
                keys.receive(message)
                _ = follower.receive(message, keyboard: keys)
            }
        }
        var result = try follower.result(id: UUID())
        result.date = Date().addingTimeInterval(-90000)
        try state.saveGuidedResult(result)
        SmoothPathwayDiagnostics.checks["midiEvidence"] = state.courseEvidence(course, lesson).count == 1
        SmoothPathwayDiagnostics.checks["spacedReview"] = state.musicalSession(pathway).first?.evidenceID != nil
        SmoothPathwayDiagnostics.checks["sessionBudget"] =
            state.musicalSession(pathway).map(\.minutes).reduce(0, +) == pathway.minutes
        if CommandLine.arguments.contains("--smooth-compose") {
            let composition = try state.openPathwayComposition(id)
            var doc = state.editor.documents.first { $0.id == composition }!
            doc.events[0].pitches = [60, 64, 67].map { EditorPitch($0) }
            state.editor.replace(doc)
            try state.saveCompositionReflection(
                id, text: "I kept a common note and let the upper voice move gently.", listened: true)
            pathway = state.courses.musicalPathways!.first { $0.id == id }!
            state.openMusicalStep(pathway.steps.last!)
            SmoothPathwayDiagnostics.checks["compositionLinked"] = pathway.compositionID == composition
        } else if CommandLine.arguments.contains("--smooth-lesson") {
            state.openMusicalStep(pathway.steps[CommandLine.arguments.contains("--smooth-pdf") ? 2 : 0])
        } else {
            state.musicalPathwayStep = nil
        }
        state.destination = .courses
    }
}
