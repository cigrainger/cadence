// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import Foundation
import MusicCore

/// Playback and cursor share the scheduled audible origin. A cancelled render
/// cannot start later, and leaving the workspace stops the separate take output.
@MainActor final class PianoTakePlayer: ObservableObject {
    @Published private(set) var take: PianoTake?
    @Published private(set) var preparing = false
    @Published private(set) var playing = false
    @Published private(set) var elapsed = 0.0
    @Published private(set) var completedID: UUID?
    @Published var error: String?
    private let output = TimedAudio()
    private let clock: () -> Double
    private var timer: Timer?
    private var epoch = UUID()
    private var origin = 0.0
    var busy: Bool { preparing || playing }
    var playhead: StudyPlayhead? {
        guard playing, let take, elapsed >= 0, let beat = take.sourceBeat(at: elapsed + take.recording.start) else {
            return nil
        }
        return .init(sourceBeat: beat, isCountIn: false, countInRemaining: 0, cycle: 0)
    }
    init(clock: @escaping () -> Double = PracticeClock.now) { self.clock = clock }
    func play(_ take: PianoTake) {
        guard take.valid else {
            error = "This take could not be played."
            return
        }
        stop()
        self.take = take
        preparing = true
        error = nil
        let token = epoch
        output.start(render: { try SampledAudio.renderTake(take.recording) }) { [weak self] response in
            guard let self, token == self.epoch else { return }
            switch response {
            case .failure(let error):
                self.stop()
                self.error = error.localizedDescription
            case .success(let time):
                self.begin(take, at: time)
                let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
                self.timer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }
    func begin(_ take: PianoTake, at time: Double) {
        guard take.valid, time.isFinite else { return }
        self.take = take
        origin = time
        preparing = false
        playing = true
        completedID = nil
        elapsed = clock() - time
    }
    func tick() {
        guard playing, let take else { return }
        elapsed = clock() - origin
        if elapsed >= take.recording.duration + 0.35 {
            let id = take.id
            stop()
            completedID = id
        }
    }
    func stop() {
        epoch = UUID()
        timer?.invalidate()
        timer = nil
        output.stop()
        preparing = false
        playing = false
        completedID = nil
        elapsed = 0
    }
}
