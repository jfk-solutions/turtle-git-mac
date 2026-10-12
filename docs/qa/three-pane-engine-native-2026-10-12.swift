import AppKit
import Foundation
import TurtleGitCore

@main struct ThreePaneEngineVerification {
    @MainActor static func editableView(_ view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let text = view as? NSTextView, text.isEditable, !text.isFieldEditor { return text }
        return view.subviews.compactMap { editableView($0) }.first
    }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        preconditionFailure("Timed out waiting for three-pane engine work")
    }
    @MainActor static func capture(_ window: NSWindow, to directory: URL, dark: Bool) async throws {
        // Diagnostic only: hidden NSHosting captures can omit SwiftUI labels.
        // Inspect every output and reject incomplete captures before publishing.
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        try await Task.sleep(nanoseconds: 100_000_000)
        guard let view = window.contentView else { preconditionFailure("Missing production content view") }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { preconditionFailure("Could not capture native content") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // Offscreen hosting content can have transparent window-background
        // pixels. Flatten against the real window's current appearance.
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill(); NSBezierPath(rect: NSRect(origin: .zero, size: view.bounds.size)).fill()
            bitmap.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rendered = NSBitmapImageRep(data: tiff),
              let png = rendered.representation(using: .png, properties: [:]) else { preconditionFailure("Could not encode native capture") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(dark ? "three-pane-engine-dark.png" : "three-pane-engine-light.png"))
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let configuration = SubversionMergeConfiguration(executable: URL(fileURLWithPath: CommandLine.arguments[1]), runtimeRoot: URL(fileURLWithPath: CommandLine.arguments[2]), regexExecutable: URL(fileURLWithPath: CommandLine.arguments[3]))
        try await verify(configuration: configuration, screenshots: CommandLine.arguments.count > 4 ? URL(fileURLWithPath: CommandLine.arguments[4]) : nil)
    }
    @MainActor static func verify(configuration: SubversionMergeConfiguration, screenshots: URL? = nil) async throws {
        let discovered = try SubversionMergeConfiguration.bundled()
        precondition(discovered.executable.resolvingSymlinksInPath().path == configuration.executable.resolvingSymlinksInPath().path)
        precondition(discovered.runtimeRoot.resolvingSymlinksInPath().path == configuration.runtimeRoot.resolvingSymlinksInPath().path)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitThreePaneEngine-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "TurtleGit.ThreePaneEngine." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let repository = GitRepository(root: root, executable: URL(fileURLWithPath: "/usr/bin/git")), file = root.appendingPathComponent("sample.cpp")
        _ = try await repository.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Native engine QA"), ("user.email", "engine@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"), ("core.autocrlf", "false")] { _ = try await repository.run(["config", key, value]) }
        try Data("version 1\nbase\nlast\n".utf8).write(to: file)
        _ = try await repository.run(["add", "--", "sample.cpp"]); _ = try await repository.run(["commit", "-m", "base"])
        _ = try await repository.run(["checkout", "-b", "side"])
        try Data("version 3\ntheirs\nlast\n".utf8).write(to: file); _ = try await repository.run(["commit", "-am", "theirs"])
        _ = try await repository.run(["checkout", "main"])
        try Data("version 2\nmine\nlast\n".utf8).write(to: file); _ = try await repository.run(["commit", "-am", "mine"])
        _ = try await repository.run(["merge", "side"], successfulExitCodes: 0...1)
        let index = try Data(contentsOf: root.appendingPathComponent(".git/index")), working = try Data(contentsOf: file)
        let head = try await repository.run(["rev-parse", "HEAD"]).stdout
        let filter = MergeRegexFilter(name: "Ignore version numbers", expression: "[0-9]+", replacement: "")
        try MergeRegexFilters.save([filter], defaults: defaults)
        let controller = TextConflictWindowController(repository: repository, access: nil, path: "sample.cpp"), model = controller.model
        model.comparisonDefaults = defaults; model.regexDefaults = defaults; model.refreshRegexFilters(); model.load()
        try await wait { !model.busy && model.document != nil }
        precondition(model.document?.mergeSources != nil && model.blocks.count == 1 && !model.dirty && model.supportsComments)
        model.selectRegexFilter(filter.name); try await wait { !model.busy }
        precondition(model.regexFilterName == filter.name && model.sourceComparison?.rows[0].mine.state == .filtered)
        precondition(model.result.hasPrefix("version 2\n") && model.blocks.count == 1)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        try await wait { !model.busy }
        try await wait { editableView(controller.window?.contentView) != nil }
        if let screenshots, let window = controller.window {
            try await capture(window, to: screenshots, dark: false); try await capture(window, to: screenshots, dark: true)
        }
        guard let replace = model.replaceEntireResult else { preconditionFailure("Production merged text view did not install Undo hooks") }
        let generated = model.result
        replace(model.result + "manual edit\n")
        try await wait { model.canUndo }
        precondition(model.dirty && model.canUndo)
        model.chooseReload = { .cancel }; model.selectRegexFilter(nil)
        precondition(model.regexFilterName == filter.name && model.dirty && model.result.hasSuffix("manual edit\n"))
        let originalOptions = model.comparisonOptions
        model.setComparisonOptions(.init(whitespace: .ignoreAll, ignoreCase: true, ignoreEndings: false))
        precondition(model.comparisonOptions == originalOptions && MergeComparisonOptions.load(from: defaults) == originalOptions)
        model.undo(); precondition(model.result == generated && !model.dirty)
        let requestedOptions = MergeComparisonOptions(whitespace: .ignoreChanges, ignoreCase: true, ignoreEndings: false, ignoreComments: true)
        model.setComparisonOptions(requestedOptions); try await wait { !model.busy }
        precondition(model.comparisonOptions == requestedOptions && MergeComparisonOptions.load(from: defaults) == requestedOptions)
        model.selectRegexFilter(nil); try await wait { !model.busy }
        try await wait { editableView(controller.window?.contentView) != nil }
        precondition(model.regexFilterName == nil && model.sourceComparison?.rows[0].mine.state != .filtered && !model.canUndo)
        model.selectRegexFilter(filter.name); try await wait { !model.busy }
        try await wait { editableView(controller.window?.contentView) != nil }
        replace(model.result + "discard me\n")
        model.chooseReload = { .discard }; model.load(); try await wait { !model.busy }
        try await wait { editableView(controller.window?.contentView) != nil }
        precondition(model.regexFilterName == filter.name && !model.result.contains("discard me"))
        let afterWorking = try Data(contentsOf: file), afterIndex = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        precondition(afterWorking == working && afterIndex == index)
        model.choose(.mine); precondition(!MergeText.hasMarkers(model.result) && model.dirty)
        model.chooseReload = { .save }; model.selectRegexFilter(nil); try await wait { !model.busy }
        try await wait { editableView(controller.window?.contentView) != nil }
        let savedBeforeReload = try Data(contentsOf: file), indexBeforeResolution = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        precondition(savedBeforeReload == Data("version 2\nmine\nlast\n".utf8) && indexBeforeResolution == index)
        precondition(model.regexFilterName == nil && model.blocks.count == 1)
        model.choose(.mine); precondition(!MergeText.hasMarkers(model.result))
        model.save(markResolved: true); try await wait { !model.busy && MergeRegexOperations.activeRequests == 0 }
        let stages = try await repository.conflicts(), afterHead = try await repository.run(["rev-parse", "HEAD"]).stdout
        let resolved = try Data(contentsOf: file)
        precondition(stages.isEmpty && afterHead == head && resolved == Data("version 2\nmine\nlast\n".utf8))
        controller.window?.close()
        // A fresh conflict tests standard Close during a pending preparation.
        _ = try await repository.run(["reset", "--hard", "HEAD"])
        _ = try await repository.run(["merge", "side"], successfulExitCodes: 0...1)
        let slow = root.appendingPathComponent("slow-adapter")
        try Data("#!/bin/sh\n/bin/sleep 2\nexit 1\n".utf8).write(to: slow)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: slow.path)
        var stalledConfiguration = configuration; stalledConfiguration.executable = slow
        let stalled = TextConflictWindowController(repository: repository, access: nil, path: "sample.cpp")
        stalled.model.engineConfiguration = stalledConfiguration; stalled.model.load()
        precondition(stalled.model.preparing); stalled.window?.performClose(nil)
        try await wait { MergeRegexOperations.activeRequests == 0 }
        precondition(stalled.model.document == nil && stalled.model.error == nil)
        stalled.window?.close()
        print("Three-pane Subversion integration: production panes/result, green regex rows, original Mine preference, Cancel/Undo, No Filter, discard and Save-before-Reload, unchanged Git state before Save, explicit resolution, HEAD preservation and standard Close cancellation passed. Owned windows/helpers closed; private repository/preferences only.")
    }
}
