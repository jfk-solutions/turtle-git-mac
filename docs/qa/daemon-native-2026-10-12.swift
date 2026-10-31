// Included in the combined receiver: no app installation or public listener.
import AppKit
import TurtleGitCore

private final class NativeDaemonDrainGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false, cancellationSeen = false
    var observedCancellation: Bool { lock.lock(); defer { lock.unlock() }; return cancellationSeen }
    func open() { lock.lock(); released = true; lock.unlock() }
    func awaitRelease() {
        lock.lock(); cancellationSeen = true; lock.unlock()
        while true {
            lock.lock(); let ready = released; lock.unlock()
            if ready { return }
            usleep(5_000)
        }
    }
}

struct DaemonNativeVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor private static func wait(_ phase: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        guard condition() else { throw Failure(description: "Daemon lifecycle did not settle: " + phase) }
    }
    @MainActor static func verify() async throws {
        let suite = "TurtleGit.Daemon.QA." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set(false, forKey: "ConfirmKillProcess")
        preferences.set(0, forKey: "AutoCloseGitProgress")
        defer { preferences.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitDaemonNative-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = GitRepository(root: root)
        let controller = GitDaemonWindowController(repository: repo, access: nil, preferences: preferences)
        controller.window?.alphaValue = 0
        let drain = NativeDaemonDrainGate()
        var owners = [controller]
        defer { drain.open(); for owner in owners { owner.model.retire(); owner.window?.close() } }
        var closed = 0
        controller.onClosed = { closed += 1 }
        controller.model.run = { _, _, token, emit in
            // Readiness crosses chunk boundaries and is not lost when output
            // floods the bounded producer queue.
            emit(GitOutputChunk(stream: .stderr, data: Data("Ready to ".utf8)))
            emit(GitOutputChunk(stream: .stderr, data: Data("rumble\n".utf8)))
            emit(GitOutputChunk(stream: .stdout, data: Data(repeating: 120, count: 2 * 1024 * 1024)))
            while !token.isCancelled { usleep(10_000) }
            drain.awaitRelease()
            return 130
        }
        controller.model.begin()
        precondition(controller.model.phase == .warning && GitDaemonWindowModel.activeOperations == 0)
        controller.model.rememberWarning = true; controller.model.proceed(); controller.model.proceed()
        precondition(controller.model.busy && GitDaemonWindowModel.activeOperations == 1)
        precondition(preferences.bool(forKey: "DaemonNoSecurityWarning"))
        let delegate = TurtleGitApplicationDelegate()
        precondition(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        try await wait("split readiness through bounded output") { controller.model.status == "Git daemon is running." }
        precondition(controller.model.status == "Git daemon is running.")
        precondition(controller.model.output.utf8.count < 100 * 1024)
        precondition(!controller.windowShouldClose(controller.window!))
        try await wait("cancel reaches owned worker") { drain.observedCancellation }
        precondition(controller.model.phase == .stopping && controller.model.status == "Stopping Git daemon…")
        precondition(controller.hasPendingWork && GitDaemonWindowModel.activeOperations == 1 && closed == 0)
        precondition(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        controller.model.cancel(); controller.model.proceed()
        precondition(controller.model.phase == .stopping && closed == 0)
        drain.open()
        // The controller's onClosed deliberately follows both worker drainage
        // and native sheet/window settlement. A zero global process count alone
        // does not prove that exact owner has delivered completion.
        try await wait("requested Close and exact owner completion") {
            GitDaemonWindowModel.activeOperations == 0 && !controller.hasPendingWork && closed == 1
        }
        precondition(GitDaemonWindowModel.activeOperations == 0 && !controller.model.busy && closed == 1)
        precondition(controller.model.status == "Git daemon stopped.")
        precondition(controller.model.cancelled && !controller.model.success && controller.model.error == nil && controller.model.completionRange != nil)
        precondition(controller.model.output.contains("User cancelled"))
        let stoppedOutput = controller.model.output
        controller.model.proceed(); controller.model.cancel()
        precondition(closed == 1 && controller.model.output == stoppedOutput && controller.model.status == "Git daemon stopped.")
        preferences.removeObject(forKey: "DaemonNoSecurityWarning")
        let abort = GitDaemonWindowController(repository: repo, access: nil, preferences: preferences)
        abort.window?.alphaValue = 0; owners.append(abort)
        var abortClosed = 0; abort.onClosed = { abortClosed += 1 }
        abort.model.rememberWarning = true; abort.model.begin(); abort.model.cancel()
        try await wait("warning Abort owner completion") { abortClosed == 1 && !abort.hasPendingWork }
        precondition(!preferences.bool(forKey: "DaemonNoSecurityWarning") && GitDaemonWindowModel.activeOperations == 0)
        let forced = GitDaemonWindowController(repository: repo, access: nil, preferences: preferences)
        forced.window?.alphaValue = 0; owners.append(forced)
        let forcedDrain = NativeDaemonDrainGate(); defer { forcedDrain.open() }
        var forcedClosed = 0; forced.onClosed = { forcedClosed += 1 }
        forced.model.run = { _, _, token, _ in while !token.isCancelled { usleep(10_000) }; forcedDrain.awaitRelease(); return 130 }
        forced.model.proceed(); forced.window?.close()
        let retiredStatus = forced.model.status, retiredOutput = forced.model.output
        try await wait("forced Close reaches owned worker") { forcedDrain.observedCancellation }
        precondition(forced.hasPendingWork && forcedClosed == 0 && GitDaemonWindowModel.activeOperations == 1)
        precondition(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        forcedDrain.open()
        try await wait("forced Close worker and callback drainage") {
            GitDaemonWindowModel.activeOperations == 0 && !forced.hasPendingWork && forcedClosed == 1
        }
        precondition(GitDaemonWindowModel.activeOperations == 0)
        precondition(forced.model.status == retiredStatus && forced.model.output == retiredOutput && forced.model.error == nil)
        print("Native daemon warning, remembered Proceed, Abort, bounded output, cancellation, forced-close and Quit ownership verified.")
    }
}
