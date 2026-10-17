// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Travels with the composition, independently of practice-history retention.
/// The source snapshot is never rewritten when the source score changes.
public struct CreativeResponse: Codable, Equatable, Sendable {
    public var material: ScoreEarMaterial
    public var sessionID: UUID
    public var createdAt: Date
    public var savedAt: Date?
    public var listenedFingerprint: String?
    public init(material: ScoreEarMaterial, sessionID: UUID, now: Date = Date()) {
        self.material = material
        self.sessionID = sessionID
        createdAt = now
    }
    public var valid: Bool {
        material.valid && createdAt.timeIntervalSince1970.isFinite
            && (savedAt.map { $0.timeIntervalSince1970.isFinite && $0 >= createdAt } ?? true)
            && (listenedFingerprint.map(ScoreRevision.valid) ?? true) && (savedAt == nil || listenedFingerprint != nil)
    }
    public func isFinished(_ document: EditorDocument) -> Bool {
        savedAt != nil && listenedFingerprint == LibraryPiece(source: .score(document)).fingerprint
    }
    public func makeDocument(piece: LibraryPiece) throws -> EditorDocument {
        guard valid, material.isCurrent(in: piece) else {
            throw MusicError.invalid("Review this source passage again before starting an answer.")
        }
        let study = try ScoreEarMaterial.study(piece: piece, scope: material.scope)
        let bars = study.selectedMeasures
        guard let first = bars.first, bars.allSatisfy({ $0.beats == first.beats && $0.beatUnit == first.beatUnit })
        else { throw MusicError.invalid("Choose a passage with one time signature for your answer.") }
        let instrument: EditorInstrument
        switch piece.source {
        case .score(let score): instrument = score.instrument
        case .study: instrument = study.part.tabStaves.isEmpty ? .piano : .guitar
        }
        var score = try EditorDocument.blank(
            instrument: instrument, bars: bars.count, meter: EditorMeter(first.beats, first.beatUnit))
        score.title = String(("Answer to “" + material.title + "”").prefix(120))
        score.fifths = material.fifths
        score.minor = material.minor
        score.tempo = min(300, max(20, Int(material.tempo.rounded())))
        if case .score(let source) = piece.source {
            score.tuning = source.tuning
            score.capo = source.capo
        }
        score.harmonies = material.chords.map { chord in
            let tick = Int((chord.start * 480).rounded())
            return EditorHarmony(bar: tick / score.meter.ticks, tick: tick % score.meter.ticks, symbol: chord.symbol)
        }
        score.responseSource = self
        return try score.validated()
    }
}

/// Absolute audio time -> a bounded, looping position in the reviewed passage.
/// MIDI lights reflect held pitches only; they are not performance grades.
public struct ScoreBandPosition: Equatable, Sendable {
    public var head: StudyPlayhead
    public var fraction: Double
    public var round: Int { head.cycle + 1 }
    public init?(seconds: Double, tempo: Double, beats: Double, loops: Int, sourceStart: Double) {
        guard seconds.isFinite, seconds >= 0, tempo.isFinite, tempo > 0,
            beats.isFinite, beats > 0, (1...4).contains(loops), sourceStart.isFinite
        else { return nil }
        let elapsed = seconds * tempo / 60
        guard elapsed < 4 + beats * Double(loops) else { return nil }
        if elapsed < 4 {
            head = .init(sourceBeat: sourceStart, isCountIn: true, countInRemaining: 4 - elapsed, cycle: 0)
            fraction = 0
        } else {
            let after = elapsed - 4
            let position = after.truncatingRemainder(dividingBy: beats)
            head = .init(
                sourceBeat: sourceStart + position, isCountIn: false, countInRemaining: 0, cycle: Int(after / beats))
            fraction = position / beats
        }
    }
}
