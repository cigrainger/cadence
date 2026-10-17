// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum Exercise: String, CaseIterable, Codable, Sendable {
    case functional = "Scale degrees"
    case intervals = "Sing intervals"
    case signatures = "Key signatures"
    case chords =
        "Chord quality"
    case triads = "Triad spelling"
    case rhythm = "Rhythm"
}

public struct PracticeQuestion: Sendable {
    public var id: String
    public var exercise: Exercise
    public var title: String
    public var detail: String
    public var choices: [String]
    public var answer: Int
    public var explanation: String
    public var audio: Score?
    public var target: Int?
    public var singingNotes: [SingingTone]?
    public var singingInterval: SingingInterval?
}

public struct ReviewCard: Codable, Equatable, Sendable {
    public var correct = 0
    public var misses = 0
    public var interval: Double = 0
    public var due = Date.distantPast
    public var schedule: ReviewSchedule?
    public init() {}
    public var review: ReviewSchedule {
        if let schedule { return schedule }
        // Legacy totals and due dates remain intact. Do not award growth at migration.
        var value = ReviewSchedule()
        value.encounters = correct + misses
        value.difficult = misses
        value.intervalDays = [0, 1, 3, 7, 14, 30, 60].last { Double($0) * 86400 <= interval } ?? 0
        value.due = due
        value.lastAdvance = interval >= 86400 ? due.addingTimeInterval(-interval) : nil
        return value
    }
}

public struct PracticeProgress: Codable, Equatable, Sendable {
    public var correct = 0
    public var attempts = 0
    public var xp = 0
    public var skills: [String: Int] = [:]
    public var days: [String] = []
    public var cards: [String: ReviewCard] = [:]
    public var guidedPassages: [String: GuidedPassageProgress]? = nil
    public var timedChanges: [String: TimedChangesProgress]? = nil
    public var playAlong: [String: PlayAlongProgress]? = nil
    public var timedPassages: [String: TimedPracticeProgress]? = nil
    public init() {}

    @discardableResult public mutating func record(
        _ question: PracticeQuestion, correct: Bool, firstTry: Bool, revealed: Bool, now: Date = Date(),
        episode: UUID = UUID(), input: PracticeInput = .choice
    ) -> Int {
        attempts += 1
        let reward = correct && !revealed ? (firstTry ? 10 : 4) : 0
        var card = cards[question.id] ?? ReviewCard()
        var schedule = card.review
        if correct {
            self.correct += 1
            xp += reward
            if !revealed { skills[question.exercise.rawValue, default: 0] += 1 }
            card.correct += 1
        } else {
            card.misses += 1
        }
        schedule.record(
            correct ? (firstTry && !revealed ? .good : .supported) : .again,
            episode: episode, input: input, now: now)
        card.schedule = schedule
        card.due = schedule.due ?? now
        // Keep the legacy mirror bounded even when the wall clock moves back.
        card.interval = min(60 * 86400, max(0, card.due.timeIntervalSince(now)))
        cards[question.id] = card
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let day = formatter.string(from: now)
        if !days.contains(day) { days.append(day) }
        return reward
    }

    public func dueCount(in questions: [PracticeQuestion], now: Date = Date()) -> Int {
        questions.filter {
            if let card = cards[$0.id] { return card.due <= now }
            return false
        }.count
    }

