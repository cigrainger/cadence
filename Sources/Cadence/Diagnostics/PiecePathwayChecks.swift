// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

@MainActor enum PiecePathwayDiagnostics { static var checks: [String: Bool] = [:] }
@MainActor enum PiecePathwayChecks {
    static func preview(state: AppState) throws {
        try LibraryChecks.preview(state: state)
        let score: EditorDocument
        if CommandLine.arguments.contains("--piece-midi") {
            score = .pianoExample
            state.editor.documents.append(score)
        } else {
            score = state.editor.documents.first { $0.title.contains("Quiet steps") } ?? state.editor.active
        }
        let piece = LibraryPiece(source: .score(score))
        let snap = try PieceSnapshot(piece: piece, from: 0, through: 3)
        var path = try PiecePathwayFactory.make(
            piece: piece, snapshot: snap, record: state.pieceRecord(piece), profile: state.learning.profile)
        if let i = path.piecePractice?.tasks.firstIndex(where: { $0.kind == .rhythm }) {
            path.piecePractice!.tasks[i].review.record(
                .again, episode: UUID(), input: .choice, now: Date().addingTimeInterval(-1800))
        }
        if let i = path.piecePractice?.tasks.firstIndex(where: { $0.kind == .signature }) {
            path.piecePractice!.tasks[i].review.record(.good, episode: UUID(), input: .choice, now: Date())
        }
        try state.savePiecePathway(path)
        state.librarySelection = piece.id
        state.libraryLearning = true
        state.destination = .library
        PiecePathwayDiagnostics.checks["piecePlanHasLocalExercises"] = path.piecePractice!.tasks.count >= 5
        PiecePathwayDiagnostics.checks["difficultTaskReturnsFirst"] = path.piecePractice!.queue().first?.kind == .rhythm
        if CommandLine.arguments.contains("--piece-brief") {
            state.learning.pathways = []
            state.learning.activePathwayID = nil
        }
        if CommandLine.arguments.contains("--piece-queue") {
            state.practicePage = .exercises
            state.destination = .practice
        }
        if CommandLine.arguments.contains("--piece-exercise"),
            let task = path.piecePractice!.tasks.first(where: { $0.kind == .interval })
        {
            state.startPathwayTask(path.id, taskID: task.id)
        }
        if CommandLine.arguments.contains("--piece-passage"),
            let task = path.piecePractice!.tasks.first(where: { $0.kind == .passage })
        {
            state.startPathwayTask(path.id, taskID: task.id)
            state.openPathwayPassage(reduced: true)
        }
        if CommandLine.arguments.contains("--piece-midi"),
            let task = path.piecePractice!.tasks.first(where: { $0.kind == .chord })
        {
            state.startPathwayTask(path.id, taskID: task.id)
        }
        if CommandLine.arguments.contains("--piece-stale"),
            let index = state.editor.documents.firstIndex(where: { $0.id == score.id })
        {
            try state.editor.documents[index].setPitch(score.events[0].id, midi: 61)
        }
    }
    static func verify(directory: URL) throws -> [String: Bool] {
        var checks: [String: Bool] = [:]
        let state = AppState(storageOverride: directory)
        let piece = LibraryPiece(source: .score(state.editor.active))
        let snap = try PieceSnapshot(piece: piece, from: 0, through: 3)
        let path = try PiecePathwayFactory.make(
            piece: piece, snapshot: snap, record: state.pieceRecord(piece), profile: state.learning.profile)
        try state.savePiecePathway(path)
        state.save()
        let reopened = AppState(storageOverride: directory)
        checks["pathwaySavedWithPiece"] = reopened.learning.pathways.first?.piecePractice?.pieceID == piece.id
        checks["pathwayAndLegacyDataReopen"] =
            reopened.learning == state.learning && reopened.editor.documents == state.editor.documents
        let question = path.piecePractice!.tasks.first { $0.kind == .signature }!
        state.startPathwayTask(path.id, taskID: question.id)
        checks["taskStartsInPractice"] = state.destination == .practice && state.currentPathwayTask?.id == question.id
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try state.recordPathwayResult(.again, input: .choice, outcome: .incorrect, now: now)
        try state.recordPathwayResult(.good, input: .choice, outcome: .correct, now: now.addingTimeInterval(10))
        checks["retriesDoNotAdvanceSchedule"] =
            state.currentPathwayTask?.review.encounters == 1
            && state.currentPathwayTask?.review.due == now.addingTimeInterval(600)
        do {
            try state.recordPathwayResult(.good, input: .choice, outcome: .correct, expectedTaskID: UUID())
            checks["lateResultCannotAttachToNewTask"] = false
        } catch { checks["lateResultCannotAttachToNewTask"] = true }
        do {
            try state.recordPathwayResult(.good, input: .selfReport, outcome: .correct)
            checks["selfReportCannotGradeAQuiz"] = false
        } catch { checks["selfReportCannotGradeAQuiz"] = true }
        checks["attemptLinkedToPieceAndTask"] =
            state.journal.attempts.last?.pieceID == piece.id
            && state.journal.attempts.last?.pathwayTaskID == question.id
        let afterAnswer = AppState(storageOverride: directory)
        checks["reviewSavedImmediately"] =
            afterAnswer.learning.pathways.first?.piecePractice?.tasks.first { $0.id == question.id }?.review.encounters
            == 1
        let untouched = path.piecePractice!.tasks.first { $0.kind == .reading }!
        state.startPathwayTask(path.id, taskID: untouched.id)
        state.skipPathwayTask()
        checks["skipDoesNotPenalise"] =
            state.learning.pathways.first?.piecePractice?.tasks.first { $0.id == untouched.id }?.review.encounters == 0
        let passage = path.piecePractice!.tasks.first { $0.kind == .passage }!
        state.startPathwayTask(path.id, taskID: passage.id)
        state.openPathwayPassage(reduced: true)
        checks["passageOpensExactSource"] =
            state.pathwayPassageMatches && state.studies.active?.from == passage.scope.fromBar - 1
            && state.studies.active?.through == passage.scope.fromBar - 1
        try state.recordPathwayResult(.good, input: .selfReport, outcome: .correct, now: now)
        checks["smallerPassageCountsAsSupported"] =
            state.currentPathwayTask?.review.lastGrade == .supported
            && state.currentPathwayTask?.review.lastInput == .selfReport
        if let id = state.studies.active?.id { state.editStudy(id) { $0.select(from: 1, through: 2) } }
        do {
            try state.recordPathwayResult(.good, input: .selfReport, outcome: .correct)
            checks["changedPassageCannotBeMisattributed"] = false
        } catch { checks["changedPassageCannotBeMisattributed"] = true }
        state.startPathwayTask(path.id, taskID: question.id)
        let url = directory.appendingPathComponent("practice-state.json")
        let saved = try Data(contentsOf: url)
        let before = state.learning
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        do {
            try state.recordPathwayResult(.good, input: .choice, outcome: .correct, now: now.addingTimeInterval(86400))
            checks["failedReviewSaveLeavesMemoryUnchanged"] = false
        } catch { checks["failedReviewSaveLeavesMemoryUnchanged"] = state.learning == before }
        try FileManager.default.removeItem(at: url)
        try saved.write(to: url, options: .atomic)
        try state.recordPathwayResult(.good, input: .choice, outcome: .correct, now: now.addingTimeInterval(86400))
        checks["reviewCanBeSavedAgain"] = state.currentPathwayTask?.review.intervalDays == 1
        try state.editor.documents[0].setPitch(state.editor.documents[0].events[0].id, midi: 61)
        do {
            try state.recordPathwayResult(.good, input: .choice, outcome: .correct)
            checks["editedScoreRejectsOldResults"] = false
        } catch { checks["editedScoreRejectsOldResults"] = true }
        checks["stalePlanHistoryPreserved"] =
            state.learning.pathways.first?.piecePractice?.tasks.first?.review.encounters ?? 0 > 0
        let damaged = Data("{damaged-learning}".utf8)
        try damaged.write(to: url)
        let blocked = AppState(storageOverride: directory)
        blocked.save()
        let preserved = try Data(contentsOf: url)
        checks["damagedPathwaysPreserved"] = blocked.learningStorageError != nil && preserved == damaged
        do {
            try blocked.savePiecePathway(path)
            checks["damagedPathwaysBlockNewPlan"] = false
        } catch {
            checks["damagedPathwaysBlockNewPlan"] = true
        }
        try saved.write(to: url, options: .atomic)
        for s in [state, reopened, afterAnswer, blocked] { s.midi.shutdown() }
        return checks
    }
}
