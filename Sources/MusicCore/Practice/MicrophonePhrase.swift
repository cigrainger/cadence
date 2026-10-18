// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum MicrophonePhraseMode: String, Codable, CaseIterable, Sendable {
    case opening, focused, context, independent
}

/// The entire reviewed source stays attached even when the invitation narrows.
/// Bars are absolute and one-based; timed targets use relative beats and zero-based bars.
public struct MicrophonePhrasePlan: Codable, Equatable, Sendable {
    public var material: ScoreEarMaterial
    public var tempo: Int
    public var fromBar: Int
    public var throughBar: Int
    public var mode: MicrophonePhraseMode
    public private(set) var beatsPerBar: Int
    /// Absolute beat of the ORIGINAL material, before any focus selection.
    public private(set) var sourceStart: Double

    /// ScoreEarMaterial does not retain meter or absolute start. Supply the current
    /// source when first opening a phrase rather than inferring meter from its length.
    public init(
        material: ScoreEarMaterial, tempo: Int = 80, fromBar: Int? = nil, throughBar: Int? = nil,
        mode: MicrophonePhraseMode = .opening, source: LibraryPiece? = nil
    ) throws {
        guard let source, material.isCurrent(in: source) else {
            throw MusicError.invalid("Reopen this reviewed phrase from its current full score before recording.")
        }
        let study = try ScoreEarMaterial.study(piece: source, scope: material.scope)
        guard let meter = study.selectedMeasures.first, (2...4).contains(meter.beats), meter.beatUnit == 4,
            study.selectedMeasures.allSatisfy({
                $0.beats == meter.beats && $0.beatUnit == 4 && abs($0.duration - Double(meter.beats)) < 0.00001
            })
        else {
            throw MusicError.invalid("Choose 1–4 complete bars in one meter: 2/4, 3/4 or 4/4.")
        }
        self.material = material
        self.tempo = tempo
        self.fromBar = fromBar ?? material.scope.fromBar
        self.throughBar = throughBar ?? material.scope.throughBar
        self.mode = mode
        beatsPerBar = meter.beats
        sourceStart = study.start
        try check()
    }

    public var key: String { material.id }
    public var isFullPhrase: Bool { fromBar == material.scope.fromBar && throughBar == material.scope.throughBar }
    private var start: Double { Double(fromBar - material.scope.fromBar) * Double(beatsPerBar) }
    private var end: Double { Double(throughBar - material.scope.fromBar + 1) * Double(beatsPerBar) }
    private var selectedNotes: [ScoreNote] {
        material.melody.filter { $0.start >= start - 0.00001 && $0.start < end - 0.00001 }
    }

    public var timed: TimedPracticePlan { TimedPracticePlan(microphonePhrase: self) }
    public var valid: Bool {
        guard material.valid, (50...140).contains(tempo), (2...4).contains(beatsPerBar),
            sourceStart.isFinite, (0..<100000).contains(sourceStart),
            abs(material.beats - Double(material.scope.throughBar - material.scope.fromBar + 1) * Double(beatsPerBar))
                < 0.00001,
            fromBar >= material.scope.fromBar, throughBar <= material.scope.throughBar, fromBar <= throughBar,
            mode == .focused || isFullPhrase || mode == .context,
            material.melody.allSatisfy({ (40...88).contains($0.midi) }),
            !selectedNotes.isEmpty,
            material.melody.allSatisfy({ note in
                // A merged tie crossing a selected edge must be included in full.
                !(note.start < start - 0.00001 && note.start + note.duration > start + 0.00001)
                    && !(note.start < end - 0.00001 && note.start + note.duration > end + 0.00001)
            }),
            zip(material.melody, material.melody.dropFirst()).allSatisfy({
                ($1.start - $0.start) * 60 / Double(tempo) >= 0.220 - 0.000001
            })
        else { return false }
        return timed.valid
    }

    private func check() throws {
        guard valid else {
            throw MusicError.invalid(
                "Choose a reviewed single-note voice, 1–4 complete bars, pitches 40–88, at 50–140 bpm with at least 220 ms between attacks. Include complete ties at both edges."
            )
        }
    }

    /// A focus bar is an absolute, one-based source bar. Merged ties can expand it.
    public func focused(around bar: Int) throws -> Self {
        guard valid, (material.scope.fromBar...material.scope.throughBar).contains(bar) else {
            throw MusicError.invalid("Choose a focus bar inside the original phrase.")
        }
        return try selecting(from: bar, through: bar, mode: .focused)
    }

    public func surrounding() throws -> Self {
        guard valid else {
            try check()
            return self
        }
        return try selecting(
            from: max(material.scope.fromBar, fromBar - 1),
            through: min(material.scope.throughBar, throughBar + 1), mode: .context)
    }

    /// Changing the invitation never creates another review identity.
    public func configured(tempo: Int? = nil, mode: MicrophonePhraseMode? = nil) throws -> Self {
        var copy = self
        copy.tempo = tempo ?? self.tempo
        copy.mode = mode ?? self.mode
        try copy.check()
        return copy
    }

    public func whole(tempo: Int? = nil, mode: MicrophonePhraseMode = .opening) throws -> Self {
        var copy = self
        copy.fromBar = material.scope.fromBar
        copy.throughBar = material.scope.throughBar
        return try copy.configured(tempo: tempo, mode: mode)
    }

    fileprivate func sameSource(as other: Self) -> Bool {
        beatsPerBar == other.beatsPerBar && sourceStart == other.sourceStart
            && Self.semantic(material) == Self.semantic(other.material)
    }

