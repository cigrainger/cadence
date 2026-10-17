// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import Foundation
import MusicCore

enum ReharmAudio {
    static func render(
        source: ReharmSource, version: ReharmVersion, tempo: Int, layer: ReharmLayer = .band, melody: [ScoreNote] = [],
        countIn: Bool = false, take: PianoRecording? = nil
    ) throws -> [Float] {
        let score = try source.accompaniment(version, layer: layer, tempo: tempo)
        let piano = try SampledAudio.render(
            Score(tempo: Double(tempo), notes: score.notes + melody), exactBeats: source.length)
        let lead = countIn ? Int((240 / Double(tempo) * 44100).rounded()) : 0
        var result =
            countIn
            ? try TimedClickTrack.render(tempo: tempo, beatsPerBar: 4, length: source.length, click: false)
            : [Float](repeating: 0, count: piano.count + 15435)
        for i in piano.indices where i + lead < result.count { result[i + lead] += piano[i] * 0.55 }
        if let take {
            let solo = try SampledAudio.renderTake(take)
            for i in solo.indices where i < result.count { result[i] += solo[i] * 0.75 }
        }
        return result.map { min(0.98, max(-0.98, $0)) }
    }
}

/// Free MIDI capture shares the existing timestamp clock, pedal-aware recording
/// and sampled playback. It never manufactures a scored-performance result.
@MainActor final class ReharmTransport: ObservableObject {
    @Published private(set) var preparing = false
    @Published private(set) var playing = false
    @Published private(set) var recording = false
    @Published private(set) var elapsed = 0.0
    @Published private(set) var pending: ReharmTake?
    @Published private(set) var completedTakeID: UUID?
    @Published var error: String?
    private(set) var expected: ReharmSession?
    private(set) var source: ReharmSource?
    private var version = ReharmVersion.original
    private var tempo = 84
    private var offsetMS = 0
    private var origin = 0.0
    private var end = 0.0
    private var events: [PianoEvent] = []
    private var replayID: UUID?
    private var onFinished: (() -> Void)?
    private var epoch = UUID()
    private var timer: Timer?
    private let output = TimedAudio()
    private let clock: () -> Double
    var busy: Bool { preparing || playing || recording }
    var beat: Double? { busy && !preparing ? max(0, min(source?.length ?? 0, elapsed * Double(tempo) / 60)) : nil }
    var countInRemaining: Int { max(0, Int(ceil(-elapsed * Double(tempo) / 60))) }
    init(clock: @escaping () -> Double = PracticeClock.now) { self.clock = clock }
    func stop(_ reason: String? = nil) {
        epoch = UUID()
        output.stop()
        timer?.invalidate()
        timer = nil
        preparing = false
        playing = false
        recording = false
        completedTakeID = nil
        onFinished = nil
        if let reason { error = reason }
    }
    func discard() {
        stop()
        pending = nil
        expected = nil
        events = []
        error = nil
    }
    func acceptSaved() {
        pending = nil
        expected = nil
        events = []
        error = nil
    }
    @discardableResult func prepareRecording(
        _ session: ReharmSession, version: ReharmVersion, tempo: Int, offsetMS: Int, held: Set<Int>, pedal: Bool = false
    ) -> Bool {
        guard pending == nil, !busy else {
            error = "Save the pending take or stop playback first."
            return false
        }
        guard session.valid, session.skill == .creating, !session.completed, session.instrument == .piano,
            (60...160).contains(tempo), (-300...300).contains(offsetMS), held.isEmpty, !pedal
        else {
            error = "Release the keys and sustain pedal, then record from the creative step at 60–160 bpm."
            return false
        }
        stop()
        expected = session
        source = session.source
        self.version = version
        self.tempo = tempo
        self.offsetMS = offsetMS
        end = session.source.length * 60 / Double(tempo)
        events = []
        error = nil
        preparing = true
        replayID = nil
        return true
    }
    func startRecording(_ state: AppState, version: ReharmVersion, tempo: Int, offsetMS: Int) {
        guard state.reharmInput.pending == nil, let session = state.reharmPractice.active,
            state.reharmCurrent(session.source)
        else { return }
        state.reharmInput.pause()
        state.audio.stop()
        guard
            prepareRecording(
                session, version: version, tempo: tempo, offsetMS: offsetMS, held: state.midi.keyboard.downNotes,
                pedal: !state.midi.keyboard.pedals.isEmpty)
        else { return }
        launch(
            render: { try ReharmAudio.render(source: session.source, version: version, tempo: tempo, countIn: true) },
            countIn: 240 / Double(tempo), record: true)
    }
    func audition(
        _ source: ReharmSource, version: ReharmVersion, tempo: Int, layer: ReharmLayer, melody: [ScoreNote] = [],
        onFinished: (() -> Void)? = nil
    ) {
        guard pending == nil else {
            error = "Save or discard your recording first."
            return
        }
        stop()
        self.source = source
        self.tempo = tempo
        end = source.length * 60 / Double(tempo)
        preparing = true
        replayID = nil
        expected = nil
        self.onFinished = onFinished
        launch(
            render: {
                try ReharmAudio.render(source: source, version: version, tempo: tempo, layer: layer, melody: melody)
            }, countIn: 0, record: false)
    }
    func replay(_ take: ReharmTake, over version: ReharmVersion) {
        guard take.valid, pending == nil else { return }
        stop()
        source = take.source
        tempo = take.tempo
        end = take.recording.end
        preparing = true
        replayID = take.id
        expected = nil
        launch(
            render: {
                try ReharmAudio.render(source: take.source, version: version, tempo: take.tempo, take: take.recording)
            }, countIn: 0, record: false)
    }
    private func launch(render: @escaping @Sendable () throws -> [Float], countIn: Double, record: Bool) {
        let token = epoch
        output.start(render: render) { [weak self] result in
            guard let self, token == self.epoch else { return }
            switch result {
            case .failure(let error): self.stop(error.localizedDescription)
            case .success(let time):
                self.begin(at: time + countIn, record: record)
                let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
                self.timer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
    }
    func begin(at time: Double, record: Bool) {
        guard source?.valid == true, time.isFinite else { return }
        origin = time
        preparing = false
        recording = record
        playing = !record
        elapsed = clock() - time
    }
    func receive(_ update: MIDIUpdate, state: AppState) {
        guard busy, expected != nil else { return }
        guard let expected, expected == state.reharmPractice.active, state.reharmCurrent(expected.source),
            state.destination == .practice, state.practicePage == .reharm, !state.audio.isPlaying,
            !state.audio.isPreparing
        else {
            stop("Recording stopped because the activity changed.")
            return
        }
        if update.message == .reset {
            stop("MIDI was reset. Start a fresh take when ready.")
            return
        }
        if case .control(_, let n, _) = update.message, n == 120 || n == 123 {
            stop("The keyboard stopped its notes. Start a fresh take.")
            return
        }
        if preparing {
            switch update.message {
            case .noteOn(_, _, let v) where v > 0, .control(_, 64, let v) where v >= 64:
                stop("Wait for the count-in before playing, then start a fresh take.")
            default: break
            }
            return
        }
        guard recording else { return }
        let seconds = update.timestamp - origin - Double(offsetMS) / 1000
        if seconds < 0 {
            switch update.message {
            case .noteOn(_, _, let v) where v > 0, .control(_, 64, let v) where v >= 64:
                stop("That entrance was before the count-in finished. Release the keys and try again.")
            default: break
            }
            return
        }
        guard seconds <= end,
            let event = PianoEvent(update.message, seconds: seconds, arrivalTimestamp: update.arrivalTimestamp)
        else { return }
        guard events.count < 8192 else {
            stop("Too many MIDI events arrived. Check the input and try again.")
            return
        }
        events.append(event)
    }
    func tick() {
        guard recording || playing else { return }
        elapsed = clock() - origin
        guard elapsed >= end + 0.5 else { return }
        let wasRecording = recording
        let id = replayID
        let finish = onFinished
        stop()
        if wasRecording, let expected, let source {
            let take = ReharmTake(
                sessionID: expected.id, source: source, version: version, tempo: tempo, offsetMS: offsetMS,
                recording: .init(events: events, end: end))
            if take.valid {
                pending = take
            } else {
                error = "No MIDI notes were recorded. Choose your keyboard and try another take."
            }
        } else {
            completedTakeID = id
            finish?()
        }
    }
}
