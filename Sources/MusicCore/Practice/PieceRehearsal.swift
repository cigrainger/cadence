// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Source resolution is shared by the whole-score workspace, its exercises and
/// saved review. A new XML parse must not invent a new practice identity.
public enum RehearsalSource {
    public static func whole(_ piece: LibraryPiece, partID: String? = nil) throws -> MusicStudy {
        var study: MusicStudy
        switch piece.source {
        case .score(let score):
            _ = try score.validated()
            study = MusicStudy(
                document: try StudyImport.read(Data(EditorXML.encode(score).utf8)), filename: score.title + ".musicxml")
            study.id = score.id
        case .study(let original): study = original
        }
        _ = try study.document.validated()
        if let partID {
            guard study.document.parts.contains(where: { $0.id == partID }) else {
                throw MusicError.invalid("This part is no longer in the piece.")
            }
            study.selectPart(partID)
        }
        study.from = 0
        study.through = study.part.measures.count - 1
        study.staff = nil
        study.speed = 1
        study.loop = false
        study.countIn = true
        study.metronome = false
        return study
    }
    public static func plan(_ piece: LibraryPiece, scope: PassageScope, tempo: Int) throws -> TimedPracticePlan {
        if scope.staff == nil { return try PianoHands.plan(piece, scope: scope, tempo: tempo) }
        var study = try whole(piece, partID: scope.partID)
        guard scope.isValid(in: study.document), scope.through - scope.from < 8,
            let staff = scope.staff, study.part.staves.contains(staff), !study.part.tabStaves.contains(staff)
        else {
            throw MusicError.invalid("Choose one notation staff and 1–8 bars inside the piece.")
        }
        _ = try ReviewedSource.pages(piece: piece, from: scope.from, through: scope.through)
        study.staff = staff
        study.from = scope.from
        study.through = scope.through
        let written = study.part.sourceNotes(staff: staff).filter { $0.midi >= 0 }
        for note in written where note.start < study.end && note.start + note.duration > study.start {
            func connects(_ other: StudyNote, before: Bool) -> Bool {
                other.voice == note.voice && other.midi == note.midi
                    && abs(
                        before ? other.start + other.duration - note.start : note.start + note.duration - other.start)
                        < 0.00001
                    && (before ? other.tieStart : other.tieStop)
            }
            guard !note.tieStop || written.contains(where: { connects($0, before: true) }),
                !note.tieStart || written.contains(where: { connects($0, before: false) })
            else {
                throw MusicError.invalid("Review an incomplete tie in this staff before practising it.")
            }
        }
        // Do not turn a tied continuation at a passage edge into a new attack.
        let notes = study.part.soundingNotes(staff: staff).filter {
            $0.start < study.end - 0.00001 && $0.start + $0.duration > study.start + 0.00001
        }
        guard notes.allSatisfy({ $0.start >= study.start - 0.00001 && $0.start + $0.duration <= study.end + 0.00001 })
        else {
            throw MusicError.invalid("Include the complete ties at both ends of this phrase.")
        }
        let guide = try GuidedPassage(study: study, pieceID: piece.id, fingerprint: piece.fingerprint)
        return try TimedPracticePlan(study: study, guided: guide, tempo: tempo)
    }
    /// Expand around the observed bar until all ties are included. Fall back to
    /// the already valid opening phrase, never silently clip sustained notes.
    public static func focus(_ piece: LibraryPiece, opening: TimedPracticeResult) throws -> TimedPracticePlan {
        guard let source = opening.plan.source else { throw MusicError.invalid("This opening pass has no source.") }
        let report = opening.report
        let bars = Dictionary(grouping: report.notes, by: { $0.target.bar })
        let measures = try whole(piece, partID: source.scope.partID).part.measures.filter {
            (source.scope.from...source.scope.through).contains($0.index)
        }
        let extraBars = report.extras.compactMap { attack in
            (measures.last { $0.start <= source.startBeat + attack.seconds / opening.plan.secondsPerBeat }
                ?? measures.first)?.index
        }
        let ranked = Set(bars.keys).union(extraBars).sorted { a, b in
            func difficulty(_ bar: Int) -> Double {
                let notes = bars[bar] ?? []
                return Double(notes.filter { $0.verdict != .onTime }.count + extraBars.filter { $0 == bar }.count)
                    / Double(max(1, notes.count))
            }
            return difficulty(a) == difficulty(b) ? a < b : difficulty(a) > difficulty(b)
        }
        guard let bar = ranked.first else { return opening.plan }
        var candidates: [PassageScope] = []
        for length in 1...min(8, source.scope.through - source.scope.from + 1) {
            for from in max(source.scope.from, bar - length + 1)...min(bar, source.scope.through - length + 1) {
                candidates.append(
                    .init(
                        partID: source.scope.partID, staff: source.scope.staff, from: from, through: from + length - 1))
            }
        }
        for scope in candidates {
            if let plan = try? plan(piece, scope: scope, tempo: opening.plan.tempo) { return plan }
        }
        return try plan(piece, scope: source.scope, tempo: opening.plan.tempo)
    }
    public static func context(_ piece: LibraryPiece, opening: TimedPracticePlan) throws -> TimedPracticePlan {
        guard let source = opening.source else { throw MusicError.invalid("This phrase has no source.") }
        let whole = try whole(piece, partID: source.scope.partID)
        // Return to at least the whole opening phrase. For a one-bar opening,
        // include a neighbour on either side when the score permits it.
        if source.scope.from == source.scope.through {
            var scope = source.scope
            scope.from = max(0, scope.from - 1)
            scope.through = min(whole.through, scope.through + 1)
            if let expanded = try? plan(piece, scope: scope, tempo: opening.tempo) { return expanded }
        }
        return try plan(piece, scope: source.scope, tempo: opening.tempo)
    }
    public static func current(_ plan: TimedPracticePlan, in piece: LibraryPiece) -> Bool {
        guard let source = plan.source, source.pieceID == piece.id, source.fingerprint == piece.fingerprint,
            let fresh = try? self.plan(piece, scope: source.scope, tempo: plan.tempo)
        else { return false }
        var a = fresh
        var b = plan
        a.title = ""
        b.title = ""
        return a == b
    }
}

