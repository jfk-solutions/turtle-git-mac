import AppKit
import SwiftUI
import TurtleGitCore

@main struct HistoryLimitVerification {
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func settle(_ host: NSView) async throws {
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
    }
    @MainActor static func wait(_ model: LogWindowModel) async throws {
        let deadline = Date().addingTimeInterval(45)
        while model.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!model.busy && model.error == nil, model.error ?? "History timeout")
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.HistoryLimit.Native.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        let repo = GitRepository(root: URL(fileURLWithPath: CommandLine.arguments[1]), executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "Scope QA"), ("user.email", "qa@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        try Data("fixture\n".utf8).write(to: repo.root.appendingPathComponent("file.txt"))
        try await repo.stage(["file.txt"]); _ = try await repo.commit(message: "root")
        let tree = try await repo.run(["rev-parse", "HEAD^{tree}"]).text.trimmingCharacters(in: .newlines)
        var parent = try await repo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        for index in 1...204 { parent = try await repo.run(["commit-tree", tree, "-p", parent, "-m", "scope-\(index)"]).text.trimmingCharacters(in: .newlines) }
        _ = try await repo.run(["update-ref", "refs/heads/main", parent])
        let paths = [".git/HEAD", ".git/index", ".git/config", ".git/refs/heads/main", "file.txt"]
        let before = try paths.map { try Data(contentsOf: repo.root.appendingPathComponent($0)) }
        prefs.set(false, forKey: "LogIncludeWorkingTreeChanges")
        let model = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs)
        defer { model.invalidate() }; model.search = ""; model.searchRegex = false
        model.reload(); try await wait(model)
        precondition(model.historyLimit.scale == .noLimit && model.entries.count == 205, "Default source scope must exceed the previous 200-row batch")

        let settings = HistoryLimitSettingsModel(defaults: prefs)
        let host = NSHostingView(rootView: HistoryLimitSettings(model: settings).defaultAppStorage(prefs))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 480, height: 230), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; defer { window.close() }
        try await settle(host)
        func button(_ title: String) -> NSButton { descendants(host).compactMap { $0 as? NSButton }.first { $0.title == title }! }
        let picker = descendants(host).compactMap { $0 as? NSPopUpButton }.first!
        precondition(picker.itemTitles == HistoryLimitScale.allCases.map(\.title), "Actual native picker order must match source")
        precondition(!button("Apply").isEnabled)
        for scale in HistoryLimitScale.allCases {
            settings.choose(scale); try await settle(host)
            let field = descendants(host).compactMap { $0 as? NSTextField }.first { $0.isEditable }!
            precondition(field.isEnabled == scale.requiresNumber, "Numeric input enablement must follow source scale")
            precondition(settings.numberText == (scale.requiresNumber ? "1" : ""))
        }
        settings.choose(.commits); settings.numberText = "3"; try await settle(host)
        precondition(button("Apply").isEnabled); button("Apply").performClick(nil); try await settle(host)
        precondition(HistoryLimitDefaults.load(defaults: prefs) == .init(scale: .commits, number: 3) && !settings.modified && !button("Apply").isEnabled)
        settings.choose(.weeks); settings.numberText = "5"; try await settle(host); button("Cancel").performClick(nil); try await settle(host)
        precondition(settings.scale == .commits && settings.numberText == "3" && !settings.modified)
        settings.choose(.months); settings.numberText = "0"; try await settle(host); button("Apply").performClick(nil); try await settle(host)
        precondition(HistoryLimitDefaults.load(defaults: prefs) == .init(scale: .months, number: 3) && settings.numberText == "0" && !settings.modified)

        HistoryLimitDefaults.apply(scale: .commits, numberText: "3", defaults: prefs)
        let count = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs)
        defer { count.invalidate() }; count.search = ""; count.searchRegex = false; count.endRevision = "HEAD"
        count.reload(); try await wait(count)
        precondition(count.entries.count == 3 && count.historyLimit.scale == .commits && count.historyLimitTitle == "Last 3 commit(s)")
        HistoryLimitDefaults.apply(scale: .weeks, numberText: "2", defaults: prefs)
        let ranged = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs)
        defer { ranged.invalidate() }; ranged.search = ""; ranged.searchRegex = false; ranged.endRevision = "HEAD"
        ranged.reload(); try await wait(ranged)
        precondition(ranged.historyLimit.scale == .noLimit && ranged.entries.count == 205)
        ranged.chooseHistoryLimit(.weeks); try await wait(ranged)
        precondition(ranged.historyLimit.scale == .weeks && ranged.historyLimit.number == 2 && ranged.entries.count == 205)

        HistoryLimitDefaults.apply(scale: .selectedDate, numberText: "ignored", defaults: prefs)
        let today = Calendar.current.startOfDay(for: Date())
        HistoryLimitDefaults.saveFrom(today, root: repo.root, defaults: prefs)
        let dated = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs)
        defer { dated.invalidate() }; dated.search = ""; dated.searchRegex = false
        precondition(dated.historyLimit.scale == .selectedDate && dated.historyLimit.from == today)
        dated.reload(); try await wait(dated); precondition(dated.entries.count == 205)
        dated.changeHistoryFrom(Date().addingTimeInterval(86400)); try await wait(dated)
        precondition(dated.historyLimit.from == HistoryLimitScope.startOfDay(dated.to), "From must clamp to To")
        dated.changeHistoryTo(Date(timeIntervalSince1970: 0)); try await wait(dated)
        precondition(dated.historyLimit.until == HistoryLimitScope.endOfDay(dated.from), "To must clamp to From and include its final second")
        let until = dated.historyLimit.until
        dated.chooseHistoryLimit(.noLimit); try await wait(dated)
        precondition(dated.historyLimit.until == until && prefs.string(forKey: HistoryLimitDefaults.fromDateKey(root: repo.root)) == nil && dated.entries.count == 205)
        let savedScope = dated.historyLimit
        dated.busy = true; dated.chooseHistoryLimit(.commits); dated.changeHistoryFrom(Date(timeIntervalSince1970: 0)); dated.changeHistoryTo(Date())
        precondition(dated.historyLimit == savedScope); dated.busy = false
        dated.invalidate(); dated.chooseHistoryLimit(.commits); precondition(dated.historyLimit == savedScope)
        let after = try paths.map { try Data(contentsOf: repo.root.appendingPathComponent($0)) }
        precondition(before == after)
        print("PASS: 205-row native default No limitation, saved count/date/time scopes, explicit range override, date clamp/inclusive end, No limitation preserves To/removes saved From, busy/closed guards; exact HEAD/index/config/ref/file preservation")
        print("PASS: actual hidden native six-choice settings picker, enabled/disabled numeric field, real Apply/Cancel buttons and persisted defaults/invalid number behavior; no main app")
    }
}
