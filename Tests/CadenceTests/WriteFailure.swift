// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

/// Fault injection is shared mutable state, with the same actor ownership as the
/// commit it controls. Do not hide mutable captured locals behind Sendable.
@MainActor final class WriteFailure { var enabled = true }
