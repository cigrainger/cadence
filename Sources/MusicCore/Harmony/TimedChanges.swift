// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public struct ChangesTimingConditions: Codable, Equatable, Sendable {
    public var click: Bool
    public var bass: Bool
    public var hints: Bool
    public var offsetMS: Int
    public init(click: Bool = true, bass: Bool = false, hints: Bool = false, offsetMS: Int = 0) {
        self.click = click
        self.bass = bass
        self.hints = hints
        self.offsetMS = offsetMS
    }
    public var valid: Bool { (-250...250).contains(offsetMS) }
}
public struct HarmonicCue: Codable, Equatable, Sendable {
    public var beat: Double
    public var bar: Int
    public var symbol: ChordSymbol
    public var sourceIndex: Int
    public var cycle: Int
    public var isRest: Bool { symbol.kind == .none }
    public func target(_ mode: ChangesMode) throws -> ChangesTarget? {
        isRest ? nil : try ChordRealization(symbol).target(mode)
    }
}
public struct TimedChangesPlan: Codable, Equatable, Sendable {
    public var title: String
    public var pieceID: String?
    public var fingerprint: String?
    public var from: Int
    public var through: Int
    public var partID: String
    public var staff: Int
    public var mode: ChangesMode
    public var tempo: Int
    public var loops: Int
    public var focus: [Int]?
    public var beatsPerBar: Int
    public var loopLength: Double
    public var cues: [HarmonicCue]
    public var secondsPerBeat: Double { 60 / Double(tempo) }
    public var length: Double { loopLength * Double(loops) }
    public var duration: Double { length * secondsPerBeat }
    public var countIn: Double { Double(beatsPerBar) * secondsPerBeat }
    public var tolerance: Double { 0.10 }
    public var settle: Double { 0.06 }
    public init(changes: ChangesPlan, mode: ChangesMode, tempo: Int = 80, loops: Int = 2, focus: [Int]? = nil) throws {
        guard (1...8).contains(changes.barTicks.count), changes.barUnits.allSatisfy({ $0 == 4 }),
            let ticks = changes.barTicks.first, [960, 1440, 1920].contains(ticks),
            changes.barTicks.allSatisfy({ $0 == ticks })
        else {
            throw MusicError.invalid(
                "Play the changes supports 1–8 complete bars in steady 2/4, 3/4 or 4/4. Choose a smaller passage if needed."
            )
        }
        title = changes.title
        pieceID = changes.pieceID
        fingerprint = changes.fingerprint
        from = changes.from
        through = changes.through
        partID = changes.partID
        staff = changes.staff
        self.mode = mode
        self.tempo = tempo
        self.loops = loops
        self.focus = focus
        beatsPerBar = ticks / 480
        var base = changes.steps.enumerated().map { i, step in
            HarmonicCue(
                beat: step.carried ? 0 : Double((step.bar - changes.from) * ticks + step.tick) / 480,
                bar: max(changes.from, step.bar), symbol: step.chord.symbol, sourceIndex: i, cycle: 0)
        }
        if base.first?.beat != 0 {
            base.insert(
                HarmonicCue(beat: 0, bar: from, symbol: .init(root: nil, kind: .none), sourceIndex: -1, cycle: 0), at: 0
            )
        }
        let fullLength = Double(changes.barTicks.reduce(0, +)) / 480
        if let focus {
            guard focus.count == 2, focus[0] >= 0, focus[1] >= focus[0], focus[1] < base.count else {
                throw MusicError.invalid("Choose a valid transition to practise.")
            }
            // Keep complete source bars so the click's downbeat still means the written downbeat.
            let bar = Double(beatsPerBar)
            let start = floor(base[focus[0]].beat / bar) * bar
            let end = min(fullLength, (floor(base[focus[1]].beat / bar) + 1) * bar)
            let prior = base.last(where: { $0.beat < start })
            base = base.filter { $0.beat >= start && $0.beat < end }
            if base.first?.beat != start, var prior {
                prior.beat = start
                prior.bar = from + Int(start / bar)
                base.insert(prior, at: 0)
            }
            base = base.map {
                var cue = $0
                cue.beat -= start
                return cue
            }
            loopLength = end - start
        } else {
            loopLength = fullLength
        }
        cues = []
        guard (1...4).contains(loops) else { throw MusicError.invalid("Choose 1–4 passes through the changes.") }
        for cycle in 0..<loops {
            cues += base.map {
                var cue = $0
                cue.beat += Double(cycle) * loopLength
                cue.cycle = cycle
                return cue
            }
        }
        guard valid else {
            throw MusicError.invalid(
                "Choose 40–160 bpm, up to 90 seconds, with at least half a second between changes. Guide and shell modes need thirds and sevenths."
            )
        }
    }
    public var valid: Bool {
        guard !title.isEmpty, title.count <= 500, (40...160).contains(tempo), (1...4).contains(loops),
            (2...4).contains(beatsPerBar),
            loopLength.isFinite, loopLength > 0, loopLength <= 32, duration <= 90, (1...256).contains(cues.count),
            (0..<1000).contains(from), through >= from, through - from < 8, (1...16).contains(staff), !partID.isEmpty,
            partID.count <= 200,
            (pieceID == nil) == (fingerprint == nil), pieceID.map({ !$0.isEmpty && $0.count <= 100 }) ?? true,
            fingerprint.map(ScoreRevision.valid) ?? true,
            focus.map({ $0.count == 2 && $0[0] >= 0 && $0[1] >= $0[0] && $0[1] < 65 }) ?? true,
            (length - (cues.last?.beat ?? length)) * secondsPerBeat >= 0.5 - 0.000001,
            cues.first?.beat == 0, cues.contains(where: { !$0.isRest })
        else { return false }
        return cues.allSatisfy { cue in
            cue.beat.isFinite && cue.beat >= 0 && cue.beat < length && (from...through).contains(cue.bar)
                && (-1...63).contains(cue.sourceIndex) && (0..<loops).contains(cue.cycle) && cue.symbol.valid
                && (cue.isRest || (try? cue.target(mode)) != nil)
        } && zip(cues.dropFirst(), cues).allSatisfy { ($0.beat - $1.beat) * secondsPerBeat >= 0.5 - 0.000001 }
    }
    public func identity(_ conditions: ChangesTimingConditions) -> String {
        "changes-timed:"
            + ScoreRevision.digest(
                "v1|\(pieceID ?? "ii-v-i")|\(fingerprint ?? "1")|\(from):\(through):\(partID):\(staff)|\(mode)|\(tempo)|\(loops)|\(focus ?? [])|\(conditions.click)|\(conditions.bass)|\(conditions.hints)|\(conditions.offsetMS)"
            )
    }
    public func cueIndex(at seconds: Double) -> Int { cues.lastIndex { $0.beat * secondsPerBeat <= seconds } ?? 0 }
    public func radius(at index: Int) -> Double {
        let before = index > 0 ? cues[index].beat - cues[index - 1].beat : Double(beatsPerBar)
        let after = index + 1 < cues.count ? cues[index + 1].beat - cues[index].beat : length - cues[index].beat
        return min(0.6, min(before, after) * secondsPerBeat * 0.45)
    }
}

