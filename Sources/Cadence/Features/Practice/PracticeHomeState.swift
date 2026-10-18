// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

/// Navigation is transient. Practice results and resumable sessions remain in
/// their existing stores; the home screen never creates a second progress model.
enum PracticePage {
    case microphonePhrase, picking, home, exercises, adaptive, ear, scoreEar, groove, playAlong, rehearsal, triads,
        tension, reharm,
        songJourney
}

struct PracticeReviewItem: Identifiable {
    enum Target {
        case reharm(UUID, TheorySkill)
        case tension(UUID, TheorySkill)
        case triads(UUID)
        case picking(UUID)
        case microphonePhrase(String)
        case rehearsal(String)
        case playAlong(
            PlayAlongResult)
        case scoreEar(ScoreEarMaterial)
        case piece(UUID, UUID)
        case guided(GuidedPassageProgress)
        case timed(
            TimedPracticeResult)
        case changes(TimedChangesResult)
    }
    var id: String
    var title: String
    var context: String
    var review: ReviewSchedule
    var order = 0
    var target: Target
}

extension AppState {
    var homePathway: MusicalPathway? {
        let paths = (courses.musicalPathways ?? []).filter { $0.recipe == SmoothChangesRecipe.identifier }
        if let active = smoothPractice.active, active.phase != .summary {
            return paths.first { $0.id == active.pathwayID }
        }
        return paths.first { $0.id == musicalPathwaySelection } ?? paths.first
    }
    var canResumeAdaptive: Bool {
        guard let active = smoothPractice.active, let pathway = homePathway else { return false }
        return active.pathwayID == pathway.id && active.phase != .summary
    }
    func navigate(to destination: Destination) {
        if self.destination != destination { stopAllPlayback(keepingMetronome: true) }
        self.destination = destination
    }
    func showPracticeHome() {
        stopAllPlayback()
        showAdaptiveSession = false
        practicePage = selectedSongJourney == nil ? .home : .songJourney
        destination = .practice
    }
    func openPractice(_ exercise: Exercise = .intervals, chords: Bool = false) {
        audio.stop()
        microphone.stop()
        pathwaySession = nil
        rhythmReview = nil
        practiceMIDIExercise = chords
        practiceExercise = exercise
        practicePage = .exercises
        destination = .practice
    }
    func showPathways() {
        showAdaptiveSession = false
        musicalPathwayStep = nil
        destination = .courses
    }
    func showAdaptiveWorkspace(inPractice: Bool) throws {
        guard let active = smoothPractice.active,
            courses.musicalPathways?.contains(where: {
                $0.id == active.pathwayID && $0.recipe == SmoothChangesRecipe.identifier
            }) == true
        else {
            throw MusicError.invalid("This session’s pathway is unavailable. Open your courses to restore it.")
        }
        // Returning after a failed save must preserve the pending answer.
        audio.stop()
        microphone.stop()
        adaptiveInput.pause(held: midi.keyboard.downNotes)
        musicalPathwaySelection = active.pathwayID
        musicalPathwayStep = nil
        showAdaptiveSession = true
        adaptiveFromPractice = inPractice
        if inPractice {
            practicePage = .adaptive
            destination = .practice
        } else {
            destination = .courses
        }
    }
    func returnToCourse(_ location: CourseLocation) {
        if showAdaptiveSession, adaptiveFromPractice, let active = smoothPractice.active,
            courses.musicalPathways?.first(where: { $0.id == active.pathwayID })?.steps.contains(where: {
                $0.courseID == location.courseID && $0.lessonID == location.lessonID
            }) == true
        {
            do { try showAdaptiveWorkspace(inPractice: true) } catch { message = error.localizedDescription }
        } else {
            showCourse(location.courseID, lessonID: location.lessonID)
        }
    }
    func beginHomeSession() throws {
        guard let pathway = homePathway else { throw MusicError.invalid("Choose a pathway from your courses first.") }
        if canResumeAdaptive {
            try showAdaptiveWorkspace(inPractice: true)
        } else {
            try openAdaptiveSession(pathway.id, fromPractice: true)
        }
    }
    func practiceReviews(now: Date = Date()) -> [PracticeReviewItem] {
        let pieces = learning.pathways.filter { pathwayCurrent($0) && $0.piecePractice?.paused == false }.sorted {
            $0.createdAt < $1.createdAt
        }
        var items = pieces.flatMap { path in
            (path.piecePractice?.tasks ?? []).enumerated().sorted { a, b in
                a.element.stage == b.element.stage ? a.offset < b.offset : a.element.stage < b.element.stage
            }.map { _, task in
                PracticeReviewItem(
                    id: "piece:\(path.id):\(task.id)", title: task.title,
                    context: pieceForPathway(path)?.title ?? path.outline.title, review: task.review,
                    target: .piece(path.id, task.id))
            }
        }
        // These providers already reject changed/deleted scores and use the
        // canonical schedule. Reorder the combined queue with that same policy.
        items += guidedReviews(at: now).map {
            .init(
                id: "guided:" + $0.latest.practiceID, title: $0.latest.title,
                context: "Keyboard reading · bars \($0.latest.scope.from+1)–\($0.latest.scope.through+1)",
                review: $0.review, target: .guided($0))
        }
        items += timedReviews(at: now).map {
            .init(
                id: "timed:" + $0.latest.practiceID, title: $0.latest.plan.title,
                context: "Rhythm & time · \($0.latest.plan.tempo) bpm", review: $0.review, target: .timed($0.latest))
        }
        items += timedChangesReviews(at: now).map {
            .init(
                id: "changes:" + $0.latest.practiceID, title: $0.latest.plan.title,
                context: "Chord changes · \($0.latest.plan.tempo) bpm", review: $0.review, target: .changes($0.latest))
        }
        items += rehearsalReviews.map {
            .init(
                id: $0.key, title: $0.title, context: "Independent return · full score", review: $0.reviewSchedule,
                target: .rehearsal($0.key))
        }
        items += playAlongReviews.map {
            .init(
                id: $0.latest.practiceID, title: $0.latest.plan.material.title,
                context: "Play along · \($0.latest.plan.setup.tempo) bpm", review: $0.review,
                target: .playAlong($0.latest))
        }
        items += scoreEarLatest.compactMap { session in
            guard let material = session.opening.material, scoreEarCurrent(material),
                (try? session.projection().stage) == .complete
            else { return nil }
            return PracticeReviewItem(
                id: material.id, title: "Bring the melody back",
                context: (libraryPieces.first { $0.id == material.pieceID }?.title ?? material.title) + " · "
                    + material.label, review: scoreEarReview(material), target: .scoreEar(material))
        }
        items += microphonePhrases.sessions.filter {
            $0.baseline != nil && (try? validateMicrophonePhrase($0.sourcePlan)) != nil
        }.map { progress in
            var review = progress.review
            if let available = microphonePhrases.returnDate(progress.id) { review.due = available }
            return .init(
                id: "microphone:" + progress.id, title: "Bring the guitar phrase back",
                context: progress.material.title + " · Microphone", review: review,
                target: .microphonePhrase(progress.id))
        }
        items += pickingPractice.sessions.filter { $0.stage == .complete && pickingCurrent($0.material) }.map {
            .init(
                id: $0.key, title: $0.style.rawValue, context: $0.material.title + " · Picking return",
                review: $0.review, target: .picking($0.id))
        }
        items += triadPractice.sessions.filter { $0.stage == .complete && triadCurrent($0.material) }.map {
            .init(
                id: $0.material.id, title: "Triads across the neck",
                context: $0.material.title + " · " + $0.material.label, review: $0.review, target: .triads($0.id))
        }
        for session in tensionPractice.sessions where session.completed && tensionCurrent(session.source) {
            for skill in TheorySkill.allCases {
                if let review = session.reviews[skill.rawValue] {
                    items.append(
                        .init(
                            id: session.source.id + ":" + session.instrument.rawValue + ":" + skill.rawValue,
                            title: "Tension · " + skill.rawValue,
                            context: session.source.title + " · " + session.instrument.rawValue, review: review,
                            target: .tension(session.id, skill)))
                }
            }
        }
        for session in reharmPractice.sessions where session.completed && reharmCurrent(session.source) {
            for skill in TheorySkill.allCases {
                if let review = session.reviews[skill.rawValue] {
                    items.append(
                        .init(
                            id: session.source.id + ":" + session.instrument.rawValue + ":" + skill.rawValue,
                            title: "Reharmonise · " + skill.rawValue,
                            context: session.source.title + " · " + session.instrument.rawValue, review: review,
                            target: .reharm(session.id, skill)))
                }
            }
        }
        for index in items.indices { items[index].order = index }
        return ReviewQueue.ordered(items, now: now, review: { $0.review }, order: { $0.order < $1.order })
    }
    func openPracticeReview(_ item: PracticeReviewItem) {
        // Resolve again at click time: a stale home snapshot must not launch a
        // changed passage or a paused pathway.
        guard let current = practiceReviews().first(where: { $0.id == item.id }) else {
            message = "This review has changed. Choose from the refreshed practice home."
            return
        }
        switch current.target {
        case .reharm(let id, let skill):
            do { try resumeReharm(id, skill: skill) } catch { message = error.localizedDescription }
        case .tension(let id, let skill):
            do { try resumeTension(id, skill: skill) } catch { message = error.localizedDescription }
        case .microphonePhrase(let id):
            do { try resumeMicrophonePhrase(id, independent: true) } catch { message = error.localizedDescription }
        case .picking(let id):
            do { try resumePicking(id, independent: true) } catch { message = error.localizedDescription }
        case .triads(let id): do { try resumeTriads(id, restart: true) } catch { message = error.localizedDescription }
        case .rehearsal(let key):
            do {
                guard !rehearsalSession.timing.hasUnsavedResult else {
                    throw MusicError.invalid(
                        "Save or discard the pending piece-practice pass before starting a review.")
                }
                try updateRehearsal(key) { try $0.beginReview() }
                if let record = rehearsals.records[key],
                    let piece = libraryPieces.first(where: { $0.id == record.pieceID })
                {
                    openPieceRehearsal(piece, key: key)
                }
            } catch { message = error.localizedDescription }
        case .playAlong(let result): openPlayAlong(result.plan.material, setup: result.plan.setup)
        case .scoreEar(let material): do { try openScoreEar(material) } catch { message = error.localizedDescription }
        case .piece(let path, let task): startPathwayTask(path, taskID: task)
        case .guided(let progress): openGuidedReview(progress)
        case .timed(let result): openTimedReview(result)
        case .changes(let result): openTimedChangesReview(result)
        }
    }
    var homeComposition: LibraryPiece? {
        if let id = homePathway?.compositionID,
            let piece = libraryPieces.first(where: { $0.id == "score:" + id.uuidString })
        {
            return piece
        }
        return libraryPieces.filter { pieceRecord($0).kind == .composition }.sorted {
            (pieceRecord($0).lastOpened ?? pieceRecord($0).addedAt)
                > (pieceRecord($1).lastOpened ?? pieceRecord($1).addedAt)
        }.first
    }
}
