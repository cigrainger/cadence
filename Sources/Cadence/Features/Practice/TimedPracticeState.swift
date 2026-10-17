// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

extension AppState {
    func timedPlan(_ study: MusicStudy, tempo: Int) throws -> TimedPracticePlan {
        try TimedPracticePlan(study: study, guided: guidedPassage(study), tempo: tempo)
    }
    func validateTimedPlan(_ plan: TimedPracticePlan) throws {
        guard plan.valid else { throw MusicError.invalid("This timing plan is invalid.") }
        let current: TimedPracticePlan
        if let source = plan.source {
            guard var study = studies.studies.first(where: { $0.id == source.studyID }) else {
                throw MusicError.invalid("The source study is no longer available.")
            }
            study.partID = source.scope.partID
            study.staff = source.scope.staff
            study.from = source.scope.from
            study.through = source.scope.through
            current = try timedPlan(study, tempo: plan.tempo)
        } else {
            guard let exercise = RhythmExercise.allCases.first(where: { $0.id == plan.rhythmID }) else {
                throw MusicError.invalid("This rhythm exercise is unavailable.")
            }
            current = TimedPracticePlan(rhythm: exercise, tempo: plan.tempo)
        }
        // Titles may change without changing the musical evidence.
        var comparison = plan
        comparison.title = current.title
        guard comparison == current else {
            throw MusicError.invalid("The music changed. Start a new pass from the current piece.")
        }
    }
    func saveTimedResult(_ result: TimedPracticeResult) throws {
        guard result.valid else { throw MusicError.invalid("This timed result is invalid.") }
        try validateTimedPlan(result.plan)
        if journal.attempts.contains(where: { $0.id == result.id }) { return }
        var copy = practiceState
        var records = copy.history.timedPassages ?? [:]
        var progress = records[result.practiceID] ?? TimedPracticeProgress(result: result)
        progress.latest = result
        progress.review.record(
            result.grade, episode: result.id, input: result.conditions.input.journalInput, now: result.date)
        records[result.practiceID] = progress
        if records.count > 256,
            let oldest = records.filter({ $0.key != result.practiceID }).min(by: {
                $0.value.latest.date < $1.value.latest.date
            })?.key
        {
            records.removeValue(forKey: oldest)
        }
        copy.history.timedPassages = records
        var attempt = PracticeAttempt(
            sessionID: result.id, activityID: result.practiceID, title: result.plan.title,
            skills: [result.plan.rhythmOnly ? "Rhythm tapping" : "Timed passage playing"],
            input: result.conditions.input.journalInput, outcome: result.report.clean ? .correct : .incorrect,
            selectedChoice: String(result.evidence.prefix(500)), tempo: Double(result.plan.tempo), date: result.date)
        attempt.id = result.id
        attempt.timedPracticeID = result.practiceID
        attempt.pieceID = result.plan.source?.pieceID
        attempt.scoreFingerprint = result.plan.source?.fingerprint
        attempt.passageScope = result.plan.source?.scope
        guard attempt.valid else { throw MusicError.invalid("This timing summary is invalid.") }
        copy.journal.append(attempt)
        try commitPractice(copy)
    }
    var timedReviews: [TimedPracticeProgress] { timedReviews(at: Date()) }
    func timedReviews(at now: Date) -> [TimedPracticeProgress] {
        let current = (history.timedPassages ?? [:]).values.filter { (try? validateTimedPlan($0.latest.plan)) != nil }
        return ReviewQueue.ordered(Array(current), now: now, review: { $0.review }) { $0.latest.date < $1.latest.date }
    }
    func openTimedReview(_ result: TimedPracticeResult) {
        do {
            try validateTimedPlan(result.plan)
            rhythmReview = result
            if let source = result.plan.source {
                editStudy(source.studyID) {
                    $0.partID = source.scope.partID
                    $0.staff = source.scope.staff
                    $0.from = source.scope.from
                    $0.through = source.scope.through
                    $0.speed = min(1.5, max(0.25, Double(result.plan.tempo) / $0.document.tempo))
                }
                studies.activeID = source.studyID
                timedStudyID = source.studyID
                destination = .studies
            } else {
                rhythmReview = result
                pathwaySession = nil
                practicePage = .exercises
                destination = .practice
            }
        } catch { message = error.localizedDescription }
    }
    func timedEvidence(_ piece: LibraryPiece) -> String {
        (history.timedPassages ?? [:]).values.filter {
            $0.latest.plan.source?.pieceID == piece.id && $0.latest.plan.source?.fingerprint == piece.fingerprint
        }
        .sorted { $0.latest.date > $1.latest.date }.prefix(3).map { $0.latest.evidence }.joined(separator: "\n")
    }
    func timedEvidence(_ study: MusicStudy) -> String {
        (history.timedPassages ?? [:]).values.filter {
            $0.latest.plan.source?.studyID == study.id && $0.latest.plan.source?.scope == PassageScope(study)
                && (try? validateTimedPlan($0.latest.plan)) != nil
        }.sorted { $0.latest.date > $1.latest.date }.prefix(3).map { $0.latest.evidence }.joined(separator: "\n")
    }
}
