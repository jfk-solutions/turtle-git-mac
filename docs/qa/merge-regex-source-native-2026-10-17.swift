// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

struct MergeRegexSourceVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ yes: Bool, _ message: String) throws { if !yes { throw Failure(description: message) } }
    @MainActor static func wait(_ yes: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<2000 { if yes() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Regex source timeout at \(line)")
    }
    @MainActor static func capture(_ window: NSWindow, name: String, folder: URL) async throws {
        guard #available(macOS 14.4, *) else { throw Failure(description: "Capture requires macOS 14.4") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance); window.alphaValue = 1; window.orderFront(nil); window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 250_000_000)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure(description: "Capture owner missing") }
            let options = SCStreamConfiguration(); options.includeChildWindows = false; options.width = Int(window.frame.width*2); options.height = Int(window.frame.height*2); options.showsCursor = false
            let pixels = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: options)
            guard let data = NSBitmapImageRep(cgImage: pixels).representation(using: .png, properties: [:]) else { throw Failure(description: "PNG missing") }
            try data.write(to: folder.appendingPathComponent(name + "-" + suffix + ".png"))
        }; window.orderOut(nil); window.alphaValue = 0
    }
    @MainActor static func verify(parser: URL) async throws {
        let suite = "TurtleGit.RegexSource." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitRegexSource-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let versions = MergeRegexFilter(name: "Versions", expression: "[0-9]+", replacement: "")
        let timestamps = MergeRegexFilter(name: "Timestamps", expression: "date=.*", replacement: "date=")
        try MergeRegexFilters.save([versions, timestamps], defaults: prefs)
        let list = MergeRegexFilterListController(defaults: prefs); list.executable = parser
        defer { list.retire() }
        let model = list.model, oldContext = model.context
        list.window?.alphaValue = 0; list.window?.orderFront(nil)
        try require(model.selected == nil && model.canEdit, "List initial selection/state")
        var closeCount = 0; list.onClosed = { closeCount += 1 }
        model.requestEdit(versions, context: oldContext)
        guard let child = list.editor else { throw Failure(description: "Child sheet missing") }
        try require(child.window?.sheetParent === list.window && child.window?.title == "Regex Filter" && (child.window?.frame.width ?? 0) >= 520 && !model.canEdit && MergeRegexFilterListController.activeEditors == 1, "Owned child session missing")
        try require(!list.windowShouldClose(list.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Child allowed close/Quit")
        model.remove(); model.saveAndClose(); model.cancel(); model.accept(timestamps, oldName: "Versions"); model.requestEdit(nil, context: oldContext)
        try require(model.filters == [versions,timestamps] && list.editor === child && !model.retired && MergeRegexFilters.load(defaults: prefs) == [versions,timestamps], "Parent changed through attached child")
        child.model.expression = "("; let staleField = child.model.field(\.expression)
        child.model.accept(); child.model.accept()
        try require(MergeRegexOperations.activeRequests == 1 && child.model.validating, "Duplicate validation started")
        try await wait { !child.model.validating }
        try require(child.model.error != nil && list.editor === child && !child.model.retired, "Invalid expression closed or accepted")
        staleField.wrappedValue = "stale"
        try require(child.model.expression == "(", "Pre-validation field binding survived")
        child.model.field(\.expression).wrappedValue = "([0-9]+)"
        child.model.name = "Releases"; child.model.replacement = "$1"
        child.model.accept()
        try await wait { list.editor == nil && MergeRegexOperations.activeRequests == 0 }
        let releases = MergeRegexFilter(name: "Releases", expression: "([0-9]+)", replacement: "$1")
        try require(model.filters == [timestamps,releases] && model.selected == releases && child.model.retired && MergeRegexFilterListController.activeEditors == 0, "Rename/child acceptance not transactional")
        child.model.accept(); child.cancel(); child.model.accepted(versions)
        model.remove(timestamps, context: oldContext); model.requestEdit(versions, context: oldContext)
        try require(model.filters == [timestamps,releases] && list.editor == nil && MergeRegexFilters.load(defaults: prefs) == [versions,timestamps], "Stale child/menu changed draft or persisted early")
        // Native Cancel and external endSheet must settle just this child once.
        model.requestEdit(nil, context: model.context)
        guard let cancelled = list.editor else { throw Failure(description: "Add sheet missing") }
        cancelled.model.name = "Cancelled"; cancelled.model.expression = "x"
        cancelled.model.cancel(); cancelled.model.accept()
        try require(list.editor == nil && model.canEdit && model.filters == [timestamps,releases], "Cancel retained a child/draft")
        model.requestEdit(releases, context: model.context)
        guard let external = list.editor, let sheet = external.window else { throw Failure(description: "External sheet missing") }
        list.window?.endSheet(sheet, returnCode: .cancel)
        try await wait { list.editor == nil }
        try require(external.model.retired && MergeRegexFilterListController.activeEditors == 0, "External sheet completion retained child")
        model.saveAndClose(); model.saveAndClose(); model.accept(versions, oldName: nil)
        try require(model.retired && closeCount == 1 && MergeRegexFilters.load(defaults: prefs) == [timestamps,releases], "Outer OK did not settle once")
        // Closed list callbacks cannot persist a discarded draft.
        let discarded = MergeRegexFilterListController(defaults: prefs); defer { discarded.retire() }
        discarded.model.remove(); discarded.model.accept(versions, oldName: nil); discarded.window?.close(); discarded.model.saveAndClose()
        try require(MergeRegexFilters.load(defaults: prefs) == [timestamps,releases], "Closed list saved late")
        // Keep an older list's draft if another owner saves shared definitions.
        let first = MergeRegexFilterListController(defaults: prefs), second = MergeRegexFilterListController(defaults: prefs)
        defer { first.retire(); second.retire() }
        first.model.accept(versions, oldName: nil); second.model.accept(.init(name: "Other", expression: "z", replacement: ""), oldName: nil); second.model.saveAndClose()
        let concurrent = MergeRegexFilters.load(defaults: prefs)
        first.model.saveAndClose()
        try require(!first.model.retired && first.model.error != nil && first.model.filters.contains(versions) && MergeRegexFilters.load(defaults: prefs) == concurrent, "Older list overwrote another window")
        first.model.cancel(); first.model.saveAndClose()
        try require(MergeRegexFilters.load(defaults: prefs) == concurrent, "Cancelled conflict draft saved late")
        // A changed captured value is not validated by an earlier helper result.
        let changed = MergeRegexFilterEditModel(filter: versions); changed.executable = parser
        var accepted = 0; changed.accepted = { _ in accepted += 1 }
        changed.accept(); changed.replacement = "changed after validation started"
        try await wait { !changed.validating && MergeRegexOperations.activeRequests == 0 }
        try require(accepted == 0 && changed.error != nil && !changed.retired, "Changed draft accepted with earlier validation")
        changed.name = "   "; changed.accept()
        try require(!changed.validating && changed.error != nil, "Whitespace-only name started validation")
        changed.retire()
        // Forced owner close retires delivery; the helper task retains Quit until drain.
        let slow = root.appendingPathComponent("slow-regex")
        try Data("#!/bin/sh\n/bin/sleep 2\nexit 1\n".utf8).write(to: slow)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: slow.path)
        let closing = MergeRegexFilterListController(defaults: prefs); closing.executable = slow
        defer { closing.retire() }
        closing.window?.alphaValue = 0; closing.window?.orderFront(nil)
        closing.model.requestEdit(concurrent[0], context: closing.model.context)
        guard let late = closing.editor else { throw Failure(description: "Retirement sheet missing") }
        late.model.accept(); closing.retire()
        try require(late.model.retired && closing.model.retired && MergeRegexFilterListController.activeEditors == 0 && MergeRegexOperations.activeRequests == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel, "Retirement released pending validation")
        late.model.accepted(versions); late.cancel(); closing.model.saveAndClose()
        try await wait { MergeRegexOperations.activeRequests == 0 }
        try require(MergeRegexFilters.load(defaults: prefs) == concurrent, "Late validation changed storage")
        if let path = ProcessInfo.processInfo.environment["TURTLEGIT_REGEX_SOURCE_CAPTURE"] {
            let gallery = MergeRegexFilterListController(defaults: prefs)
            let editor = MergeRegexFilterEditController(filter: releases, executable: parser)
            defer { gallery.retire(); editor.cancel() }
            try await capture(gallery.window!, name: "merge-regex-list-source", folder: URL(fileURLWithPath: path))
            try await capture(editor.window!, name: "merge-regex-editor-source", folder: URL(fileURLWithPath: path))
        }
        try require(MergeRegexFilterListController.activeEditors == 0 && MergeRegexOperations.activeRequests == 0, "Owned regex work retained")
        print("PASS native regex source: owned list/editor, source actions, invalid regex correction, single acceptance/Cancel/external completion, captured draft/menu guards, concurrent-save refusal, parent retirement and independent helper drain")
    }
}