/// Raw physical key events, replayed in source-clock order. Pedal is deliberately separate.
public struct ChordKeyEvent: Codable, Equatable, Sendable {
    public var seconds: Double
    public var note: Int
    public var channel: Int
    public var down: Bool
    public var arrivalTimestamp: Bool
    public init(seconds: Double, note: Int, channel: Int = 0, down: Bool, arrivalTimestamp: Bool = false) {
        self.seconds = seconds
        self.note = note
        self.channel = channel
        self.down = down
        self.arrivalTimestamp = arrivalTimestamp
    }
    public var valid: Bool {
        seconds.isFinite && (-7...91).contains(seconds) && (0...127).contains(note) && (0...15).contains(channel)
    }
}
public enum ChangeTiming: String, Sendable {
    case onTime = "On time"
    case early = "Early"
    case late = "Late"
    case held = "Held through"
    case missed = "Not matched"
}
public struct ChangeAssessment: Sendable {
    public var cue: HarmonicCue
    public var timing: ChangeTiming
    public var delta: Double?
    public var notes: [Int]
    public var missing: [Int]
    public var extra: [Int]
    public var bassCorrect: Bool
    public var strayPresses: Int
    public var harmonyCorrect: Bool { timing != .missed }
    public var clean: Bool { (timing == .onTime || timing == .held) && strayPresses == 0 }
}
public struct ChangesTimingReport: Sendable {
    public var changes: [ChangeAssessment]
    public var clean: Bool { !changes.isEmpty && changes.allSatisfy(\.clean) }
    public var harmonicMatches: Int { changes.filter(\.harmonyCorrect).count }
    public var onTime: Int { changes.filter { $0.timing == .onTime || $0.timing == .held }.count }
    public var recoveryCount: Int { zip(changes, changes.dropFirst()).filter { !$0.clean && $1.clean }.count }
    public var difficultIndex: Int? { changes.firstIndex { !$0.clean } }
}
public enum ChangesTimingMatcher {
    private struct Moment {
        var time: Double
        var notes: [Int]
    }
    public static func assess(_ plan: TimedChangesPlan, events: [ChordKeyEvent]) throws -> ChangesTimingReport {
        guard plan.valid, events.count <= 4096,
            events.allSatisfy({ $0.valid && $0.seconds >= -plan.countIn - 0.25 && $0.seconds <= plan.duration + 0.5 })
        else { throw MusicError.invalid("This chord pass contains invalid input.") }
        let ordered = events.enumerated().sorted {
            $0.element.seconds == $1.element.seconds ? $0.offset < $1.offset : $0.element.seconds < $1.element.seconds
        }.map(\.element)
        var keys = Set<MIDIKey>()
        var moments = [Moment(time: -plan.countIn - 0.25, notes: [])]
        for group in Dictionary(grouping: ordered, by: \.seconds).sorted(by: { $0.key < $1.key }) {
            for event in group.value {
                let key = MIDIKey(channel: event.channel, note: event.note)
                if event.down { keys.insert(key) } else { keys.remove(key) }
            }
            let notes = Array(Set(keys.map(\.note))).sorted()
            if notes != moments.last!.notes { moments.append(Moment(time: group.key, notes: notes)) }
        }
        var results: [ChangeAssessment] = []
        for (index, cue) in plan.cues.enumerated() {
            let target = try cue.target(plan.mode)
            let onset = cue.beat * plan.secondsPerBeat
            let radius = plan.radius(at: index)
            let lo = onset - radius
            let hi = onset + radius
            func judgement(_ notes: [Int]) -> ChordJudgement {
                if let target { return target.judge(notes) }
                return ChordJudgement(missing: [], extra: Array(Set(notes.map { mod($0) })).sorted(), bassCorrect: true)
            }
            var matching: Moment?
            var best = moments.last(where: { $0.time <= onset }) ?? moments[0]
            func score(_ moment: Moment) -> Int {
                let j = judgement(moment.notes)
                return j.missing.count + j.extra.count + (j.bassCorrect ? 0 : 1)
            }
            for (i, moment) in moments.enumerated() {
                let end = i + 1 < moments.count ? moments[i + 1].time : plan.duration + 0.6
                guard moment.time <= hi, end >= lo else { continue }
                if score(moment) < score(best) { best = moment }
                // A fleeting intermediate shape is not a completed transition.
                if judgement(moment.notes).correct, end - max(lo, moment.time) >= plan.settle, matching == nil {
                    matching = moment
                }
            }
            let previous = index > 0 ? try plan.cues[index - 1].target(plan.mode) : nil
            let same =
                index > 0 && previous?.pitchClasses == target?.pitchClasses && previous?.bass?.pc == target?.bass?.pc
            let played = matching ?? best
            let j = judgement(played.notes)
            let delta = matching.map { $0.time - onset }
            let timing: ChangeTiming
            if let delta {
                if delta < -radius && (same || cue.isRest) {
                    timing = .held
                } else {
                    timing = abs(delta) <= plan.tolerance + 0.000001 ? .onTime : delta < 0 ? .early : .late
                }
            } else {
                timing = .missed
            }
            let allowed = target?.pitchClasses ?? []
            let strays = ordered.filter { e in
                e.down && e.seconds >= lo && e.seconds <= hi && !allowed.contains(mod(e.note))
                    && !(e.seconds < onset && (previous?.pitchClasses.contains(mod(e.note)) ?? false))
            }.count
            results.append(
                ChangeAssessment(
                    cue: cue, timing: timing, delta: timing == .held ? nil : delta, notes: played.notes,
                    missing: j.missing, extra: j.extra, bassCorrect: j.bassCorrect, strayPresses: strays))
        }
        return ChangesTimingReport(changes: results)
    }
}

