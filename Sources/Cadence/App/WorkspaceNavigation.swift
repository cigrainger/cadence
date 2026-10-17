// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import MusicCore
import SwiftUI

private struct WorkspaceWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 1000 }
extension EnvironmentValues {
    var workspaceWidth: CGFloat {
        get { self[WorkspaceWidthKey.self] }
        set { self[WorkspaceWidthKey.self] = newValue }
    }
}

/// Sections describe the learner's intent; destinations keep existing activity
/// owners intact. Moving between sections never starts or resets an activity.
enum WorkspaceSection: String, CaseIterable, Identifiable {
    case learn = "Learn"
    case library = "Library"
    case studio = "Studio"
    case explore = "Explore"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .learn: "point.topleft.down.to.point.bottomright.curvepath"
        case .library: "books.vertical"
        case .studio: "pencil.and.outline"
        case .explore: "circle.hexagongrid"
        }
    }
    var detail: String {
        switch self {
        case .learn: "Listen. Understand. Make it yours."
        case .library: "Your music and the books behind it."
        case .studio: "Write, arrange and rehearse."
        case .explore: "Follow a musical connection."
        }
    }
    var initial: Destination {
        switch self {
        case .learn: .practice
        case .library: .library
        case .studio: .editor
        case .explore: .explore
        }
    }
    var destinations: [Destination] {
        switch self {
        case .learn: [.practice, .courses, .plans]
        case .library: [.library, .books]
        case .studio: [.editor, .studies]
        case .explore: [.explore, .chords, .tools]
        }
    }
}

extension Destination {
    var routeID: String {
        switch self {
        case .practice: "practice"
        case .courses: "courses"
        case .plans: "plans"
        case .library: "library"
        case .books: "books"
        case .editor: "editor"
        case .studies: "studies"
        case .explore: "explore"
        case .chords: "chords"
        case .tools: "tools"
        }
    }
    var section: WorkspaceSection {
        switch self {
        case .practice, .courses, .plans: .learn
        case .library, .books: .library
        case .editor, .studies: .studio
        case .explore, .chords, .tools: .explore
        }
    }
    var tabTitle: String {
        switch self {
        case .practice: "Your pathway"
        case .courses: "Courses"
        case .plans: "Personal plans"
        case .library: "Music"
        case .books: "Books & chapters"
        case .editor: "Write & arrange"
        case .studies: "Rehearse"
        case .explore: "Theory"
        case .chords: "Chords & voicings"
        case .tools: "Metronome & tuner"
        }
    }
}

extension AppState {
    var workspace: WorkspaceSection { destination.section }
    func navigateWorkspace(_ section: WorkspaceSection) {
        navigate(to: workspaceLocations[section] ?? section.initial)
    }
    func showSongHome() {
        stopAllPlayback()
        practicePage = .songJourney
        destination = .practice
    }
    func showPracticeOverview() {
        stopAllPlayback()
        practicePage = .home
        destination = .practice
    }
}

struct WorkspaceTabs: View {
    @EnvironmentObject private var state: AppState
    var body: some View {
        HStack(spacing: 6) {
            ForEach(state.workspace.destinations) { destination in
                tab(
                    destination.tabTitle,
                    selected: state.destination == destination
                        && (destination != .practice || state.practicePage == .songJourney),
                    id: destination.id
                ) {
                    if destination == .practice { state.showSongHome() } else { state.navigate(to: destination) }
                }
                if destination == .practice {
                    tab(
                        "Practice & review",
                        selected: state.destination == .practice
                            && state.practicePage != .songJourney, id: "reviews"
                    ) { state.showPracticeOverview() }
                }
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 22).padding(.vertical, 10)
    }
    private func tab(_ title: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.moss : Color.ink.opacity(0.65))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(selected ? Color.moss.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityIdentifier("workspace.tab." + id)
    }
}
