// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

extension AppState {
    func guidedPassage(_ study: MusicStudy) throws -> GuidedPassage {
        let piece = try practicePiece(study)
        return try GuidedPassage(study: study, pieceID: piece.id, fingerprint: piece.fingerprint)
    }

    func practicePiece(_ study: MusicStudy) throws -> LibraryPiece {
        let piece: LibraryPiece
        if let source = study.sourceEditor {
            guard let score = editor.documents.first(where: { $0.id == source.scoreID }) else {
                throw MusicError.invalid(
                    "The source composition is unavailable. Open a current piece from the library.")
            }
            func music(_ xml: String) -> String {
                ScoreRevision.fingerprint(
                    xml: xml.replacingOccurrences(
                        of: " id=\"n[A-Fa-f0-9]{32}s[0-9]+p[0-9]+\"", with: "", options: .regularExpression),
                    sourceMap: "")
            }
            guard music(try EditorXML.encode(score)) == music(study.document.originalXML) else {
                throw MusicError.invalid(
                    "This practice copy uses earlier music. Choose Practise passage again from the current score.")
            }
            piece = LibraryPiece(source: .score(score))
        } else {
            piece = LibraryPiece(source: .study(study))
        }
        return piece
    }

    /// Result, review and journal summary share the existing atomic practice commit.
    func saveGuidedResult(_ result: GuidedPassageResult) throws {
        guard result.valid, let source = studies.studies.first(where: { $0.id == result.studyID }) else {
            throw MusicError.invalid("The passage is unavailable. This result has not been saved to another score.")
        }
        var study = source
        study.partID = result.scope.partID
        study.staff = result.scope.staff
        study.from = result.scope.from
        study.through = result.scope.through
        let plan = try guidedPassage(study)
        guard plan.id == result.practiceID, plan.steps.count == result.steps.count,
            zip(plan.steps, result.steps).allSatisfy({
                $0.bar == $1.bar && abs($0.beat - $1.beat) < 0.00001 && $0.notes == $1.target
            })
        else {
            throw MusicError.invalid("The score or selected notes changed. Start a fresh guided pass.")
        }
        if journal.attempts.contains(where: { $0.id == result.id }) { return }
        var copy = practiceState
        var records = copy.history.guidedPassages ?? [:]
        var progress = records[result.practiceID] ?? GuidedPassageProgress(result: result)
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
        copy.history.guidedPassages = records
        var attempt = PracticeAttempt(
            sessionID: result.id, activityID: result.practiceID, title: result.title,
            skills: ["Guided passage reading"], input: .midi, outcome: .correct, assisted: true,
            selectedChoice: String(result.evidence.prefix(500)), date: result.date)
        attempt.id = result.id
        attempt.pieceID = result.pieceID
        attempt.guidedPracticeID = result.practiceID
        attempt.scoreFingerprint = result.fingerprint
        attempt.passageScope = result.scope
        guard attempt.valid else { throw MusicError.invalid("The guided practice summary is invalid.") }
        copy.journal.append(attempt)
        try commitPractice(copy)
    }
    func openGuidedReview(_ progress: GuidedPassageProgress) {
        let result = progress.latest
        guard let study = studies.studies.first(where: { $0.id == result.studyID }) else {
            message = "This practice copy is no longer available."
            return
        }
        do {
            var copy = study
            copy.partID = result.scope.partID
            copy.staff = result.scope.staff
            copy.from = result.scope.from
            copy.through = result.scope.through
            guard try guidedPassage(copy).id == result.practiceID else {
                throw MusicError.invalid("This review belongs to earlier music. Start a new pass from the piece.")
            }
            audio.stop()
            microphone.stop()
            studies.activeID = study.id
            editStudy(study.id) { $0 = copy }
            guidedStudyID = study.id
            destination = .studies
        } catch { message = error.localizedDescription }
    }
    func guidedEvidence(_ piece: LibraryPiece) -> String {
        (history.guidedPassages ?? [:]).values.filter {
            $0.latest.pieceID == piece.id && $0.latest.fingerprint == piece.fingerprint
        }
        .sorted { $0.latest.date > $1.latest.date }.prefix(5).map { $0.latest.evidence }.joined(separator: "\n")
    }
    func guidedReference(_ study: MusicStudy) -> StudyReference {
        var reference = study.reference
        if let plan = try? guidedPassage(study), let result = history.guidedPassages?[plan.id]?.latest {
            reference.context += "\nRecorded practice for this exact score and selection: " + result.evidence
        }
        let timed = timedEvidence(study)
        if !timed.isEmpty { reference.context += "\nRecorded timing for this exact score and selection: " + timed }
        return reference
    }
    var guidedReviews: [GuidedPassageProgress] { guidedReviews(at: Date()) }
    func guidedReviews(at now: Date) -> [GuidedPassageProgress] {
        let pieces = Dictionary(uniqueKeysWithValues: libraryPieces.map { ($0.id, $0.fingerprint) })
        let items = (history.guidedPassages ?? [:]).values.filter { value in
            pieces[value.latest.pieceID] == value.latest.fingerprint
                && studies.studies.contains { $0.id == value.latest.studyID }
        }
        return ReviewQueue.ordered(Array(items), now: now, review: { $0.review }) { $0.latest.date < $1.latest.date }
    }
}
