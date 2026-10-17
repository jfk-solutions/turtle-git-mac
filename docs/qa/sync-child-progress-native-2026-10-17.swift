// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

@main struct SyncChildProgressVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor final class Gate {
        var entered = false
        private var reply: CheckedContinuation<Void, Never>?
        func wait() async { entered = true; await withCheckedContinuation { reply = $0 } }
        func open() { let callback = reply; reply = nil; callback?.resume() }
    }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(_ ready: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<6000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Sync child progress wait at \(line)")
    }
    @MainActor static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    @MainActor static func capture(_ window: NSWindow, name: String) async throws {
        guard let output = ProcessInfo.processInfo.environment["TURTLEGIT_SYNC_CHILD_CAPTURE"] else { return }
        if #available(macOS 14.4, *) {
            let folder = URL(fileURLWithPath: output); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (appearance, suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
                window.appearance = NSAppearance(named: appearance); window.alphaValue = 1; window.orderFront(nil); window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 250_000_000)
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure(description: "Missing owned progress window") }
                let config = SCStreamConfiguration(); config.width = Int(window.frame.width*2); config.height = Int(window.frame.height*2); config.showsCursor = false; config.includeChildWindows = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: config)
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name+"-"+suffix+".png"))
            }
            window.alphaValue = 0
        }
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), executable = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.SyncChildQA."+UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite); NSApp.windows.forEach { $0.close() } }
        preferences.set(0, forKey: "AutoCloseGitProgress"); preferences.set(true, forKey: "ShowAppContextMenuIcons")
        let repo = GitRepository(root: root, executable: executable)
        _ = try await repo.run(["init", "--initial-branch=main", "--template="])
        for (key,value) in [("user.name","Sync QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("tag.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "base")
        let remote = root.appendingPathComponent("server.git")
        _ = try await repo.run(["clone","--bare","--template=","--",root.path,remote.path])
        _ = try await repo.run(["remote","add","origin",remote.path])
        let server = GitRepository(root: remote, executable: executable)
        _ = try await server.run(["config","core.hooksPath",remote.appendingPathComponent("hooks").path])
        let store = ActionLogStore(storageURL: root.appendingPathComponent("private-action-log.txt"))
        ProgressActionLog.install(store: store, preferences: preferences)
        _ = try await repo.run(["tag","qa-local"])
        let initial = try await repo.synchronizationTags(remote: "origin")
        let row = initial.rows.first { $0.name.rawValue == "qa-local" }!
        var pushed = 0
        let push = SynchronizationProgressController(repository: repo, operation: .tag(.push,row,initial,false), cancellation: OperationCancellation(), preferences: preferences) { result in
            if case .success(.tag) = result { pushed += 1 }
        }
        push.window!.alphaValue = 0; push.window!.orderFront(nil); push.model.start()
        try await wait { !push.model.busy && SynchronizationProgressModel.activeOperations == 0 }
        try require(push.model.success && push.model.percentage == 100 && push.model.currentWork == "Success" && push.model.completionRange != nil && pushed == 0, "Manual Push result did not retain completion")
        let saved = try store.read(); push.model.saveActionLog(); try require(try store.read() == saved, "Duplicate Action log entry")
        try await wait { views(push.window!.contentView!).contains { $0 is SubmoduleProgressTextView } }
        let text = views(push.window!.contentView!).compactMap { $0 as? SubmoduleProgressTextView }.first!
        let clipboard = NSPasteboard.withUniqueName(); text.clipboard = clipboard
        text.setSelectedRange(NSRange(location:0,length:min(4,(text.string as NSString).length)))
        let selection = text.selectedRange(), menu = text.outputMenu()
        try require(menu.items.first?.image != nil && menu.items.last?.image != nil, "Source Copy icons missing")
        text.copyAllInformation(nil)
        try require(clipboard.string(forType:.string) == text.string && text.selectedRange() == selection, "Copy all changed selection or lost output")
        clipboard.releaseGlobally(); push.close(); try await wait { pushed == 1 }; push.close(); try require(pushed == 1, "Progress completion repeated")

        // Source tag progress captures the preference; later Settings edits cannot change this attempt.
        _ = try await server.run(["tag","qa-remote"])
        let incoming = try await repo.synchronizationTags(remote:"origin"), incomingRow = incoming.rows.first { $0.name.rawValue == "qa-remote" }!
        preferences.set(2,forKey:"AutoCloseGitProgress"); var fetched = 0
        let fetch = SynchronizationProgressController(repository:repo,operation:.tag(.fetch,incomingRow,incoming,false),cancellation:OperationCancellation(),preferences:preferences) { result in if case .success(.tag) = result { fetched += 1 } }
        fetch.window!.alphaValue = 0; fetch.window!.orderFront(nil); preferences.set(0,forKey:"AutoCloseGitProgress"); fetch.model.start()
        try await wait { fetched == 1 && SynchronizationProgressModel.activeOperations == 0 }
        _ = try await repo.run(["rev-parse","--verify","refs/tags/qa-remote"])

        // Real transport rejection retains its raw diagnostics, terminal code, native footer and failure window.
        let hook = remote.appendingPathComponent("hooks/pre-receive")
        try FileManager.default.createDirectory(at:hook.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("#!/bin/sh\necho 'fatal: QA remote rejected the tag' >&2\nexit 1\n".utf8).write(to:hook)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:hook.path)
        _ = try await repo.run(["tag","qa-rejected"])
        let rejecting = try await repo.synchronizationTags(remote:"origin"), rejectedRow = rejecting.rows.first { $0.name.rawValue == "qa-rejected" }!
        var rejected = 0
        let failure = SynchronizationProgressController(repository:repo,operation:.tag(.push,rejectedRow,rejecting,false),cancellation:OperationCancellation(),preferences:preferences) { result in if case .failure = result { rejected += 1 } }
        failure.window!.alphaValue = 0; failure.window!.orderFront(nil); failure.model.start()
        try await wait { !failure.model.busy && SynchronizationProgressModel.activeOperations == 0 }
        try require(!failure.model.success && !failure.model.cancelled && failure.model.percentage == 100 && failure.model.currentWork.contains("exit code") && failure.model.output.contains("QA remote rejected") && failure.model.completionRange != nil && rejected == 0,"Real rejection lost Git result/footer")
        try await capture(failure.window!,name:"sync-child-progress-failure"); failure.close(); try await wait { rejected == 1 }

        let state = try await repo.synchronizationRebaseState(target:"HEAD")
        preferences.set(true,forKey:"ConfirmKillProcess")
        let gate = Gate(), token = OperationCancellation(); var closed = 0; var answer: ((Bool)->Void)?
        let live = SynchronizationProgressController(repository:repo,operation:.merge(state),cancellation:token,preferences:preferences) { _ in closed += 1 }
        live.model.executeOperation = { onOutput in
            onOutput(GitOutputChunk(stream:.stderr,data:Data("Receiving objects:  42% (42/100)\r".utf8)))
            await gate.wait(); return .merge(try await repo.run(["status","--short"]))
        }
        live.model.confirmCancel = { answer = $0 }; live.window!.alphaValue = 0; live.window!.orderFront(nil); live.model.start()
        try await wait { gate.entered && live.model.percentage == 42 }
        try require(live.model.currentWork.contains("Receiving objects"), "Live parser current work lost")
        try await capture(live.window!,name:"sync-child-progress-live")
        live.model.cancel(); try require(live.model.confirmingCancellation && answer != nil,"Abort question was not owned")
        gate.open(); try await wait { !live.model.busy }
        try require(live.model.success && closed == 0 && !token.isCancelled,"Natural success closed behind Abort question")
        answer?(true); answer?(true); try await wait { closed == 1 }
        try require(!token.isCancelled,"Late Abort cancelled natural success")

        // Forced closure retires the presentation but keeps parent continuation and Quit fenced until actual drain.
        let drain = Gate(), forcedToken = OperationCancellation(); var delivered = 0, didClose = 0
        let forced = SynchronizationProgressController(repository:repo,operation:.merge(state),cancellation:forcedToken,preferences:preferences) { result in if case .failure = result { delivered += 1 } }
        forced.onClosed = { didClose += 1 }
        forced.model.executeOperation = { onOutput in await drain.wait(); onOutput(GitOutputChunk(stream:.stderr,data:Data("late output\n".utf8))); return .merge(try await repo.run(["status","--short"])) }
        forced.window!.alphaValue = 0; forced.window!.orderFront(nil); forced.model.start(); try await wait { drain.entered }
        let before = forced.model.output; forced.abortPresentation()
        try require(SynchronizationProgressModel.activeOperations == 1 && delivered == 0 && didClose == 0 && forcedToken.isCancelled,"Forced close released worker ownership early")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit ignored closed live worker")
        drain.open(); try await wait { SynchronizationProgressModel.activeOperations == 0 && delivered == 1 && didClose == 1 }
        try require(forced.model.output == before && forced.model.completionRange == nil && forced.model.result == nil,"Retired worker republished late output/result/footer")
        forced.abortPresentation(); try require(delivered == 1 && didClose == 1,"Forced-close callback repeated")

        preferences.set(false,forKey:"ConfirmKillProcess")
        let cancelGate = Gate(), cancelToken = OperationCancellation(); var cancelled = 0
        let abort = SynchronizationProgressController(repository:repo,operation:.merge(state),cancellation:cancelToken,preferences:preferences) { _ in cancelled += 1 }
        abort.model.executeOperation = { _ in await cancelGate.wait(); try cancelToken.check(); return .merge(try await repo.run(["status","--short"])) }
        abort.window!.alphaValue = 0; abort.window!.orderFront(nil); abort.model.start(); try await wait { cancelGate.entered }
        abort.model.cancel(); abort.model.cancel(); try require(cancelToken.isCancelled && abort.model.cancelling,"Direct Abort did not cancel captured worker")
        cancelGate.open(); try await wait { !abort.model.busy && SynchronizationProgressModel.activeOperations == 0 }
        try require(abort.model.cancelled && abort.model.currentWork == "User cancelled" && abort.model.percentage == 100 && cancelled == 0,"Cancelled failure lost retained terminal state")
        abort.close(); try await wait { cancelled == 1 }
        var compact = 0; let compactToken = OperationCancellation()
        let tags = SynchronizationProgressController(repository:repo,operation:.tags("origin"),cancellation:compactToken,preferences:preferences) { result in if case .success(.tags) = result { compact += 1 } }
        tags.window!.alphaValue = 0; tags.window!.orderFront(nil); tags.model.start(); try await wait { compact == 1 && SynchronizationProgressModel.activeOperations == 0 }
        try require(!compactToken.isCancelled, "Successful compact close cancelled parent request")
        try require(NSApp.windows.filter { $0.isVisible }.isEmpty,"Owned progress window remained visible")
        print("PASS Sync child progress: real tag Push/Fetch/rejection, captured auto-close, native Copy icons/private clipboard, one Action log, live parser, completion/timing/footer, question/natural-success race, direct Abort, compact results, forced close/late output/drain/Quit and once-only parent callbacks")
    }
}
