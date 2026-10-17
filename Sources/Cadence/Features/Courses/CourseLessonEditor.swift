// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct CourseLessonEditor: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let course: CourseDefinition
    @State var draft: CourseLesson
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Shape this lesson").font(.system(size: 26, weight: .medium, design: .serif))
                Spacer()
                Button("Cancel") { dismiss() }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("Title", text: $draft.title)
                    HStack {
                        Picker("Kind", selection: $draft.kind) {
                            ForEach(CourseLessonKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        Picker("Instrument", selection: $draft.instrument) {
                            ForEach(EditorInstrument.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                    }
                    HStack {
                        Stepper(
                            "First \(draft.source.epubHrefs == nil ? "page" : "section") \(draft.source.fromPage)",
                            value: $draft.source.fromPage,
                            in: course.chapter.source.fromPage...course.chapter.source.throughPage)
                        Stepper(
                            "Last \(draft.source.throughPage)", value: $draft.source.throughPage,
                            in: draft.source.fromPage...course.chapter.source.throughPage)
                    }
                    field("Printed label (optional)", text: $draft.source.printedLabel)
                    field("From the book · brief paraphrase", text: $draft.bookSummary)
                    field("Learning goal · your guidance", text: $draft.goal)
                    field("Practice suggestion", text: $draft.practice)
                    field("What to notice / ready to move on", text: $draft.readyWhen)
                    if draft.kind == .music {
                        field("Exact printed exercise or system to import", text: $draft.passage)
                        Text(
                            "One musical exercise, up to four consecutive pages or EPUB reading sections. Distinct exercises should be separate lessons."
                        ).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Skills").fontWeight(.medium)
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                        alignment: .leading
                    ) {
                        ForEach(CourseSkill.allCases, id: \.self) { skill in
                            Toggle(
                                skill.rawValue,
                                isOn: Binding(
                                    get: { draft.skills.contains(skill) },
                                    set: { value in
                                        if value {
                                            draft.skills.append(skill)
                                        } else {
                                            draft.skills.removeAll { $0 == skill }
                                        }
                                    })
                            ).toggleStyle(.checkbox)
                        }
                    }
                    if course.chapter.lessons.count > 1 {
                        Text("Useful earlier lessons · suggestions, not locks").fontWeight(.medium)
                        ForEach(course.chapter.lessons.filter { $0.id != draft.id }) { lesson in
                            Toggle(
                                lesson.title,
                                isOn: Binding(
                                    get: { draft.prerequisites.contains(lesson.id) },
                                    set: { value in
                                        if value {
                                            draft.prerequisites.append(lesson.id)
                                        } else {
                                            draft.prerequisites.removeAll { $0 == lesson.id }
                                        }
                                    })
                            ).toggleStyle(.checkbox)
                        }
                    }
                    field(
                        "Things to check · one per line",
                        text: Binding(
                            get: { draft.uncertainties.joined(separator: "\n") },
                            set: { draft.uncertainties = $0.split(separator: "\n").map(String.init) }))
                }.padding(.trailing, 8)
            }.frame(height: 590)
            if let error { Text(error).font(.caption).foregroundStyle(Color.clay) }
            HStack {
                if course.chapter.lessons.contains(where: { $0.id == draft.id }) {
                    Button("Remove lesson", role: .destructive) {
                        perform { try state.removeCourseLesson(courseID: course.id, lessonID: draft.id) }
                    }.disabled(course.chapter.lessons.count == 1)
                }
                Spacer()
                Text("Changes keep the previous outline and require review.").font(.caption).foregroundStyle(.secondary)
                Button("Save lesson") { perform { try state.saveCourseLesson(courseID: course.id, lesson: draft) } }
                    .buttonStyle(.cadencePrimary)
            }
        }.padding(24).frame(width: 690).onChange(of: draft.source.fromPage) { _, value in
            draft.source.throughPage = max(value, draft.source.throughPage)
        }
    }
    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: text, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...5)
        }
    }
    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct CourseHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let course: CourseDefinition
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Earlier outlines").font(.system(size: 26, weight: .medium, design: .serif))
                Spacer()
                Button("Done") { dismiss() }
            }
            Text(
                "The latest 20 earlier outlines are kept. Text is selectable so you can carry an earlier idea into a new lesson."
            ).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(course.history.reversed(), id: \.revision) { chapter in
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Revision \(chapter.revision) · " + chapter.title).fontWeight(.semibold)
                            Text(chapter.origin + " · " + chapter.source.label).font(.caption).foregroundStyle(
                                .secondary)
                            Text(chapter.summary)
                            ForEach(chapter.lessons) { lesson in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(lesson.title).fontWeight(.medium)
                                    Text(lesson.source.label)
                                    Text(lesson.bookSummary)
                                    Text("Goal: " + lesson.goal)
                                    Text("Try: " + lesson.practice)
                                    Text("Notice: " + lesson.readyWhen)
                                    if !lesson.passage.isEmpty { Text("Exercise: " + lesson.passage) }
                                }.font(.callout)
                            }
                            Divider()
                        }.textSelection(.enabled)
                    }
                }
            }.frame(height: 550)
        }.padding(24).frame(width: 650)
    }
}
