// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import Foundation

/// A paid reply remains available when only its local save needs another attempt.
@MainActor final class SavedRequest<Reply>: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var started: Date?
    @Published private(set) var pending: Reply?
    @Published private(set) var completedID: UUID?
    @Published var error: String?
    private var job: Task<Void, Never>?
    private var token = UUID()
    private var commit: (@MainActor (Reply) throws -> Void)?

    func run(
        request: @escaping @MainActor () async throws -> Reply, commit: @escaping @MainActor (Reply) throws -> Void
    ) {
        guard !busy, pending == nil else { return }
        self.commit = commit
        token = UUID()
        let current = token
        busy = true
        started = Date()
        error = nil
        job = Task { @MainActor in
            defer {
                if token == current {
                    busy = false
                    started = nil
                    job = nil
                }
            }
            do {
                let reply = try await request()
                try Task.checkCancellation()
                guard token == current else { return }
                pending = reply
                retrySave()
            } catch {
                if token == current {
                    self.error =
                        Task.isCancelled ? "Request stopped. Saved work is unchanged." : error.localizedDescription
                }
            }
        }
    }
    func accept(_ reply: Reply, commit: @escaping @MainActor (Reply) throws -> Void) {
        guard !busy, pending == nil else { return }
        self.commit = commit
        pending = reply
        retrySave()
    }
    func retrySave() {
        guard let pending, let commit else { return }
        do {
            try commit(pending)
            self.pending = nil
            self.commit = nil
            error = nil
            completedID = UUID()
        } catch {
            self.error =
                "The reply could not be saved: " + error.localizedDescription
                + " Keep this view open and try saving again."
        }
    }
    func cancel() {
        if busy { error = "Request stopped. Saved work is unchanged; work already sent may still be charged." }
        token = UUID()
        job?.cancel()
        job = nil
        busy = false
        started = nil
        if pending == nil { commit = nil }
    }
    /// Explicit user recovery after copying an unsavable reply. This never
    /// records completion or retries the request; cancellation alone keeps it.
    func discardPending() {
        guard !busy, pending != nil else { return }
        pending = nil
        commit = nil
        error = nil
    }
}
