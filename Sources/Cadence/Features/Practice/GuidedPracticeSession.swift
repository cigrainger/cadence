// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import Foundation
import MusicCore

/// UI-independent session state; the core follower owns musical matching.
@MainActor final class GuidedPracticeSession: ObservableObject {
    @Published private(set) var follower: GuidedFollower?
    @Published private(set) var listening = false
    @Published private(set) var result: GuidedPassageResult?
    @Published private(set) var saved = false
    @Published var error: String?
    @Published private(set) var feedback = ""
    private var episode = UUID()
    var plan: GuidedPassage? { follower?.plan }
    var hasUnsavedResult: Bool { result != nil && !saved }
    func configure(_ plan: GuidedPassage) {
        guard !hasUnsavedResult else {
            listening = false
            error = "Save this completed pass before starting another selection, or discard its result."
            return
        }
        listening = false
        follower = GuidedFollower(plan: plan)
        result = nil
        saved = false
        episode = UUID()
        error = nil
        feedback = ""
    }
    func start(held: Set<Int>) {
        guard follower != nil, result == nil else { return }
        follower?.resume(held: held)
        listening = true
        error = nil
    }
    func pause() { listening = false }
    func invalidate(_ message: String) {
        listening = false
        if !hasUnsavedResult {
            follower = nil
            result = nil
            saved = false
        }
        error = message
    }
    func hint() { follower?.hint() }
    @discardableResult func receive(_ message: MIDIMessage, keyboard: MIDIKeyboardState) -> GuidedInputResult {
        guard listening, var follower else { return .ignored }
        if message == .reset {
            pause()
            self.follower?.resume(held: keyboard.downNotes)
            return .ignored
        }
        let change = follower.receive(message, keyboard: keyboard)
        self.follower = follower
        switch change {
        case .correction(let note):
            feedback =
                "Heard \(Solfege.noteName(midi: note, pitch: Pitch.spelled(note))). Read the highlighted notes and try again."
        case .advanced: feedback = "Matched. Continue when you’re ready."
        case .complete:
            listening = false
            do {
                result = try follower.result(id: episode)
                feedback = "Passage complete."
            } catch {
                self.error = error.localizedDescription
            }
        case .ignored: break
        }
        return change
    }
    func save(using commit: (GuidedPassageResult) throws -> Void) {
        guard let result, !saved else { return }
        do {
            try commit(result)
            saved = true
            error = nil
        } catch {
            self.error =
                "This pass could not be saved. Keep it open and try saving again. " + error.localizedDescription
        }
    }
    func discardResult() {
        result = nil
        saved = false
    }
}
