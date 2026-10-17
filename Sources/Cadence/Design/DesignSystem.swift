// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

extension Color {
    static let ink = Color(red: 0.13, green: 0.18, blue: 0.20)
    static let canvas = Color(red: 0.97, green: 0.96, blue: 0.93)
    static let moss = Color(red: 0.22, green: 0.40, blue: 0.33)
    static let clay = Color(red: 0.76, green: 0.39, blue: 0.27)
    static let line = Color(red: 0.87, green: 0.88, blue: 0.84)
}

struct Card<Content: View>: View {
    var title: String
    var subtitle: String?
    var padding: CGFloat = 20
    var spacing: CGFloat = 18
    var tint: Color = .paper
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if !title.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    if let subtitle {
                        Spacer()
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            content
        }
        .padding(padding).frame(maxWidth: .infinity, alignment: .leading)
        .background(tint, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line.opacity(0.7), lineWidth: 1))
    }
}

struct Pill: View {
    var text: String
    var active = false
    var body: some View {
        Text(text).font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(active ? Color.white : Color.ink).background(
                active ? Color.moss : Color.line.opacity(0.4), in: Capsule())
    }
}

struct ChoiceMenu<Value: Hashable>: View {
    var title: String
    @Binding var selection: Value
    var options: [Value]
    var label: (Value) -> String
    var body: some View {
        Menu {
            ForEach(options, id: \.self) { value in
                Button {
                    selection = value
                } label: {
                    HStack {
                        Text(label(value))
                        if selection == value { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            Text(label(selection)).lineLimit(1)
        }
        .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.cadenceMenu)
        .accessibilityLabel(title).accessibilityValue(label(selection)).help("\(title): \(label(selection))")
    }
}

// Shared learning surfaces: a restrained frame, clear editorial hierarchy, and
// diagrams derived from the notes the learner is actually using.
extension Color {
    static let paper = Color(red: 0.995, green: 0.991, blue: 0.977)
    static let sidebar = Color(red: 0.93, green: 0.935, blue: 0.90)
    static let ochre = Color(red: 0.66, green: 0.48, blue: 0.20)
}

struct Eyebrow: View {
    var text: String
    var body: some View { Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.5) }
}

struct LearningSectionHeading: View {
    var title: String
    var detail: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 22, weight: .medium, design: .serif))
            Spacer()
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct CadenceMark: View {
    private static let image = NSImage(contentsOf: AppResources.url("Brand/mark.png"))
    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "music.note")
            }
        }.frame(width: 36, height: 36).accessibilityHidden(true)
    }
}

struct VoiceLeadingDiagram: View {
    let from: [Int]
    let to: [Int]
    var onDark = false
    private var pairs: [(Int, Int)] { Array(zip(from.sorted(), to.sorted())) }
    private func name(_ note: Int) -> String { Solfege.noteName(midi: note, pitch: Pitch.spelled(note)) }
    private var description: String {
        pairs.map {
            "\(name($0.0)) to \(name($0.1)), \($0.1 == $0.0 ? "stays in place" : "\(abs($0.1-$0.0)) semitones \($0.1 > $0.0 ? "up" : "down")")"
        }.joined(separator: ". ")
    }
    var body: some View {
        GeometryReader { geometry in
            let low = Double((from + to).min() ?? 60) - 2
            let high = Double((from + to).max() ?? 72) + 2
            let y: (Int) -> CGFloat = {
                CGFloat(1 - (Double($0) - low) / max(1, high - low)) * (geometry.size.height - 14) + 7
            }
            ZStack {
                ForEach(Array(pairs.enumerated()), id: \.offset) { index, pair in
                    let color: Color =
                        onDark
                        ? [
                            Color.white, Color(red: 0.79, green: 0.85, blue: 0.62),
                            Color(red: 0.93, green: 0.70, blue: 0.52),
                        ][index % 3] : [Color.moss, Color.ochre, Color.clay][index % 3]
                    Path { path in
                        path.move(to: CGPoint(x: 43, y: y(pair.0)))
                        path.addLine(to: CGPoint(x: geometry.size.width - 43, y: y(pair.1)))
                    }.stroke(
                        color.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: pair.0 == pair.1 ? [4, 4] : []))
                    Circle().fill(color).frame(width: 7, height: 7).position(x: 43, y: y(pair.0))
                    Circle().fill(color).frame(width: 7, height: 7).position(x: geometry.size.width - 43, y: y(pair.1))
                    Text(name(pair.0)).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(
                        color
                    ).position(x: 17, y: y(pair.0))
                    Text(name(pair.1)).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(
                        color
                    ).position(x: geometry.size.width - 17, y: y(pair.1))
                }
            }
        }.frame(height: 105).accessibilityElement(children: .ignore).accessibilityLabel(
            "Voice movement. " + description)
    }
}

/// Keep native Button semantics and shortcuts; share only the visual treatment.
struct CadenceButtonStyle: ButtonStyle {
    var primary = false
    var disclosure = false
    func makeBody(configuration: Configuration) -> some View {
        CadenceButtonFace(configuration: configuration, primary: primary, disclosure: disclosure)
    }
}
private struct CadenceButtonFace: View {
    let configuration: ButtonStyleConfiguration
    let primary: Bool
    let disclosure: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size
    @State private var hovering = false
    private var vertical: CGFloat { size == .large ? 10 : size == .small || size == .mini ? 5 : 7 }
    var body: some View {
        HStack(spacing: 8) {
            configuration.label
            if disclosure {
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(
                    Color.moss)
            }
        }
        .font(.system(size: size == .large ? 14 : size == .mini ? 11 : 12, weight: .semibold))
        .padding(.horizontal, size == .large ? 16 : 11).padding(.vertical, vertical)
        .foregroundStyle(primary ? Color.white : configuration.role == .destructive ? Color.clay : Color.ink)
        .background(
            primary ? Color.moss : hovering && enabled ? Color.moss.opacity(0.08) : Color.paper,
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9).stroke(
                primary ? Color.white.opacity(0.16) : hovering && enabled ? Color.moss.opacity(0.5) : Color.line,
                lineWidth: 1)
        )
        .brightness(configuration.isPressed ? -0.05 : 0)
        .opacity(enabled ? 1 : 0.48)
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onHover { hovering = $0 }
    }
}
extension ButtonStyle where Self == CadenceButtonStyle {
    static var cadence: Self { Self() }
    static var cadencePrimary: Self { Self(primary: true) }
    static var cadenceMenu: Self { Self(disclosure: true) }
}
