// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Darwin
import Foundation

/// LaunchServices sends the app-open event SwiftUI needs on older macOS hosts.
/// Every invocation owns one fresh fixture instance, never a running user app.
@MainActor final class NativePreview {
    private let appURL: URL
    private let arguments: [String]
    private let captureLog: URL
    private let existing: Set<pid_t>
    private let started = ProcessInfo.processInfo.systemUptime
    private var app: NSRunningApplication?
    private var timer: Timer?
    private var signals: [DispatchSourceSignal] = []
    private var stopping: (reason: String, at: Double)?

    init(executable: URL, arguments: [String], snapshot: URL) {
        appURL = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        self.arguments = arguments
        captureLog = snapshot.deletingPathExtension().appendingPathExtension("capture.log")
        existing = Set(
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.cadence.music").map(\.processIdentifier)
        )
    }
    func start() {
        try? FileManager.default.removeItem(at: captureLog)
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { Task { @MainActor in self.stop("Interrupted", sample: false) } }
            source.resume()
            signals.append(source)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in self.tick() }
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        configuration.arguments = arguments
        // The profile must belong to the app PID. Do not forward credentials or
        // other shell environment into an app launched by the system service.
        if let profile = ProcessInfo.processInfo.environment["LLVM_PROFILE_FILE"] {
            configuration.environment = ["LLVM_PROFILE_FILE": profile]
        }
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { application, error in
            Task { @MainActor in
                guard let application else {
                    self.finish(1, "LaunchServices: \(error?.localizedDescription ?? "No application returned")")
                }
                guard !self.existing.contains(application.processIdentifier),
                    application.bundleURL?.standardizedFileURL == self.appURL.standardizedFileURL
                else { self.finish(1, "Refusing an existing or different application instance") }
                self.app = application
                FileHandle.standardError.write(Data("Native preview PID: \(application.processIdentifier)\n".utf8))
            }
        }
    }
    private func tick() {
        if let app, app.isTerminated {
            let log = (try? String(contentsOf: captureLog, encoding: .utf8)) ?? ""
            // NSRunningApplication has no child wait status. Require the app's
            // explicit end marker; PNG and assertion validation remain in Python.
            finish(
                stopping == nil && log.contains("Snapshot: complete\n") ? 0 : 1,
                stopping?.reason
                    ?? (log.contains("Snapshot: complete\n") ? nil : "Preview exited before completing capture"))
        }
        if let stopping, ProcessInfo.processInfo.systemUptime - stopping.at > 3 {
            finish(1, stopping.reason + "; owned preview did not terminate")
        }
        // Leave the Python caller time to collect diagnostics and reap this
        // launcher after it has stopped its independently launched app.
        let limit = arguments.contains("--settings") ? 25.0 : 45.0
        if ProcessInfo.processInfo.systemUptime - started > limit { stop("Native preview timed out", sample: true) }
    }
    private func stop(_ message: String, sample: Bool) {
        guard stopping == nil else { return }
        stopping = (message, ProcessInfo.processInfo.systemUptime)
        if let app, !app.isTerminated {
            if sample {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                process.arguments = [
                    String(app.processIdentifier), "1", "-file",
                    captureLog.deletingPathExtension().appendingPathExtension("sample.log").path,
                ]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                if (try? process.run()) != nil { process.waitUntilExit() }
            }
            _ = app.forceTerminate()
            return
        }
        finish(1, message)
    }
    private func finish(_ code: Int32, _ message: String? = nil) -> Never {
        if let log = try? Data(contentsOf: captureLog) { FileHandle.standardError.write(log) }
        if let message { FileHandle.standardError.write(Data((message + "\n").utf8)) }
        Darwin.exit(code)
    }
}

@main struct NativePreviewCommand {
    @MainActor static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let executablePath = args.first, let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count
        else {
            FileHandle.standardError.write(
                Data("Usage: native-preview CADENCE_EXECUTABLE --snapshot OUTPUT.png [flags]\n".utf8))
            exit(1)
        }
        let executable = URL(fileURLWithPath: executablePath).standardizedFileURL
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard executable.lastPathComponent == "Cadence", bundle.pathExtension == "app",
            Bundle(url: bundle)?.bundleIdentifier == "com.cadence.music",
            Bundle(url: bundle)?.executableURL?.standardizedFileURL == executable,
            FileManager.default.isExecutableFile(atPath: executable.path)
        else {
            FileHandle.standardError.write(Data("Choose the freshly built Cadence app bundle.\n".utf8))
            exit(1)
        }
        let runner = NativePreview(
            executable: executable, arguments: Array(args.dropFirst()), snapshot: URL(fileURLWithPath: args[index + 1]))
        runner.start()
        withExtendedLifetime(runner) { RunLoop.main.run() }
    }
}
