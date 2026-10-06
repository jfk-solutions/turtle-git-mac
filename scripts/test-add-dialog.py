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
        precondition(copy.submenu?.items.map(\.title) == ["Full paths", "Relative paths", "File/folder names", "Extensions", "All visible columns"])
        precondition(menu.items.filter { !$0.isSeparatorItem }.allSatisfy(\.isEnabled))
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
        print("Actual Add receiver: Save/Export captured routing, exact binary copies and relative paths, unchanged staging/checks, queued-copy cancellation/quit guards and source overwrite rejection; Delete menu/keyboard requests, cancelled confirmations, recoverable binary Trash and ignored files, permanent fixture delete, owned cancellation and stale-index rejection; Ignore names/masks/folder menu projections and captured requests, real Ignore model writes and Add refresh, cancelled child/check/index retention; context command dispatch without launching apps, selection/clipboard ordering and dotted extensions, disabled menu/quit guards, check toggles; ignored defaults, refresh check retention, path-captured checkbox, native columns/disabled worker, checked-only OK/close, real forced add, one-shot progress, executable/symlink post-actions preserving staged bytes after disk edit/deletion, quit guard and cancelled unchanged-index case passed. No windows/menus displayed; gestures/signed acceptance pending.")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='TurtleGitAddDialogTest-') as directory:
    folder = pathlib.Path(directory); main = folder / 'Driver.swift'; main.write_text(driver); binary = folder / 'verify'
    sources = ['AddWindow.swift', 'AddFileTable.swift', 'AddProgressWindow.swift', 'SelectionAllCheckbox.swift', 'CommandLabel.swift', 'Appearance.swift', 'AlternativeEditorSettings.swift', 'IgnoreWindow.swift']
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-target', platform.machine() + '-apple-macos13.0', '-F', str(frameworks), '-framework', 'TurtleGitCore', '-Xlinker', '-rpath', '-Xlinker', str(frameworks), *[str(root / 'Sources/TurtleGitMac' / s) for s in sources], str(main), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(folder / 'fixture')], check=True)
