// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Detached preparation must follow its playback task's cancellation. Otherwise
/// repeated Play/Stop can leave multiple large sample buffers rendering at once.
enum AudioRenderTask {
    static func run<T: Sendable>(_ render: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try render()
        }
        return try await withTaskCancellationHandler(
            operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}
