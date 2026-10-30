// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

/// Supplemental receiver cases; the runner owns process and offscreen policy.
@MainActor enum WorkspaceOwnerVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    static func wait(_ ready: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<3000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Workspace ownership timeout at \(line)")
    }
    static func buttons(_ view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons($0) }
    }
    static func workspace(root: URL, git: URL) async throws {
        let delegate = TurtleGitApplicationDelegate()
        delegate.startupArguments = []; delegate.startupDirectory = root.path
        let model = RepositoryModel(startMonitoring: false, initializePreferences: false)
        let actionModel = RepositoryModel(startMonitoring:false,initializePreferences:false)
        delegate.makeStandaloneWorkspace={actionModel}
        var windows: [NSWindow] = [], delivered: [String] = [], presentations = 0
        defer {
            delegate.presentWorkspace = nil
            for window in windows { window.close() }
            model.stopMonitoringForTermination();actionModel.stopMonitoringForTermination()
        }
        delegate.presentWorkspace = { presentations += 1 }
        delegate.startupCommandHandler = { owner, _, _ in if owner === model { delivered.append("startup") } }
        delegate.workspaceOpenHandler = { owner, url in if owner === actionModel { delivered.append(url.lastPathComponent) } }
        delegate.workspaceServiceHandler = { owner, request in
            if owner === actionModel && request.action == .status { delivered.append("service"); return true }; return false
        }
        delegate.repositoryModel = model
        delegate.startupDidFinishLaunching()
        let first = root.appendingPathComponent("first.diff"), second = root.appendingPathComponent("second.diff")
        delegate.application(NSApp, open: [first, second])
        try delegate.submitServiceRequest(FinderServiceCommand.status.request(paths: [root]))
        try require(presentations == 1 && delivered.isEmpty && delegate.pendingFinderServiceRequest != nil, "Queued startup/URL/Services ran before native attachment or requested duplicate presentation")
        @MainActor func attach() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: -24000, y: -24000, width: 1000, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.alphaValue = 0
            window.contentView = NSHostingView(rootView: RepositoryWindow(model: model, onWorkspaceWindowAttached: delegate.workspaceWindowDidAttach))
            windows.append(window); window.orderFront(nil); window.contentView?.layoutSubtreeIfNeeded()
            return window
        }
        let initial = attach()
        try await wait { delivered == ["startup", "first.diff", "second.diff", "service"] }
        try require(model.workspaceWindow === initial && delegate.startupDelivered && delegate.pendingFinderServiceRequest == nil, "Native workspace did not own queued one-shot delivery")
        initial.close(); try await wait { model.workspaceWindow == nil }
        delegate.application(NSApp, open: [root.appendingPathComponent("after-close.diff")])
        try require(presentations == 1 && delivered.count == 5 && delivered.last == "after-close.diff" && model.workspaceWindow == nil && delegate.actionRepositoryModel === actionModel, "Dialog delivery after close opened/reused a workspace or lost the private action owner")
        delegate.application(NSApp,open:[URL(string:"turtlegit://workspace")!])
        try require(presentations == 2 && model.workspaceWindow == nil,"Explicit Open did not request the identified workspace")
        try require(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false) && presentations == 3, "Dock reopen did not use the same identified presentation route")
        let reopened = attach()
        try await wait { delivered.last == "after-close.diff" && delivered.count == 5 }
        // A stale callback from the old capture cannot clear the replacement.
        initial.contentView = nil
        try require(model.workspaceWindow === reopened && delivered.filter { $0 == "startup" }.count == 1, "Retired capture cleared replacement owner or replayed startup")
        try require(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp), "Closing workspace would terminate its owned child workflows")
        let tool = TurtleGitApplicationDelegate(); tool.startupArguments = ["--merge-tool"]
        var toolPresentations = 0; tool.presentWorkspace = { toolPresentations += 1 }
        try require(!tool.applicationShouldOpenUntitledFile(NSApp) && !tool.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false) && toolPresentations == 0, "Standalone Merge requested a workspace")
        reopened.close(); try await wait { model.workspaceWindow == nil }
    }
    static func retirement(root: URL, git: URL) async throws {
        let fm = FileManager.default, folder = root.appendingPathComponent("quit-repository")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let repo = GitRepository(root: folder, executable: git, askpass: nil, libgit2Configuration: .init(enabled: false))
        _ = try await repo.run(["init", "--template=", "-b", "main"])
        for (key, value) in [("user.name", "Workspace QA"), ("user.email", "workspace@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        let file = folder.appendingPathComponent("file")
        try Data("base\n".utf8).write(to: file); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        try Data("working\n".utf8).write(to: file)
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: folder.appendingPathComponent(".git/index"))
        let suite = "TurtleGit.WorkspaceOwner." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        prefs.set(false, forKey: "UseLibgit2"); prefs.set(false, forKey: "EnableGravatar"); prefs.set(false, forKey: "Autocompletion"); prefs.set(true, forKey: "HintStagingMode")
        var owners: [CommitWindowController] = [], held: CheckedContinuation<[StatusEntry], Error>?
        defer {
            held?.resume(throwing: OperationCancellationFailure.cancelled); held = nil
            for owner in owners { if let window = owner.window, let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .abort); sheet.orderOut(nil) }; owner.close() }
            prefs.removePersistentDomain(forName: suite)
        }
        func quitReadinessDiagnostic()->String {
            let counters=quitWorkerCounters(),active=counters.filter{$0.1 != 0}.map{"\($0.0)=\($0.1)"}.joined(separator:",")
            let windows=NSApp.windows.map{window in
                let identity="window=\(window.windowNumber),visible=\(window.isVisible),sheet=\(window.attachedSheet != nil),delegate=\(String(describing:window.delegate.map{type(of:$0)}))"
                guard let owner=window.delegate as? CommitWindowController else{return identity}
                return identity+",reuse=\(owner.canReuse),busy=\(owner.model.busy),confirming=\(owner.model.confirmingQuit),identity=\(owner.model.commitIdentityPrepared),metadata=\(owner.model.loadingFileMetadata),focus=\(owner.model.messageFocusAvailable),picker=\(owner.hasMessagePicker),error=\(owner.model.error ?? "none")"
            }.joined(separator:"; ")
            return "counterInventory=\(counters.count),active=[\(active)],modal=\(String(describing:NSApp.modalWindow)),windows=[\(windows)]"
        }
        func waitForQuitReadiness(_ phase:String,_ ownersReady:()->Bool)async throws {
            do {
                try await wait {ownersReady() && NSApp.modalWindow==nil && quitWorkerCounters().allSatisfy{$0.1==0}}
            } catch {
                throw Failure(description:"Quit readiness \(phase) did not settle: \(quitReadinessDiagnostic())")
            }
        }
        @MainActor func makeOwner() async throws -> CommitWindowController {
            let owner = CommitWindowController(repository: repo, access: nil, defaults: prefs)
            owners.append(owner); owner.window?.isReleasedWhenClosed = false; owner.window?.alphaValue = 0; owner.window?.setFrameOrigin(.init(x: -24000, y: -24000)); owner.showWindow(nil)
            owner.model.reload(paths: ["."])
            try await wait { !owner.model.busy && owner.model.hasHead && owner.model.changelistsLoaded && owner.messageEditor() != nil && CommitWindowModel.activeReloads == 0 && CommitWindowModel.activeMetadataOperations == 0 }
            try require(owner.model.error == nil && owner.canReuse, "Actual Commit preparation failed: \(owner.model.error ?? "none")")
            owner.model.message = "Retained workspace quit draft"
            return owner
        }
        prefs.set(true, forKey: "Commit.SkipCancelConfirmation")
        let retired = try await makeOwner(), retiredWindow = retired.window!
        retired.model.cancel()
        try await wait { !retired.canReuse && !retiredWindow.isVisible && CommitWindowModel.activeReloads == 0 }
        // Retain an actual retired native object in AppKit's enumeration, as
        // happens with cached closed windows; do not revive its controller/model.
        retiredWindow.orderFront(nil); retiredWindow.orderOut(nil)
        try require(NSApp.windows.contains { $0 === retiredWindow } && !retired.canReuse, "Retired Commit was not retained in actual NSApplication window inventory")
        let delegate = TurtleGitApplicationDelegate(); delegate.startupArguments = []
        var replies: [Bool] = []; delegate.replyToTermination = { _, accepted in replies.append(accepted) }
        try await waitForQuitReadiness("initial retired owner drain"){!retired.canReuse && !retiredWindow.isVisible && !retired.model.confirmingQuit}
        try require(delegate.applicationShouldTerminate(NSApp) == .terminateNow && !retiredWindow.isVisible && !retired.model.confirmingQuit, "Quit resurrected or waited for a retired Commit")
        prefs.set(false, forKey: "Commit.SkipCancelConfirmation")
        let live = try await makeOwner(), liveWindow = live.window!
        try require(delegate.applicationShouldTerminate(NSApp) == .terminateLater, "Live Commit skipped its real cancellation question")
        try await wait { liveWindow.attachedSheet != nil }
        let no = buttons(liveWindow.attachedSheet?.contentView).first { $0.title == "No" }
        try require(no != nil && live.model.confirmingQuit, "Actual Commit No/Yes question missing")
        no?.performClick(nil)
        try await wait { replies == [false] && liveWindow.attachedSheet == nil && !live.model.confirmingQuit }
        try require(live.canReuse && live.model.message == "Retained workspace quit draft" && !retiredWindow.isVisible, "Declining Quit lost draft or revived retired owner")
        // No declines this Quit attempt, but the presentation-only draft styler
        // may still own a worker. The application correctly refuses a new Quit
        // until that real worker drains; sheet detachment is not admission.
        try await waitForQuitReadiness("after declining first Quit"){
            live.canReuse && liveWindow.isVisible && !live.model.busy && !live.model.confirmingQuit && liveWindow.attachedSheet==nil && live.model.message=="Retained workspace quit draft" && !retired.canReuse && !retiredWindow.isVisible
        }
        let beforeSecondQuit=quitReadinessDiagnostic(),secondReply=delegate.applicationShouldTerminate(NSApp)
        try require(secondReply == .terminateLater,"Second Quit did not ask live Commit; reply=\(secondReply.rawValue),before=\(beforeSecondQuit),after=\(quitReadinessDiagnostic())")
        try await wait { liveWindow.attachedSheet != nil }
        let yes = buttons(liveWindow.attachedSheet?.contentView).first { $0.title == "Yes" }
        try require(yes != nil, "Actual Commit affirmative choice missing"); yes?.performClick(nil)
        try await wait { replies == [false, true] && liveWindow.attachedSheet == nil && !live.model.confirmingQuit }
        live.close(); try await wait { !live.canReuse }
        let pending = try await makeOwner()
        pending.model.queryCommitStatus = { _, _ in try await withCheckedThrowingContinuation { held = $0 } }
        pending.model.reload(paths: ["."]); try await wait { held != nil }
        pending.close()
        try require(!pending.canReuse && CommitWindowModel.activeReloads > 0 && delegate.applicationShouldTerminate(NSApp) == .terminateCancel, "Retired Commit worker lost its real Quit fence")
        held?.resume(throwing: OperationCancellationFailure.cancelled); held = nil
        try await wait { CommitWindowModel.activeReloads == 0 && CommitWindowModel.activeMetadataOperations == 0 }
        try await waitForQuitReadiness("final retired owner drain"){!retired.canReuse && !live.canReuse && !pending.canReuse}
        try require(delegate.applicationShouldTerminate(NSApp) == .terminateNow && !retiredWindow.isVisible, "Drained retired owners still blocked Quit")
        let finalHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        try require(finalHead == head && (try Data(contentsOf: folder.appendingPathComponent(".git/index"))) == index && (try Data(contentsOf: file)) == Data("working\n".utf8), "Ownership/quit checks mutated repository bytes")
    }
}
