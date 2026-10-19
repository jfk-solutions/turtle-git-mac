// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@main struct FormatPatchOptionsVerification {
    @MainActor static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "FormatPatchOptions", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(condition(), "Timed out waiting for Format Patch options")
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let suite = "TurtleGit.FormatPatchOptions.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let repository = GitRepository(root: root, executable: git)
        _ = try await repository.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Options QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repository.run(["config", key, value]) }
        for value in ["base", "tip"] {
            try Data((value + "\n").utf8).write(to: root.appendingPathComponent("file")); try await repository.stage(["file"])
            _ = try await repository.commit(message: value)
        }
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout
        let first = try await repository.run(["rev-parse", "HEAD~1"]).text.trimmingCharacters(in: .newlines)
        _ = try await repository.run(["tag", "excluded-tag"])
        _ = try await repository.run(["update-ref", "refs/remotes/origin/topic", first])
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let controller = FormatPatchWindowController(repository: repository, access: nil, preferences: prefs)
        defer { controller.close() }
        controller.window!.alphaValue = 0; controller.showWindow(nil)
        try await wait { !controller.model.busy }
        var referenceConfigured = 0, logConfigured = 0
        controller.configureReferencePicker = { if $0.preferences === prefs { referenceConfigured += 1 } }
        controller.configureLogPicker = { if $0.colorPreferences === prefs { logConfigured += 1 } }
        func choose(_ browser: ReferenceBrowserWindowController, _ name: String) {
            browser.model.nested = true; browser.model.setFolder("refs")
            browser.model.select([GitReferenceName(name)], last: GitReferenceName(name)); browser.model.accept()
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            controller.window!.appearance = NSAppearance(named: appearance)
            controller.model.mode = .since; controller.model.since = "origin/topic"
            controller.chooseRevision(.since)
            try await wait { controller.referencePicker?.model.busy == false }
            let browser = controller.referencePicker!
            try require(controller.model.hasOptionSheet && controller.activeOperation && !controller.model.optionsAvailable, "Since owns its options")
            try require(referenceConfigured > 0 && browser.model.scope == .excludingTags && browser.model.selection.contains("refs/remotes/origin/topic"), "Source no-tag namespace and initial remote branch")
            try require(!browser.model.snapshot!.references.contains { $0.name.rawValue.hasPrefix("refs/tags/") } && browser.window!.alphaValue == 0 && browser.window!.appearance == controller.window!.appearance, "Source scope, private appearance and hidden host")
            controller.model.export(); controller.model.unifiedDiff(); controller.model.load()
            controller.model.apply(FormatPatchPreset(startRevision: "changed", endRevision: "changed"))
            try require(!controller.model.busy && !controller.model.progress && controller.model.since == "origin/topic", "Draft cannot be replaced/submitted while picker is open")
            choose(browser, "refs/remotes/origin/topic")
            try await wait { !controller.model.hasOptionSheet && controller.window!.attachedSheet == nil }
            try require(controller.model.since == "refs/remotes/origin/topic", "Since keeps qualified branch")
            controller.model.mode = .from; controller.model.from = first; controller.model.to = "HEAD"
            controller.chooseRevision(.from)
            try await wait { controller.picker?.model.busy == false && controller.picker?.model.entries.isEmpty == false }
            let log = controller.picker!
            try require(logConfigured > 0 && log.model.endRevision == first && !log.model.showWorkingTree && log.model.selecting && log.window!.alphaValue == 0, "Range picker starts at entered revision with private defaults and no working tree")
            log.model.finishSelection(log.model.entries.first { $0.hash == first })
            try await wait { !controller.model.hasOptionSheet && controller.window!.attachedSheet == nil }
            try require(controller.model.from == first && controller.model.mode == .from, "From accepts source hash")
            controller.chooseRevision(.to)
            try await wait { controller.picker?.model.busy == false && controller.picker?.model.entries.isEmpty == false }
            let late = controller.picker!; controller.model.from = "changed while open"
            late.model.finishSelection(late.model.entries.first)
            try await wait { !controller.model.hasOptionSheet && controller.window!.attachedSheet == nil }
            try require(controller.model.to == "HEAD" && controller.model.from == "changed while open", "Late To cannot overwrite an edited range")
        }
        controller.presentPicker = { _, _ in false }; controller.chooseRevision(.since)
        try require(!controller.model.hasOptionSheet && controller.referencePicker == nil, "Refused presentation releases draft")
        controller.presentPicker = { parent, child in parent.beginSheet(child); return true }
        controller.chooseRevision(.since); try await wait { controller.referencePicker?.model.busy == false }
        controller.referencePicker!.model.finish(nil)
        try await wait { !controller.model.hasOptionSheet && controller.window!.attachedSheet == nil }

        var directoryReply: ((NSApplication.ModalResponse) -> Void)?
        controller.presentDirectory = { _, _, reply in directoryReply = reply }
        let output = root.appendingPathComponent("chosen output")
        controller.selectedDirectory = { _ in output }
        controller.chooseDirectory()
        let blocker = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        blocker.isReleasedWhenClosed = false; blocker.alphaValue = 0; controller.window!.beginSheet(blocker, completionHandler: { _ in })
        directoryReply?(.OK)
        try require(controller.model.hasOptionSheet && controller.model.directory != output.path, "Folder waits for sheet retirement")
        controller.window!.endSheet(blocker); blocker.close()
        try await wait { !controller.model.hasOptionSheet }
        try require(controller.model.directory == output.path && controller.model.outputAccess != nil, "Chosen output retains grant")
        directoryReply?(.OK)
        controller.chooseDirectory(); controller.model.directory = "edited path"; directoryReply?(.OK)
        try require(!controller.model.hasOptionSheet && controller.model.directory == "edited path", "Late folder result cannot replace changed path")
        controller.chooseDirectory(); controller.close(); directoryReply?(.OK)
        try require(controller.directoryPanel == nil && controller.model.isRetired && controller.model.directory == "edited path", "Owner retirement refuses late folder callbacks")

        let count = FormatPatchWindowModel(repository: repository, access: nil, preferences: prefs)
        count.load(); try await wait { !count.busy }; count.mode = .number
        for invalid in [0, -1, Int(Int32.max) + 1] { count.count = invalid; try require(!count.valid, "Invalid source count enabled OK") }
        count.count = Int(Int32.max); try require(count.valid, "INT_MAX is valid"); count.invalidate()
        try Data("working change\n".utf8).write(to: root.appendingPathComponent("file"))
        let preview = FormatPatchWindowController(repository: repository, access: nil, preferences: prefs)
        defer { preview.close() }; preview.window!.alphaValue = 0; preview.showWindow(nil)
        try await wait { !preview.model.busy }
        preview.model.unifiedDiff(); try await wait { !preview.model.busy }
        try require(preview.patch?.model.readOnly == true && preview.patch?.model.document.text.contains("working change") == true && preview.patch?.window?.alphaValue == 0, "Read-only actual HEAD-to-working preview")
        preview.close(); try require(preview.patch == nil, "Owned preview closes with owner")

        let wrapper = root.appendingPathComponent("controlled-git"), phase = root.appendingPathComponent("controlled-git.phase"), marker = root.appendingPathComponent("controlled-git.started")
        let quote = "'" + git.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        #!/bin/sh
        task_phase=$(cat "$0.phase" 2>/dev/null)
        for task_arg in "$@"; do
          if [ "$task_arg" = "$task_phase" ]; then
            /bin/sleep 30 &
            task_child=$!
            trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
            printf '%s %s\\n' "$$" "$task_child" > "$0.started"
            wait "$task_child"
          fi
        done
        exec \(quote) "$@"
        """
        try Data(script.utf8).write(to: wrapper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let slowRepository = GitRepository(root: root, executable: wrapper)
        for forced in [false, true] {
            try Data("rev-parse".utf8).write(to: phase)
            let slow = FormatPatchWindowController(repository: slowRepository, access: nil, preferences: prefs)
            defer { slow.close() }; slow.window!.alphaValue = 0; slow.showWindow(nil)
            try await wait { FileManager.default.fileExists(atPath: marker.path) }
            let pids = try String(contentsOf: marker).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
            try require(pids.count == 2 && FormatPatchWindowModel.activeOperations > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Initial read owns process/grant and blocks Quit")
            if forced { slow.close() } else { slow.model.close() }
            try await wait { !slow.model.busy && slow.model.isRetired && pids.allSatisfy { kill($0, 0) != 0 } }
            try require(!slow.model.hasHead && slow.model.references.isEmpty && slow.model.error == nil, "Closed initial read cannot publish fields/errors")
            try FileManager.default.removeItem(at: marker)
        }
        try Data().write(to: phase)
        let slowPreview = FormatPatchWindowController(repository: slowRepository, access: nil, preferences: prefs)
        defer { slowPreview.close() }; slowPreview.window!.alphaValue = 0; slowPreview.showWindow(nil)
        try await wait { !slowPreview.model.busy }; try Data("diff".utf8).write(to: phase)
        var published = 0; slowPreview.model.unifiedDiff(onResult: { _ in published += 1 })
        try await wait { FileManager.default.fileExists(atPath: marker.path) }
        let pids = try String(contentsOf: marker).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        slowPreview.close()
        try await wait { !slowPreview.model.busy && pids.allSatisfy { kill($0, 0) != 0 } }
        try require(published == 0 && slowPreview.model.error == nil && FormatPatchWindowModel.activeOperations == 0, "Retired diff cannot publish and retains accounting through reaping")
        try require(try await repository.run(["rev-parse", "HEAD"]).stdout == head && Data(contentsOf: root.appendingPathComponent(".git/index")) == index && Data(contentsOf: root.appendingPathComponent(".git/config")) == config, "Read-only options changed repository state")
        try require(!NSApp.windows.contains { $0.isVisible }, "Owned options/preview windows remain visible")
        print("PASS Format Patch options: source no-tag browser, entered single-commit ranges, light/dark ownership, stale/refused/Cancel/folder guards, count bounds, actual read-only preview, cancellation/reaped processes and unchanged HEAD/index/config.")
    }
}
