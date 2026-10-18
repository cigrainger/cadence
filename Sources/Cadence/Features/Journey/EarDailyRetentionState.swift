// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

extension AppState {
    /// An explicit lifecycle action keeps canonical results, creative artifacts
    /// and an exposure checkpoint when an old completed coordinator is retired.
    func archiveEarDailyCompleted() throws {
        guard earDailyInput.pending == nil, !microphonePhraseSession.hasUnsavedTake, !microphonePhraseSession.busy
        else {
            throw MusicError.invalid("Finish the waiting take before archiving completed sessions.")
        }
        var book = earDailyPractice
        let retired = try book.archiveCompleted()
        var snapshot = practiceState
        for session in retired {
            for take in microphonePhrases.sessions.flatMap(\.takes) where session.attemptIDs.contains(take.id) {
                retainEarDailySummary(take, owner: session, in: &snapshot)
            }
            var checkpoint = PracticeAttempt(
                sessionID: session.id,
                activityID: session.material.id + ":daily-ear-completed", title: session.material.title,
                skills: ["Source exposure"], input: .selfReport, outcome: .skipped, assisted: true,
                selectedChoice: "Completed session archived; journal results and compositions are retained.",
                date: session.lastExposure)
            checkpoint.pathwayID = session.journeyID
            checkpoint.pieceID = session.material.pieceID
            checkpoint.scoreFingerprint = session.material.fingerprint
            checkpoint.passageScope = .init(
                partID: session.material.scope.partID, staff: session.material.staff,
                from: session.material.scope.fromBar - 1, through: session.material.scope.throughBar - 1)
            snapshot.journal.append(checkpoint)
        }
        snapshot.earDaily = book
        try commitPractice(snapshot)
    }

    @discardableResult func retireEarDailyDetails(_ id: UUID) throws -> Int {
        guard let session = earDailyPractice.sessions.first(where: { $0.id == id }),
            earDailyInput.pending == nil, !microphonePhraseSession.hasUnsavedTake, !microphonePhraseSession.busy
        else {
            throw MusicError.invalid("Finish the waiting take before clearing older detector details.")
        }
        let candidates = earDailyDetailCandidates(session)
        let ids = Set(candidates.dropLast(2).map(\.id))
        guard !ids.isEmpty else { return 0 }
        var microphoneBook = microphonePhrases
        let retired = try microphoneBook.retirePitchOnlyTakes(ids)
        var snapshot = practiceState
        for take in retired {
            if let owner = earDailyPractice.sessions.first(where: { $0.attemptIDs.contains(take.id) }) {
                retainEarDailySummary(take, owner: owner, in: &snapshot)
            }
        }
        snapshot.microphonePhrases = microphoneBook
        try commitPractice(snapshot)
        return retired.count
    }

    func earDailyDetailCleanupCount(_ session: EarDailySession) -> Int {
        max(0, earDailyDetailCandidates(session).count - 2)
    }

    private func earDailyDetailCandidates(_ session: EarDailySession) -> [MicrophonePhraseTake] {
        let known = Set(earDailyPractice.sessions.flatMap(\.attemptIDs)).union(
            journal.attempts.filter {
                $0.activityID.contains(":daily-ear:") && $0.input == .microphone
            }.map(\.id))
        return microphonePhrases.sessions.flatMap(\.takes).filter {
            $0.plan.key == session.material.id && $0.calibration == nil && !$0.report.conclusive
                && known.contains($0.id)
        }.sorted { $0.date < $1.date }
    }

    private func retainEarDailySummary(
        _ take: MicrophonePhraseTake, owner: EarDailySession, in snapshot: inout PracticeState
    ) {
        guard !snapshot.journal.attempts.contains(where: { $0.id == take.id }) else { return }
        var summary = PracticeAttempt(
            sessionID: owner.id, activityID: owner.activityID,
            title: owner.material.title, skills: ["Play it by ear"], input: .microphone, outcome: .skipped,
            assisted: true,
            selectedChoice: String(
                ("Inconclusive capture; no correctness grade. " + (take.signalIssue ?? "")).prefix(500)),
            played: take.attacks.compactMap(\.midi), target: take.plan.timed.targets.map(\.pitch), date: take.date)
        summary.id = take.id
        summary.pathwayID = owner.journeyID
        summary.pieceID = owner.material.pieceID
        summary.scoreFingerprint = owner.material.fingerprint
        summary.passageScope = take.plan.timed.source?.scope
        snapshot.journal.append(summary)
    }
}
