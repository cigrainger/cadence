// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

@MainActor enum CourseDiagnostics { static var checks: [String: Bool] = [:] }
@MainActor enum CourseChecks {
    static func preview(state: AppState, ready: Bool) throws {
        try CourseExamples.preview(state: state, ready: ready)
        let course = state.courses.courses[0]
        let lesson = course.chapter.lessons[1]
        CourseDiagnostics.checks = [
            "sourceLinked": course.chapter.lessons.allSatisfy { course.chapter.source.contains($0.source) },
            "outlineGate": course.chapter.reviewed == ready, "exerciseLinked": course.exercises.count == 2,
        ]
        if ready {
            let (score, approval) = try state.readyCourseScore(course, lesson)
            var study = try ComposePractice.make(score, from: approval.from, through: approval.through)
            study.staff = approval.staff
            state.studies.add(study)
            let plan = try state.guidedPassage(study)
            var follower = GuidedFollower(plan: plan)
            var keys = MIDIKeyboardState()
            for step in plan.steps {
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
            CourseDiagnostics.checks["reviewedExercisePlayable"] = !score.playback(from: 0, through: 3).notes.isEmpty
            CourseDiagnostics.checks["virtualMIDIRecorded"] =
                state.courseEvidence(course, lesson).first?.mode == .guided
            CourseDiagnostics.checks["spacedReviewSuggested"] = state.courseSuggestions(course).first?.kind == .review
        } else {
            CourseDiagnostics.checks["unreviewedExerciseBlocked"] = (try? state.readyCourseScore(course, lesson)) == nil
        }
    }
}
