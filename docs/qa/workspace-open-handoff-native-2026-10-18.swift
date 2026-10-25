// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func handoffHiddenOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(NSPoint(x:-24000,y:-24000))
        handoffHiddenOrder(mode,relativeTo:number)
    }
}

enum WorkspaceOpenHandoffVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    @MainActor static func wait(line: Int = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<3000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Workspace handoff timeout at \(line)")
    }
    @MainActor static func verify() async throws {
        // Preserve real AppKit visibility/ownership assertions without exposing
        // receiver-owned failure windows or sheets on the user's desktop.
        let ordered=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!
        let hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.handoffHiddenOrder(_:relativeTo:)))!
        method_exchangeImplementations(ordered,hidden)
        defer {method_exchangeImplementations(ordered,hidden)}
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.ExternalHandoff." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let patch = root.appendingPathComponent("literal [é]\ninput.PATCH")
        let finder = FinderRequest(action: .log, paths: [root], alternateTool: true).url!
        let invalid = URL(string: "turtlegit://action?command=not-a-command&path=/tmp")!
        let web = URL(string: "https://example.invalid/file.patch")!
        let broker = WorkspaceOpenHandoff()
        broker.applicationURL = { root.appendingPathComponent("Owned App.app") }
        var launches: [[URL]] = [], replies: [(Error?) -> Void] = []
        var configurationChecks = 0
        broker.launch = { urls, app, configuration, reply in
            launches.append(urls); replies.append(reply)
            if configuration.createsNewApplicationInstance && configuration.activates && configuration.arguments == ["--turtlegit-action-only"] && app.lastPathComponent == "Owned App.app" { configurationChecks += 1 }
        }
        broker.submit([web, invalid, root.appendingPathComponent("not-patch.txt")])
        try require(launches.isEmpty && !broker.hasPendingWork, "Unsupported URL launched a workspace")
        broker.submit([finder, patch, finder])
        try require(launches.count == 1 && launches[0].map(\.absoluteString) == [finder, patch, finder].map(\.absoluteString) && configurationChecks == 1, "Handoff changed order/duplicates/literal URLs or reused tool arguments/process")
        try require(broker.pendingCount == 1, "Launch was not owned through reply")
        replies[0](nil); replies[0](Failure(description: "late duplicate"))
        try require(!broker.hasPendingWork && broker.failureWindows.isEmpty, "Duplicate launch reply created stale error/work")
        var acknowledge: (() -> Void)?
        broker.presentFailure = { _, reply in acknowledge = reply }
        broker.submit([finder]); replies[1](Failure(description: "simulated workspace failure"))
        try require(broker.hasPendingWork && acknowledge != nil, "Failure lost its owned acknowledgment")
        acknowledge?(); acknowledge?()
        try require(!broker.hasPendingWork, "One-shot failure acknowledgment did not retire")
        broker.submit([finder]); try require(broker.hasPendingWork, "Retirement fixture did not launch")
        broker.retire(); try require(broker.hasPendingWork, "Retirement released in-flight launch/scopes before callback")
        replies[2](Failure(description: "late failure after retirement"))
        try require(!broker.hasPendingWork, "Retired launch did not drain")
        broker.submit([finder]); try require(launches.count == 3, "Retired broker accepted another request")

        // Exercise the real ownerless failure window and sheet-owner retirement.
        let visible = WorkspaceOpenHandoff()
        visible.launch = { _, _, _, reply in reply(Failure(description: "Owned native launch failure")) }
        visible.owner = { nil }; visible.submit([finder])
        try require(visible.failureWindows.count == 1 && visible.failureWindows[0].isVisible && visible.hasPendingWork, "Ownerless native failure was invisible or unowned")
        visible.failureWindows[0].performClose(nil)
        try await wait { !visible.hasPendingWork }
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 220), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false; parent.alphaValue = 0; parent.orderFront(nil)
        defer { parent.close(); visible.retire() }
        visible.owner = { parent }; visible.submit([finder])
        try await wait { visible.failureWindows.count == 1 && parent.attachedSheet === visible.failureWindows[0] }
        parent.close(); try await wait { !visible.hasPendingWork }

        // Normal startup owns queued events once, with no second Scene URL path.
        let normal = TurtleGitApplicationDelegate(); normal.startupArguments = []; normal.startupDirectory = root.path
        let normalModel = RepositoryModel(startMonitoring: false, initializePreferences: false)
        let actionModel=RepositoryModel(startMonitoring:false,initializePreferences:false)
        normal.makeStandaloneWorkspace={actionModel}
        var sequence: [String] = []
        normal.startupCommandHandler = { _, _, _ in sequence.append("startup") }
        normal.workspaceOpenHandler = { model, url in if model === actionModel { sequence.append(url.absoluteString) } }
        normal.application(NSApp, open: [finder, patch]); normal.startupDidFinishLaunching()
        try require(sequence.isEmpty, "Open events ran before workspace ownership")
        normal.repositoryModel = normalModel
        try require(sequence == ["startup", finder.absoluteString, patch.absoluteString], "Startup and queued URL order/one-shot delivery changed")
        normal.application(NSApp, open: [finder]); normal.startupDidFinishLaunching()
        try require(sequence == ["startup", finder.absoluteString, patch.absoluteString, finder.absoluteString], "Queued events replayed or repeated user action was suppressed")
        var reentrant: [URL] = []
        let nested = root.appendingPathComponent("nested.diff")
        normal.workspaceOpenHandler = { _, url in
            reentrant.append(url)
            if url == finder { normal.application(NSApp, open: [nested]) }
        }
        normal.application(NSApp, open: [finder, patch])
        try require(reentrant == [finder, patch, nested], "Reentrant event delivery overtook an older received URL")
        normalModel.stopMonitoringForTermination();actionModel.stopMonitoringForTermination()

        // Closing the Git editor cannot exit before an accepted external launch
        // and its failure acknowledgment, nor rewrite the captured Git status.
        let base = root.appendingPathComponent("base"), mine = root.appendingPathComponent("mine")
        try Data("before\n".utf8).write(to: base); try Data("after\n".utf8).write(to: mine)
        let workspace = RepositoryModel(startMonitoring: false, initializePreferences: false)
        workspace.fileComparisonPreferences = prefs
        var shown: FileComparisonWindowController?
        workspace.configureMergeToolLaunch = { session in
            session.requiresScopes = false; session.executable = { git }
            session.presentation = { controller in shown = controller as? FileComparisonWindowController; controller.window?.alphaValue = 0; controller.window?.orderFront(nil) }
        }
        let tool = TurtleGitApplicationDelegate()
        tool.startupArguments = ["--merge-tool", "--base", base.path, "--mine", mine.path, "--readonly"]; tool.startupDirectory = root.path
        tool.repositoryModel = workspace
        var exitStatus: Int32?, toolReply: ((Error?) -> Void)?, toolAck: (() -> Void)?
        tool.startupMergeToolExit = { exitStatus = $0 }
        tool.workspaceOpenHandoff.launch = { urls, _, config, reply in
            if urls == [finder] && config.createsNewApplicationInstance && config.arguments == ["--turtlegit-action-only"] { toolReply = reply }
        }
        tool.workspaceOpenHandoff.presentFailure = { _, reply in toolAck = reply }
        tool.application(NSApp, open: [finder]); tool.startupDidFinishLaunching()
        defer { shown?.close(); workspace.stopMonitoringForTermination(); tool.workspaceOpenHandoff.retire() }
        try await wait { shown?.model.document != nil && shown?.model.mergeToolHasPendingWork == false && shown?.model.filtering == false }
        try require(toolReply != nil && tool.applicationShouldTerminate(NSApp) == .terminateCancel, "Quit ignored an accepted external launch")
        shown!.close(); try await wait { workspace.mergeToolLaunches.isEmpty }
        try require(exitStatus == nil, "Git tool exited before external launch completion")
        toolReply?(Failure(description: "simulated external launch failure"))
        try require(toolAck != nil && exitStatus == nil && tool.applicationShouldTerminate(NSApp) == .terminateCancel, "Failure acknowledgment lost process/Quit ownership")
        toolAck?(); try await wait { exitStatus != nil }
        try require(exitStatus == 0 && !tool.workspaceOpenHandoff.hasPendingWork && (try Data(contentsOf: mine)) == Data("after\n".utf8), "External failure changed Git comparison result or input")
        toolReply?(nil); toolAck?()
        try require(exitStatus == 0 && !tool.workspaceOpenHandoff.hasPendingWork, "Late duplicate handoff reply changed completed Git status")
        print("PASS: external workspace URLs preserve literal delivery, fresh process configuration, early startup order, owned failure/drain/Quit and original Git exit status")
    }
}
