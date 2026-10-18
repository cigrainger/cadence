// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

@MainActor enum SnapshotDiagnostics {
    private static var timingOrigin: TimeInterval?
    private static var phases: [String: TimeInterval] = [:]

    static func mark(_ phase: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if timingOrigin == nil { timingOrigin = now }
        phases[phase] = now - (timingOrigin ?? now)
    }

    /// Preserve each preview group's renderer ownership and the existing
    /// overlay order. Readiness and the saved sidecar use this single report.
    static var report: [String: Any] {
        let score = ScoreRendererDiagnostics.latest
        let editor = EditorDiagnostics.latest
        var report = score
        if !editor.isEmpty {
            report = editor
            report["nativeEditing"] = EditorDiagnostics.native
        }
        func replace(_ name: String, _ checks: [String: Bool], _ renderer: [String: Any]) {
            guard !checks.isEmpty else { return }
            report = renderer
            report[name] = checks
        }
        replace("midiChecks", MIDIDiagnostics.checks, editor)
        replace("changesChecks", ChangesDiagnostics.checks, [:])
        replace("practiceChecks", PassageDiagnostics.checks, score)
        replace("pdfChecks", PDFImportDiagnostics.checks, editor)
        replace("libraryChecks", LibraryDiagnostics.checks, editor)
        replace("piecePathwayChecks", PiecePathwayDiagnostics.checks, score)
        replace("guidedChecks", GuidedDiagnostics.checks, score)
        replace("timedChecks", TimedDiagnostics.checks, score)
        replace("timedChangesChecks", TimedChangesDiagnostics.checks, [:])
        replace("courseChecks", CourseDiagnostics.checks, editor)
        replace("smoothChecks", SmoothPathwayDiagnostics.checks, editor)
        replace("adaptiveChecks", AdaptiveSessionDiagnostics.checks, editor)
        replace("homeChecks", PracticeHomeDiagnostics.checks, [:])
        replace("scoreEarChecks", ScoreEarDiagnostics.checks, score.isEmpty ? editor : score)
        replace("earChecks", EarPathwayDiagnostics.checks, [:])
        replace("grooveChecks", GrooveDiagnostics.checks, [:])
        replace("playAlongChecks", PlayAlongDiagnostics.checks, score)
        replace("rehearsalChecks", RehearsalDiagnostics.checks, score)
        replace("reharmChecks", ReharmDiagnostics.checks, score)
        replace("tensionChecks", TensionDiagnostics.checks, score)
        replace("microphonePhraseChecks", MicrophonePhraseDiagnostics.checks, score)
        replace("earDailyChecks", EarDailyDiagnostics.checks, score.isEmpty ? editor : score)
        replace("pickingChecks", PickingDiagnostics.checks, editor)
        replace("triadChecks", TriadDiagnostics.checks, editor)
        replace("flowChecks", FlowPracticeDiagnostics.checks, score)
        replace("handsChecks", HandsTogetherDiagnostics.checks, score)
        replace("shapeChecks", ShapePhraseDiagnostics.checks, score)
        if !SongJourneyDiagnostics.checks.isEmpty { report["songJourneyChecks"] = SongJourneyDiagnostics.checks }
        // Relative to the first snapshot callback, not a claim about process
        // startup. The external command timer also includes launch and exit.
        if let timingOrigin {
            report["snapshotTiming"] = [
                "elapsedSeconds": ProcessInfo.processInfo.systemUptime - timingOrigin, "phases": phases,
            ]
        }
        return report
    }

    static func write(to destination: URL) throws {
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination, options: .atomic)
    }
}
