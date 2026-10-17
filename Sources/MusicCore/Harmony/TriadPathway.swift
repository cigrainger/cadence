// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum TriadInversion: Int, Codable, CaseIterable, Sendable {
    case root, first, second
    public var label: String { ["Root position", "First inversion", "Second inversion"][rawValue] }
    public var bassDegree: Int { [1, 3, 5][rawValue] }
}
public struct NeckTriad: Codable, Equatable, Sendable {
    public var frets: [Int]
    public var notes: [Int]  // ascending string index, not necessarily pitch
    public var inversion: TriadInversion
    public var voicing: Voicing { Voicing(frets: frets, pitches: notes, rank: 0) }
}
public struct TriadChange: Codable, Equatable, Sendable {
    public var bar: Int
    public var tick: Int
    public var symbol: ChordSymbol
    public var carried: Bool
    public var triadName: String {
        let pitches = tones
        guard pitches.count == 3 else { return symbol.label }
        let intervals = [mod(pitches[1].pc - pitches[0].pc), mod(pitches[2].pc - pitches[0].pc)]
        let suffix: String
        switch intervals {
        case [4, 7]: suffix = ""
        case [3, 7]: suffix = "m"
        case [3, 6]: suffix = "dim"
        case [4, 8]: suffix = "+"
        default: suffix = " · 1–3–5"
        }
        return pitches[0].name + suffix
    }
    public var tones: [Pitch] {
        guard let realized = try? ChordRealization(symbol) else { return [] }
        return [1, 3, 5].compactMap { degree in realized.tones.first { $0.degree == degree }?.pitch }
    }
}
/// A deliberately narrow harmonic reduction: never silently replace a suspended,
/// omitted or multiply altered third/fifth with a major/minor guess.
public enum TriadNeck {
    public static let sets = ["Strings 1–3 · highest", "Strings 2–4", "Strings 3–5", "Strings 4–6 · lowest"]
    public static func tones(_ symbol: ChordSymbol) throws -> [Pitch] {
        let chord = try ChordRealization(symbol)
        guard chord.symbol.root != nil,
            [1, 3, 5].allSatisfy({ degree in chord.tones.filter { $0.degree == degree }.count == 1 })
        else {
            throw MusicError.invalid(
                "\(symbol.label) needs a single written root, third and fifth. Choose another passage for this triad exercise; suspended and omitted-tone chords stay unchanged in your score."
            )
        }
        let tones = [1, 3, 5].map { degree in chord.tones.first { $0.degree == degree }!.pitch }
        guard Set(tones.map(\.pc)).count == 3 else {
            throw MusicError.invalid("This chord does not contain three distinct triad tones.")
        }
        return tones
    }
    public static func shapes(_ tones: [Pitch], tuning: Tuning, capo: Int, group: Int) -> [NeckTriad] {
        guard tones.count == 3, Set(tones.map(\.pc)).count == 3, tuning.pitches.count == 6,
            tuning.pitches.allSatisfy({ (24...88).contains($0) }), (0...9).contains(capo), (0...3).contains(group)
        else { return [] }
        let strings = Array((3 - group)...(5 - group))
        let pcs = Set(tones.map(\.pc))
        let choices = strings.map { s in (0...12).filter { pcs.contains(mod(tuning.pitches[s] + capo + $0)) } }
        var result: [NeckTriad] = []
        for a in choices[0] {
            for b in choices[1] {
                for c in choices[2] {
                    let played = [a, b, c]
                    let positive = played.filter { $0 > 0 }
                    guard (positive.max() ?? 0) - (positive.min() ?? 0) <= 4 else { continue }
                    let notes = zip(strings, played).map { tuning.pitches[$0.0] + capo + $0.1 }
                    guard Set(notes.map { mod($0) }) == pcs, let bass = notes.min(),
                        let degree = tones.firstIndex(where: { $0.pc == mod(bass) })
                    else { continue }
                    var frets = Array(repeating: -1, count: 6)
                    for (s, f) in zip(strings, played) { frets[s] = f }
                    result.append(NeckTriad(frets: frets, notes: notes, inversion: TriadInversion(rawValue: degree)!))
                }
            }
        }
        return result.sorted { a, b in
            let x = a.frets.filter { $0 >= 0 }
            let y = b.frets.filter { $0 >= 0 }
            return x.max() != y.max() ? x.max()! < y.max()! : x.lexicographicallyPrecedes(y)
        }
    }
    /// Movement is measured on each physical string. It describes travel, not
    /// finger independence, comfort or a uniquely correct musical interpretation.
    public static func movement(_ from: NeckTriad, _ to: NeckTriad) -> Int {
        zip(from.frets, to.frets).reduce(0) { $0 + (($1.0 >= 0 && $1.1 >= 0) ? abs($1.0 - $1.1) : 0) }
    }
    public static func route(_ options: [[NeckTriad]]) throws -> [NeckTriad] {
        guard !options.isEmpty, options.count <= 16, options.allSatisfy({ !$0.isEmpty && $0.count <= 100 }) else {
            throw MusicError.invalid("Choose a string set with a playable shape for every chord, up to 16 changes.")
        }
        var costs = options[0].map { Double($0.frets.max() ?? 0) * 0.001 }
        var parents: [[Int]] = []
        for step in 1..<options.count {
            var next: [Double] = []
            var links: [Int] = []
            for shape in options[step] {
                let scores = options[step - 1].indices.map {
                    costs[$0] + Double(movement(options[step - 1][$0], shape))
                }
                let best = scores.indices.min { scores[$0] < scores[$1] }!
                next.append(scores[best])
                links.append(best)
            }
            costs = next
            parents.append(links)
        }
        var index = costs.indices.min { costs[$0] < costs[$1] }!
        var path = [options.last![index]]
        for step in parents.indices.reversed() {
            index = parents[step][index]
            path.insert(options[step][index], at: 0)
        }
        return path
    }
}
public struct TriadMaterial: Codable, Equatable, Sendable {
    public var pieceID: String
    public var fingerprint: String
    public var title: String
    public var scope: PassageScope
    public var tuning: Tuning
    public var capo: Int
    public var group: Int
    public var changes: [TriadChange]
    public var route: [NeckTriad]
    public var id: String {
        "triads:"
            + ScoreRevision.digest(
                "\(pieceID):\(fingerprint):\(scope.partID):\(scope.staff ?? 1):\(scope.from):\(scope.through):\(tuning.pitches):\(capo):\(group)"
            )
    }
    public var label: String { "Bars \(scope.from+1)–\(scope.through+1) · " + TriadNeck.sets[group] }
    public init(piece: LibraryPiece, scope: PassageScope, tuning: Tuning, capo: Int, group: Int) throws {
        guard (0...3).contains(group), scope.through - scope.from < 8 else {
            throw MusicError.invalid("Choose up to eight bars and a string set.")
        }
        let source = try ChangesSource(piece: piece, from: scope.from, through: scope.through, partID: scope.partID)
        let plan = try source.plan(staff: scope.staff ?? 1)
        // A carried symbol belongs to the earlier source page, which must also
        // have been reviewed. Requiring the preceding span avoids a false link.
        let reviewStart = plan.steps.first(where: \.carried)?.bar ?? scope.from
        _ = try ReviewedSource.pages(piece: piece, from: reviewStart, through: scope.through)
        guard (1...16).contains(plan.steps.count), plan.steps.allSatisfy({ $0.chord.symbol.root != nil }) else {
            throw MusicError.invalid("Choose up to 16 chord changes without N.C. sections for this pathway.")
        }
        self.pieceID = piece.id
        fingerprint = piece.fingerprint
        title = piece.title
        self.scope = PassageScope(partID: source.partID, staff: plan.staff, from: scope.from, through: scope.through)
        self.tuning = tuning
        self.capo = capo
        self.group = group
        changes = plan.steps.map {
            TriadChange(bar: $0.bar, tick: $0.tick, symbol: $0.chord.symbol, carried: $0.carried)
        }
        let choices = try changes.map {
            TriadNeck.shapes(try TriadNeck.tones($0.symbol), tuning: tuning, capo: capo, group: group)
        }
        route = try TriadNeck.route(choices)
    }
    public var valid: Bool {
        guard !pieceID.isEmpty, pieceID.count <= 100, ScoreRevision.valid(fingerprint), title.count <= 500,
            (0...3).contains(group), (0..<1000).contains(scope.from), scope.through >= scope.from,
            scope.through - scope.from < 8,
            scope.partID.count <= 200, (1...16).contains(scope.staff ?? 1), (1...16).contains(changes.count),
            route.count == changes.count
        else { return false }
        var previous = (-1, -1)
        for (index, pair) in zip(changes, route).enumerated() {
            let (change, shape) = pair
            guard
                change.carried
                    ? index == 0 && change.bar >= 0 && change.bar < scope.from
                    : (scope.from...scope.through).contains(change.bar), (0...24000).contains(change.tick),
                change.bar > previous.0 || (change.bar == previous.0 && change.tick > previous.1),
                let tones = try? TriadNeck.tones(change.symbol),
                TriadNeck.shapes(tones, tuning: tuning, capo: capo, group: group).contains(shape)
            else { return false }
            previous = (change.bar, change.tick)
        }
        return true
    }
    public func current(in piece: LibraryPiece) -> Bool {
        guard piece.id == pieceID, piece.fingerprint == fingerprint,
            let rebuilt = try? Self(piece: piece, scope: scope, tuning: tuning, capo: capo, group: group)
        else { return false }
        var a = self
        var b = rebuilt
        a.title = ""
        b.title = ""
        return a == b
    }
    public var earNotes: [Int] {
        guard let first = route.first, let change = changes.first else { return [] }
        return change.tones.prefix(2).compactMap { tone in first.notes.first { mod($0) == tone.pc } }
    }
    public func answerDocument() throws -> EditorDocument {
        guard valid else { throw MusicError.invalid("This triad source is invalid.") }
        var document = try EditorDocument.blank(instrument: .guitar, bars: 2, meter: .init(4, 4))
        document.title = String(("Guitar answer to “" + title + "”").prefix(120))
        document.tuning = tuning
        document.capo = capo
        document.tempo = 72
        // A new two-bar prompt, explicitly an adaptation of the chosen changes.
        document.harmonies = changes.prefix(2).enumerated().map {
            EditorHarmony(bar: $0.offset, tick: 0, symbol: $0.element.symbol)
        }
        document.triadSource = self
        return try document.validated()
    }
}
public enum TriadStage: String, Codable, CaseIterable, Sendable {
    case find, connect, ear, create, complete
    public var title: String {
        switch self {
        case .find: "Find the inversion"
        case .connect: "Make the changes smooth"
        case .ear: "Ear to fretboard"
        case .create: "Make a musical answer"
        case .complete: "Keep the connection"
        }
    }
}
public enum TriadAction: Equatable, Sendable {
    case inversion(TriadInversion)
    case connected
    case microphone([Int])
    case skip, finish
}
public struct TriadSession: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var material: TriadMaterial
    public var stage = TriadStage.find
    public var cursor = 0
    public var mistakes = 0
    public var review = ReviewSchedule()
    public var updatedAt = Date()
    public init(material: TriadMaterial) { self.material = material }
    public var valid: Bool {
        material.valid && material.route.indices.contains(cursor) && (0...100000).contains(mistakes) && review.valid
            && updatedAt.timeIntervalSince1970.isFinite
    }
    public mutating func apply(_ action: TriadAction, now: Date = Date()) throws -> PracticeAttempt {
        guard valid, now.timeIntervalSince1970.isFinite, stage != .complete else {
            throw MusicError.invalid("Reopen this pathway before practising again.")
        }
        var input = PracticeInput.selfReport
        var outcome = PracticeOutcome.revealed
        var played: [Int] = []
        var target: [Int] = []
        var choice: String?
        let oldStage = stage
        switch (stage, action) {
        case (.find, .inversion(let answer)):
            input = .choice
            outcome = answer == material.route[cursor].inversion ? .correct : .incorrect
            choice = answer.label
            if outcome == .correct {
                if cursor + 1 < material.changes.count { cursor += 1 } else { stage = .connect }
            } else {
                mistakes += 1
            }
        case (.connect, .connected):
            stage = .ear
            choice = "I tried the changes on guitar"
        case (.ear, .microphone(let notes)):
            guard !notes.isEmpty, notes.count <= 12, notes.allSatisfy({ (0...127).contains($0) }) else {
                throw MusicError.invalid("Play the two notes separately before checking them.")
            }
            input = .microphone
            target = material.earNotes
            played = notes
            outcome = notes == target ? .correct : .incorrect
            if outcome == .correct { stage = .create } else { mistakes += 1 }
        case (.create, .finish):
            stage = .complete
            choice = "I improvised a short answer"
        case (_, .skip):
            outcome = .skipped
            stage = TriadStage.allCases[TriadStage.allCases.firstIndex(of: stage)! + 1]
        default: throw MusicError.invalid("That action belongs to another step of this pathway.")
        }
        updatedAt = now
        if stage == .complete { review.record(.supported, episode: id, input: .selfReport, now: now) }
        var attempt = PracticeAttempt(
            sessionID: id, activityID: material.id + ":" + oldStage.rawValue,
            title: "Triads across the neck · " + oldStage.title,
            skills: ["Guitar triads", oldStage.title], input: input, outcome: outcome, assisted: true,
            selectedChoice: choice, played: played, target: target, date: now)
        attempt.pieceID = material.pieceID
        attempt.scoreFingerprint = material.fingerprint
        return attempt
    }
    public mutating func restart() {
        id = UUID()
        stage = .find
        cursor = 0
        mistakes = 0
        updatedAt = Date()
    }
}
public struct TriadPractice: Codable, Equatable, Sendable {
    public var sessions: [TriadSession] = []
    public var activeID: UUID?
    public init() {}
    public var active: TriadSession? { sessions.first { $0.id == activeID } }
    public func validated() throws -> Self {
        guard sessions.count <= 100, Set(sessions.map(\.id)).count == sessions.count,
            Set(sessions.map { $0.material.id }).count == sessions.count, sessions.allSatisfy(\.valid),
            activeID == nil || active != nil
        else { throw MusicError.invalid("The saved guitar pathways are invalid.") }
        return self
    }
}
