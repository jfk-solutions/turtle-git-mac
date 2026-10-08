import AppKit
import SwiftUI
import TurtleGitCore

@main struct LFSLocksVerification {
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func settle(line: Int = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        print("LFS WINDOW DIAGNOSTIC", line, NSApplication.shared.windows.map { ($0.title, $0.attachedSheet?.title ?? "none", $0.isVisible, descendants($0.contentView ?? NSView()).compactMap { $0 as? NSTableView }.map(\.numberOfRows)) }); fflush(stdout)
        preconditionFailure("LFS native condition did not settle at line \(line)")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repository = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repository.run(["init", "-b", "main"])
        _ = try await repository.run(["config", "user.name", "LFS native QA"]); _ = try await repository.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repository.run(["config", "commit.gpgsign", "false"]); _ = try await repository.run(["config", "core.hooksPath", "/dev/null"])
        try Data("retained\n".utf8).write(to: root.appendingPathComponent("tracked")); try await repository.stage(["tracked"]); _ = try await repository.commit(message: "base")
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repository.run(["rev-parse", "HEAD"]).stdout
        let controller = LFSLocksWindowController(repository: repository, access: nil), model = controller.model, window = controller.window!
        defer { window.close() }
        var server = [LFSLock(id: "1", path: "file2.bin", owner: "QA"), LFSLock(id: "2", path: "雪\t🦎.bin", owner: "Other")]
        var requests: [([String], Bool)] = []
        model.query = { _ in server }
        model.change = { paths, force, _, report in
            requests.append((paths, force))
            let files = paths.map { path in LFSFileResult(path: path, success: force || path == "file2.bin", output: force || path == "file2.bin" ? "Unlocked" : "owned by another user") }
            for file in files { report(file) }
            server.removeAll { lock in files.contains { $0.path == lock.path && $0.success } }
            return LFSBatchResult(files: files)
        }
        await model.refresh(); precondition(model.error == nil && model.checked == ["1", "2"])
        window.contentView!.layoutSubtreeIfNeeded()
        try await settle { descendants(window.contentView!).contains { $0 is NSTableView } }
        let table = descendants(window.contentView!).compactMap { $0 as? NSTableView }.first!
        precondition(table.numberOfRows == 2 && table.tableColumns.count == 4)
        precondition(MenuIcon.lock.image() != nil && MenuIcon.unlock.image() != nil)
        model.selectAll(false); precondition(!model.canUnlock); model.setChecked("1", true); precondition(model.canUnlock)
        model.selectAll(true); await model.unlock()
        precondition(model.results.map(\.success) == [true, false] && model.locks == [server[0]] && model.checked == ["2"])
        precondition(requests.count == 1 && !requests[0].1 && Set(requests[0].0) == ["file2.bin", "雪\t🦎.bin"])
        try await settle { window.attachedSheet != nil }
        let delegate = TurtleGitApplicationDelegate()
        precondition(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        await model.unlock(forceRetry: true)
        precondition(requests.count == 2 && requests[1].1 && requests[1].0 == requests[0].0)
        precondition(model.results.allSatisfy(\.success) && model.locks.isEmpty)
        model.finishProgress(); try await settle { window.attachedSheet == nil }
        model.confirmingQuit = true; model.selectAll(true); model.setForce(true); await model.unlock(); await model.refresh()
        precondition(requests.count == 2 && !model.force && !controller.windowShouldClose(window))
        model.confirmingQuit = false
        model.query = { _ in throw LFSLocksFailure.selection }; await model.refresh()
        precondition(model.error != nil && model.locks.isEmpty && model.checked.isEmpty)
        model.query = { _ in [LFSLock(id: "3", path: "tracked", owner: "QA")] }; await model.refresh()
        model.change = { paths, _, token, report in
            let file = LFSFileResult(path: paths[0], success: true, output: "Completed before cancellation"); report(file)
            try await Task.sleep(nanoseconds: 100_000_000)
            token.cancel(); return LFSBatchResult(files: [file], cancelled: true)
        }
        let task = Task { await model.unlock() }; try await settle { model.busy && model.results.count == 1 }
        precondition(!controller.windowShouldClose(window))
        precondition(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        model.setChecked("3", false); model.setForce(true); model.finishProgress()
        precondition(model.checked == ["3"] && !model.force && model.showingProgress)
        await task.value
        precondition(model.results.count == 1 && model.information.contains("Completed server changes remain"))
        model.finishProgress(); try await settle { window.attachedSheet == nil }; window.close()
        let afterHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let afterFile = try Data(contentsOf: root.appendingPathComponent("tracked"))
        precondition(afterHead == head && index == afterIndex)
        precondition(afterFile == Data("retained\n".utf8))
        print("PASS: hidden native LFS Locks window/table, original lock/unlock artwork, checked targets/select-all, injected mixed per-file outcomes and refresh, captured force retry targets, actual progress-sheet ownership and Quit refusal, busy/confirmation guards, refresh failure and cancellation with retained completed results. HEAD/raw index/working contents retained; owned window/sheet closed. No real LFS server/helper or physical input acceptance claimed.")
    }
}
