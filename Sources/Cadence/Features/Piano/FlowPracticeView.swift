// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct FlowPassagePicker: View {
    @EnvironmentObject private var state: AppState
    let record: PieceRehearsal
    let joins: [FlowJoin]
    let locked: Bool
    @Binding var error: String?
    private var choices: [TimedPracticePlan] {
        var seen = Set<PassageScope>()
        return (joins.map(\.plan) + [record.opening]).filter { plan in
            plan.source.map { seen.insert($0.scope).inserted } ?? false
        }
    }
    var body: some View {
        if let flow = record.flow {
            Picker(
                "Passage",
                selection: Binding(
                    get: { flow.plan.source?.scope },
                    set: { scope in
                        if let plan = choices.first(where: { $0.source?.scope == scope }) {
                            var next = flow
                            next.plan = plan
                            update(next)
                        }
                    })
            ) {
                ForEach(Array(choices.enumerated()), id: \.offset) { _, plan in
                    Text(label(plan)).tag(plan.source?.scope)
                }
            }.disabled(locked)
            Picker(
                "Click",
                selection: Binding(
                    get: { flow.pulse },
                    set: { pulse in
                        var next = flow
                        next.pulse = pulse
                        update(next)
                    })
            ) {
                ForEach(FlowPulse.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.disabled(locked)
        }
    }
    private func label(_ plan: TimedPracticePlan) -> String {
        guard let scope = plan.source?.scope else { return "Phrase" }
        if scope == record.opening.source?.scope { return "Whole opening phrase" }
        return "Join · bars \(scope.from+1)–\(scope.through+1)"
    }
    private func update(_ settings: FlowSettings) {
        do {
            try state.configureRehearsalFlow(settings)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct FlowAdviceView: View {
    @EnvironmentObject private var state: AppState
    let record: PieceRehearsal
    let exercise: RehearsalExercise
    let joins: [FlowJoin]
    let locked: Bool
    @Binding var error: String?
    var body: some View {
        let advice = FlowPractice.advice(record, exercise: exercise)
        VStack(alignment: .leading, spacing: 9) {
            Label("A possible next step", systemImage: "arrow.up.right").font(.caption.weight(.medium)).foregroundStyle(
                Color.moss)
            Text(advice.title).font(.system(size: 20, weight: .medium, design: .serif))
            Text(advice.reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let settings = advice.settings {
                Button("Try this setting") {
                    do {
                        try state.configureRehearsalFlow(settings)
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                    }
                }.disabled(locked)
            }
            if let join = joins.first(where: { $0.plan == record.flow?.plan }) {
                DisclosureGroup("Why this join?") {
                    Text(join.reason + " Complete ties stay inside the loop.").font(.caption).foregroundStyle(
                        .secondary)
                }.font(.caption)
            }
            Text(
                "Keep this pace, choose another join or move on. Suggestions use your latest completed passes at these settings."
            ).font(.caption).foregroundStyle(.secondary)
        }.padding(12).background(Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
    }
}
