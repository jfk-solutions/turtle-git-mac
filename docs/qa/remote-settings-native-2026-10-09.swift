import AppKit
import SwiftUI
import TurtleGitCore
import Darwin

private final class IdentityFixtureBookmarks: RepositoryBookmarkProvider {
    var starts = 0, stops = 0
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark { ResolvedBookmark(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: false) }
    func startAccessing(_ url: URL) -> Bool { starts += 1; return true }
    func stopAccessing(_ url: URL) { stops += 1 }
}
@main struct RemoteSettingsReceiver {
    struct Failure: Error { let message: String }
    @MainActor static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws { if try !value() { throw Failure(message: message) } }
    @MainActor static func wait(_ predicate: () -> Bool) async throws { for _ in 0..<500 { if predicate() { return }; try await Task.sleep(nanoseconds: 20_000_000) }; throw Failure(message: "Wait timed out") }
    @MainActor static func outline(_ view: NSView) -> NSOutlineView? { if let value = view as? NSOutlineView { return value }; for child in view.subviews { if let value = outline(child) { return value } }; return nil }
    @MainActor static func main() async {
        do { try await run() } catch { fputs("FAIL \(error)\n", stderr); exit(1) }
    }
    @MainActor static func run() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), git = URL(fileURLWithPath: CommandLine.arguments[2])
        let domain = "TurtleGit.RemoteSettings.QA." + UUID().uuidString; let prefs = UserDefaults(suiteName: domain)!; defer { prefs.removePersistentDomain(forName: domain) }
        let repo = GitRepository(root: root, executable: git)
        _ = try await repo.run(["init", "-b", "main"]); _ = try await repo.run(["config", "user.name", "QA"]); _ = try await repo.run(["config", "user.email", "qa@example.invalid"]); _ = try await repo.run(["config", "commit.gpgsign", "false"]); _ = try await repo.run(["config", "core.hooksPath", "/dev/null"])
        try Data("fixture\n".utf8).write(to: root.appendingPathComponent("file")); _ = try await repo.run(["add", "file"]); _ = try await repo.run(["commit", "-m", "fixture"])
        try await identitySelection(root: root, repo: repo, preferences: prefs)
        _ = try await repo.run(["update-ref", "refs/remotes/stale/main", "HEAD"])
        let owner = ReferenceBrowserWindowController(repository: repo, access: nil, initial: "", preferences: prefs, picking: false, onChoose: { _ in }); defer { owner.close() }
        owner.model.load(); try await wait { !owner.model.busy }; owner.model.setFolder("refs/remotes")
        owner.presentRemoteSettings = { _, _ in true }; owner.window!.contentView!.layoutSubtreeIfNeeded()
        guard let menu = outline(owner.window!.contentView!)?.menu else { throw Failure(message: "No folder menu") }; menu.delegate?.menuNeedsUpdate?(menu)
        guard let command = menu.items.first(where: { $0.title == "Manage Remotes" }), let action = command.action else { throw Failure(message: "No Manage Remotes command") }
        try require(command.isEnabled && command.image?.name() == MenuIcon.settings.contextImage(defaults: prefs)?.name(), "Original settings icon/command")
        try require(NSApplication.shared.sendAction(action, to: command.target, from: command), "Actual Manage Remotes dispatch")
        guard let controller = owner.remoteSettingsDialog, let view = controller.window?.contentView as? RemoteSettingsNativeView else { throw Failure(message: "No shipping native settings route/view") }; defer { controller.close() }
        try await wait { !controller.model.busy }; let model = controller.model
        try require(model.names.isEmpty && view.prune.state == .mixed && view.tags.indexOfSelectedItem == 0 && !view.rename.isEnabled && !view.remove.isEnabled, "Empty source defaults")
        try require(owner.model.hasChild && !owner.windowShouldClose(owner.window!), "Browser child ownership")
        var prompts: [String] = [], fetches: [String] = []
        model.confirm = { prompt in prompts.append(prompt.message); return (true, false) }; model.onFetch = { fetches.append($0) }
        view.url.stringValue = root.path; view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.url))
        try require(model.draft.name == "origin" && model.changed.contains(.name) && view.remote.stringValue == "origin", "Origin prefill via actual field")
        view.tags.selectItem(at: 2); view.tagChanged(); view.prune.state = .on; view.pruneChanged(); view.pushDefault.state = .on; view.defaultChanged()
        view.saveClicked(); try await wait { !model.busy }; try require(model.error == nil && model.names == ["origin"] && model.selected == "origin" && model.changed.isEmpty && fetches == ["origin"], "New remote Save/Fetch")
        let saved = try await repo.remoteSettings(name: "origin"); try require(saved.tags == .all && saved.prune == .enabled && saved.pushDefault, "Saved native options")
        view.remote.stringValue = "team/nested"; view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.remote)); view.renameClicked(); try await wait { !model.busy }; try require(model.selected == "team/nested" && model.names == ["team/nested"] && model.changed.isEmpty, "Separate Rename")
        model.edit(.name) { $0.name = "second" }; model.edit(.url) { $0.url = root.path }; model.edit(.tags) { $0.tags = .all }; model.save(); try await wait { !model.busy }; try require(model.error == nil && model.names.count == 2 && model.draft.tags == .none && fetches == ["origin","second"] && prompts.contains(RemoteSettingsWindowModel.Prompt.noTags.message), "No-tags offer and second remote")
        model.edit(.pushURL) { $0.pushURL = "draft" }; model.confirm = { _ in (false,false) }; model.select("team/nested"); try await wait { !model.busy }; try require(model.selected == "team/nested" && model.changed.isEmpty, "Dirty selection Discard")
        model.edit(.pushURL) { $0.pushURL = "saved" }; model.confirm = { _ in (true,false) }; model.select("second"); try await wait { !model.busy }; let first = try await repo.remoteSettings(name: "team/nested"); try require(first.pushURL == "saved" && model.selected == "second", "Dirty selection Save")
        model.edit(.url) { $0.url = "overwrite" }; var answer: CheckedContinuation<(yes: Bool, suppress: Bool),Never>?
        model.confirm = { _ in await withCheckedContinuation { answer = $0 } }; model.save(); try await wait { answer != nil }
        try require(model.busy && !controller.windowShouldClose(controller.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Pending confirmation Close/Quit gates")
        model.rename(); model.remove(); model.edit(.url) { $0.url = "late edit" }; try require(model.draft.url == "overwrite", "Busy edit/mutation guard")
        let no = answer; answer = nil; no?.resume(returning: (false,false)); try await wait { !model.busy }; let unchanged = try await repo.remoteSettings(name: "second"); try require(unchanged.url == root.path, "Overwrite No mutated")
        model.confirm = { _ in (true,false) }; model.save(); try await wait { !model.busy }; let overwritten = try await repo.remoteSettings(name: "second"); try require(overwritten.url == "overwrite", "Explicit overwrite Yes")
        model.edit(.name) { $0.name = "edited-but-not-selected" }; model.remove(); try await wait { !model.busy }; try require(model.names == ["team/nested"] && model.selected == nil && model.draft.name.isEmpty, "Remove uses captured selected name")
        let overwriteAlert = RemoteSettingsNativeView.alert(.overwrite("origin")); try require(overwriteAlert.buttons.map(\.title) == ["Yes","No"] && overwriteAlert.buttons[1].keyEquivalent == "\r", "Overwrite default No")
        let dirtyAlert = RemoteSettingsNativeView.alert(.saveDiscard); try require(dirtyAlert.buttons.map(\.title) == ["Save","Discard"] && dirtyAlert.buttons[0].keyEquivalent == "\r", "Save/Discard default")
        let tagsAlert = RemoteSettingsNativeView.alert(.noTags); try require(tagsAlert.showsSuppressionButton, "Tag suppression control")
        model.select("team/nested"); try await wait { !model.busy }; model.confirm = { _ in await withCheckedContinuation { answer = $0 } }; model.remove(); try await wait { answer != nil }; owner.close(); let late = answer; answer = nil; late?.resume(returning: (true,false)); try await Task.sleep(nanoseconds: 100_000_000)
        let names = try await repo.remoteNames(); try require(names == ["team/nested"] && model.closed && !model.busy, "Late Yes after owner close mutated")
        for stage in ["config", "rename", "rm", "add"] {
            let helper = root.appendingPathComponent("slow-" + stage), marker = URL(fileURLWithPath: helper.path + ".started"), pause = URL(fileURLWithPath: helper.path + ".pause")
            let quoted = "'" + git.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let script = """
            #!/bin/sh
            task_match=false
            for task_argument in "$@"; do
              if [ "$task_argument" = '\(stage)' ]; then task_match=true; fi
            done
            if [ "$task_match" = true ] && [ -f "$0.pause" ]; then
              /bin/sleep 30 &
              task_child=$!
              trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
              printf '%s %s\\n' "$$" "$task_child" > "$0.started"
              wait "$task_child"
            fi
            exec \(quoted) "$@"
            """
            try Data(script.utf8).write(to: helper); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            let pending = RemoteSettingsWindowController(repository: GitRepository(root: root, executable: helper), access: nil, preferences: prefs, noFetch: true)
            var ids: [Int32] = []; defer { pending.close(); for pid in ids where kill(pid, 0) == 0 { _ = kill(pid, SIGTERM) } }
            pending.model.confirm = { _ in (true, false) }; pending.model.load(); try await wait { !pending.model.busy }
            if stage == "config" { try Data().write(to: pause); pending.model.select("team/nested") }
            else {
                pending.model.select("team/nested"); try await wait { !pending.model.busy }
                if stage == "rename" { pending.model.edit(.name) { $0.name = "renamed" } }
                if stage == "add" { pending.model.edit(.name) { $0.name = "new" }; pending.model.edit(.url) { $0.url = root.path } }
                try Data().write(to: pause)
                if stage == "rename" { pending.model.rename() }; if stage == "rm" { pending.model.remove() }; if stage == "add" { pending.model.save() }
            }
            try await wait { FileManager.default.fileExists(atPath: marker.path) }; ids = try String(contentsOf: marker).split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }
            try require(ids.count == 2 && ids.allSatisfy { kill($0,0) == 0 }, "No live process group")
            pending.close(); try await wait { ids.allSatisfy { kill($0,0) != 0 } }; try await Task.sleep(nanoseconds: 100_000_000)
            try require(pending.model.closed && !pending.model.busy && pending.model.error == nil, "Late forced-close result")
            let after = try await repo.remoteNames(); try require(after == ["team/nested"], "Forced-close mutation completed")
            print("PASS remote settings forced process cleanup: " + stage)
        }
        let offer = RemoteSettingsWindowController(repository: repo, access: nil, preferences: prefs); defer { offer.close() }
        var configured = 0; offer.configureFetch = { _ in configured += 1 }; offer.presentFetch = { _, _ in true }; offer.model.confirm = { prompt in if case .fetch = prompt { return (true,false) }; return (false,false) }
        offer.model.load(); try await wait { !offer.model.busy }; offer.model.edit(.name) { $0.name = "offered" }; offer.model.edit(.url) { $0.url = root.path }; offer.model.save()
        try await wait { !offer.model.busy && offer.fetchDialog != nil && offer.fetchDialog?.model.busy == false }
        try require(configured == 1 && offer.fetchDialog?.model.options.remote == "offered" && offer.fetchDialog?.model.options.allRemotes == false, "Actual owned Fetch offer/configuration")
        try require(offer.model.hasChild && !offer.windowShouldClose(offer.window!), "Fetch child Close gate")
        offer.model.edit(.url) { $0.url = "blocked" }; try require(offer.model.draft.url == root.path, "Fetch child edit gate")
        offer.fetchDialog?.close(); try require(offer.fetchDialog == nil, "Fetch child not released")
        try require(!NSApplication.shared.windows.contains { $0.isVisible }, "Receiver displayed windows")
        print("PASS native Remote fields, tri-state/options, origin prefill, Add/Save, Rename, dirty Save/Discard, overwrite No/Yes, captured Remove, Fetch offer, actual browser route/ownership, Close/Quit and late confirmation")
    }
    @MainActor static func identitySelection(root: URL, repo: GitRepository, preferences: UserDefaults) async throws {
        let key = root.appendingPathComponent("private-fixture-key"), putty = root.appendingPathComponent("fixture.ppk")
        try Data("opaque fixture key content".utf8).write(to: key); try Data("PuTTY-User-Key-File-3: ssh-ed25519\n".utf8).write(to: putty)
        let provider = IdentityFixtureBookmarks(), storage = root.appendingPathComponent("private-grants/grants.json")
        let store = SSHIdentityAccessStore(storageURL: storage, provider: provider)
        let model = RemoteSettingsWindowModel(repository: repo, access: nil, preferences: preferences, noFetch: true, identityAccess: store)
        let view = RemoteSettingsNativeView(model: model); defer { model.invalidate() }
        model.edit(.name) { $0.name = "identity-fixture" }; model.edit(.url) { $0.url = root.path }; model.edit(.puttyKeyFile) { $0.puttyKeyFile = "C:\\fixture.ppk" }
        model.selectIdentity(key)
        try require(model.draft.sshKeyFile == key.path && view.sshKey.stringValue == key.path && model.changed.contains(.sshKeyFile), "Native key selection/draft field")
        model.save(); try await wait { !model.busy }
        let saved = try await repo.remoteSettings(name: "identity-fixture")
        try require(saved.sshKeyFile == key.path && saved.puttyKeyFile == "C:\\fixture.ppk" && model.error == nil, "Separate native/Windows key configuration")
        do { let grant = try store.acquire(path: saved.sshKeyFile, requireSecurityScope: true); try require(grant.file == key, "Saved key grant") }
        try require(provider.starts == provider.stops, "Key scope leaked")
        let bytes = try Data(contentsOf: storage)
        model.setChild(true); try require(!view.sshKey.isEnabled && !view.browseSSH.isEnabled && !view.browse.isEnabled && !model.canApply, "Picker child does not gate edits")
        model.selectIdentity(putty); try require(model.draft.sshKeyFile == key.path, "Selection accepted while child owned"); model.setChild(false)
        model.selectIdentity(putty); try require(model.error != nil && model.draft.sshKeyFile == key.path && (try Data(contentsOf: storage)) == bytes, "PuTTY content accepted as native key")
        view.sshKey.stringValue = root.appendingPathComponent("typed-key").path; view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.sshKey))
        try require(model.changed.contains(.sshKeyFile), "Typed identity change missing")
        do { _ = try store.acquire(path: model.draft.sshKeyFile); throw Failure(message: "Typed path granted access") } catch SSHIdentityAccessFailure.missingGrant {}
        model.invalidate(); model.selectIdentity(key); try require(!view.sshKey.isEnabled && (try Data(contentsOf: storage)) == bytes, "Late closed identity selection changed grants")
        let unchanged = try await repo.remoteSettings(name: "identity-fixture"); try require(unchanged.sshKeyFile == key.path, "Discarded key draft saved")
        try await repo.removeRemote(name: "identity-fixture")
        print("PASS native SSH key selection/save, legacy preservation, private grants, PPK refusal, typed-path nonauthorization and child/late fences")
    }
}
