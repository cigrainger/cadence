// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct PassageTempoView: View {
    @EnvironmentObject private var state: AppState
    var study: MusicStudy
    @State private var showHistory = false
    private var progress: PassageTempoProgress {
        study.practiceBook?.progress(for: study) ?? PassageTempoProgress(study: study)
    }
    private var bpm: Double { study.document.tempo * study.speed }
    private var next: Double { progress.nextBPM(current: bpm, sourceTempo: study.document.tempo) }
    var body: some View {
        Card(
            title: "Build a comfortable tempo",
            subtitle: study.passageLabel + " · saved for this part and staff selection", padding: 16, spacing: 10
        ) {
            HStack(spacing: 14) {
                Text("\(number(bpm)) bpm").font(.system(size: 23, weight: .medium, design: .serif)).foregroundStyle(
                    Color.moss
                ).monospacedDigit()
                Stepper(
                    "Target \(number(progress.targetBPM))",
                    value: Binding(get: { progress.targetBPM }, set: { value in change { $0.targetBPM = value } }),
                    in: study.document.tempo * 0.25...study.document.tempo * 1.5, step: 1
                ).fixedSize()
                ChoiceMenu(
                    title: "Tempo step",
                    selection: Binding(get: { progress.increment }, set: { value in change { $0.increment = value } }),
                    options: [2, 5, 10], label: { "+\($0) bpm" }
                ).frame(width: 100)
                Spacer(minLength: 0)
                Button("Mark comfortable", systemImage: "checkmark.circle") { change { try $0.record(bpm) } }
                Button("Try \(number(next)) bpm", systemImage: "arrow.up.right") {
                    state.editStudy(study.id) { $0.speed = next / study.document.tempo }
                }.disabled(next <= bpm + 0.01)
            }.controlSize(.small)
            HStack {
                Text(
                    progress.bestBPM.map { "Best recorded: \(number($0)) bpm" }
                        ?? "Start slowly, and mark a tempo when it feels comfortable."
                ).font(.caption).foregroundStyle(.secondary)
                if progress.reachedTarget {
                    Label("Target reached", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(
                        Color.moss)
                }
                Spacer()
                if !progress.comfortable.isEmpty {
                    Button(showHistory ? "Hide history" : "Tempo history") { showHistory.toggle() }.font(.caption)
                        .buttonStyle(.plain).foregroundStyle(Color.moss)
                }
            }
            if showHistory {
                ForEach(progress.comfortable.suffix(6).reversed()) { mark in
                    HStack {
                        Text(mark.date.formatted(date: .abbreviated, time: .shortened))
                        Spacer()
                        Text("\(number(mark.bpm)) bpm").monospacedDigit()
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(
                "Your own comfort check · no automatic rating of your playing. Tempo changes apply when you start playback again."
            ).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    private func number(_ value: Double) -> String { String(format: "%.3g", value) }
    private func change(_ action: (inout PassageTempoProgress) throws -> Void) {
        var updated = progress
        do {
            try action(&updated)
            state.editStudy(study.id) {
                var book = $0.practiceBook ?? PassagePracticeBook()
                book.set(updated)
                $0.practiceBook = book
            }
        } catch { state.message = error.localizedDescription }
    }
}
