// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Original practice arrangements, grounded in two learner-owned sources.
/// These are teaching variations, never represented as page transcriptions.
public enum SmoothChangesRecipe {
    public static let identifier = "smooth-changes-v1"
    public struct Draft {
        public var courses: [CourseDefinition]
        public var scores: [EditorDocument]
        public var pathway: MusicalPathway
    }
    public static func make(
        songbook: CourseBook, jazzbook: CourseBook, inversions: Int, songwriting: Int, jazzPage: Int = 26
    ) throws -> Draft {
        guard songbook.isEPUB, !jazzbook.isEPUB, inversions > 0, songwriting > 0, inversions <= songbook.pageCount,
            songwriting < songbook.pageCount, jazzPage > 0, jazzPage < jazzbook.pageCount
        else {
            throw MusicError.invalid(
                "Choose the inversions and songwriting sections, and the opening two pages of Three-Note Voicings.")
        }
        let inv = CourseSourceAnchor(book: songbook, from: inversions, through: inversions)
        let jazz = CourseSourceAnchor(
            book: jazzbook, from: jazzPage, through: jazzPage + 1, printedLabel: "Three-Note Voicings")
        let write = CourseSourceAnchor(book: songbook, from: songwriting, through: songwriting + 1)
        let first = CourseLesson(
            title: "One chord, three shapes", source: inv, instrument: .piano,
            bookSummary:
                "The same three chord tones can be arranged with a different note at the bottom. The section connects these inversions to easier changes on the keyboard.",
            goal: "Find C major in three positions and hear what stays the same.",
            practice:
                "Cadence exercise: listen to the four bars, then play the right hand slowly. Name the lowest note of each shape. Try again without watching the keyboard diagram.",
            readyWhen: "You can find each shape and explain why all three are C major.",
            passage:
                "Cadence-written inversion study, inspired by the linked section. Octaves and whole-note rhythm are our arrangement, not a transcription of the diagram.",
            skills: [.harmony, .listening, .recall])
        let second = CourseLesson(
            title: "Connect C, F and G", source: inv, instrument: .piano,
            bookSummary: "Nearby inversions can make right-hand chord changes easier and more fluent.",
            goal: "Move through C–F–G–C while keeping the right hand in a small area.",
            practice:
                "Hear the complete phrase. Find the next shape before moving. Keep common notes where comfortable. Practise a difficult approach and landing together, then return to all four bars.",
            readyWhen: "You can keep a steady pulse through the changes at a tempo you choose.",
            passage:
                "Cadence-written close-position C–F–G–C study. Compare its movement with root-position chords. This is an added practice arrangement.",
            skills: [.harmony, .pulse, .expression], prerequisites: [first.id])
        let third = CourseLesson(
            title: "Follow the guide tones", source: jazz, instrument: .piano,
            bookSummary:
                "The opening pages use roots, thirds and sevenths to connect ii–V–I chords. A shared tone can stay while another voice moves by a semitone.",
            goal: "Hear and play the thirds and sevenths through Dm7–G7–Cmaj7.",
            practice:
                "Cadence exercise: play the upper staff first. Sing the moving note if useful. Listen to the bass in playback, then add it yourself without time pressure. The timed exercise assesses the upper staff only.",
            readyWhen: "You can describe which note moves at each change and find the two-note shapes.",
            passage:
                "Cadence-written guide-tone study in C, with a repeated tonic bar. Based on the idea in the linked opening pages; it is not an exact copy of a printed figure.",
            skills: [.harmony, .listening, .pulse])
        let fourth = CourseLesson(
            title: "Find it again in F", source: jazz, instrument: .piano,
            bookSummary:
                "The chapter suggests taking the progression through other keys and changing the arrangement of the upper voices.",
            goal: "Find the same guide-tone relationship in a different key.",
            practice:
                "Before listening, work out Gm7–C7–Fmaj7. Locate the thirds and sevenths, then check your proposal. This separate example helps us see what carries over from C.",
            readyWhen: "You can explain the relationship and play this example with less help.",
            passage:
                "Cadence-written transfer study in F. A different key and register; recorded separately from the study in C.",
            skills: [.harmony, .recall, .pulse], prerequisites: [third.id])
        let fifth = CourseLesson(
            title: "Write four bars of your own", source: write, kind: .explanation, instrument: .piano,
            bookSummary:
                "This section explores writing with a small set of chords and using them within a musical phrase.",
            goal: "Write and play a short phrase whose chord changes feel connected.",
            practice:
                "Choose C–F–G–C, a ii–V–I, or your own progression. Write four bars in Compose. Find nearby voicings, then choose a rhythm or top-note melody. Listen back and revise one transition. You can expand to eight bars when you want.",
            readyWhen:
                "You have a saved phrase and can describe one voicing choice and its effect. Creative choices are reflected on, not automatically graded.",
            skills: [.expression, .harmony, .pulse])
        var a = CourseDefinition(
            chapter: .init(
                title: "Inversions & close changes", source: inv,
                summary: "Rikky Rooksby's keyboard shapes become two small, original practice studies.",
                origin: "Cadence-authored pathway · source-linked paraphrases and original studies",
                lessons: [first, second]))
        var b = CourseDefinition(
            chapter: .init(
                title: "Guide tones & another key", source: jazz,
                summary: "Explore Levine's guide-tone idea, then carry it from C into F.",
                origin: "Cadence-authored pathway · source-linked paraphrases and original studies",
                lessons: [third, fourth]))
        let c = CourseDefinition(
            chapter: .init(
                title: "A phrase of your own", source: write,
                summary: "Bring the ideas into a small composition you can keep and revisit.",
                origin: "Cadence-authored composition invitation", lessons: [fifth]))
        let scores = try (0..<4).map { try score(index: $0) }
        a.exercises = zip(a.chapter.lessons, scores.prefix(2)).map { .init(lesson: $0.0, scoreID: $0.1.id) }
        b.exercises = zip(b.chapter.lessons, scores.suffix(2)).map { .init(lesson: $0.0, scoreID: $0.1.id) }
        let steps: [MusicalPathway.Step] = [
            .init(courseID: a.id, lessonID: first.id, title: first.title, role: .discover),
            .init(courseID: a.id, lessonID: second.id, title: second.title, role: .practise),
            .init(courseID: b.id, lessonID: third.id, title: third.title, role: .practise),
            .init(courseID: b.id, lessonID: fourth.id, title: fourth.title, role: .transfer),
            .init(courseID: c.id, lessonID: fifth.id, title: fifth.title, role: .compose),
        ]
        return Draft(
            courses: [a, b, c], scores: scores,
            pathway: .init(
                recipe: identifier, title: "Make chord changes sound smooth",
                goal: "Connect comfortable voicings, keep a pulse, and use the movement in a phrase of your own.",
                steps: steps))
    }
    public static func score(index: Int) throws -> EditorDocument {
        let names = ["One chord, three shapes", "Connect C, F and G", "Follow the guide tones", "Find it again in F"]
        let upper = [
            [[60, 64, 67], [64, 67, 72], [67, 72, 76], [60, 64, 67]],
            [[60, 64, 67], [60, 65, 69], [59, 62, 67], [60, 64, 67]], [[65, 72], [65, 71], [64, 71], [64, 71]],
            [[58, 65], [58, 64], [57, 64], [57, 64]],
        ]
        let roots = [[], [], [50, 43, 48, 48], [43, 48, 41, 41]]
        let chords = [
            ["C", "C/E", "C/G", "C"], ["C", "F", "G", "C"], ["Dm7", "G7", "Cmaj7", "Cmaj7"],
            ["Gm7", "C7", "Fmaj7", "Fmaj7"],
        ]
        guard (0..<4).contains(index) else { throw MusicError.invalid("This pathway study is unavailable.") }
        var events: [EditorEvent] = []
        for bar in 0..<4 {
            events.append(
                .init(
                    bar: bar, rhythm: .init(1920),
                    pitches: upper[index][bar].map { EditorPitch($0, spelling: Pitch.spelled($0, flats: index == 3)) }))
            events.append(
                .init(
                    bar: bar, staff: 2, rhythm: .init(1920),
                    pitches: roots[index].isEmpty ? [] : [EditorPitch(roots[index][bar])]))
        }
        var score = EditorDocument(title: names[index], instrument: .piano, events: events)
        score.tempo = 60
        score.fifths = index == 3 ? -1 : 0
        score.harmonies = try chords[index].enumerated().map {
            try .init(bar: $0.offset, symbol: ChordSymbol.parse($0.element))
        }
        return try score.validated()
    }
    public static func composition() throws -> EditorDocument {
        var score = EditorDocument(
            title: "My smooth changes", instrument: .piano,
            events: (0..<4).flatMap { bar in (1...2).map { EditorEvent(bar: bar, staff: $0, rhythm: .init(1920)) } })
        score.tempo = 60
        score.harmonies = try ["C", "F", "G", "C"].enumerated().map {
            try .init(bar: $0.offset, symbol: ChordSymbol.parse($0.element))
        }
        return try score.validated()
    }
}
