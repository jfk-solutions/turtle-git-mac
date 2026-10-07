import AppKit
import SwiftUI
import TurtleGitCore

@main struct RollupVerification {
    @MainActor static func wait(_ model: LogWindowModel) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy && model.error == nil, model.error ?? "History did not finish")
    }
    @MainActor static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews { if let table = table(in: child) { return table } }
        return nil
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Rollup QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        var hashes: [String] = []
        for index in 0..<6 {
            try Data("\(index)".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "c\(index)")
            hashes.append(try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines))
        }
        _ = try await repo.run(["tag", "root", hashes[0]]); _ = try await repo.run(["tag", "boundary", hashes[2]])
        let paths = [".git/index", ".git/config", ".git/HEAD", "file"]
        let before = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let suite = "TurtleGit.Rollup.QA." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        // Model-specific visibility defaults are private; no avatar requests.
        defaults.set(false, forKey: "EnableGravatar")
        defer { defaults.removePersistentDomain(forName: suite) }
        let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/IssueRegex/issue-regex")
        let model = LogWindowModel(repository: repo, access: nil, labelDefaults: defaults, historyRegexExecutable: helper)
        defer { model.invalidate() }
        model.showWorkingTree = false; model.search = ""; model.searchRegex = false
        model.reload(); try await wait(model); model.toggleHistoryWalk(.compressed); try await wait(model)
        precondition(model.entries.map(\.hash) == [hashes[5], hashes[2], hashes[0]])
        precondition(model.canToggleRollup && model.rollupTitle == "Expand" && model.graph[0].collapsed)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; defer { window.close() }
        window.contentViewController = NSHostingController(rootView: LogDialog(model: model)); window.contentView?.layoutSubtreeIfNeeded()
        guard let table = table(in: window.contentView!), let menu = table.menu else { preconditionFailure("Native revision menu missing") }
        menu.delegate?.menuNeedsUpdate?(menu)
        let expand = menu.indexOfItem(withTitle: "Expand"); precondition(expand >= 0 && expand < menu.indexOfItem(withTitle: "Copy to clipboard"))
        menu.performActionForItem(at: expand); try await wait(model)
        precondition(model.entries.map(\.hash) == [hashes[5], hashes[4], hashes[3], hashes[2], hashes[0]])
        precondition(model.rollupTitle == "Collapse" && !model.graph[0].collapsed && model.entries[0].parents == [hashes[4]])
        model.select([hashes[4]]); model.toggleRollup(); try await wait(model)
        precondition(model.entries.map(\.hash) == [hashes[5], hashes[4], hashes[2], hashes[0]], "Forced mid-segment collapse did not hide the next ordinary parent")
        model.toggleRollup(); try await wait(model)
        precondition(model.entries.map(\.hash) == [hashes[5], hashes[4], hashes[3], hashes[2], hashes[0]], "Reversing override did not restore inherited expansion")
        model.select([hashes[5]])
        menu.delegate?.menuNeedsUpdate?(menu); menu.performActionForItem(at: menu.indexOfItem(withTitle: "Collapse")); try await wait(model)
        precondition(model.entries.map(\.hash) == [hashes[5], hashes[2], hashes[0]])
        model.select([hashes[2]]); model.toggleRollup(); try await wait(model)
        precondition(model.entries.map(\.hash) == [hashes[5], hashes[2], hashes[1], hashes[0]])
        model.select([hashes[1]]); precondition(model.rollupTitle == "Collapse"); model.toggleRollup(); try await wait(model)
        precondition(model.rollupInfo[hashes[1]]?.forced == true)
        model.select([hashes[5], hashes[2]]); precondition(!model.canToggleRollup)
        model.search = "c"; model.reload(); try await wait(model); precondition(!model.canToggleRollup)
        model.search = "["; model.searchRegex = true; model.reload(); try await wait(model); model.select([hashes[5]])
        precondition(model.canToggleRollup, "Invalid regex did not retain source inactive-filter behavior")
        model.busy = true; precondition(!model.canToggleRollup); model.toggleRollup(); model.busy = false
        model.invalidate(); precondition(!model.canToggleRollup)
        let after = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }; precondition(before == after)
        print("Native rollup: actual Expand/Collapse menu routing, linear label boundaries, mid-segment forced collapse, hollow state, parent preservation, multiple/busy/closed/search guards and invalid regex passed; repository unchanged")
    }
}
