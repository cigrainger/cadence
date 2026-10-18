// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Combine
import Foundation
import MusicCore

@MainActor protocol AcousticCountInOutput: AnyObject {
    func schedule(render: @escaping @Sendable () throws -> [Float], ready: @escaping (Result<Double, Error>) -> Void)
    func stop()
}

extension TimedAudio: AcousticCountInOutput {
    func schedule(render: @escaping @Sendable () throws -> [Float], ready: @escaping (Result<Double, Error>) -> Void) {
        start(render: render, reference: .scheduledRender, ready: ready)
    }
}

/// Display time is independent from the input evidence. Only original audio host
/// timestamps and the frozen scheduled-render origin enter a saved comparison.
@MainActor final class MicrophonePhraseSession: ObservableObject {
    enum Phase { case idle, preparing, calibrating, countIn, playing, finishing }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var calibration: AcousticCalibration?
    @Published private(set) var plan: MicrophonePhrasePlan?
    @Published private(set) var elapsed = 0.0
    @Published private(set) var pending: MicrophonePhraseTake?
    @Published private(set) var displayedTake: MicrophonePhraseTake?
    @Published var inputChannel = 0 {
        didSet {
            if inputChannel != oldValue { invalidate("Input channel changed. Measure timing for this channel again.") }
        }
    }
    @Published var error: String?
    @Published private(set) var needsExposureSave = false
    private var performanceOrigin: Double?
    private var interruption: ((Date) throws -> Void)?
    private var interruptedSave: (() throws -> Void)?
    var busy: Bool { phase != .idle }
    var hasUnsavedTake: Bool { pending != nil }
    private let output: any AcousticCountInOutput
    private let clock: @MainActor () -> Double
    private let route: @MainActor () -> MicrophoneAudioRoute?
    private let date: @MainActor () -> Date
    private weak var microphone: Microphone?
    private var task: Task<Void, Never>?
    private var token = UUID()
    private var subscriptions = Set<AnyCancellable>()