    public func next(in questions: [PracticeQuestion], avoiding id: String?, now: Date = Date()) -> PracticeQuestion? {
        let eligible = questions.filter { $0.id != id }
        let pool = eligible.isEmpty ? questions : eligible
        let queue = ReviewQueue.ordered(pool, now: now, review: { cards[$0.id]?.review ?? ReviewSchedule() }) {
            $0.id < $1.id
        }
        return queue.first ?? pool.min { (cards[$0.id]?.due ?? .distantPast) < (cards[$1.id]?.due ?? .distantPast) }
    }
    public func validated() throws -> Self {
        guard (playAlong?.count ?? 0) <= 256,
            playAlong?.allSatisfy({ key, value in
                value.latest.valid && key == value.latest.practiceID && value.review.valid
            }) ?? true
        else {
            throw MusicError.invalid("The play-along history contains invalid results.")
        }
        guard (timedChanges?.count ?? 0) <= 256,
            timedChanges?.allSatisfy({ key, value in
                value.latest.valid && key == value.latest.practiceID && value.review.valid
            }) ?? true
        else {
            throw MusicError.invalid("The chord timing history contains invalid results.")
        }
        guard (timedPassages?.count ?? 0) <= 256,
            timedPassages?.allSatisfy({ key, value in
                value.latest.valid && key == value.latest.practiceID && value.review.valid
            }) ?? true
        else {
            throw MusicError.invalid("The timed practice history contains invalid results.")
        }
        guard (guidedPassages?.count ?? 0) <= 256,
            guidedPassages?.allSatisfy({ key, value in
                key == value.latest.practiceID && value.latest.valid && value.review.valid
            }) ?? true
        else {
            throw MusicError.invalid("The guided passage history contains invalid results.")
        }
        guard (0...10_000_000).contains(attempts), correct >= 0, correct <= attempts, (0...1_000_000_000).contains(xp),
            cards.count <= 100000,
            days.count <= 100000, skills.count <= 1000, skills.values.allSatisfy({ (0...10_000_000).contains($0) }),
            cards.allSatisfy({ key, card in
                !key.isEmpty && key.count <= 300 && card.correct >= 0 && card.correct <= 1_000_000 && card.misses >= 0
                    && card.misses <= 1_000_000 && card.correct + card.misses <= 1_000_000 && card.interval.isFinite
                    && (0...60 * 86400).contains(card.interval) && card.due.timeIntervalSince1970.isFinite
                    && (card.schedule?.valid ?? true)
            })
        else { throw MusicError.invalid("This practice history contains invalid review data.") }
        return self
    }
}

public enum QuestionFactory {
    public static let rhythmValues: [[Double]] = [
        [1, 1, 1, 1], [0.5, 0.5, 1, 2], [1, 0.5, 0.5, 2], [0.5, 0.5, 0.5, 0.5, 2],
    ]
    public static let rhythmNames = [
        "Quarter · quarter · quarter · quarter", "Eighth · eighth · quarter · half", "Quarter · eighth · eighth · half",
        "Eighth · eighth · eighth · eighth · half",
    ]

