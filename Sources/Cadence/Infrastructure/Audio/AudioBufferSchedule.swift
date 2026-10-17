// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AVFoundation

/// Queue a buffer and return immediately. Awaiting the SDK alternative would
/// wait for playback completion, delaying the host-clock origin/count-in setup.
enum AudioBufferSchedule {
    static func enqueue(_ buffer: AVAudioPCMBuffer, on player: AVAudioPlayerNode, looping: Bool = false) {
        player.scheduleBuffer(buffer, at: nil, options: looping ? .loops : [], completionHandler: nil)
    }
}
