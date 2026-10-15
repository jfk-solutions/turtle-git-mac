import AppKit
import Darwin
import TurtleGitCore

struct ComparisonOutputOwnershipVerification {
    @MainActor static func wait(_ predicate: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<2000 { if predicate() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        preconditionFailure("Compare output did not settle at line \(line)")
    }
    @MainActor static func run(root: URL, git: URL) async throws {
        let suite = "TurtleGit.OutputOwnership." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let directory = root.appendingPathComponent("output-ownership")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = directory.appendingPathComponent("base.txt"), mine = directory.appendingPathComponent("mine.txt")
        let before = Data("base\n".utf8), after = Data("mine\nno newline".utf8)
        try before.write(to: base); try after.write(to: mine)
        let initialCount = FileComparisonWindowModel.activePaneExports
        @MainActor func owner() async throws -> FileComparisonWindowController {
            let owner = FileComparisonWindowController(comparison: try WorkingFileComparison(base: base, destination: mine), permissions: [])
            owner.model.comparisonDefaults = preferences
            owner.model.load()
            try await wait { !owner.model.busy && !owner.model.filtering && owner.model.document != nil }
            return owner
        }
        for patch in [false, true] {
            let controller = try await owner(), model = controller.model
            defer { controller.close() }
            model.patchExecutable = git
            var pending: CheckedContinuation<URL?, Never>?, prompts = 0
            let choose: (NSWindow, String, URL) async -> URL? = { window, name, folder in
                precondition(window === controller.window && folder.standardizedFileURL.path == directory.standardizedFileURL.path)
                precondition(name == (patch ? "mine.txt.diff" : "mine.txt"))
                prompts += 1
                return await withCheckedContinuation { pending = $0 }
            }
            if patch { model.choosePatchLocation = choose } else { model.chooseExportLocation = choose }
            @MainActor func start() { if patch { model.createUnifiedPatch() } else { model.export(base: false) } }
            let target = directory.appendingPathComponent(patch ? "unified.diff" : "copy.txt")
            let sentinel = Data("keep existing destination".utf8); try sentinel.write(to: target)
            start(); try await wait { pending != nil }
            precondition(model.exporting && FileComparisonWindowModel.activePaneExports == initialCount + 1)
            precondition(!controller.windowShouldClose(controller.window!))
            precondition(TurtleGitApplicationDelegate().applicationShouldTerminate(.shared) == .terminateCancel)
            // A parent can independently publish busy=false. The owned choice
            // must still fence operations rather than trusting that flag alone.
            model.busy = false
            let document = model.document, encoding = model.encoding(base: false), pane = model.activeBase
            let draft = model.draftText(base: false)
            model.export(base: true); model.createUnifiedPatch(); model.load()
            model.activatePane(base: true); model.editingEnabled = true; model.changeEncoding(.utf16LEBOM, base: false)
            model.updateDraft("must not replace", base: false)
            var saveReply: Bool?; model.save { saveReply = $0 }
            precondition(saveReply == false && prompts == 1 && model.exporting && !model.canCreateUnifiedPatch)
            precondition(model.encoding(base: false) == encoding && model.activeBase == pane && model.draftText(base: false) == draft)
            precondition(model.document?.base.bytes == document?.base.bytes && model.document?.destination.bytes == document?.destination.bytes)
            model.cancelOutput(); pending!.resume(returning: target); pending = nil
            try await wait { !model.exporting }
            let canceledBytes = try Data(contentsOf: target); precondition(canceledBytes == sentinel)
            precondition(model.error == nil && FileComparisonWindowModel.activePaneExports == initialCount)
            start(); try await wait { pending != nil }; pending!.resume(returning: target); pending = nil
            try await wait { !model.exporting }
            let bytes = try Data(contentsOf: target)
            if patch {
                precondition(bytes.range(of: Data("--- a/base.txt".utf8)) != nil && bytes.range(of: Data("+++ b/mine.txt".utf8)) != nil)
                precondition(bytes.range(of: Data("+mine".utf8)) != nil && bytes.range(of: Data("No newline at end of file".utf8)) != nil)
            } else { precondition(bytes == after) }
            precondition(prompts == 2 && model.error == nil && FileComparisonWindowModel.activePaneExports == initialCount)
            start(); try await wait { pending != nil }
            controller.close()
            precondition(FileComparisonWindowModel.activePaneExports == initialCount + 1)
            precondition(TurtleGitApplicationDelegate().applicationShouldTerminate(.shared) == .terminateCancel)
            pending!.resume(returning: target); pending = nil
            try await wait { FileComparisonWindowModel.activePaneExports == initialCount }
            let lateBytes = try Data(contentsOf: target); precondition(lateBytes == bytes)
            precondition(model.error == nil)
            print("PASS: \(patch ? "unified patch" : "pane copy") captured output, bounded owner, duplicate/operation guards despite busy overwrite, Cancel/retry, forced-close late reply and Quit lifetime")
        }
        do {
            let controller = try await owner(), model = controller.model
            defer { controller.close() }
            let marker = directory.appendingPathComponent("generator.pid"), shim = directory.appendingPathComponent("held-git")
            let target = directory.appendingPathComponent("canceled-generator.diff"), sentinel = Data("existing patch".utf8)
            try sentinel.write(to: target)
            let quotedMarker = "'" + marker.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
            let script = "#!/bin/sh\nprintf '%s\\n' \"$$\" > " + quotedMarker + "\nwhile :; do /bin/sleep 1; done\n"
            try Data(script.utf8).write(to: shim); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shim.path)
            model.patchExecutable = shim; model.choosePatchLocation = { _, _, _ in target }
            model.createUnifiedPatch(); try await wait { FileManager.default.fileExists(atPath: marker.path) }
            let pid = pid_t(try String(contentsOf: marker).trimmingCharacters(in: .newlines))!
            precondition(FileComparisonWindowModel.activePaneExports == initialCount + 1)
            model.cancelOutput(); try await wait { !model.exporting }
            try await wait { kill(pid, 0) == -1 && errno == ESRCH }
            try await wait { kill(-pid, 0) == -1 && errno == ESRCH }
            let bytes = try Data(contentsOf: target)
            precondition(bytes == sentinel && model.error == nil && FileComparisonWindowModel.activePaneExports == initialCount)
            print("PASS: active unified-diff generator Cancel reaps its exact process group, preserves destination and suppresses cancellation error")
        }
        let controller = try await owner(), model = controller.model
        defer { controller.close() }
        model.activatePane(base: false); model.editingEnabled = true
        try await wait { model.canTransfer(toBase: false) }
        let originalEncoding = model.encoding(base: false), originalDraft = model.draftText(base: false)
        model.chooseFormat = { _, _, _ in nil }; model.showFormatDialog(base: false)
        try await wait { !model.hasPendingEditorChoice }
        precondition(model.encoding(base: false) == originalEncoding && model.draftText(base: false) == originalDraft)
        model.chooseFormat = { _, _, _ in .init(encoding: .utf16BEBOM, ending: .crlf) }
        model.showFormatDialog(base: false)
        try await wait { !model.hasPendingEditorChoice && !model.filtering }
        precondition(model.encoding(base: false) == .utf16BEBOM && model.draftText(base: false) == "mine\r\nno newline")
        var formatReply: CheckedContinuation<MergeFormatSelection?, Never>?, calls = 0
        model.chooseFormat = { _, _, _ in calls += 1; return await withCheckedContinuation { formatReply = $0 } }
        let encoding = model.encoding(base: false), draft = model.draftText(base: false)
        model.showFormatDialog(base: false); try await wait { formatReply != nil }
        precondition(model.hasPendingEditorChoice && FileComparisonWindowModel.activePaneExports == initialCount + 1)
        model.showFormatDialog(base: false); model.export(base: false); model.createUnifiedPatch(); model.changeEncoding(.utf16BEBOM, base: false)
        precondition(calls == 1 && !model.exporting && model.encoding(base: false) == encoding)
        precondition(!controller.windowShouldClose(controller.window!))
        controller.close()
        precondition(FileComparisonWindowModel.activePaneExports == initialCount + 1)
        formatReply!.resume(returning: .init(encoding: .utf16BEBOM, ending: .crlf)); formatReply = nil
        try await wait { FileComparisonWindowModel.activePaneExports == initialCount }
        precondition(model.encoding(base: false) == encoding && model.draftText(base: false) == draft)
        let finalBase = try Data(contentsOf: base), finalMine = try Data(contentsOf: mine)
        precondition(finalBase == before && finalMine == after)
        print("PASS: held format transaction fences output/reentry/mutations and normal close; forced retirement keeps Quit ownership until stale reply settles, disk/draft/encoding unchanged")
    }
}
