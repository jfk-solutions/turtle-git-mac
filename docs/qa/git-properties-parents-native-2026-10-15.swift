// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import TurtleGitCore

@main struct GitPropertiesParentsVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct ScopeProvider: RepositoryBookmarkProvider {
        func create(for url: URL) throws -> Data { Data(url.path.utf8) }
        func resolve(_ data: Data) throws -> ResolvedBookmark { ResolvedBookmark(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), stale: false) }
        func startAccessing(_ url: URL) -> Bool { true }
        func stopAccessing(_ url: URL) {}
    }
    static func require(_ value: Bool, _ description: String) throws { if !value { throw Failure(description: description) } }
    @MainActor static func wait(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<1500 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Parent property operation did not settle")
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    @MainActor static func main() async throws { try await verify() }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), engine = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: engine), child = root.appendingPathComponent("module snow 雪")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let childRepo = GitRepository(root: child, executable: engine)
        for current in [repo, childRepo] {
            _ = try await current.run(["init", "-b", current.root == root ? "parent" : "child"])
            for (key, value) in [("user.name", "Properties Parent QA"), ("user.email", "parent@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await current.run(["config", key, value]) }
        }
        try Data("child\n".utf8).write(to: child.appendingPathComponent("file.txt"))
        try await childRepo.stage(["file.txt"]); _ = try await childRepo.commit(message: "child baseline")
        let childHead = try await childRepo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let modules = root.appendingPathComponent(".gitmodules")
        let registration = "[submodule \"qa\"]\n\tpath = module snow 雪\n\turl = https://example.invalid/module.git\n"
        try registration.write(to: modules, atomically: true, encoding: .utf8)
        try await repo.stage([".gitmodules"])
        _ = try await repo.run(["update-index", "--add", "--cacheinfo", "160000," + childHead + "," + child.lastPathComponent])
        _ = try await repo.commit(message: "registered module")
        let parentHead = try await repo.run(["rev-parse", "HEAD"]).stdout
        let childIndex = try Data(contentsOf: child.appendingPathComponent(".git/index")), parentEntries = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        let suite = "TurtleGit.Properties.Parents.QA." + UUID().uuidString, preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        func context(_ access: RepositoryAccessLease? = nil, executable: URL? = nil) -> GitPropertiesContext {
            GitPropertiesContext(repository: GitRepository(root: child, executable: executable ?? engine), paths: ["."], access: access, submodule: false)
        }
        let owner = GitPropertiesWindowController(contexts: [context()], preferences: preferences)
        defer { owner.close() }
        let model = owner.model
        try await wait { !model.busy }
        try require(model.error == nil && model.contexts.count == 2 && model.selected == 0, "Live registration did not add parent first: \(model.error ?? "no error"), pages \(model.contexts.count)")
        try require(model.contexts[0].repository.root.path == root.path && model.contexts[0].paths == [child.lastPathComponent] && model.contexts[0].submodule, "Parent lost source context")
        try require(model.current?.hasSubmodule == true && model.current?.branch == "parent", "Parent metadata missing")
        let draft = model.draft; model.set(\GitPropertyDraft.executable, .on)
        try require(model.draft == draft, "Gitlink mode gate missing")
        var log: GitPropertiesContext?, settings: GitPropertiesContext?
        model.onLog = { log = $0 }; model.onSettings = { settings = $0 }
        model.showLog(); model.showSettings()
        try require(log?.repository.root.path == root.path && log?.paths == [child.lastPathComponent] && settings?.repository.root.path == root.path, "Parent callbacks followed child")
        model.set(\GitPropertyDraft.assumeUnchanged, .on); model.apply()
        try await wait { !model.busy && GitPropertiesWindowModel.activeOperations == 0 }
        try require(model.error == nil && model.current?.draft.assumeUnchanged == .on, "Parent flag Apply/refresh failed")
        try require(try Data(contentsOf: child.appendingPathComponent(".git/index")) == childIndex, "Parent Apply wrote child index")
        model.set(\GitPropertyDraft.assumeUnchanged, .off); model.apply()
        try await wait { !model.busy && GitPropertiesWindowModel.activeOperations == 0 }
        model.selected = 1; model.showLog(); model.showSettings()
        try require(log?.repository.root.path == child.path && log?.paths == ["."] && settings?.repository.root.path == child.path, "Child callbacks followed parent")
        model.load(); try await wait { !model.busy }
        try require(model.selected == 1 && model.current?.branch == "child", "Refresh lost selected child")
        try "[submodule \"qa\"]\npath = other\n".write(to: modules, atomically: true, encoding: .utf8)
        model.load(); try await wait { !model.busy }
        try require(model.error == nil && model.contexts.count == 1 && model.current?.branch == "child", "Refresh retained stale registration")
        try registration.write(to: modules, atomically: true, encoding: .utf8)
        owner.close()
        // Simulated leases check model boundaries, not signed sandbox acceptance.
        for broad in [false, true] {
            let access = RepositoryAccessLease(url: broad ? root : child, provider: ScopeProvider())
            let scoped = GitPropertiesWindowController(contexts: [context(access)], preferences: preferences, requiresScopes: true)
            defer { scoped.close() }
            try await wait { !scoped.model.busy }
            try require(scoped.model.error == nil && scoped.model.contexts.count == (broad ? 2 : 1), "Primary scope boundary changed")
            try require(scoped.model.contexts.allSatisfy { access.contains($0.repository.root) }, "Parent escaped primary grant")
            scoped.close()
        }
        let denied = GitPropertiesWindowController(contexts: [context()], preferences: preferences, requiresScopes: true)
        try await wait { !denied.model.busy }
        try require(denied.model.error != nil && denied.model.snapshots.allSatisfy { $0 == nil }, "Missing scope ran property read")
        denied.close()
        // Force-close while parent discovery itself owns a helper and descendant.
        let helper = root.appendingPathComponent("held-parent-properties")
        let script = """
        #!/bin/sh
        for task_arg in "$@"; do
          if [ "$task_arg" = --show-toplevel ]; then
            /bin/sleep 30 &
            task_child=$!
            trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
            printf '%s %s\\n' "$$" "$task_child" > "$0.ready.tmp"
            /bin/mv "$0.ready.tmp" "$0.ready"
            wait "$task_child"
          fi
        done
        exec \(quote(engine.path)) "$@"
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let marker = URL(fileURLWithPath: helper.path + ".ready")
        let narrowLease = RepositoryAccessLease(url: child, provider: ScopeProvider())
        let narrow = GitPropertiesWindowController(contexts: [context(narrowLease, executable: helper)], preferences: preferences, requiresScopes: true)
        try await wait { !narrow.model.busy }
        try require(narrow.model.error == nil && narrow.model.contexts.count == 1 && !FileManager.default.fileExists(atPath: marker.path), "Narrow scope probed parent before containment check")
        narrow.close()
        let slow = GitPropertiesWindowController(contexts: [context(executable: helper)], preferences: preferences)
        defer { slow.close() }
        try await wait { FileManager.default.fileExists(atPath: marker.path) }
        let pids = try String(contentsOf: marker, encoding: .utf8).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        try require(!slow.windowShouldClose(slow.window!), "Parent discovery allowed busy close")
        slow.close()
        try require(slow.model.retired && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Retired discovery lost Quit accounting")
        try await wait { !slow.model.busy && GitPropertiesWindowModel.activeOperations == 0 }
        try require(pids.count == 2 && pids.allSatisfy { kill($0, 0) != 0 } && slow.model.contexts.count == 1 && slow.model.snapshots.allSatisfy { $0 == nil }, "Discovery leaked a process or published after close")
        let parentAfter = try await repo.run(["rev-parse", "HEAD"]).stdout, childAfter = try await childRepo.run(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
        try require(parentAfter == parentHead && childAfter == childHead, "Properties moved repository heads")
        let parentEntriesAfter = try await repo.run(["ls-files", "--stage", "-z"]).stdout
        try require(parentEntriesAfter == parentEntries && Data(contentsOf: child.appendingPathComponent(".git/index")) == childIndex, "Property restoration changed entries or child index")
        try require(try Data(contentsOf: child.appendingPathComponent("file.txt")) == Data("child\n".utf8), "Properties changed working bytes")
        print("PASS: Git Properties live parent ordering, scoped callbacks, flag Apply, child selection, registration refresh, primary-grant boundaries and discovery cancellation/reaping")
    }
}
