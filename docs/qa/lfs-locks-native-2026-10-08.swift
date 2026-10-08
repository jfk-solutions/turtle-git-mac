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
        // Exercise both actual status-list owners and their production routing.
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/lfs"), withIntermediateDirectories: true)
        let unusual = "-雪\t\n🦎.bin"
        try Data("untracked LFS candidate\n".utf8).write(to: root.appendingPathComponent(unusual))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        let defaultsName = "TurtleGit.LFS.StatusQA." + UUID().uuidString
        let defaults = UserDefaults(suiteName: defaultsName)!
        let commit = CommitWindowController(repository: repository, access: nil, defaults: defaults)
        let status = StatusWindowController(repository: repository, access: nil, defaults: defaults)
        defer { defaults.removePersistentDomain(forName: defaultsName); commit.window?.close(); status.window?.close() }
        commit.model.reload(); status.model.reload()
        try await settle { !commit.model.busy && !status.model.busy && commit.model.hasLFS && status.model.hasLFS }
        let entry = commit.model.entries.first { $0.path == unusual }!
        precondition(commit.model.canLockLFS([entry]))
        precondition(!LFSLockingSelection.isAvailable([entry], hasLFS: false, root: root, directories: []))
        precondition(!LFSLockingSelection.isAvailable([entry], hasLFS: true, root: root, directories: [unusual]))
        let folderEntry = StatusEntry.parse(Data("?? folder\0".utf8))[0]
        let conflictEntry = StatusEntry.parse(Data("UU tracked\0".utf8))[0]
        precondition(!LFSLockingSelection.isAvailable([folderEntry], hasLFS: true, root: root, directories: []))
        precondition(!LFSLockingSelection.isAvailable([entry, folderEntry], hasLFS: true, root: root, directories: []))
        precondition(!LFSLockingSelection.isAvailable([conflictEntry], hasLFS: true, root: root, directories: []))
        commit.model.confirmingQuit = true
        commit.model.setLFSLocked([unusual], locked: true)
        precondition(!commit.model.busy)
        commit.model.confirmingQuit = false
        var captured: LFSFileOperationController?
        var operations: [([String], Bool, Bool)] = []
        let factory: (GitRepository, RepositoryAccessLease?) -> LFSFileOperationController = { repository, access in
            let controller = LFSFileOperationController(repository: repository, access: access)
            controller.model.query = { _ in preconditionFailure("Hidden owner-column operation must not query remote locks") }
            controller.model.lockChange = { paths, _, report in
                operations.append((paths, true, false))
                let result = LFSFileResult(path: paths[0], success: true, output: "Locked")
                report(result); return LFSBatchResult(files: [result])
            }
            controller.model.change = { paths, force, _, report in
                operations.append((paths, false, force))
                let result = LFSFileResult(path: paths[0], success: force, output: force ? "Unlocked" : "owned by another user")
                report(result); return LFSBatchResult(files: [result])
            }
            captured = controller; return controller
        }
        commit.makeLFSOperation = factory; status.makeLFSOperation = factory
        for locked in [true, false] {
            commit.model.setLFSLocked([unusual], locked: locked)
            try await settle { captured?.model.showingProgress == true && captured?.model.busy == false }
            let operation = captured!
            precondition(commit.window?.attachedSheet === operation.window && commit.model.busy)
            precondition(operation.model.operationLocked == locked && operations.last!.0 == [unusual] && operations.last!.1 == locked && !operations.last!.2)
            precondition(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
            let count = operations.count; commit.model.setLFSLocked([unusual], locked: !locked)
            precondition(operations.count == count)
            if !locked {
                commit.model.selection = []
                await operation.model.unlock(forceRetry: true)
                precondition(operations.last!.0 == [unusual] && operations.last!.2)
            }
            operation.model.finishProgress()
            try await settle { commit.window?.attachedSheet == nil && !commit.model.busy }
            captured = nil
        }
        status.model.confirmingQuit = true
        status.model.setLFSLocked([unusual], locked: true)
        precondition(captured == nil && !status.model.busy && !status.windowShouldClose(status.window!))
        status.model.confirmingQuit = false
        status.model.setLFSLocked([unusual, "not-a-row"], locked: true)
        precondition(captured == nil && !status.model.busy)
        status.model.setLFSLocked([unusual], locked: true)
        try await settle { captured?.model.showingProgress == true && captured?.model.busy == false }
        let operation = captured!
        precondition(status.window?.attachedSheet === operation.window && status.model.busy)
        precondition(!status.windowShouldClose(status.window!))
        precondition(operations.last!.0 == [unusual] && operations.last!.1)
        operation.model.finishProgress()
        try await settle { status.window?.attachedSheet == nil && !status.model.busy }
        captured = nil
        // Original header action controls the optional ninth text column.
        func ownerProbe() -> CommitFileInteraction.Probe {
            descendants(commit.window!.contentView!).compactMap { $0 as? CommitFileInteraction.Probe }.first!
        }
        try Data("unlocked candidate\n".utf8).write(to: root.appendingPathComponent("unlocked.bin"))
        var ownerQueries = 0
        commit.model.queryLFSOwners = { _ in
            ownerQueries += 1
            return [LFSLock(id: "owner", path: unusual, owner: "Alice")]
        }
        commit.model.reload(); try await settle { !commit.model.busy }
        precondition(ownerQueries == 0 && !commit.model.visibleFileColumns.contains(.lfsOwner))
        try await settle { descendants(commit.window!.contentView!).contains { $0 is CommitFileInteraction.Probe } }
        let ownerTable = descendants(commit.window!.contentView!).compactMap { $0 as? NSTableView }.first!
        try await settle { ownerTable.tableColumns.count == 10 && ownerProbe().columnMenu().item(withTitle: "LFS Lock") != nil }
        let savedChecks = commit.model.checked
        commit.model.selection = [unusual]
        let ownerItem = ownerProbe().columnMenu().item(withTitle: "LFS Lock")!
        _ = NSApplication.shared.sendAction(ownerItem.action!, to: ownerItem.target, from: ownerItem)
        try await settle { !commit.model.busy && commit.model.lfsOwnershipKnown }
        precondition(ownerQueries == 1 && commit.model.lfsOwners[unusual] == "Alice" && commit.model.checked == savedChecks && commit.model.selection == [unusual])
        let lockedEntry = commit.model.entries.first { $0.path == unusual }!, freeEntry = commit.model.entries.first { $0.path == "unlocked.bin" }!
        precondition(commit.model.lfsActions([lockedEntry]) == [.unlock] && commit.model.lfsActions([freeEntry]) == [.lock] && commit.model.lfsActions([lockedEntry,freeEntry]).isEmpty)
        let ownerColumn = ownerTable.tableColumns.first { $0.headerCell.stringValue == "LFS Lock" }!
        precondition(!ownerColumn.isHidden)
        let text = StatusListClipboard.text([lockedEntry], root: root, statistics: [:], copy: .column(.lfsOwner), lfsOwners: commit.model.lfsOwners)
        precondition(text == "Alice\n")
        ownerColumn.width = 217
        ownerProbe().rememberNativeColumnLayout(adjustedColumn: .lfsOwner)
        let restored = CommitWindowModel(repository: repository, access: nil, unversionedDefaults: defaults, dialogDefaults: defaults)
        precondition(restored.fileColumns.visible.contains(.lfsOwner) && restored.fileColumns.widths[.lfsOwner] == 217)
        // Error and cancellation use an unhosted model to avoid showing the
        // production error alert during headless acceptance.
        let failureModel = CommitWindowModel(repository: repository, access: nil, unversionedDefaults: defaults, dialogDefaults: defaults)
        failureModel.queryLFSOwners = { _ in throw LFSLocksFailure.selection }
        failureModel.reload(); try await settle { !failureModel.busy }
        precondition(failureModel.error != nil && !failureModel.lfsOwnershipKnown && failureModel.lfsOwners.isEmpty && failureModel.lfsActions([freeEntry]).isEmpty)
        var querying = false
        failureModel.queryLFSOwners = { token in
            querying = true
            while !token.isCancelled { try await Task.sleep(nanoseconds: 5_000_000) }
            return [LFSLock(id: "stale", path: unusual, owner: "Stale")]
        }
        failureModel.reload(); try await settle { querying && failureModel.busy }
        failureModel.cancel(closeWindow: false)
        try await settle { !failureModel.busy }
        precondition(!failureModel.lfsOwnershipKnown && failureModel.lfsOwners.isEmpty)
        let hide = ownerProbe().columnMenu().item(withTitle: "LFS Lock")!
        _ = NSApplication.shared.sendAction(hide.action!, to: hide.target, from: hide)
        try await settle { ownerColumn.isHidden }
        precondition(commit.model.lfsActions([lockedEntry,freeEntry]) == [.lock,.unlock])
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git/lfs"))
        commit.model.reload(); try await settle { !commit.model.busy && !commit.model.hasLFS }
        try await settle { ownerProbe().columnMenu().item(withTitle: "LFS Lock") == nil }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/lfs"), withIntermediateDirectories: true)
        var statusQueries = 0
        var statusReply = [LFSLock(id: "status-owner", path: unusual, owner: "")]
        status.model.queryLFSOwners = { _ in statusQueries += 1; return statusReply }
        status.model.reload(); try await settle { !status.model.busy && status.model.hasLFS }
        precondition(statusQueries == 0 && !status.model.ownersVisible)
        try await settle { descendants(status.window!.contentView!).contains { $0 is WorkingTreeLFSColumn.Probe } }
        let statusTable = descendants(status.window!.contentView!).compactMap { $0 as? NSTableView }.first!
        try await settle { statusTable.headerView?.menu?.item(withTitle: "LFS Lock") != nil }
        let statusOwner = statusTable.tableColumns.first { $0.headerCell.stringValue == "LFS Lock" }!
        try await settle { statusTable.tableColumns.count == 7 && statusOwner.isHidden }
        let statusChoice = statusTable.headerView!.menu!.item(withTitle: "LFS Lock")!
        status.model.selection = [unusual]
        _ = NSApplication.shared.sendAction(statusChoice.action!, to: statusChoice.target, from: statusChoice)
        try await settle { !status.model.busy && status.model.lfsOwnershipKnown && !statusOwner.isHidden }
        let statusLocked = status.model.visibleFiles.first { $0.id == unusual }!, statusFree = status.model.visibleFiles.first { $0.id == "unlocked.bin" }!
        precondition(statusQueries == 1 && status.model.selection == [unusual] && status.model.lfsOwners[unusual] == "")
        precondition(status.model.lfsActions([statusLocked]) == [.unlock] && status.model.lfsActions([statusFree]) == [.lock] && status.model.lfsActions([statusLocked,statusFree]).isEmpty)
        precondition(StatusWindowModel(repository: repository, access: nil, defaults: defaults).showLFSOwners)
        statusReply = [LFSLock(id: "z", path: unusual, owner: "Zebra"), LFSLock(id: "a", path: "unlocked.bin", owner: "Alice")]
        status.model.reload(); try await settle { !status.model.busy }
        precondition(status.model.sortedRows.allSatisfy { $0.fileExtension == ".bin" })
        let sortColumns: [StatusListColumn] = [.path,.fileExtension,.status,.added,.removed,.lastModified,.lfsOwner]
        for (index, column) in sortColumns.enumerated() {
            for ascending in [true,false] {
                let old = statusTable.sortDescriptors, prototype = statusTable.tableColumns[index].sortDescriptorPrototype!
                statusTable.sortDescriptors = [prototype.ascending == ascending ? prototype : prototype.reversedSortDescriptor as! NSSortDescriptor]
                statusTable.dataSource!.tableView?(statusTable, sortDescriptorsDidChange: old)
                try await settle { status.model.sortOrder.first?.column == column && status.model.sortOrder.first?.order == (ascending ? .forward : .reverse) }
                if column == .lfsOwner { precondition(status.model.sortedRows.first!.id == (ascending ? "unlocked.bin" : unusual)) }
                precondition(status.model.selection == [unusual])
            }
        }
        status.model.setSortOrder([StatusFileSort(column: .lfsOwner),StatusFileSort(column: .path)])
        precondition(status.model.sortOrder.count == 1)
        status.model.confirmingQuit = true
        status.model.setSortOrder([StatusFileSort(column: .path)])
        status.model.setShowLFSOwners(false)
        precondition(status.model.sortOrder[0].column == .lfsOwner && status.model.showLFSOwners)
        status.model.confirmingQuit = false
        // The selected batch must follow the displayed owner sort, rather
        // than Git's original path order or unordered selection-set iteration.
        status.model.setLFSLocked([unusual,"unlocked.bin"], locked: false)
        try await settle { captured?.model.showingProgress == true && captured?.model.busy == false }
        precondition(operations.last!.0 == ["unlocked.bin",unusual] && !operations.last!.1)
        captured!.model.finishProgress()
        try await settle { status.window?.attachedSheet == nil && !status.model.busy }
        captured = nil
        let statusFailure = StatusWindowModel(repository: repository, access: nil, defaults: defaults)
        statusFailure.queryLFSOwners = { _ in throw LFSLocksFailure.selection }
        statusFailure.reload(); try await settle { !statusFailure.busy }
        precondition(statusFailure.error != nil && statusFailure.lfsOwners.isEmpty && !statusFailure.lfsOwnershipKnown && statusFailure.lfsActions([statusFree]).isEmpty)
        var statusQueryActive = false
        status.model.queryLFSOwners = { token in
            statusQueryActive = true
            while !token.isCancelled { try await Task.sleep(nanoseconds: 5_000_000) }
            return [LFSLock(id: "late", path: unusual, owner: "Late")]
        }
        status.model.reload(); try await settle { statusQueryActive && status.model.busy }
        precondition(!status.windowShouldClose(status.window!))
        try await settle { !status.model.busy }
        precondition(status.model.lfsOwners.isEmpty && !status.model.lfsOwnershipKnown)
        let statusHide = statusTable.headerView!.menu!.item(withTitle: "LFS Lock")!
        _ = NSApplication.shared.sendAction(statusHide.action!, to: statusHide.target, from: statusHide)
        try await settle { statusOwner.isHidden }
        precondition(status.model.lfsActions([statusLocked,statusFree]) == [.lock,.unlock])
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git/lfs"))
        status.model.reload(); try await settle { !status.model.busy && !status.model.hasLFS }
        try await settle { statusTable.headerView?.menu?.item(withTitle: "LFS Lock") == nil }
        commit.window?.close(); status.window?.close()
        let afterHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let afterFile = try Data(contentsOf: root.appendingPathComponent("tracked"))
        precondition(afterHead == head && index == afterIndex)
        precondition(afterFile == Data("retained\n".utf8))
        print("PASS: hidden native LFS Locks window/table, original lock/unlock artwork, checked targets/select-all, injected mixed per-file outcomes and refresh, captured force retry targets, actual progress-sheet ownership and Quit refusal, busy/confirmation guards, refresh failure and cancellation with retained completed results. HEAD/raw index/working contents retained; owned window/sheet closed. Commit and Working Tree selection gating, Lock/Unlock captured routing and attached progress/Force retry validated. No real LFS server/helper or physical input acceptance claimed.")
    }
}
