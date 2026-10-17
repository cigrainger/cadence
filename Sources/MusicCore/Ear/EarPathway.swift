// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Original, bounded phrases. The recipe is stored, never a model-generated answer key.
public struct EarPhrase: Codable, Equatable, Sendable {
    public var recipe: Int
    public var tonic: Int
    public var material: ScoreEarMaterial?
    public init(material: ScoreEarMaterial) {
        self.material = material
        recipe = 0
        tonic = material.referenceTonic
    }
    public init(recipe: Int = 0, tonic: Int = 60) {
        self.recipe = recipe
        self.tonic = tonic
    }
    public static let patterns = [[1, 2, 1], [1, 3, 2, 1], [1, 3, 5], [5, 4, 3], [1, 1, 2, 1], [3, 2, 5, 1]]
    public var valid: Bool {
        if let material { return material.valid && recipe == 0 && tonic == material.referenceTonic }
        return Self.patterns.indices.contains(recipe) && [48, 50, 53, 55, 60, 62, 65, 67].contains(tonic)
    }
    public var degrees: [Int] { material?.tones.map(\.degree) ?? (valid ? Self.patterns[recipe] : []) }
    public var notes: [Int] { material?.melody.map(\.midi) ?? degrees.map { tonic + [0, 2, 4, 5, 7, 9, 11][$0 - 1] } }
    public var solfege: [String] {
        material?.tones.map(\.solfege) ?? degrees.map { Solfege.syllable(degree: $0, alteration: 0) }
    }
    public var key: String {
        if let material { return material.tonic.name + (material.minor ? " minor · Do-based" : " major") }
        return Pitch.spelled(tonic).name + " major"
    }
    public var title: String {
        if let material { return String((material.title + " · " + material.label).prefix(500)) }
        return "Phrase \(recipe+1) · \(key)"
    }
    public func activity(_ input: PracticeInput) -> String {
        if let material { return material.id + ":" + input.rawValue }
        return "ear:v1:\(recipe):\(tonic):\(input.rawValue)"
    }
    public var score: Score {
        if let material {
            return Score(
                title: title, tempo: material.tempo,
                notes: [ScoreNote(midi: tonic, start: 0, duration: 1)]
                    + material.melody.map { note in
                        var n = note
                        n.start += 2
                        return n
                    } + [ScoreNote(midi: -1, start: 2, duration: material.beats)])
        }
        // Establish tonic, leave a breath, then present the phrase.
        return Score(
            title: title, tempo: 90,
            notes: [ScoreNote(midi: tonic, start: 0, duration: 1)]
                + notes.enumerated().map {
                    ScoreNote(midi: $0.element, start: 2 + Double($0.offset), duration: 0.8)
                })
    }
    public func matches(_ played: [Int], input: PracticeInput) -> Bool {
        guard !played.isEmpty, played.count == notes.count, played.allSatisfy({ (0...127).contains($0) }) else {
            return false
        }
        let shift = played[0] - notes[0]
        // Singing may use a comfortable octave, but must retain key and contour.
        return input == .singing
            ? shift % 12 == 0 && zip(played, notes).allSatisfy { $0 - $1 == shift } : input == .midi && played == notes
    }
    public static func suggested(history: PracticeProgress, now: Date = Date()) -> Self {
        let pool = [60, 62, 65, 67, 48, 50, 53, 55].flatMap { tonic in
            patterns.indices.map { Self(recipe: $0, tonic: tonic) }
        }
        var due: [(EarPhrase, Date)] = []
        for phrase in pool {
            for input in [PracticeInput.singing, .midi] {
                if let date = history.cards[phrase.activity(input)]?.review.due, date <= now {
                    due.append((phrase, date))
                }
            }
        }
        due.sort { left, right in
            if left.1 == right.1 { return left.0.recipe < right.0.recipe }
            return left.1 < right.1
        }
        if let phrase = due.first?.0 { return phrase }
        return pool.first { phrase in
            [PracticeInput.singing, .midi].allSatisfy { history.cards[phrase.activity($0)] == nil }
        } ?? pool.first { phrase in
            [PracticeInput.singing, .midi].contains { history.cards[phrase.activity($0)] == nil }
        } ?? Self()
    }
}
public enum EarStage: String, Codable, CaseIterable, Sendable { case hear, imagine, sing, play, review, complete }
public struct EarEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case heard, replay, imagined, hint, answer, next, accompaniment, tonic
    }
    public var id: UUID
    public var date: Date
    public var kind: Kind
    public var notes: [Int]
    public var skipped: Bool
    public init(_ kind: Kind, notes: [Int] = [], skipped: Bool = false, id: UUID = UUID(), date: Date = Date()) {
        self.kind = kind
        self.notes = notes
        self.skipped = skipped
        self.id = id
        self.date = date
    }
}
public struct EarResult: Equatable, Sendable {
    public var event: EarEvent
    public var phrase: EarPhrase
    public var round: Int
    public var input: PracticeInput
    public var assisted: Bool
    public var correct: Bool { phrase.matches(event.notes, input: input) && !event.skipped }
    public var outcome: PracticeOutcome { event.skipped ? .skipped : correct ? .correct : .incorrect }
    public func attempt(sessionID: UUID) -> PracticeAttempt {
        var value = PracticeAttempt(
            sessionID: sessionID, activityID: phrase.activity(input), title: phrase.title,
            skills: ["Hear → imagine → sing → play", input == .singing ? "Sung recall" : "Keyboard recall"],
            input: input, outcome: outcome, assisted: assisted, ordinal: round + 1, keyPC: phrase.tonic % 12,
            played: event.notes, target: phrase.notes, date: event.date)
        if let source = phrase.material {
            value.pieceID = source.pieceID
            value.scoreFingerprint = source.fingerprint
            value.skills = ["Score-linked recall", input == .singing ? "Sung recall" : "Keyboard recall", source.label]
            value.selectedChoice =
                "Pitch and note order only. Singing accepts a consistent octave shift. Rhythm and technique are not graded."
        }
        value.id = event.id
        return value
    }
}
public struct EarProjection: Equatable, Sendable {
    public var phrase: EarPhrase
    public var stage = EarStage.hear
    public var round = 0
    public var hinted = false
    public var assisted = false
    public var awaitingAdvance = false
    public var results: [EarResult] = []
    public var focused = false
    public var isReturn = false
    public var delayed = false
    public var accompanimentVisits = 0
    public var roundTitle: String {
        if phrase.material != nil {
            return isReturn
                ? (delayed
                    ? (assisted ? "Return · with support" : "Independent return") : "Early return · with support")
                : "Meet the passage"
        }
        return round == 0
            ? "Opening check" : round == 1 ? (focused ? "A useful return" : "A little further") : "A new key"
    }
    public var reason: String {
        if phrase.material != nil {
            return isReturn
                ? (delayed
                    ? "Recall this exact passage with its melody and solfège tucked away. Replays or hints remain available and are recorded as support."
                    : "This return is close to your last encounter. Enjoy the practice; it won't count as a delayed independent recall.")
                : "Hear a passage from your own music, carry it silently, then find it with your voice and on the keys. This first encounter counts as supported learning."
        }
        if round == 0 { return "A short phrase reveals what to practise today." }
        if round == 2 { return "Keep the relationships. Find them in a different key, with support tucked away." }
        let first = results.filter { $0.round == 0 && !$0.event.skipped }
        if first.contains(where: { !$0.correct }) {
            let needs = first.filter { !$0.correct }.map { $0.input == .singing ? "singing" : "finding the keys" }
                .joined(separator: " and ")
            return
                "Let's revisit the same phrase: \(needs) needed more attention. This return counts as supported practice."
        }
        return focused
            ? "Another encounter with this phrase, with no pressure to get it right."
            : "That phrase came back clearly. Try a different shape."
    }
}
/// Replayable events make resumed stages, assistance and derived grades verifiable.
public struct EarSession: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var opening: EarPhrase
    public var startedAt: Date?
    public var returnReadyAt: Date?
    public private(set) var events: [EarEvent] = []
    public init(phrase: EarPhrase = EarPhrase()) { opening = phrase }
    public func projection() throws -> EarProjection {
        guard opening.valid, events.count <= 128, Set(events.map(\.id)).count == events.count else {
            throw MusicError.invalid("Invalid ear-training session.")
        }
        guard [startedAt, returnReadyAt].compactMap({ $0 }).allSatisfy({ $0.timeIntervalSince1970.isFinite }),
            returnReadyAt == nil || (startedAt != nil && opening.material != nil)
        else { throw MusicError.invalid("Invalid passage return date.") }
        var p = EarProjection(phrase: opening)
        if opening.material != nil {
            p.isReturn = returnReadyAt != nil
            p.delayed = returnReadyAt.map { (startedAt ?? .distantPast) >= $0 } ?? false
            p.assisted = !p.delayed
            if p.isReturn { p.stage = .imagine }
        }
        for e in events {
            guard e.date.timeIntervalSince1970.isFinite,
                e.notes.count <= 12, e.notes.allSatisfy({ (0...127).contains($0) }),
                e.kind == .answer || (e.notes.isEmpty && !e.skipped),
                !e.skipped || e.notes.isEmpty, p.stage != .complete
            else { throw MusicError.invalid("Invalid ear-training event.") }
            switch e.kind {
            case .tonic:
                guard opening.material != nil, !p.awaitingAdvance, [.imagine, .sing, .play].contains(p.stage),
                    events.filter({ $0.kind == .tonic }).count <= 24
                else { throw MusicError.invalid("The home note is available before a recall attempt.") }
            case .accompaniment:
                guard opening.material != nil, p.stage == .review, p.accompanimentVisits < 24 else {
                    throw MusicError.invalid("Play along after the recall checks, or finish this session.")
                }
                p.accompanimentVisits += 1
            case .heard:
                guard p.stage == .hear else { throw MusicError.invalid("This phrase has already been heard.") }
                p.stage = .imagine
            case .replay:
                guard !p.awaitingAdvance, [.imagine, .sing, .play].contains(p.stage),
                    events.filter({ $0.kind == .replay }).count <= 24
                else { throw MusicError.invalid("Continue with this phrase, or skip this stage.") }
                p.assisted = true
            case .imagined:
                guard p.stage == .imagine else {
                    throw MusicError.invalid("Leave a moment to imagine the phrase first.")
                }
                p.stage = .sing
            case .hint:
                guard !p.awaitingAdvance || opening.material != nil, [.imagine, .sing, .play].contains(p.stage),
                    !p.hinted
                else { throw MusicError.invalid("Solfège is already open or unavailable here.") }
                p.hinted = true
                p.assisted = true
            case .answer:
                guard !p.awaitingAdvance, [.sing, .play].contains(p.stage), e.skipped || !e.notes.isEmpty else {
                    throw MusicError.invalid("Capture a phrase, or skip this stage.")
                }
                let input: PracticeInput = p.stage == .sing ? .singing : .midi
                p.results.append(
                    EarResult(event: e, phrase: p.phrase, round: p.round, input: input, assisted: p.assisted))
                p.awaitingAdvance = true
            case .next:
                if p.stage == .review {
                    if opening.material != nil || p.round == 2 {
                        p.stage = .complete
                        continue
                    }
                    p.round += 1
                    if p.round == 1 {
                        p.focused = p.results.contains {
                            $0.round == 0 && ($0.event.skipped || !$0.correct || $0.assisted)
                        }
                        if !p.focused { p.phrase.recipe = (opening.recipe + 1) % EarPhrase.patterns.count }
                    } else {
                        p.phrase = opening
                        p.phrase.tonic = [48: 50, 50: 53, 53: 55, 55: 48, 60: 62, 62: 65, 65: 67, 67: 60][
                            opening.tonic]!
                    }
                    p.stage = .hear
                    p.hinted = false
                    p.assisted = p.round == 1 && p.focused
                } else {
                    guard p.awaitingAdvance, [.sing, .play].contains(p.stage) else {
                        throw MusicError.invalid("Finish this attempt first.")
                    }
                    p.stage = p.stage == .sing ? .play : .review
                    p.awaitingAdvance = false
                }
            }
        }
        return p
    }
    public mutating func append(_ event: EarEvent) throws {
        guard !events.contains(where: { $0.id == event.id }) else { return }
        var copy = self
        copy.events.append(event)
        _ = try copy.projection()
        self = copy
    }
}
public struct EarPractice: Codable, Equatable, Sendable {
    public var active: EarSession?
    public var completed: [EarSession] = []
    public init() {}
    public func validated() throws -> Self {
        guard completed.count <= 20, Set(completed.map(\.id)).count == completed.count,
            active.map({ a in !completed.contains { $0.id == a.id } }) ?? true
        else { throw MusicError.invalid("Invalid ear-training history.") }
        if let active {
            guard active.opening.material == nil else {
                throw MusicError.invalid("Use the library session store for score-linked practice.")
            }
            _ = try active.projection()
        }
        for session in completed {
            guard session.opening.material == nil, try session.projection().stage == .complete else {
                throw MusicError.invalid("Unfinished ear-training archive.")
            }
        }
        return self
    }
}
extension PracticeProgress {
    public mutating func record(_ result: EarResult, sessionID: UUID) {
        guard !result.event.skipped else { return }
        let question = PracticeQuestion(
            id: result.phrase.activity(result.input), exercise: .intervals, title: result.phrase.title,
            detail: "Recall by ear", choices: [], answer: 0, explanation: "")
        record(
            question, correct: result.correct, firstTry: !result.assisted, revealed: result.assisted,
            now: result.event.date, episode: sessionID, input: result.input)
    }
}

/// Stable monophonic notes; repeated notes require an actual breath, not tuning jitter.
public struct SungPhraseCapture: Sendable {
    public private(set) var notes: [Int] = []
    private var candidate: Int?
    private var began: Double?
    private var silence: Double?
    private var accepted: Int?
    private var lastTime: Double?
    public init() {}
    public mutating func receive(midi: Int?, cents: Double = 0, confidence: Double = 1, at time: Double) {
        guard time.isFinite, lastTime.map({ time >= $0 }) ?? true, notes.count < 13 else { return }
        lastTime = time
        guard let midi else {
            candidate = nil
            began = nil
            if silence == nil { silence = time }
            if time - (silence ?? time) >= 0.2 { accepted = nil }
            return
        }
        // Invalid or unstable voiced frames do not count as a breath.
        silence = nil
        guard (0...127).contains(midi), cents.isFinite, confidence.isFinite, abs(cents) <= 35, confidence >= 0.85 else {
            candidate = nil
            began = nil
            return
        }
        if candidate != midi {
            candidate = midi
            began = time
        }
        if midi != accepted, time - (began ?? time) >= 0.35 {
            notes.append(midi)
            accepted = midi
        }
    }
}
