import AppKit
import SwiftUI
import TurtleGitCore

@main struct ClientHooksVerification {
    @MainActor static func main() async { do { try await verify() } catch { fputs("Client hooks failed: \(error)\n",stderr); ClientHookProcessPool.shared.cancelAll(); for _ in 0..<1000 { if ClientHookProcessPool.shared.activeScripts == 0 { break }; try? await Task.sleep(nanoseconds:10_000_000) }; exit(1) } }
    @MainActor static func verify() async throws {
        func require(_ value:Bool,_ message:String) throws { if !value { throw NSError(domain:message,code:1) } }
        func wait(_ ready:()->Bool) async throws { for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }; throw NSError(domain:"Hook native work did not settle",code:1) }
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), git = URL(fileURLWithPath:CommandLine.arguments[2])
        let suite = "TurtleGit.Hooks.QA." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        prefs.set(2,forKey:"AutoCloseGitProgress")
        defer { prefs.removePersistentDomain(forName:suite); ClientHookProcessPool.shared.cancelAll() }
        func makeRepo(_ name:String) async throws -> GitRepository {
            let path = root.appendingPathComponent(name); try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)
            let repo = GitRepository(root:path,executable:git)
            _ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Hook QA"),("user.email","qa@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] { _ = try await repo.run(["config",key,value]) }
            try Data("initial\n".utf8).write(to:path.appendingPathComponent("file.txt")); try await repo.stage(["file.txt"]); _ = try await repo.commit(message:"base")
            return repo
        }
        let script = root.appendingPathComponent("hook.sh")
        try Data("""
        printf '%s\\n' "$1" >> "$2/hook-log"
        case "$1" in
        start_commit_hook) printf 'start message' > "$4" ;;
        pre_commit_hook) printf 'hook commit message' > "$4" ;;
        post_commit_hook) [ ! -f "$2/fail-post" ] || { printf 'post failure' >&2; exit 9; } ;;
        pre_rebase_hook) printf '%s|%s' "$3" "$4" > "$2/rebase-hook-args" ;;
        esac
        """.utf8).write(to:script)
        func hook(_ type:ClientHookType,_ repo:GitRepository,local:Bool = false) -> ClientHook {
            ClientHook(type:type,path:repo.root.path,command:"/bin/sh '" + script.path + "' '" + type.rawValue + "' '%root%'",show:false,local:local)
        }
        func install(_ repo:GitRepository) throws { prefs.set(try ClientHookConfiguration.serialize(ClientHookType.allCases.map { hook($0,repo) }),forKey:"hooks") }
        func log(_ repo:GitRepository) -> [String] { ((try? String(contentsOf:repo.root.appendingPathComponent("hook-log"),encoding:.utf8)) ?? "").split(separator:"\n").map(String.init) }

        let repo = try await makeRepo("settings")
        try Data("[unrelated]\nvalue = retained\n".utf8).write(to:repo.root.appendingPathComponent(".tgitconfig"))
        let model = HookSettingsModel(preferences:prefs), transaction = SettingsTransaction()
        let parent = NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:660),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        parent.isReleasedWhenClosed = false
        parent.contentViewController = NSHostingController(rootView:HookSettingsPage(model:model,repository:repo,access:nil).environment(\.settingsTransaction,transaction))
        defer { model.invalidate(); parent.close(); transaction.invalidate() }
        model.window = parent; model.activate(repository:repo,access:nil); try await wait { model.loaded && !model.busy }
        model.configure(add:true)
        try await wait { parent.attachedSheet?.delegate is HookConfigurationController }
        let configuration = parent.attachedSheet!.delegate as! HookConfigurationController
        configuration.draft.hook = hook(.preCommit,repo,local:true); configuration.accept()
        try require(model.hooks.count == 1 && model.modified && !model.hasEditor,"Owned Add did not update draft only")
        let before = try Data(contentsOf:repo.root.appendingPathComponent(".tgitconfig"))
        try require(!String(decoding:before,as:UTF8.self).contains("precommit"),"Dialog OK wrote before shared Apply")
        try await wait { transaction.modified }
        transaction.apply(closeAfter:false); try await wait { !transaction.busy }
        try require(!model.modified && transaction.error == nil,"Shared Apply failed")
        let values = try await repo.projectClientHooks(); try require(values.count == 1 && values[0].command == hook(.preCommit,repo).command,"Project save differs")
        model.setEnabled(values[0].id,false); let disabled = await model.apply()
        try require(disabled && ClientHookPreferences.decision(values[0],preferences:prefs) == false,"Local disable was not stored per user")
        let project = try await repo.projectClientHooks(); try require(project[0].enabled,"Disable leaked to shared project config")
        model.setEnabled(values[0].id,true); model.cancel(); try require(!model.hooks[0].enabled && !model.modified,"Cancel did not restore local enable draft")
        model.selection = [model.hooks[0].id]; model.configure(copy:true)
        try await wait { parent.attachedSheet?.delegate is HookConfigurationController }
        let copy = parent.attachedSheet!.delegate as! HookConfigurationController
        copy.draft.setLocal(false); copy.draft.hook.path = "*"; copy.accept()
        try require(model.hooks.count == 2 && model.modified,"Copy did not preserve original key")
        model.cancel(); try require(model.hooks.count == 1,"Cancel did not discard copied global hook")
        model.configure(add:true); try await wait { model.hasEditor }; model.invalidate()
        try require(!model.hasEditor && parent.attachedSheet == nil,"Invalidation left owned configuration sheet")
        try require(MenuIcon.settingsHooks.image() != nil,"Original hook icon did not decode")

        print("Hook settings draft/Apply/Cancel and configuration ownership passed.")
        let session = ClientHookSession(preferences:prefs)
        defer { session.retire() }
        var approvals = 0
        session.approval = { _ in approvals += 1; return .init(approved:true,remember:true,cancelled:false) }
        let denied = try await session.run(.preCommit,repository:repo,access:nil,message:"draft")
        try require(denied == nil && approvals == 0,"Remembered rejection was executed or prompted")
        try ClientHookPreferences.remember(values[0],approved:nil,preferences:prefs)
        let accepted = try await session.run(.preCommit,repository:repo,access:nil,message:"draft")
        try require(accepted?.message == "hook commit message" && approvals == 1,"Approval/message readback differs")
        _ = try await session.run(.preCommit,repository:repo,access:nil,message:"draft")
        try require(approvals == 1,"Exact remembered script prompted twice")
        let late = ClientHookSession(preferences:prefs)
        var pending:CheckedContinuation<ClientHookSession.Approval,Never>?
        try ClientHookPreferences.remember(values[0],approved:nil,preferences:prefs)
        late.approval = { _ in await withCheckedContinuation { pending = $0 } }
        let operation = Task { try await late.run(.preCommit,repository:repo,access:nil,message:"late") }
        try await wait { pending != nil }; let lines = log(repo).count; late.retire()
        pending?.resume(returning:.init(approved:true,remember:true,cancelled:false)); pending = nil
        do { _ = try await operation.value; throw NSError(domain:"Retired approval executed",code:1) } catch OperationCancellationFailure.cancelled {}
        try require(log(repo).count == lines && ClientHookPreferences.decision(values[0],preferences:prefs) == nil,"Late approval wrote or launched")

        print("Hook approval/rejection/late retirement passed.")
        let commitRepo = try await makeRepo("commit"); try install(commitRepo)
        try Data("change\n".utf8).write(to:commitRepo.root.appendingPathComponent("file.txt"))
        let commit = CommitWindowModel(repository:commitRepo,access:nil,unversionedDefaults:prefs,dialogDefaults:prefs)
        defer { commit.invalidateForClose() }
        commit.reload(paths:["file.txt"]); try await wait { !commit.busy && commit.entries.contains { $0.path == "file.txt" } }
        try require(commit.message == "start message" && log(commitRepo) == ["start_commit_hook"],"Commit Start hook did not seed draft")
        commit.message = "user message"; commit.commit(); try await wait { !commit.busy }
        let committed = try await commitRepo.run(["log","-1","--format=%B"])
        try require(committed.text.trimmingCharacters(in:.newlines) == "hook commit message" && log(commitRepo) == ["start_commit_hook","pre_commit_hook","post_commit_hook"],"Commit pre/post ordering or modified message differs")
        try Data("more\n".utf8).write(to:commitRepo.root.appendingPathComponent("file.txt")); try Data().write(to:commitRepo.root.appendingPathComponent("fail-post"))
        commit.reload(paths:["file.txt"]); try await wait { !commit.busy }; commit.message = "another"; commit.commit(); try await wait { !commit.busy }
        let count = try await commitRepo.run(["rev-list","--count","HEAD"])
        try require(count.text == "3\n" && commit.error?.contains("commit succeeded") == true,"Post-hook error obscured successful commit")

        print("Hook actual Commit ordering and post-failure success passed.")
        let pushRepo = try await makeRepo("push"), remote = root.appendingPathComponent("remote.git")
        _ = try await pushRepo.run(["init","--bare",remote.path]); _ = try await pushRepo.run(["remote","add","origin",remote.path]); try install(pushRepo)
        let push = PushWindowModel(repository:pushRepo,access:nil,preferences:prefs); defer { push.invalidate() }
        push.load(); try await wait { !push.busy && !push.options.source.isEmpty }
        push.options.remote = "origin"; push.options.destination = "main"; push.push(confirmed:true); try await wait { !push.busy }
        try require(log(pushRepo) == ["pre_push_hook","post_push_hook"] && push.error == nil,"Push pre/post routing differs")
        let failHook = ClientHook(type:.prePush,path:pushRepo.root.path,command:"/bin/sh -c 'exit 7' hook",show:false)
        prefs.set(try ClientHookConfiguration.serialize([failHook]),forKey:"hooks"); push.clientHooks.continueAfterFailure = { _ in false }
        push.push(confirmed:true); try await wait { !push.busy }
        try require(push.error?.contains("Pre-push hook failed") == true,"Failed pre-hook did not abort Push")

        print("Hook actual Push routing and pre-failure abort passed.")
        let rebaseRepo = try await makeRepo("rebase"); _ = try await rebaseRepo.run(["checkout","-b","topic"])
        try Data("topic\n".utf8).write(to:rebaseRepo.root.appendingPathComponent("file.txt")); try await rebaseRepo.stage(["file.txt"]); _ = try await rebaseRepo.commit(message:"topic")
        let rebase = RebaseWindowModel(repository:rebaseRepo,access:nil,messageDefaults:prefs)
        defer { rebase.clientHooks.retire() }
        rebase.options.branch = "topic"; rebase.options.upstream = "main"; rebase.options.force = true; rebase.plan = try await rebaseRepo.rebasePlan(rebase.options)
        prefs.set(try ClientHookConfiguration.serialize([hook(.preRebase,rebaseRepo)]),forKey:"hooks")
        rebase.clientHooks.continueAfterFailure = { _ in false }
        // Use a failing hook to verify the actual Start boundary without launching
        // a rebase editor or mutating history in this focused receiver.
        var preRebase = hook(.preRebase,rebaseRepo); preRebase.command += " extra"
        let rebaseScript = root.appendingPathComponent("rebase-fail.sh")
        try Data("printf '%s|%s' \"$1\" \"$2\" > \"$4/rebase-hook-args\"\nexit 8\n".utf8).write(to:rebaseScript)
        preRebase.command = "/bin/sh '" + rebaseScript.path + "'"
        prefs.set(try ClientHookConfiguration.serialize([preRebase]),forKey:"hooks")
        rebase.editorExecutable = git; rebase.execute("start"); try await wait { !rebase.busy }
        try require(rebase.error?.contains("Pre-rebase hook failed") == true,"Rebase Start bypassed hook boundary")
        try require((try? String(contentsOf:rebaseRepo.root.appendingPathComponent("rebase-hook-args"),encoding:.utf8)) == "main|topic","Rebase hook arguments differ")

        try await wait { ClientHookProcessPool.shared.activeScripts == 0 }
        let background = ClientHookSession(preferences:prefs); defer { background.retire() }
        let backgroundHook = ClientHook(type:.postPush,path:pushRepo.root.path,command:"/bin/sh -c 'sleep 30 & wait' hook",wait:false,show:false)
        prefs.set(try ClientHookConfiguration.serialize([backgroundHook]),forKey:"hooks")
        _ = try await background.run(.postPush,repository:pushRepo,access:nil)
        try require(ClientHookProcessPool.shared.activeScripts == 1,"Non-wait execution lost pool ownership")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel,"Quit ignored non-wait hook")
        ClientHookProcessPool.shared.cancelAll(); try await wait { ClientHookProcessPool.shared.activeScripts == 0 }
        print("Hook settings shared drafts/configuration ownership, approvals/late fences, actual Commit/Push/Rebase boundaries and non-wait cancellation passed.")
    }
}
