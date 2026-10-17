// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

@MainActor final class ChangesSession: ObservableObject {
    @Published private(set) var practice: ChangesPractice?
    @Published private(set) var pending: PracticeAttempt?
    @Published private(set) var feedback: ChordJudgement?
    @Published private(set) var feedbackLabel = ""
    @Published private(set) var listening = false
    @Published var error: String?
    private var capture = MIDIStepCapture()
    var waitingForRelease: Bool { capture.waitingForRelease }
    func start(plan: ChangesPlan, mode: ChangesMode, held: Set<Int>) throws {
        guard pending == nil else {
            throw MusicError.invalid("Save or discard the pending answer before starting a new pass.")
        }
        practice = try ChangesPractice(plan: plan, mode: mode)
        feedback = nil
        feedbackLabel = ""
        error = nil
        pause(held: held)
    }
    func pause(held: Set<Int>) {
        listening = false
        capture.reset(held: held)
    }
    func listen(held: Set<Int>) {
        guard practice?.finished == false, pending == nil else { return }
        capture.reset(held: held)
        listening = true
    }
    func reveal() {
        guard pending == nil else { return }
        practice?.reveal()
    }
    func discardPending() {
        pause(held: [])
        pending = nil
        error = nil
        practice = nil
        feedback = nil
    }
    func receive(_ update: MIDIUpdate, state: AppState, active: Bool) {
        guard active, !state.audio.isPlaying, !state.audio.isPreparing else {
            pause(held: update.keyboard.downNotes)
            return
        }
        guard listening, pending == nil, practice?.finished == false else { return }
        if let notes = capture.receive(update.message, state: update.keyboard) {
            do {
                guard let practice else { return }
                try state.validateChangesPlan(practice.plan)
                pending = try practice.answer(notes)
                feedback = practice.targets[practice.cursor].judge(notes)
                feedbackLabel = practice.plan.steps[practice.stepIndex].chord.symbol.label
                savePending(state: state)
            } catch {
                self.error = error.localizedDescription
                pause(held: update.keyboard.downNotes)
            }
        }
    }
    func savePending(state: AppState) {
        guard let pending, var next = practice else { return }
        do {
            try state.validateChangesPlan(next.plan)
            try next.accept(pending)
            guard state.recordAttempt(pending) else {
                throw MusicError.invalid(
                    "This answer is still here. Restore access to your data, then choose Save answer again.")
            }
            practice = next
            self.pending = nil
            error = nil
            if next.finished { pause(held: state.midi.keyboard.downNotes) }
        } catch {
            self.error = error.localizedDescription
            pause(held: state.midi.keyboard.downNotes)
        }
    }
}

extension AppState {
    func changesSource(piece: LibraryPiece, from: Int, through: Int, partID: String?) throws -> ChangesSource {
        let resolved: LibraryPiece
        if case .study(let study) = piece.source { resolved = try practicePiece(study) } else { resolved = piece }
        return try ChangesSource(piece: resolved, from: from, through: through, partID: partID)
    }
    func openChanges(_ plan: ChangesPlan = .example) {
        if changesSession.pending != nil, changesPlan.id != plan.id {
            message = "Save or discard the pending Follow the changes answer first."
            return
        }
        if timedChangesSession.hasUnsavedResult, changesPlan.id != plan.id {
            message = "Save or discard the completed timed pass first."
            return
        }
        timedChangesSession.cancel()
        if changesPlan.id != plan.id {
            timedChangesSession.discard()
            showTimedChanges = false
            changesReview = nil
        }
        changesSession.pause(held: midi.keyboard.downNotes)
        audio.stop()
        microphone.stop()
        changesPlan = plan
        showChanges = true
        destination = .chords
    }
    func validateChangesPlan(_ plan: ChangesPlan) throws {
        guard let id = plan.pieceID else {
            guard plan == .example else { throw MusicError.invalid("This example has changed.") }
            return
        }
        guard let piece = libraryPieces.first(where: { $0.id == id }) else {
            throw MusicError.invalid("The source piece is no longer in the library.")
        }
        let current = try ChangesSource(piece: piece, from: plan.from, through: plan.through, partID: plan.partID).plan(
            staff: plan.staff)
        guard current.id == plan.id, current.steps == plan.steps else {
            throw MusicError.invalid("The score changed. Open Follow the changes again from the current piece.")
        }
    }
    func changesEvidence(_ piece: LibraryPiece) -> String {
        let attempts = journal.attempts.filter {
            $0.activityID.hasPrefix("changes:") && $0.pieceID == piece.id && $0.scoreFingerprint == piece.fingerprint
        }.suffix(12)
        guard !attempts.isEmpty else { return "" }
        return
            "Follow the changes: untimed MIDI pitch collections; no timing, pedal or technique grade. Recent attempts:\n"
            + attempts.map {
                "\($0.title): \($0.outcome.rawValue), \($0.assisted ? "with tones/example shown" : "without hints"), try \($0.ordinal ?? 1)."
            }.joined(separator: "\n")
    }
}

struct FollowChangesButton: View {
    @EnvironmentObject var state: AppState
    var piece: LibraryPiece
    var from: Int
    var through: Int
    var partID: String? = nil
    private var source: ChangesSource? {
        try? state.changesSource(piece: piece, from: from, through: through, partID: partID)
    }
    var body: some View {
        Group {
            if let source, source.staffs.count > 1 {
                Menu("Follow changes", systemImage: "arrow.triangle.branch") {
                    ForEach(source.staffs, id: \.self) { staff in
                        Button("Chord symbols on staff \(staff)") { open(staff) }
                    }
                }
            } else {
                Button("Follow changes", systemImage: "arrow.triangle.branch") { open(source?.staffs.first ?? 1) }
            }
        }.help("Explore and practise the written chord symbols in bars \(from+1)–\(through+1).")
    }
    private func open(_ staff: Int) {
        do {
            state.openChanges(
                try state.changesSource(piece: piece, from: from, through: through, partID: partID).plan(staff: staff))
        } catch { state.message = error.localizedDescription }
    }
}
