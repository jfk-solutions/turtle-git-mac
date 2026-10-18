// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

enum MergeReflectedPatchVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(line: UInt = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<1800 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Reflected patch timeout at line \(line)")
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.MergeReflectedPatch." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let repositoryRoot = root.appendingPathComponent("working tree"), unrelatedRoot = root.appendingPathComponent("other tree")
        try FileManager.default.createDirectory(at: repositoryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelatedRoot, withIntermediateDirectories: true)
        _ = try await GitRepository(root: repositoryRoot, executable: git).run(["init", "--quiet"])
        _ = try await GitRepository(root: unrelatedRoot, executable: git).run(["init", "--quiet"])
        let base = root.appendingPathComponent("temporary base"), mine = root.appendingPathComponent("temporary mine")
        let old = Data("old\r\nunchanged\r\n".utf8), new = Data("new\r\nunchanged\r\n".utf8)
        try old.write(to: base); try new.write(to: mine)
        var owners: [FileComparisonWindowController] = []
        defer { for owner in owners { owner.close() } }
        func owner(baseName: String, mineName: String) throws -> FileComparisonWindowController {
            let request = try MergeToolInvocation.parse(arguments: ["--merge-tool", "--base", base.path, "--mine", mine.path,
                "--readonly", "--basereflectedname", baseName, "--minereflectedname", mineName], currentDirectory: root.path)!
            let value = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [], preferences: preferences, deferInitialLoad: true)
            owners.append(value); value.model.editorConfigEnabled = [true: false, false: false]
            value.model.patchExecutable = git; value.model.saveFolderAccess.requireScope = false
            try value.model.configureMergeTool(request)
            value.window!.alphaValue = 0; value.window!.orderFront(nil); value.model.beginTransferredDocument()
            return value
        }
        let reflected = repositoryRoot.appendingPathComponent("nested/actual.txt")
        let editor = try owner(baseName: reflected.path, mineName: reflected.path), model = editor.model
        try await wait { !model.busy && !model.filtering && model.document != nil }
        try require(model.mergeToolReadOnly && model.canCreateUnifiedPatch, "Readonly comparison cannot create its source-supported patch")
        let output = root.appendingPathComponent("reflected.diff")
        var choices = 0
        model.choosePatchLocation = { _, _, _ in choices += 1; return output }
        model.createUnifiedPatch()
        try await wait { !model.mergeToolHasPendingWork }
        try require(choices == 1 && model.error == nil && FileManager.default.fileExists(atPath: output.path), "Native reflected patch export failed: " + (model.error ?? "no output"))
        let patch = try Data(contentsOf: output), text = String(decoding: patch, as: UTF8.self)
        try require(text.hasPrefix("diff --git \"a/nested/actual.txt\" \"b/nested/actual.txt\"\nindex ") && text.contains("\n--- \"a/nested/actual.txt\"\n+++ \"b/nested/actual.txt\"\n@@ "), "Native export retained temporary paths instead of reflected names")
        try require(model.document?.base.path == base.path && model.document?.destination.path == mine.path && !model.dirty && !model.mergeToolSaved, "Patch export changed input/output ownership or saved the Git merge result")
        try FileManager.default.createDirectory(at: reflected.deletingLastPathComponent(), withIntermediateDirectories: true)
        try old.write(to: reflected)
        _ = try await GitRepository(root: repositoryRoot, executable: git).run(["apply", "--", output.path])
        try require((try Data(contentsOf: reflected)) == new, "Exported reflected patch did not apply to its repository-relative file")
        let first = repositoryRoot.appendingPathComponent("before.txt"), second = repositoryRoot.appendingPathComponent("after.txt")
        let swapped = try owner(baseName: first.path, mineName: second.path)
        try await wait { !swapped.model.busy && !swapped.model.filtering && swapped.model.document != nil }
        swapped.model.switchSides()
        try await wait { !swapped.model.busy && !swapped.model.filtering && swapped.model.document?.base.path == mine.path }
        let swappedOutput = root.appendingPathComponent("swapped.diff")
        swapped.model.choosePatchLocation = { _, _, _ in swappedOutput }
        swapped.model.createUnifiedPatch(); try await wait { !swapped.model.mergeToolHasPendingWork }
        let swappedText = String(decoding: try Data(contentsOf: swappedOutput), as: UTF8.self)
        try require(swapped.model.error == nil && swappedText.hasPrefix("diff --git \"a/after.txt\" \"b/before.txt\"\n"), "Switch sides detached reflected names from their active panes")
        try require(swappedText.contains("-new\r\n+old\r\n"), "Switch sides did not reverse the saved comparison input payload")
        let other = unrelatedRoot.appendingPathComponent("actual.txt")
        let mismatch = try owner(baseName: reflected.path, mineName: other.path)
        try await wait { !mismatch.model.busy && !mismatch.model.filtering && mismatch.model.document != nil }
        let fallbackOutput = root.appendingPathComponent("fallback.diff")
        mismatch.model.choosePatchLocation = { _, _, _ in fallbackOutput }
        mismatch.model.createUnifiedPatch(); try await wait { !mismatch.model.mergeToolHasPendingWork }
        let fallback = String(decoding: try Data(contentsOf: fallbackOutput), as: UTF8.self)
        try require(mismatch.model.error == nil && !fallback.contains("nested/actual.txt") && fallback.contains("temporary base") && fallback.contains("temporary mine"), "Different repository reflected names overrode generated source labels")
        let cancelled = try owner(baseName: reflected.path, mineName: reflected.path)
        try await wait { !cancelled.model.busy && !cancelled.model.filtering && cancelled.model.document != nil }
        let cancelledOutput = root.appendingPathComponent("cancelled.diff")
        var answer: CheckedContinuation<URL?, Never>?
        cancelled.model.choosePatchLocation = { _, _, _ in await withCheckedContinuation { answer = $0 } }
        cancelled.model.createUnifiedPatch(); try await wait { answer != nil }
        cancelled.close()
        try require(cancelled.model.mergeToolHasPendingWork, "Retired native export lost the pending chooser")
        answer?.resume(returning: cancelledOutput); answer = nil
        try await wait { !cancelled.model.mergeToolHasPendingWork }
        try require(!FileManager.default.fileExists(atPath: cancelledOutput.path), "Late reflected export choice wrote after retirement")
        for owner in owners { owner.close() }
        try await wait { owners.allSatisfy { !$0.model.mergeToolHasPendingWork } }
        try require((try Data(contentsOf: base)) == old && (try Data(contentsOf: mine)) == new, "Reflected patch export modified selected inputs")
        print("PASS: native reflected patch export, readonly comparison, applicable Git-relative headers, unchanged inputs/result ownership, swapped pane metadata, cross-repository fallback and cancelled chooser drain")
    }
}
