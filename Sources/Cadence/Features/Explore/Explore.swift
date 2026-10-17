// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct ExploreView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(spacing: 20) {
            HStack(alignment: .top, spacing: 20) {
                Card(title: "Circle of fifths", subtitle: "Major · relative minor") {
                    CircleOfFifths().frame(height: 300)
                }.frame(width: 360)
                Card(title: "\(state.root.name) \(state.scale.rawValue)") {
                    Text(state.scale.character).font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 7) {
                        ForEach(Array(state.scaleNotes.enumerated()), id: \.offset) { i, note in
                            VStack(spacing: 8) {
                                Text(note.name).font(.system(size: 20, weight: .medium, design: .serif))
                                Text(state.scale.formula[i]).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity).padding(.vertical, 12).background(
                                i == 0 ? Color.clay.opacity(0.10) : Color.canvas, in: RoundedRectangle(cornerRadius: 9))
                        }
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("KEY SIGNATURE").font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(
                            .secondary)
                        Text(signatureNotes(state.scale.signature(state.root))).font(.system(size: 14, weight: .medium))
                        if [.harmonicMinor, .melodicMinor].contains(state.scale) {
                            Text("Uses the minor key signature; raised notes are written as accidentals.").font(
                                .caption
                            ).foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("Compare").font(.caption)
                        ChoiceMenu(
                            title: "Compare scales", selection: $state.comparison,
                            options: [Optional<Scale>.none] + Scale.allCases.map(Optional.some),
                            label: { $0?.rawValue ?? "No comparison" }
                        ).font(.caption).frame(maxWidth: 260)
                    }
                    HStack {
                        Button("Hear the scale", systemImage: "play.fill") { state.playScale() }.buttonStyle(
                            .cadencePrimary)
                        Button("Explain this", systemImage: "sparkles") {
                            state.ask(
                                "Explain \(state.root.name) \(state.scale.rawValue), its sound, and a short guitar and piano exercise."
                            )
                        }.buttonStyle(.cadence)
                        Button {
                            state.instrumentFocus += 1
                        } label: {
                            Image(systemName: "pianokeys")
                        }.accessibilityLabel("Jump to guitar and piano")
                    }
                }.frame(minHeight: 348)
            }
            if let other = state.comparison, other != state.scale {
                Card(title: "Compare with \(state.root.name) \(other.rawValue)") {
                    let selected = state.scaleNotes
                    let comparison = other.notes(state.root)
                    HStack(spacing: 8) {
                        ForEach(Array(comparison.enumerated()), id: \.offset) { index, note in
                            let changed = !selected.contains { $0.pc == note.pc }
                            VStack(spacing: 6) {
                                Text(note.name).font(.system(size: 19, weight: .medium, design: .serif))
                                Text(other.formula[index]).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity).padding(10).background(
                                changed ? Color.clay.opacity(0.12) : Color.canvas, in: RoundedRectangle(cornerRadius: 9)
                            )
                        }
                    }
                    HStack {
                        Text("Notes unique to the comparison are outlined on both instruments.").font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Hear comparison", systemImage: "play") { state.playScale(other) }
                        Button("Hear selected", systemImage: "play") { state.playScale() }
                    }
                }
            }
            let chords = harmonize(root: state.root, scale: state.scale)
            if !chords.isEmpty {
                Card(title: "Chords in this scale", subtitle: "Open a chord to explore its voicings") {
                    HStack(spacing: 10) {
                        ForEach(Array(chords.enumerated()), id: \.offset) { _, chord in
                            Button {
                                state.useChord(chord)
                            } label: {
                                VStack(spacing: 8) {
                                    Text(chord.degree).font(.caption).foregroundStyle(.secondary)
                                    Text(chord.root.name + chord.quality.symbol).font(
                                        .system(size: 19, weight: .medium, design: .serif))
                                }.frame(maxWidth: .infinity).padding(.vertical, 13).background(
                                    Color.canvas, in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain)
                                .contextMenu {
                                    Button("Hear chord") {
                                        state.audio.chord(chord.quality.intervals.map { 60 + chord.root.pc + $0 })
                                    }
                                }
                        }
                    }
                }
            }
            InstrumentCards(
                notes: state.scaleNotes, degrees: state.scale.formula,
                comparison: state.comparison == state.scale ? [] : state.comparison?.notes(state.root) ?? []
            ).id("instruments")
        }
    }
}

struct InstrumentCards: View {
    @EnvironmentObject var state: AppState
    var notes: [Pitch]
    var degrees: [String]
    var exactNotes: Set<Int>? = nil
    var comparison: [Pitch] = []
    @State private var tuningEditor = false
    var body: some View {
        VStack(spacing: 20) {
            Card(title: "On the guitar", subtitle: "Click any fret to hear it · roots in terracotta") {
                HStack {
                    TuningPicker().frame(width: 210)
                    Button("Custom…") { tuningEditor = true }.font(.caption)
                    Stepper("Capo \(state.capo)", value: $state.capo, in: 0...9).frame(width: 120)
                    Spacer()
                    Toggle("Left handed", isOn: $state.leftHanded).toggleStyle(.checkbox)
                    Toggle("Degrees", isOn: $state.showDegrees).toggleStyle(.checkbox)
                }.font(.caption)
                Fretboard(
                    root: state.root, notes: notes, degrees: degrees, tuning: state.tuning, capo: state.capo,
                    showDegrees: state.showDegrees, leftHanded: state.leftHanded, comparison: comparison,
                    play: state.audio.note)
            }
            Card(title: "On the piano", subtitle: "Click any key to hear it") {
                Piano(
                    root: state.root, notes: notes, degrees: degrees, showDegrees: state.showDegrees,
                    exactNotes: exactNotes, comparison: comparison, play: state.audio.note)
            }
        }
        .sheet(isPresented: $tuningEditor) { TuningEditor().environmentObject(state) }
    }
}

