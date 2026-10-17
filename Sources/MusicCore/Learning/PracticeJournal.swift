// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum PracticeInput: String, Codable, CaseIterable, Sendable {
    case choice, singing, midi, selfReport, tapping, microphone
}
public enum PracticeOutcome: String, Codable, Sendable { case correct, incorrect, revealed, skipped }
public struct PracticeAttempt: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var date: Date
    public var sessionID: UUID
    public var activityID: String
    public var title: String
    public var skills: [String]
    public var input: PracticeInput
    public var outcome: PracticeOutcome
    public var ordinal: Int?
    public var responseSeconds: Double?
    public var selectedChoice: String?
    public var expectedChoice: String?
    public var assisted: Bool
    public var keyPC: Int?
    public var played: [Int]
    public var target: [Int]
    public var tempo: Double?
    public var pathwayID: UUID?
    public var pathwayTaskID: UUID?
    public var pieceID: String?
    public var scoreID: UUID?
    public var guidedPracticeID: String?
    public var timedPracticeID: String?
    public var scoreFingerprint: String?
    public var passageScope: PassageScope?
    public init(
        sessionID: UUID, activityID: String, title: String, skills: [String], input: PracticeInput,
        outcome: PracticeOutcome, assisted: Bool = false, ordinal: Int? = nil, responseSeconds: Double? = nil,
        selectedChoice: String? = nil, expectedChoice: String? = nil, keyPC: Int? = nil, played: [Int] = [],
        target: [Int] = [], tempo: Double? = nil, scoreID: UUID? = nil, date: Date = Date()
    ) {
        self.sessionID = sessionID
        self.activityID = activityID
        self.title = title
        self.skills = skills
        self.input = input
        self.outcome = outcome
        self.assisted = assisted
        self.ordinal = ordinal
        self.responseSeconds = responseSeconds
        self.selectedChoice = selectedChoice
        self.expectedChoice = expectedChoice
        self.keyPC = keyPC
        self.played = played
        self.target = target
        self.tempo = tempo
        self.scoreID = scoreID
        self.date = date
    }
    public var valid: Bool {
        if let timedPracticeID {
            guard timedPracticeID.hasPrefix("timed:"), timedPracticeID.count == 70,
                ScoreRevision.valid(String(timedPracticeID.dropFirst(6))), guidedPracticeID == nil,
                input == .midi || input == .tapping, tempo != nil
            else { return false }
        }
        if let guidedPracticeID {
            guard guidedPracticeID.hasPrefix("guided:"), guidedPracticeID.count == 71,
                let scoreFingerprint, ScoreRevision.valid(scoreFingerprint), let scope = passageScope,
                (0..<1000).contains(scope.from), scope.through >= scope.from, scope.through - scope.from < 16,
                scope.partID.count <= 200, scope.staff.map({ (1...16).contains($0) }) ?? true,
                input == .midi, assisted
            else { return false }
        }
        guard pieceID.map({ $0.count <= 100 }) ?? true, date.timeIntervalSince1970.isFinite, !activityID.isEmpty,
            activityID.count <= 300, title.count <= 500
        else { return false }
        guard skills.count <= 16, skills.allSatisfy({ !$0.isEmpty && $0.count <= 200 }), played.count <= 128,
            target.count <= 128, (played + target).allSatisfy({ (0...127).contains($0) })
        else { return false }
        guard ordinal.map({ (1...100000).contains($0) }) ?? true,
            responseSeconds.map({ $0.isFinite && (0...86400).contains($0) }) ?? true
        else { return false }
        guard [selectedChoice, expectedChoice].compactMap({ $0 }).allSatisfy({ $0.count <= 500 }),
            keyPC.map({ (0...11).contains($0) }) ?? true
        else { return false }
        return tempo.map { $0.isFinite && (5...450).contains($0) } ?? true
    }
}
public struct PracticeJournal: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public private(set) var attempts: [PracticeAttempt] = []
    public init() {}
    public mutating func append(_ attempt: PracticeAttempt) {
        guard attempt.valid, !attempts.contains(where: { $0.id == attempt.id }) else { return }
        attempts.append(attempt)
        if attempts.count > 10000 { attempts.removeFirst(attempts.count - 10000) }
    }
    public func restored() throws -> Self {
        guard schemaVersion == 1 else {
            throw MusicError.invalid("This practice history needs a newer version of Cadence.")
        }
        var copy = Self()
        var seen = Set<UUID>()
        copy.attempts = attempts.suffix(10000).filter { $0.valid && seen.insert($0.id).inserted }
        return copy
    }
    public var sessionCount: Int { Set(attempts.map(\.sessionID)).count }
    public var checked: [PracticeAttempt] { attempts.filter { $0.outcome == .correct || $0.outcome == .incorrect } }
    public var firstTryCorrect: Int {
        checked.filter { $0.outcome == .correct && !$0.assisted && $0.ordinal == 1 }.count
    }
    public var unassistedCorrect: Int { checked.filter { $0.outcome == .correct && !$0.assisted }.count }
    public func observations(skill: String, input: PracticeInput) -> [PracticeAttempt] {
        checked.filter { $0.skills.contains(skill) && $0.input == input }
    }
}
