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
        var accepted: [String] = [], closed = 0
        model.onAccepted = { accepted = $0 }; model.close = { closed += 1 }; model.apply()
        precondition(Set(accepted) == [file, ignored] && closed == 1)
        let progress = AddProgressWindowModel(repository: repo, access: nil, paths: accepted)
        var finishes = 0; progress.onFinished = { _, success in precondition(success); finishes += 1 }
        await progress.run(); precondition(progress.success && !progress.busy && finishes == 1)
        await progress.run(); precondition(finishes == 1)
        let staged = try await repo.run(["diff", "--cached", "--name-only", "-z"]).stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        precondition(Set(staged) == [file, ignored])
        let cancelled = AddProgressWindowModel(repository: repo, access: nil, paths: [unchecked]); cancelled.cancel(); await cancelled.run()
        precondition(cancelled.cancelled && !cancelled.success && !cancelled.busy)
        let after = try await repo.run(["diff", "--cached", "--name-only", "-z"]).stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        precondition(Set(after) == [file, ignored])
        print("Actual Add receiver: ignored defaults, refresh check retention, path-captured checkbox, native columns/disabled worker, checked-only OK/close, real forced add, one-shot progress and cancelled unchanged-index case passed. No windows/menus displayed; gestures/signed acceptance pending.")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='TurtleGitAddDialogTest-') as directory:
    folder = pathlib.Path(directory); main = folder / 'Driver.swift'; main.write_text(driver); binary = folder / 'verify'
    sources = ['AddWindow.swift', 'AddFileTable.swift', 'AddProgressWindow.swift', 'SelectionAllCheckbox.swift', 'CommandLabel.swift', 'Appearance.swift']
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-target', platform.machine() + '-apple-macos13.0', '-F', str(frameworks), '-framework', 'TurtleGitCore', '-Xlinker', '-rpath', '-Xlinker', str(frameworks), *[str(root / 'Sources/TurtleGitMac' / s) for s in sources], str(main), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(folder / 'fixture')], check=True)
