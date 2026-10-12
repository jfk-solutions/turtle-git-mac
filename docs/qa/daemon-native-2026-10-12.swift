// Included in the combined receiver: no app installation or public listener.
import AppKit
import TurtleGitCore

struct DaemonNativeVerification {
    @MainActor static func verify() async throws {
        let preferences = UserDefaults(suiteName: "TurtleGit.Daemon.QA." + UUID().uuidString)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitDaemonNative-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        let controller = GitDaemonWindowController(repository: repo, access: nil, preferences: preferences)
        var closed = 0
        controller.onClosed = { closed += 1 }
        controller.model.run = { _, _, token, emit in
            // Readiness crosses chunk boundaries and is not lost when output
            // floods the bounded producer queue.
            emit(GitOutputChunk(stream: .stderr, data: Data("Ready to ".utf8)))
            emit(GitOutputChunk(stream: .stderr, data: Data("rumble\n".utf8)))
            emit(GitOutputChunk(stream: .stdout, data: Data(repeating: 120, count: 2 * 1024 * 1024)))
            while !token.isCancelled { usleep(10_000) }
            return 130
        }
        controller.model.begin()
        precondition(controller.model.phase == .warning && GitDaemonWindowModel.activeOperations == 0)
        controller.model.rememberWarning = true; controller.model.proceed(); controller.model.proceed()
        precondition(controller.model.busy && GitDaemonWindowModel.activeOperations == 1)
        precondition(preferences.bool(forKey: "DaemonNoSecurityWarning"))
        let delegate = TurtleGitApplicationDelegate()
        precondition(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        for _ in 0..<100 {
            if controller.model.status == "Git daemon is running." { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(controller.model.status == "Git daemon is running.")
        precondition(controller.model.output.utf8.count < 100 * 1024)
        precondition(!controller.windowShouldClose(controller.window!))
        for _ in 0..<100 {
            if GitDaemonWindowModel.activeOperations == 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(GitDaemonWindowModel.activeOperations == 0 && !controller.model.busy && closed == 1)
        precondition(controller.model.status == "Git daemon stopped.")
        preferences.removeObject(forKey: "DaemonNoSecurityWarning")
        let abort = GitDaemonWindowController(repository: repo, access: nil, preferences: preferences)
        abort.model.rememberWarning = true; abort.model.begin(); abort.model.cancel()
        precondition(!preferences.bool(forKey: "DaemonNoSecurityWarning") && GitDaemonWindowModel.activeOperations == 0)
        let forced = GitDaemonWindowController(repository: repo, access: nil, preferences: preferences)
        forced.model.run = { _, _, token, _ in while !token.isCancelled { usleep(10_000) }; return 130 }
        forced.model.proceed(); forced.window?.close()
        precondition(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        for _ in 0..<100 {
            if GitDaemonWindowModel.activeOperations == 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(GitDaemonWindowModel.activeOperations == 0)
        print("Native daemon warning, remembered Proceed, Abort, bounded output, cancellation, forced-close and Quit ownership verified.")
    }
}
