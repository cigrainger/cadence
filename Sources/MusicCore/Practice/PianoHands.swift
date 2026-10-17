// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Two written staves share a clock and a physical keyboard. This records score
/// ownership, never an inferred hand position, MIDI channel or finger assignment.
public enum PianoHands {
    public static func plan(_ piece: LibraryPiece, scope: PassageScope, tempo: Int) throws -> TimedPracticePlan {
        let study = try RehearsalSource.whole(piece, partID: scope.partID)
        let staves = study.part.staves.filter { !study.part.tabStaves.contains($0) }.sorted()
        guard scope.staff == nil, scope.isValid(in: study.document), staves.count == 2,
            PianoPhrase.isPiano(piece, part: study.part)
        else {
            throw MusicError.invalid(
                "Hands together needs a piano part with two notation staves. Choose one staff for other parts.")
        }
        let plans = try staves.map { staff -> TimedPracticePlan in
            var selected = scope
            selected.staff = staff
            return try RehearsalSource.plan(piece, scope: selected, tempo: tempo)
        }
        // A key cannot be held by one hand and freshly struck by the other at
        // the same time. Do not pretend MIDI identifies those two actions.
        let notes = staves.map { staff in
            study.part.soundingNotes(staff: staff).filter {
                $0.start < plans[0].source!.startBeat + plans[0].length
                    && $0.start + $0.duration > plans[0].source!.startBeat
            }
        }
        for a in notes[0] {
            guard
                !notes[1].contains(where: { b in
                    a.midi == b.midi && abs(a.start - b.start) > 0.00001
                        && max(a.start, b.start) < min(a.start + a.duration, b.start + b.duration) - 0.00001
                })
            else {
                throw MusicError.invalid(
                    "These staves hold and re-strike the same key across hands. Practise one staff for this passage; MIDI cannot identify the hands independently."
                )
            }
        }
        var combined = plans[0]
        combined.source?.scope.staff = nil
        combined.handStaves = staves
        combined.targets = []
        for (staff, plan) in zip(staves, plans) {
            for var target in plan.targets {
                if let i = combined.targets.firstIndex(where: {
                    $0.pitch == target.pitch && abs($0.beat - target.beat) < 0.00001
                }) {
                    combined.targets[i].staves?.append(staff)
                } else {
                    target.staves = [staff]
                    combined.targets.append(target)
                }
            }
        }
        combined.targets.sort { $0.beat == $1.beat ? $0.pitch < $1.pitch : $0.beat < $1.beat }
        guard combined.valid,
            combined.onsetBeats.allSatisfy({ beat in combined.targets.filter { $0.beat == beat }.count <= 10 })
        else {
            throw MusicError.invalid(
                "Choose 1–8 bars with notes in both staves, up to ten simultaneous keys and at least 120 ms between entrances at this tempo."
            )
        }
        return combined
    }
    public static func solo(_ plan: TimedPracticePlan, exercise: RehearsalExercise) throws -> TimedPracticePlan {
        guard plan.valid, let staves = plan.handStaves, exercise.isHand else {
            throw MusicError.invalid("Choose a hands-together phrase to practise either hand with a partner.")
        }
        let staff = exercise == .rightHand ? staves[0] : staves[1]
        var solo = plan
        solo.source?.scope.staff = staff
        solo.handStaves = nil
        solo.targets = plan.targets.filter { $0.staves?.contains(staff) == true }.map { target in
            var t = target
            t.staves = nil
            return t
        }
        guard solo.valid else { throw MusicError.invalid("Choose a passage with playable notes in this staff.") }
        return solo
    }
    public static func partner(in plan: TimedPracticePlan, exercise: RehearsalExercise) -> Int? {
        guard let hands = plan.handStaves, hands.count == 2, exercise.isHand else { return nil }
        return exercise == .rightHand ? hands[1] : hands[0]
    }
    /// Freeze the reviewed other part before rendering. Ties, durations and
    /// expressive playback are shared with ordinary score playback.
    public static func accompaniment(_ piece: LibraryPiece, solo: TimedPracticePlan, partnerStaff: Int) throws -> Score
    {
        guard let source = solo.source, let staff = source.scope.staff, staff != partnerStaff,
            RehearsalSource.current(solo, in: piece)
        else { throw MusicError.invalid("This partner part no longer matches the reviewed score.") }
        var scope = source.scope
        scope.staff = nil
        let both = try plan(piece, scope: scope, tempo: solo.tempo)
        guard both.handStaves?.contains(partnerStaff) == true, both.handStaves?.contains(staff) == true else {
            throw MusicError.invalid("Choose the other staff of this piano part.")
        }
        let study = try RehearsalSource.whole(piece, partID: scope.partID)
        let notes = study.part.soundingNotes(staff: partnerStaff).filter {
            $0.start >= source.startBeat - 0.00001 && $0.start < source.startBeat + solo.length - 0.00001
        }.map { original -> ScoreNote in
            var note = original
            note.start = max(0, note.start - source.startBeat)
            return note
        }
        return Score(title: "Cadence · staff \(partnerStaff)", tempo: Double(solo.tempo), notes: notes)
    }
}