    private static func semantic(_ material: ScoreEarMaterial) -> ScoreEarMaterial {
        var copy = material
        copy.title = ""
        copy.scope.partName = ""
        for index in copy.melody.indices {
            copy.melody[index].id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        }
        return copy
    }

    private func selecting(from: Int, through: Int, mode: MicrophonePhraseMode) throws -> Self {
        var copy = self
        copy.fromBar = from
        copy.throughBar = through
        copy.mode = mode
        var changed = true
        while changed {
            changed = false
            for note in material.melody {
                if note.start < copy.end - 0.00001 && note.start + note.duration > copy.start + 0.00001 {
                    let first = material.scope.fromBar + Int(floor(note.start / Double(beatsPerBar)))
                    let last =
                        material.scope.fromBar
                        + Int(floor((note.start + note.duration - 0.00001) / Double(beatsPerBar)))
                    let lower = min(copy.fromBar, first)
                    let upper = max(copy.throughBar, last)
                    changed = changed || lower != copy.fromBar || upper != copy.throughBar
                    copy.fromBar = lower
                    copy.throughBar = upper
                }
            }
        }
        try copy.check()
        return copy
    }

    /// The parent must repeat this current-source check before capture and commit.
    public func isCurrent(in piece: LibraryPiece) -> Bool {
        guard valid,
            let fresh = try? Self(
                material: material, tempo: tempo, fromBar: fromBar, throughBar: throughBar, mode: mode, source: piece)
        else { return false }
        return fresh == self
    }
}

extension TimedPracticePlan {
    fileprivate init(microphonePhrase plan: MicrophonePhrasePlan) {
        let material = plan.material
        guard material.valid, (2...4).contains(plan.beatsPerBar),
            plan.fromBar >= material.scope.fromBar, plan.throughBar <= material.scope.throughBar,
            plan.fromBar <= plan.throughBar
        else {
            title = material.title
            rhythmID = nil
            source = nil
            targets = []
            tempo = plan.tempo
            beatsPerBar = plan.beatsPerBar
            length = 0
            return
        }
        let start = Double(plan.fromBar - material.scope.fromBar) * Double(plan.beatsPerBar)
        let end = Double(plan.throughBar - material.scope.fromBar + 1) * Double(plan.beatsPerBar)
        title = material.title
        rhythmID = nil
        tempo = plan.tempo
        beatsPerBar = plan.beatsPerBar
        length = max(0, end - start)
        source = TimedSource(
            studyID: UUID(uuidString: String(material.pieceID.split(separator: ":").last ?? ""))
                ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            pieceID: material.pieceID, fingerprint: material.fingerprint,
            scope: PassageScope(
                partID: material.scope.partID, staff: material.staff, from: plan.fromBar - 1,
                through: plan.throughBar - 1), startBeat: plan.sourceStart + start)
        targets = material.melody.filter { $0.start >= start - 0.00001 && $0.start < end - 0.00001 }.map {
            TimedTarget(
                beat: max(0, $0.start - start),
                bar: material.scope.fromBar - 1 + Int(floor(max(0, $0.start) / Double(max(1, plan.beatsPerBar)))),
                pitch: $0.midi)
        }
    }
}

/// Only the native capture owner can assert a shared input/output host-clock origin.
/// Unknown clock evidence is retained, but cannot be matched using arrival time.
public enum MicrophonePhraseClock: String, Codable, Sendable { case unknown, sharedHost }

public enum MicrophonePhrasePitchVerdict: String, Codable, Sendable {
    case matched, wrong, missing, uncertain, disputed
    public var label: String {
        switch self {
        case .matched: "Pitch matched"
        case .wrong: "Different pitch"
        case .missing: "No attack matched"
        case .uncertain: "Pitch inconclusive"
        case .disputed: "Match disputed"
        }
    }
    fileprivate var conclusive: Bool { self == .matched || self == .wrong || self == .missing }
}

public enum MicrophonePhraseTimingVerdict: String, Codable, Sendable {
    case onTime, early, late, missing, uncalibrated, uncertain, disputed
    public var label: String {
        switch self {
        case .onTime: "Within onset tolerance"
        case .early: "Earlier entrance"
        case .late: "Later entrance"
        case .missing: "No attack matched"
        case .uncalibrated: "Timing uncalibrated"
        case .uncertain: "Timing inconclusive"
        case .disputed: "Match disputed"
        }
    }
    fileprivate var conclusive: Bool { self == .onTime || self == .early || self == .late || self == .missing }
}

public struct MicrophonePhraseNote: Equatable, Sendable {
    public var target: TimedTarget
    public var index: Int
    public var attack: AcousticAttack?
    /// Display estimates rounded to 10 ms; verdicts are computed before rounding.
    public var deltaMS: Double?
    /// Deviation from the target sounding pitch, rounded to 5 cents.
    public var cents: Double?
    public var uncertaintyMS: Double?
    public var toleranceMS: Double?
    public var pitch: MicrophonePhrasePitchVerdict
    public var timing: MicrophonePhraseTimingVerdict
    public var conclusive: Bool { pitch.conclusive && timing.conclusive }
    public var clean: Bool { pitch == .matched && timing == .onTime }
}

