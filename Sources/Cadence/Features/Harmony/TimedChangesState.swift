// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

extension AppState {
    func changesPlan(for plan: TimedChangesPlan) throws -> ChangesPlan {
        guard let id = plan.pieceID else { return .example }
        guard let piece = libraryPieces.first(where: { $0.id == id }) else {
            throw MusicError.invalid("The source piece is no longer in the library.")
        }
        return try ChangesSource(piece: piece, from: plan.from, through: plan.through, partID: plan.partID).plan(
            staff: plan.staff)
    }
    func validateTimedChanges(_ plan: TimedChangesPlan) throws {
        guard plan.valid else { throw MusicError.invalid("This timed chord plan is invalid.") }
        let current = try TimedChangesPlan(
            changes: changesPlan(for: plan), mode: plan.mode, tempo: plan.tempo, loops: plan.loops, focus: plan.focus)
        var comparison = plan
        comparison.title = current.title
        guard comparison == current else {
            throw MusicError.invalid("The chord symbols or score changed. Open a new pass from the current piece.")
        }
    }
    func saveTimedChanges(_ result: TimedChangesResult) throws {
        guard result.valid else { throw MusicError.invalid("This chord pass is invalid.") }
        try validateTimedChanges(result.plan)
        if journal.attempts.contains(where: { $0.id == result.id }) { return }
        var copy = practiceState
        var records = copy.history.timedChanges ?? [:]
        var progress = records[result.practiceID] ?? TimedChangesProgress(result: result)
        progress.latest = result
        progress.review.record(result.grade, episode: result.id, input: .midi, now: result.date)
        records[result.practiceID] = progress
        if records.count > 256,
            let oldest = records.filter({ $0.key != result.practiceID }).min(by: {
                $0.value.latest.date < $1.value.latest.date
            })?.key
        {
            records.removeValue(forKey: oldest)
        }
        copy.history.timedChanges = records
        var attempt = PracticeAttempt(
            sessionID: result.id, activityID: result.practiceID, title: result.plan.title,
            skills: ["Timed chord transitions", result.plan.mode.rawValue], input: .midi,
            outcome: result.report.clean ? .correct : .incorrect, assisted: result.assisted,
            selectedChoice: String(result.evidence.prefix(500)), tempo: Double(result.plan.tempo), date: result.date)
        attempt.id = result.id
        attempt.pieceID = result.plan.pieceID
        attempt.scoreFingerprint = result.plan.fingerprint
        guard attempt.valid else { throw MusicError.invalid("This chord summary is invalid.") }
        copy.journal.append(attempt)
        try commitPractice(copy)
    }
    var timedChangesReviews: [TimedChangesProgress] { timedChangesReviews(at: Date()) }
    func timedChangesReviews(at now: Date) -> [TimedChangesProgress] {
        let current = (history.timedChanges ?? [:]).values.filter { (try? validateTimedChanges($0.latest.plan)) != nil }
        return ReviewQueue.ordered(Array(current), now: now, review: { $0.review }) { $0.latest.date < $1.latest.date }
    }
    func openTimedChangesReview(_ result: TimedChangesResult) {
        guard !timedChangesSession.hasUnsavedResult, changesSession.pending == nil else {
            message = "Save or discard the pending chord answer first."
            return
        }
        do {
            try validateTimedChanges(result.plan)
            let plan = try changesPlan(for: result.plan)
            timedChangesSession.discard()
            openChanges(plan)
            changesReview = result
            showTimedChanges = true
        } catch { message = error.localizedDescription }
    }
    func timedChangesEvidence(_ piece: LibraryPiece) -> String {
        (history.timedChanges ?? [:]).values.filter {
            $0.latest.plan.pieceID == piece.id && $0.latest.plan.fingerprint == piece.fingerprint
        }
        .sorted { $0.latest.date > $1.latest.date }.prefix(3).map { $0.latest.evidence }.joined(separator: "\n")
    }
}
