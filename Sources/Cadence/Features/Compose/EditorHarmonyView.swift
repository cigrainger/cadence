// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct EditorHarmonyView: View {
    @Environment(\.dismiss) private var dismiss
    let document: EditorDocument
    let save: (EditorHarmony) throws -> Void
    let remove: (UUID) throws -> Void
    @State private var identity: UUID
    @State private var bar: Int
    @State private var beat: String
    @State private var staff: Int
    @State private var text: String
    @State private var error: String?
    @FocusState private var textFocused: Bool
    init(
        document: EditorDocument, selected: EditorEvent?, harmony: EditorHarmony?,
        save: @escaping (EditorHarmony) throws -> Void, remove: @escaping (UUID) throws -> Void
    ) {
        self.document = document
        self.save = save
        self.remove = remove
        _identity = State(initialValue: harmony?.id ?? UUID())
        _bar = State(initialValue: (harmony?.bar ?? selected?.bar ?? 0) + 1)
        _beat = State(
            initialValue: String(
                format: "%.6g",
                Double(harmony?.tick ?? selected.map { document.onset($0) } ?? 0) * Double(document.meter.unit) / 1920
                    + 1))
        _staff = State(initialValue: harmony?.staff ?? 1)
        _text = State(initialValue: harmony?.symbol.label ?? "")
    }
    private var symbol: ChordSymbol? { try? resolvedSymbol() }
    private var existing: Bool { document.harmonies.contains { $0.id == identity } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Chord symbols").font(.system(size: 28, weight: .semibold, design: .serif))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Write the changes above your music.").foregroundStyle(.secondary)
            HStack(spacing: 18) {
                Stepper("Bar \(bar)", value: $bar, in: 1...document.barCount).fixedSize()
                Text("Beat")
                TextField("Beat", text: $beat).frame(width: 100)
                Text("of \(document.meter.beats)").foregroundStyle(.secondary)
                if document.instrument == .piano {
                    Picker("Staff", selection: $staff) {
                        Text("Upper").tag(1)
                        Text("Lower").tag(2)
                    }.frame(width: 150)
                }
            }
            TextField("Cmaj7, Dm7, G7(b9), C/E…", text: $text)
                .font(.system(size: 24, design: .serif)).textFieldStyle(.plain).focused($textFocused)
                .padding(10).frame(minHeight: 48).background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                .onSubmit { commit() }
            if let symbol { Text(symbol.label).font(.title2).foregroundStyle(Color.moss) }
            Text(
                "Major, minor, 6/7/9/11/13, diminished, suspended, added or altered degrees, slash basses and N.C. Beat 1 is the bar start; 1.5 is halfway to beat 2."
            )
            .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.callout).foregroundStyle(Color.clay).textSelection(.enabled) }
            HStack {
                Button(existing ? "Save changes" : "Add symbol") { commit() }.buttonStyle(.cadencePrimary).disabled(
                    text.isEmpty)
                if existing {
                    Button("Remove symbol", role: .destructive) {
                        do {
                            try remove(identity)
                            reset()
                        } catch { self.error = error.localizedDescription }
                    }
                    Button("New symbol") { reset() }
                }
                Spacer()
            }
            Divider()
            Text("In bar \(bar)").font(.headline)
            if document.harmonies(in: bar - 1).isEmpty { Text("No chord symbols yet.").foregroundStyle(.secondary) }
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(document.harmonies(in: bar - 1)) { item in
                        Button {
                            identity = item.id
                            text = item.symbol.label
                            staff = item.staff
                            beat = String(format: "%.6g", Double(item.tick) * Double(document.meter.unit) / 1920 + 1)
                            error = nil
                        } label: {
                            VStack(spacing: 4) {
                                Text(item.symbol.label).font(.system(size: 18, weight: .medium, design: .serif))
                                Text(
                                    "Beat \(String(format: "%.4g", Double(item.tick)*Double(document.meter.unit)/1920+1))"
                                        + (document.instrument == .piano
                                            ? " · \(item.staff == 1 ? "upper" : "lower")" : "")
                                ).font(.caption)
                            }.padding(5)
                        }.tint(item.id == identity ? Color.moss : Color.secondary)
                    }
                }
            }
            Text(
                "Symbols describe the harmony. Playback and MIDI practice use the written notes; adding a symbol does not generate accompaniment."
            )
            .font(.caption).foregroundStyle(.secondary)
        }.padding(26).frame(width: 620).background(Color.canvas).onAppear { textFocused = true }
    }
    private func reset() {
        identity = UUID()
        text = ""
        error = nil
        textFocused = true
    }
    private func resolvedSymbol() throws -> ChordSymbol {
        if let original = document.harmonies.first(where: { $0.id == identity }), original.symbol.label == text {
            return original.symbol
        }
        return try ChordSymbol.parse(text)
    }
    private func commit() {
        do {
            guard let value = Double(beat), value.isFinite, value >= 1, value < Double(document.meter.beats + 1) else {
                throw MusicError.invalid("Choose a beat inside this bar.")
            }
            let ticks = (value - 1) * 1920 / Double(document.meter.unit)
            guard abs(ticks.rounded() - ticks) < 0.02 else {
                throw MusicError.invalid("Use a beat on the supported rhythm grid.")
            }
            var item = EditorHarmony(
                bar: bar - 1, tick: Int(ticks.rounded()), staff: staff, symbol: try resolvedSymbol())
            item.id = identity
            try save(item)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
