// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A hardware anchor and the bounded residual of subsequent device timestamps.
/// This preserves the sample/host conversion independently of delivery and DSP.
public struct AcousticClockEvidence: Codable, Equatable, Sendable {
    public var firstSampleTime: Int64
    public var firstHostSeconds: Double
    public var sampleRate: Double
    public var frameCount: Int
    public var inputChannel: Int?
    public var maximumHostResidualMS: Double
    public var version = "sample-host-anchor-v1"
    public init(
        firstSampleTime: Int64, firstHostSeconds: Double, sampleRate: Double, frameCount: Int,
        maximumHostResidualMS: Double, inputChannel: Int? = nil
    ) {
        self.inputChannel = inputChannel
        self.firstSampleTime = firstSampleTime
        self.firstHostSeconds = firstHostSeconds
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.maximumHostResidualMS = maximumHostResidualMS
    }
    public var valid: Bool {
        sampleRate.isFinite && (8000...192000).contains(sampleRate) && firstHostSeconds.isFinite
            && firstHostSeconds >= 0 && firstHostSeconds.ulp <= 1 / sampleRate
            && frameCount >= 0 && Double(frameCount) <= sampleRate * 35
            && maximumHostResidualMS.isFinite && (0...5000).contains(maximumHostResidualMS)
            && (inputChannel.map { (0..<64).contains($0) } ?? true)
            && version == "sample-host-anchor-v1"
    }
    public var usable: Bool { valid && frameCount > 0 && maximumHostResidualMS <= 5 }
    /// Calibration and take anchors each contribute this allowance, separately.
    public var mappingAllowanceMS: Double { 5 }
    public func sampleTime(at host: Double) -> Int64? {
        guard valid, host.isFinite else { return nil }
        let delta = ((host - firstHostSeconds) * sampleRate).rounded()
        guard delta.isFinite, (-1...Double(frameCount) + 1).contains(delta) else { return nil }
        let result = firstSampleTime.addingReportingOverflow(Int64(delta))
        return result.overflow ? nil : result.partialValue
    }
}