public struct MicrophonePhraseReport: Equatable, Sendable {
    public var notes: [MicrophonePhraseNote]
    public var extras: [AcousticAttack]
    public var conclusive: Bool
    public var clean: Bool { conclusive && !notes.isEmpty && notes.allSatisfy(\.clean) && extras.isEmpty }
    public var focusBar: Int? { notes.first { !$0.clean }.map { $0.target.bar + 1 } }
    public var suggestion: String
    public var matchedPitch: Int { notes.filter { $0.pitch == .matched }.count }
    public var wrongPitch: Int { notes.filter { $0.pitch == .wrong }.count }
    public var missing: Int { notes.filter { $0.pitch == .missing }.count }
    public var onTime: Int { notes.filter { $0.timing == .onTime }.count }
    public var early: Int { notes.filter { $0.timing == .early }.count }
    public var late: Int { notes.filter { $0.timing == .late }.count }
}

public struct MicrophonePhraseTake: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var plan: MicrophonePhrasePlan
    public var originHostSeconds: Double
    public var calibration: AcousticCalibration?
    public var routeID: String
    public var sampleRate: Double
    public var attacks: [AcousticAttack]
    public var signalIssue: String?
    /// Indices into plan.timed.targets, never edits to the raw detector observations.
    public var disputedTargets: [Int]
    public var clock: MicrophonePhraseClock
    public var usedHint: Bool
    /// Input sample/host mapping retained independently of the declared clock kind.
    /// Native attack uncertainty already includes this take anchor's allowance.
    public var clockEvidence: AcousticClockEvidence?
    /// Earlier-source evidence may be retained without granting current-score credit.
    /// Nil preserves legacy records and means an ordinary take.
    public var archivalOnly: Bool?
    public var isArchivalOnly: Bool { archivalOnly == true }

    public init(
        id: UUID = UUID(), date: Date = Date(), plan: MicrophonePhrasePlan, originHostSeconds: Double,
        calibration: AcousticCalibration? = nil, routeID: String, sampleRate: Double, attacks: [AcousticAttack],
        signalIssue: String? = nil, disputedTargets: [Int] = [], clock: MicrophonePhraseClock = .unknown,
        usedHint: Bool = false, clockEvidence: AcousticClockEvidence? = nil, archivalOnly: Bool? = nil
    ) {
        self.id = id
        self.date = date
        self.plan = plan
        self.originHostSeconds = originHostSeconds
        self.calibration = calibration
        self.routeID = routeID
        self.sampleRate = sampleRate
        self.attacks = attacks
        self.signalIssue = signalIssue
        self.disputedTargets = disputedTargets
        self.clock = clock
        self.usedHint = usedHint
        self.clockEvidence = clockEvidence
        self.archivalOnly = archivalOnly
    }

    public var valid: Bool {
        guard plan.valid, date.timeIntervalSince1970.isFinite, originHostSeconds.isFinite, originHostSeconds >= 0,
            sampleRate.isFinite, (8000...192000).contains(sampleRate), originHostSeconds.ulp <= 1 / sampleRate,
            clockEvidence.map({ $0.valid && $0.sampleRate == sampleRate }) ?? true,
            !routeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, routeID.utf8.count <= 256,
            attacks.count <= 128, Set(attacks.map(\.id)).count == attacks.count,
            attacks.allSatisfy({ attack in
                attack.valid && attack.hostSeconds.ulp <= 1 / sampleRate
                    && (-0.5...plan.timed.duration + 1).contains(attack.hostSeconds - originHostSeconds)
                    && (clockEvidence.map({ $0.sampleTime(at: attack.hostSeconds) != nil }) ?? true)
                    && (attack.sampleTime == nil) == (attack.sampleRate == nil)
                    && (attack.sampleRate.map({ $0 == sampleRate }) ?? true)
                    && (attack.sampleTime.map({ sample in
                        clockEvidence.map { $0.sampleTime(at: attack.hostSeconds) == sample } ?? true
                    }) ?? true)
            }),
            signalIssue.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 500 }) ?? true,
            disputedTargets.count <= plan.timed.targets.count,
            Set(disputedTargets).count == disputedTargets.count,
            disputedTargets.allSatisfy({ plan.timed.targets.indices.contains($0) }),
            !(plan.mode == .independent && usedHint)
        else { return false }
        return calibration.map({ $0.usable(routeID: routeID, sampleRate: sampleRate, now: date) }) ?? true
    }

    public var assisted: Bool { plan.mode != .independent || usedHint }
    public var report: MicrophonePhraseReport { MicrophonePhraseMatcher.assess(self) }

    fileprivate var calibratedClock: Bool {
        clock == .sharedHost && clockEvidence?.usable == true
            && calibration?.clockEvidence?.usable == true
            && calibration?.usable(routeID: routeID, sampleRate: sampleRate, now: date) == true
            && attacks.allSatisfy { $0.sampleTime != nil && $0.sampleRate == sampleRate }
    }

    /// The existing score renderer receives only calibrated, individually conclusive
    /// observations. Pitch-only observations never acquire an "on time" label.
    public var scoreFeedback: [LiveTimedNote] {
        guard valid, !isArchivalOnly, calibratedClock, signalIssue == nil else { return [] }
        return report.notes.filter(\.conclusive).map { note in
            let attack = note.attack.map {
                TimedAttack(seconds: correctedSeconds($0), pitch: $0.midi ?? note.target.pitch)
            }
            let verdict: OnsetVerdict
            if note.pitch == .missing {
                verdict = .missed
            } else if note.pitch == .wrong {
                verdict = .wrongPitch
            } else if note.timing == .early {
                verdict = .early
            } else if note.timing == .late {
                verdict = .late
            } else {
                verdict = .onTime
            }
            return LiveTimedNote(
                assessment: TimedAssessment(
                    target: note.target, attack: attack, delta: note.deltaMS.map { $0 / 1000 }, verdict: verdict),
                settled: true)
        }
    }

    fileprivate func correctedSeconds(_ attack: AcousticAttack) -> Double {
        // Raw input clocks survive persistence; correction happens exactly here, once.
        attack.hostSeconds - originHostSeconds - (calibration?.offsetMS ?? 0) / 1000
    }

    public var evidence: String {
        let r = report
        let quality: String
        if let calibration, valid, calibratedClock, !isArchivalOnly {
            quality =
                "measured offset about \(rounded(calibration.offsetMS, step: 10)) ms, jitter allowance \(roundedUp(calibration.jitterMS, step: 10)) ms, \(calibration.matchedPulses) pulses"
        } else {
            quality = calibration == nil ? "unavailable; pitch-only evidence" : "unproven or unusable; no timing grade"
        }
        let pitchUncertain = r.notes.filter { $0.pitch == .uncertain }.count
        let timingUncertain = r.notes.filter { $0.timing == .uncertain || $0.timing == .uncalibrated }.count
        let marks = disputedTargets.sorted().map(String.init).joined(separator: ",")
        let issues = signalIssue.map { " Signal flag: \(String($0.prefix(160)))." } ?? ""
        let mapping =
            "Take mapping: \(mappingEvidence(clockEvidence)); calibration mapping: \(mappingEvidence(calibration?.clockEvidence))."
        let result =
            "Microphone single-note phrase, source bars \(plan.fromBar)–\(plan.throughBar), \(plan.tempo) bpm, \(plan.mode.rawValue). \(isArchivalOnly ? "Earlier-version archive only. " : "")Pitch: \(r.matchedPitch) matched, \(r.wrongPitch) different, \(r.missing) unmatched, \(pitchUncertain) uncertain. Timing: \(r.onTime) within tolerance, \(r.early) early, \(r.late) late, \(r.notes.filter { $0.timing == .missing }.count) unmatched, \(timingUncertain) uncertain/uncalibrated. \(r.extras.count) extra candidates; disputed target indices [\(marks)]. Calibration: \(quality); clock \(clock.rawValue). \(mapping) Onset tolerance is at least 60 ms plus measured jitter, attack uncertainty and any separate calibration mapping allowance; display estimates are rounded to 10 ms. \(r.conclusive ? "Conclusive observations." : "Inconclusive; no correctness or proficiency credit.")\(issues) \(r.suggestion) Durations, bends, technique and polyphony are not assessed. Detector confidence is heuristic; this is no diagnosis and grants no automatic AI credit."
        let rows = r.notes.map { note in
            let heard = note.attack?.midi.map { String($0) } ?? "unresolved"
            let cents = note.cents.map { "\(rounded($0, step: 5)) cents" } ?? "unassessed"
            let timing = note.deltaMS.map { "about \(rounded($0, step: 10)) ms" } ?? "unassessed"
            let uncertainty = note.uncertaintyMS.map { "±\(roundedUp($0, step: 10)) ms" } ?? "unknown"
            return
                "bar \(note.target.bar + 1), target MIDI \(note.target.pitch), observed MIDI \(heard): pitch \(note.pitch.rawValue) (\(cents)); timing \(note.timing.rawValue) (\(timing), \(uncertainty))."
        }.joined(separator: "\n")
        return String(
            (result + "\nSource revision: " + plan.material.fingerprint + "\nPer-note evidence:\n" + rows).prefix(5000))
    }
}

