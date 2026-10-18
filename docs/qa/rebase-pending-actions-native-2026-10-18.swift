// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum RebasePendingActionsVerification {
    struct Failure: Error, CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(description:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool) async throws {
        for _ in 0..<2200 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Pending replay actions did not settle at \(line)")
    }
    static func views(_ root:NSView)->[NSView] {[root]+root.subviews.flatMap(views)}
    static func verify(structural:Bool) async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2])),editor=URL(fileURLWithPath:CommandLine.arguments[3])
        _ = try await repo.run(["init","-b","main"])
        for(key,value) in [("user.name","Pending Replay QA"),("user.email","pending@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        func commit(_ path:String) async throws {try Data((path+"\n").utf8).write(to:root.appendingPathComponent(path));try await repo.stage([path]);_ = try await repo.commit(message:path)}
        try await commit("base");_ = try await repo.run(["switch","-c","upstream"]);try await commit("upstream")
        if structural {_ = try await repo.run(["switch","-c","side","main"]);try await commit("side")}
        _ = try await repo.run(["switch","-c","topic","main"])
        for path in ["first","second","third"] {try await commit(path)}
        if structural {_ = try await repo.run(["merge","--no-ff","--no-edit","side"])}
        let domain="TurtleGit.PendingReplay.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:domain)!
        defer {prefs.removePersistentDomain(forName:domain)}
        let owner=RebaseWindowController(repository:repo,access:nil,preferences:prefs),model=owner.model,window=owner.window!
        defer {owner.close()};window.alphaValue=0;window.orderFront(nil);model.editorExecutable=editor
        model.load(upstream:"refs/heads/upstream",preserveMerges:structural)
        try await wait {!model.busy && !model.loadingPlan && model.canStart && RebaseWindowModel.activePreparationReads==0}
        let oldest=model.entries.last!.id;model.setAction(.edit,ids:[oldest]);model.execute("start")
        try await wait {!model.busy && model.active && model.state?.isEditPause==true && RebaseWindowModel.activePreparationReads==0}
        let before=try await repo.rebaseActionEditSnapshot(),index=try Data(contentsOf:root.appendingPathComponent(".git/index")),todo=root.appendingPathComponent(".git/rebase-merge/git-rebase-todo")
        model.amendMessage="Unapplied native editor draft";let draft=model.amendMessage
        let skippedPath=structural ? "second":"third"
        let future=model.entries.first{$0.progress == .pending && $0.commit.subject==skippedPath}!.id
        model.selection=[future]
        var table:RebaseReplayNativeTable?
        try await wait {table=views(window.contentView!).compactMap{$0 as? RebaseReplayNativeTable}.first;return table?.owner?.available==true && model.revisionMenuAvailable && RebaseWindowModel.activePreparationReads==0}
        let native=table!,coordinator=native.owner!
        let menu=coordinator.menu(ids:[future],alternate:false),edit=menu.item(withTitle:"Edit")!
        try require(edit.isEnabled && edit.image != nil && !model.editable && model.canEditPendingActions,"Paused future row actions missing")
        _ = NSApp.sendAction(edit.action!,to:edit.target,from:edit)
        try await wait {!model.busy && !model.editingPendingActions && RebaseWindowModel.activePreparationReads==0}
        try require(model.error==nil && model.entries.first{$0.id==future}?.action == .edit,"Native pending Edit was not saved: "+(model.error ?? "none"))
        try require(model.amendMessage==draft,"Saving future actions discarded current message draft")
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==index,"Pending action changed index")
        let saved=try await GitRepository(root:root,executable:repo.executable).rebaseActionEditSnapshot()
        try require(saved.head==before.head && saved.replay.first{$0.id==future}?.action == .edit,"Saved action did not survive fresh repository/session read")
        model.setAction(.skip,ids:[future]);try await wait {!model.busy && RebaseWindowModel.activePreparationReads==0}
        try require(model.entries.first{$0.id==future}?.action == .skip && model.amendMessage==draft,"Pending Skip lost action or draft")
        try require(model.revisionActionChoices([oldest]).isEmpty,"Current occurrence exposed editable actions")
        let originalBytes=try Data(contentsOf:todo),captured=try await repo.rebaseActionEditSnapshot()
        var held:CheckedContinuation<RebaseActionEditSnapshot,Never>?
        defer {held?.resume(returning:captured);held=nil}
        model.readActionEditSnapshot={_ in await withCheckedContinuation {held=$0}}
        model.setAction(.pick,ids:[future]);try await wait {held != nil}
        window.performClose(nil)
        try require(!model.retired && RebaseWindowModel.activePreparationReads>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Pending write preparation lost close/Quit ownership")
        model.cancelPreparation();owner.close();held?.resume(returning:captured);held=nil
        try await wait {RebaseWindowModel.activePreparationReads==0 && RebaseWindowModel.activeColumnReads==0}
        let retiredBytes=try Data(contentsOf:todo)
        try require(model.retired && retiredBytes==originalBytes,"Late cancelled/retired action rewrote saved todo")
        let final=try await repo.continueRebase()
        try require(!final.state.active,"Saved future Skip did not finish replay: "+final.output)
        let head=try await repo.rebaseCommit("HEAD")
        try require(head.parents.count==(structural ? 2:1),"Saved actions changed replay topology")
        try require(!FileManager.default.fileExists(atPath:root.appendingPathComponent(skippedPath).path),"Saved future Skip was not executed")
        print("PASS: native paused future Edit/Skip, real menu eligibility/icons, durable reopen, current-message draft/index/HEAD preservation, close/Quit/cancel/retirement drain and actual linear/structural Continue")
    }
}
