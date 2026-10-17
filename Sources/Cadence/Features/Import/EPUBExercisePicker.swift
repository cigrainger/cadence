// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct EPUBExercisePicker: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let course: CourseDefinition
    let lesson: CourseLesson
    let asset: BookAsset
    let model: PDFImportModel
    @State private var selected = Set<String>()
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Choose the music to make playable").font(.system(size: 25, weight: .medium, design: .serif))
                Spacer()
                Button("Cancel") { dismiss() }
            }
            Text(
                "Select up to four illustrations from this lesson. The original EPUB stays linked; selected images enter the existing notation review queue."
            ).font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ForEach(asset.images(in: lesson.source), id: \.path) { image in
                        VStack(alignment: .leading, spacing: 8) {
                            if let ns = NSImage(data: image.data) {
                                Image(nsImage: ns).resizable().scaledToFit().frame(height: 180).frame(
                                    maxWidth: .infinity
                                ).background(.white)
                            }
                            Toggle(
                                image.path.components(separatedBy: "/").last ?? "Illustration",
                                isOn: Binding(
                                    get: { selected.contains(image.path) },
                                    set: { if $0 { selected.insert(image.path) } else { selected.remove(image.path) } })
                            ).toggleStyle(.checkbox)
                        }.padding(12).background(Color.canvas, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                if asset.images(in: lesson.source).isEmpty {
                    ContentUnavailableView(
                        "No supported illustrations here", systemImage: "photo",
                        description: Text("Choose another section, or attach a score you create in Compose."))
                }
            }.frame(height: 420)
            if let error { Text(error).foregroundStyle(Color.clay).font(.caption) }
            HStack {
                Text("No model request starts until you choose it in the import queue.").font(.caption).foregroundStyle(
                    .secondary)
                Spacer()
                Button("Prepare selected illustrations") {
                    do {
                        let ordered = asset.images(in: lesson.source).map(\.path).filter { selected.contains($0) }
                        try state.prepareEPUBExercise(
                            courseID: course.id, lessonID: lesson.id, asset: asset, selected: ordered, model: model)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.cadencePrimary).disabled(selected.isEmpty || selected.count > 4)
            }
        }.padding(24).frame(width: 730)
    }
}