/// Review is a property of the original pages, not the presence of imported
/// notes. Missing pages between selected source pages also block assessment.
public enum ReviewedSource {
    public static func pages(piece: LibraryPiece, from: Int, through: Int) throws -> [Int] {
        guard from >= 0, through >= from else { throw MusicError.invalid("Choose a valid score passage.") }
        guard case .score(let score) = piece.source, let pdf = score.pdfSource else { return [] }
        if let pages = pdf.pages {
            let selected = pages.indices.filter {
                pdf.range(for: pages[$0].page)?.overlaps(from..<(through + 1)) == true
            }
            guard let first = selected.first, let last = selected.last,
                pages[first...last].allSatisfy({
                    $0.barCount > 0 && $0.reviewed && $0.replacement == nil && $0.status != .reading
                })
            else {
                throw MusicError.invalid(
                    "Review the selected PDF pages in Compose first. Missing pages or pending replacements inside this passage need attention."
                )
            }
            return selected.map { pages[$0].page }
        }
        guard pdf.reviewed else {
            throw MusicError.invalid("Review this PDF page against the original in Compose first.")
        }
        return [pdf.page]
    }
}

public enum RehearsalStage: String, Codable, CaseIterable, Sendable {
    case opening, focus, context, complete, review
    public var title: String {
        switch self {
        case .opening: "An opening pass"
        case .focus: "Give it a little attention"
        case .context: "Back into the phrase"
        case .complete: "Let it settle"
        case .review: "See what stayed"
        }
    }
}
public enum RehearsalExercise: String, Codable, CaseIterable, Sendable {
    case notes = "Play the notes"
    case rhythm = "Tap the rhythm"
    case connected = "Connect the melody"
    case rightHand = "Right hand"
    case leftHand = "Left hand"
    public var isHand: Bool { self == .rightHand || self == .leftHand }
}
public struct RehearsalFocusResult: Codable, Equatable, Sendable {
    public var exercise: RehearsalExercise
    public var pass: TimedPracticeResult
    public var flowSource: TimedPracticePlan?
    public init(exercise: RehearsalExercise, pass: TimedPracticeResult, flowSource: TimedPracticePlan? = nil) {
        self.exercise = exercise
        self.pass = pass
        self.flowSource = flowSource
    }
}
public struct RehearsalReviewResult: Codable, Equatable, Sendable {
    public var pass: TimedPracticeResult
    public var independent: Bool
}

