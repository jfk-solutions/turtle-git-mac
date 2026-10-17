// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import ScreenCaptureKit
import TurtleGitCore

struct RebaseSourceVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ yes:Bool,_ message:String)throws {if !yes {throw Failure(description:message)}}
    @MainActor static func wait(_ ready:()->Bool,line:UInt = #line)async throws {for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Rebase source timeout at \(line)")}
    @MainActor static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    @MainActor static func settle(_ model:RebaseWindowModel)async throws {try await wait {!model.busy && !model.loadingPlan && RebaseWindowModel.activePreparationReads==0 && RebaseWindowModel.activeColumnReads==0 && RebaseWindowModel.activeReplayOperations==0}}
    @MainActor static func capture(_ window:NSWindow,name:String,folder:URL)async throws {
        guard #available(macOS 14.4,*) else {throw Failure(description:"Capture requires 14.4")}
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        for (appearance,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:appearance);window.alphaValue=1;window.orderFront(nil);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
            try require(window.frame.height<=900,"Rebase host escaped native content bounds")
            let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
            guard let own=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else {throw Failure(description:"Missing capture owner")}
            let configuration=SCStreamConfiguration();configuration.includeChildWindows=false;configuration.width=Int(window.frame.width*2);configuration.height=Int(window.frame.height*2);configuration.showsCursor=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:own),configuration:configuration)
            guard let png=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else {throw Failure(description:"Missing PNG")}
            try png.write(to:folder.appendingPathComponent(name+"-"+suffix+".png"))
        };window.orderOut(nil);window.alphaValue=0
    }
    @MainActor static func verify()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Rebase Source"),("user.email","qa@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] {_=try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:root.appendingPathComponent("base"));try await repo.stage(["base"]);_=try await repo.commit(message:"Base")
        let base=try await repo.rebaseCommit("HEAD")
        _=try await repo.run(["switch","-c","upstream"]);try Data("upstream\n".utf8).write(to:root.appendingPathComponent("upstream"));try await repo.stage(["upstream"]);_=try await repo.commit(message:"Upstream")
        let upstream=try await repo.rebaseCommit("HEAD")
        _=try await repo.run(["switch","-c","topic",base.hash])
        for i in 1...2 {let file="topic-\(i)";try Data("topic \(i)\n".utf8).write(to:root.appendingPathComponent(file));try await repo.stage([file]);_=try await repo.commit(message:"Topic \(i)")}
        let head=try await repo.rebaseCommit("HEAD"),tree=try await repo.run(["write-tree"]).stdout
        let suite="TurtleGit.RebaseSource."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"EnableLogCache");prefs.set(false,forKey:"EnableGravatar");defer {prefs.removePersistentDomain(forName:suite)}
        let owner=RebaseWindowController(repository:repo,access:nil,preferences:prefs),model=owner.model
        defer {owner.close()};owner.window?.alphaValue=0;owner.window?.orderFront(nil);model.editorExecutable=URL(fileURLWithPath:CommandLine.arguments[3]);model.load(upstream:"refs/heads/upstream");try await settle(model)
        try require(model.canStart && model.startTitle=="Start Rebase" && model.entries.count==2,"Source plan missing")
        let oldBranch=model.referenceBinding(branch:true,context:model.formContext)
        model.option(\.force,context:model.formContext).wrappedValue=true
        try require(model.loadingPlan && model.plan==nil,"Force did not synchronously replace plan")
        oldBranch.wrappedValue="refs/heads/main";try require(model.options.branch=="refs/heads/topic","Old option context changed branch")
        try await settle(model);model.option(\.force,context:model.formContext).wrappedValue=false;try await settle(model)
        model.option(\.preserveMerges,context:model.formContext).wrappedValue=true
        try require(!model.canAdd && model.loadingPlan,"Preserve merges did not immediately disable Add/reload")
        try await settle(model);model.option(\.preserveMerges,context:model.formContext).wrappedValue=false;try await settle(model)
        let picker=model.beginReferenceSelection(.upstream)!
        model.options.force=true;model.acceptReferenceSelection(picker,value:"refs/heads/main");try await settle(model)
        try require(model.options.upstream=="refs/heads/upstream" && model.pickingReference==nil,"Changed picker options accepted old target")
        model.option(\.force,context:model.formContext).wrappedValue=false;try await settle(model)
        try await wait {views(owner.window?.contentView).compactMap{$0 as? NSSegmentedControl}.contains{$0.accessibilityLabel()=="Rebase bulk actions"}}
        let bulk=views(owner.window?.contentView).compactMap{$0 as? NSSegmentedControl}.first{$0.accessibilityLabel()=="Rebase bulk actions"}!,target=bulk.target as! RebaseSplitControl.Coordinator
        try require(bulk is RebaseNativeSplitControl && bulk.menu(forSegment:1)?.items.allSatisfy{$0.image != nil}==true,"Owned source split control/artwork missing")
        model.setAction(.edit,ids:[model.plan!.entries[0].id])
        if let folder=ProcessInfo.processInfo.environment["TURTLEGIT_REBASE_SOURCE_CAPTURE"] {try await capture(owner.window!,name:"rebase-source",folder:URL(fileURLWithPath:folder))}
        model.request("start");let first=model.pendingConfirmation!
        try require(!model.editable && !model.revisionMenuAvailable && !owner.windowShouldClose(owner.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Confirmation lost form/Close/Quit ownership")
        model.option(\.force,context:model.formContext).wrappedValue=true;try require(!model.options.force,"Pending confirmation accepted Force")
        model.options.force=true;model.options.force=false
        model.answerConfirmation(first,proceed:true);try require(!model.busy && !model.active && model.pendingConfirmation==nil,"Changed-and-restored plan accepted old confirmation")
        model.request("start");let second=model.pendingConfirmation!;model.answerConfirmation(first,proceed:false)
        try require(model.pendingConfirmation?.id==second.id,"Old reply dismissed new confirmation")
        model.answerConfirmation(second,proceed:false);model.request("start");let accepted=model.pendingConfirmation!
        // Auto-dismissal may clear presentation before the retained action runs.
        model.confirmation=nil;model.answerConfirmation(accepted,proceed:true);model.answerConfirmation(accepted,proceed:true)
        try await settle(model);try require(model.active && model.state?.isEditPause==true && model.primaryActionTitle=="Amend","Accepted Start did not reach actual Edit pause")
        let message=model.messageBinding(model.formContext);message.wrappedValue="Edited Cafe\u{301}";message.wrappedValue="Edited Café"
        try require(model.amendMessage.utf8.elementsEqual("Edited Café".utf8),"Captured active message dropped Unicode edits")
        model.splitBinding(model.formContext).wrappedValue=true;try require(model.splitCommit,"Source Edit/Split unavailable")
        model.splitBinding(model.formContext).wrappedValue=false
        if let folder=ProcessInfo.processInfo.environment["TURTLEGIT_REBASE_SOURCE_CAPTURE"] {try await capture(owner.window!,name:"rebase-edit-source",folder:URL(fileURLWithPath:folder))}
        model.request("abort");let abort=model.pendingConfirmation!;model.confirmation=nil;model.answerConfirmation(abort,proceed:true);try await settle(model)
        let restored=try await repo.rebaseCommit("HEAD"),restoredTree=try await repo.run(["write-tree"]).stdout
        try require(restored.hash==head.hash && tree==restoredTree && !model.active && model.retired,"Actual Abort did not restore and retire owner")
        target.menuWillOpen(bulk.menu(forSegment:1) ?? NSMenu());try require(!bulk.isEnabled && (bulk as? RebaseNativeSplitControl)?.lifetime.retired==true,"Retired native split control remained enabled")
        message.wrappedValue="closed";try require(model.amendMessage != "closed","Closed message binding remained live")
        let cherry=RebaseWindowController(repository:repo,access:nil,preferences:prefs);defer {cherry.close()};cherry.window?.alphaValue=0;cherry.window?.orderFront(nil);cherry.model.load(cherryPick:[head.hash]);try await settle(cherry.model)
        cherry.model.option(\.addCherryPickedFrom,context:cherry.model.formContext).wrappedValue=true
        try require(cherry.model.plan?.options.addCherryPickedFrom==true && prefs.bool(forKey:"CherrypickAddCherryPickedFrom"),"Cherry Pick source attribution did not update synchronously")
        let internalForce=cherry.model.options.force;cherry.model.option(\.force,context:cherry.model.formContext).wrappedValue = !internalForce;try require(cherry.model.options.force==internalForce,"Cherry Pick accepted hidden Force option")
        if let folder=ProcessInfo.processInfo.environment["TURTLEGIT_REBASE_SOURCE_CAPTURE"] {try await capture(cherry.window!,name:"cherry-pick-source",folder:URL(fileURLWithPath:folder))};cherry.close()
        let fast=RebaseWindowModel(repository:repo,access:nil,messageDefaults:prefs);defer {fast.retire()};fast.load(upstream:upstream.hash);try await settle(fast);fast.chooseBranch("refs/heads/main");try await settle(fast)
        try require(fast.plan?.disposition == .fastForward && fast.primaryActionTitle=="Start (FastFwd)","Source fast-forward button title missing")
        let queued=RebaseWindowModel(repository:repo,access:nil,messageDefaults:prefs);defer {queued.retire()}
        queued.load(upstream:"refs/heads/upstream");try await settle(queued);queued.request("start");let waiting=queued.pendingConfirmation!
        queued.load(upstream:base.hash);queued.refreshState()
        try require(!queued.busy && queued.pendingConfirmation?.id==waiting.id && queued.options.upstream=="refs/heads/upstream","Incoming handoff replaced reviewed question/plan")
        queued.answerConfirmation(waiting,proceed:false);try await settle(queued)
        try require(queued.pendingConfirmation==nil && queued.options.upstream==base.hash && queued.plan?.upstreamHash==base.hash,"Queued session refresh/Fetch handoff did not resume after answer")
        print("PASS Rebase source: captured reference/options/message/footer bindings, synchronous Force/Preserve/Cherry attribution, complete picker intent, immutable one-use confirmations, queued refresh/handoffs and Close/Quit fences, real Start/Edit/Abort restoration, owned split controls and source fast-forward title; private repositories/preferences")
    }
}
