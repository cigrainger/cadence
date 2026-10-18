// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import CoreAudio
import Foundation
import MusicCore

/// Session-local identity: a new app launch always needs a new loopback check.
/// Buffer/rate changes matter even when the selected device IDs stay the same.
struct MicrophoneAudioRoute: Equatable, Sendable {
    var id: String
    var sampleRate: Double
    var valid: Bool {
        !id.isEmpty && id.utf8.count <= 256 && sampleRate.isFinite && (8000...192000).contains(sampleRate)
    }

    static func current() -> Self? {
        guard let input = integer(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice),
            let output = integer(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice),
            input != kAudioObjectUnknown, output != kAudioObjectUnknown,
            let inputRate = rate(input), let outputRate = rate(output),
            let inputBuffer = integer(input, kAudioDevicePropertyBufferFrameSize),
            let outputBuffer = integer(output, kAudioDevicePropertyBufferFrameSize)
        else { return nil }
        let result = Self(
            id: CourseBook.digest(
                Data("\(input)|\(output)|\(inputRate)|\(outputRate)|\(inputBuffer)|\(outputBuffer)".utf8)),
            sampleRate: inputRate)
        return result.valid ? result : nil
    }

    private static func integer(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func rate(_ device: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
            value.isFinite, (8000...192000).contains(value)
        else { return nil }
        return value
    }
}

enum MicrophonePulseAudio {
    static func countIn(_ plan: TimedPracticePlan) throws -> [Float] {
        var samples = try TimedClickTrack.render(plan, click: false)
        // Leave the final count-in beat silent. This gives the acoustic path room
        // to settle before even the earliest assessable first-note entrance.
        let quietStart = Int(((plan.countIn - plan.secondsPerBeat) * 44100).rounded())
        if samples.indices.contains(quietStart) {
            for i in quietStart..<samples.count { samples[i] = 0 }
        }
        return samples
    }

    static func calibration(sampleRate: Double = 44100) throws -> [Float] {
        guard sampleRate.isFinite, (8000...96000).contains(sampleRate),
            let last = AcousticCalibration.pulseOffsets.last, last.isFinite, (0...8).contains(last)
        else { throw MusicError.invalid("The loopback pulse schedule is invalid.") }
        var samples = [Float](repeating: 0, count: Int((last + 0.5) * sampleRate))
        for onset in AcousticCalibration.pulseOffsets {
            let start = Int((onset * sampleRate).rounded())
            let length = Int(0.1 * sampleRate)
            for frame in 0..<length where start + frame < samples.count {
                let time = Double(frame) / sampleRate
                let envelope = min(1, time / 0.003) * min(1, (0.1 - time) / 0.012)
                samples[start + frame] += Float(0.18 * envelope * sin(2 * .pi * 1000 * time))
            }
        }
        return samples
    }
}
