// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct Fretboard: View {
    var root: Pitch
    var notes: [Pitch]
    var degrees: [String]
    var tuning: Tuning
    var capo: Int
    var showDegrees: Bool
    var leftHanded: Bool
    var comparison: [Pitch] = []
    var play: (Int) -> Void
    var exactFrets: [Int: Int]? = nil
    var fretCount = 12
    var colorRoots = true
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let start = 62.0
            let end = width - 22
            let top = 30.0
            let bottom = height - 38
            let gap = (bottom - top) / 5
            let boundary: (Int) -> Double = { fret in
                start + (end - start) * (1 - pow(2, -Double(fret) / 12)) / (1 - pow(2, -Double(fretCount) / 12))
            }
            let displayX: (Double) -> Double = { x in leftHanded ? width - x : x }
            let labelMap = Dictionary(
                notes.enumerated().map {
                    ($0.element.pc, showDegrees && $0.offset < degrees.count ? degrees[$0.offset] : $0.element.name)
                }, uniquingKeysWith: { first, _ in first })
            let comparisonMap = Dictionary(comparison.map { ($0.pc, $0.name) }, uniquingKeysWith: { first, _ in first })
            Canvas { context, size in
                let board = CGRect(
                    x: leftHanded ? width - end : start, y: top - 17, width: end - start, height: bottom - top + 34)
                context.fill(
                    Path(roundedRect: board, cornerRadius: 8), with: .color(Color(red: 0.96, green: 0.93, blue: 0.87)))
                for fret in 0...fretCount {
                    let x = displayX(boundary(fret))
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: top - 17))
                    line.addLine(to: CGPoint(x: x, y: bottom + 17))
                    context.stroke(
                        line, with: .color(fret == 0 ? Color.ink : Color.ink.opacity(0.2)),
                        lineWidth: fret == 0 ? 4 : 1.2)
                    if fret > 0 {
                        let center = displayX((boundary(fret - 1) + boundary(fret)) / 2)
                        context.draw(
                            Text("\(fret)").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary),
                            at: CGPoint(x: center, y: height - 12))
                        if [3, 5, 7, 9, 12].contains(fret) {
                            let ys = fret == 12 ? [top + gap * 1.5, top + gap * 3.5] : [top + gap * 2.5]
                            for y in ys {
                                context.fill(
                                    Path(ellipseIn: CGRect(x: center - 3, y: y - 3, width: 6, height: 6)),
                                    with: .color(Color.ink.opacity(0.13)))
                            }
                        }
                    }
                }
                for row in 0..<6 {
                    let string = 5 - row
                    let y = top + Double(row) * gap
                    var line = Path()
                    line.move(to: CGPoint(x: displayX(start), y: y))
                    line.addLine(to: CGPoint(x: displayX(end), y: y))
                    context.stroke(line, with: .color(Color.ink.opacity(0.3)), lineWidth: 0.6 + Double(row) * 0.22)
                    context.draw(
                        Text(Pitch.chromatic(tuning.pitches[string] + capo)).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary), at: CGPoint(x: displayX(13), y: y))
                    for fret in 0...fretCount {
                        if let exactFrets, exactFrets[string] != fret { continue }
                        let midi = tuning.pitches[string] + capo + fret
                        guard let label = labelMap[mod(midi)] ?? comparisonMap[mod(midi)] else { continue }
                        let comparisonOnly = labelMap[mod(midi)] == nil
                        let x = displayX(fret == 0 ? 39 : (boundary(fret - 1) + boundary(fret)) / 2)
                        let circle = Path(ellipseIn: CGRect(x: x - 12, y: y - 12, width: 24, height: 24))
                        context.fill(
                            circle,
                            with: .color(comparisonOnly ? .canvas : colorRoots && mod(midi) == root.pc ? .clay : .moss))
                        if comparisonOnly { context.stroke(circle, with: .color(.clay), lineWidth: 1.5) }
                        context.draw(
                            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(
                                comparisonOnly ? Color.clay : .white), at: CGPoint(x: x, y: y))
                    }
                }
            }
            .gesture(
                SpatialTapGesture().onEnded { value in
                    let x = leftHanded ? width - value.location.x : value.location.x
                    let row = min(5, max(0, Int(((value.location.y - top) / gap).rounded())))
                    let fret = x < start ? 0 : ((1...fretCount).first { x <= boundary($0) } ?? fretCount)
                    play(tuning.pitches[5 - row] + capo + fret)
                })
        }
        .frame(height: 244)
        .accessibilityLabel(
            "Guitar fretboard, \(tuning.name), capo \(capo). Notes: \(notes.map(\.name).joined(separator:", ")). High string at the top. Click any fret to hear it."
        )
        .accessibilityChildren {
            ForEach(0..<6, id: \.self) { string in
                ForEach(0...fretCount, id: \.self) { fret in
                    Button("String \(6-string), fret \(fret), \(Pitch.chromatic(tuning.pitches[string]+capo+fret))") {
                        play(tuning.pitches[string] + capo + fret)
                    }
                }
            }
        }
    }
}

