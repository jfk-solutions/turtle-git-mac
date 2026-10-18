// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// The command's frame policy survives actual two/three-file Open handoffs,
/// while each new document drops the previous output/name/save obligation.
enum MergeToolContinuityVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }
    @MainActor static func wait(line: Int = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<3000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Merge continuity timeout at \(line)")
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.MergeContinuity." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        let workspace = RepositoryModel(startMonitoring: false, initializePreferences: false)
        workspace.fileComparisonPreferences = prefs
        let files = ["base", "theirs", "mine", "output", "new-base", "new-theirs", "new-mine"].map { root.appendingPathComponent($0) }
        for (index, file) in files.enumerated() { try Data(("source \(index)\nshared\n").utf8).write(to: file) }
        let originals = try files.map { try Data(contentsOf: $0) }
        var shown: [NSWindowController] = [], status: Int32?
        workspace.configureMergeToolLaunch = { session in
            session.requiresScopes = false; session.executable = { git }
            session.presentation = { controller in shown.append(controller); controller.window?.alphaValue = 0; controller.window?.orderFront(nil) }
        }
        defer {
            workspace.stopMonitoringForTermination()
            for controller in shown { controller.close() }
            for session in workspace.mergeToolLaunches.values { session.cancel() }
            prefs.removePersistentDomain(forName: suite)
        }
        let args = ["--merge-tool", "--base", files[0].path, "--theirs", files[1].path, "--mine", files[2].path,
                    "--merged", files[3].path, "--blame", "--saverequired", "--basename", "Old Base",
                    "--theirsname", "Old Theirs", "--minename", "Old Mine", "--mergedname", "Old Result",
                    "--basereflectedname", "/display/base", "--theirsreflectedname", "/display/theirs",
                    "--minereflectedname", "/display/mine", "--mergedreflectedname", "/display/result", "--line", "2"]
        try require(workspace.handleMergeToolCommandLine(arguments: args, currentDirectory: root.path, completion: { status = $0 }), "Command not selected")
        try await wait { shown.last is TextConflictWindowController }
        let first = shown.last as! TextConflictWindowController
        try await wait { first.model.document != nil && !first.model.mergeToolHasPendingWork }
        let window = first.window!
        try require(first.model.mergeToolPaneTitle("fallback", mine: true) == "Old Mine" && first.model.mergeToolPaneLocation(result: true) == "/display/result", "Initial source metadata missing")
        try first.replaceEditor(.compare(base: files[4], mine: files[6], single: false), permissions: [RepositoryAccessLease(url: root)])
        try await wait { workspace.mergeToolLaunches.values.first?.editor is FileComparisonWindowController }
        let pair = workspace.mergeToolLaunches.values.first!.editor as! FileComparisonWindowController
        shown.append(pair)
        try await wait { pair.model.document != nil && !pair.model.mergeToolHasPendingWork && !pair.model.filtering }
        try require(pair.window === window && first.window == nil && pair.model.mergeToolReadOnly && pair.model.mergeToolBlame, "Three-to-two handoff lost frame or Blame policy")
        try require(pair.model.paneTitle(base: false) != "Old Mine" && pair.model.document?.destination.path == files[6].path, "Replacement retained old document metadata/path")
        try require(pair.model.canSwitchSides, "Fixture cannot switch the current two-file frame")
        pair.model.switchSides()
        try await wait { !pair.model.mergeToolHasPendingWork && !pair.model.filtering && pair.model.mergeToolReflectedName(base: true) == "/display/mine" }
        try pair.replaceEditor(.merge(base: files[4], theirs: files[5], mine: files[6]), permissions: [RepositoryAccessLease(url: root)])
        try await wait { workspace.mergeToolLaunches.values.first?.editor is TextConflictWindowController }
        let next = workspace.mergeToolLaunches.values.first!.editor as! TextConflictWindowController
        shown.append(next)
        try await wait { next.model.document != nil && !next.model.mergeToolHasPendingWork }
        try require(next.window === window && pair.window == nil && next.model.mergeToolReadOnly && next.model.mergeToolBlame, "Two-to-three handoff lost immutable frame policy")
        try require(next.model.mergeToolInvocation == nil && !next.model.mergeToolRequiresSave && next.model.workingMergeOutput == nil, "Replacement reapplied old output/required-save/line invocation")
        try require(next.model.mergeToolPaneTitle("new mine", mine: true) == "new mine", "Replacement retained descriptive title")
        try require(next.model.mergeToolPaneLocation() == "/display/mine" && next.model.mergeToolPaneLocation(mine: false) == "/display/theirs" && next.model.mergeToolPaneLocation(mine: true) == "/display/base" && next.model.mergeToolPaneLocation(result: true) == "/display/result", "Three-file reflected frame names did not survive Open")
        try require(next.model.workingMerge?.mineURL.path == files[6].path && next.model.workingMerge?.baseURL.path == files[4].path, "Reflected display metadata replaced actual inputs")
        let before = next.model.result
        next.model.save(markResolved: false)
        try require(next.model.result == before && !next.model.busy, "Read-only replacement entered Save")
        next.close()
        try await wait { status != nil && workspace.mergeToolLaunches.isEmpty && shown.allSatisfy { ($0 as? TextConflictWindowController)?.model.mergeToolHasPendingWork != true && ($0 as? FileComparisonWindowController)?.model.mergeToolHasPendingWork != true } }
        try require(status == 1, "Discarded original Git result was silently reported successful")
        for (file, bytes) in zip(files, originals) { try require(try Data(contentsOf: file) == bytes, "Frame metadata handoff changed an input/output") }
        print("PASS: actual three/two/three-file frame handoffs preserve reflected/Blame policy, reset document obligations and drain current ownership")
    }
}
