// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import MusicCore
import SwiftUI
import UniformTypeIdentifiers

struct PracticeHistoryView: View {
    @EnvironmentObject private var state: AppState
    @State private var expanded = false
    @State private var exportError: String?
    var body: some View {
        DisclosureGroup("Your recent practice", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(
                        "\(state.journal.checked.count) checks · \(state.journal.firstTryCorrect) first-try correct · \(state.journal.sessionCount) \(state.journal.sessionCount == 1 ? "session" : "sessions")"
                    ).font(.caption)
                    Spacer()
                    Button("Export history", systemImage: "square.and.arrow.up") { export() }.controlSize(.small)
                }
                Text(
                    "A record of what you tried, not a proficiency score. Input methods and assisted answers stay distinct. Earlier totals are retained above; this detailed history starts with this version."
                ).font(.caption).foregroundStyle(.secondary)
                if let error = state.journalStorageError { Text(error).font(.caption).foregroundStyle(Color.clay) }
                if state.journal.attempts.isEmpty {
                    Text("Your next exercise will start this history.").foregroundStyle(.secondary).font(.caption)
                }
                ForEach(state.journal.attempts.suffix(10).reversed()) { attempt in
                    HStack(spacing: 12) {
                        Image(
                            systemName: attempt.outcome == .correct
                                ? "checkmark.circle"
                                : attempt.outcome == .incorrect ? "arrow.clockwise.circle" : "circle.dotted"
                        ).foregroundStyle(attempt.outcome == .correct ? Color.moss : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attempt.title).font(.system(size: 12))
                            Text(
                                attempt.timedPracticeID != nil
                                    ? "\(attempt.input == .midi ? "MIDI" : "Spacebar") · timed pass · \(Int(attempt.tempo ?? 80)) bpm · \(attempt.outcome == .correct ? "on time" : "another look")"
                                    : attempt.guidedPracticeID != nil
                                        ? "MIDI · guided passage completed · timing untested"
                                        : "\(attempt.input == .midi ? "MIDI" : attempt.input == .selfReport ? "Self report" : attempt.input.rawValue.capitalized) · \(attempt.outcome.rawValue)\(attempt.assisted ? " · assisted" : "")"
                            ).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(attempt.date, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let exportError { Text(exportError).font(.caption).foregroundStyle(Color.clay) }
            }.padding(.top, 12)
        }.padding(16).background(Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
            .onAppear {
                if state.journalStorageError != nil
                    || (state.isPreview && CommandLine.arguments.contains("--midi-chord-check"))
                {
                    expanded = true
                }
            }
    }
    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Cadence-practice-history.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state.journal).write(to: url, options: .atomic)
        } catch { exportError = error.localizedDescription }
    }
}
