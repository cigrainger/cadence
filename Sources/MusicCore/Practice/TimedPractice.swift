// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum TimedInput: String, Codable, CaseIterable, Sendable {
    case midi = "MIDI keyboard"
    case space = "Spacebar"
    public var journalInput: PracticeInput { self == .midi ? .midi : .tapping }
}
public struct TimedConditions: Codable, Equatable, Sendable {
    public var input: TimedInput
    public var click: Bool
    /// Positive values subtract a consistently late input/output offset.
    public var offsetMS: Int
    /// The written staff played by Cadence during a supported one-hand pass.
    public var partnerStaff: Int?
    public var flowPulse: FlowPulse?
    public init(
        input: TimedInput = .midi, click: Bool = true, offsetMS: Int = 0, partnerStaff: Int? = nil,
        flowPulse: FlowPulse? = nil
    ) {
        self.input = input
        self.click = click
        self.offsetMS = offsetMS
        self.partnerStaff = partnerStaff
        self.flowPulse = flowPulse
    }
    public var valid: Bool {
        (flowPulse.map { $0.click == click } ?? true) && (-250...250).contains(offsetMS)
            && (partnerStaff.map { (1...16).contains($0) } ?? true)
    }
}
public struct TimedTarget: Codable, Equatable, Sendable {
    public var beat: Double
    public var bar: Int
    public var pitch: Int
    /// Written ownership, only for a two-staff plan. Shared unisons are one key.
    public var staves: [Int]?
    public init(beat: Double, bar: Int, pitch: Int = 60, staves: [Int]? = nil) {
        self.beat = beat
        self.bar = bar
        self.pitch = pitch
        self.staves = staves
    }
}
public struct TimedSource: Codable, Equatable, Sendable {
    public var studyID: UUID
    public var pieceID: String
    public var fingerprint: String
    public var scope: PassageScope
    public var startBeat: Double
    public var valid: Bool {
        !pieceID.isEmpty && pieceID.count <= 100 && ScoreRevision.valid(fingerprint) && (0..<1000).contains(scope.from)
            && scope.through >= scope.from && scope.through - scope.from < 8 && !scope.partID.isEmpty
            && scope.partID.count <= 200 && (scope.staff.map { (1...16).contains($0) } ?? true) && startBeat.isFinite
            && (0..<100000).contains(startBeat)
    }
}
/// A fixed timeline. Display timers never decide whether an attack was early or late.
public struct TimedPracticePlan: Codable, Equatable, Sendable {
    public var title: String
    public var rhythmID: String?
    public var source: TimedSource?
    public var targets: [TimedTarget]
    public var handStaves: [Int]?
    public var tempo: Int
    public var beatsPerBar: Int
    public var length: Double
    public var rhythmOnly: Bool { rhythmID != nil }
    public var secondsPerBeat: Double { 60 / Double(tempo) }
    public var duration: Double { length * secondsPerBeat }
    public var countIn: Double { Double(beatsPerBar) * secondsPerBeat }
    public var onsetBeats: [Double] { Array(Set(targets.map(\.beat))).sorted() }
    public var tolerance: Double {
        let beats = onsetBeats
        let gap = zip(beats.dropFirst(), beats).map { $0 - $1 }.min() ?? 1
        return min(0.08, gap * secondsPerBeat * 0.2)
    }
    public var valid: Bool {
        guard !title.isEmpty, title.count <= 500, (40...160).contains(tempo), (2...4).contains(beatsPerBar),
            length.isFinite, length > 0, length <= 32, duration <= 60,
            (1...256).contains(targets.count), (source != nil) != (rhythmID != nil), source?.valid ?? true,
            rhythmID.map({ !$0.isEmpty && $0.count <= 100 }) ?? true
        else { return false }
        if let hands = handStaves {
            guard source?.scope.staff == nil, source != nil, hands.count == 2, hands == hands.sorted(),
                hands[0] < hands[1],
                hands.allSatisfy({ (1...16).contains($0) }),
                hands.allSatisfy({ staff in targets.contains { $0.staves?.contains(staff) == true } })
            else { return false }
        }
        var seen = Set<String>()
        return targets.allSatisfy { t in
            (handStaves.map { hands in
                guard let staves = t.staves else { return false }
                return !staves.isEmpty && staves == Array(Set(staves)).sorted() && staves.allSatisfy(hands.contains)
            } ?? (t.staves == nil)) && t.beat.isFinite && t.beat >= 0 && t.beat < length && (0..<1000).contains(t.bar)
                && (0...127).contains(t.pitch)
                && (source.map { ($0.scope.from...$0.scope.through).contains(t.bar) } ?? (t.bar < 8))
                && seen.insert("\(t.beat):\(rhythmOnly ? 0 : t.pitch)").inserted
        } && targets.map(\.beat) == targets.map(\.beat).sorted()
            && zip(onsetBeats.dropFirst(), onsetBeats).allSatisfy { ($0 - $1) * secondsPerBeat >= 0.12 - 0.000001 }
    }
    public func identity(_ conditions: TimedConditions) -> String {
        let sourceID =
            source.map {
                "\($0.pieceID)|\($0.fingerprint)|\($0.scope.partID)|\($0.scope.staff ?? 0)|\($0.scope.from)|\($0.scope.through)"
            } ?? rhythmID ?? ""
        let partner =
            (conditions.partnerStaff.map { "|partner:\($0)" } ?? "")
            + (conditions.flowPulse.map { "|flow:\($0.rawValue)" } ?? "")
        return "timed:"
            + ScoreRevision.digest(
                "v1|\(sourceID)|\(tempo)|\(conditions.input.rawValue)|\(conditions.click)|\(conditions.offsetMS)\(partner)"
            )
    }
    public init(study: MusicStudy, guided: GuidedPassage, tempo: Int) throws {
        let staves = study.part.staves.filter { !study.part.tabStaves.contains($0) }
        guard study.staff != nil || staves.count == 1, study.through - study.from < 8,
            let meter = study.selectedMeasures.first,
            (2...4).contains(meter.beats), meter.beatUnit == 4,
            study.selectedMeasures.allSatisfy({ $0.beats == meter.beats && $0.beatUnit == 4 })
        else {
            throw MusicError.invalid("For Play in time, choose one notation staff and 1–8 bars in 2/4, 3/4 or 4/4.")
        }
        title = guided.title
        rhythmID = nil
        self.tempo = tempo
        beatsPerBar = meter.beats
        length = study.end - study.start
        source = TimedSource(
            studyID: study.id, pieceID: guided.pieceID, fingerprint: guided.fingerprint, scope: guided.scope,
            startBeat: study.start)
        targets = guided.steps.flatMap { step in
            step.notes.map { TimedTarget(beat: step.beat - study.start, bar: step.bar, pitch: $0) }
        }
        guard valid else {
            throw MusicError.invalid(
                "Choose a shorter passage, 40–160 bpm, with at least 120 ms between entrances. Very fast ornaments are not assessed yet."
            )
        }
    }
    public init(rhythm: RhythmExercise, tempo: Int) {
        title = rhythm.rawValue
        rhythmID = rhythm.id
        source = nil
        self.tempo = tempo
        beatsPerBar = 4
        length = 8
        targets = rhythm.beats.map { TimedTarget(beat: $0, bar: Int($0 / 4)) }
    }
    public static func calibration(tempo: Int = 80) -> Self {
        var plan = Self(rhythm: .pulse, tempo: tempo)
        plan.rhythmID = "calibration"
        plan.title = "Timing check"
        return plan
    }
}

