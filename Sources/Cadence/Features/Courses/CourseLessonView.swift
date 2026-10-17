// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

struct CourseLessonView: View {
    @EnvironmentObject private var state: AppState
    let course: CourseDefinition
    let lesson: CourseLesson
    let asset: BookAsset?
    let model: PDFImportModel
    let edit: () -> Void
    var showTitle = true
    @State private var error: String?
    @State private var selectImages = false
    @State private var from = 1
    @State private var through = 4
    @State private var staff = 1
    @State private var checked = false
    @State private var introduced = false
    @State private var note = ""
    @State private var saved = false
    @State private var guidance = false
    private var score: EditorDocument? {
        course.link(lesson).flatMap { link in state.editor.documents.first { $0.id == link.scoreID } }
    }
    private var ready: Bool { (try? state.readyCourseScore(course, lesson)) != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showTitle {
                HStack {
                    Text(lesson.title).font(.system(size: 21, weight: .medium, design: .serif))
                    Spacer()
                    Button("Edit", action: edit)
                }
            } else {
                HStack {
                    Text("YOUR LEARNING").font(.caption).foregroundStyle(Color.moss)
                    Spacer()
                    Button("Edit lesson", action: edit).controlSize(.small)
                }
            }
            if showTitle { section("Learning goal · your guidance", lesson.goal) }
            if ready {
                exercise
                DisclosureGroup("Book and practice guidance", isExpanded: $guidance) { lessonGuidance.padding(.top, 8) }
            } else {
                lessonGuidance
                if lesson.kind == .music {
                    exercise
                } else if course.chapter.reviewed {
                    Button("Open metronome", systemImage: "metronome") {
                        state.courseReturn = .init(courseID: course.id, lessonID: lesson.id)
                        state.destination = .tools
                    }
                }
            }
            if course.chapter.reviewed {
                reflection
                evidence
            }
            if let error { Text(error).font(.caption).foregroundStyle(Color.clay).textSelection(.enabled) }
        }.sheet(isPresented: $selectImages) {
            if let asset { EPUBExercisePicker(course: course, lesson: lesson, asset: asset, model: model) }
        }.onAppear {
            if let score { through = min(4, score.barCount) }
            if let approval = course.link(lesson)?.approval {
                from = approval.from + 1
                through = approval.through + 1
                staff = approval.staff ?? 0
            }
            if let reflection = state.courses.reflections[lesson.learningIdentity] {
                introduced = reflection.introduced
                note = reflection.note
            }
        }
        .onChange(of: from) { _, value in
            through = max(value, min(through, value + 15))
            checked = false
        }
        .onChange(of: through) { _, _ in checked = false }
        .onChange(of: staff) { _, _ in checked = false }
        .onChange(of: note) { _, _ in saved = false }
        .onChange(of: introduced) { _, _ in saved = false }
    }
    private var lessonGuidance: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !lesson.bookSummary.isEmpty { section("From the book · paraphrase", lesson.bookSummary) }
            section("Try this", lesson.practice)
            section("What to notice", lesson.readyWhen)
            Text(lesson.skills.map(\.rawValue).joined(separator: " · ")).font(.caption).foregroundStyle(Color.moss)
            if !lesson.prerequisites.isEmpty {
                Text(
                    "Useful first: "
                        + course.chapter.lessons.filter { lesson.prerequisites.contains($0.id) }.map(\.title).joined(
                            separator: ", ") + ". Every lesson stays open."
                ).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(lesson.uncertainties, id: \.self) { Text($0).font(.caption).foregroundStyle(Color.clay) }
        }
    }
    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(body).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var exercise: some View {
        Card(title: ready ? "Ready to play" : "Make this exercise playable", padding: 14, spacing: 11) {
            Text(lesson.passage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !course.chapter.reviewed {
                Text("Review the chapter outline first, then prepare or attach notation for this exercise.").font(
                    .callout)
            } else {
                if let score {
                    Text(score.title + " · \(score.barCount) bars · " + score.instrument.rawValue).fontWeight(.medium)
                    HStack {
                        Button("Review notation & source", systemImage: "music.note.list") { openScore(score) }
                        if score.pdfSource?.pages != nil {
                            Button("Pages & retries") {
                                state.courseReturn = .init(courseID: course.id, lessonID: lesson.id)
                                state.pdfImportScoreID = score.id
                                state.showPDFImport = true
                            }
                        }
                    }.controlSize(.small)
                    if !ready {
                        approval(score)
                    } else {
                        if let approval = course.link(lesson)?.approval {
                            Text(
                                "Reviewed bars \(approval.from+1)–\(approval.through+1) · "
                                    + (approval.staff.map { "staff \($0)" } ?? "both staves")
                            ).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Listen", systemImage: "play.fill") { practise(.listen) }
                            Button("Follow the notes") { practise(.guided) }.buttonStyle(.cadencePrimary)
                            Button("Play in time") { practise(.timed) }
                        }.controlSize(.small)
                        HStack {
                            Button("Recall exercises") { practise(.recall) }
                            Button("Ask my coach") { askCoach(score) }
                        }.controlSize(.small)
                        Text(
                            "MIDI practice uses the reviewed selection. Timing mode supports up to eight bars; unsupported music explains what needs changing. Listening is always available."
                        ).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Button("Prepare editable notation…", systemImage: "doc.viewfinder") {
                        perform {
                            if let pdf = asset?.pdf {
                                try state.prepareCourseExercise(
                                    courseID: course.id, lessonID: lesson.id, asset: pdf, model: model)
                            } else {
                                selectImages = true
                            }
                        }
                    }.buttonStyle(.cadencePrimary).disabled(asset == nil || state.isPreview)
                    Text(
                        "Opens the page queue for this exercise. You choose when to start each import, review the result, and correct it beside the original."
                    ).font(.caption).foregroundStyle(.secondary)
                }
                Menu {
                    ForEach(state.editor.documents.filter { $0.instrument == lesson.instrument }, id: \.id) { item in
                        Button(item.title) {
                            perform {
                                try state.attachCourseScore(courseID: course.id, lessonID: lesson.id, scoreID: item.id)
                                from = 1
                                through = min(4, item.barCount)
                                checked = false
                            }
                        }
                    }
                } label: {
                    Label(
                        score == nil ? "Use an existing editable score" : "Attach a different score",
                        systemImage: "link")
                }
                .menuStyle(.borderlessButton).fixedSize().font(.caption)
            }
        }
    }
    private func approval(_ score: EditorDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Check notes, rhythms, rests and source pages in Compose, then choose the bars for this lesson.").font(
                .caption
            ).foregroundStyle(.secondary)
            HStack {
                Stepper("From \(from)", value: $from, in: 1...score.barCount)
                Stepper("Through \(through)", value: $through, in: from...max(from, min(score.barCount, from + 15)))
            }.font(.caption)
            if score.instrument == .piano {
                Picker("Practice staff", selection: $staff) {
                    Text("Right hand / staff 1").tag(1)
                    Text("Left hand / staff 2").tag(2)
                    Text("Both staves").tag(0)
                }
            }
            Toggle("I checked this selection against the source exercise", isOn: $checked).toggleStyle(.checkbox).font(
                .caption)
            Button("Use these reviewed bars") {
                perform {
                    try state.approveCourseScore(
                        courseID: course.id, lessonID: lesson.id, from: from - 1, through: through - 1,
                        staff: staff == 0 ? nil : staff)
                }
            }.disabled(!checked)
            Text(
                "Changing the music or its source requires another review. Earlier practice results remain attached to the earlier music."
            ).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var reflection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Your reflection").fontWeight(.medium)
            Toggle("I've explored this lesson", isOn: $introduced).toggleStyle(.checkbox)
            TextField("What felt easier? What would you like to revisit?", text: $note, axis: .vertical).textFieldStyle(
                .roundedBorder
            ).lineLimit(2...5)
            HStack {
                Button("Save reflection") {
                    perform {
                        try state.reflectOnLesson(
                            courseID: course.id, lessonID: lesson.id, introduced: introduced, note: note)
                        saved = true
                    }
                }
                if saved { Text("Saved").font(.caption).foregroundStyle(Color.moss) }
            }
            Text("A reflection helps choose the next lesson. It is separate from measured practice results.").font(
                .caption
            ).foregroundStyle(.secondary)
        }
    }
    private var evidence: some View {
        let evidence = state.courseEvidence(course, lesson)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Practice on these reviewed bars").fontWeight(.medium)
            if evidence.isEmpty {
                Text(
                    "No recorded practice for this selection yet. Listening and reflections do not create a performance grade."
                ).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(evidence.prefix(8))) { item in
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.mode.rawValue + " · " + item.date.formatted(date: .abbreviated, time: .shortened)).font(
                        .caption
                    ).foregroundStyle(Color.moss)
                    Text(item.summary).font(.caption).textSelection(.enabled)
                    HStack {
                        Text(item.review.reason()).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Revisit") {
                            perform {
                                try state.openCoursePractice(
                                    courseID: course.id, lessonID: lesson.id, mode: item.mode,
                                    evidenceID: item.practiceID)
                            }
                        }.controlSize(.small)
                    }
                }.padding(10).background(Color.moss.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
    private func openScore(_ score: EditorDocument) {
        state.courseReturn = .init(courseID: course.id, lessonID: lesson.id)
        state.pdfReviewPage = score.pdfSource?.page
        state.returnToCompose(score.id, from: from - 1, through: min(score.barCount - 1, through - 1))
    }
    private func practise(_ mode: CoursePracticeMode) {
        perform { try state.openCoursePractice(courseID: course.id, lessonID: lesson.id, mode: mode) }
    }
    private func askCoach(_ score: EditorDocument) {
        state.courseReturn = .init(courseID: course.id, lessonID: lesson.id)
        let evidence = state.courseEvidence(course, lesson).prefix(4).map(\.summary).joined(separator: "\n")
        state.ask(
            "Help me with this lesson: \(lesson.title).\nGoal: \(lesson.goal)\nSuggested practice: \(lesson.practice)\nWhat to notice: \(lesson.readyWhen)\nRecorded evidence (limited to the reviewed selection):\n\(evidence)\nExplain one small next step. Do not infer physical technique or general mastery from this evidence.",
            study: (try? ComposePractice.make(score, from: from - 1, through: min(score.barCount - 1, through - 1)))?
                .reference)
    }
    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct CourseReturnBar: View {
    @EnvironmentObject private var state: AppState
    let location: CourseLocation
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "book.pages").foregroundStyle(Color.moss)
            Text(
                (try? state.course(location.courseID).chapter.lessons.first { $0.id == location.lessonID }?.title)
                    ?? "Your chapter"
            ).font(.caption).lineLimit(1)
            Spacer()
            Button(state.showAdaptiveSession ? "Back to session" : "Back to lesson") { state.returnToCourse(location) }
            Button {
                state.courseReturn = nil
            } label: {
                Image(systemName: "xmark")
            }.buttonStyle(.plain).accessibilityLabel("Dismiss lesson link")
        }.controlSize(.small).padding(.horizontal, 22).padding(.vertical, 9).background(Color.moss.opacity(0.07))
    }
}
