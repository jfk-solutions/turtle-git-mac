// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// Deliberate, briefly visible WindowServer capture of the actual native window.
/// No view-cache rendering, screenshot compositing, public HTTP or GUI app launch.
@main struct BlamePaneCapture {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func views(_ root: NSView?) -> [NSView] { guard let root else { return [] }; return [root] + root.subviews.flatMap { views($0) } }
    @MainActor static func wait(_ message: String, _ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: message)
    }
    @MainActor static func drain() async throws {
        try await wait("Capture-owned Blame work/windows did not drain") {
            BlameWindowModel.activeHistoryOperations == 0 && BlameWindowModel.activeSyntaxRequests == 0 && NSApp.windows.allSatisfy { !$0.isVisible && $0.attachedSheet == nil }
        }
    }
    @MainActor static func main() async throws {
        do { try await capture() }
        catch { NSApp.windows.forEach { $0.orderOut(nil); $0.close() }; try? await drain(); throw error }
        try await drain()
    }
    @MainActor static func capture() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2]), output = URL(fileURLWithPath: CommandLine.arguments[3])
        let repo = GitRepository(root: root, executable: git, askpass: nil, libgit2Configuration: .init())
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Alex Rivera"), ("user.email", "alex@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("core.precomposeunicode", "false")] { _ = try await repo.run(["config", key, value]) }
        let path = "Greeting.swift", file = root.appendingPathComponent(path)
        var lines = ["import Foundation", "", "struct Greeting {", "    let name: String", "", "    func message() -> String {", "        return \"Hello, \\(name)!\"", "    }", "}", "", "// A small UTF-8 example: café · 雪", "let greeting = Greeting(name: \"TurtleGit\")", "print(greeting.message())", ""]
        let commits = [("Alex Rivera", "alex@example.invalid", "Add a native greeting example\n\nIntroduce a small Swift type and preserve the original UTF-8 source."), ("Morgan Chen", "morgan@example.invalid", "Greet readers in their own language\n\nKeep Unicode text readable in the source pane.\nThis revision changes the greeting without changing its public interface."), ("Alex Rivera", "alex@example.invalid", "Polish the greeting and document its history\n\nShow the selected revision in the native Properties grid.\nKeep its complete message available in the description pane.\n\nThe Parents group identifies the previous change with its full commit hash.")]
        for (offset, commit) in commits.enumerated() {
            if offset == 1 { lines[6] = "        return \"Hello, \\(name)! Welcome — 歡迎.\"" }
            if offset == 2 { lines[10] = "// UTF-8 stays intact: café · 雪 · 🐢"; lines.insert("// Every line keeps its author and revision.", at: 11) }
            try Data(lines.joined(separator: "\n").utf8).write(to: file)
            for (key, value) in [("user.name", commit.0), ("user.email", commit.1)] { _ = try await repo.run(["config", key, value]) }
            try await repo.stage([path])
            let date = "2026-10-\(16 + offset)T10:00:00+00:00"
            _ = try await repo.run(["commit", "-m", commit.2], environmentOverrides: ["GIT_AUTHOR_DATE": date, "GIT_COMMITTER_DATE": date])
        }
        let baselinePaths = [".git/index", ".git/HEAD", ".git/config", path], baseline = try baselinePaths.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let suite = "TurtleGit.BlamePaneCapture." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!, clipboard = NSPasteboard.withUniqueName()
        preferences.set(false, forKey: "EnableGravatar"); preferences.set(false, forKey: "EnableLogCache")
        preferences.set(true, forKey: "Blame.ShowLog"); preferences.set(true, forKey: "Blame.ShowProperties")
        preferences.set(230, forKey: "Blame.Pane.Dock.bottom.Extent"); preferences.set(380, forKey: "Blame.Pane.Dock.right.Extent")
        DialogGeometry.install(preferences: preferences)
        defer { DialogGeometry.install(preferences: .standard); clipboard.releaseGlobally(); preferences.removePersistentDomain(forName: suite) }
        let controller = BlameWindowController(repository: repo, access: nil, path: path, revision: "HEAD", options: GitBlameOptions(), preferences: preferences, requireScope: false)
        let model = controller.model, window = controller.window!
        window.animationBehavior = .none
        model.writeClipboard = { text in clipboard.clearContents(); clipboard.setString(text, forType: .string) }
        defer { window.orderOut(nil); controller.close() }
        let available = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 900)
        window.setContentSize(NSSize(width: min(1280, available.width - 30), height: min(800, available.height - 55))); window.center()
        // AppKit calculates actual clip visibility only after the window joins
        // WindowServer. This initial layout remains completely transparent.
        NSApplication.shared.setActivationPolicy(.accessory)
        window.alphaValue = 0; window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        try await wait("Actual Blame document, history or syntax did not settle") { !model.busy && !model.syntaxWorking && model.error == nil && model.syntaxError == nil && model.historyEntries.count == 3 && !model.lines.isEmpty }
        let selected = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        model.selectedLogHashes = [selected]; model.revisionDetails.basicExpanded = true; model.revisionDetails.parentsExpanded = true; model.revisionDetails.selection = "basic.8"
        try await wait("Native Properties grid did not render the complete selected revision") {
            window.contentView?.layoutSubtreeIfNeeded()
            return views(window.contentView).compactMap { $0 as? NSTableView }.contains { $0.accessibilityLabel() == "Blame revision properties" && $0.numberOfRows >= 12 }
        }
        let parent = try requireParent(model)
        let property = try XCTable(window, label: "Blame revision properties"), history = try XCTable(window, label: "Blame Log")
        // Startup frame restoration can save intermediate dock extents. Adjust
        // the actual native dividers after the settled window, as a user would.
        let splits = views(window.contentView).compactMap { $0 as? NSSplitView }
        if let split = splits.first(where: { !$0.isVertical && $0.arrangedSubviews.count == 2 && views($0).contains(where: { $0 === property }) && views($0).contains(where: { $0 === history }) }) {
            split.setPosition(split.bounds.height - 230 - split.dividerThickness, ofDividerAt: 0)
        }
        window.contentView?.layoutSubtreeIfNeeded()
        if let split = splits.first(where: { $0.isVertical && $0.arrangedSubviews.count == 2 && views($0).contains(where: { $0 === property }) && !views($0).contains(where: { $0 === history }) }) {
            split.setPosition(split.bounds.width - 380 - split.dividerThickness, ofDividerAt: 0)
        }
        window.contentView?.layoutSubtreeIfNeeded()
        // Enlarge only the real native split divider so all property rows and
        // the expanded Parents group fit in the deliberate capture geometry.
        if let split = views(window.contentView).compactMap({ $0 as? NSSplitView }).last(where: { !$0.isVertical && $0.arrangedSubviews.count == 2 && views($0).contains(where: { $0 === property }) && !views($0).contains(where: { $0 === history }) }) {
            split.setPosition(min(310, split.bounds.height - 110), ofDividerAt: 0)
        }
        try await wait("Capture geometry clips the expanded Parents group: window=" + NSStringFromRect(window.frame) + " property=" + NSStringFromRect(property.frame)) {
            window.contentView?.layoutSubtreeIfNeeded()
            return property.rows(in: property.visibleRect).length >= 12
        }
        try require(history.numberOfRows == 3, "Native Log lost source history rows")
        try require(history.visibleRect.contains(history.rect(ofRow: 2)), "Capture geometry clips the final native Log row")
        try require(!model.showGravatar, "Capture must not start public avatar traffic")
        window.orderOut(nil); window.alphaValue = 1
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        var captures: [[String: Any]] = []
        for (theme, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.alphaValue = 0; window.orderFront(nil)
            window.appearance = NSAppearance(named: theme); window.contentView?.appearance = window.appearance
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await Task.sleep(nanoseconds: 300_000_000)
            window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let destination = output.appendingPathComponent("blame-panes-" + name + ".png")
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); process.arguments = ["-x", "-o", "-l", String(window.windowNumber), destination.path]
            let errors = Pipe(); process.standardError = errors; process.standardOutput = FileHandle.nullDevice
            window.alphaValue = 1; window.orderFront(nil); window.displayIfNeeded()
            let shown = Date()
            // WindowServer gets one compositor turn; no activation or image cache.
            let visibilityLimit = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 1_800_000_000) } catch { return }
                window.orderOut(nil)
            }
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
                try process.run()
                let deadline = Date().addingTimeInterval(5)
                while process.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
                if process.isRunning { window.orderOut(nil); process.terminate(); process.waitUntilExit(); throw Failure(description: "Owned screencapture exceeded its deadline") }
                let visibleElapsed = Date().timeIntervalSince(shown)
                window.orderOut(nil); visibilityLimit.cancel()
                let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                try require(process.terminationStatus == 0, "WindowServer capture failed (no fallback image): " + errorText)
                let data = try Data(contentsOf: destination)
                guard let image = NSBitmapImageRep(data: data) else { throw Failure(description: "WindowServer did not return a decodable PNG") }
                var colors = Set<String>()
                for y in stride(from: 0, to: image.pixelsHigh, by: max(1, image.pixelsHigh / 40)) {
                    for x in stride(from: 0, to: image.pixelsWide, by: max(1, image.pixelsWide / 40)) {
                        if let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                            colors.insert([color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent].map { String(Int(($0 * 255).rounded())) }.joined(separator: ","))
                        }
                    }
                }
                try require(colors.count > 12, "WindowServer returned an empty/uniform native window capture; original PNG retained for diagnosis")
                print("CAPTURE \(name): visible_seconds=\(visibleElapsed), sampled_original_colors=\(colors.count), frame=\(NSStringFromRect(window.frame))")
                captures.append(["theme": name, "path": destination.path, "width": image.pixelsWide, "height": image.pixelsHigh, "window_number": window.windowNumber, "visible_seconds": visibleElapsed, "sampled_original_colors": colors.count])
            } catch { window.orderOut(nil); visibilityLimit.cancel(); if process.isRunning { process.terminate(); process.waitUntilExit() }; throw error }
        }
        controller.close(); try await drain()
        try require(try baselinePaths.map { try Data(contentsOf: root.appendingPathComponent($0)) } == baseline, "Capture changed repository/index/source bytes")
        let manifest: [String: Any] = ["capture_method": "WindowServer /usr/sbin/screencapture -x -o -l", "captures": captures, "revision": selected, "parent_label": parent.name, "parent_value": parent.value, "parent_description": parent.description, "body": commits[2].2, "history_rows": 3, "source_bytes_unchanged": true, "owned_windows_closed": true, "public_network": false]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("capture.json"))
        print("PASS Blame pane compositor capture: light/dark complete owned native window; source/index/config unchanged; no avatar traffic; windows and work drained")
    }
    @MainActor static func requireParent(_ model: BlameWindowModel) throws -> BlameRevisionDetails.Row {
        guard let entry = model.selectedHistoryEntry, let hash = entry.parents.first, let row = model.revisionDetails.parents.first else { throw Failure(description: "Selected native revision has no parent property") }
        try require(row.name == String(hash.prefix(8)) && row.description.hasPrefix("0 - " + hash + "\n"), "Native parent label/description lost source short/full hash semantics")
        return row
    }
    @MainActor static func XCTable(_ window: NSWindow, label: String) throws -> NSTableView {
        guard let table = views(window.contentView).compactMap({ $0 as? NSTableView }).first(where: { $0.accessibilityLabel() == label }) else { throw Failure(description: "Missing actual native table " + label) }; return table
    }
}