private func mappingEvidence(_ evidence: AcousticClockEvidence?) -> String {
    guard let evidence else { return "not retained; timing unproven" }
    guard evidence.valid else { return "invalid sample/host anchor" }
    return
        "\(evidence.version), \(evidence.frameCount) frames at \(rounded(evidence.sampleRate, step: 1)) Hz, maximum host residual ≤\(roundedUp(evidence.maximumHostResidualMS, step: 1)) ms (\(evidence.usable ? "usable" : "unusable"))"
}

private func rounded(_ value: Double, step: Double) -> Int {
    guard value.isFinite, abs(value) < 1_000_000 else { return 0 }
    return Int((value / step).rounded() * step)
}

private func roundedUp(_ value: Double, step: Double) -> Int {
    guard value.isFinite, abs(value) < 1_000_000 else { return 0 }
    return Int(ceil(value / step) * step)
}

private enum MicrophonePhraseMatcher {
    static func reliable(_ attack: AcousticAttack) -> Bool {
        attack.valid && attack.frequency != nil && attack.confidence >= 0.85 && attack.rms >= 0.006
            && attack.clippedFraction < 0.01
    }

    static func assess(_ take: MicrophonePhraseTake) -> MicrophonePhraseReport {
        if take.isArchivalOnly {
            return MicrophonePhraseReport(
                notes: [], extras: Array(take.attacks.prefix(128)), conclusive: false,
                suggestion: "Earlier-version evidence is archived without assessment or current-score credit.")
        }
        guard take.valid else {
            return MicrophonePhraseReport(
                notes: [], extras: Array(take.attacks.prefix(128)), conclusive: false,
                suggestion: "Reopen the current phrase and check capture clocks before another take.")
        }
        let plan = take.plan.timed
        let calibrated = take.calibratedClock
        let usableSignal =
            take.signalIssue == nil && take.clock == .sharedHost
            && (take.clockEvidence?.usable ?? true)
            && take.attacks.contains(where: reliable)
        var buckets = [[AcousticAttack]](repeating: [], count: plan.targets.count)
        var extras: [AcousticAttack] = []
        let ordered = take.attacks.sorted {
            $0.hostSeconds == $1.hostSeconds ? $0.id.uuidString < $1.id.uuidString : $0.hostSeconds < $1.hostSeconds
        }
        // Unknown latency cannot establish disjoint time windows. A pitch-only
        // pass may compare attack ORDER only when every target has one reliable
        // candidate; a missing/extra candidate makes the alignment uncertain.
        if !calibrated {
            if usableSignal, ordered.count == plan.targets.count, ordered.allSatisfy(reliable) {
                for index in ordered.indices { buckets[index] = [ordered[index]] }
            } else {
                extras = ordered
            }
        }
        for attack in ordered where calibrated {
            let seconds = take.correctedSeconds(attack)
            guard take.clock == .sharedHost,
                let nearest = plan.targets.indices.min(by: {
                    abs(plan.targets[$0].beat * plan.secondsPerBeat - seconds)
                        < abs(plan.targets[$1].beat * plan.secondsPerBeat - seconds)
                }),
                abs(seconds - plan.targets[nearest].beat * plan.secondsPerBeat)
                    <= TimedMatcher.windowRadius(plan, beat: plan.targets[nearest].beat) + 0.000001
            else {
                extras.append(attack)
                continue
            }
            buckets[nearest].append(attack)
        }
        var notes: [MicrophonePhraseNote] = []
        // Native onset uncertainty includes the take anchor. Missing attacks have
        // no uncertainty of their own, so cover at least the native 10 ms floor
        // and the largest retained attack allowance, plus the separate calibration.
        let coverageUncertainty =
            max(10, take.attacks.map(\.onsetUncertaintyMS).max() ?? 10)
            + (take.calibration?.jitterMS ?? 0)
            + (take.calibration?.clockEvidence?.mappingAllowanceMS ?? 0)
        let coveredTargets = plan.targets.map { target in
            calibrated && coversWindow(take, target: target, uncertaintyMS: coverageUncertainty)
        }
        for (index, target) in plan.targets.enumerated() {
            let bucket = buckets[index]
            // Two candidates are not resolved by picking whichever flatters the score.
            let attack = bucket.count == 1 ? bucket.first : nil
            if bucket.count > 1 { extras.append(contentsOf: bucket) }
            let delta = attack.map { (take.correctedSeconds($0) - target.beat * plan.secondsPerBeat) * 1000 }
            let cents = attack?.frequency.map { (69 + 12 * log2($0 / 440) - Double(target.pitch)) * 100 }
            // The take anchor is included in native onset uncertainty. Calibration
            // has a separate anchor, so its mapping allowance is added only here.
            let uncertainty = attack.map {
                $0.onsetUncertaintyMS + (take.calibration?.jitterMS ?? 0)
                    + (take.calibration?.clockEvidence?.mappingAllowanceMS ?? 0)
            }
            let tolerance = uncertainty.map { 60 + $0 }
            var pitch: MicrophonePhrasePitchVerdict = .uncertain
            var timing: MicrophonePhraseTimingVerdict = calibrated ? .uncertain : .uncalibrated
            if usableSignal && calibrated && coveredTargets[index] && bucket.isEmpty {
                pitch = .missing
                timing = .missing
            } else if usableSignal, let attack, reliable(attack), let delta, let cents,
                let uncertainty, let tolerance
            {
                let radiusMS = TimedMatcher.windowRadius(plan, beat: target.beat) * 1000
                // If onset uncertainty crosses a window boundary, ownership is uncertain.
                if !calibrated || abs(delta) + uncertainty <= radiusMS + 0.000001 {
                    pitch = abs(cents) <= 45 + 0.000001 ? .matched : .wrong
                    if calibrated && coveredTargets[index] && attack.onsetUncertaintyMS <= 40 {
                        timing = abs(delta) <= tolerance + 0.000001 ? .onTime : delta < 0 ? .early : .late
                    }
                }
            }
            if take.disputedTargets.contains(index) {
                pitch = .disputed
                timing = .disputed
            }
            notes.append(
                MicrophonePhraseNote(
                    target: target, index: index, attack: attack,
                    deltaMS: calibrated && usableSignal ? delta.map { Double(rounded($0, step: 10)) } : nil,
                    cents: usableSignal ? cents.map { Double(rounded($0, step: 5)) } : nil,
                    uncertaintyMS: calibrated ? uncertainty.map { Double(roundedUp($0, step: 10)) } : nil,
                    toleranceMS: calibrated ? tolerance.map { Double(roundedUp($0, step: 10)) } : nil,
                    pitch: pitch, timing: timing))
        }
        extras.sort {
            $0.hostSeconds == $1.hostSeconds ? $0.id.uuidString < $1.id.uuidString : $0.hostSeconds < $1.hostSeconds
        }
        let conclusive =
            usableSignal && calibrated && coveredTargets.allSatisfy { $0 } && notes.allSatisfy(\.conclusive)
            && extras.allSatisfy { reliable($0) && $0.onsetUncertaintyMS <= 40 }
        let suggestion: String
        if !calibrated && usableSignal {
            suggestion =
                ordered.count == plan.targets.count && ordered.allSatisfy(reliable)
                ? "Pitch-only comparison follows attack order. Timing and time-window ownership remain unassessed."
                : "The attack count is uncertain, so pitch-only notes cannot be aligned safely. Inspect the heard pitches and try again."
        } else if !conclusive {
            suggestion = "Check the clean single-note input and calibration, then try one short take again."
        } else if let note = notes.first(where: { !$0.clean }) {
            suggestion = "Try source bar \(note.target.bar + 1) once slowly, then return to its surrounding phrase."
        } else if !extras.isEmpty {
            suggestion = "Try the phrase once more with one clear attack per written entrance."
        } else {
            suggestion =
                "Keep this take as evidence and return to the complete phrase after a day without a demonstration."
        }
        return MicrophonePhraseReport(notes: notes, extras: extras, conclusive: conclusive, suggestion: suggestion)
    }