    init(
        output: (any AcousticCountInOutput)? = nil,
        clock: @escaping @MainActor () -> Double = PracticeClock.now,
        route: @escaping @MainActor () -> MicrophoneAudioRoute? = MicrophoneAudioRoute.current,
        date: @escaping @MainActor () -> Date = Date.init,
        notifications: NotificationCenter = .default,
        workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.output = output ?? TimedAudio()
        self.clock = clock
        self.route = route
        self.date = date
        notifications.publisher(for: .AVAudioEngineConfigurationChange).sink { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.invalidate("Audio configuration changed. Measure loopback timing again.")
            }
        }.store(in: &subscriptions)
        workspaceNotifications.publisher(for: NSWorkspace.willSleepNotification).sink { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in self?.invalidate("The Mac slept. Measure the audio loopback again.") }
        }.store(in: &subscriptions)
    }

    private func currentRoute() -> MicrophoneAudioRoute? {
        guard let base = route(), (0..<64).contains(inputChannel) else { return nil }
        return .init(
            id: CourseBook.digest(Data("\(base.id)|input-channel:\(inputChannel)".utf8)), sampleRate: base.sampleRate)
    }

    func calibratedForCurrentRoute() -> Bool {
        guard let current = currentRoute() else { return false }
        return calibration?.usable(routeID: current.id, sampleRate: current.sampleRate, now: date()) == true
    }

    func select(_ plan: MicrophonePhrasePlan) throws {
        guard !busy, pending == nil, plan.valid else {
            throw MusicError.invalid("Save or discard the waiting take before changing the phrase.")
        }
        self.plan = plan
        displayedTake = nil
        elapsed = 0
        error = nil
    }

    func useGuidance() throws {
        guard !busy, pending == nil else {
            throw MusicError.invalid("Keep or discard the waiting take before using coaching.")
        }
        if let plan, plan.mode == .independent { self.plan = try plan.whole(mode: .context) }
    }

    func inspect(_ take: MicrophonePhraseTake) {
        guard !busy, pending == nil, take.valid else { return }
        plan = take.plan
        displayedTake = take
    }

    func cancel(_ reason: String? = nil) {
        if let origin = performanceOrigin, clock() >= origin, let interruption {
            let stopped = date()
            interruptedSave = { try interruption(stopped) }
            needsExposureSave = true
        }
        performanceOrigin = nil
        interruption = nil
        token = UUID()
        task?.cancel()
        task = nil
        output.stop()
        microphone?.stop()
        microphone = nil
        phase = .idle
        if let reason { error = reason }
        _ = retryExposureSave()
    }

    @discardableResult func retryExposureSave() -> Bool {
        guard let interruptedSave else { return true }
        do {
            try interruptedSave()
            self.interruptedSave = nil
            needsExposureSave = false
            return true
        } catch {
            self.error = "The interrupted practice could not be saved: \(error.localizedDescription)"
            return false
        }
    }

    func invalidate(_ reason: String) {
        calibration = nil
        cancel(reason)
    }

    func calibrate(microphone: Microphone) {
        guard !busy, pending == nil, let current = currentRoute(), current.valid else {
            error = "Save the waiting take and select an available input/output in Sound settings first."
            return
        }
        calibration = nil
        begin(microphone: microphone, route: current, plan: nil, calibration: nil, validate: {})
    }

    func start(
        _ plan: MicrophonePhrasePlan, microphone: Microphone, pitchOnly: Bool,
        interrupted: @escaping @MainActor (Date) throws -> Void = { _ in },
        validate: @escaping @MainActor () throws -> Void
    ) {
        guard !busy, pending == nil, plan.valid, let current = currentRoute(), current.valid else {
            error = "Save pending work, then choose an available microphone and a current phrase."
            return
        }
        let measured = calibration.flatMap {
            $0.usable(routeID: current.id, sampleRate: current.sampleRate, now: date()) ? $0 : nil
        }
        guard pitchOnly || measured != nil else {
            error = "Measure loopback timing for this route, or explicitly choose pitch-only practice."
            return
        }
        guard !(pitchOnly && plan.mode == .independent) else {
            error =
                "Independent timing review needs a measured calibration. Pitch-only practice stays available as a guided pass."
            return
        }
        guard retryExposureSave() else { return }
        begin(
            microphone: microphone, route: current, plan: plan, calibration: pitchOnly ? nil : measured,
            interrupted: interrupted, validate: validate)
    }

    private func begin(
        microphone: Microphone, route current: MicrophoneAudioRoute, plan: MicrophonePhrasePlan?,
        calibration measured: AcousticCalibration?, interrupted: @escaping @MainActor (Date) throws -> Void = { _ in },
        validate: @escaping @MainActor () throws -> Void
    ) {
        cancel()
        let captured = token
        self.microphone = microphone
        self.interruption = interrupted
        if let plan { self.plan = plan }
        displayedTake = nil
        error = nil
        elapsed = 0
        phase = .preparing
        task = Task { [weak self] in
            await microphone.startPhrase(channel: self?.inputChannel ?? 0)
            guard let self, captured == token, !Task.isCancelled else { return }
            guard microphone.listening else {
                cancel(microphone.error ?? "The microphone did not start.")
                return
            }
            do {
                try validate()
                guard currentRoute() == current else {
                    throw MusicError.invalid("The audio route changed while starting. Calibrate it again.")
                }
            } catch {
                cancel(error.localizedDescription)
                return
            }
            output.schedule(render: {
                if let plan { return try MicrophonePulseAudio.countIn(plan.timed) }
                return try MicrophonePulseAudio.calibration()
            }) { [weak self] result in
                guard let self, captured == token else { return }
                switch result {
                case .failure(let failure): cancel(failure.localizedDescription)
                case .success(let origin):
                    guard origin.isFinite, abs(origin - clock()) < 3 else {
                        cancel("Audio output did not provide a usable scheduled clock.")
                        return
                    }
                    if let plan {
                        performanceOrigin = origin + plan.timed.countIn
                        let first = plan.timed.targets.first!
                        let earliest =
                            first.beat * plan.timed.secondsPerBeat
                            - TimedMatcher.windowRadius(plan.timed, beat: first.beat) - 0.06
                        microphone.requirePhrasePreroll(
                            before: performanceOrigin! + (measured?.offsetMS ?? 0) / 1000 + earliest)
                    }
                    monitor(
                        origin: origin, route: current, plan: plan, calibration: measured, token: captured,
                        validate: validate)
                }
            }
        }
    }

    private func monitor(
        origin: Double, route current: MicrophoneAudioRoute, plan: MicrophonePhrasePlan?,
        calibration measured: AcousticCalibration?, token captured: UUID,
        validate: @escaping @MainActor () throws -> Void
    ) {
        let countIn = plan?.timed.countIn ?? 0
        let finishAt: Double
        if let plan {
            let timed = plan.timed
            let lastWindow =
                timed.targets.map {
                    $0.beat * timed.secondsPerBeat + TimedMatcher.windowRadius(timed, beat: $0.beat)
                }.max() ?? timed.duration
            // Include measured input delay and quality allowances after the last
            // ownership window; the written bar end alone does not prove coverage.
            let end =
                measured.map { max(timed.duration + 0.5, lastWindow + $0.offsetMS / 1000 + 0.1) }
                ?? (timed.duration + 1.1)
            finishAt = origin + timed.countIn + end
        } else {
            finishAt = origin + AcousticCalibration.pulseOffsets.last! + 0.9
        }
        phase = plan == nil ? .calibrating : .countIn
        task = Task { [weak self] in
            guard let self else { return }
            var nextRouteCheck = clock()
            while clock() < finishAt {
                guard !Task.isCancelled, captured == token else { return }
                guard microphone?.listening == true else {
                    cancel("The microphone stopped. Start a new pass.")
                    return
                }
                elapsed = clock() - origin - countIn
                if plan != nil { phase = elapsed < 0 ? .countIn : .playing }
                if clock() >= nextRouteCheck {
                    guard currentRoute() == current else {
                        invalidate("The audio route changed. This pass was stopped; measure timing again.")
                        return
                    }
                    nextRouteCheck = clock() + 0.25
                }
                do { try await Task.sleep(nanoseconds: 40_000_000) } catch { return }
            }
            phase = .finishing
            guard let result = await microphone?.finishPhrase(), captured == token, !Task.isCancelled else { return }
            let finishedExposure = interruption
            performanceOrigin = nil
            interruption = nil
            output.stop()
            phase = .idle
            self.microphone = nil
            do {
                try validate()
                guard currentRoute() == current else {
                    throw MusicError.invalid("The audio route changed during the take. Measure it again.")
                }
                if let issue = result.issue, plan == nil { throw MusicError.invalid(issue) }
                if let plan {
                    let passageOrigin = origin + countIn
                    let offset = (measured?.offsetMS ?? 0) / 1000
                    let attacks = result.attacks.filter {
                        let seconds = $0.hostSeconds - passageOrigin - offset
                        return seconds >= (measured == nil ? -0.2 : -0.5)
                            && seconds <= plan.timed.duration + (measured == nil ? 1 : 0.5)
                    }
                    let take = MicrophonePhraseTake(
                        date: date(), plan: plan, originHostSeconds: passageOrigin, calibration: measured,
                        routeID: current.id, sampleRate: result.sampleRate > 0 ? result.sampleRate : current.sampleRate,
                        attacks: attacks, signalIssue: result.issue, clock: .sharedHost,
                        clockEvidence: result.clockEvidence)
                    guard take.valid else {
                        throw MusicError.invalid(
                            "This audio evidence could not form a valid take. Try a shorter, clean phrase.")
                    }
                    pending = take
                    displayedTake = take
                } else {
                    let pulses = result.attacks.filter {
                        $0.frequency.map { abs($0 - 1000) <= 35 } == true && $0.confidence >= 0.90
                            && $0.clippedFraction < 0.01 && $0.onsetUncertaintyMS <= 25
                    }.map(\.hostSeconds)
                    guard result.clockEvidence?.usable == true else {
                        throw MusicError.invalid(
                            "The input clock could not support calibration. Try the current wired route again.")
                    }
                    var measured = try AcousticCalibration.measure(
                        expected: AcousticCalibration.pulseOffsets.map { origin + $0 }, observed: pulses,
                        routeID: current.id, sampleRate: result.sampleRate, now: date())
                    measured.clockEvidence = result.clockEvidence
                    calibration = measured
                }
            } catch {
                self.error = error.localizedDescription
                if plan != nil, let finishedExposure {
                    let stopped = date()
                    interruptedSave = { try finishedExposure(stopped) }
                    needsExposureSave = true
                    _ = retryExposureSave()
                }
            }
        }
    }

    func dispute(_ index: Int, uncertain: Bool) {
        guard var take = pending, take.plan.timed.targets.indices.contains(index) else { return }
        take.disputedTargets.removeAll { $0 == index }
        if uncertain {
            take.disputedTargets.append(index)
            take.disputedTargets.sort()
        }
        pending = take
        displayedTake = take
    }

    func save(using commit: (MicrophonePhraseTake) throws -> Void) {
        guard let take = pending else { return }
        do {
            try commit(take)
            pending = nil
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func discard() {
        guard !busy else { return }
        pending = nil
        displayedTake = nil
        error = nil
    }
}
