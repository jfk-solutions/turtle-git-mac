import AppKit
import TurtleGitCore

@main struct ReferenceTrackingVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func find<T: NSView>(_ type: T.Type, _ view: NSView, label: String) -> T? {
        if let result = view as? T, result.accessibilityLabel() == label { return result }
        for child in view.subviews { if let result = find(type, child, label: label) { return result } }; return nil
    }
    @MainActor static func wait(_ windows: [NSWindow], _ ready: () -> Bool) async throws {
        for _ in 0..<3000 { windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }; if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Timed out")
    }
    @MainActor static func main() async { do { try await verify() } catch { print("FAIL: \(error)"); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.ReferenceTracking.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        print("PREFERENCES: " + suite)
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Tracking QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("base\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.run(["commit", "-m", "base"])
        _ = try await repo.run(["remote", "add", "origin", "https://example.invalid/unused"])
        _ = try await repo.run(["update-ref", "refs/remotes/origin/main", "HEAD"]); _ = try await repo.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        _ = try await repo.run(["tag", "release"]); _ = try await repo.run(["update-ref", "refs/notes/custom", "HEAD"])
        try await repo.updateBranchDescription("main", message: "keep description")
        _ = try await repo.run(["config", "branch.main.pushRemote", "other"])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index")), file = try Data(contentsOf: root.appendingPathComponent("file"))
        let browser = ReferenceBrowserWindowController(repository: repo, access: nil, initial: "refs/heads/main", preferences: prefs, onChoose: { _ in })
        defer { browser.close() }; let window = browser.window!
        var logs: [String] = []; browser.model.onLog = { logs.append($0) }
        browser.presentTrackingPicker = { parent, _ in parent.makeFirstResponder(nil); return true }
        browser.configureTrackingPicker = { _ in print("CHILD CREATED"); fflush(stdout) }
        browser.model.load(); try await wait([window]) { !browser.model.busy && browser.model.snapshot != nil }
        guard let table = find(NSTableView.self, window.contentView!, label: "References"), let menu = table.menu else { throw Failure(description: "Native table/menu absent") }
        func invoke(_ title: String) throws {
            window.contentView?.layoutSubtreeIfNeeded()
            guard let currentTable = find(NSTableView.self, window.contentView!, label: "References"), let currentMenu = currentTable.menu else { throw Failure(description: "Current native menu absent") }
            if currentTable !== table { print("Reacquired native table/menu after SwiftUI update; old menu delegate present=\(menu.delegate != nil)"); fflush(stdout) }
            currentMenu.delegate?.menuNeedsUpdate?(currentMenu)
            guard let item = currentMenu.items.first(where: { $0.title == title }), item.isEnabled, item.target != nil else { throw Failure(description: "Menu missing/disabled/target absent: " + title) }
            try require(item.image != nil, "Requested original artwork adaptation")
            print("ACTION \(title), target \(type(of: item.target!)), window exists=\(browser.window != nil), sheet=\(browser.window?.attachedSheet != nil)"); fflush(stdout)
            _ = (item.target as? NSObject)?.perform(item.action!)
        }
        var pickerCount = 0
        func picker() async throws -> ReferenceBrowserWindowController {
            pickerCount += 1; print("PICKER: \(pickerCount) parent closed=\(browser.model.closed) busy=\(browser.model.busy) selected=\(browser.model.selected?.rawValue ?? "nil")"); fflush(stdout)
            try invoke("Select tracked branch")
            guard let child = browser.trackingPicker else { throw Failure(description: "Owned remote picker absent at call \(pickerCount); hasChild=\(browser.model.hasChild) canChange=\(browser.model.canChangeTracking)") }
            try await wait([window, child.window!]) { !child.model.busy && child.model.snapshot != nil }
            try require(child.model.scope == .remotes && child.model.preferences === prefs, "Remote-only scope/private prefs")
            try require(child.model.snapshot!.references.allSatisfy { GitReferenceName.removingPrefix("refs/remotes/", from: $0.name.rawValue) != nil } && !child.model.folders.contains("refs/heads") && !child.model.folders.contains("refs/tags"), "Excluded namespaces")
            try require(find(NSOutlineView.self, child.window!.contentView!, label: "Reference namespaces") != nil && find(NSTableView.self, child.window!.contentView!, label: "References") != nil, "Actual namespace tree/list")
            try require(browser.model.hasChild && !browser.model.canAccept && !browser.windowShouldClose(window) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Parent/close/Quit gates")
            browser.selectTracking(); browser.model.unsetTracking(); browser.model.load()
            try require(browser.trackingPicker === child && !browser.model.busy, "Duplicate and competing operation gates")
            return child
        }
        let before = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let cancelled = try await picker(); cancelled.model.cancel()
        try require(browser.trackingPicker == nil && !browser.model.hasChild && before == Data(contentsOf: root.appendingPathComponent(".git/config")), "Cancel retains config/releases child")
        let selected = try await picker()
        let choice = selected.model.snapshot!.initialSelection("refs/remotes/origin/main"); selected.model.folder = choice.folder; selected.model.selected = choice.reference
        selected.model.onLog?("refs/remotes/origin/main"); try require(logs == ["refs/remotes/origin/main"], "Inherited canonical context callback")
        selected.model.accept()
        try require(browser.model.changingTracking && browser.model.busy, "Tracking write active")
        browser.model.load(); try require(browser.model.changingTracking && browser.model.busy, "F5 cannot supersede mutation")
        try await wait([window]) { browser.trackingPicker == nil && !browser.model.busy }
        try require(browser.model.chosen?.upstream == "origin/main", "Set and refresh original selection")
        try invoke("Unset tracked branch"); try await wait([window]) { !browser.model.busy }
        try require(browser.model.chosen?.upstream == "" && browser.model.chosen?.description == "keep description", "Unset keeps branch description")
        let pushRemote = try await repo.run(["config", "--get", "branch.main.pushRemote"]).text; try require(pushRemote == "other\n", "Unset keeps push remote")
        _ = try await repo.run(["config", "--replace-all", "remote.origin.fetch", "+refs/heads/other:refs/remotes/origin/other"])
        let config = try Data(contentsOf: root.appendingPathComponent(".git/config"))
        let invalid = try await picker(); let invalidChoice = invalid.model.snapshot!.initialSelection("refs/remotes/origin/main"); invalid.model.folder = invalidChoice.folder; invalid.model.selected = invalidChoice.reference; invalid.model.accept()
        try await wait([window]) { browser.trackingPicker == nil && !browser.model.busy }
        try require(browser.model.error?.contains("fetch setting") == true && config == Data(contentsOf: root.appendingPathComponent(".git/config")), "Fetch mapping failure/error preserves config")
        try await wait([window]) { window.attachedSheet != nil }
        browser.selectTracking(); try require(browser.trackingPicker == nil, "Error alert blocks competing picker")
        func okay(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == "OK" { return button }
            for child in view.subviews { if let result = okay(child) { return result } }; return nil
        }
        guard let alertView = window.attachedSheet?.contentView, let alertOK = okay(alertView) else { throw Failure(description: "Actual error alert OK button absent") }
        alertOK.performClick(nil)
        try await wait([window]) { window.attachedSheet == nil && browser.model.error == nil }
        browser.presentTrackingPicker = { _, _ in false }; browser.selectTracking()
        try require(browser.trackingPicker == nil && !browser.model.hasChild, "Rejected child cleanup")
        for reference in ["refs/tags/release", "refs/remotes/origin/main", "refs/notes/custom"] {
            browser.model.folder = "refs"; browser.model.selected = GitReferenceName(reference)
            try require(!browser.model.canChangeTracking, "Nonlocal gate"); browser.selectTracking(); try require(browser.trackingPicker == nil, "Nonlocal command rejected")
        }
        let bareRoot = root.appendingPathComponent("bare.git"); _ = try await repo.run(["clone", "--bare", root.path, bareRoot.path])
        let bare = ReferenceBrowserWindowController(repository: GitRepository(root: bareRoot, executable: repo.executable), access: nil, initial: "refs/heads/main", preferences: prefs, onChoose: { _ in }); defer { bare.close() }
        bare.model.load(); try await wait([bare.window!]) { !bare.model.busy && bare.model.snapshot != nil }
        try require(bare.model.bare && !bare.model.canChangeTracking, "Bare tracking gate"); bare.selectTracking(); try require(bare.trackingPicker == nil, "Bare child absent"); bare.close()
        browser.model.folder = "refs/heads"; browser.model.selected = "refs/heads/main"; browser.presentTrackingPicker = { parent, _ in print("FORCED PRESENT"); fflush(stdout); parent.makeFirstResponder(nil); return true }
        let forced = try await picker(); browser.close(); forced.model.selected = "refs/remotes/origin/main"; forced.model.accept()
        try require(browser.model.closed && forced.model.closed && browser.trackingPicker == nil && config == Data(contentsOf: root.appendingPathComponent(".git/config")), "Forced cleanup/stale child no write")
        let after = try await repo.run(["rev-parse", "HEAD"]).stdout; try require(head == after && index == Data(contentsOf: root.appendingPathComponent(".git/index")) && file == Data(contentsOf: root.appendingPathComponent("file")), "HEAD/index/worktree unchanged")
        try require(NSApplication.shared.windows.allSatisfy { !$0.isVisible }, "No displayed windows")
        print("PASS: tracking menus, full remote-only browser, canonical inherited callback, set/unset/config retention, fetch-mapping error, cancel/parent/Quit/type/bare/reject/stale/forced cleanup")
    }
}