struct Piano: View {
    var root: Pitch
    var notes: [Pitch]
    var degrees: [String]
    var showDegrees: Bool
    var exactNotes: Set<Int>? = nil
    var comparison: [Pitch] = []
    var play: (Int) -> Void
    var midiRange: ClosedRange<Int> = 48...83
    var colorRoots = true
    var keyHeight: CGFloat = 156
    private var range: [Int] { Array(midiRange) }
    private func black(_ midi: Int) -> Bool { [1, 3, 6, 8, 10].contains(mod(midi)) }
    var body: some View {
        GeometryReader { geometry in
            let whites = range.filter { !black($0) }
            let keyWidth = geometry.size.width / Double(whites.count)
            let blackWidth = keyWidth * 0.60
            let height = geometry.size.height
            let labelMap = Dictionary(
                notes.enumerated().map {
                    ($0.element.pc, showDegrees && $0.offset < degrees.count ? degrees[$0.offset] : $0.element.name)
                }, uniquingKeysWith: { first, _ in first })
            let comparisonMap = Dictionary(comparison.map { ($0.pc, $0.name) }, uniquingKeysWith: { first, _ in first })
            Canvas { context, size in
                for (index, midi) in whites.enumerated() {
                    let rect = CGRect(x: Double(index) * keyWidth + 1, y: 0, width: keyWidth - 2, height: height - 1)
                    let selected = exactNotes?.contains(midi) ?? (labelMap[mod(midi)] != nil)
                    let color: Color =
                        selected
                        ? (colorRoots && mod(midi) == root.pc ? Color.clay.opacity(0.21) : Color.moss.opacity(0.15))
                        : .white
                    context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(color))
                    context.stroke(Path(roundedRect: rect, cornerRadius: 5), with: .color(.line), lineWidth: 1)
                    if selected {
                        let center = CGPoint(x: rect.midX, y: height - 31)
                        let diameter = keyHeight < 156 ? min(24, max(6, keyWidth - 2)) : 24
                        context.fill(
                            Path(
                                ellipseIn: CGRect(
                                    x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter,
                                    height: diameter)), with: .color(colorRoots && mod(midi) == root.pc ? .clay : .moss)
                        )
                        if diameter >= 20 {
                            context.draw(
                                Text(labelMap[mod(midi)] ?? Pitch.chromatic(midi)).font(
                                    .system(size: 9, weight: .semibold)
                                ).foregroundStyle(.white), at: center)
                        }
                    } else if let label = comparisonMap[mod(midi)] {
                        let center = CGPoint(x: rect.midX, y: height - 31)
                        context.stroke(
                            Path(ellipseIn: CGRect(x: center.x - 12, y: center.y - 12, width: 24, height: 24)),
                            with: .color(.clay), lineWidth: 1.5)
                        context.draw(
                            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.clay),
                            at: center)
                    } else if mod(midi) == 0 {
                        context.draw(
                            Text("C\(midi/12-1)").font(.system(size: 10)).foregroundStyle(.secondary),
                            at: CGPoint(x: rect.midX, y: height - 15))
                    }
                }
                for midi in range where black(midi) {
                    let previous = whites.filter { $0 < midi }.count
                    let rect = CGRect(
                        x: Double(previous) * keyWidth - blackWidth / 2, y: 0, width: blackWidth, height: height * 0.62)
                    context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(.ink))
                    let selected = exactNotes?.contains(midi) ?? (labelMap[mod(midi)] != nil)
                    if selected {
                        let center = CGPoint(x: rect.midX, y: rect.maxY - 22)
                        let diameter = keyHeight < 156 ? min(20, max(4, blackWidth - 1)) : 20
                        context.fill(
                            Path(
                                ellipseIn: CGRect(
                                    x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter,
                                    height: diameter)), with: .color(colorRoots && mod(midi) == root.pc ? .clay : .moss)
                        )
                        if diameter >= 18 {
                            context.draw(
                                Text(labelMap[mod(midi)] ?? Pitch.chromatic(midi)).font(
                                    .system(size: 8, weight: .semibold)
                                ).foregroundStyle(.white), at: center)
                        }
                    } else if let label = comparisonMap[mod(midi)] {
                        let center = CGPoint(x: rect.midX, y: rect.maxY - 22)
                        context.stroke(
                            Path(ellipseIn: CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20)),
                            with: .color(.white), lineWidth: 1.2)
                        context.draw(
                            Text(label).font(.system(size: 8, weight: .semibold)).foregroundStyle(.white), at: center)
                    }
                }
            }
            .gesture(
                SpatialTapGesture().onEnded { value in
                    if value.location.y < height * 0.62 {
                        for midi in range where black(midi) {
                            let x = Double(whites.filter { $0 < midi }.count) * keyWidth
                            if abs(value.location.x - x) < blackWidth / 2 {
                                play(midi)
                                return
                            }
                        }
                    }
                    play(whites[min(whites.count - 1, max(0, Int(value.location.x / keyWidth)))])
                })
        }.frame(height: keyHeight)
            .accessibilityLabel(
                "Piano keyboard. Highlighted notes: \(notes.map(\.name).joined(separator:", ")). Click a key to hear it."
            )
            .accessibilityChildren {
                ForEach(range, id: \.self) { midi in Button("Play \(Pitch.chromatic(midi))\(midi/12-1)") { play(midi) }
                }
            }
    }
}