/// A small, explicit learning cycle. Only a delayed first return can lengthen
/// the review interval. Practice success never masquerades as retained learning.
public struct PieceRehearsal: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var phraseIntention: PhraseIntention?
    public private(set) var flow: FlowSettings?
    public var flowReflection: FlowReflection?
    public private(set) var createdAt: Date
    public private(set) var opening: TimedPracticePlan
    public private(set) var stage = RehearsalStage.opening
    public private(set) var openingResult: TimedPracticeResult?
    public private(set) var focus: TimedPracticePlan?
    public private(set) var context: TimedPracticePlan?
    public private(set) var focusResults: [RehearsalFocusResult] = []
    public private(set) var contextResult: TimedPracticeResult?
    public private(set) var reviews: [RehearsalReviewResult] = []
    public private(set) var review = ReviewSchedule()
    public private(set) var reviewStarts = 0
    public private(set) var reviewEpisode: UUID?
    public private(set) var lastExposure: Date
    public var pieceID: String { opening.source?.pieceID ?? "" }
    public var fingerprint: String { opening.source?.fingerprint ?? "" }
    public var title: String { opening.title }
    public var key: String {
        guard let source = opening.source else { return "" }
        return "rehearsal:"
            + ScoreRevision.digest(
                "\(pieceID)|\(fingerprint)|\(source.scope.partID)|\(source.scope.staff ?? 0)|\(source.scope.from)|\(source.scope.through)"
            )
    }
    public var activePlan: TimedPracticePlan {
        switch stage {
        case .opening: opening
        case .focus: flow?.plan ?? focus ?? opening
        default: context ?? opening
        }
    }
    public var nextReview: Date? { review.due.map { max($0, lastExposure.addingTimeInterval(20 * 3600)) } }
    public var reviewSchedule: ReviewSchedule {
        var copy = review
        copy.due = nextReview
        return copy
    }
    public var attempts: [TimedPracticeResult] {
        [openingResult].compactMap { $0 } + focusResults.map(\.pass) + [contextResult].compactMap { $0 }
            + reviews.map(\.pass)
    }
    public init(opening: TimedPracticePlan, now: Date = Date()) throws {
        guard opening.valid, opening.source != nil, now.timeIntervalSince1970.isFinite else {
            throw MusicError.invalid("Choose a supported opening phrase.")
        }
        self.opening = opening
        createdAt = now
        lastExposure = now
    }
    public static func exercisePlan(_ source: TimedPracticePlan, exercise: RehearsalExercise, tempo: Int) throws
        -> TimedPracticePlan
    {
        var plan = exercise.isHand ? try PianoHands.solo(source, exercise: exercise) : source
        plan.tempo = tempo
        if exercise == .rhythm {
            guard let linked = source.source else { throw MusicError.invalid("This rhythm has no source.") }
            plan.handStaves = nil
            plan.rhythmID = "rehearsal:" + ScoreRevision.digest(source.identity(.init()))
            plan.source = nil
            plan.targets = source.onsetBeats.compactMap { beat in
                source.targets.first { $0.beat == beat }.map {
                    TimedTarget(beat: beat, bar: $0.bar - linked.scope.from)
                }
            }
        }
        guard plan.valid else {
            throw MusicError.invalid("Choose 40–160 bpm and a short enough phrase for this exercise.")
        }
        return plan
    }
    private func accepts(_ result: TimedPracticeResult, plan: TimedPracticePlan, click: Bool, now: Date) -> Bool {
        result.valid && result.plan == plan && result.conditions.input == .midi && result.conditions.click == click
            && result.conditions.partnerStaff == nil && result.conditions.flowPulse == nil && result.date >= createdAt
            && result.date <= now.addingTimeInterval(5) && !attempts.contains { $0.id == result.id }
    }
    public mutating func recordOpening(
        _ result: TimedPracticeResult, focus: TimedPracticePlan, context: TimedPracticePlan, now: Date = Date()
    ) throws {
        guard stage == .opening, accepts(result, plan: opening, click: false, now: now),
            Self.related(focus, to: opening), Self.related(context, to: opening),
            let f = focus.source?.scope, let o = opening.source?.scope, let c = context.source?.scope,
            f.from >= o.from, f.through <= o.through, c.from <= o.from, c.through >= o.through
        else { throw MusicError.invalid("This opening pass does not match the current phrase.") }
        openingResult = result
        self.focus = focus
        self.context = context
        stage = .focus
        lastExposure = result.date
    }
    public mutating func configureFlow(_ settings: FlowSettings?) throws {
        guard stage == .focus, settings.map({ $0.valid(in: opening) }) ?? true else {
            throw MusicError.invalid(
                "Choose a supported join inside the opening phrase and a tempo at or below the opening pace.")
        }
        flow = settings
    }
    public mutating func recordFocus(
        _ result: TimedPracticeResult, exercise: RehearsalExercise, flowSource: TimedPracticePlan? = nil,
        now: Date = Date()
    ) throws {
        let item = RehearsalFocusResult(exercise: exercise, pass: result, flowSource: flowSource)
        guard stage == .focus, acceptsFocus(item),
            flowSource == nil
                ? flow == nil
                : flow?.plan == flowSource && flow?.tempo == result.plan.tempo
                    && flow?.pulse == result.conditions.flowPulse
                    && result.conditions.partnerStaff
                        == (flow?.partner == true ? PianoHands.partner(in: flowSource!, exercise: exercise) : nil),
            result.date >= lastExposure, result.date <= now.addingTimeInterval(5),
            !attempts.contains(where: { $0.id == result.id })
        else { throw MusicError.invalid("This exercise does not match the focused bars and support settings.") }
        focusResults.append(item)
        focusResults = Array(focusResults.suffix(12))
        lastExposure = result.date
    }
    private func acceptsFocus(_ item: RehearsalFocusResult) -> Bool {
        let result = item.pass
        let source = item.flowSource ?? focus
        guard let source, result.valid, result.plan.tempo <= opening.tempo,
            Self.acceptsPartner(result, exercise: item.exercise, source: source),
            item.exercise == .rhythm || result.conditions.input == .midi,
            result.plan == (try? Self.exercisePlan(source, exercise: item.exercise, tempo: result.plan.tempo))
        else { return false }
        if item.flowSource != nil {
            return result.conditions.flowPulse != nil && FlowPractice.contains(source, in: opening)
        }
        return result.conditions.flowPulse == nil && result.conditions.click
    }
    private static func acceptsPartner(
        _ result: TimedPracticeResult, exercise: RehearsalExercise, source: TimedPracticePlan
    ) -> Bool {
        guard let partner = result.conditions.partnerStaff else { return true }
        return exercise.isHand && source.handStaves?.contains(partner) == true
            && partner != result.plan.source?.scope.staff
    }
    public mutating func returnToPhrase() throws {
        guard stage == .focus, !focusResults.isEmpty,
            opening.handStaves == nil
                || focusResults.contains(where: { $0.exercise == .notes && $0.pass.plan.handStaves != nil })
        else {
            throw MusicError.invalid(
                opening.handStaves == nil
                    ? "Try a focused exercise before returning to the phrase."
                    : "Try a focused pass with both hands before returning to the phrase.")
        }
        stage = .context
    }
    public mutating func recordContext(_ result: TimedPracticeResult, now: Date = Date()) throws {
        guard stage == .context, let context, accepts(result, plan: context, click: false, now: now),
            result.date >= lastExposure
        else { throw MusicError.invalid("This return does not match the surrounding phrase.") }
        contextResult = result
        stage = .complete
        lastExposure = result.date
        review.record(.supported, episode: id, input: .midi, now: result.date)
        review.due = result.date.addingTimeInterval(86400)
    }
    public mutating func beginReview(now: Date = Date()) throws {
        guard stage == .complete, let due = nextReview, now >= due else {
            throw MusicError.invalid(
                "Let this phrase settle before the independent return. You can still listen and practise.")
        }
        stage = .review
        reviewStarts = 0
        reviewEpisode = UUID()
    }
    /// Persist before the count-in. A cancelled or interrupted return remains
    /// an exposure, even across relaunch, and a second start is supported.
    public mutating func startReviewPass(now: Date = Date()) throws {
        guard stage == .review, reviewStarts < 1000, now.timeIntervalSince1970.isFinite else {
            throw MusicError.invalid("Open the saved independent return first.")
        }
        reviewStarts += 1
    }
    public mutating func recordReview(_ result: TimedPracticeResult, now: Date = Date()) throws {
        guard stage == .review, reviewStarts > 0, let context, let episode = reviewEpisode,
            accepts(result, plan: context, click: false, now: now), result.date >= lastExposure
        else { throw MusicError.invalid("This review does not match the saved phrase.") }
        let independent =
            reviewStarts == 1 && result.date >= (nextReview ?? .distantFuture)
            && !result.attacks.contains(where: \.arrivalTimestamp)
        let grade: ReviewGrade = independent ? (result.report.clean ? .good : .again) : .supported
        reviews.append(.init(pass: result, independent: independent))
        reviews = Array(reviews.suffix(12))
        review.record(grade, episode: episode, input: .midi, now: result.date)
        review.due = max(review.due ?? result.date, result.date.addingTimeInterval(86400))
        lastExposure = result.date
        stage = .complete
    }
    public mutating func expose(now: Date = Date()) throws {
        guard now.timeIntervalSince1970.isFinite, now >= lastExposure else {
            throw MusicError.invalid("This practice time is invalid.")
        }
        lastExposure = now
        if stage == .review { reviewStarts = max(2, reviewStarts) }
    }
    public mutating func practiseAgain(now: Date = Date()) throws {
        guard stage == .complete || stage == .review else { throw MusicError.invalid("Finish this step first.") }
        try expose(now: now)
        stage = .focus
        focusResults = []
        contextResult = nil
        flowReflection = nil
    }
    private static func related(_ a: TimedPracticePlan, to b: TimedPracticePlan) -> Bool {
        guard a.valid, let x = a.source, let y = b.source else { return false }
        return x.pieceID == y.pieceID && x.fingerprint == y.fingerprint && x.studyID == y.studyID
            && x.scope.partID == y.scope.partID && x.scope.staff == y.scope.staff && a.handStaves == b.handStaves
            && a.tempo == b.tempo
    }
    public var valid: Bool {
        guard opening.valid, opening.source != nil, createdAt.timeIntervalSince1970.isFinite,
            lastExposure.timeIntervalSince1970.isFinite, lastExposure >= createdAt, review.valid,
            (0...1000).contains(reviewStarts), focusResults.count <= 12, reviews.count <= 12,
            attempts.allSatisfy({ $0.valid && $0.date >= createdAt && $0.date <= lastExposure }),
            Set(attempts.map(\.id)).count == attempts.count
        else { return false }
        if flowReflection != nil && contextResult == nil { return false }
        if stage == .opening {
            return flow == nil && openingResult == nil && focus == nil && context == nil && attempts.isEmpty
                && review.encounters == 0
        }
        guard let result = openingResult, result.plan == opening, result.conditions.input == .midi,
            !result.conditions.click, result.conditions.partnerStaff == nil, result.conditions.flowPulse == nil,
            let focus, let context, Self.related(focus, to: opening), Self.related(context, to: opening),
            let f = focus.source?.scope, let o = opening.source?.scope, let c = context.source?.scope,
            f.from >= o.from, f.through <= o.through, c.from <= o.from, c.through >= o.through,
            focusResults.allSatisfy(acceptsFocus), flow.map({ $0.valid(in: opening) }) ?? true,
            contextResult.map({
                $0.plan == context && $0.conditions.input == .midi && !$0.conditions.click
                    && $0.conditions.partnerStaff == nil && $0.conditions.flowPulse == nil
            }) ?? true,
            reviews.allSatisfy({
                $0.pass.plan == context && $0.pass.conditions.input == .midi && !$0.pass.conditions.click
                    && $0.pass.conditions.partnerStaff == nil && $0.pass.conditions.flowPulse == nil
                    && (!$0.independent || !$0.pass.attacks.contains(where: \.arrivalTimestamp))
            })
        else { return false }
        if opening.handStaves != nil && stage != .focus
            && !focusResults.contains(where: { $0.exercise == .notes && $0.pass.plan.handStaves != nil })
        {
            return false
        }
        switch stage {
        case .opening: return false
        case .focus: return contextResult == nil
        case .context: return !focusResults.isEmpty && contextResult == nil
        case .complete: return !focusResults.isEmpty && contextResult != nil && review.due != nil
        case .review: return !focusResults.isEmpty && contextResult != nil && reviewEpisode != nil && review.due != nil
        }
    }
}

public struct PieceRehearsalBook: Codable, Equatable, Sendable {
    public var records: [String: PieceRehearsal] = [:]
    public init() {}
    public func validated() throws -> Self {
        guard records.count <= 64, records.allSatisfy({ $0.key == $0.value.key && $0.value.valid }),
            Set(records.values.map(\.id)).count == records.count
        else {
            throw MusicError.invalid(
                "The piece practice sessions are damaged or need a newer Cadence. The saved file has been preserved.")
        }
        return self
    }
}
