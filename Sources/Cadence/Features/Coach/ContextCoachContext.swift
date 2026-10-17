// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import MusicCore

extension AppState {
    var currentCoachContext: CoachContext {
        if destination == .editor {
            let piece = LibraryPiece(source: .score(editor.active))
            let location = editorLocations[editor.active.id]
            let from =
                editor.active.events.first { $0.id == location?.selectedID }?.bar ?? location?.from
                ?? editorPassageFocus?.from ?? 0
            if let location, !location.wholePiece {
                return pieceCoachContext(piece, from: location.from, through: location.through)
            }
            return pieceCoachContext(piece, from: from)
        }
        if destination == .studies, let study = studies.active {
            let piece = libraryPieces.first {
                $0.id == study.sourceEditor.map { "score:" + $0.scoreID.uuidString }
                    || $0.id == "study:" + study.id.uuidString
            }
            if let piece {
                return pieceCoachContext(piece, from: study.from, through: study.through, partID: study.partID)
            }
            return CoachContext(
                id: "study:" + study.id.uuidString, title: study.document.title,
                subtitle: study.passageLabel, reference: guidedReference(study).context)
        }
        if destination == .library,
            let piece = libraryPieces.first(where: { $0.id == librarySelection }) ?? libraryPieces.first
        {
            let location = libraryBrowser.locations[piece.id]
            return pieceCoachContext(
                piece, from: (location?.from ?? 1) - 1,
                through: (location?.through ?? 4) - 1,
                partID: location?.partID.isEmpty == false ? location?.partID : nil)
        }
        if destination == .practice, practicePage == .songJourney, let journey = selectedSongJourney {
            return songCoachContext(journey, lesson: songLesson ?? .hear)
        }
        if destination == .practice, let context = activityCoachContext { return context }
        if destination == .books,
            let course = courses.courses.first(where: { $0.id == courseSelection }) ?? courses.courses.first
        {
            let lesson = course.chapter.lessons.first { $0.id == courseLessonSelection } ?? course.chapter.lessons.first
            return CoachContext(
                id: "chapter:" + course.id.uuidString + ":" + String(course.chapter.revision) + ":"
                    + (lesson?.id.uuidString ?? "overview"),
                title: course.chapter.title, subtitle: lesson?.title ?? "Book chapter",
                reference:
                    "Reviewed chapter: \(course.chapter.reviewed). Supplied summary: \(course.chapter.summary). Lesson: \(lesson?.title ?? "None"). Goal: \(lesson?.goal ?? "Explore the chapter"). Practice: \(lesson?.practice ?? ""). The original book is not included. Do not claim to have read it."
            )
        }
        if destination == .courses, let path = selectedMusicalPathway {
            return CoachContext(
                id: "course:" + path.id.uuidString, title: path.title,
                subtitle: "Musical pathway",
                reference: path.goal + "\n" + path.steps.map(\.title).joined(separator: "; "))
        }
        if destination == .plans, let path = learning.activePathway {
            return CoachContext(
                id: "plan:" + path.id.uuidString, title: path.outline.title,
                subtitle: "Personal learning plan", reference: path.coachContext)
        }
        let reference = context + "\nWorkspace: " + workspace.rawValue + ". Activity: " + destination.tabTitle
        return CoachContext(
            id: "theory:" + CourseBook.digest(Data(reference.utf8)),
            title: destination == .practice ? "Your practice" : destination.tabTitle,
            subtitle: root.name + " " + scale.rawValue, reference: reference)
    }
    func pieceCoachContext(_ piece: LibraryPiece, from: Int = 0, through: Int? = nil, partID: String? = nil)
        -> CoachContext
    {
        let bars: Int
        if case .study(let study) = piece.source {
            bars = study.document.parts.first { $0.id == (partID ?? study.partID) }?.measures.count ?? piece.bars
        } else {
            bars = piece.bars
        }
        let first = max(0, min(bars - 1, from))
        let last = max(first, min(bars - 1, min(first + 15, through ?? first + 3)))
        let snapshot = try? PieceSnapshot(piece: piece, from: first, through: last, partID: partID)
        return CoachContext(
            id: piece.id + ":" + piece.fingerprint + ":\(partID ?? "P1"):\(first)-\(last)", title: piece.title,
            subtitle: "Bars \(first + 1)–\(last + 1) · " + (snapshot?.scope.partName ?? piece.instrument),
            reference: snapshot?.context
                ?? "Title: \(piece.title). This score's notes are unavailable; ask the learner for a supported passage.",
            snapshot: snapshot)
    }
    private var activityCoachContext: CoachContext? {
        var source: (pieceID: String, from: Int, through: Int, partID: String?, title: String)?
        switch practicePage {
        case .scoreEar:
            if let material = scoreEarPractice.active?.opening.material {
                source = (
                    material.pieceID, material.scope.fromBar - 1, material.scope.throughBar - 1,
                    material.scope.partID, "Hear, imagine, sing and play"
                )
            }
        case .playAlong:
            if let material = playAlongMaterial {
                source = (
                    material.pieceID, material.scope.fromBar - 1, material.scope.throughBar - 1,
                    material.scope.partID, "Play along with the score"
                )
            }
        case .rehearsal:
            if let id = rehearsalPieceID {
                let scope = rehearsalSession.sourcePlan?.source?.scope
                source = (id, scope?.from ?? 0, scope?.through ?? 3, scope?.partID, "Practise this piece")
            }
        case .triads:
            if let material = triadPractice.active?.material {
                source = (
                    material.pieceID, material.scope.from, material.scope.through, material.scope.partID,
                    "Triads across the neck"
                )
            }
        case .tension:
            if let material = tensionPractice.active?.source {
                source = (
                    material.pieceID, material.scope.from, material.scope.through, material.scope.partID,
                    "Create and resolve tension"
                )
            }
        case .reharm:
            if let material = reharmPractice.active?.source {
                source = (
                    material.pieceID, material.scope.from, material.scope.through, material.scope.partID,
                    "Reharmonise and improvise"
                )
            }
        default: break
        }
        guard let source, let piece = libraryPieces.first(where: { $0.id == source.pieceID }) else { return nil }
        var context = pieceCoachContext(piece, from: source.from, through: source.through, partID: source.partID)
        context.id = source.title + ":" + context.id
        context.subtitle = source.title + " · " + context.subtitle
        context.reference +=
            "\nActivity: \(source.title). This is the current score version; it does not prove what the learner heard or played. Ask about the attempt rather than inventing performance feedback."
        return context
    }
    func songCoachContext(_ journey: SongJourney, lesson: SongLesson) -> CoachContext {
        let material = lesson == .independent ? journey.transfer : journey.material
        let piece = libraryPieces.first { $0.id == material.pieceID }
        var value =
            piece.map {
                pieceCoachContext(
                    $0, from: material.scope.fromBar - 1, through: material.scope.throughBar - 1,
                    partID: material.scope.partID)
            }
            ?? CoachContext(id: journey.id.uuidString, title: material.title, subtitle: material.label, reference: "")
        value.id = "journey:" + journey.id.uuidString + ":" + lesson.rawValue + ":" + value.id
        value.title = "Make a song your own"
        value.subtitle = lesson.title + " · " + material.title
        value.reference +=
            "\nGoal: \(lesson.goal). Instrument: \(journey.instrument.rawValue). Recorded evidence: "
            + SongLesson.allCases.map { $0.title + ": " + (songEvidence(journey)[$0]?.label ?? "No observations") }
            .joined(separator: "; ")
            + ". Hearing, explaining, playing and creating are separate. Do not infer technique, mastery or artistic quality from limited observations."
        return value
    }
    func openContextCoach() {
        stopAllPlayback()
        contextCoach.open(currentCoachContext)
    }
    func sendContextQuestion() {
        guard !isPreview else {
            contextCoach.reply.error = "Preview mode never sends a model request."
            return
        }
        do {
            let key = try aiSettings.requestKey()
            contextCoach.send(apiKey: key, model: aiSettings.model) { [weak self] reply in
                guard let self else { throw MusicError.invalid("The workspace is no longer available.") }
                try self.saveContextReply(reply)
            }
        } catch { contextCoach.reply.error = error.localizedDescription }
    }
    func saveContextReply(_ reply: ContextCoachReply) throws {
        guard let snapshot = reply.context.snapshot, let exchange = reply.exchange else { return }
        guard libraryPieces.contains(where: { $0.id == snapshot.pieceID }) else {
            throw MusicError.invalid(
                "The original piece was removed. The reply is kept here and has not been attached to another piece.")
        }
        try changePiece(snapshot.pieceID) { record in
            if !record.conversation.contains(where: { $0.id == exchange.id }) { record.conversation.append(exchange) }
            record.conversation = Array(record.conversation.suffix(24))
        }
    }
}