public enum RhythmExercise: String, CaseIterable, Codable, Sendable {
    case pulse = "Find the pulse"
    case eighths = "Divide the beat"
    case rests = "Leave room for rests"
    case offbeats =
        "Feel the offbeats"
    public var id: String {
        switch self {
        case .pulse: "pulse"
        case .eighths: "eighths"
        case .rests: "rests"
        case .offbeats: "offbeats"
        }
    }
    public var beats: [Double] {
        switch self {
        case .pulse: return [0, 1, 2, 3, 4, 5, 6, 7]
        case .eighths: return [0, 1, 1.5, 2, 3, 3.5, 4, 4.5, 5, 6, 6.5, 7]
        case .rests: return [0, 2, 3, 4, 5, 7]
        case .offbeats: return [0, 1.5, 2, 3.5, 4, 5.5, 6, 7.5]
        }
    }
    public var instruction: String {
        switch self {
        case .pulse: "Count 1, 2, 3, 4. Tap once on each beat, keeping the spaces even."
        case .eighths: "Count 1 & 2 & 3 & 4 &. Keep the beat steady when two taps share a beat."
        case .rests: "Keep counting through the rests. Silence still takes time."
        case .offbeats: "Keep counting the beat, and place the offbeat taps on ‘&’."
        }
    }
}
public struct TimedAttack: Codable, Equatable, Sendable {
    /// Seconds relative to the audible passage start, after the explicit offset.
    public var seconds: Double
    public var pitch: Int
    public var arrivalTimestamp: Bool
    public init(seconds: Double, pitch: Int = 60, arrivalTimestamp: Bool = false) {
        self.seconds = seconds
        self.pitch = pitch
        self.arrivalTimestamp = arrivalTimestamp
    }
    public var valid: Bool { seconds.isFinite && (-1...65).contains(seconds) && (0...127).contains(pitch) }
}
public enum OnsetVerdict: String, Codable, Sendable { case onTime, early, late, wrongPitch, missed }
public struct TimedAssessment: Equatable, Sendable {
    public var target: TimedTarget
    public var attack: TimedAttack?
    public var delta: Double?
    public var verdict: OnsetVerdict
}
public struct TimedReport: Equatable, Sendable {
    public var notes: [TimedAssessment]
    public var extras: [TimedAttack]
    public var onTime: Int { notes.filter { $0.verdict == .onTime }.count }
    public var early: Int { notes.filter { $0.verdict == .early }.count }
    public var late: Int { notes.filter { $0.verdict == .late }.count }
    public var missed: Int { notes.filter { $0.verdict == .missed }.count }
    public var wrong: Int { notes.filter { $0.verdict == .wrongPitch }.count }
    public var matchedPitch: Int { notes.count - missed - wrong }
    public var clean: Bool { !notes.isEmpty && onTime == notes.count && extras.isEmpty }
    public var difficultBars: [Int] {
        Array(Set(notes.filter { $0.verdict != .onTime }.map { $0.target.bar })).sorted()
    }
    public var medianOffset: Double? {
        let values = notes.compactMap(\.delta).sorted()
        guard !values.isEmpty else { return nil }
        let n = values.count
        return (values[(n - 1) / 2] + values[n / 2]) / 2
    }
    public var calibrationOffsetMS: Int? {
        guard missed <= 2, wrong == 0, extras.isEmpty, let median = medianOffset,
            notes.compactMap(\.delta).count >= 6
        else { return nil }
        let deviations = notes.compactMap(\.delta).map { abs($0 - median) }.sorted()
        guard deviations[deviations.count / 2] <= 0.045 else { return nil }
        return Int((median * 1000).rounded())
    }
}
public enum TimedMatcher {
    public static func windowRadius(_ plan: TimedPracticePlan, beat: Double) -> Double {
        let beats = plan.onsetBeats
        guard let index = beats.firstIndex(of: beat) else { return 0 }
        let before = index > 0 ? (beat - beats[index - 1]) * plan.secondsPerBeat : .infinity
        let after = index + 1 < beats.count ? (beats[index + 1] - beat) * plan.secondsPerBeat : .infinity
        return min(0.4, min(before, after) * 0.49)
    }
    /// Fixed, disjoint onset windows keep a missed/extra note from moving all
    /// subsequent matches. Chord pitches match independently of packet order.
    public static func assess(_ plan: TimedPracticePlan, attacks: [TimedAttack]) throws -> TimedReport {
        guard plan.valid, attacks.count <= 2048, attacks.allSatisfy(\.valid) else {
            throw MusicError.invalid("This timed pass contains invalid input.")
        }
        let beats = plan.onsetBeats
        let times = beats.map { $0 * plan.secondsPerBeat }
        var buckets = [[Int]](repeating: [], count: beats.count)
        var extras: [TimedAttack] = []
        for (index, attack) in attacks.enumerated() {
            guard
                let nearest = times.indices.min(by: {
                    abs(times[$0] - attack.seconds) < abs(times[$1] - attack.seconds)
                })
            else { continue }
            let radius = windowRadius(plan, beat: beats[nearest])
            if abs(attack.seconds - times[nearest]) <= radius + 0.000001 {
                buckets[nearest].append(index)
            } else {
                extras.append(attack)
            }
        }
        var notes: [TimedAssessment] = []
        for (group, beat) in beats.enumerated() {
            let targets = plan.targets.filter { $0.beat == beat }
            var remaining = buckets[group].sorted {
                abs(attacks[$0].seconds - times[group]) < abs(attacks[$1].seconds - times[group])
            }
            var assigned: [Int: Int] = [:]
            // First reserve every correct pitch; a stray note cannot steal it.
            for (i, target) in targets.enumerated() {
                if let match = remaining.firstIndex(where: { plan.rhythmOnly || attacks[$0].pitch == target.pitch }) {
                    assigned[i] = remaining.remove(at: match)
                }
            }
            for (i, target) in targets.enumerated() {
                let matched = assigned[i] ?? (remaining.isEmpty ? nil : remaining.removeFirst())
                let attack = matched.map { attacks[$0] }
                let delta = attack.map { $0.seconds - times[group] }
                let verdict: OnsetVerdict
                if let attack, let delta {
                    verdict =
                        !plan.rhythmOnly && attack.pitch != target.pitch
                        ? .wrongPitch : abs(delta) <= plan.tolerance + 0.000001 ? .onTime : delta < 0 ? .early : .late
                } else {
                    verdict = .missed
                }
                notes.append(TimedAssessment(target: target, attack: attack, delta: delta, verdict: verdict))
            }
            extras.append(contentsOf: remaining.map { attacks[$0] })
        }
        return TimedReport(notes: notes, extras: extras.sorted { $0.seconds < $1.seconds })
    }
}
public struct TimedPracticeResult: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var plan: TimedPracticePlan
    public var conditions: TimedConditions
    public var attacks: [TimedAttack]
    public var practiceID: String { plan.identity(conditions) }
    public var report: TimedReport {
        (try? TimedMatcher.assess(plan, attacks: attacks)) ?? TimedReport(notes: [], extras: [])
    }
    public var grade: ReviewGrade {
        valid && report.clean
            ? (attacks.contains(where: \.arrivalTimestamp) || conditions.partnerStaff != nil
                || conditions.flowPulse != nil ? .supported : .good) : .again
    }
    public var valid: Bool {
        plan.valid && conditions.valid && (plan.rhythmOnly || conditions.input == .midi)
            && plan.rhythmID != "calibration"
            && (conditions.partnerStaff.map {
                !plan.rhythmOnly && plan.source?.scope.staff != nil && plan.source?.scope.staff != $0
            } ?? true) && date.timeIntervalSince1970.isFinite && attacks.count <= 2048
            && attacks.allSatisfy { $0.valid && $0.seconds >= -0.5 && $0.seconds <= plan.duration + 0.5 }
    }
    public init(
        id: UUID = UUID(), date: Date = Date(), plan: TimedPracticePlan, conditions: TimedConditions,
        attacks: [TimedAttack]
    ) {
        self.id = id
        self.date = date
        self.plan = plan
        self.conditions = conditions
        self.attacks = attacks
    }
    public var evidence: String {
        let r = report
        let selection =
            plan.source.map {
                "\($0.scope.staff.map { "staff \($0)" } ?? (plan.handStaves == nil ? "selected notation staff" : "both notation staves")), bars \($0.scope.from + 1)–\($0.scope.through + 1)"
            } ?? plan.title
        return
            "Timed \(plan.rhythmOnly ? "rhythm tapping" : "MIDI passage"), \(selection), \(plan.tempo) bpm, \(conditions.input.rawValue), click \(conditions.flowPulse?.rawValue ?? (conditions.click ? "on" : "off")), partner \(conditions.partnerStaff.map { "staff \($0)" } ?? "off"), offset \(conditions.offsetMS) ms, onset tolerance ±\(Int((plan.tolerance * 1000).rounded())) ms: \(r.onTime)/\(r.notes.count) on time, \(r.early) early, \(r.late) late, \(r.wrong) wrong pitches, \(r.missed) missed, \(r.extras.count) extra presses. \(attacks.filter(\.arrivalTimestamp).count) presses used callback-arrival timing. Note lengths, pedal, dynamics and physical technique were not graded. Device timing is not a proficiency measure."
    }
}
public struct TimedPracticeProgress: Codable, Equatable, Sendable {
    public var latest: TimedPracticeResult
    public var review = ReviewSchedule()
    public init(result: TimedPracticeResult) { latest = result }
}
