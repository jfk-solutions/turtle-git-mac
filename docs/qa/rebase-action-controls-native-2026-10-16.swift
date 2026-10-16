import AppKit
import TurtleGitCore

@main struct RebaseActionControlsVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String) throws {if !value{throw Failure(description:message)}}
    @MainActor static func wait(_ ready:()->Bool,line:Int = #line) async throws {
        for _ in 0..<2500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Action controls timeout at \(line)")
    }
    @MainActor static func descendants(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{descendants($0)}}
    @MainActor static func capture(_ window:NSWindow,_ name:String) async throws {
        guard let path=ProcessInfo.processInfo.environment["TURTLEGIT_REBASE_ACTION_CAPTURES"] else{return}
        let folder=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        NSApp.activate(ignoringOtherApps:true);window.makeKeyAndOrderFront(nil);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:350_000_000)
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");process.arguments=["-x","-o","-l",String(window.windowNumber),folder.appendingPathComponent(name+".png").path]
        try process.run();process.waitUntilExit();try require(process.terminationStatus==0,"Compositor capture failed")
    }
    @MainActor static func main() async {do{try await verify()}catch{fputs("Rebase action controls failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify() async throws {
        let captures=ProcessInfo.processInfo.environment["TURTLEGIT_REBASE_ACTION_CAPTURES"] != nil
        NSApp.setActivationPolicy(captures ? .accessory:.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for(key,value) in [("user.name","Action QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"Base")
        let base=try await repo.rebaseCommit("HEAD")
        _ = try await repo.run(["switch","-c","upstream"]);try Data("upstream\n".utf8).write(to:root.appendingPathComponent("upstream"));try await repo.stage(["upstream"]);_ = try await repo.commit(message:"Upstream metadata")
        let upstream=try await repo.rebaseCommit("HEAD")
        _ = try await repo.run(["switch","-c","topic",base.hash])
        for index in 1...3 {let path="change-\(index).txt";try Data("revision \(index)\n".utf8).write(to:root.appendingPathComponent(path));try await repo.stage([path]);_ = try await repo.commit(message:"Change \(index)")}
        let original=try await repo.rebaseCommit("HEAD"),originalIndex=try await repo.run(["write-tree"]).stdout
        let suite="TurtleGit.RebaseActions."+UUID().uuidString
        guard let prefs=UserDefaults(suiteName:suite) else{throw Failure(description:"Private preferences unavailable")}
        defer{prefs.removePersistentDomain(forName:suite)}
        let controller=RebaseWindowController(repository:repo,access:nil,preferences:prefs),model=controller.model
        defer{model.retire();controller.close()}
        model.editorExecutable=URL(fileURLWithPath:CommandLine.arguments[3])
        controller.window?.alphaValue=captures ? 1:0;controller.window?.orderFront(nil)
        @MainActor func settle() async throws {try await wait{!model.busy && !model.loadingPlan && RebaseWindowModel.activePreparationReads==0 && RebaseWindowModel.activeColumnReads==0}}
        model.load(upstream:"refs/heads/upstream");try await settle()
        try require(model.entries.count==3 && model.canStart,"Plan unavailable: \(model.error ?? "none")")
        try require(model.referenceTooltip(branch:true).contains(original.hash) && model.referenceTooltip(branch:true).contains("Author: Action QA <qa@example.invalid>") && model.referenceTooltip(branch:false).contains(upstream.hash) && model.referenceTooltip(branch:false).contains("Upstream metadata"),"Reference tooltip is stale or incomplete")
        var control:NSSegmentedControl?
        try await wait{control=descendants(controller.window?.contentView).compactMap{$0 as? NSSegmentedControl}.first{$0.accessibilityLabel()=="Rebase bulk actions"};return control != nil}
        let referenceButtons=descendants(controller.window?.contentView).compactMap{$0 as? NSPopUpButton}
        try require(referenceButtons.first{$0.accessibilityLabel()=="Branch"}?.toolTip==model.referenceTooltip(branch:true) && referenceButtons.first{$0.accessibilityLabel()=="Upstream"}?.toolTip==model.referenceTooltip(branch:false),"Native reference controls omitted captured tooltips")
        guard let bulk=control,let coordinator=bulk.target as? RebaseSplitControl.Coordinator,let menu=bulk.menu(forSegment:1) else{throw Failure(description:"Native split/menu missing")}
        try require(menu.items.map(\.title)==RebaseBulkAction.allCases.map(\.rawValue) && menu.items.allSatisfy{$0.image != nil},"Source bulk order/artwork differs")
        func pressMain(_ button:NSSegmentedControl) throws {
            // AppKit's momentary segment is selected only during its native
            // event dispatch. Reproduce that state for a headless target/action
            // invocation, restoring the production tracking mode afterwards.
            let tracking=button.trackingMode;defer{button.trackingMode=tracking}
            button.trackingMode = .selectOne;button.selectedSegment=0
            guard let selector=button.action else{throw Failure(description:"Split control action missing")}
            _ = NSApp.sendAction(selector,to:button.target,from:button)
        }
        func choose(_ action:RebaseBulkAction) throws {
            coordinator.menuWillOpen(menu)
            guard let item=menu.items.first(where:{$0.title==action.rawValue}),let selector=item.action else{throw Failure(description:"Bulk action missing")}
            _ = NSApp.sendAction(selector,to:item.target,from:item)
        }
        try choose(.squashAll)
        try require(model.bulkAction == .squashAll && model.plan?.entries.map(\.action)==[.pick,.squash,.squash] && model.canStart,"Squash ALL changed oldest commit")
        try choose(.editAll);try require(model.plan?.entries.allSatisfy{$0.action == .edit}==true,"Edit ALL failed")
        model.setAction(.pick,ids:[model.entries[0].id]);try pressMain(bulk)
        try require(model.plan?.entries.allSatisfy{$0.action == .edit}==true,"Main segment did not repeat chosen bulk command: selected=\(bulk.selectedSegment), enabled=\(bulk.isEnabled), editable=\(model.canUseBulkActions), choice=\(model.bulkAction), actions=\(model.plan?.entries.map(\.action) ?? [])")
        model.chooseBulkAction(.pickAll);model.selection=[model.entries[1].id];model.setAction(.edit)
        try choose(.squashUnselected)
        try require(model.plan?.entries.map(\.action)==[.pick,.edit,.squash],"Unselected Squash changed selected/oldest row")
        try choose(.skipUnselected);try require(model.plan?.entries.map(\.action)==[.skip,.edit,.skip],"Skip unselected changed selected row")
        try choose(.editUnselected);try require(model.plan?.entries.allSatisfy{$0.action == .edit}==true,"Edit unselected failed")
        model.chooseBulkAction(.pickAll);let oldest=model.entries.last!.id
        model.setAction(.squash,ids:[oldest]);try require(model.plan?.entries.first?.action == .pick,"Selected Squash changed oldest commit")
        coordinator.menuWillOpen(menu);let oldItem=menu.items[1];model.selection=[model.entries[0].id];coordinator.chosen(oldItem)
        try require(model.bulkAction == .pickAll && model.plan?.entries.allSatisfy{$0.action == .pick}==true,"Stale selection menu applied")
        let away=model.captureBulkAction(),previousSelection=model.selection
        model.selection=[oldest];model.selection=previousSelection;away?(RebaseBulkAction.editAll.rawValue)
        try require(model.bulkAction == .pickAll,"Selection-away/return revived an old menu")
        let once=model.captureBulkAction();once?(RebaseBulkAction.editAll.rawValue);once?(RebaseBulkAction.pickAll.rawValue)
        try require(model.bulkAction == .editAll && model.plan?.entries.allSatisfy{$0.action == .edit}==true,"Bulk request was replayed")
        model.busy=true;model.chooseBulkAction(.pickAll);try require(model.bulkAction == .editAll,"Busy bulk callback accepted");model.busy=false
        model.chooseBulkAction(.squashAll)
        for(appearance,name) in [(NSAppearance.Name.aqua,"rebase-action-controls-light"),(.darkAqua,"rebase-action-controls-dark")] {controller.window?.appearance=NSAppearance(named:appearance);if let window=controller.window{try await capture(window,name)}}
        // Actual Edit pause exposes Edit/Split next to Continue, with ordinary Abort recovery.
        model.chooseBulkAction(.pickAll);model.setAction(.edit,ids:[oldest]);model.execute("start");try await settle()
        try require(model.active && model.state?.canSplit==true && model.canSplit,"Edit pause did not expose footer Split")
        for(appearance,name) in [(NSAppearance.Name.aqua,"rebase-edit-footer-light"),(.darkAqua,"rebase-edit-footer-dark")] {controller.window?.appearance=NSAppearance(named:appearance);if let window=controller.window{try await capture(window,name)}}
        model.execute("abort");try await settle()
        let aborted=try await repo.rebaseCommit("HEAD"),abortedIndex=try await repo.run(["write-tree"]).stdout
        try require(aborted.hash==original.hash && abortedIndex==originalIndex,"Edit Abort failed to restore repository")
        try require(model.retired,"Abort did not retire its native owner")
        let reopened=RebaseWindowController(repository:repo,access:nil,preferences:prefs),replay=reopened.model
        defer{replay.retire();reopened.close()}
        replay.editorExecutable=URL(fileURLWithPath:CommandLine.arguments[3]);reopened.window?.alphaValue=captures ? 1:0;reopened.window?.orderFront(nil)
        @MainActor func settleReplay() async throws {try await wait{!replay.busy && !replay.loadingPlan && RebaseWindowModel.activePreparationReads==0 && RebaseWindowModel.activeColumnReads==0}}
        replay.load(upstream:"refs/heads/upstream");try await settleReplay()
        try require(replay.canUseBulkActions,"Reopened Rebase not editable")
        replay.chooseBulkAction(.squashAll)
        try require(replay.plan?.entries.map(\.action)==[.pick,.squash,.squash] && replay.canStart,"Reloaded bulk plan invalid: \(replay.plan?.entries.map(\.action) ?? [])")
        replay.execute("start");try await settleReplay()
        if replay.state?.squashMessage != nil {replay.amendMessage="Combined changes";replay.execute("continue");try await settleReplay()}
        try require(replay.finished && replay.completedSuccessfully,"Bulk Squash replay failed: \(replay.error ?? replay.output)")
        let count=try await repo.run(["rev-list","--count","refs/heads/upstream..refs/heads/topic"]).text
        try require(count=="1\n","Bulk Squash did not create one replayed commit")
        var routes:[String]=[],closed=0
        replay.close={closed += 1};replay.onCompletedLog={routes.append("log")};replay.onCompletedPush={routes.append("push:"+$0)};replay.onCompletedMail={_ in routes.append("mail")}
        try await wait{descendants(reopened.window?.contentView).compactMap{$0 as? NSSegmentedControl}.contains{$0.accessibilityLabel()=="Rebase completion actions"}}
        replay.completionAfterFetch=true;replay.objectWillChange.send()
        var completion:NSSegmentedControl?
        try await wait{completion=descendants(reopened.window?.contentView).compactMap{$0 as? NSSegmentedControl}.first{$0.accessibilityLabel()=="Rebase completion actions"};return completion?.menu(forSegment:1)?.items.count==4}
        guard let post=completion,let postCoordinator=post.target as? RebaseSplitControl.Coordinator,let postMenu=post.menu(forSegment:1),let push=postMenu.items.first(where:{$0.title==RebaseCompletionAction.push.rawValue}) else{throw Failure(description:"Completion split missing")}
        postCoordinator.menuWillOpen(postMenu);postCoordinator.chosen(push);postCoordinator.chosen(push)
        try require(replay.completionAction == .push && routes==["push:HEAD"] && closed==1,"Completion selection was not remembered or repeated")
        try pressMain(post)
        try require(routes==["push:HEAD","push:HEAD"] && closed==2,"Main completion segment ignored chosen command")
        let stale=replay.captureCompletionAction();replay.load(upstream:"refs/heads/upstream");try await settleReplay();stale?(RebaseCompletionAction.log.rawValue)
        try require(routes.count==2,"Old completion callback survived restart")
        replay.retire();replay.chooseBulkAction(.pickAll);try require(replay.captureBulkAction()==nil,"Retired bulk menu available")
        print("PASS: native source-ordered sticky Rebase bulk/completion split controls, oldest/selected/unselected rules, one-use/stale/busy guards, canonical reference metadata, actual Edit/footer/Abort and Squash replay; owned windows closed.")
    }
}
