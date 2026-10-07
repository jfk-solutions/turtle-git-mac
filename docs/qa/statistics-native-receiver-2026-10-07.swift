import AppKit
import Foundation
import TurtleGitCore

@main struct StatisticsNativeVerification {
    @MainActor static func wait(_ model: StatisticsWindowModel) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy, "Statistics timed out")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        _ = try await repo.run(["config", "user.name", "Statistics QA"])
        _ = try await repo.run(["config", "user.email", "qa@example.invalid"])
        _ = try await repo.run(["config", "commit.gpgsign", "false"])
        _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        try Data("one\ntwo\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "base")
        try Data("one\nthree\n".utf8).write(to: root.appendingPathComponent("file")); try await repo.stage(["file"]); _ = try await repo.commit(message: "change")
        let entries = try await repo.history()
        let paths = [".git/index", ".git/config", ".git/HEAD", "file"]
        let before = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let suite = "TurtleGit.Statistics.QA." + UUID().uuidString
        let isolated = UserDefaults(suiteName: suite)!
        defer { isolated.removePersistentDomain(forName: suite) }
        let controller = StatisticsWindowController(repository: repo, access: nil, entries: entries, defaults: isolated)
        defer { controller.close() }
        let model = controller.model
        precondition(model.metric == .statistics && model.options == LogStatisticsOptions() && model.summary?.totalCommits == 2)
        model.selectMetric(.commitsByDate); precondition(model.graph?.points.reduce(0) { $0 + $1.value } == 2)
        model.selectMetric(.linesIncluding); try await wait(model)
        precondition(model.error == nil && model.summary?.changesCalculated == true && model.summary?.totalChanges.files == 2)
        precondition(model.graph?.points.reduce(0) { $0 + $1.value } == 4)
        model.selectMetric(.commitsByDate)
        for style in LogStatisticsStyle.allCases { model.style = style; controller.window?.contentView?.layoutSubtreeIfNeeded(); await Task.yield() }
        model.selectMetric(.authorship); precondition(model.graph?.points.map(\.value) == [100])
        model.options.useCommitterNames = true; model.options.caseSensitive = false; model.rebuild(resetAuthors: true)
        model.style = .pie
        var closed = false; controller.onClosed = { closed = true }
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: controller.window!.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        precondition(controller.window!.performKeyEquivalent(with: escape) && closed)
        let restored = StatisticsWindowModel(repository: repo, access: nil, entries: entries, defaults: isolated)
        precondition(restored.metric == .authorship && restored.style == .pie && restored.options.useCommitterNames && !restored.options.caseSensitive)
        restored.start(); restored.cancel(); try await wait(restored)
        precondition(restored.error != nil && restored.summary?.changesCalculated == false)
        let after = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }; precondition(before == after)
        print("Native Statistics: defaults, snapshot graphs, actual lazy diff totals, automatic calculation, preference restoration, cancellation and unchanged repository passed")
    }
}
