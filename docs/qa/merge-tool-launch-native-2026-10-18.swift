// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

enum MergeToolLaunchVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description: message) } }
    @MainActor static func wait(line: Int = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<3000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Merge-tool launch timeout at \(line)")
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.MergeToolLaunch." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let base = root.appendingPathComponent("base [literal]\nfile"), mine = root.appendingPathComponent("mine file"), output = root.appendingPathComponent("merged file")
        try Data("before\nshared\n".utf8).write(to: base); try Data("after\nshared\n".utf8).write(to: mine)
        let originalMine = try Data(contentsOf: mine)
        let workspace = RepositoryModel(startMonitoring: false, initializePreferences: false)
        workspace.fileComparisonPreferences = prefs
        var shown: [NSWindowController] = [], completions: [Int32] = []
        workspace.configureMergeToolLaunch = { session in
            session.requiresScopes = false; session.executable = { git }
            session.configurePatchWorkflow = { workflow in workflow.chooseBetterTarget = { _, _ in .original } }
            session.presentation = { controller in shown.append(controller); controller.window?.alphaValue = 0; controller.window?.orderFront(nil) }
        }
        defer { workspace.stopMonitoringForTermination(); shown.forEach { $0.close() } }
        func launch(_ arguments: [String]) throws {
            workspace.error = nil
            try require(workspace.handleMergeToolCommandLine(arguments: ["--merge-tool"] + arguments, currentDirectory: root.path, completion: { completions.append($0) }), "Merge invocation not recognized")
        }
        func pair() async throws -> FileComparisonWindowController {
            try await wait { shown.last is FileComparisonWindowController }
            let controller = shown.last as! FileComparisonWindowController
            try await wait { !controller.model.mergeToolHasPendingWork && controller.model.document != nil && !controller.model.filtering }
            return controller
        }
        try require(!workspace.handleMergeToolCommandLine(arguments: ["--command=log", "--path", root.path], currentDirectory: root.path), "Merge parser consumed repository command")
        try launch(["--base", base.path, "--mine", mine.path, "--readonly", "--oneway", "--basename", "Original", "--minename", "Changed", "--line", "2"])
        let readonly = try await pair()
        try require(readonly.model.mergeToolReadOnly && readonly.model.paneTitle(base: true) == "Original" && readonly.model.document?.destination.path == mine.path, "Launch lost labels, paths or readonly policy")
        let originalWindow = readonly.window
        try readonly.replaceEditor(.compare(base: mine, mine: base, single: false), permissions: [RepositoryAccessLease(url: root)])
        try await wait { workspace.mergeToolLaunches.values.first?.editor !== readonly }
        let replacement = workspace.mergeToolLaunches.values.first!.editor as! FileComparisonWindowController
        try await wait { !replacement.model.mergeToolHasPendingWork && replacement.model.document != nil && !replacement.model.filtering }
        try require(replacement.window === originalWindow && readonly.window == nil && replacement.model.mergeToolReadOnly && replacement.model.onePaneActive && replacement.model.paneTitle(base: true) != "Original", "Open replacement lost current owner, readonly/view policy or reset names")
        replacement.close(); try await wait { completions.count == 1 && workspace.mergeToolLaunches.isEmpty }
        try require(completions.last == 0 && (try Data(contentsOf: mine)) == originalMine, "Readonly compare close changed input or exit status")
        shown = []
        try launch(["--base", base.path, "--mine", mine.path, "--merged", output.path, "--saverequired"])
        let writable = try await pair(); var saved: Bool?
        writable.model.save { saved = $0 }; try await wait { saved != nil && !writable.model.mergeToolHasPendingWork }
        try require(saved == true && (try Data(contentsOf: output)) == originalMine && (try Data(contentsOf: mine)) == originalMine, "Session output did not save separately")
        writable.close(); try await wait { completions.count == 2 && workspace.mergeToolLaunches.isEmpty }
        try require(completions.last == 0, "Accepted saved output did not return success")
        // Accepted Don't Save/Open resets the editor, while the original Git result remains failed.
        let abandonedOutput = root.appendingPathComponent("abandoned-result")
        shown = []; try launch(["--base", base.path, "--mine", mine.path, "--merged", abandonedOutput.path, "--saverequired"])
        let abandoned = try await pair()
        try abandoned.replaceEditor(.compare(base: mine, mine: base, single: false), permissions: [RepositoryAccessLease(url: root)])
        try await wait { workspace.mergeToolLaunches.values.first?.editor !== abandoned }
        let opened = workspace.mergeToolLaunches.values.first!.editor as! FileComparisonWindowController
        try await wait { !opened.model.mergeToolHasPendingWork && opened.model.document != nil && !opened.model.filtering }
        try require(!opened.model.dirty && workspace.mergeToolLaunches.values.first?.completionStatus == 1, "Open erased the original unsaved Git result obligation")
        opened.close(); try await wait { completions.count == 3 && workspace.mergeToolLaunches.isEmpty }
        try require(completions.last == 1 && !FileManager.default.fileExists(atPath: abandonedOutput.path), "Discarded original result became successful or wrote an output")
        // Explicit cleanup preserves modified inputs and the configured output.
        let scratchBase = root.appendingPathComponent("cleanup-base"), scratchMine = root.appendingPathComponent("cleanup-mine"), scratchOutput = root.appendingPathComponent("cleanup-output")
        try Data("base\n".utf8).write(to: scratchBase); try Data("mine\n".utf8).write(to: scratchMine)
        shown = []; try launch(["--base", scratchBase.path, "--mine", scratchMine.path, "--merged", scratchOutput.path, "--saverequired", "--deletebasetheirsmineonclose"])
        let cleanup = try await pair(); saved = nil; cleanup.model.save { saved = $0 }; try await wait { saved == true && !cleanup.model.mergeToolHasPendingWork }
        try Data("external edit\n".utf8).write(to: scratchBase); cleanup.close()
        try await wait { completions.count == 4 && workspace.mergeToolLaunches.isEmpty }
        try require(FileManager.default.fileExists(atPath: scratchBase.path) && !FileManager.default.fileExists(atPath: scratchMine.path) && (try Data(contentsOf: scratchOutput)) == Data("mine\n".utf8), "Owned cleanup removed changed input/output or retained unchanged temporary input")
        // Byte-oriented unified output uses the same finite completion protocol.
        let patchFile = root.appendingPathComponent("review.patch")
        try launch(["--createunifieddiff", "--origfile", base.path, "--modifiedfile", mine.path, "--outfile", patchFile.path])
        try await wait { completions.count == 5 && workspace.mergeToolLaunches.isEmpty }
        let patchBytes = try Data(contentsOf: patchFile)
        try require(completions.last == 0 && String(decoding: patchBytes, as: UTF8.self).contains("+after"), "Unified command did not write reviewed patch bytes")
        // Source reverse/readonly and labels reach the actual patch parent and child.
        let target = root.appendingPathComponent("patch-target"); try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let sample = target.appendingPathComponent("sample"); try Data("after\n".utf8).write(to: sample)
        let left = root.appendingPathComponent("patch-left"), right = root.appendingPathComponent("patch-right")
        try Data("before\n".utf8).write(to: left); try Data("after\n".utf8).write(to: right)
        let reviewBytes = try await MergeUnifiedPatch.create(base: WorkingFileComparison.workingContent(at: left), destination: WorkingFileComparison.workingContent(at: right), baseLabel: "sample", destinationLabel: "sample", executable: git)
        try reviewBytes.write(to: patchFile); shown = []
        try launch(["--diff", patchFile.path, "--patchpath", target.path, "--readonly", "--reversedpatch", "--patchoriginal", "Original", "--patchpatched", "Patched"])
        try await wait { shown.last is WorkingTreePatchWindowController }
        let review = shown.last as! WorkingTreePatchWindowController
        try await wait { !review.model.busy && review.model.review != nil }
        try require(review.model.reversed && review.model.mergeToolReadOnly && review.model.mergeToolOriginalLabel == "Original" && !review.model.canApply && !review.model.canSaveDraft && !review.model.canResolveSpecial, "Patch entry lost reversed/readonly/source captions")
        review.model.apply(); review.model.saveDraft(); try require((try Data(contentsOf: sample)) == Data("after\n".utf8), "Readonly patch entry mutated target")
        review.close(); try await wait { completions.count == 6 && workspace.mergeToolLaunches.isEmpty }
        // A cancelled, noncooperative authorization retains lifetime and refuses late presentation.
        var authorization: CheckedContinuation<RepositoryAccessLease?, Error>?
        workspace.configureMergeToolLaunch = { session in
            session.requiresScopes = false; session.executable = { git }
            session.authorize = { _, _ in try await withCheckedThrowingContinuation { authorization = $0 } }
            session.presentation = { _ in fatalError("Cancelled launch presented a late editor") }
        }
        try launch(["--base", base.path, "--mine", mine.path])
        try await wait { authorization != nil }
        workspace.mergeToolLaunches.values.first!.cancel()
        try require(workspace.hasPendingRepositoryWork && completions.count == 6, "Cancelled authorization was released before its real reply")
        authorization?.resume(returning: RepositoryAccessLease(url: root)); authorization = nil
        try await wait { completions.count == 7 && workspace.mergeToolLaunches.isEmpty && MergeToolLaunchSession.activePreparations == 0 }
        try require(completions.last == 1 && (try Data(contentsOf: mine)) == originalMine, "Late authorization changed result or input")
        // Empty source entry owns Open and retains an outstanding native path choice through close.
        workspace.configureMergeToolLaunch = { session in
            session.requiresScopes = false; session.executable = { git }
            session.presentation = { controller in shown.append(controller); controller.window?.alphaValue = 0; controller.window?.orderFront(nil) }
        }
        shown = []; try launch([])
        try await wait { shown.last is MergeOpenWindowController }
        let open = shown.last as! MergeOpenWindowController
        var pathChoice: CheckedContinuation<URL?, Never>?
        open.choosePath = { _, _ in await withCheckedContinuation { pathChoice = $0 } }; open.browse(.base)
        try await wait { pathChoice != nil && open.pendingChoices == 1 }
        open.close(); try require(completions.count == 7 && workspace.hasPendingRepositoryWork, "Open discarded a still-owned chooser worker")
        pathChoice?.resume(returning: base); pathChoice = nil
        try await wait { completions.count == 8 && workspace.mergeToolLaunches.isEmpty && open.pendingChoices == 0 }
        try require(completions.last == 1 && open.base.stringValue.isEmpty && open.window?.isVisible == false, "Retired Open choice changed a field or revived its owner")
        // Default Save As has an owned ownerless panel and one-shot retirement.
        var outputReply: ((NSApplication.ModalResponse) -> Void)?
        var sawOwnerlessPanel = false
        workspace.configureMergeToolLaunch = { session in
            session.requiresScopes = false; session.executable = { git }
            session.presentOutputPanel = { _, owner, reply in sawOwnerlessPanel = owner == nil; outputReply = reply }
            session.selectedOutputURL = { _ in root.appendingPathComponent("cancelled.patch") }
        }
        try launch(["--createunifieddiff", "--origfile", base.path, "--modifiedfile", mine.path])
        try await wait { outputReply != nil }
        let pendingOutput = workspace.mergeToolLaunches.values.first!
        try require(sawOwnerlessPanel && pendingOutput.outputPanel != nil && workspace.hasPendingRepositoryWork, "Ownerless Save As was skipped or lost ownership")
        pendingOutput.cancel(); try await wait { completions.count == 9 && workspace.mergeToolLaunches.isEmpty }
        outputReply?(.OK); outputReply = nil
        try require(completions.count == 9 && completions.last == 1 && !FileManager.default.fileExists(atPath: root.appendingPathComponent("cancelled.patch").path), "Retired Save As callback wrote output or completed twice")
        let chosenPatch = root.appendingPathComponent("chosen.patch")
        workspace.configureMergeToolLaunch = { session in
            session.requiresScopes = false; session.executable = { git }
            session.presentOutputPanel = { _, _, reply in reply(.OK) }; session.selectedOutputURL = { _ in chosenPatch }
        }
        try launch(["--createunifieddiff", "--origfile", base.path, "--modifiedfile", mine.path])
        try await wait { completions.count == 10 && workspace.mergeToolLaunches.isEmpty }
        try require(completions.last == 0 && (try Data(contentsOf: chosenPatch)) == patchBytes, "Ownerless Save As acceptance lost exact unified bytes")
        // A recognized request with no loaded document must not report success on close.
        workspace.configureMergeToolLaunch = { session in
            session.requiresScopes = false; session.executable = { git }
            session.presentation = { controller in shown.append(controller); controller.window?.alphaValue = 0 }
        }
        shown = []; try launch(["--base", target.path, "--mine", mine.path, "--readonly"])
        try await wait { shown.last is FileComparisonWindowController }
        let failed = shown.last as! FileComparisonWindowController
        try await wait { !failed.model.mergeToolHasPendingWork && failed.model.error != nil }
        try require(failed.model.document == nil && workspace.mergeToolLaunches.values.first?.completionStatus == 1, "Failed comparison load became successful tool completion")
        failed.model.error = nil; try await wait { failed.window?.attachedSheet == nil }
        failed.close(); try await wait { completions.count == 11 && workspace.mergeToolLaunches.isEmpty && failed.window?.isVisible == false }
        try require(completions.last == 1, "Failed comparison close returned success")
        // Real startup dispatch chooses the Merge route once and uses injected process exit only after close.
        workspace.configureMergeToolLaunch = { session in
            session.requiresScopes = false; session.executable = { git }
            session.presentation = { controller in shown.append(controller); controller.window?.alphaValue = 0; controller.window?.orderFront(nil) }
        }
        let startup = TurtleGitApplicationDelegate(); var exitStatus: Int32?
        startup.startupArguments = ["--merge-tool", "--base", base.path, "--mine", mine.path, "--readonly"]
        startup.startupDirectory = root.path; startup.startupMergeToolExit = { exitStatus = $0 }
        shown = []; startup.repositoryModel = workspace; startup.startupDidFinishLaunching()
        let started = try await pair(); try require(exitStatus == nil, "Startup returned before the editor finished")
        let quitReply = startup.applicationShouldTerminate(NSApp)
        try require(quitReply == .terminateLater, "Standalone Quit bypassed owned completion: reply=\(quitReply.rawValue), windows=\(NSApp.windows.map { "\(type(of:$0)),visible=\($0.isVisible),sheet=\($0.attachedSheet != nil),delegate=\(String(describing:$0.delegate))" }), fileSessions=\(FileListComparisonSession.activeOperations), paneExports=\(FileComparisonWindowModel.activePaneExports)")
        try await wait { exitStatus != nil && workspace.mergeToolLaunches.isEmpty }
        try require(exitStatus == 0 && startup.startupDelivered && started.window?.isVisible == false, "Startup Merge Quit did not deliver exact exit after close")
        print("PASS: Merge tool launch: source routing, labels, exact private grants, separate saved output, changed-input cleanup fencing, raw unified output, reverse/readonly patch entry, held cancellation drain, failed-load exit and one-shot startup process completion")
    }
}
