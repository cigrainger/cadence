// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

extension AppState {
    func playAlongPlan(_ material: ScoreEarMaterial, setup: PlayAlongSetup) throws -> PlayAlongPlan {
        guard let piece = libraryPieces.first(where: { $0.id == material.pieceID }), material.isCurrent(in: piece)
        else { throw MusicError.invalid("The source changed. Choose a reviewed passage from the current piece.") }
        let study = try ScoreEarMaterial.study(piece: piece, scope: material.scope)
        return try PlayAlongPlan(material: material, sourceStart: study.start, setup: setup)
    }
    func validatePlayAlong(_ plan: PlayAlongPlan) throws {
        let current = try playAlongPlan(plan.material, setup: plan.setup)
        guard plan.valid, current == plan else {
            throw MusicError.invalid("The play-along source changed. Start a new pass.")
        }
    }
    func savePlayAlong(_ result: PlayAlongResult) throws {
        guard result.valid else { throw MusicError.invalid("This play-along result is invalid.") }
        try validatePlayAlong(result.plan)
        if journal.attempts.contains(where: { $0.id == result.pass.id }) { return }
        var copy = practiceState
        var records = copy.history.playAlong ?? [:]
        var progress = records[result.practiceID] ?? PlayAlongProgress(result: result)
        progress.latest = result
        progress.review.record(result.grade, episode: result.pass.id, input: .midi, now: result.pass.date)
        records[result.practiceID] = progress
        if records.count > 256,
            let oldest = records.filter({ $0.key != result.practiceID }).min(by: {
                $0.value.latest.pass.date < $1.value.latest.pass.date
            })?.key
        {
            records.removeValue(forKey: oldest)
        }
        copy.history.playAlong = records
        var attempt = PracticeAttempt(
            sessionID: result.pass.id, activityID: result.practiceID, title: result.plan.material.title,
            skills: ["Play-along pitch", "Play-along timing"], input: .midi,
            outcome: result.pass.report.clean ? .correct : .incorrect,
            assisted: result.assisted, selectedChoice: String(result.evidence.prefix(500)),
            tempo: Double(result.plan.setup.tempo), date: result.pass.date)
        attempt.id = result.pass.id
        attempt.pieceID = result.plan.material.pieceID
        attempt.scoreFingerprint = result.plan.material.fingerprint
        attempt.passageScope = result.pass.plan.source?.scope
        guard attempt.valid else { throw MusicError.invalid("This play-along summary could not be saved.") }
        copy.journal.append(attempt)
        try commitPractice(copy)
    }
    var playAlongReviews: [PlayAlongProgress] {
        (history.playAlong ?? [:]).values.filter { (try? validatePlayAlong($0.latest.plan)) != nil }.sorted {
            $0.latest.pass.date < $1.latest.pass.date
        }
    }
    func openPlayAlong(_ material: ScoreEarMaterial, setup: PlayAlongSetup? = nil) {
        do {
            if playAlongSession.timing.hasUnsavedResult, playAlongSession.plan?.material.id != material.id {
                throw MusicError.invalid("Save or discard the pending play-along pass first.")
            }
            var chosen = setup ?? PlayAlongSetup()
            if setup == nil { chosen.tempo = min(160, max(50, Int(material.tempo.rounded()))) }
            _ = try playAlongPlan(material, setup: chosen)
            audio.stop()
            microphone.stop()
            scoreEarInput.pause()
            playAlongSession.timing.cancel()
            if !playAlongSession.timing.hasUnsavedResult {
                playAlongSession.timing.discard()
                playAlongSession.setup = chosen
            }
            playAlongMaterial = material
            practicePage = .playAlong
            destination = .practice
        } catch { message = error.localizedDescription }
    }
    func playAlongEvidence(_ piece: LibraryPiece) -> String {
        (history.playAlong ?? [:]).values.filter {
            $0.latest.plan.material.pieceID == piece.id && $0.latest.plan.material.fingerprint == piece.fingerprint
        }.sorted { $0.latest.pass.date > $1.latest.pass.date }.prefix(3).map { $0.latest.evidence }.joined(
            separator: "\n")
    }
}
