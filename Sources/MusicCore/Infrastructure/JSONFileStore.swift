// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// One independently recoverable file. A failed load never authorizes replacing it.
/// The write closure is injectable so disk failures can be tested without a real full disk.
public final class JSONFileStore<Value: Codable> {
    public let url: URL
    public private(set) var loadError: String?
    private let validate: (Value) throws -> Value
    private let restore: (Value) throws -> Value
    private let write: (Data, URL) throws -> Void
    private var expected: Data?
    private var loaded = false
    private let maximumBytes: Int

    public init(
        url: URL, validate: @escaping (Value) throws -> Value,
        restore: ((Value) throws -> Value)? = nil,
        maximumBytes: Int = 128 * 1024 * 1024,
        write: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    ) {
        self.maximumBytes = max(1, maximumBytes)
        self.url = url
        self.validate = validate
        self.restore = restore ?? validate
        self.write = write
    }

    public func load(default fallback: Value) -> Value {
        loaded = true
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback }
        do {
            let data = try readSnapshot()
            let value = try restore(JSONDecoder().decode(Value.self, from: data))
            expected = data
            return value
        } catch {
            loadError =
                "\(url.lastPathComponent) could not be opened. The original file has been preserved. "
                + error.localizedDescription
            return fallback
        }
    }

    public func save(_ value: Value) throws {
        guard loaded else { throw MusicError.invalid("Open the saved file before replacing it.") }
        if let loadError { throw MusicError.invalid(loadError) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(validate(value))
        guard data.count <= maximumBytes else {
            throw MusicError.invalid("This saved library exceeds the supported size. The previous file is unchanged.")
        }
        let current = FileManager.default.fileExists(atPath: url.path) ? try readSnapshot() : nil
        guard current == expected else {
            throw MusicError.invalid(
                "\(url.lastPathComponent) changed outside this session. Reopen Cadence before saving; the other copy has been preserved."
            )
        }
        guard current != data else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let current {
            try write(current, url.appendingPathExtension("previous"))
        }
        try write(data, url)
        expected = data
    }
    /// Check size before reading or decoding. A second check covers growth
    /// between metadata lookup and the read; oversized originals stay intact.
    private func readSnapshot() throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumBytes else { throw MusicError.invalid("The saved file exceeds the supported size.") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumBytes else { throw MusicError.invalid("The saved file exceeds the supported size.") }
        return data
    }

}

/// The result and the schedule derived from it share one atomic commit.
/// Older practice.json, attempts.json and learning.json files are read only at migration.
public struct PracticeState: Codable, Equatable, Sendable {
    public var schemaVersion = 15
    public var history: PracticeProgress
    public var journal: PracticeJournal
    public var learning: LearningLibrary
    public var smooth: SmoothPractice?
    public var ear: EarPractice?
    public var scoreEar: ScoreEarPractice?
    public var rehearsal: PieceRehearsalBook?
    public var pianoTakes: PianoTakeBook?
    public var triads: TriadPractice?
    public var tension: TensionPractice?
    public var reharm: ReharmPractice?
    public init(
        history: PracticeProgress = PracticeProgress(), journal: PracticeJournal = PracticeJournal(),
        learning: LearningLibrary = LearningLibrary(), smooth: SmoothPractice? = nil, ear: EarPractice? = nil,
        scoreEar: ScoreEarPractice? = nil, rehearsal: PieceRehearsalBook? = nil, pianoTakes: PianoTakeBook? = nil,
        triads: TriadPractice? = nil, tension: TensionPractice? = nil, reharm: ReharmPractice? = nil
    ) {
        self.history = history
        self.journal = journal
        self.learning = learning
        self.smooth = smooth
        self.ear = ear
        self.scoreEar = scoreEar
        self.rehearsal = rehearsal
        self.pianoTakes = pianoTakes
        self.triads = triads
        self.tension = tension
        self.reharm = reharm
    }
    public func validated() throws -> Self {
        guard (1...15).contains(schemaVersion) else {
            throw MusicError.invalid("This practice data needs a newer Cadence.")
        }
        _ = try history.validated()
        _ = try learning.validated()
        if let smooth { _ = try smooth.validated() }
        if let ear { _ = try ear.validated() }
        if let scoreEar { _ = try scoreEar.validated() }
        if let rehearsal { _ = try rehearsal.validated() }
        if let reharm { _ = try reharm.validated() }
        if let tension { _ = try tension.validated() }
        if let triads { _ = try triads.validated() }
        if let pianoTakes { _ = try pianoTakes.validated() }
        // New snapshots must be complete. Legacy journal cleanup happens only during migration.
        guard try journal.restored() == journal else {
            throw MusicError.invalid("The detailed practice history contains invalid records.")
        }
        // Version 15 protects reharmonisations and recorded improvisations from older writers.
        var restored = self
        restored.schemaVersion = 15
        return restored
    }
}