struct TuningPicker: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        HStack {
            Text("Tuning")
            ChoiceMenu(
                title: "Guitar tuning", selection: $state.tuning,
                options: Tuning.presets.contains(state.tuning) ? Tuning.presets : Tuning.presets + [state.tuning],
                label: { $0.name })
        }
    }
}

struct TuningEditor: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @State private var pitches = Tuning.presets[0].pitches
    @State private var name = "Custom tuning"
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Tune your instrument").font(.system(size: 25, weight: .medium, design: .serif))
            Text("Set sounding pitches from the lowest string to the highest. Capo is applied separately.")
                .foregroundStyle(.secondary)
            ForEach(0..<6, id: \.self) { index in
                HStack {
                    Text("String \(6-index)").frame(width: 75, alignment: .leading)
                    Picker("Pitch", selection: $pitches[index]) {
                        ForEach(24...88, id: \.self) { midi in Text("\(Pitch.chromatic(midi))\(midi/12-1)").tag(midi) }
                    }.labelsHidden().frame(width: 150)
                    Button("Hear", systemImage: "play.circle") { state.audio.note(pitches[index]) }
                }
            }
            TextField("Tuning name", text: $name)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use tuning") {
                    state.tuning = Tuning(
                        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Custom tuning" : name, pitches)
                    dismiss()
                }.buttonStyle(.cadencePrimary).keyboardShortcut(.defaultAction)
            }
        }.padding(30).frame(width: 460).background(Color.canvas).tint(.moss)
            .onAppear {
                pitches = state.tuning.pitches
                name = state.tuning.name
            }
    }
}

