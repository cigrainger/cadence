// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

extension EarDailyPractice {
    /// Explicitly retires completed coordinators while preserving the selected
    /// session. The caller retains their evidence and exposure before committing.
    public mutating func archiveCompleted() throws -> [EarDailySession] {
        _ = try validated()
        let retired = sessions.filter { $0.stage == .complete && $0.id != selectedID }
        let retiredIDs = Set(retired.map(\.id))
        var copy = self
        copy.sessions.removeAll { retiredIDs.contains($0.id) }
        _ = try copy.validated()
        self = copy
        return retired
    }
}

extension MicrophonePhrasePractice {
    /// Returns explicitly selected pitch-only records for journal summarisation.
    /// Timing evidence and its existing review schedule are never retired here.
    public mutating func retirePitchOnlyTakes(_ ids: Set<UUID>) throws -> [MicrophonePhraseTake] {
        _ = try validated()
        let retired = sessions.flatMap(\.takes).filter { ids.contains($0.id) }
        guard retired.count == ids.count, Set(retired.map(\.id)) == ids,
            retired.allSatisfy({ $0.calibration == nil && $0.plan.mode != .independent && !$0.report.conclusive })
        else {
            throw MusicError.invalid(
                "Choose only existing pitch-only takes; calibrated and independent evidence is kept.")
        }

        var copy = self
        // Record exposure while all takes still exist, so notePractice can check
        // historical independent returns and overlapping source encounters.
        for session in sessions {
            if let removedMaxDate = session.takes.filter({ ids.contains($0.id) }).map(\.date).max() {
                try copy.notePractice(materialID: session.id, now: removedMaxDate)
            }
        }
        for index in copy.sessions.indices {
            copy.sessions[index].takes.removeAll { ids.contains($0.id) }
        }
        // Validation rebuilds the timed review and checks that the untouched
        // saved schedule still agrees with the retained timed evidence.
        _ = try copy.validated()
        self = copy
        return retired
    }
}