struct ChordsView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Chord workspace", selection: $state.showChanges) {
                Text("One chord").tag(false)
                Text("Follow the changes").tag(true)
            }.pickerStyle(.segmented).frame(width: 330)
            if state.showChanges {
                FollowChangesView(midi: state.midi, audio: state.audio, session: state.changesSession).id(
                    state.changesPlan.id)
            } else {
                SingleChordView()
            }
        }
    }
}

struct SingleChordView: View {
    @EnvironmentObject var state: AppState
    @State private var voicings: [Voicing] = []
    @State private var triadsOnly = false
    @State private var stringGroup = -1
    @State private var inversion = 0
    @State private var loading = true
    private var key: String {
        "\(state.activeChordRoot.name)-\(state.quality.rawValue)-\(state.tuning.pitches)-\(state.capo)-\(triadsOnly)-\(stringGroup)"
    }
    private var pianoNotes: [Int] {
        let notes = state.quality.intervals.map { 48 + state.activeChordRoot.pc + $0 }
        return notes.enumerated().map { $0.element + ($0.offset < min(inversion, notes.count - 1) ? 12 : 0) }.sorted()
    }
    var body: some View {
        VStack(spacing: 20) {
            Card(
                title: "\(state.activeChordRoot.name)\(state.quality.symbol)",
                subtitle: "Key context: \(state.root.name) \(state.scale.rawValue)"
            ) {
                HStack(alignment: .center, spacing: 16) {
                    ForEach(state.chordNotes, id: \.self) { note in
                        Text(note.name).font(.system(size: 30, weight: .medium, design: .serif)).padding(16).background(
                            Color.canvas, in: RoundedRectangle(cornerRadius: 12))
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 10) {
                        ChoiceMenu(
                            title: "Piano inversion", selection: $inversion, options: Array(0..<state.chordNotes.count)
                        ) { ["Root position", "First inversion", "Second inversion", "Third inversion"][min(3, $0)] }
                        .frame(width: 235)
                        Button("Hear chord", systemImage: "play.fill") { state.audio.chord(pianoNotes) }.buttonStyle(
                            .cadencePrimary)
                    }
                }
                Piano(
                    root: state.activeChordRoot, notes: state.chordNotes, degrees: [], showDegrees: false,
                    exactNotes: Set(pianoNotes), play: state.audio.note)
            }
            Card(title: "Guitar voicings", subtitle: "Frets are relative to the capo · low E at left") {
                HStack {
                    TuningPicker().frame(width: 220)
                    Stepper("Capo \(state.capo)", value: $state.capo, in: 0...9).frame(width: 130)
                    Spacer()
                    Toggle("Three note shapes", isOn: $triadsOnly).disabled(state.chordNotes.count > 3)
                }
                if triadsOnly && state.chordNotes.count == 3 {
                    ChoiceMenu(title: "String set", selection: $stringGroup, options: Array(-1...3)) {
                        $0 == -1 ? "All adjacent sets" : TriadNeck.sets[$0]
                    }.frame(width: 300)
                }
                Text(
                    "Shapes are ranked for a low position, compact reach, and a root in the bass. Try a few to find the fingering that suits your hand."
                ).font(.caption).foregroundStyle(.secondary)
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                } else if voicings.isEmpty {
                    Text(
                        "No compact shape found with these settings. Try a different tuning or turn off three note shapes."
                    ).foregroundStyle(.secondary).padding()
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 200))], spacing: 16) {
                        ForEach(Array(voicings.prefix(12).enumerated()), id: \.offset) { i, voicing in
                            Button {
                                state.audio.chord(voicing.pitches)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(i == 0 ? "START HERE" : "VOICING \(i+1)").font(
                                            .system(size: 9, weight: .semibold)
                                        ).tracking(1)
                                        Spacer()
                                        Image(systemName: "play.circle").foregroundStyle(Color.moss)
                                    }
                                    ChordDiagram(
                                        voicing: voicing, root: state.activeChordRoot, tuning: state.tuning,
                                        capo: state.capo)
                                    Text("Bass: \(Pitch.chromatic(voicing.pitches.min() ?? 0,flats:true))").font(
                                        .caption2
                                    ).foregroundStyle(.secondary)
                                }.padding(12).background(Color.canvas, in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .task(id: key) {
            loading = true
            let root = state.activeChordRoot
            let quality = state.quality
            let tuning = state.tuning
            let capo = state.capo
            let triads = triadsOnly && quality.intervals.count == 3
            let group = stringGroup < 0 ? nil : stringGroup
            let result = await Task.detached {
                Guitar.voicings(
                    root: root, quality: quality, tuning: tuning, capo: capo, triads: triads, stringGroup: group)
            }.value
            guard !Task.isCancelled else { return }
            voicings = result
            loading = false
        }
        .onChange(of: state.quality) { _, _ in inversion = 0 }
    }
}
