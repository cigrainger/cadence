// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct HarmonicScore: View {
    let piece: LibraryPiece
    let scope: PassageScope
    var analysis: ScoreAnalysis? = nil
    var focus: Int? = nil
    var playhead: StudyPlayhead? = nil
    @State private var height: CGFloat = 240
    @State private var error: String?
    @State private var study: MusicStudy?
    private var identity: String { piece.id + piece.fingerprint + scope.partID + (String(describing: analysis)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let study {
                ScrollView(.vertical) {
                    ScoreRenderer(
                        study: study, playhead: playhead,
                        focus: .init(
                            partID: scope.partID, staff: scope.staff, from: focus ?? scope.from,
                            through: focus ?? scope.through), height: $height, error: $error
                    ).frame(height: height)
                }.frame(height: min(300, max(190, height)))
                Text(
                    "Full score · highlighted \(focus.map { "bar \($0+1)" } ?? "bars \(scope.from+1)–\(scope.through+1)") · scroll to explore"
                ).font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(Color.clay) }
        }.task(id: identity) {
            do {
                study = try HarmonyTheory.displayStudy(piece: piece, partID: scope.partID, analysis: analysis)
                error = nil
            } catch {
                self.error = error.localizedDescription
                study = nil
            }
        }
    }
}
struct ScoreAnalysisPanel: View {
    @EnvironmentObject private var state: AppState
    let piece: LibraryPiece
    let scope: PassageScope
    var showsScore = true
    @State private var fifths = 0
    @State private var staff = 1
    @State private var focus: Int?
    @State private var editing: HarmonicAnnotation?
    @State private var expected: HarmonicAnnotation?
    @State private var error: String?
    private var currentScope: PassageScope {
        .init(partID: scope.partID, staff: staff, from: scope.from, through: scope.through)
    }
    private var staffs: [Int] {
        (try? ChangesSource(piece: piece, from: scope.from, through: scope.through, partID: scope.partID).staffs) ?? [1]
    }
    private var anchors: [HarmonyAnchor] { (try? HarmonyTheory.anchors(piece: piece, scope: currentScope)) ?? [] }
    private var analysis: ScoreAnalysis? { state.savedAnalysis(piece) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Read the harmony").font(.system(size: 25, weight: .medium, design: .serif))
                    Text("Your interpretations, attached to the music").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                ChoiceMenu(title: "Local major key", selection: $fifths, options: Array(-7...7)) {
                    HarmonyTheory.majorTonic(fifths: $0).name + " major"
                }.frame(width: 170)
            }
            HStack {
                Button("Hear selected bars", systemImage: "play.fill") {
                    do {
                        var study = try RehearsalSource.whole(piece, partID: scope.partID)
                        study.from = scope.from
                        study.through = scope.through
                        study.countIn = false
                        state.audio.playStudy(try StudyPlaybackPlan(study: study, wholePiece: false), loop: false)
                    } catch { self.error = error.localizedDescription }
                }
                Button("Stop", systemImage: "stop.fill") { state.audio.stop() }
                Text("Plays the written notes; chord symbols are read separately.").font(.caption).foregroundStyle(
                    .secondary)
            }
            if staffs.count > 1 {
                ChoiceMenu(title: "Harmony staff", selection: $staff, options: staffs) { "Staff \($0)" }.frame(
                    width: 180)
            }
            if showsScore { HarmonicScore(piece: piece, scope: currentScope, analysis: analysis, focus: focus) }
            if anchors.isEmpty {
                Text(
                    "Choose reviewed bars with chord symbols to add harmonic readings. Add symbols in Compose if needed."
                ).font(.callout)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(Array(anchors.enumerated()), id: \.element.id) { i, anchor in
                            let saved = analysis?.annotations.first { $0.id == anchor.id }
                            Button {
                                focus = anchor.bar
                                expected = saved
                                editing =
                                    saved
                                    ?? HarmonicAnnotation(
                                        anchor: anchor,
                                        readings: [
                                            HarmonyTheory.suggestion(
                                                anchor.symbol,
                                                next: i + 1 < anchors.count ? anchors[i + 1].symbol : nil,
                                                tonic: HarmonyTheory.majorTonic(fifths: fifths))
                                        ])
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("BAR \(anchor.bar+1) · \(String(format:"%.2g",1+Double(anchor.tick)/480)) qn")
                                        .font(.system(size: 9, weight: .semibold)).tracking(1)
                                    Text(anchor.symbol.label).font(.system(size: 25, weight: .medium, design: .serif))
                                    Text(saved?.readings.first?.roman ?? "Add a reading").font(.callout)
                                        .foregroundStyle(Color.moss)
                                    Text(
                                        saved == nil
                                            ? "Suggested starting point" : "\(saved!.readings.count) saved reading(s)"
                                    ).font(.caption2).foregroundStyle(.secondary)
                                }.frame(width: 150, alignment: .leading).padding(5)
                            }
                        }
                    }.padding(.vertical, 3)
                }
                Text(
                    "First readings appear above the staff. Keep alternative readings alongside them. Suggestions use your chosen major key and written chord symbols; check inversions, local key and style by ear and in the score."
                ).font(.caption).foregroundStyle(.secondary)
                HStack {
                    ForEach(EditorInstrument.allCases, id: \.self) { instrument in
                        Button(
                            "Explore tension · " + instrument.rawValue,
                            systemImage: instrument == .piano ? "pianokeys" : "guitars"
                        ) {
                            do {
                                try state.beginTension(
                                    piece: piece, scope: currentScope, tonic: HarmonyTheory.majorTonic(fifths: fifths),
                                    instrument: instrument)
                                error = nil
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
            if !anchors.isEmpty {
                HStack {
                    ForEach(EditorInstrument.allCases, id: \.self) { instrument in
                        Button("Reharmonise · " + instrument.rawValue, systemImage: "arrow.triangle.branch") {
                            do {
                                try state.beginReharm(
                                    piece: piece, scope: currentScope, tonic: HarmonyTheory.majorTonic(fifths: fifths),
                                    instrument: instrument)
                                error = nil
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(Color.clay) }
            TheoryReferences()
        }
        .onDisappear { state.audio.stop() }
        .onAppear {
            staff = staffs.contains(scope.staff ?? 1) ? (scope.staff ?? 1) : (staffs.first ?? 1)
            if case .score(let doc) = piece.source { fifths = doc.fifths }
            if case .study(let original) = piece.source { fifths = original.part.measures.first?.fifths ?? 0 }
        }
        .onAppear {
            if state.isPreview, CommandLine.arguments.contains("--tension-reading"), let first = anchors.first {
                expected = analysis?.annotations.first { $0.id == first.id }
                editing =
                    expected ?? HarmonicAnnotation(anchor: first, readings: [.init(roman: "V7/ii", function: .applied)])
            }
        }
        .sheet(item: $editing) { item in
            HarmonicReadingEditor(item: item) { value in
                try state.saveHarmonicReading(piece: piece, scope: currentScope, item: value, expected: expected)
            }
        }
    }
}
private struct HarmonicReadingEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var item: HarmonicAnnotation
    let save: (HarmonicAnnotation) throws -> Void
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("\(item.anchor.symbol.label) · bar \(item.anchor.bar+1)").font(
                .system(size: 28, weight: .medium, design: .serif))
            Text("Interpret this moment. The first reading is shown on the score.").foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(item.readings.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(index == 0 ? "On the score" : "Alternative \(index)").font(.headline)
                                Spacer()
                                if item.readings.count > 1 { Button("Remove") { item.readings.remove(at: index) } }
                            }
                            HStack {
                                TextField("Roman numeral / analysis label", text: $item.readings[index].roman)
                                    .textFieldStyle(.roundedBorder)
                                ChoiceMenu(
                                    title: "Function", selection: $item.readings[index].function,
                                    options: HarmonicFunction.allCases
                                ) { $0.rawValue }.frame(width: 245)
                            }
                            TextField("Style / convention", text: $item.readings[index].convention).textFieldStyle(
                                .roundedBorder)
                            Text("Why this reading? What do you hear?").font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $item.readings[index].explanation).font(.callout).frame(height: 75)
                                .scrollContentBackground(.hidden).padding(9)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 8)).overlay(
                                    RoundedRectangle(cornerRadius: 8).stroke(Color.line)
                                )
                                .accessibilityLabel("Explanation for reading \(index+1)")
                        }.padding(16).background(Color.paper, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            if let error { Text(error).foregroundStyle(Color.clay).font(.callout) }
            HStack {
                Button("Add another reading", systemImage: "plus") { item.readings.append(.init()) }.disabled(
                    item.readings.count >= 6)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save readings") {
                    do {
                        try save(item)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.cadencePrimary)
            }
        }.padding(28).frame(width: 720, height: 640).background(Color.paper).buttonStyle(.cadence)
    }
}
struct TheoryReferences: View {
    var body: some View {
        HStack(spacing: 16) {
            Text("READ & EXPLORE").font(.system(size: 9, weight: .semibold)).tracking(1)
            Link("OMT · tonicization", destination: URL(string: HarmonyTheory.omt)!)
            Link("OMT · jazz harmony", destination: URL(string: HarmonyTheory.jazz)!)
            Link("MIT · sing, play, compose", destination: URL(string: HarmonyTheory.mit)!)
        }.font(.caption).foregroundStyle(Color.moss)
    }
}
