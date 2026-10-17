// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

extension AppState {
    var songJourneys: [SongJourney] { courses.songJourneys ?? [] }
    var selectedSongJourney: SongJourney? { songJourneys.first { $0.id == songJourneyID } ?? songJourneys.first }

    @discardableResult func startSongJourney(instrument: EditorInstrument, pieceID: String? = nil) throws -> UUID {
        guard songInput.pending == nil else {
            throw MusicError.invalid("Save or discard the pending opening answer before starting another pathway.")
        }
        if pieceID == nil,
            let existing = songJourneys.first(where: {
                $0.instrument == instrument && (try? validateSongJourney($0)) != nil
            })
        {
            openSongJourney(existing.id)
            return existing.id
        }
        var library = editor
        var exampleIDs: [String] = []
        func original(_ transfer: Bool) throws -> LibraryPiece {
            let suffix = (instrument == .piano ? 1 : 3) + (transfer ? 1 : 0)
            let id = UUID(uuidString: "988B8DAB-BC15-41DB-885C-00000000000\(suffix)")!
            exampleIDs.append("score:" + id.uuidString)
            if let existing = library.documents.first(where: { $0.id == id }) {
                return LibraryPiece(source: .score(existing))
            }
            var score = try SongJourneyExamples.score(instrument: instrument, transfer: transfer)
            score.id = id
            library.documents.append(score)
            return LibraryPiece(source: .score(score))
        }
        let primary: LibraryPiece
        if let pieceID {
            guard let piece = libraryPieces.first(where: { $0.id == pieceID }) else {
                throw MusicError.invalid("This piece is no longer in your library.")
            }
            if case .score(let score) = piece.source, score.instrument != instrument {
                throw MusicError.invalid("Choose the same instrument as this score.")
            }
            if case .study(let study) = piece.source {
                let expected: EditorInstrument = study.part.tabStaves.isEmpty ? .piano : .guitar
                guard expected == instrument else {
                    throw MusicError.invalid("Choose the same instrument as this part.")
                }
            }
            primary = piece
        } else {
            primary = try original(false)
        }
        let transfer = try original(true)
        func material(_ piece: LibraryPiece) throws -> ScoreEarMaterial {
            let part: String
            switch piece.source {
            case .score: part = "P1"
            case .study(let study): part = study.partID
            }
            return try ScoreEarMaterial(
                piece: piece, scope: .init(fromBar: 1, throughBar: 4, partID: part, partName: "Melody"), staff: 1,
                voice: "1")
        }
        let journey = SongJourney(
            material: try material(primary), transfer: try material(transfer), instrument: instrument)
        guard journey.valid else {
            throw MusicError.invalid(
                "Choose four reviewed 4/4 bars with one melodic voice and written chord symbols. The full piece stays in the library."
            )
        }
        // Saving the small original examples first is repeat-safe: their fixed IDs
        // avoid duplicates if the subsequent course commit needs another attempt.
        try libraryWorkspace.commitScores(library)
        var notes = notebook
        notes.reconcile(libraryPieces)
        for id in exampleIDs where notebook.records[id] == nil {
            notes.records[id]?.kind = .example
            notes.records[id]?.composer = "Cadence"
        }
        try libraryWorkspace.commitNotebook(notes)
        var copy = courses
        if copy.songJourneys == nil { copy.songJourneys = [] }
        copy.songJourneys!.append(journey)
        try commitCourses(copy)
        openSongJourney(journey.id)
        return journey.id
    }
    func openSongJourney(_ id: UUID) {
        guard songInput.pending == nil || songInput.pending?.journey.id == id else {
            message = "Save or discard the pending opening answer before switching pathways."
            return
        }
        guard songJourneys.contains(where: { $0.id == id }) else {
            message = "This pathway is no longer available."
            return
        }
        stopAllPlayback()
        songJourneyID = id
        showAdaptiveSession = false
        practicePage = .songJourney
        destination = .practice
    }
    func validateSongJourney(_ journey: SongJourney) throws {
        guard journey.valid, songJourneys.contains(where: { $0.sameContent(as: journey) }),
            scoreEarCurrent(journey.material), scoreEarCurrent(journey.transfer)
        else {
            throw MusicError.invalid(
                "A source piece changed or needs review. Your earlier results are kept. Start a fresh pathway from the reviewed music."
            )
        }
    }
    func songOpening(_ journey: SongJourney) -> SongLessonEvidence {
        .init(attempts: journal.attempts.filter { $0.activityID == journey.openingID && $0.pathwayID == journey.id })
    }
    func songEvidence(_ journey: SongJourney, now: Date = Date()) -> [SongLesson: SongLessonEvidence] {
        guard (try? validateSongJourney(journey)) != nil else { return [:] }
        let primary = journal.attempts.filter {
            $0.pieceID == journey.material.pieceID && $0.scoreFingerprint == journey.material.fingerprint
        }
        let hearingIDs = [PracticeInput.singing, .midi].map { EarPhrase(material: journey.material).activity($0) }
        let hearing = primary.filter { hearingIDs.contains($0.activityID) }
        let changesPlan = try? songChanges(journey)
        let prefix = changesPlan.map { $0.id + ":" }
        let changes = primary.filter { attempt in prefix.map { attempt.activityID.hasPrefix($0) } ?? false }
        let plays = (history.playAlong ?? [:]).values.filter { $0.latest.plan.material.id == journey.material.id }.map(
            \.latest)
        let playIDs = Set(plays.map { $0.pass.id })
        let groove = primary.filter { playIDs.contains($0.id) }
        let returnIDs = Set(
            (history.playAlong ?? [:]).values.filter { $0.latest.plan.material.id == journey.transfer.id }.map {
                $0.latest.pass.id
            })
        let earliest = songReturnDate(journey)
        let independent = journal.attempts.filter {
            returnIDs.contains($0.id) && $0.pieceID == journey.transfer.pieceID
                && $0.scoreFingerprint == journey.transfer.fingerprint && $0.date >= earliest
        }
        let composition = editor.documents.first { $0.id == journey.compositionID }
        let latestChangeSession = changes.max { $0.date < $1.date }?.sessionID
        let fullChanges =
            changesPlan.map { plan in
                let episode = changes.filter { $0.sessionID == latestChangeSession }
                let checked = episode.filter { $0.outcome == .correct && !$0.assisted }
                let expected = Set(
                    plan.playableIndices.map { plan.id + ":" + ChangesMode.complete.rawValue + ":\($0)" })
                return expected.isSubset(of: Set(checked.map(\.activityID)))
                    && !episode.contains { $0.assisted || $0.outcome == .incorrect }
            } ?? false
        return [
            .hear: .init(attempts: hearing), .changes: .init(attempts: changes, complete: fullChanges),
            .groove: .init(attempts: groove),
            .arrange: .init(hasArtifact: composition.map { $0.responseSource?.isFinished($0) == true } ?? false),
            .independent: .init(attempts: independent),
        ]
    }
    func songChanges(_ journey: SongJourney) throws -> ChangesPlan {
        guard let piece = libraryPieces.first(where: { $0.id == journey.material.pieceID }) else {
            throw MusicError.invalid("The source piece is unavailable.")
        }
        return try ChangesSource(
            piece: piece, from: journey.material.scope.fromBar - 1, through: journey.material.scope.throughBar - 1,
            partID: journey.material.scope.partID
        ).plan(staff: journey.material.harmonyStaff)
    }
    func songReturnDate(_ journey: SongJourney) -> Date {
        let lastPractice =
            journal.attempts.filter {
                $0.pieceID == journey.material.pieceID && $0.scoreFingerprint == journey.material.fingerprint
                    && $0.input != .selfReport && $0.outcome != .skipped
            }.map(\.date).max() ?? journey.created
        let creation =
            editor.documents.first { $0.id == journey.compositionID }?.responseSource?.savedAt ?? journey.created
        return max(max(lastPractice, creation), journey.created).addingTimeInterval(86400)
    }
    func songSession(_ journey: SongJourney, now: Date = Date()) -> [SongSessionItem] {
        guard (try? validateSongJourney(journey)) != nil else { return [] }
        let evidence = songEvidence(journey, now: now)
        let returns = (history.playAlong ?? [:]).values.filter { $0.latest.plan.material.id == journey.transfer.id }
        // Keep each activity's schedule, but recommend from the most recent
        // assessment. An old guided card must not override a newer clean return.
        let latestReturn = returns.max { $0.latest.pass.date < $1.latest.pass.date }
        let next = latestReturn?.review.due ?? songReturnDate(journey)
        let hasPractised =
            [SongLesson.hear, .changes, .groove].contains { lesson in
                evidence[lesson]?.attempts.contains { $0.input != .selfReport && $0.outcome != .skipped } == true
            }
            || evidence[.arrange]?.hasArtifact == true
        return SongSessionPlanner.session(
            minutes: journey.minutes, opening: songOpening(journey), evidence: evidence,
            independentDue: hasPractised && now >= max(songReturnDate(journey), next))
    }
    func setSongMinutes(_ minutes: Int, journey: SongJourney) throws {
        var copy = courses
        guard let i = copy.songJourneys?.firstIndex(where: { $0.id == journey.id }) else {
            throw MusicError.invalid("This pathway changed.")
        }
        copy.songJourneys![i].minutes = minutes
        try commitCourses(copy)
    }
    func openSongActivity(_ lesson: SongLesson, journey: SongJourney) throws {
        try validateSongJourney(journey)
        songJourneyID = journey.id
        songLesson = lesson
        switch lesson {
        case .hear: try openScoreEar(journey.material)
        case .changes: openChanges(try songChanges(journey))
        case .groove: openPlayAlong(journey.material)
        case .arrange:
            if !editor.documents.contains(where: { $0.id == journey.compositionID }) {
                guard let piece = libraryPieces.first(where: { $0.id == journey.material.pieceID }) else {
                    throw MusicError.invalid("Open the source piece first.")
                }
                try libraryWorkspace.addComposition(journey.arrangement(piece: piece))
            }
            returnToCompose(journey.compositionID)
        case .independent:
            var setup = PlayAlongSetup()
            setup.guide = false
            setup.piano = false
            setup.tempo = min(160, max(50, Int(journey.transfer.tempo)))
            openPlayAlong(journey.transfer, setup: setup)
        }
    }
    func saveSongOpening(
        _ journey: SongJourney, notes: [Int], input: PracticeInput, assisted: Bool, verifiedFrom: [Int]?, id: UUID,
        now: Date = Date()
    ) throws {
        try validateSongJourney(journey)
        guard [.midi, .choice].contains(input), notes.count <= 128, notes.allSatisfy({ (0...127).contains($0) }),
            !notes.isEmpty, input != .midi || verifiedFrom == journey.openingPrompt.from
        else { throw MusicError.invalid("Check the starting shape before submitting the next chord.") }
        if journal.attempts.contains(where: { $0.id == id }) { return }
        let previous = songOpening(journey).attempts
        var attempt = PracticeAttempt(
            sessionID: journey.id, activityID: journey.openingID, title: "Opening check · C → F",
            skills: ["Smooth chord changes"], input: input,
            outcome: journey.openingPrompt.judge(notes).correct ? .correct : .incorrect,
            assisted: assisted || !previous.isEmpty,
            ordinal: previous.count + 1, played: notes, date: now)
        attempt.id = id
        attempt.pathwayID = journey.id
        try practiceWorkspace.record(attempt)
    }
    func songExplanation(_ journey: SongJourney) -> SongLessonEvidence {
        .init(
            attempts: journal.attempts.filter { $0.activityID == journey.explanationID && $0.pathwayID == journey.id })
    }
    func saveSongExplanation(_ journey: SongJourney, answer: Int, id: UUID = UUID()) throws {
        try validateSongJourney(journey)
        guard [0, 4, 7].contains(answer) else { throw MusicError.invalid("Choose one of the starting chord's notes.") }
        if journal.attempts.contains(where: { $0.id == id }) { return }
        let previous = songExplanation(journey).attempts
        var attempt = PracticeAttempt(
            sessionID: journey.id, activityID: journey.explanationID,
            title: "Name the common tone · C major to F major", skills: ["Explaining harmony"], input: .choice,
            outcome: answer == 0 ? .correct : .incorrect, assisted: !previous.isEmpty,
            ordinal: previous.count + 1, selectedChoice: Pitch.spelled(answer).name, expectedChoice: "C")
        attempt.id = id
        attempt.pathwayID = journey.id
        try practiceWorkspace.record(attempt)
    }
    func coachForSong(_ journey: SongJourney, lesson: SongLesson) {
        stopAllPlayback()
        contextCoach.open(
            songCoachContext(journey, lesson: lesson),
            prompt:
                "Help me make a song my own on \(journey.instrument.rawValue). Today: \(lesson.title). Suggest one useful next step toward my eight-bar arrangement, with an easier alternative. Keep hearing, explaining, playing and creating separate."
        )
    }
}