    private static func coversWindow(
        _ take: MicrophonePhraseTake, target: TimedTarget, uncertaintyMS: Double
    ) -> Bool {
        guard let mapping = take.clockEvidence, mapping.usable, let calibration = take.calibration else {
            return false
        }
        let plan = take.plan.timed
        // Compare the complete disjoint target window in ORIGINAL input time.
        // The offset moves both edges; calibration and onset allowances expand
        // them. Seeing one reliable note never proves later silent audio exists.
        let center = take.originHostSeconds + target.beat * plan.secondsPerBeat + calibration.offsetMS / 1000
        let radius = TimedMatcher.windowRadius(plan, beat: target.beat) + uncertaintyMS / 1000
        let first = (center - radius - mapping.firstHostSeconds) * mapping.sampleRate
        let end = (center + radius - mapping.firstHostSeconds) * mapping.sampleRate
        return first >= -0.000001 && end <= Double(mapping.frameCount) + 0.000001
    }
}

/// Evidence is bounded without silently evicting a baseline or an old score revision.
public struct MicrophonePhraseProgress: Codable, Equatable, Identifiable, Sendable {
    public var sourcePlan: MicrophonePhrasePlan
    public var takes: [MicrophonePhraseTake] = []
    public var review = ReviewSchedule()
    /// Keep the bounded hearing history so delayed-return rules can be revalidated.
    public var demonstrations: [Date] = []
    /// Exposure still matters when the learner chooses not to keep a raw take.
    /// One date per interval between independent returns is sufficient for replay.
    public var unkeptPracticeDates: [Date] = []
    public var material: ScoreEarMaterial { sourcePlan.material }
    public var id: String { material.id }
    public var latest: MicrophonePhraseTake? { takes.last }
    public var lastDemonstration: Date? { demonstrations.last }
    public var lastPractice: Date? { (takes.map(\.date) + unkeptPracticeDates).max() }
    public var returnDate: Date? {
        (takes.map(\.date) + demonstrations + unkeptPracticeDates).max()?.addingTimeInterval(20 * 3600)
    }
    public var baseline: MicrophonePhraseTake? {
        takes.first { !$0.isArchivalOnly && $0.plan.mode == .opening && $0.plan.isFullPhrase && $0.report.conclusive }
    }