public struct TimedChangesResult: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var plan: TimedChangesPlan
    public var conditions: ChangesTimingConditions
    public var events: [ChordKeyEvent]
    public init(
        id: UUID = UUID(), date: Date = Date(), plan: TimedChangesPlan, conditions: ChangesTimingConditions,
        events: [ChordKeyEvent]
    ) {
        self.id = id
        self.date = date
        self.plan = plan
        self.conditions = conditions
        self.events = events
    }
    public var valid: Bool {
        plan.valid && conditions.valid && date.timeIntervalSince1970.isFinite && events.count <= 4096
            && events.allSatisfy { $0.valid && $0.seconds >= -plan.countIn - 0.25 && $0.seconds <= plan.duration + 0.5 }
    }
    public var practiceID: String { plan.identity(conditions) }
    public var report: ChangesTimingReport {
        (try? ChangesTimingMatcher.assess(plan, events: events)) ?? ChangesTimingReport(changes: [])
    }
    public var assisted: Bool { conditions.hints || conditions.bass || events.contains(where: \.arrivalTimestamp) }
    public var grade: ReviewGrade { valid && report.clean ? (assisted ? .supported : .good) : .again }
    public var evidence: String {
        let report = report
        return
            "Timed chord transitions, \(plan.mode.rawValue), bars \(plan.from+1)–\(plan.through+1), staff \(plan.staff), \(plan.tempo) bpm, \(plan.loops) loops, \(plan.focus == nil ? "full selection" : "isolated transition"): \(report.harmonicMatches)/\(report.changes.count) harmonies matched, \(report.onTime) on time or held through, \(report.recoveryCount) recoveries. Click \(conditions.click), bass \(conditions.bass), hints \(conditions.hints), offset \(conditions.offsetMS) ms. Checks physical key sets stable for 60 ms in bounded transition windows; ±100 ms timing tolerance. Between-change playing, durations, pedal and technique not graded."
    }
}
public struct TimedChangesProgress: Codable, Equatable, Sendable {
    public var latest: TimedChangesResult
    public var review = ReviewSchedule()
    public init(result: TimedChangesResult) { latest = result }
}
