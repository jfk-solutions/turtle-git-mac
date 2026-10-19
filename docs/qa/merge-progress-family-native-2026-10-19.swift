import AppKit
import TurtleGitCore

@MainActor enum MergeProgressFamilyFixture {
    static func require(_ value:Bool,_ text:String)throws{if !value{throw NSError(domain:text,code:1)}}
    static func wait(_ text:String,_ value:()->Bool)async throws{for _ in 0..<2500{if value(){return};try await Task.sleep(nanoseconds:10_000_000)};throw NSError(domain:text,code:2)}
    static func views(_ view:NSView?)->[NSView]{guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    static func repository(_ name:String,conflict:Bool=false)async throws->GitRepository{
        let root=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(name),git=URL(fileURLWithPath:CommandLine.arguments[2])
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:git);_ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Merge family"),("user.email","merge@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_ = try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"base")
        _ = try await repo.run(["switch","-c","feature"])
        let changed=conflict ? "file":"feature"
        try Data("theirs\n".utf8).write(to:root.appendingPathComponent(changed));try await repo.stage([changed]);_ = try await repo.commit(message:"feature")
        _ = try await repo.run(["switch","main"])
        if conflict{try Data("ours\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_ = try await repo.commit(message:"ours")}
        return repo
    }
    static func options()->MergeOptions{var value=MergeOptions();value.revision="refs/heads/feature";value.noFastForward=true;return value}
    static func owner(_ model:MergeProgressWindowModel)->(NSWindow,MergeProgressWindowController){
        let parent=NSWindow(contentRect:NSRect(x:-12000,y:-12000,width:700,height:450),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        parent.isReleasedWhenClosed=false;parent.alphaValue=0;parent.appearance=NSAppearance(named:.darkAqua)
        let controller=MergeProgressWindowController(model:model)
        controller.window?.alphaValue=0;controller.window?.appearance=parent.appearance
        if let window=controller.window{parent.beginSheet(window,completionHandler:nil)}
        return(parent,controller)
    }
    static func footer(_ model:MergeProgressWindowModel,_ owner:MergeProgressWindowController,success:Bool)async throws{
        try await wait("Native Merge output/footer did not update"){
            owner.window?.contentView?.layoutSubtreeIfNeeded()
            return views(owner.window?.contentView).compactMap{$0 as? SubmoduleProgressTextView}.first?.string==model.output && model.completionRange != nil
        }
        let text=views(owner.window?.contentView).compactMap{$0 as? SubmoduleProgressTextView}.first!,range=model.completionRange!
        try require(model.commandFinished && model.commandSucceeded==success && model.percentage==100 && NSMaxRange(range)<=text.textStorage!.length,"Merge completion lost receipt/range/retained100")
        let caption=(model.output as NSString).substring(with:range)
        try require(success ? caption.contains("Success") : ["git did not exit cleanly","Operation failed","User cancelled"].contains(where:caption.contains),"Merge footer did not identify command outcome: \(caption)")
        let actual=text.textStorage!.attribute(.foregroundColor,at:range.location,effectiveRange:nil) as? NSColor
        for appearance in [NSAppearance.Name.aqua,.darkAqua]{
            NSAppearance(named:appearance)!.performAsCurrentDrawingAppearance{
                let expected=success ? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? NSColor.textColor:SubmoduleProgressTextView.successColor:SubmoduleProgressTextView.color(error:true)
                precondition(actual?.usingColorSpace(.sRGB)==expected.usingColorSpace(.sRGB),"Native Merge footer color differs in \(appearance)")
            }
        }
        try require(!text.isEditable && text.isSelectable && text.preferences===model.presentationPreferences,"Merge output lost source read-only selectable control or captured preferences")
    }
}

struct MergeProgressFamilyVerification {
    @MainActor static func verify()async throws{
        typealias F=MergeProgressFamilyFixture
        let suite="TurtleGit.MergeFamily."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,clipboard=NSPasteboard.withUniqueName()
        prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(true,forKey:"StyleGitOutput");prefs.set(true,forKey:"ShowAppContextMenuIcons");prefs.set(13,forKey:"LogFontSize");prefs.set(false,forKey:"ShowGitexeTimings")
        defer{prefs.removePersistentDomain(forName:suite);clipboard.releaseGlobally()}
        let repo=try await F.repository("success"),model=MergeProgressWindowModel(repository:repo,access:nil,options:F.options(),target:.branch,showStashPop:false,preferences:prefs)
        model.outputClipboard=clipboard
        let (parent,owner)=F.owner(model);defer{owner.close();parent.close()}
        var closed=0,handoffs=0
        owner.onClosed={closed+=1};model.onPostAction={action,request in
            precondition(action == .push && request.revision=="refs/heads/feature" && parent.attachedSheet==nil && owner.window?.sheetParent==nil && !model.hasPendingWork)
            handoffs+=1
        }
        await model.run();try await F.wait("Successful Merge retained worker"){!model.busy && !model.hasPendingWork}
        try F.require(model.success && model.postActions==[.removeBranch,.push],"Successful Merge post-actions differ")
        try await F.footer(model,owner,success:true)
        try F.require(!(model.output as NSString).substring(with:model.completionRange!).contains(" ms @ "),"Captured hidden Git timings preference was ignored")
        let text=F.views(owner.window?.contentView).compactMap{$0 as? SubmoduleProgressTextView}.first!
        try F.require(text.clipboard===clipboard && text.font?.pointSize==13,"Merge output ignored captured pasteboard/font")
        text.setSelectedRange(NSRange(location:0,length:min(4,(text.string as NSString).length)));let selected=text.selectedRange()
        text.copyAllInformation(nil);try F.require(clipboard.string(forType:.string)==model.output && text.selectedRange()==selected,"Native Copy All changed output bytes or selection")
        let menu=text.outputMenu();try F.require(menu.items.filter{!$0.isSeparatorItem}.allSatisfy{$0.image != nil},"Merge output context icons missing")
        var question:NSAlert?,reply:((NSApplication.ModalResponse)->Void)?
        owner.presentQuestion={kind,alert,window,answer in
            if case .deleteBranch(let branch)=kind{precondition(branch=="feature")}else{preconditionFailure("Unexpected Merge question")}
            question=alert;reply=answer;alert.beginSheetModal(for:window,completionHandler:answer)
        }
        let head=try await repo.run(["rev-parse","HEAD"]).stdout
        model.perform(.removeBranch);try await F.wait("Delete branch question missing"){question?.window.sheetParent===owner.window}
        try F.require(question?.window.alphaValue==0 && question?.window.appearance?.name==parent.appearance?.name && model.confirmingDeletion,"Delete branch question lost captured presentation")
        reply?(.alertSecondButtonReturn);reply?(.alertFirstButtonReturn)
        try await F.wait("Abort-delete question did not detach"){!model.confirmingDeletion && owner.window?.attachedSheet==nil}
        let retained=try await repo.run(["show-ref","--verify","--quiet","refs/heads/feature"],successfulExitCodes:0...1)
        try F.require(retained.exitCode==0,"Late duplicate Abort-delete deleted branch")
        question=nil;model.perform(.removeBranch);try await F.wait("Second Delete branch question missing"){question?.window.sheetParent===owner.window}
        reply?(.alertFirstButtonReturn);reply?(.alertFirstButtonReturn)
        try await F.wait("Delete branch worker did not drain"){!model.busy && !model.hasPendingWork && !model.confirmingDeletion && owner.window?.attachedSheet==nil}
        let removed=try await repo.run(["show-ref","--verify","--quiet","refs/heads/feature"],successfulExitCodes:0...1),after=try await repo.run(["rev-parse","HEAD"]).stdout
        try F.require(removed.exitCode==1 && after==head && model.postActions==[.push],"Delete branch changed merged HEAD or retained delete action")
        model.perform(.push);model.perform(.push)
        try await F.wait("Actual-close Push handoff did not release"){closed==1 && handoffs==1 && parent.attachedSheet==nil}
        let unrelated=try await F.repository("unrelated")
        _ = try await unrelated.run(["checkout","--orphan","other"]);_ = try await unrelated.run(["rm","-rf","--","."])
        try Data("other\n".utf8).write(to:unrelated.root.appendingPathComponent("other"));try await unrelated.stage(["other"]);_ = try await unrelated.commit(message:"Unrelated source");_ = try await unrelated.run(["switch","main"])
        var retryOptions=F.options();retryOptions.revision="refs/heads/other"
        let retry=MergeProgressWindowModel(repository:unrelated,access:nil,options:retryOptions,target:.branch,showStashPop:false,preferences:prefs),retryHost=F.owner(retry)
        defer{retryHost.1.close();retryHost.0.close()}
        await retry.run();try await F.footer(retry,retryHost.1,success:false)
        try F.require(retry.postActions==[.mergeUnrelated,.stash],"Unrelated failure lost explicit retry")
        let failed=retry.output;retry.perform(.mergeUnrelated)
        try F.require(retry.hasPendingWork && !retry.commandFinished && retry.completionRange==nil && retry.percentage==nil && retry.output.isEmpty,"Retry did not synchronously retire the prior attempt receipt")
        try await F.wait("Unrelated retry did not finish"){!retry.busy && !retry.hasPendingWork && retry.success}
        try await F.footer(retry,retryHost.1,success:true)
        try F.require(retry.output != failed && !retry.output.contains("refusing to merge unrelated histories"),"Retry retained prior attempt diagnostics/footer")
        let parents=try await unrelated.run(["rev-list","--parents","-n","1","HEAD"]).text.split(whereSeparator:{$0.isWhitespace})
        try F.require(parents.count==3,"Explicit unrelated retry did not create a real merge commit")
        print("Merge native styled output/footer, captured clipboard/font/icons, actual Delete abort/accept, actual-close once-only handoff and unrelated retry passed.")
    }
}