    public init(plan: MicrophonePhrasePlan) throws {
        sourcePlan = try plan.whole(mode: .opening)
    }

    public func plan(tempo: Int = 80, mode: MicrophonePhraseMode = .opening) throws -> MicrophonePhrasePlan {
        try sourcePlan.whole(tempo: tempo, mode: mode)
    }
}

/// A staged value only. PracticeWorkspace must persist this and the returned journal
/// attempt together, publishing neither if its single snapshot commit fails.
public struct MicrophonePhrasePractice: Codable, Equatable, Sendable {
    public var sessions: [MicrophonePhraseProgress] = []
    public var selectedID: String?
    public init() {}
    public var active: MicrophonePhraseProgress? { sessions.first { $0.id == selectedID } }

    public mutating func open(_ material: ScoreEarMaterial, source: LibraryPiece? = nil) throws {
        try open(MicrophonePhrasePlan(material: material, tempo: 50, source: source))
    }

    public mutating func open(_ plan: MicrophonePhrasePlan) throws {
        _ = try validated()
        guard plan.valid else { throw MusicError.invalid("This microphone phrase plan is invalid.") }
        var copy = self
        if let index = sessions.firstIndex(where: { $0.id == plan.key }) {
            guard sessions[index].sourcePlan.sameSource(as: plan) else {
                throw MusicError.invalid("The phrase identity does not match its saved source. Reopen the full score.")
            }
        } else {
            guard sessions.count < 32 else {
                throw MusicError.invalid("The 32 saved microphone phrases are full. Existing evidence is preserved.")
            }
            copy.sessions.append(try MicrophonePhraseProgress(plan: plan))
        }
        copy.selectedID = plan.key
        _ = try copy.validated()
        self = copy
    }

    /// Uses overlapping phrase history across retained score versions, not tempo,
    /// offset, mode or focus as a way to obtain another independent encounter.
    public func returnDate(_ materialID: String) -> Date? {
        guard let progress = sessions.first(where: { $0.id == materialID }) else { return nil }
        return sessions.filter { Self.related($0.material, progress.material) }.flatMap {
            $0.takes.map(\.date) + $0.demonstrations + $0.unkeptPracticeDates
        }.max()?.addingTimeInterval(20 * 3600)
    }

    @discardableResult
    public mutating func record(_ take: MicrophonePhraseTake, source: LibraryPiece) throws -> PracticeAttempt? {
        guard take.plan.isCurrent(in: source) else {
            throw MusicError.invalid("The reviewed score changed before this take was saved. Reopen the full score.")
        }
        return try record(take)
    }

