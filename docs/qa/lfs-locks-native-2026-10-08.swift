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
        let defaultsName = "TurtleGit.LFS.StatusQA." + UUID().uuidString
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repository = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repository.run(["init", "-b", "main"])
        _ = try await repository.run(["config", "user.name", "LFS native QA"]); _ = try await repository.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repository.run(["config", "commit.gpgsign", "false"]); _ = try await repository.run(["config", "core.hooksPath", "/dev/null"])
        try Data("retained\n".utf8).write(to: root.appendingPathComponent("tracked")); try await repository.stage(["tracked"]); _ = try await repository.commit(message: "base")
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), head = try await repository.run(["rev-parse", "HEAD"]).stdout
        let controller = LFSLocksWindowController(repository: repository, access: nil, defaults: defaults), model = controller.model, window = controller.window!
        defer { window.close() }
        var server = [LFSLock(id: "1", path: "file2.bin", owner: "QA"), LFSLock(id: "2", path: "雪\t🦎.bin", owner: "Other")]
        var requests: [([String], Bool)] = []
        var standaloneQueries = 0
        model.query = { _ in standaloneQueries += 1; return server }
        model.change = { paths, force, _, report in
            requests.append((paths, force))
            let files = paths.map { path in LFSFileResult(path: path, success: force || path == "file2.bin", output: force || path == "file2.bin" ? "Unlocked" : "owned by another user") }
            for file in files { report(file) }
            server.removeAll { lock in files.contains { $0.path == lock.path && $0.success } }
            return LFSBatchResult(files: files)
        }
        for (name, count) in [("file2.bin",8),("雪\t🦎.bin",16)] {
            try Data(repeating: 120, count: count).write(to: root.appendingPathComponent(name))
        }
        await model.refresh(); precondition(model.error == nil && model.checked == ["1", "2"])
        window.contentView!.layoutSubtreeIfNeeded()
        try await settle { descendants(window.contentView!).contains { $0 is NSTableView } }
        let table = descendants(window.contentView!).compactMap { $0 as? NSTableView }.first!
        precondition(table.numberOfRows == 2 && table.tableColumns.count == 7)
        precondition(MenuIcon.lock.image() != nil && MenuIcon.unlock.image() != nil)
        try await settle { table.headerView?.menu?.item(withTitle: "Filename") != nil && table.tableColumns.filter { !$0.isHidden }.count == 4 }
        func locksProbe() -> CommitFileInteraction.Probe { descendants(window.contentView!).compactMap { $0 as? CommitFileInteraction.Probe }.first! }
        precondition(locksProbe().nativeColumns == LFSLocksWindowModel.columns && locksProbe().itemIDs?.count == 2)
        precondition(table.tableColumns[2].isHidden && table.tableColumns[4].isHidden && table.tableColumns[5].isHidden)
        precondition(locksProbe().columnMenu().item(withTitle: "Status") == nil)
        model.selection = ["2"]
        for (index,column) in LFSLocksWindowModel.columns.enumerated() {
            for ascending in [true,false] {
                let old = table.sortDescriptors, prototype = table.tableColumns[index + 1].sortDescriptorPrototype!
                table.sortDescriptors = [prototype.ascending == ascending ? prototype : prototype.reversedSortDescriptor as! NSSortDescriptor]
                table.dataSource!.tableView?(table, sortDescriptorsDidChange: old)
                try await settle { model.sortOrder.first?.column == column && model.sortOrder.first?.order == (ascending ? .forward : .reverse) }
                precondition(model.checked == ["1","2"] && model.selection == ["2"])
                if column == .fileSize { precondition(model.rows.first!.id == (ascending ? "1" : "2")) }
            }
        }
        let locksFilenameChoice = locksProbe().columnMenu().item(withTitle: "Filename")!
        _ = NSApplication.shared.sendAction(locksFilenameChoice.action!, to: locksFilenameChoice.target, from: locksFilenameChoice)
        try await settle { !table.tableColumns[2].isHidden }
        let locksOwnerColumn = table.tableColumns[6]
        table.moveColumn(6, toColumn: 1); locksOwnerColumn.width = 217
        locksProbe().rememberNativeColumnLayout(adjustedColumn: .lfsOwner)
        let savedLocksColumns = model.fileColumns
        precondition(savedLocksColumns.order.first == .lfsOwner && savedLocksColumns.widths[.lfsOwner] == 217)
        model.setSortOrder([LFSFileSort(column: .lfsOwner)])
        precondition(model.clipboardText(["1","2"], copy: .column(.lfsOwner)) == "Other\nQA\n")
        precondition(model.clipboardText(["1","2"], copy: .relativePaths) == "雪\t🦎.bin\nfile2.bin\n")
        precondition(model.clipboardText(["1"], copy: .pathsAndStatus) == "Path\tStatus\nfile2.bin\tUnknown\n")
        precondition(model.clipboardText(["1"], copy: .fullPaths) == root.appendingPathComponent("file2.bin").path + "\n")
        precondition(model.clipboardText(["2"], copy: .names) == "雪\t🦎.bin\n")
        precondition(model.clipboardText(["1","2"], copy: .all).components(separatedBy: "\n")[0] == model.visibleColumns.map(\.rawValue).joined(separator: "\t"))
        let reopen = LFSLocksWindowController(repository: repository, access: nil, defaults: defaults)
        reopen.model.query = { _ in server }; await reopen.model.refresh()
        reopen.window!.contentView!.layoutSubtreeIfNeeded()
        try await settle {
            let views = descendants(reopen.window!.contentView!)
            guard let table = views.compactMap({ $0 as? NSTableView }).first,
                  let probe = views.compactMap({ $0 as? CommitFileInteraction.Probe }).first else { return false }
            return probe.columnDefinition(atNativeIndex: 1) == .lfsOwner && abs(table.tableColumns[1].width - 217) < 0.5
        }
        precondition(reopen.model.fileColumns == savedLocksColumns); reopen.window?.close()
        try await settle { locksProbe().enabled && locksProbe().columnDefinition(atNativeIndex: 1) == .lfsOwner }
        precondition(locksProbe().fitColumn(atNativeIndex: 1, useDefault: false))
        precondition(model.fileColumns.widths[.lfsOwner] != nil)
        precondition(locksProbe().fitColumn(atNativeIndex: 1, useDefault: true))
        precondition(model.fileColumns.widths[.lfsOwner] == nil)
        let customizedLocksColumns = model.fileColumns
        locksProbe().confirmResetColumns = { owner in precondition(owner === window && model.busy); return false }
        let locksNoReset = locksProbe().columnMenu().item(withTitle: "Reset columns")!
        _ = NSApplication.shared.sendAction(locksNoReset.action!, to: locksNoReset.target, from: locksNoReset)
        try await settle { !model.busy && locksProbe().enabled }
        precondition(model.fileColumns == customizedLocksColumns)
        locksProbe().confirmResetColumns = { owner in
            precondition(owner === window && model.busy)
            model.setColumn(.fileSize, visible: true); precondition(model.fileColumns == customizedLocksColumns)
            return true
        }
        let locksYesReset = locksProbe().columnMenu().item(withTitle: "Reset columns")!
        _ = NSApplication.shared.sendAction(locksYesReset.action!, to: locksYesReset.target, from: locksYesReset)
        try await settle { !model.busy && locksProbe().enabled && model.fileColumns == LFSLocksWindowModel.defaultColumns && locksProbe().columnDefinition(atNativeIndex: 1) == .path && table.tableColumns.filter { !$0.isHidden }.count == 4 }
        model.setColumn(.fileExtension, visible: false); model.setColumn(.lfsOwner, visible: false)
        try await settle { table.tableColumns.filter { !$0.isHidden }.count == 2 }
        precondition(model.clipboardText(["1"], copy: .all) == "Path\nfile2.bin\n")
        precondition(model.clipboardText(["1"], copy: .column(.path)) == "file2.bin\n")
        model.setColumn(.fileExtension, visible: true); model.setColumn(.lfsOwner, visible: true)
        model.setSortOrder([LFSFileSort(column: .path),LFSFileSort(column: .fileSize)]); precondition(model.sortOrder.count == 1)
        model.toggleChecks(["1","2"], mark: "1"); precondition(model.checked.isEmpty && model.selection == ["2"])
        model.toggleChecks(["1","2"], mark: "1"); precondition(model.checked == ["1","2"])

        func allCheckbox() -> NSButton {
            descendants(window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Select/deselect all" }!
        }
        try await settle { descendants(window.contentView!).contains { ($0 as? NSButton)?.title == "Select/deselect all" } }
        let all = allCheckbox()
        try await settle { all.state == .on && all.isEnabled }
        model.selection = ["2"]
        all.performClick(nil); try await settle { model.checked.isEmpty && all.state == .off }
        precondition(model.selection == ["2"] && !model.canUnlock)
        all.performClick(nil); try await settle { model.checked == ["1","2"] && all.state == .on }
        model.setChecked("1", false); try await settle { all.state == .mixed }
        // Source's automatically-created indeterminate state clears on click;
        // users never manually create a third selection state.
        all.performClick(nil); try await settle { model.checked.isEmpty && all.state == .off }
        precondition(model.selection == ["2"])
        model.selectAll(true); try await settle { all.state == .on }
        model.confirmingQuit = true; try await settle { !all.isEnabled && !locksProbe().enabled }
        let guardedColumns = model.fileColumns
        model.setColumn(.fileSize, visible: true); model.setSortOrder([LFSFileSort(column: .fileSize)])
        precondition(model.fileColumns == guardedColumns && model.sortOrder.first!.column == .path)
        all.performClick(nil); precondition(model.checked == ["1","2"])
        model.confirmingQuit = false; try await settle { all.isEnabled }
        model.selectAll(false); precondition(!model.canUnlock); model.setChecked("1", true); precondition(model.canUnlock)
        model.selectAll(true)
        print("LOCKS SORT/RESULT DIAGNOSTIC before", model.sortOrder.map { ($0.column.rawValue,$0.order) }, model.rows.map(\.id)); fflush(stdout)
        let queriesBeforeReview = standaloneQueries
        let locksBeforeReview = model.locks
        await model.unlock()
        print("LOCKS SORT/RESULT DIAGNOSTIC after", model.results.map { ($0.path,$0.success) }, model.locks.map(\.id), model.checked); fflush(stdout)
        precondition(model.results.map(\.success) == [true, false] && model.locks == locksBeforeReview && model.checked == ["1","2"] && standaloneQueries == queriesBeforeReview)
        precondition(requests.count == 1 && !requests[0].1 && Set(requests[0].0) == ["file2.bin", "雪\t🦎.bin"])
        try await settle { window.attachedSheet != nil }
        model.setChecked("1", false); model.selectAll(false); model.setForce(true)
        await model.refresh()
        precondition(!model.canUnlock && model.checked == ["1","2"] && !model.force && standaloneQueries == queriesBeforeReview)
        let delegate = TurtleGitApplicationDelegate()
        precondition(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        await model.unlock(forceRetry: true)
        precondition(requests.count == 2 && requests[1].1 && requests[1].0 == requests[0].0)
        precondition(model.results.allSatisfy(\.success) && model.locks == locksBeforeReview && standaloneQueries == queriesBeforeReview)
        model.finishProgress(); try await settle { window.attachedSheet == nil && !model.busy }
        precondition(model.locks.isEmpty && standaloneQueries == queriesBeforeReview + 1)
        model.finishProgress(); precondition(standaloneQueries == queriesBeforeReview + 1)
        model.confirmingQuit = true; model.selectAll(true); model.setForce(true); await model.unlock(); await model.refresh()
        precondition(requests.count == 2 && !model.force && !controller.windowShouldClose(window))
        model.confirmingQuit = false
        model.query = { _ in throw LFSLocksFailure.selection }; await model.refresh()
        precondition(model.error != nil && model.locks.isEmpty && model.checked.isEmpty)
        try await settle { all.state == .off && !all.isEnabled }
        var cancelledQueries = 0
        model.query = { _ in cancelledQueries += 1; return [LFSLock(id: "3", path: "tracked", owner: "QA")] }; await model.refresh()
        model.change = { paths, _, token, report in
            let file = LFSFileResult(path: paths[0], success: true, output: "Completed before cancellation"); report(file)
            try await Task.sleep(nanoseconds: 100_000_000)
            token.cancel(); return LFSBatchResult(files: [file], cancelled: true)
        }
        let task = Task { await model.unlock() }; try await settle { model.busy && model.results.count == 1 }
        try await settle { !all.isEnabled }
        precondition(!controller.windowShouldClose(window))
        precondition(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        model.setChecked("3", false); model.setForce(true); model.finishProgress()
        precondition(model.checked == ["3"] && !model.force && model.showingProgress)
        await task.value
        precondition(model.results.count == 1 && model.information.contains("Completed server changes remain"))
        precondition(cancelledQueries == 1)
        model.finishProgress(); try await settle { window.attachedSheet == nil && !model.busy }
        precondition(cancelledQueries == 2 && model.results.count == 1)
        window.close()
        let reviewController = LFSLocksWindowController(repository: repository, access: nil, defaults: defaults)
        let reviewModel = reviewController.model
        reviewModel.query = { _ in [LFSLock(id: "review", path: "tracked", owner: "QA")] }; await reviewModel.refresh()
        reviewModel.change = { paths, _, _, _ in LFSBatchResult(files: paths.map { LFSFileResult(path: $0, success: true, output: "Done") }) }
        await reviewModel.unlock()
        let retainedResults = reviewModel.results
        var refreshEntered = false, allowRefresh = false, refreshCount = 0
        reviewModel.query = { token in
            refreshCount += 1; refreshEntered = true
            precondition(!token.isCancelled && reviewController.window?.attachedSheet == nil)
            while !allowRefresh { try await Task.sleep(nanoseconds: 5_000_000) }
            throw LFSLocksFailure.selection
        }
        reviewModel.finishProgress()
        precondition(reviewModel.busy && !reviewModel.showingProgress)
        try await settle { refreshEntered }
        reviewModel.finishProgress(); await reviewModel.unlock(); await reviewModel.refresh()
        precondition(refreshCount == 1 && reviewModel.results.map(\.path) == retainedResults.map(\.path) && reviewModel.results.map(\.success) == retainedResults.map(\.success) && reviewModel.results.map(\.output) == retainedResults.map(\.output) && reviewModel.locks.isEmpty)
        allowRefresh = true; try await settle { !reviewModel.busy }
        precondition(reviewModel.results.map(\.path) == retainedResults.map(\.path) && reviewModel.results.map(\.success) == retainedResults.map(\.success) && reviewModel.results.map(\.output) == retainedResults.map(\.output) && reviewModel.error?.contains("Operation results are retained. Refresh failed:") == true && reviewModel.checked.isEmpty)
        reviewController.window?.close()
        // Source check memory is by path, not remote ID, survives disappearance
        // and failed refresh, and context operations reset only their targets.
        let memoryModel = LFSLocksWindowModel(repository: repository, access: nil, defaults: defaults)
        var memoryReply = [LFSLock(id: "a", path: "file2.bin", owner: "QA"),LFSLock(id: "b", path: "雪\t🦎.bin", owner: "Other")]
        memoryModel.query = { _ in memoryReply }; await memoryModel.refresh()
        memoryModel.setChecked("a", false)
        memoryReply[0] = LFSLock(id: "a2", path: "file2.bin", owner: "QA"); await memoryModel.refresh()
        precondition(memoryModel.checked == ["b"])
        memoryReply.removeFirst(); await memoryModel.refresh()
        memoryReply.insert(LFSLock(id: "a3", path: "file2.bin", owner: "QA"), at: 0)
        memoryReply.append(LFSLock(id: "new", path: "new.bin", owner: "QA")); await memoryModel.refresh()
        precondition(memoryModel.checked == ["b","new"])
        memoryModel.selectAll(false)
        memoryReply.append(LFSLock(id: "later", path: "later.bin", owner: "QA")); await memoryModel.refresh()
        precondition(memoryModel.checked == ["later"])
        memoryModel.query = { _ in throw LFSLocksFailure.selection }; await memoryModel.refresh()
        precondition(memoryModel.checked.isEmpty && memoryModel.locks.isEmpty)
        memoryModel.query = { _ in memoryReply }; await memoryModel.refresh()
        precondition(memoryModel.checked == ["later"])
        memoryModel.change = { paths, _, _, report in
            let files = paths.map { LFSFileResult(path: $0, success: false, output: "Retained lock") }
            for file in files { report(file) }; return LFSBatchResult(files: files)
        }
        await memoryModel.perform(paths: ["file2.bin"], locked: false)
        precondition(memoryModel.checked == ["later"])
        memoryModel.finishProgress(); try await settle { !memoryModel.busy }
        precondition(memoryModel.checked == ["a3","later"])
        memoryModel.setChecked("a3", false)
        await memoryModel.unlock()
        precondition(memoryModel.checked == ["later"])
        memoryModel.finishProgress()
        // Real AppKit viewport and row-index/focus-mark restoration across a
        // cleared/repopulated list; the setting disables position restoration.
        let positionController = LFSLocksWindowController(repository: repository, access: nil, defaults: defaults)
        let positionModel = positionController.model
        var positionReply = (0..<160).map { LFSLock(id: "before-\($0)", path: String(format: "position-%03d.bin",$0), owner: "QA") }
        positionModel.query = { _ in positionReply }; await positionModel.refresh()
        positionController.window!.contentView!.layoutSubtreeIfNeeded()
        try await settle { descendants(positionController.window!.contentView!).contains { $0 is CommitFileInteraction.Probe } }
        let positionTable = descendants(positionController.window!.contentView!).compactMap { $0 as? NSTableView }.first!
        let positionProbe = descendants(positionController.window!.contentView!).compactMap { $0 as? CommitFileInteraction.Probe }.first!
        try await settle { positionTable.numberOfRows == 160 && positionProbe.itemIDs?.count == 160 && positionTable.headerView?.menu != nil }
        precondition(positionModel.saveColumnLayout(order: positionModel.fileColumns.order, widths: [.path:1200]))
        try await settle { abs(positionTable.tableColumns[1].width - 1200) < 0.5 }
        let positionScroll = positionTable.enclosingScrollView!
        positionScroll.layoutSubtreeIfNeeded(); positionTable.layoutSubtreeIfNeeded()
        positionTable.selectRowIndexes(IndexSet([20,22]), byExtendingSelection: false)
        try await settle { positionModel.selection == ["before-20","before-22"] }
        positionProbe.focusedPath?.wrappedValue = "before-22"
        positionScroll.contentView.scroll(to: NSPoint(x:150,y:500)); positionScroll.reflectScrolledClipView(positionScroll.contentView)
        let savedOrigin = positionScroll.contentView.bounds.origin
        precondition(savedOrigin.x > 0 && savedOrigin.y > 0)
        positionModel.setChecked("before-20", false)
        positionReply = (0..<160).map { LFSLock(id: "after-\($0)", path: String(format: "position-%03d.bin",$0), owner: "QA") }
        await positionModel.refresh()
        try await settle { positionModel.selection == ["after-20"] && positionProbe.focusedPath?.wrappedValue == "after-22" && abs(positionScroll.contentView.bounds.origin.x - savedOrigin.x) < 0.5 && abs(positionScroll.contentView.bounds.origin.y - savedOrigin.y) < 0.5 }
        precondition(!positionModel.checked.contains("after-20") && positionModel.checked.count == 159)
        defaults.set(false, forKey: "RememberFileListPosition")
        positionTable.selectRowIndexes(IndexSet(integer:30), byExtendingSelection: false)
        positionProbe.focusedPath?.wrappedValue = "after-30"
        positionScroll.contentView.scroll(to: NSPoint(x:150,y:700)); positionScroll.reflectScrolledClipView(positionScroll.contentView)
        await positionModel.refresh()
        try await settle { positionModel.selection.isEmpty && positionProbe.focusedPath?.wrappedValue == nil && positionScroll.contentView.bounds.origin == .zero }
        precondition(!positionModel.checked.contains("after-20") && positionModel.checked.count == 159)
        defaults.removeObject(forKey: "RememberFileListPosition"); positionController.window?.close()
        // Context actions use highlighted IDs, ignore the dialog Force checkbox,
        // and expose both operations only with the owner column hidden.
        precondition(!model.hasLFS && model.lfsActions(["3"]).isEmpty)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/lfs"), withIntermediateDirectories: true)
        let contextController = LFSLocksWindowController(repository: repository, access: nil, defaults: defaults)
        let contextModel = contextController.model
        let contextReply = [LFSLock(id: "c1", path: "file2.bin", owner: "QA"),LFSLock(id: "c2", path: "雪\t🦎.bin", owner: "Other")]
        contextModel.query = { _ in contextReply }; await contextModel.refresh()
        precondition(contextModel.hasLFS && contextModel.lfsActions(["c2"]) == [.unlock])
        contextModel.setColumn(.lfsOwner, visible: false)
        precondition(contextModel.lfsActions(["c2"]) == [.lock,.unlock] && contextModel.lfsActions(["c2","missing"]).isEmpty)
        contextModel.setForce(true); contextModel.checked = ["c1"]; contextModel.selection = ["c2"]
        var contextLockRequests: [[String]] = [], contextUnlockRequests: [([String],Bool)] = []
        contextModel.lockChange = { paths, _, report in
            precondition(contextModel.checked == ["c1"] && contextModel.selection == ["c2"])
            contextLockRequests.append(paths)
            let files = paths.map { LFSFileResult(path: $0, success: false, output: "Already locked") }
            for file in files { report(file) }; return LFSBatchResult(files: files)
        }
        contextModel.change = { paths, force, _, report in
            contextUnlockRequests.append((paths,force))
            let files = paths.map { LFSFileResult(path: $0, success: force, output: force ? "Unlocked" : "Owned by another user") }
            for file in files { report(file) }; return LFSBatchResult(files: files)
        }
        await contextModel.setSelectionLocked(["c2"], locked: true)
        try await settle { contextController.window?.attachedSheet?.title == "LFS Lock – TurtleGit" }
        precondition(contextLockRequests == [["雪\t🦎.bin"]] && contextModel.operationLocked && contextModel.results.count == 1 && !contextModel.results[0].success)
        await contextModel.unlock(forceRetry: true)
        await contextModel.setSelectionLocked(["c2"], locked: false)
        precondition(contextLockRequests.count == 1 && contextUnlockRequests.isEmpty)
        contextModel.finishProgress(); try await settle { contextController.window?.attachedSheet == nil && !contextModel.busy }
        contextModel.checked = ["c1"]; contextModel.selection = ["c2"]
        await contextModel.setSelectionLocked(["c2"], locked: false)
        try await settle { contextController.window?.attachedSheet?.title == "LFS Unlock – TurtleGit" }
        precondition(contextUnlockRequests.count == 1 && contextUnlockRequests[0].0 == ["雪\t🦎.bin"] && !contextUnlockRequests[0].1 && contextModel.force)
        await contextModel.unlock(forceRetry: true)
        precondition(contextUnlockRequests.count == 2 && contextUnlockRequests[1].0 == contextUnlockRequests[0].0 && contextUnlockRequests[1].1 && contextModel.results[0].success)
        contextModel.finishProgress(); try await settle { contextController.window?.attachedSheet == nil && !contextModel.busy }
        contextModel.checked = ["c1"]; contextModel.selection = ["c2"]
        await contextModel.unlock()
        precondition(contextUnlockRequests.count == 3 && contextUnlockRequests[2].0 == ["file2.bin"] && contextUnlockRequests[2].1)
        contextModel.finishProgress(); try await settle { contextController.window?.attachedSheet == nil && !contextModel.busy }
        contextModel.checked = ["c1"]; contextModel.selection = ["c1","c2"]
        contextModel.setSortOrder([LFSFileSort(column: .lfsOwner)])
        await contextModel.setSelectionLocked(["c1","c2"], locked: false)
        precondition(contextUnlockRequests.count == 4 && contextUnlockRequests[3].0 == ["雪\t🦎.bin","file2.bin"] && !contextUnlockRequests[3].1)
        precondition(contextModel.results.count == 2 && contextModel.results.allSatisfy { !$0.success })
        contextModel.finishProgress(); try await settle { contextController.window?.attachedSheet == nil && !contextModel.busy }
        contextModel.confirmingQuit = true
        await contextModel.setSelectionLocked(["c2"], locked: true)
        precondition(contextLockRequests.count == 1)
        contextModel.confirmingQuit = false; contextController.window?.close()
        // Source OnCmdEnd opens Pull after successful Lock, before result
        // dismissal. Instantiate the actual native options controller; never
        // submit it or run a network transport.
        var pullWindows: [FetchWindowController] = []
        func openNativePull() {
            let pull = FetchWindowController(repository: repository, access: nil, isPull: true, preferences: defaults)
            precondition(pull.model.isPull && pull.model.repository.root == root && pull.model.repository.executable == repository.executable)
            precondition(pull.window!.title.contains(" – Pull – TurtleGit"))
            pull.window!.contentView!.layoutSubtreeIfNeeded()
            precondition(!descendants(pull.window!.contentView!).compactMap { $0 as? NSButton }.isEmpty)
            pullWindows.append(pull); pull.model.load()
        }
        func closeNativePulls() async throws {
            for pull in pullWindows {
                try await settle { !pull.model.busy }
                precondition(pull.model.progress == nil && pull.model.fetchProgress == nil)
                pull.window?.close()
            }
            pullWindows.removeAll()
        }
        let followUpController = LFSLocksWindowController(repository: repository, access: nil, defaults: defaults)
        let followUpModel = followUpController.model
        followUpModel.query = { _ in contextReply }; await followUpModel.refresh()
        var successfulPulls = 0
        followUpController.onPullAfterLock = { [weak followUpController] in
            precondition(!followUpModel.busy && followUpModel.showingProgress && followUpController?.window?.attachedSheet != nil)
            successfulPulls += 1; openNativePull()
        }
        for mode in ["success", "mixed", "cancelled", "tokenCancelled", "throws", "unlock"] {
            followUpModel.lockChange = { paths, token, _ in
                if mode == "throws" { throw LFSLocksFailure.selection }
                if mode == "tokenCancelled" { token.cancel() }
                return LFSBatchResult(files: paths.enumerated().map { offset,path in
                    LFSFileResult(path: path, success: mode != "mixed" || offset == 0, output: mode)
                }, cancelled: mode == "cancelled")
            }
            followUpModel.change = { paths, _, _, _ in LFSBatchResult(files: paths.map { LFSFileResult(path: $0, success: true, output: "Unlocked") }) }
            await followUpModel.perform(paths: ["file2.bin","雪\t🦎.bin"], locked: mode != "unlock")
            precondition(successfulPulls == 1 && pullWindows.count == 1)
            followUpModel.finishProgress(); try await settle { !followUpModel.busy && followUpController.window?.attachedSheet == nil }
            precondition(successfulPulls == 1)
        }
        try await closeNativePulls(); followUpController.window?.close()
        let directoryMenuModel = LFSLocksWindowModel(repository: repository, access: nil, defaults: defaults)
        directoryMenuModel.hasLFS = true; directoryMenuModel.locks = [LFSLock(id: "dir", path: "folder", owner: "QA")]
        directoryMenuModel.fileMetadata = ["folder": StatusListMetadata(modificationDate: nil, size: nil, isDirectory: true)]
        precondition(directoryMenuModel.lfsActions(["dir"]).isEmpty)
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git/lfs"))
        for name in ["file2.bin","雪\t🦎.bin"] { try FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
        // Exercise both actual status-list owners and their production routing.
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git/lfs"), withIntermediateDirectories: true)
        let unusual = "-雪\t\n🦎.bin"
        try Data("untracked LFS candidate\n".utf8).write(to: root.appendingPathComponent(unusual))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        // Existing visibility preferences migrate without writing on read.
        defaults.set(true, forKey: "WorkingTree.LFSOwnerVisible")
        let migratedStatus = StatusWindowModel(repository: repository, access: nil, defaults: defaults)
        precondition(migratedStatus.showLFSOwners && defaults.object(forKey: "WorkingTree.FileColumns.Version") == nil)
        defaults.removeObject(forKey: "WorkingTree.LFSOwnerVisible")
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
        var commitPulls = 0, statusPulls = 0
        commit.onPullAfterLFSLock = {
            precondition(commit.model.busy && commit.window?.attachedSheet === captured?.window && captured?.model.busy == false)
            commitPulls += 1; openNativePull()
        }
        status.onPullAfterLFSLock = {
            precondition(status.model.busy && status.window?.attachedSheet === captured?.window && captured?.model.busy == false)
            statusPulls += 1; openNativePull()
        }
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
        precondition(commitPulls == 1 && statusPulls == 1 && pullWindows.count == 2)
        try await closeNativePulls()
        commit.onPullAfterLFSLock = {}; status.onPullAfterLFSLock = {}
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
        try await settle { descendants(status.window!.contentView!).contains { $0 is CommitFileInteraction.Probe } }
        let statusTable = descendants(status.window!.contentView!).compactMap { $0 as? NSTableView }.first!
        try await settle { statusTable.headerView?.menu?.item(withTitle: "LFS Lock") != nil }
        let statusOwner = statusTable.tableColumns.first { $0.headerCell.stringValue == "LFS Lock" }!
        try await settle { statusTable.tableColumns.count == 9 && statusOwner.isHidden }
        precondition(statusTable.tableColumns.filter { !$0.isHidden }.count == 6)
        precondition(statusTable.tableColumns[1].isHidden && statusTable.tableColumns[7].isHidden)
        func statusProbe() -> CommitFileInteraction.Probe { descendants(status.window!.contentView!).compactMap { $0 as? CommitFileInteraction.Probe }.first! }
        precondition(statusProbe().leadingColumnCount == 0 && !statusProbe().keyboardDeleteEnabled)
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
        let sortColumns = StatusListColumn.allCases
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
        // Real header visibility/order/width fitting and reopened native table.
        let filenameChoice = statusTable.headerView!.menu!.item(withTitle: "Filename")!
        _ = NSApplication.shared.sendAction(filenameChoice.action!, to: filenameChoice.target, from: filenameChoice)
        try await settle { !statusTable.tableColumns[1].isHidden }
        let sizeChoice = statusTable.headerView!.menu!.item(withTitle: "File size")!
        _ = NSApplication.shared.sendAction(sizeChoice.action!, to: sizeChoice.target, from: sizeChoice)
        try await settle { !statusTable.tableColumns[7].isHidden }
        precondition(status.model.sortedRows.allSatisfy { $0.metadata?.size != nil })
        status.model.setSortOrder([StatusFileSort(column: .fileSize)])
        let sizes = status.model.sortedRows.map { $0.metadata!.size! }
        precondition(sizes == sizes.sorted())
        status.model.setSortOrder([StatusFileSort(column: .lfsOwner)])
        let allIDs: Set<String> = [unusual,"unlocked.bin"]
        precondition(status.model.clipboardText(allIDs, copy: .column(.lfsOwner)) == "Alice\nZebra\n")
        precondition(status.model.clipboardText(allIDs, copy: .relativePaths) == "unlocked.bin\n" + unusual + "\n")
        precondition(status.model.clipboardText(allIDs, copy: .names) == "unlocked.bin\n" + unusual + "\n")
        precondition(status.model.clipboardText(allIDs, copy: .fullPaths) == root.appendingPathComponent("unlocked.bin").path + "\n" + root.appendingPathComponent(unusual).path + "\n")
        statusTable.moveColumn(8, toColumn: 0); statusOwner.width = 217
        statusProbe().rememberNativeColumnLayout(adjustedColumn: .lfsOwner)
        let savedStatusColumns = status.model.fileColumns
        precondition(savedStatusColumns.order.first == .lfsOwner && savedStatusColumns.widths[.lfsOwner] == 217)
        try await settle { statusProbe().columnDefinition(atNativeIndex: 0) == .lfsOwner }
        let headings = status.model.clipboardText(allIDs, copy: .all).components(separatedBy: "\n")[0]
        precondition(headings == status.model.visibleColumns.map(\.rawValue).joined(separator: "\t") && headings.hasPrefix("LFS Lock\t"))
        let restoredStatus = StatusWindowController(repository: repository, access: nil, defaults: defaults)
        restoredStatus.model.queryLFSOwners = { _ in statusReply }
        restoredStatus.model.reload(); try await settle { !restoredStatus.model.busy && restoredStatus.model.hasLFS }
        restoredStatus.window!.contentView!.layoutSubtreeIfNeeded()
        try await settle {
            let views = descendants(restoredStatus.window!.contentView!)
            guard let table = views.compactMap({ $0 as? NSTableView }).first,
                  let probe = views.compactMap({ $0 as? CommitFileInteraction.Probe }).first else { return false }
            return probe.columnDefinition(atNativeIndex: 0) == .lfsOwner && !table.tableColumns[0].isHidden && abs(table.tableColumns[0].width - 217) < 0.5
        }
        precondition(restoredStatus.model.fileColumns == savedStatusColumns)
        restoredStatus.window?.close()
        precondition(statusProbe().fitColumn(atNativeIndex: 0, useDefault: false))
        try await settle { !status.model.busy && statusProbe().enabled }
        precondition(status.model.fileColumns.widths[.lfsOwner] != nil)
        precondition(statusProbe().fitColumn(atNativeIndex: 0, useDefault: true))
        precondition(status.model.fileColumns.widths[.lfsOwner] == nil)
        let customizedStatusColumns = status.model.fileColumns
        statusProbe().confirmResetColumns = { owner in precondition(owner === status.window && status.model.busy); return false }
        let noReset = statusProbe().columnMenu().item(withTitle: "Reset columns")!
        _ = NSApplication.shared.sendAction(noReset.action!, to: noReset.target, from: noReset)
        try await settle { !status.model.busy && statusProbe().enabled }
        precondition(status.model.fileColumns == customizedStatusColumns)
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
        // Confirmed reset restores the source six-column default and clears
        // adjusted widths/order; calls during the question remain blocked.
        statusProbe().confirmResetColumns = { owner in
            precondition(owner === status.window && status.model.busy)
            let before = status.model.fileColumns
            status.model.setColumn(.fileSize, visible: false)
            precondition(status.model.fileColumns == before)
            return true
        }
        if !statusProbe().enabled { print("RESET TARGET WAIT: model busy", status.model.busy, "native target enabled", statusProbe().enabled); fflush(stdout) }
        try await settle { statusProbe().enabled && !status.model.busy }
        let yesReset = statusProbe().columnMenu().item(withTitle: "Reset columns")!
        _ = NSApplication.shared.sendAction(yesReset.action!, to: yesReset.target, from: yesReset)
        try await settle { !status.model.busy && status.model.fileColumns == StatusWindowModel.defaultColumns && statusProbe().columnDefinition(atNativeIndex: 0) == .path && statusTable.tableColumns.filter { !$0.isHidden }.count == 6 }
        precondition(StatusWindowModel(repository: repository, access: nil, defaults: defaults).fileColumns == StatusWindowModel.defaultColumns)
        for column in StatusWindowModel.defaultColumns.visible where column != .path { status.model.setColumn(column, visible: false) }
        precondition(status.model.clipboardText(["unlocked.bin"], copy: .all) == "Path\nunlocked.bin\n")
        precondition(status.model.clipboardText(["unlocked.bin"], copy: .column(.path)) == "unlocked.bin\n")
        for column in StatusWindowModel.defaultColumns.visible where column != .path { status.model.setColumn(column, visible: true) }
        commit.window?.close(); status.window?.close()
        // Resolve shares the same three-state helper; use a separate real
        // conflicted repository and activate only selection controls.
        let resolveRoot = root.deletingLastPathComponent().appendingPathComponent("resolve-" + root.lastPathComponent)
        try FileManager.default.createDirectory(at: resolveRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: resolveRoot) }
        let resolveRepo = GitRepository(root: resolveRoot, executable: repository.executable)
        _ = try await resolveRepo.run(["init","-b","main"])
        _ = try await resolveRepo.run(["config","user.name","Resolve checkbox QA"])
        _ = try await resolveRepo.run(["config","user.email","qa@example.invalid"])
        _ = try await resolveRepo.run(["config","commit.gpgsign","false"])
        _ = try await resolveRepo.run(["config","core.hooksPath","/dev/null"])
        for path in ["a","b"] { try Data("base\n".utf8).write(to: resolveRoot.appendingPathComponent(path)) }
        try await resolveRepo.stage(["a","b"]); _ = try await resolveRepo.commit(message: "base")
        _ = try await resolveRepo.run(["checkout","-b","other"])
        for path in ["a","b"] { try Data("other\n".utf8).write(to: resolveRoot.appendingPathComponent(path)) }
        try await resolveRepo.stage(["a","b"]); _ = try await resolveRepo.commit(message: "other")
        _ = try await resolveRepo.run(["checkout","main"])
        for path in ["a","b"] { try Data("main\n".utf8).write(to: resolveRoot.appendingPathComponent(path)) }
        try await resolveRepo.stage(["a","b"]); _ = try await resolveRepo.commit(message: "main")
        _ = try await resolveRepo.run(["merge","-m","conflict","other"], successfulExitCodes: 0...1)
        let resolveIndex = try Data(contentsOf: resolveRoot.appendingPathComponent(".git/index"))
        let resolve = ResolveWindowController(repository: resolveRepo, access: nil, paths: [])
        defer { resolve.window?.close() }
        resolve.model.load(); try await settle { !resolve.model.busy && resolve.model.entries.count == 2 }
        resolve.window!.contentView!.layoutSubtreeIfNeeded()
        try await settle { descendants(resolve.window!.contentView!).contains { ($0 as? NSButton)?.title == "Select/deselect all" } }
        let resolveAll = descendants(resolve.window!.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Select/deselect all" }!
        try await settle { resolveAll.state == .on && resolveAll.isEnabled && !resolve.model.busy }
        resolveAll.performClick(nil); try await settle { resolve.model.checked.isEmpty && resolveAll.state == .off }
        resolveAll.performClick(nil); try await settle { resolve.model.checked == ["a","b"] && resolveAll.state == .on }
        resolve.model.checked = ["a"]; try await settle { resolveAll.state == .mixed }
        resolveAll.performClick(nil); try await settle { resolve.model.checked.isEmpty && resolveAll.state == .off }
        resolve.model.busy = true; try await settle { !resolveAll.isEnabled }
        resolveAll.performClick(nil); precondition(resolve.model.checked.isEmpty)
        resolve.model.busy = false; resolve.window?.close()
        let resolveAfterIndex = try Data(contentsOf: resolveRoot.appendingPathComponent(".git/index"))
        precondition(resolveAfterIndex == resolveIndex)
        let afterHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        let afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let afterFile = try Data(contentsOf: root.appendingPathComponent("tracked"))
        precondition(afterHead == head && index == afterIndex)
        precondition(afterFile == Data("retained\n".utf8))
        print("PASS: hidden native LFS Locks window/table, original lock/unlock artwork, checked targets/select-all, injected mixed per-file outcomes and refresh, captured force retry targets, actual progress-sheet ownership and Quit refusal, busy/confirmation guards, refresh failure and cancellation with retained completed results. HEAD/raw index/working contents retained; owned window/sheet closed. Commit and Working Tree selection gating, Lock/Unlock captured routing and attached progress/Force retry validated. No real LFS server/helper or physical input acceptance claimed.")
    }
}
