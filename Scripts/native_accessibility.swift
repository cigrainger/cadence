// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import ApplicationServices
import Foundation

// Inspect only the child process launched here. No global input events, privacy
// preference changes, other applications, credentials or personal files.
@MainActor func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
    return result
}
@MainActor func descendants(_ root: AXUIElement) -> [AXUIElement] {
    var result: [AXUIElement] = []
    var queue = [root]
    var index = 0
    while index < queue.count && index < 2500 {
        let element = queue[index]
        index += 1
        result.append(element)
        if let children = value(element, kAXChildrenAttribute) as? [AXUIElement] { queue += children }
    }
    return result
}
@MainActor func text(_ element: AXUIElement) -> String {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { value(element, $0) as? String }.joined(
        separator: " ")
}
@MainActor func find(_ root: AXUIElement, identifier: String? = nil, containing: String? = nil) -> AXUIElement? {
    descendants(root).first { element in
        if let identifier { return value(element, kAXIdentifierAttribute) as? String == identifier }
        if let containing { return text(element).contains(containing) }
        return false
    }
}
@MainActor func wait(_ condition: @MainActor () -> Bool, seconds: Double = 2) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    repeat {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.04)
    } while Date() < end
    return false
}
@MainActor func press(_ root: AXUIElement, _ identifier: String) -> Bool {
    wait {
        descendants(root).filter { value($0, kAXIdentifierAttribute) as? String == identifier }.contains {
            AXUIElementPerformAction($0, kAXPressAction as CFString) == .success
        }
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { fatalError("Usage: native_accessibility.swift CADENCE_EXECUTABLE SNAPSHOT.png") }
guard AXIsProcessTrusted() else {
    fputs(
        "Native accessibility verification requires a trusted developer terminal. No system permission was changed.\n",
        stderr)
    exit(1)
}
let executable = URL(fileURLWithPath: arguments[1]).standardizedFileURL
let snapshot = URL(fileURLWithPath: arguments[2]).standardizedFileURL
guard executable.lastPathComponent == "Cadence", FileManager.default.isExecutableFile(atPath: executable.path) else {
    fatalError("Choose the freshly built Cadence executable.")
}
let process = Process()
process.executableURL = executable
process.arguments = ["--song-preview", "YES", "--song-ax", "YES", "--snapshot", snapshot.path, "--width", "1350", "--height", "1050"]
try process.run()
// An accessory preview can render while its AX tree is not registered. Activate
// only our own child; never send input to the user's running Cadence or other apps.
_ = wait({ NSRunningApplication(processIdentifier: process.processIdentifier)?.activate(options: []) == true }, seconds: 2)
let application = AXUIElementCreateApplication(process.processIdentifier)
AXUIElementSetMessagingTimeout(application, 1)
var checks: [String: Bool] = [:]
let ready = wait({ find(application, identifier: "journey.full-score") != nil }, seconds: 4)
if !ready {
    fputs("Cannot connect to Cadence's accessibility controls. Use an unlocked macOS session and a trusted developer terminal.\n", stderr)
}
checks["accessibleFullScore"] = ready
checks["accessibleMilestones"] = ["hear", "changes", "groove", "arrange", "independent"].allSatisfy {
    find(application, identifier: "journey.lesson." + $0) != nil
}
let wrong = ready && press(application, "journey.theory.4")
checks["theoryMissOffersRetry"] = wrong && wait {
    find(application, containing: "Compare the two sets of chord tones, then try again.") != nil
}
let corrected = wrong && press(application, "journey.theory.0")
checks["theoryRetryKeepsSupportVisible"] = corrected && wait {
    find(application, containing: "C can stay.") != nil && find(application, containing: "With support") != nil
}
let chapter = ready && press(application, "journey.lesson.arrange")
let arrangement = chapter && wait { find(application, containing: "Open my eight bars") != nil }
let opened = arrangement && press(application, "journey.open-activity")
checks["opensEightBarArrangement"] =
    opened && wait { find(application, containing: "Save finished arrangement") != nil }
let finishButtons = descendants(application).filter {
    value($0, kAXRoleAttribute) as? String == kAXButtonRole && text($0).contains("Save finished arrangement")
}
checks["unfinishedArrangementCannotFinish"] = !finishButtons.isEmpty && finishButtons.allSatisfy {
    value($0, kAXEnabledAttribute) as? Bool == false
}
let returned = press(application, "journey.return")
checks["returnsToMap"] = returned && wait { find(application, identifier: "journey.full-score") != nil }
let fullScore = press(application, "journey.full-score")
checks["opensFullPiece"] =
    fullScore
    && wait {
        find(application, containing: "A small beginning") != nil && find(application, containing: "8 bars") != nil
            && find(application, identifier: "journey.return") != nil
    }
let studio = fullScore && find(application, identifier: "workspace.content.editor") != nil
let openedCoach = studio && press(application, "workspace.coach")
checks["coachAlongsideFullScore"] = openedCoach && wait {
    find(application, identifier: "coach.question") != nil
        && find(application, identifier: "workspace.content.editor") != nil
}
let question = "How can I shape this phrase?"
let entered = wait {
    guard let field = find(application, identifier: "coach.question") else { return false }
    return AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, question as CFString) == .success
}
_ = press(application, "coach.close")
_ = press(application, "workspace.coach")
checks["coachDraftSurvivesClosure"] = entered && wait {
    find(application, identifier: "coach.question").flatMap { value($0, kAXValueAttribute) as? String } == question
}
_ = press(application, "coach.close")
let library = press(application, "workspace.library") && wait {
    find(application, identifier: "workspace.content.library") != nil
}
let explore = press(application, "workspace.explore") && wait {
    find(application, identifier: "workspace.content.explore") != nil
}
let resumed = press(application, "workspace.studio") && wait {
    find(application, identifier: "workspace.content.editor") != nil
        && find(application, containing: "A small beginning") != nil
}
checks["sectionsKeepFullScore"] = library && explore && resumed
let coachResumed = press(application, "workspace.coach")
checks["coachDraftSurvivesNavigation"] = coachResumed && wait {
    find(application, identifier: "coach.question").flatMap { value($0, kAXValueAttribute) as? String } == question
}
_ = press(application, "coach.close")
let learn = press(application, "workspace.learn") && wait {
    find(application, identifier: "journey.full-score") != nil
}
checks["learnReturnsToPathway"] = learn
_ = press(application, "journey.return")
if !wait({ !process.isRunning }, seconds: 36) { process.terminate() }
process.waitUntilExit()
let sidecar = snapshot.deletingPathExtension().appendingPathExtension("json")
var report =
    (try? Data(contentsOf: sidecar)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
var result = report["songJourneyChecks"] as? [String: Bool] ?? [:]
result.merge(checks) { _, new in new }
report["songJourneyChecks"] = result
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
    to: sidecar, options: .atomic)
print("Native accessibility journey:", checks)
guard process.terminationStatus == 0, checks.values.allSatisfy({ $0 }) else { exit(1) }