struct CircleOfFifths: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let middle = size / 2
            ZStack {
                Circle().stroke(Color.line, lineWidth: 1).padding(36)
                Circle().stroke(Color.line, lineWidth: 1).padding(76)
                VStack(spacing: 5) {
                    Text(state.root.name).font(.system(size: 38, weight: .medium, design: .serif))
                    Text(state.scale.rawValue.replacingOccurrences(of: " / ", with: "\n")).font(
                        .system(size: 10, weight: .medium)
                    ).multilineTextAlignment(.center).foregroundStyle(.secondary)
                }.position(x: middle, y: middle)
                ForEach(Array(Pitch.fifths.enumerated()), id: \.offset) { index, pitch in
                    let angle = Double(index) * Double.pi / 6 - Double.pi / 2
                    let selected = mod(state.scale.signature(state.root), 12) == mod(pitch.majorFifths, 12)
                    Button {
                        state.root = pitch
                        state.scale = .major
                    } label: {
                        VStack(spacing: 3) {
                            Text(pitch.name).font(.system(size: 17, weight: .semibold, design: .serif))
                            Text(signatureShort(pitch.majorFifths)).font(.system(size: 9))
                        }.frame(width: 42, height: 40).foregroundStyle(selected ? .white : Color.ink).background(
                            selected ? Color.moss : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).position(
                        x: middle + cos(angle) * (middle - 24), y: middle + sin(angle) * (middle - 24))
                    let relative = pitch.transposed(semitones: 9, steps: 5)
                    Button {
                        state.root = relative
                        state.scale = .minor
                    } label: {
                        Text(relative.name + "m").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .frame(width: 35, height: 25)
                    }.buttonStyle(.plain).position(
                        x: middle + cos(angle) * (middle - 76), y: middle + sin(angle) * (middle - 76))
                }
            }.frame(width: size, height: size)
        }.aspectRatio(1, contentMode: .fit)
    }
}

func signatureShort(_ fifths: Int) -> String {
    fifths == 0 ? "no ♯ / ♭" : "\(abs(fifths)) \(fifths > 0 ? "♯" : "♭")"
}

func signatureNotes(_ fifths: Int) -> String {
    if fifths == 0 { return "No sharps or flats" }
    if abs(fifths) > 7 { return "Theoretical key · choose an enharmonic root for a simpler signature" }
    let order = fifths > 0 ? ["F♯", "C♯", "G♯", "D♯", "A♯", "E♯", "B♯"] : ["B♭", "E♭", "A♭", "D♭", "G♭", "C♭", "F♭"]
    return order.prefix(abs(fifths)).joined(separator: "  ")
}

struct ChordDiagram: View {
    var voicing: Voicing
    var root: Pitch
    var tuning: Tuning
    var capo: Int
    var body: some View {
        Canvas { context, size in
            let positive = voicing.frets.filter { $0 > 0 }
            let base = (positive.max() ?? 0) > 4 ? (positive.min() ?? 1) : 1
            let left = 22.0
            let right = size.width - 18
            let top = 30.0
            let bottom = size.height - 26
            let rows = max(4, (positive.max() ?? base) - base + 1)
            let dx = (right - left) / 5
            let dy = (bottom - top) / Double(rows)
            for string in 0..<6 {
                let x = left + Double(string) * dx
                var p = Path()
                p.move(to: CGPoint(x: x, y: top))
                p.addLine(to: CGPoint(x: x, y: bottom))
                context.stroke(p, with: .color(Color.ink.opacity(0.3)), lineWidth: 1)
                let fret = voicing.frets[string]
                if fret <= 0 {
                    context.draw(
                        Text(fret < 0 ? "×" : "○").font(.system(size: 13)).foregroundStyle(.secondary),
                        at: CGPoint(x: x, y: top - 14))
                } else {
                    let y = top + (Double(fret - base) + 0.5) * dy
                    let isRoot = mod(tuning.pitches[string] + capo + fret) == root.pc
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - 7, y: y - 7, width: 14, height: 14)),
                        with: .color(isRoot ? .clay : .moss))
                }
            }
            for row in 0...rows {
                let y = top + Double(row) * dy
                var p = Path()
                p.move(to: CGPoint(x: left, y: y))
                p.addLine(to: CGPoint(x: right, y: y))
                context.stroke(p, with: .color(Color.ink.opacity(0.35)), lineWidth: row == 0 && base == 1 ? 3 : 1)
            }
            if base > 1 {
                context.draw(
                    Text("\(base)").font(.system(size: 10)).foregroundStyle(.secondary),
                    at: CGPoint(x: 8, y: top + dy / 2))
            }
            context.draw(
                Text(voicing.label).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary),
                at: CGPoint(x: size.width / 2, y: size.height - 7))
        }.frame(height: 155)
            .accessibilityLabel("Guitar fingering, low string to high string: \(voicing.label)")
    }
}