    /// Use the source-taking overload at the workspace boundary, or perform its
    /// current-source check in the parent's transaction before calling this method.
    @discardableResult
    public mutating func record(_ take: MicrophonePhraseTake) throws -> PracticeAttempt? {
        _ = try validated()
        guard !take.isArchivalOnly else {
            throw MusicError.invalid(
                "Use the archive action to retain earlier-version evidence without a journal grade.")
        }
        if let existing = sessions.flatMap(\.takes).first(where: { $0.id == take.id }) {
            guard existing == take else {
                throw MusicError.invalid("This take ID already belongs to different microphone evidence.")
            }
            return nil
        }
        guard take.valid, let index = sessions.firstIndex(where: { $0.id == selectedID }),
            sessions[index].id == take.plan.key, sessions[index].sourcePlan.sameSource(as: take.plan),
            isLatestVersion(sessions[index]),
            sessions[index].takes.last.map({ $0.date <= take.date }) ?? true,
            sessions[index].lastDemonstration.map({ $0 <= take.date }) ?? true
        else {
            throw MusicError.invalid("This take is stale or does not match the active reviewed score, route or clocks.")
        }
        if let latestExposure = returnDate(take.plan.key)?.addingTimeInterval(-20 * 3600), latestExposure > take.date {
            throw MusicError.invalid("This take predates the saved practice or hearing history. Reopen the phrase.")
        }
        guard sessions[index].takes.count < 16 else {
            throw MusicError.invalid("The 16 saved takes for this phrase are full. Existing evidence is preserved.")
        }
        try checkIndependent(take, in: sessions[index])
        var copy = self
        copy.sessions[index].takes.append(take)
        copy.sessions[index].review = Self.rebuiltReview(copy.sessions[index].takes)
        _ = try copy.validated()
        let attempt = Self.attempt(take)
        guard attempt.valid else { throw MusicError.invalid("This microphone journal observation is invalid.") }
        self = copy
        return attempt
    }

    /// Retains an explicitly marked take against its original saved source, even
    /// after selection or the current version changes. No journal entry or review
    /// is produced, and an archived independent take needs no credit eligibility.
    public mutating func archive(_ take: MicrophonePhraseTake) throws {
        _ = try validated()
        guard take.isArchivalOnly else {
            throw MusicError.invalid("Mark this take as archive-only before retaining earlier-version evidence.")
        }
        if let existing = sessions.flatMap(\.takes).first(where: { $0.id == take.id }) {
            guard existing == take else {
                throw MusicError.invalid("This take ID already belongs to different microphone evidence.")
            }
            return
        }
        guard take.valid, let index = sessions.firstIndex(where: { $0.id == take.plan.key }),
            sessions[index].sourcePlan.sameSource(as: take.plan),
            sessions[index].takes.last.map({ $0.date <= take.date }) ?? true
        else { throw MusicError.invalid("This archived take does not match its original saved phrase or date order.") }
        guard sessions[index].takes.count < 16 else {
            throw MusicError.invalid("The 16 saved takes for this phrase are full. Existing evidence is preserved.")
        }
        var copy = self
        copy.sessions[index].takes.append(take)
        _ = try copy.validated()
        self = copy
    }

    public mutating func noteDemonstration(materialID: String, now: Date = Date()) throws {
        _ = try validated()
        guard now.timeIntervalSince1970.isFinite,
            let index = sessions.firstIndex(where: { $0.id == materialID }), isLatestVersion(sessions[index]),
            sessions[index].takes.last.map({ $0.date <= now }) ?? true,
            sessions[index].lastDemonstration.map({ $0 <= now }) ?? true
        else { throw MusicError.invalid("Reopen the current phrase before recording a demonstration.") }
        if sessions[index].lastDemonstration == now { return }
        guard sessions[index].demonstrations.count < 64 else {
            throw MusicError.invalid("The saved demonstration history is full. Existing evidence is preserved.")
        }
        var copy = self
        copy.sessions[index].demonstrations.append(now)
        _ = try copy.validated()
        self = copy
    }

    /// Call when discarding/retrying a played take. No detector result or grade is
    /// invented. Coalescing dates after the last independent return keeps unlimited
    /// unkept retries possible without invalidating historical return eligibility.
    public mutating func notePractice(materialID: String, now: Date = Date()) throws {
        _ = try validated()
        guard now.timeIntervalSince1970.isFinite,
            let index = sessions.firstIndex(where: { $0.id == materialID })
        else { throw MusicError.invalid("Reopen the current phrase before noting practice exposure.") }
        // A later related encounter already delays recall at least as far as this
        // save-only recovery. Never move history backwards or wedge a retry.
        if let latest = returnDate(materialID)?.addingTimeInterval(-20 * 3600), latest > now { return }

        var copy = self
        let previous = sessions[index].unkeptPracticeDates.last
        if previous == now { return }
        if let previous,
            !sessions[index].takes.contains(where: {
                !$0.isArchivalOnly && $0.plan.mode == .independent && $0.date >= previous
            })
        {
            copy.sessions[index].unkeptPracticeDates[copy.sessions[index].unkeptPracticeDates.count - 1] = now
        } else {
            guard sessions[index].unkeptPracticeDates.count < 17 else {
                throw MusicError.invalid("The saved practice exposure history is full. Existing evidence is preserved.")
            }
            copy.sessions[index].unkeptPracticeDates.append(now)
        }
        _ = try copy.validated()
        self = copy
    }

