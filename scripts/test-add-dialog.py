#!/usr/bin/env python3
"""Actual Add models/table receiver; displays no windows or menus."""
import pathlib, platform, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parent.parent
frameworks = root / 'build/Build/Products/Debug'
driver = r'''
import AppKit
import SwiftUI
import TurtleGitCore
@main struct Verify {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let repo = GitRepository(root: folder)
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Add QA"])
        _ = try await repo.run(["config", "user.email", "add@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        try Data("*.log\n".utf8).write(to: folder.appendingPathComponent(".gitignore"))
        try await repo.stage([".gitignore"]); _ = try await repo.commit(message: "base")
        let file = "new 雪\n.txt", unchecked = "unchecked.txt", ignored = "ignored.log"
        for path in [file, unchecked, ignored] { try Data(path.utf8).write(to: folder.appendingPathComponent(path)) }
        let model = AddWindowModel(repository: repo, access: nil); model.setScope(["."])
        try await model.read(); precondition(model.checked == [file, unchecked] && !model.entries.contains { $0.path == ignored })
        model.checked.remove(unchecked); try await model.read(); precondition(!model.checked.contains(unchecked))
        model.includeIgnored = true; try await model.read(); precondition(model.entries.contains { $0.path == ignored } && !model.checked.contains(ignored))
        model.checked.insert(ignored)
        let receiver = AddFileTable.Coordinator(model: model), scroll = receiver.make()
        precondition(receiver.table.tableColumns.map(\.title) == ["", "Path", "Extension", "Size", "Modification date"])
        precondition(receiver.numberOfRows(in: receiver.table) == 3 && scroll.documentView === receiver.table)
        precondition((receiver.table as? NativeWatermarkTable)?.watermarkImage != nil)
        let watermarkDomain = "TurtleGitAddWatermark-" + UUID().uuidString
        let watermarkDefaults = UserDefaults(suiteName: watermarkDomain)!
        defer { watermarkDefaults.removePersistentDomain(forName: watermarkDomain) }
        let watermark = NativeWatermarkTable(icon: .addBackdrop, defaults: watermarkDefaults)
        precondition(watermark.backdropRect(in: NSRect(x: 0, y: 0, width: 300, height: 240)) == NSRect(x: 172, y: 112, width: 128, height: 128))
        precondition(watermark.backdropRect(in: NSRect(x: 20, y: 70, width: 300, height: 240)) == NSRect(x: 192, y: 182, width: 128, height: 128))
        watermarkDefaults.set(false, forKey: "ShowListBackgroundImage"); precondition(watermark.backdropRect(in: NSRect(x: 0, y: 0, width: 300, height: 240)) == nil)
        watermarkDefaults.removeObject(forKey: "ShowListBackgroundImage")
        let artwork = MenuIcon.addBackdrop.image(size: 128)!; precondition(!artwork.isTemplate)
        var imageRect = NSRect(x: 0, y: 0, width: 128, height: 128)
        let pixels = NSBitmapImageRep(cgImage: artwork.cgImage(forProposedRect: &imageRect, context: nil, hints: nil)!)
        precondition(pixels.hasAlpha && pixels.colorAt(x: 0, y: 0)!.alphaComponent < 0.01)
        precondition((0..<pixels.pixelsHigh).contains { y in (0..<pixels.pixelsWide).contains { x in
            let color = pixels.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            return color.alphaComponent > 0.1 && color.alphaComponent < 0.9 && abs(color.redComponent - color.blueComponent) > 0.1
        } })
        try pixels.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/turtlegit-add-background-128.png"))
        let index = receiver.rows.firstIndex { $0.path == unchecked }!
        let checkbox = receiver.tableView(receiver.table, viewFor: receiver.table.tableColumns[0], row: index) as! NSButton
        precondition(checkbox.identifier?.rawValue == unchecked && checkbox.state == .off)
        checkbox.state = .on; receiver.toggleRow(checkbox); precondition(model.checked.contains(unchecked))
        checkbox.state = .off; receiver.toggleRow(checkbox); precondition(!model.checked.contains(unchecked))
        model.busy = true; precondition(!model.canApply)
        let disabled = receiver.tableView(receiver.table, viewFor: receiver.table.tableColumns[0], row: index) as! NSButton
        precondition(!disabled.isEnabled); model.busy = false
        model.highlighted = [file, unchecked]; receiver.refresh()
        let displayed = receiver.selectedRows.map(\.path)
        precondition(receiver.clipboardText("relative") == displayed.joined(separator: "\n") + "\n")
        precondition(receiver.clipboardText("full") == displayed.map { folder.appendingPathComponent($0).path }.joined(separator: "\n") + "\n")
        precondition(receiver.clipboardText("names") == displayed.map { ($0 as NSString).lastPathComponent }.joined(separator: "\n") + "\n")
        precondition(receiver.clipboardText("ext") == ".txt\n.txt\n")
        precondition(receiver.clipboardText("all").hasPrefix("Path\tExtension"))
        receiver.toggleSelectedChecks(); precondition(model.checked.contains(unchecked)); receiver.toggleSelectedChecks()
        precondition(!model.checked.contains(file) && !model.checked.contains(unchecked)); model.checked = [file, ignored]
        var opened: [(String, AddFileOpenAction)] = []; model.onOpen = { opened.append(($0, $1)) }
        receiver.openSelected(.open); precondition(opened.isEmpty)
        model.highlighted = [file]; receiver.refresh(); receiver.openSelected(.open); receiver.openSelected(.openWith); receiver.openSelected(.editor)
        precondition(opened.count == 3 && opened.allSatisfy { $0.0 == file })
        let menu = receiver.table.menu!; receiver.menuNeedsUpdate(menu)
        let copy = menu.items.first { $0.title == "Copy to clipboard" }!
        precondition(copy.submenu?.items.filter { !$0.isHidden }.map(\.title) == ["Full paths", "Relative paths", "File/folder names", "Extensions", "All visible columns"])
        precondition(menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.allSatisfy(\.isEnabled))
        let currentColumnItem = copy.submenu!.items.first { $0.representedObject as? String == "column" }!
        precondition(currentColumnItem.isHidden && !currentColumnItem.isEnabled && receiver.clipboardText("column").isEmpty)
        let pathColumn = receiver.table.tableColumns.firstIndex { $0.identifier.rawValue == "path" }!
        receiver.prepareContext(row: receiver.rows.firstIndex { $0.path == file }!, column: pathColumn)
        receiver.menuNeedsUpdate(menu)
        precondition(currentColumnItem.title == "Column 'Path'" && !currentColumnItem.isHidden && currentColumnItem.isEnabled)
        precondition(receiver.clipboardText("column") == file + "\n")
        model.highlighted = [file, unchecked]; receiver.refresh()
        let extensionColumn = receiver.table.tableColumns.firstIndex { $0.identifier.rawValue == "ext" }!
        receiver.prepareContext(row: receiver.rows.firstIndex { $0.path == unchecked }!, column: extensionColumn)
        precondition(model.selectionMark == unchecked && receiver.clipboardText("column") == ".txt\n.txt\n")
        receiver.table.moveColumn(extensionColumn, toColumn: pathColumn)
        receiver.menuNeedsUpdate(menu)
        precondition(currentColumnItem.title == "Column 'Extension'" && receiver.clipboardText("column") == ".txt\n.txt\n")
        let sizeColumn = receiver.table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("size"))!
        sizeColumn.isHidden = false
        receiver.prepareContext(row: 0, column: receiver.table.tableColumns.firstIndex { $0 === sizeColumn }!)
        receiver.menuNeedsUpdate(menu)
        let copiedSize = receiver.clipboardText("column")
        precondition(currentColumnItem.title == "Column 'Size'" && copiedSize == receiver.selectedRows.map { receiver.cellText($0, key: "size") }.joined(separator: "\n") + "\n")
        sizeColumn.isHidden = true; receiver.menuNeedsUpdate(menu)
        precondition(currentColumnItem.isHidden && !currentColumnItem.isEnabled && receiver.clipboardText("column").isEmpty)
        let dateColumn = receiver.table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("date"))!
        dateColumn.isHidden = false
        receiver.prepareContext(row: 0, column: receiver.table.tableColumns.firstIndex { $0 === dateColumn }!)
        receiver.menuNeedsUpdate(menu)
        let displayedDates = receiver.selectedRows.map { row in
            let index = receiver.rows.firstIndex { $0.path == row.path }!
            return (receiver.tableView(receiver.table, viewFor: dateColumn, row: index) as! NSTextField).stringValue
        }
        precondition(currentColumnItem.title == "Column 'Modification date'" && receiver.clipboardText("column") == displayedDates.joined(separator: "\n") + "\n")
        dateColumn.isHidden = true
        receiver.prepareContext(row: 0, column: 0); receiver.menuNeedsUpdate(menu)
        precondition(currentColumnItem.title == "Column 'Path'")
        model.busy = true; receiver.menuNeedsUpdate(menu)
        precondition(!currentColumnItem.isEnabled && receiver.clipboardText("column").isEmpty)
        model.busy = false
        model.confirmingQuit = true; receiver.menuNeedsUpdate(menu)
        precondition(!currentColumnItem.isEnabled && receiver.clipboardText("column").isEmpty)
        model.confirmingQuit = false
        receiver.prepareContext(row: 0, column: -1); receiver.menuNeedsUpdate(menu)
        precondition(currentColumnItem.isHidden && receiver.clipboardText("column").isEmpty)
        receiver.prepareContext(row: -1, column: pathColumn); receiver.menuNeedsUpdate(menu)
        precondition(currentColumnItem.isHidden && receiver.clipboardText("column").isEmpty)
        model.highlighted = [file]; receiver.refresh()
        let heldBytes = try Data(contentsOf: folder.appendingPathComponent(file))
        try FileManager.default.removeItem(at: folder.appendingPathComponent(file)); try FileManager.default.createDirectory(at: folder.appendingPathComponent(file), withIntermediateDirectories: false)
        receiver.menuNeedsUpdate(menu); receiver.openSelected(.open)
        precondition(opened.count == 3 && menu.items.first { $0.title == "Open" }!.isHidden)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(file)); try heldBytes.write(to: folder.appendingPathComponent(file))
        model.confirmingQuit = true; receiver.menuNeedsUpdate(menu); receiver.openSelected(.open)
        precondition(receiver.clipboardText("relative").isEmpty && opened.count == 3 && menu.items.filter { !$0.isSeparatorItem }.allSatisfy { !$0.isEnabled })
        model.confirmingQuit = false
        var accepted: [String] = [], closed = 0
        model.onAccepted = { accepted = $0 }; model.close = { closed += 1 }; model.apply()
        precondition(Set(accepted) == [file, ignored] && closed == 1)
        let progress = AddProgressWindowModel(repository: repo, access: nil, paths: accepted)
        let progressTable = AddProgressTable.Coordinator(model: progress), progressScroll = progressTable.make()
        precondition(progressTable.table.tableColumns.map(\.title) == ["Action", "Path"])
        precondition(progressTable.table.watermarkImage != nil && progressScroll.documentView === progressTable.table)
        precondition(progressTable.numberOfRows(in: progressTable.table) == accepted.count)
        var finishes = 0; progress.onFinished = { _, success in precondition(success); finishes += 1 }
        await progress.run(); precondition(progress.success && !progress.busy && finishes == 1)
        await progress.run(); precondition(finishes == 1)
        let staged = try await repo.run(["diff", "--cached", "--name-only", "-z"]).stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        precondition(Set(staged) == [file, ignored])
        let originalBlob = try await repo.run(["show", ":" + file]).stdout
        try Data("edited after Add".utf8).write(to: folder.appendingPathComponent(file))
        await progress.changeMode(.executable); precondition(progress.success && !progress.busy && finishes == 2)
        let executable = try await repo.run(["ls-files", "--stage", "-z", "--", file]).stdout
        precondition(String(decoding: executable, as: UTF8.self).hasPrefix("100755 "))
        try FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        await progress.changeMode(.symlink); precondition(progress.success && !progress.busy && finishes == 3)
        let link = try await repo.run(["ls-files", "--stage", "-z", "--", file]).stdout
        let preserved = try await repo.run(["show", ":" + file]).stdout
        precondition(String(decoding: link, as: UTF8.self).hasPrefix("120000 ") && preserved == originalBlob)
        progress.confirmingQuit = true; await progress.changeMode(.executable); precondition(finishes == 3); progress.confirmingQuit = false
        let cancelled = AddProgressWindowModel(repository: repo, access: nil, paths: [unchecked]); cancelled.cancel(); await cancelled.run()
        precondition(cancelled.cancelled && !cancelled.success && !cancelled.busy)
        let after = try await repo.run(["diff", "--cached", "--name-only", "-z"]).stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        precondition(Set(after) == [file, ignored])
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        for path in ["ignore-a.txt", "ignore-b.TXT", "sub/folder.tmp", "mixed.data"] { try Data(path.utf8).write(to: folder.appendingPathComponent(path)) }
        model.includeIgnored = false; try await model.read()
        var ignoreRequests: [([String], Bool)] = []; model.onIgnore = { ignoreRequests.append(($0, $1)) }
        model.highlighted = ["ignore-a.txt", "ignore-b.TXT"]; receiver.refresh(); receiver.menuNeedsUpdate(menu)
        let sameExtension = menu.items.first { $0.title == "Ignore" }!
        precondition(sameExtension.submenu?.items.map(\.title) == ["Ignore 2 items", "*.txt"])
        receiver.ignoreSelected(mask: true); precondition(Set(ignoreRequests.last!.0) == ["ignore-a.txt", "ignore-b.TXT"] && ignoreRequests.last!.1)
        model.highlighted = ["sub/folder.tmp"]; receiver.refresh(); receiver.menuNeedsUpdate(menu)
        precondition(menu.items.first { $0.title == "Ignore" }!.submenu?.items.map(\.title) == ["folder.tmp", "*.tmp", "sub"])
        receiver.ignoreSelected(folder: true); precondition(ignoreRequests.last!.0 == ["sub"] && !ignoreRequests.last!.1)
        model.highlighted = ["ignore-a.txt", "mixed.data"]; receiver.refresh(); receiver.menuNeedsUpdate(menu)
        precondition(menu.items.contains { $0.title == "Ignore 2 items" && $0.submenu == nil })
        precondition(menu.items.contains { $0.title == "Ignore 2 items by extension" })
        let oldChecks = model.checked, oldIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        precondition(model.beginIgnore() && !model.canApply); model.cancel(); receiver.ignoreSelected()
        precondition(model.ignoring && model.busy && ignoreRequests.count == 2)
        model.finishIgnore(changed: false); precondition(!model.busy && model.checked == oldChecks)
        let afterCancel = try await repo.run(["ls-files", "--stage", "-z"]).stdout; precondition(afterCancel == oldIndex)
        func applyIgnore(_ paths: [String], mask: Bool = false) async throws {
            precondition(model.beginIgnore())
            let ignore = IgnoreWindowModel(repository: repo, access: nil, options: try IgnoreOptions(paths: paths, mask: mask))
            var finished = false
            ignore.onRulesWritten = { _ in finished = true; model.finishIgnore(changed: true) }
            ignore.apply()
            for _ in 0..<300 {
                if finished && !model.busy { break }
                if let error = ignore.error { throw NSError(domain: error, code: 1) }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            precondition(finished && !model.busy)
        }
        let unrelatedBytes = try Data(contentsOf: folder.appendingPathComponent(unchecked))
        model.checked.remove(unchecked)
        try await applyIgnore(["ignore-a.txt"])
        precondition(!model.entries.contains { $0.path == "ignore-a.txt" } && !model.checked.contains(unchecked))
        try await applyIgnore(["ignore-b.TXT"], mask: true)
        precondition(!model.entries.contains { $0.path == "ignore-b.TXT" })
        try await applyIgnore(["sub"])
        precondition(!model.entries.contains { $0.path.hasPrefix("sub/") })
        let finalIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        let finalUnrelated = try Data(contentsOf: folder.appendingPathComponent(unchecked))
        precondition(finalIndex == oldIndex && finalUnrelated == unrelatedBytes)
        precondition(FileManager.default.fileExists(atPath: folder.appendingPathComponent("sub/folder.tmp").path))
        let deleting = "delete 雪\n.bin", permanent = "permanent.bin", ignoredDelete = "trash.log", cancelledDelete = "cancel-delete.bin"
        let deletionBytes = Data([0, 255, 13, 10])
        for path in [deleting, permanent, ignoredDelete, cancelledDelete] { try deletionBytes.write(to: folder.appendingPathComponent(path)) }
        model.includeIgnored = true; try await model.read()
        var deleteRequests: [([StatusEntry], Bool)] = []; model.onDelete = { deleteRequests.append(($0, $1)) }
        model.highlighted = [deleting]; receiver.refresh(); receiver.deleteSelected(permanently: false, keyboard: true)
        precondition(deleteRequests.count == 1 && deleteRequests[0].0.map(\.path) == [deleting] && !deleteRequests[0].1)
        receiver.menuNeedsUpdate(menu); precondition(menu.items.contains { $0.title == "Delete" && !$0.isHidden && $0.isEnabled })
        let checksBeforeDelete = model.checked
        precondition(model.beginDeleteConfirmation(deleteRequests[0].0, permanently: false)); model.cancel()
        precondition(model.busy && !model.canApply); precondition(model.finishDeleteConfirmation(accepted: false) == nil)
        precondition(!model.busy && model.checked == checksBeforeDelete && FileManager.default.fileExists(atPath: folder.appendingPathComponent(deleting).path))
        var deletions = 0; model.onDeleteChanged = { _ in deletions += 1 }
        precondition(model.beginDeleteConfirmation(deleteRequests[0].0, permanently: false))
        await model.finishDeleteConfirmation(accepted: true)?.value
        let recycled = model.lastDeleteResult!
        defer { for url in recycled.trashedFiles { try? FileManager.default.removeItem(at: url) } }
        precondition(recycled.trashedFiles.count == 1 && !model.entries.contains { $0.path == deleting })
        let recovered = try Data(contentsOf: recycled.trashedFiles[0]); precondition(recovered == deletionBytes && deletions == 1)
        model.highlighted = [ignoredDelete]; receiver.refresh(); receiver.deleteSelected(permanently: false)
        precondition(deleteRequests.last!.0.first!.state == .ignored)
        precondition(model.beginDeleteConfirmation(deleteRequests.last!.0, permanently: false)); await model.finishDeleteConfirmation(accepted: true)?.value
        let ignoredRecycled = model.lastDeleteResult!
        defer { for url in ignoredRecycled.trashedFiles { try? FileManager.default.removeItem(at: url) } }
        precondition(ignoredRecycled.trashedFiles.count == 1 && !FileManager.default.fileExists(atPath: folder.appendingPathComponent(ignoredDelete).path))
        model.highlighted = [permanent]; receiver.refresh(); receiver.deleteSelected(permanently: true, keyboard: true)
        precondition(deleteRequests.last!.1); precondition(model.beginDeleteConfirmation(deleteRequests.last!.0, permanently: true))
        await model.finishDeleteConfirmation(accepted: true)?.value
        precondition(model.lastDeleteResult!.trashedFiles.isEmpty && !FileManager.default.fileExists(atPath: folder.appendingPathComponent(permanent).path))
        let beforeCancel = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        model.highlighted = [cancelledDelete]; receiver.refresh(); receiver.deleteSelected(permanently: false)
        precondition(model.beginDeleteConfirmation(deleteRequests.last!.0, permanently: false))
        let cancelledTask = model.finishDeleteConfirmation(accepted: true); model.cancel(); await cancelledTask?.value
        precondition(model.lastDeleteResult == nil && FileManager.default.fileExists(atPath: folder.appendingPathComponent(cancelledDelete).path) && !model.busy)
        let afterDeleteCancel = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        precondition(beforeCancel == oldIndex && afterDeleteCancel == beforeCancel)
        let stale = model.entries.first { $0.path == cancelledDelete }!.status
        try await repo.stage([cancelledDelete]); let stagedBeforeStale = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        precondition(model.beginDeleteConfirmation([stale], permanently: false)); await model.finishDeleteConfirmation(accepted: true)?.value
        let stagedAfterStale = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        precondition(model.lastDeleteResult == nil && stagedBeforeStale == stagedAfterStale && FileManager.default.fileExists(atPath: folder.appendingPathComponent(cancelledDelete).path))
        let copyPath = "copy-folder/source 雪\n.bin", copyBytes = Data([0, 255, 13, 10, 7])
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("copy-folder"), withIntermediateDirectories: true)
        try copyBytes.write(to: folder.appendingPathComponent(copyPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appendingPathComponent(copyPath).path)
        try await model.read(); model.highlighted = [copyPath]; receiver.refresh()
        var savedRequests: [String] = [], exportRequests: [[String]] = []
        model.onSave = { savedRequests.append($0) }; model.onExport = { exportRequests.append($0) }
        receiver.saveAs(); receiver.export(); precondition(savedRequests == [copyPath] && exportRequests == [[copyPath]])
        let outputFolder = folder.deletingLastPathComponent().appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let saved = outputFolder.appendingPathComponent("saved.bin")
        let beforeCopy = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        let checksBeforeCopy = model.checked
        await model.saveFile(copyPath, to: saved)
        let savedBytes = try Data(contentsOf: saved); precondition(savedBytes == copyBytes && !model.busy)
        await model.exportFiles([copyPath], to: outputFolder)
        let exportedBytes = try Data(contentsOf: outputFolder.appendingPathComponent(copyPath)); precondition(exportedBytes == copyBytes)
        let afterCopy = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        precondition(beforeCopy == afterCopy && model.checked == checksBeforeCopy)
        model.confirmingQuit = true; precondition(model.startSave(copyPath, to: saved) == nil); receiver.saveAs(); precondition(savedRequests.count == 1); model.confirmingQuit = false
        let cancelledCopy = outputFolder.appendingPathComponent("cancelled.bin")
        let copyTask = model.startSave(copyPath, to: cancelledCopy); precondition(model.busy && !model.canApply); model.cancel(); await copyTask?.value
        precondition(!model.busy && !FileManager.default.fileExists(atPath: cancelledCopy.path))
        await model.saveFile(copyPath, to: folder.appendingPathComponent(copyPath))
        let sourceAfter = try Data(contentsOf: folder.appendingPathComponent(copyPath)); precondition(sourceAfter == copyBytes && !model.busy)
        let addedHistoryPath = "newly-added-history.bin"
        try Data("added\n".utf8).write(to: folder.appendingPathComponent(addedHistoryPath))
        try await repo.stage([addedHistoryPath]); model.setScope([addedHistoryPath]); try await model.read()
        model.highlighted = [addedHistoryPath]; receiver.refresh()
        precondition(receiver.canLog && receiver.canCompareBase && !receiver.canBlame)
        let ignoredHistoryPath = "history-ignored.log"
        try Data("ignored\n".utf8).write(to: folder.appendingPathComponent(ignoredHistoryPath))
        model.includeIgnored = true; model.setScope([ignoredHistoryPath]); try await model.read(); model.highlighted = [ignoredHistoryPath]; receiver.refresh()
        precondition(!receiver.canLog && !receiver.canCompareBase && !receiver.canBlame)
        model.setScope([".gitignore"]); try await model.read(); model.highlighted = [".gitignore"]; receiver.refresh()
        var logged: [String] = [], blamed: [String] = [], baseComparisons: [[String]] = [], pairs: [[String]] = []
        model.onLog = { logged.append($0) }; model.onBlame = { blamed.append($0) }; model.onCompare = { baseComparisons.append($0) }; model.onCompareTwo = { pairs.append($0) }
        receiver.menuNeedsUpdate(menu); precondition(receiver.canLog && receiver.canBlame && receiver.canCompareBase)
        receiver.showLog(); receiver.blame(); receiver.compareBase()
        precondition(logged == [".gitignore"] && blamed == [".gitignore"] && baseComparisons == [[".gitignore"]])
        var historyOptions = HistoryOptions(); historyOptions.paths = [".gitignore"]
        precondition(model.hasHead && receiver.canUnifiedDiff)
        var unifiedPatches: [(Data, Bool)] = []
        model.onUnifiedPatch = { bytes, alternate in unifiedPatches.append((bytes, alternate)) }
        let unifiedIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        let expectedUnified = try await repo.run(["diff", "--no-ext-diff", "--no-color", "--stat", "-p", "--end-of-options", "HEAD", "--", ".gitignore"]).stdout
        let unifiedTask = model.startUnifiedDiff(paths: [".gitignore"], alternate: true)
        precondition(model.busy && unifiedTask != nil && !model.canApply)
        await unifiedTask?.value
        precondition(!model.busy && unifiedPatches.count == 1 && unifiedPatches[0].0 == expectedUnified && unifiedPatches[0].1)
        receiver.unifiedDiff(); precondition(model.busy)
        for _ in 0..<300 { if !model.busy { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        precondition(!model.busy && unifiedPatches.count == 2 && !unifiedPatches[1].1 && unifiedPatches[1].0 == expectedUnified)
        model.unifiedViewerBusy = { true }; precondition(!receiver.canUnifiedDiff && model.startUnifiedDiff(paths: [".gitignore"]) == nil)
        model.unifiedViewerBusy = { false }
        model.confirmingQuit = true; precondition(model.startUnifiedDiff(paths: [".gitignore"]) == nil); model.confirmingQuit = false
        let closesBeforeUnifiedCancel = closed
        let cancelledUnified = model.startUnifiedDiff(paths: [".gitignore"]); model.cancel(); await cancelledUnified?.value
        precondition(!model.busy && unifiedPatches.count == 2 && closed == closesBeforeUnifiedCancel + 1)
        let afterUnified = try await repo.run(["ls-files", "--stage", "-z"]).stdout; precondition(afterUnified == unifiedIndex)
        model.setScope([".gitignore", addedHistoryPath]); try await model.read(); model.highlighted = [".gitignore", addedHistoryPath]; model.selectionMark = ".gitignore"; receiver.refresh()
        let unifiedPaths = receiver.selectedRows.map(\.path)
        var expectedMany = Data()
        for path in unifiedPaths { expectedMany.append(try await repo.run(["diff", "--no-ext-diff", "--no-color", "--stat", "-p", "--end-of-options", "HEAD", "--", path]).stdout) }
        precondition(String(decoding: expectedMany, as: UTF8.self).components(separatedBy: "diff --git").count == 3)
        await model.startUnifiedDiff(paths: unifiedPaths)?.value
        precondition(unifiedPatches.count == 3 && unifiedPatches.last!.0 == expectedMany)
        let patchesBeforeBusyRace = unifiedPatches.count
        let busyRace = model.startUnifiedDiff(paths: unifiedPaths)
        model.unifiedViewerBusy = { true }; await busyRace?.value
        precondition(!model.busy && unifiedPatches.count == patchesBeforeBusyRace && model.error?.contains("Finish the open unified diff operation") == true)
        model.unifiedViewerBusy = { false }
        let checksBeforeViewerError = model.checked
        model.onUnifiedPatch = { _, _ in throw NSError(domain: "Add viewer QA", code: 1, userInfo: [NSLocalizedDescriptionKey: "viewer unavailable"]) }
        await model.startUnifiedDiff(paths: unifiedPaths)?.value
        precondition(!model.busy && model.error == "viewer unavailable" && model.checked == checksBeforeViewerError)
        model.onUnifiedPatch = { bytes, alternate in unifiedPatches.append((bytes, alternate)) }
        let unbornFolder = folder.deletingLastPathComponent().appendingPathComponent("unborn-diff")
        try FileManager.default.createDirectory(at: unbornFolder, withIntermediateDirectories: false)
        let unbornRepo = GitRepository(root: unbornFolder); _ = try await unbornRepo.run(["init", "-b", "main"])
        try Data("first\n".utf8).write(to: unbornFolder.appendingPathComponent("first.txt")); try await unbornRepo.stage(["first.txt"])
        let unbornModel = AddWindowModel(repository: unbornRepo, access: nil); unbornModel.setScope(["first.txt"]); try await unbornModel.read(); unbornModel.highlighted = ["first.txt"]
        let unbornReceiver = AddFileTable.Coordinator(model: unbornModel); _ = unbornReceiver.make()
        precondition(unbornReceiver.canCompareBase && !unbornModel.hasHead && !unbornReceiver.canUnifiedDiff && unbornModel.startUnifiedDiff(paths: ["first.txt"]) == nil)
        let history = try await repo.history(options: historyOptions)
        precondition(!history.isEmpty)
        let annotation = try await repo.blame(path: ".gitignore", revision: "HEAD")
        precondition(annotation.contents == Data("*.log\n".utf8))
        model.setScope(["."]); try await model.read(); model.highlighted = [copyPath, unchecked]; receiver.refresh()
        precondition(!receiver.canCompareBase && !receiver.canLog && !receiver.canBlame && !receiver.canUnifiedDiff && receiver.canCompareTwo)
        receiver.compareTwo(); precondition(pairs == [receiver.selectedRows.map(\.path)])
        let pair = try await repo.workingFilePairComparison(paths: pairs[0]); precondition(pair.files.count == 1)
        model.confirmingQuit = true; receiver.showLog(); receiver.blame(); receiver.compareBase(); receiver.compareTwo()
        precondition(logged.count == 1 && blamed.count == 1 && baseComparisons.count == 1 && pairs.count == 1); model.confirmingQuit = false
        _ = try await repo.run(["mv", "--", ".gitignore", "renamed-ignore.txt"])
        model.setScope(["renamed-ignore.txt"]); try await model.read(); model.highlighted = ["renamed-ignore.txt"]; receiver.refresh()
        precondition(receiver.oldLogPath == ".gitignore"); receiver.showOldLog(); precondition(logged.last == ".gitignore")
        historyOptions.paths = [logged.last!]
        let oldHistory = try await repo.history(options: historyOptions); precondition(!oldHistory.isEmpty)
        model.setScope(["renamed-ignore.txt", copyPath]); try await model.read(); model.highlighted = ["renamed-ignore.txt", copyPath]
        model.selectionMark = copyPath; precondition(!receiver.canCompareBase && receiver.canIgnore && receiver.canDelete)
        model.selectionMark = "renamed-ignore.txt"; precondition(receiver.canCompareBase && !receiver.canIgnore && !receiver.canDelete)
        model.setScope(["renamed-ignore.txt", copyPath]); try await model.read()
        model.highlighted = ["renamed-ignore.txt", copyPath]; receiver.refresh()
        let retainedFile = folder.appendingPathComponent("renamed-ignore.txt")
        let renamedWorkingBytes = try Data(contentsOf: retainedFile)
        // HEAD still has the original path, so use that path before the rename for fallback.
        _ = try await repo.run(["mv", "--", "renamed-ignore.txt", ".gitignore"])
        model.setScope([".gitignore", copyPath]); try await model.read(); model.highlighted = [".gitignore", copyPath]; receiver.refresh()
        let fallbackIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        try FileManager.default.removeItem(at: folder.appendingPathComponent(".gitignore"))
        receiver.menuNeedsUpdate(menu)
        precondition(receiver.canCompareTwo && menu.items.first { $0.title == "Compare two files" }?.isHidden == false)
        receiver.compareTwo(); let fallbackPaths = pairs.last!; precondition(fallbackPaths == receiver.selectedRows.map(\.path))
        let fallback = try await repo.workingFilePairComparison(paths: fallbackPaths)
        let fallbackDocument = try await repo.comparisonFile(fallback, path: fallbackPaths[1])
        let historicalBytes = fallbackPaths[0] == ".gitignore" ? fallbackDocument.base.bytes : fallbackDocument.destination.bytes
        precondition(historicalBytes == Data("*.log\n".utf8))
        let unchangedFallbackIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout; precondition(unchangedFallbackIndex == fallbackIndex)
        try renamedWorkingBytes.write(to: folder.appendingPathComponent(".gitignore"))
        let nestedDirectory = "pair-directory"
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(nestedDirectory), withIntermediateDirectories: false)
        try Data("child".utf8).write(to: folder.appendingPathComponent(nestedDirectory + "/child"))
        _ = try await repo.run(["init", folder.appendingPathComponent(nestedDirectory).path])
        model.setScope([copyPath, nestedDirectory]); try await model.read()
        let directoryRow = model.entries.first { $0.isDirectory }!; model.highlighted = [copyPath, directoryRow.path]; receiver.refresh()
        precondition(!receiver.canCompareTwo)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(nestedDirectory))
        precondition(!receiver.canCompareTwo)
        let restorePath = "restore-雪\n.bin", restoreOther = "restore-untracked.data"
        let restoreOriginal = Data([0, 255, 13, 10, 65]), restoreLater = Data([0, 254, 66])
        try Data("index bytes".utf8).write(to: folder.appendingPathComponent(restorePath)); try await repo.stage([restorePath])
        try restoreOriginal.write(to: folder.appendingPathComponent(restorePath)); try restoreOriginal.write(to: folder.appendingPathComponent(restoreOther))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appendingPathComponent(restorePath).path)
        model.setScope([restorePath, restoreOther]); try await model.read(); model.highlighted = [restorePath, restoreOther]; model.selectionMark = restorePath; receiver.refresh()
        receiver.menuNeedsUpdate(menu)
        let restoreMenu = menu.items.first { $0.title == "Restore after commit" }!
        precondition(receiver.canRestoreCopy && !restoreMenu.isHidden)
        let restoreIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        receiver.restoreItem(); precondition(model.busy)
        for _ in 0..<300 { if !model.busy { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        precondition(!model.busy && Set(model.restoreCopies.keys) == [restorePath, restoreOther])
        receiver.menuNeedsUpdate(menu); precondition(restoreMenu.title == "Restore")
        let restoreRowIndex = receiver.rows.firstIndex { $0.path == restorePath }!
        let pathCell = receiver.tableView(receiver.table, viewFor: receiver.table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("path")), row: restoreRowIndex) as! NSTableCellView
        precondition(pathCell.subviews.contains { $0.identifier?.rawValue == "restore-overlay" && ($0 as? NSImageView)?.image != nil })
        precondition(model.startMarkForRestore([restorePath, restoreOther]) == nil)
        try restoreLater.write(to: folder.appendingPathComponent(restorePath)); try restoreLater.write(to: folder.appendingPathComponent(restoreOther))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: folder.appendingPathComponent(restorePath).path)
        var restoreRequests: [[String]] = [], restoreChanges = 0
        model.onRestore = { restoreRequests.append($0) }; model.onRestoreChanged = { restoreChanges += 1 }
        receiver.restoreItem(); precondition(restoreRequests == [receiver.selectedRows.map(\.path)])
        let restoreChecks = model.checked
        precondition(model.beginRestoreConfirmation(restoreRequests[0]) && !model.canApply)
        model.cancel(); precondition(model.busy)
        await model.finishRestoreConfirmation(accepted: false)?.value
        precondition(!model.busy && model.checked == restoreChecks && model.restoreCopies.count == 2)
        let afterAbortBytes = try Data(contentsOf: folder.appendingPathComponent(restorePath)); precondition(afterAbortBytes == restoreLater)
        model.confirmingQuit = true; receiver.restoreItem(); precondition(restoreRequests.count == 1 && model.startMarkForRestore([restorePath]) == nil && !model.beginRestoreConfirmation([restorePath])); model.confirmingQuit = false
        precondition(model.beginRestoreConfirmation([restorePath])); let cancelledRestore = model.finishRestoreConfirmation(accepted: true); model.cancel(); await cancelledRestore?.value
        let cancelledRestoreBytes = try Data(contentsOf: folder.appendingPathComponent(restorePath)); precondition(!model.busy && model.restoreCopies.count == 2 && cancelledRestoreBytes == restoreLater)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(restorePath)); try FileManager.default.createDirectory(at: folder.appendingPathComponent(restorePath), withIntermediateDirectories: false)
        precondition(model.beginRestoreConfirmation([restorePath, restoreOther])); await model.finishRestoreConfirmation(accepted: true)?.value
        precondition(!model.busy && model.restoreCopies[restorePath] != nil && model.restoreCopies[restoreOther] == nil && restoreChanges == 1)
        let restoredOtherBytes = try Data(contentsOf: folder.appendingPathComponent(restoreOther)); precondition(restoredOtherBytes == restoreOriginal)
        try FileManager.default.removeItem(at: folder.appendingPathComponent(restorePath)); try restoreLater.write(to: folder.appendingPathComponent(restorePath))
        try await model.read(); model.highlighted = [restorePath]; model.selectionMark = restorePath; receiver.refresh()
        precondition(model.beginRestoreConfirmation([restorePath])); await model.finishRestoreConfirmation(accepted: true)?.value
        let restoredBytes = try Data(contentsOf: folder.appendingPathComponent(restorePath))
        let restoredPermissions = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(restorePath).path)[.posixPermissions] as? Int
        precondition(restoredBytes == restoreOriginal && restoredPermissions == 0o755 && model.restoreCopies.isEmpty && restoreChanges == 2)
        let afterRestoreIndex = try await repo.run(["ls-files", "--stage", "-z"]).stdout; precondition(afterRestoreIndex == restoreIndex)
        receiver.menuNeedsUpdate(menu); precondition(restoreMenu.title == "Restore after commit")
        model.highlighted = [restoreOther]; model.selectionMark = restoreOther; receiver.refresh(); receiver.menuNeedsUpdate(menu)
        precondition(!receiver.canRestoreCopy && restoreMenu.isHidden)
        print("Actual Add receiver: source-shaped restoration mark/Restore menu and original overlay, ordered mixed versioned/untracked copy capture, no recapture, native confirmation request/Abort/quit/queued-cancel guards, partial directory-failure recovery, exact binary bytes/permissions and unchanged index; unified HEAD-to-working patch bytes and ordered multi-file scope, default/alternate captured viewer routing, unchanged index, unborn/untracked suppression, queued cancellation and viewer/quit guards; current-column clipboard without headings, named icon menu, stable column identity after reorder, marked-row capture, hidden-column/invalid-hit/quit guards and checkbox-to-Path mapping; disappeared tracked file comparison offers pinned HEAD bytes without index changes; nested directory exclusion persists after removal; tracked Log/HEAD Blame/base routes, hidden untracked history/base, ordered working-file pair, rename old-name history, marked-row gates and quit guards; exact original translucent colored Add artwork, default/preference/viewport anchoring and native Action/Path progress table; Save/Export captured routing, exact binary copies and relative paths, unchanged staging/checks, queued-copy cancellation/quit guards and source overwrite rejection; Delete menu/keyboard requests, cancelled confirmations, recoverable binary Trash and ignored files, permanent fixture delete, owned cancellation and stale-index rejection; Ignore names/masks/folder menu projections and captured requests, real Ignore model writes and Add refresh, cancelled child/check/index retention; context command dispatch without launching apps, selection/clipboard ordering and dotted extensions, disabled menu/quit guards, check toggles; ignored defaults, refresh check retention, path-captured checkbox, native columns/disabled worker, checked-only OK/close, real forced add, one-shot progress, executable/symlink post-actions preserving staged bytes after disk edit/deletion, quit guard and cancelled unchanged-index case passed. No windows/menus displayed; gestures/signed acceptance pending.")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='TurtleGitAddDialogTest-') as directory:
    folder = pathlib.Path(directory); main = folder / 'Driver.swift'; main.write_text(driver); binary = folder / 'verify'
    sources = ['AddWindow.swift', 'AddFileTable.swift', 'AddProgressWindow.swift', 'SelectionAllCheckbox.swift', 'CommandLabel.swift', 'Appearance.swift', 'AlternativeEditorSettings.swift', 'IgnoreWindow.swift', 'NativeWatermarkTable.swift', 'AddProgressTable.swift']
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-target', platform.machine() + '-apple-macos13.0', '-F', str(frameworks), '-framework', 'TurtleGitCore', '-Xlinker', '-rpath', '-Xlinker', str(frameworks), *[str(root / 'Sources/TurtleGitMac' / s) for s in sources], str(main), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(folder / 'fixture')], check=True)
