// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum MusicDynamic: String, Codable, CaseIterable, Sendable {
    case ppp, pp, p, mp, mf, f, ff, fff
    public var velocity: Int { [32, 44, 56, 68, 80, 94, 108, 120][Self.allCases.firstIndex(of: self)!] }
}
/// Optional on older saves. Duration stays notated; gate controls audible length.
public struct NotePerformance: Codable, Equatable, Sendable {
    public var velocity: Int
    public var gate: Double
    public init(velocity: Int = 80, gate: Double = 0.9) {
        self.velocity = velocity
        self.gate = gate
    }
}
public struct StudyExpression: Codable, Equatable, Sendable {
    public var staccato = false
    public var accent = false
    public var slurStarts: [String] = []
    public var slurStops: [String] = []
    public init() {}
}
public struct StudyDynamic: Codable, Equatable, Sendable {
    public var start: Double
    public var staff: Int
    public var voice: String?
    public var dynamic: MusicDynamic
    public init(start: Double, staff: Int, voice: String?, dynamic: MusicDynamic) {
        self.start = start
        self.staff = staff
        self.voice = voice
        self.dynamic = dynamic
    }
}