    public func validated() throws -> Self {
        guard sessions.count <= 32, Set(sessions.map(\.id)).count == sessions.count,
            selectedID == nil || sessions.contains(where: { $0.id == selectedID })
        else { throw MusicError.invalid("Invalid saved microphone phrase collection.") }
        var ids = Set<UUID>()
        for session in sessions {
            guard session.sourcePlan.valid, session.sourcePlan.isFullPhrase, session.sourcePlan.mode == .opening,
                session.takes.count <= 16, session.demonstrations.count <= 64,
                session.unkeptPracticeDates.count <= 17,
                session.demonstrations.allSatisfy({ $0.timeIntervalSince1970.isFinite }),
                session.unkeptPracticeDates.allSatisfy({ $0.timeIntervalSince1970.isFinite }),
                zip(session.demonstrations, session.demonstrations.dropFirst()).allSatisfy({ $0 < $1 }),
                zip(session.unkeptPracticeDates, session.unkeptPracticeDates.dropFirst()).allSatisfy({ $0 < $1 }),
                zip(session.takes, session.takes.dropFirst()).allSatisfy({ $0.date <= $1.date }),
                session.review.valid, session.review == Self.rebuiltReview(session.takes)
            else { throw MusicError.invalid("Invalid saved microphone phrase progress or review schedule.") }
            for take in session.takes {
                guard take.valid, ids.insert(take.id).inserted, take.plan.key == session.id,
                    session.sourcePlan.sameSource(as: take.plan)
                else { throw MusicError.invalid("Invalid or mismatched saved microphone take.") }
                try checkIndependent(take, in: session)
            }
        }
        return self
    }

    private func isLatestVersion(_ progress: MicrophonePhraseProgress) -> Bool {
        sessions.last { $0.material.pieceID == progress.material.pieceID }?.material.fingerprint
            == progress.material.fingerprint
    }

    private static func related(_ a: ScoreEarMaterial, _ b: ScoreEarMaterial) -> Bool {
        a.pieceID == b.pieceID && a.scope.partID == b.scope.partID && a.staff == b.staff && a.voice == b.voice
            && a.scope.fromBar <= b.scope.throughBar && b.scope.fromBar <= a.scope.throughBar
    }

    private func checkIndependent(_ take: MicrophonePhraseTake, in progress: MicrophonePhraseProgress) throws {
        guard !take.isArchivalOnly, take.plan.mode == .independent else { return }
        let baseline = progress.takes.first {
            !$0.isArchivalOnly && $0.id != take.id && $0.date < take.date && $0.plan.mode == .opening
                && $0.plan.isFullPhrase
                && $0.report.conclusive
        }
        let previous = sessions.filter { Self.related($0.material, take.plan.material) }.flatMap {
            $0.takes.filter { $0.id != take.id && $0.date <= take.date }.map(\.date)
                + $0.demonstrations.filter { $0 <= take.date }
                + $0.unkeptPracticeDates.filter { $0 <= take.date }
        }.max()
        guard take.plan.isFullPhrase, !take.usedHint, let baseline, take.plan.tempo == baseline.plan.tempo,
            let previous, take.date.timeIntervalSince(previous) >= 20 * 3600
        else {
            throw MusicError.invalid(
                "An independent return needs the complete phrase at its saved baseline tempo, at least 20 hours after practice or hearing it, without hints or a demonstration."
            )
        }
    }

    private static func rebuiltReview(_ takes: [MicrophonePhraseTake]) -> ReviewSchedule {
        var review = ReviewSchedule()
        var baselineTempo: Int?
        for take in takes where !take.isArchivalOnly && take.valid && take.report.conclusive {
            if baselineTempo == nil && take.plan.mode == .opening && take.plan.isFullPhrase {
                baselineTempo = take.plan.tempo
                // A guided baseline invites a return but cannot advance mastery.
                review.record(
                    take.report.clean ? .supported : .again, episode: take.id, input: .microphone, now: take.date)
            } else if take.plan.mode == .independent && take.plan.isFullPhrase && take.plan.tempo == baselineTempo {
                review.record(take.report.clean ? .good : .again, episode: take.id, input: .microphone, now: take.date)
            }
        }
        return review
    }

    private static func attempt(_ take: MicrophonePhraseTake) -> PracticeAttempt {
        let report = take.report
        var skills = ["microphone-phrase-\(take.plan.mode.rawValue)"]
        // The shared journal has one outcome per attempt. On a failed phrase,
        // tag only failed dimensions so a pitch error is not a timing failure.
        if !report.conclusive || report.clean {
            skills += ["microphone-pitch", "microphone-onset"]
        } else {
            if report.notes.contains(where: { $0.pitch != .matched }) { skills.append("microphone-pitch") }
            if report.notes.contains(where: { $0.timing != .onTime }) { skills.append("microphone-onset") }
            if !report.extras.isEmpty { skills.append("microphone-extra-attacks") }
        }
        var attempt = PracticeAttempt(
            sessionID: take.id, activityID: "microphone-phrase:\(take.plan.key)", title: take.plan.material.title,
            skills: skills,
            input: .microphone,
            outcome: report.conclusive ? (report.clean ? .correct : .incorrect) : .skipped,
            assisted: take.assisted,
            played: take.attacks.compactMap(\.midi), target: take.plan.timed.targets.map(\.pitch),
            tempo: Double(take.plan.tempo), date: take.date)
        attempt.id = take.id
        attempt.pieceID = take.plan.material.pieceID
        attempt.scoreFingerprint = take.plan.material.fingerprint
        attempt.passageScope = take.plan.timed.source?.scope
        return attempt
    }
}
