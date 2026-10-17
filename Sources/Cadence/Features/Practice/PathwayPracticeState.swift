// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

struct PathwayPracticeSession: Equatable {
    var pathwayID: UUID
    var taskID: UUID
    var episode = UUID()
    var studyID: UUID?
    var studyXML: String?
    var practiceFrom: Int?
    var practiceThrough: Int?
    var reduced = false
}

extension AppState {
    var currentPathway: LearningPathway? { learning.pathways.first { $0.id == pathwaySession?.pathwayID } }
    var currentPathwayTask: PieceTask? {
        currentPathway?.piecePractice?.tasks.first { $0.id == pathwaySession?.taskID }
    }
    func pieceForPathway(_ path: LearningPathway) -> LibraryPiece? {
        libraryPieces.first { $0.id == path.piecePractice?.pieceID }
    }
    func pathwayCurrent(_ path: LearningPathway) -> Bool {
        guard let piece = pieceForPathway(path), let practice = path.piecePractice else { return false }
        return piece.fingerprint == practice.fingerprint
    }
    func savePiecePathway(_ path: LearningPathway) throws {
        guard pathwayCurrent(path) else {
            throw MusicError.invalid(
                "The score changed while the plan was being prepared. Make a new plan for the current music.")
        }
        var copy = learning
        copy.add(path)
        try commitLearning(copy)
    }
    func startPathwayTask(_ pathID: UUID, taskID: UUID) {
        guard let path = learning.pathways.first(where: { $0.id == pathID }), pathwayCurrent(path),
            path.piecePractice?.tasks.contains(where: { $0.id == taskID }) == true
        else {
            message = "This pathway refers to an earlier score. Create a fresh plan from the piece’s Learn tab."
            return
        }
        audio.stop()
        microphone.stop()
        midi.panic()
        pathwaySession = PathwayPracticeSession(pathwayID: pathID, taskID: taskID)
        learning.activePathwayID = pathID
        practicePage = .exercises
        destination = .practice
    }
    func returnToPiecePathway(_ path: LearningPathway) {
        audio.stop()
        microphone.stop()
        pathwaySession = nil
        learning.activePathwayID = path.id
        libraryLearning = true
        if let id = path.piecePractice?.pieceID { showLibraryPiece(id) }
    }
    func openPathwayPassage(reduced: Bool = false) {
        guard var session = pathwaySession, let path = currentPathway, let task = currentPathwayTask,
            let piece = pieceForPathway(path), pathwayCurrent(path)
        else {
            message = "The linked score has changed or is unavailable."
            return
        }
        let from = task.scope.fromBar - 1
        let through = reduced ? from : task.scope.throughBar - 1
        openLibraryPiece(piece, from: from, through: through, partID: task.scope.partID, practise: true)
        guard destination == .studies, let study = studies.active, study.partID == task.scope.partID,
            study.from == from, study.through == through
        else { return }
        session.studyID = study.id
        session.studyXML = study.document.originalXML
        session.practiceFrom = from
        session.practiceThrough = through
        session.reduced = reduced
        pathwaySession = session
    }
    var pathwayPassageMatches: Bool {
        guard let session = pathwaySession, let path = currentPathway, pathwayCurrent(path), let study = studies.active,
            let task = currentPathwayTask, task.kind == .passage
        else { return false }
        return study.id == session.studyID && study.document.originalXML == session.studyXML
            && study.partID == task.scope.partID && study.staff == nil && study.from == session.practiceFrom
            && study.through == session.practiceThrough
    }
    @discardableResult func recordPathwayResult(
        _ grade: ReviewGrade, input: PracticeInput, outcome: PracticeOutcome, assisted: Bool = false,
        played: [Int] = [], choice: String? = nil, expectedTaskID: UUID? = nil, ordinal: Int? = nil, now: Date = Date()
    ) throws -> Bool {
        guard let session = pathwaySession, let path = currentPathway, pathwayCurrent(path),
            let task = currentPathwayTask,
            let pathIndex = learning.pathways.firstIndex(where: { $0.id == path.id }),
            let taskIndex = path.piecePractice?.tasks.firstIndex(where: { $0.id == task.id })
        else {
            throw MusicError.invalid(
                "The score or pathway has changed. This result was not attached to a different piece.")
        }
        guard expectedTaskID == nil || expectedTaskID == task.id else {
            throw MusicError.invalid("This result belongs to an earlier exercise.")
        }
        let expectedInput: PracticeInput = task.kind == .passage ? .selfReport : task.kind == .chord ? .midi : .choice
        guard input == expectedInput else {
            throw MusicError.invalid("This result does not match the exercise’s input type.")
        }
        if input == .selfReport {
            guard pathwayPassageMatches else {
                throw MusicError.invalid("Return to the linked part and bars before recording how the passage felt.")
            }
        }
        let supported = assisted || (input == .selfReport && session.reduced)
        let effective: ReviewGrade = grade == .good && supported ? .supported : grade
        var copy = learning
        let changed = copy.pathways[pathIndex].piecePractice!.tasks[taskIndex].review.record(
            effective, episode: session.episode, input: input, now: now)
        var attempt = PracticeAttempt(
            sessionID: session.episode, activityID: "pathway:" + task.id.uuidString, title: task.title,
            skills: [task.skill], input: input, outcome: outcome,
            assisted: supported || (task.review.lastEpisode == session.episode && task.review.lastGrade != .good),
            ordinal: ordinal, selectedChoice: choice, played: played, target: task.target, date: now)
        attempt.pathwayID = path.id
        attempt.pathwayTaskID = task.id
        attempt.pieceID = path.piecePractice!.pieceID
        guard attempt.valid else { throw MusicError.invalid("This practice result is invalid.") }
        var snapshot = practiceState
        snapshot.learning = copy
        snapshot.journal.append(attempt)
        try commitPractice(snapshot)
        return changed
    }
    func skipPathwayTask() {
        guard let session = pathwaySession, let path = currentPathway, let task = currentPathwayTask else { return }
        var attempt = PracticeAttempt(
            sessionID: session.episode, activityID: "pathway:" + task.id.uuidString, title: task.title,
            skills: [task.skill], input: task.kind == .passage ? .selfReport : task.kind == .chord ? .midi : .choice,
            outcome: .skipped)
        attempt.pathwayID = path.id
        attempt.pathwayTaskID = task.id
        attempt.pieceID = path.piecePractice?.pieceID
        guard recordAttempt(attempt) else { return }
        nextPathwayTask()
    }
    func nextPathwayTask() {
        guard let path = currentPathway else {
            pathwaySession = nil
            return
        }
        if let task = path.piecePractice?.queue(excluding: pathwaySession?.taskID).first {
            startPathwayTask(path.id, taskID: task.id)
        } else {
            returnToPiecePathway(path)
        }
    }
    func piecePracticeEvidence(_ piece: LibraryPiece) -> String {
        let pathwayEvidence = learning.pathways.filter {
            $0.piecePractice?.pieceID == piece.id && $0.piecePractice?.fingerprint == piece.fingerprint
        }.prefix(5).map { $0.piecePractice!.evidence }.filter { !$0.isEmpty }.joined(separator: "\n").prefix(3500)
            .description
        return [
            pathwayEvidence, guidedEvidence(piece), timedEvidence(piece), changesEvidence(piece),
            timedChangesEvidence(piece), playAlongEvidence(piece), rehearsalEvidence(piece),
        ].filter { !$0.isEmpty }.joined(separator: "\n").prefix(7000).description
    }
}
