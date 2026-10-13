import AppKit
import TurtleGitCore

@main struct CommitPreferencesVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description:message) } }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func wait(_ ready: () -> Bool) async throws {
        for _ in 0..<1500 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Commit preference controls did not settle")
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Commit preferences failed: \(error)\n",stderr); exit(1) } }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]), git=URL(fileURLWithPath:CommandLine.arguments[2]), repo=GitRepository(root:root,executable:git)
        func initialize(_ repository: GitRepository) async throws {
            _ = try await repository.run(["init","-b","main"])
            for (key,value) in [("user.name","Preferences QA"),("user.email","qa@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] { _ = try await repository.run(["config",key,value]) }
        }
        try await initialize(repo)
        let origin=root.appendingPathComponent("origin"), source=GitRepository(root:origin,executable:git)
        try FileManager.default.createDirectory(at:origin,withIntermediateDirectories:true); try await initialize(source)
        try Data("base\n".utf8).write(to:origin.appendingPathComponent("code.c")); try await source.stage(["code.c"]); _ = try await source.commit(message:"base")
        try Data("origin/\n".utf8).write(to:root.appendingPathComponent(".gitignore"))
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file.swift"))
        _ = try await repo.run(["-c","protocol.file.allow=always","submodule","add",origin.path,"module"])
        try await repo.stage([".gitignore",".gitmodules","file.swift","module"]); _ = try await repo.commit(message:"base")
        let module=GitRepository(root:root.appendingPathComponent("module"),executable:git)
        for (key,value) in [("user.name","Preferences QA"),("user.email","qa@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] { _ = try await module.run(["config",key,value]) }
        try Data("new child\n".utf8).write(to:module.root.appendingPathComponent("code.c")); try await module.stage(["code.c"]); _ = try await module.commit(message:"child change")
        try Data("modified\n".utf8).write(to:root.appendingPathComponent("file.swift"))
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),work=try Data(contentsOf:root.appendingPathComponent("file.swift"))
        let suite="TurtleGit.CommitPreferences.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        let keys=["Commit.KeepChangelists","Commit.DoNotAutoselectSubmodules","Commit.TemplateNotEdited.Proceed","StyleCommitMessages","Autocompletion","AutocompleteRemovesExtensions","LogFontName","LogFontSize"]
        let global=UserDefaults.standard.dictionaryRepresentation().filter { keys.contains($0.key) }
        prefs.set(true,forKey:"Commit.KeepChangelists"); prefs.set(true,forKey:"Commit.DoNotAutoselectSubmodules"); prefs.set(false,forKey:"StyleCommitMessages")
        prefs.set(false,forKey:"Autocompletion"); prefs.set(true,forKey:"AutocompleteRemovesExtensions")
        prefs.set("Menlo",forKey:"LogFontName"); prefs.set(24,forKey:"LogFontSize")
        let owner=CommitWindowController(repository:repo,access:nil,defaults:prefs); defer { owner.close() }
        let model=owner.model
        try require(model.keepChangelists && model.doNotAutoselectSubmodules && !model.formattingEnabled,"Initial controls ignored supplied preferences")
        model.reload(paths:["."])
        try await wait { owner.window!.contentView!.layoutSubtreeIfNeeded(); return !model.busy && model.canReceiveFileDrop }
        try require(model.submodules.contains("module") && !model.checked.contains("module") && model.checked.contains("file.swift"),"Initial actual submodule selection policy wrong")
        try await wait { model.messageCompletionCatalog.candidates.contains("file") }
        try require(model.colorPreferences === prefs,"File colors do not use the owning store")
        try await wait { owner.window!.contentView!.layoutSubtreeIfNeeded(); return descendants(owner.window!.contentView!).compactMap { $0 as? NSTextView }.contains { abs(($0.font?.pointSize ?? 0)-24)<0.1 } }
        try require(!model.formattingEnabled,"Native editor reset private formatting preference")
        model.setDoNotAutoselectSubmodules(false)
        try require(model.checked.contains("module") && !prefs.bool(forKey:"Commit.DoNotAutoselectSubmodules"),"Submodule checkbox did not apply/persist immediately")
        model.setDoNotAutoselectSubmodules(true)
        try require(!model.checked.contains("module") && prefs.bool(forKey:"Commit.DoNotAutoselectSubmodules"),"Submodule exclusion did not apply immediately")
        model.saveKeepChangelists(false); model.rememberTemplateProceed()
        try require(!prefs.bool(forKey:"Commit.KeepChangelists") && prefs.bool(forKey:"Commit.TemplateNotEdited.Proceed"),"Saved choices escaped owning preferences")
        model.busy=true; model.saveKeepChangelists(true); model.setDoNotAutoselectSubmodules(false)
        try require(!model.keepChangelists && model.doNotAutoselectSubmodules,"Busy preference action was accepted"); model.busy=false
        model.stagingEnabled=true; model.setDoNotAutoselectSubmodules(false)
        try require(model.doNotAutoselectSubmodules,"Staging-disabled submodule action accepted"); model.stagingEnabled=false
        let reopened=CommitWindowController(repository:repo,access:nil,defaults:prefs); defer { reopened.close() }
        try require(!reopened.model.keepChangelists && reopened.model.doNotAutoselectSubmodules && !reopened.model.formattingEnabled,"Reopened dialog did not retain choices")
        reopened.close(); owner.close(); model.saveKeepChangelists(true); model.setDoNotAutoselectSubmodules(false)
        try require(!prefs.bool(forKey:"Commit.KeepChangelists") && prefs.bool(forKey:"Commit.DoNotAutoselectSubmodules"),"Retired dialog changed saved choices")
        let after=UserDefaults.standard.dictionaryRepresentation().filter { keys.contains($0.key) }
        try require(NSDictionary(dictionary:global).isEqual(to:after),"Private Commit changed global preferences")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(afterHead==head && (try Data(contentsOf:root.appendingPathComponent(".git/index")))==index && (try Data(contentsOf:root.appendingPathComponent("file.swift")))==work,"Control changes mutated HEAD/index/worktree")
        print("Commit preferences: actual submodule selection, initial/reopened private controls, native editor font/formatting, completion options, warning/Keep choices, busy/staging/retired gates and global/repository preservation passed. Owned windows closed.")
    }
}
