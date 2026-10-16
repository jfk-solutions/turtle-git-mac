import AppKit
import TurtleGitCore

@main struct LogRevertSelectionVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String) throws {if !value{throw Failure(description:message)}}
    @MainActor static func wait(_ ready:()->Bool,line:Int = #line) async throws {
        for _ in 0..<2500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Revert selection timeout at \(line)")
    }
    @MainActor static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    @MainActor static func main() async {do{try await verify()}catch{fputs("Log Revert selection failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),helper=root.appendingPathComponent("revert-git")
        setenv("TG_SELECTION_REVERT_GIT",git.path,1);defer{unsetenv("TG_SELECTION_REVERT_GIT")}
        try Data("#!/bin/sh\nif [ \"$4\" = revert ]; then\n printf '%s\\n' \"$@\" >> \"$3/.git/revert-invocations\"\nfi\nexec \"$TG_SELECTION_REVERT_GIT\" \"$@\"\n".utf8).write(to:helper)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:helper.path)
        let repo=GitRepository(root:root,executable:helper)
        _ = try await repo.run(["init","-b","main"])
        for(key,value) in [("user.name","Revert QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        try Data("initial\n".utf8).write(to:root.appendingPathComponent("initial.txt"));try await repo.stage(["initial.txt"]);_ = try await repo.commit(message:"Root payload")
        let initial=try await repo.rebaseCommit("HEAD")
        _ = try await repo.run(["switch","-c","side"]);try Data("side\n".utf8).write(to:root.appendingPathComponent("side.txt"));try await repo.stage(["side.txt"]);_ = try await repo.commit(message:"Side payload")
        _ = try await repo.run(["switch","main"]);try Data("normal\n".utf8).write(to:root.appendingPathComponent("extra.txt"));try await repo.stage(["extra.txt"]);_ = try await repo.commit(message:"Normal payload")
        _ = try await repo.run(["merge","--no-ff","side","-m","Merge payload"]);let merge=try await repo.rebaseCommit("HEAD")
        try Data("stash\n".utf8).write(to:root.appendingPathComponent("initial.txt"));_ = try await repo.run(["stash","push","-m","selection stash"])
        var stash=try await repo.rebaseCommit("refs/stash");stash.references=[RevisionReference(name:"refs/stash")]
        try Data("post\n".utf8).write(to:root.appendingPathComponent("post.txt"));try await repo.stage(["post.txt"]);_ = try await repo.commit(message:"Post payload")
        let post=try await repo.rebaseCommit("HEAD"),head=try await repo.run(["rev-parse","HEAD"]).stdout
        let suite="TurtleGit.LogRevertSelection."+UUID().uuidString
        guard let prefs=UserDefaults(suiteName:suite) else{throw Failure(description:"Private preferences unavailable")}
        prefs.set(true,forKey:"LogIncludeWorkingTreeChanges");prefs.set(false,forKey:"EnableGravatar");prefs.set(true,forKey:"ShowAppContextMenuIcons")
        defer{prefs.removePersistentDomain(forName:suite)}
        try Data("unrelated working\n".utf8).write(to:root.appendingPathComponent("side.txt"))
        let owner=LogWindowController(repository:repo,access:nil,labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false),model=owner.model
        var child:HistoryRevertWindowController?,captured:LogRevertSelection?,legacy=0,commitCallbacks=0
        defer{child?.close();owner.close()}
        owner.window?.alphaValue=0;owner.window?.orderFront(nil);model.reload()
        try await wait{!model.busy && !model.loadingHistory && model.entries.contains{$0.hash.isEmpty} && views(owner.window?.contentView).contains{$0 is HistoryTableView}}
        guard let table=views(owner.window?.contentView).compactMap({$0 as? HistoryTableView}).first,let coordinator=table.delegate as? RevisionTable.Coordinator,let menu=table.menu,let working=model.entries.first(where:{$0.hash.isEmpty}) else{throw Failure(description:"Actual working-tree Log missing")}
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false);workspace.configureLogRevert(model,repository:repo,access:nil)
        try require(model.onPreparedRevert != nil,"Repository adapter lost source selection context")
        model.onRevertRevisions={_,_ in legacy += 1}
        model.onPreparedRevert={ [weak owner] selection in
            captured=selection
            let controller=HistoryRevertWindowController(repository:repo,access:nil,entries:selection.rows,mainline:selection.mainline,preferences:prefs);child=controller
            controller.model.onCommit={commitCallbacks += 1}
            controller.window?.alphaValue=0
            if let window=controller.window{owner?.window?.beginSheet(window)}
            controller.model.start()
        }
        func menuItem()->NSMenuItem? {menu.items.first{$0.action.map(NSStringFromSelector)=="revertCaptured:"}}
        func select(_ rows:[LogEntry]) {
            model.graph=CommitGraph.layout(rows);model.entries=rows
            model.select(Set(rows.map(\.hash)));coordinator.menuNeedsUpdate(menu)
        }
        func start(_ rows:[LogEntry]) throws {
            child=nil;captured=nil;select(rows)
            guard let item=menuItem(),let action=item.action,item.isEnabled else{throw Failure(description:"Source multi-selection Revert missing")}
            try require(item.submenu==nil,"Batch Revert invented a per-commit mainline picker")
            _ = NSApp.sendAction(action,to:item.target,from:item)
            try require(captured?.rows.map(\.hash)==rows.map(\.hash) && captured?.multiple==true && legacy==0,"Typed batch context lost placeholder or dispatched legacy twice")
        }
        func answer(_ title:String,default expected:String) async throws {
            try await wait{guard let sheet=child?.window?.attachedSheet else{return false};sheet.alphaValue=0;return sheet.defaultButtonCell != nil && views(sheet.contentView).compactMap{$0 as? NSButton}.contains{$0.title==title}}
            guard let sheet=child?.window?.attachedSheet,let button=views(sheet.contentView).compactMap({$0 as? NSButton}).first(where:{$0.title==title}) else{throw Failure(description:"Native Revert answer missing")}
            try require(sheet.defaultButtonCell?.title==expected,"Source native default differs: \(sheet.defaultButtonCell?.title ?? "nil")")
            button.performClick(nil)
        }
        func finished() async throws {try await wait{child?.model.busy==false && HistoryRevertWindowModel.activeOperations==0}}
        func closeChild() async throws {child?.close();try await wait{owner.window?.attachedSheet==nil};child=nil}
        let invocation=root.appendingPathComponent(".git/revert-invocations")
        func reset() async throws {_ = try await repo.run(["reset","--hard","HEAD"]);try? FileManager.default.removeItem(at:invocation);try Data("unrelated working\n".utf8).write(to:root.appendingPathComponent("side.txt"))}
        select([initial]);try require(menuItem()==nil,"Single-root Revert source exclusion changed")
        try start([working,initial]);try await answer("No",default:"No");try await finished();try await closeChild()
        try require(!FileManager.default.fileExists(atPath:invocation.path) && FileManager.default.fileExists(atPath:root.appendingPathComponent("initial.txt").path),"No invoked root Revert")
        try start([working,initial]);try await answer("Yes",default:"No");try await answer("OK",default:"OK");try await finished()
        try require(child?.model.success==true && child?.model.completed==2 && !FileManager.default.fileExists(atPath:root.appendingPathComponent("initial.txt").path),"Root batch did not apply or lost source progress count")
        try require(try String(contentsOf:root.appendingPathComponent("side.txt"))=="unrelated working\n","Root Revert changed unrelated working contents")
        let commands=try String(contentsOf:invocation);try require(commands.contains("revert\n--no-edit\n--no-commit\n"+initial.hash) && commands.components(separatedBy:"revert\n").count==2,"Git did not receive exact root commit")
        try await closeChild();try await reset()
        // One real merge plus the placeholder is still a multi-selection failure.
        try start([working,merge]);try await answer("Yes",default:"No");try await answer("Abort",default:"Abort");try await finished()
        try require(child?.model.success==false && child?.model.completed==2 && !FileManager.default.fileExists(atPath:invocation.path),"Merge batch guessed mainline or bypassed Skip/Abort")
        try await closeChild();try await reset()
        // Stash is also a merge: Skip it and continue to the eligible root.
        try start([working,stash,initial]);try await answer("Yes",default:"No");try await answer("Skip",default:"Abort");try await answer("OK",default:"OK");try await finished()
        try require(child?.model.success==true && child?.model.completed==3 && !FileManager.default.fileExists(atPath:root.appendingPathComponent("initial.txt").path),"Skip failed to continue to root")
        try await closeChild();try await reset()
        // Abort after a successful earlier commit preserves its inverse/message.
        try start([working,post,stash,initial]);try await answer("Yes",default:"No");try await answer("Abort",default:"Abort");try await answer("OK",default:"OK");try await finished()
        try require(child?.model.success==true && child?.model.completed==3 && FileManager.default.fileExists(atPath:root.appendingPathComponent("initial.txt").path) && !FileManager.default.fileExists(atPath:root.appendingPathComponent("post.txt").path),"Abort rolled back partial results or continued to root")
        let message=try String(contentsOf:root.appendingPathComponent(".git/MERGE_MSG"));try require(message.contains("Post payload") && commitCallbacks==0,"Partial message/OK result handoff differs")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout;try require(afterHead==head,"Revert batch committed or moved HEAD")
        try await closeChild()
        print("PASS: captured original Revert selection/count, typed Log adapter, native No/Yes and OK/Commit defaults, actual root inverse with unrelated preservation, merge Abort, stash Skip/root continuation, partial-result Abort/MERGE_MSG and unchanged HEAD; no empty revision or guessed mainline sent to Git; owned windows closed.")
    }
}