    public static func deck(_ exercise: Exercise, root: Pitch, scale: Scale) -> [PracticeQuestion] {
        switch exercise {
        case .functional:
            // Functional hearing starts with an unambiguous major/minor tonal cadence.
            let family: Scale =
                [.minor, .harmonicMinor, .melodicMinor, .minorPentatonic, .blues].contains(scale) ? .minor : .major
            return (0..<7).map { degree in
                let target = 60 + root.pc + family.intervals[degree]
                let targetName = family.notes(root)[degree].name
                let triads = harmonize(root: root, scale: family)
                var notes: [ScoreNote] = []
                for (time, index) in [0, 3, 4, 0].enumerated() {
                    let base = 48 + root.pc + family.intervals[index]
                    // A major dominant establishes the leading tone in minor keys.
                    let intervals = family == .minor && index == 4 ? [0, 4, 7] : triads[index].quality.intervals
                    notes += intervals.map { ScoreNote(midi: base + $0, start: Double(time), duration: 0.8) }
                }
                notes.append(ScoreNote(midi: target, start: 5, duration: 1.25))
                return PracticeQuestion(
                    id: "degree:\(root.pc):\(family.rawValue):\(degree)", exercise: exercise,
                    title: "Where does this note belong?",
                    detail:
                        "Hear the cadence in \(root.name) \(family == .minor ? "minor" : "major"), then identify the last note.",
                    choices: family.formula.enumerated().map { $0.offset == 0 ? "1 · tonic" : $0.element },
                    answer: degree,
                    explanation:
                        "The target is \(targetName), degree \(family.formula[degree]) of \(root.name) \(family == .minor ? "minor" : "major"). Find the tonic, then sing your way to that degree.",
                    audio: Score(tempo: 105, notes: notes), target: target,
                    singingNotes: Solfege.notes(root: root, scale: family))
            }
        case .intervals:
            return IntervalSingingFactory.deck(root: root, scale: scale)
        case .signatures:
            return Pitch.fifths.flatMap { pitch in
                [false, true].map { minor in
                    let key = minor ? pitch.transposed(semitones: 9, steps: 5) : pitch
                    let count = pitch.majorFifths
                    var wrong = Array((-7...7).filter { $0 != count }.shuffled().prefix(3))
                    wrong.append(count)
                    wrong.shuffle()
                    return PracticeQuestion(
                        id: "signature:\(count):\(minor)", exercise: exercise,
                        title: "\(key.name) \(minor ? "minor" : "major")",
                        detail: "Which key signature belongs to this key?", choices: wrong.map(signature),
                        answer: wrong.firstIndex(of: count)!,
                        explanation:
                            "\(pitch.name) major and \(pitch.transposed(semitones:9,steps:5).name) minor share \(signature(count)). \(signatureNotes(count))"
                    )
                }
            }
        case .chords:
            let qualities: [ChordQuality] = [.major, .minor, .diminished, .augmented]
            return qualities.enumerated().map { index, quality in
                let base = 48 + root.pc
                return PracticeQuestion(
                    id: "quality:\(quality.rawValue):\(root.pc)", exercise: exercise,
                    title: "What kind of triad do you hear?", detail: "Listen to the space between the notes.",
                    choices: qualities.map(\.rawValue), answer: index,
                    explanation:
                        "This is \(root.name) \(quality.rawValue.lowercased()). Its semitone intervals from the root are \(quality.intervals.map(String.init).joined(separator:", ")).",
                    audio: Score(
                        tempo: 80, notes: quality.intervals.map { ScoreNote(midi: base + $0, start: 0, duration: 2) }))
            }
        case .triads:
            let qualities: [ChordQuality] = [.major, .minor, .diminished, .augmented]
            return qualities.map { quality in
                let choices = qualities.shuffled()
                return PracticeQuestion(
                    id: "spell:\(root.name):\(quality.rawValue)", exercise: exercise,
                    title: "Spell \(root.name)\(quality.symbol)", detail: "Which notes make this triad?",
                    choices: choices.map { $0.notes(root).map(\.name).joined(separator: " · ") },
                    answer: choices.firstIndex(of: quality)!,
                    explanation:
                        "\(root.name)\(quality.symbol) contains \(quality.notes(root).map(\.name).joined(separator:", ")). Build the 3rd and 5th above the root."
                )
            }
        case .rhythm:
            return rhythmValues.enumerated().map { index, values in
                var beat = 4.0
                var notes = (0..<4).map { ScoreNote(midi: $0 == 0 ? 84 : 79, start: Double($0), duration: 0.08) }
                for duration in values {
                    notes.append(ScoreNote(midi: 88, start: beat, duration: 0.12))
                    beat += duration
                }
                return PracticeQuestion(
                    id: "rhythm:\(index)", exercise: exercise, title: "Find the rhythm",
                    detail: "Four count-in clicks, then one bar in 4/4 at 80 bpm. Choose the pattern you hear.",
                    choices: rhythmNames, answer: index,
                    explanation:
                        "Durations in quarter note beats: \(values.map { String(format:"%g",$0) }.joined(separator:" · ")). Tap a steady beat as you listen.",
                    audio: Score(tempo: 80, notes: notes))
            }
        }
    }
    public static func signature(_ count: Int) -> String {
        count == 0 ? "No sharps or flats" : "\(abs(count)) \(count > 0 ? "sharp" : "flat")\(abs(count) == 1 ? "" : "s")"
    }
    public static func signatureNotes(_ count: Int) -> String {
        let order =
            count > 0 ? ["F♯", "C♯", "G♯", "D♯", "A♯", "E♯", "B♯"] : ["B♭", "E♭", "A♭", "D♭", "G♭", "C♭", "F♭"]
        return count == 0 ? "All notes are natural." : order.prefix(abs(count)).joined(separator: ", ")
    }
}
