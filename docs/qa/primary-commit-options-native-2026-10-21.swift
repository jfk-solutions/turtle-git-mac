// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// Invoked by the shared primary-dialog receiver. Every window, preference
/// domain and delayed operation belongs to this private repository fixture.
enum PrimaryCommitOptionsVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:UInt = #line)throws {if !value{throw Failure(description:"\(line): \(message)")}}
    @MainActor static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    @MainActor static func wait(_ window:NSWindow?,_ message:String,_ ready:()->Bool)async throws {
        for _ in 0..<1800 {window?.contentView?.layoutSubtreeIfNeeded();if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:message)
    }
    @MainActor final class Gate {
        var entered=false
        private var continuation:CheckedContinuation<Void,Never>?
        func hold()async {entered=true;await withCheckedContinuation{continuation=$0}}
        func release(){let current=continuation;continuation=nil;current?.resume()}
    }
    @MainActor final class Context {
        let repository:GitRepository,preferences:UserDefaults,suite:String
        var owners:[CommitWindowController]=[],menus:[NSMenu]=[],gates:[Gate]=[]
        init(repository:GitRepository){
            self.repository=repository;suite="TurtleGit.PrimaryCommitOptions."+UUID().uuidString;preferences=UserDefaults(suiteName:suite)!
            preferences.set(false,forKey:"UseLibgit2");preferences.set(true,forKey:"ShowAppContextMenuIcons")
            preferences.set(true,forKey:"SelectFilesForCommit");preferences.set(true,forKey:"AddBeforeCommit")
            preferences.set(false,forKey:"ConfirmKillProcess");preferences.set(1,forKey:"CommitMergeHint");preferences.set(1,forKey:"HintStagingMode")
        }
        func owner()async throws->CommitWindowController {
            let owner=CommitWindowController(repository:repository,access:nil,defaults:preferences)
            owners.append(owner);owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-18000,y:-18000))
            owner.showWindow(nil);owner.model.reload(paths:["literal.txt"])
            try await PrimaryCommitOptionsVerification.wait(owner.window,"Initial Commit snapshot did not settle"){!owner.model.busy && owner.model.changelistsLoaded && owner.commandsAvailable}
            let menu=NSMenu(title:"Private Commit commands");menus.append(menu)
            guard let router=owner.commandMenu else{throw Failure(description:"Actual Commit command router missing")}
            router.applicationMenu={menu};router.keyWindow={ [weak owner] in owner?.window};router.install()
            return owner
        }
        func gate()->Gate {let value=Gate();gates.append(value);return value}
        func clean()async throws {
            owners.forEach{$0.close()};gates.forEach{$0.release()}
            try await PrimaryCommitOptionsVerification.wait(nil,"Commit fixture workers did not drain"){
                CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activeReloads==0 && CommitWindowModel.activeCommitPreflights==0
            }
            preferences.removePersistentDomain(forName:suite)
        }
    }
    @MainActor static func allItems(_ menu:NSMenu)->[NSMenuItem] {menu.items.flatMap{[$0]+($0.submenu.map{allItems($0)} ?? [])}}
    @MainActor static func item(_ context:Context,_ name:String)->NSMenuItem? {context.menus.flatMap{allItems($0)}.last{$0.identifier?.rawValue=="TurtleGit.Commit.Form."+name}}
    @MainActor static func readyItem(_ context:Context,_ owner:CommitWindowController,_ name:String)async throws->NSMenuItem {
        try await wait(owner.window,"Native Commit command \(name) unavailable"){owner.commandMenu?.install();return item(context,name)?.isEnabled==true}
        guard let value=item(context,name) else{throw Failure(description:"Missing native command \(name)")};return value
    }
    @MainActor static func press(_ item:NSMenuItem)throws {guard let action=item.action else{throw Failure(description:"Native Commit action missing")};_ = NSApp.sendAction(action,to:item.target,from:item)}
    @MainActor static func command(_ context:Context,_ owner:CommitWindowController,_ name:String)async throws {try press(try await readyItem(context,owner,name))}
    @MainActor static func field(_ owner:CommitWindowController,_ name:String)->NSTextField? {views(owner.window?.contentView).first{$0.identifier?.rawValue==name} as? NSTextField}
    @MainActor static func keyboard(_ owner:CommitWindowController,_ text:String,_ flags:NSEvent.ModifierFlags) throws->Bool {
        guard let window=owner.window,let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:0) else{throw Failure(description:"Could not construct native Commit key event")}
        return window.performKeyEquivalent(with:event)
    }
    @MainActor static func options(_ context:Context)async throws {
        let owner=try await context.owner(),model=owner.model
        let branch="feature/"+String(repeating:"long-reference-",count:20)+"雪"
        model.newBranch=branch;model.message="Private conditional options draft"
        _=try await readyItem(context,owner,"newBranch")
        try require(try keyboard(owner,"n",[.command,.option]),"Native new-branch key was not routed")
        try await wait(owner.window,"New branch editor did not receive source focus/select-all"){
            guard let value=field(owner,"Commit new branch"),let editor=value.currentEditor() else{return false}
            return model.createBranch && editor.selectedRange==NSRange(location:0,length:branch.utf16.count)
        }
        guard let nativeBranch=field(owner,"Commit new branch") else{throw Failure(description:"Actual branch field missing")}
        try require(nativeBranch.toolTip==branch,"Long new-branch draft tooltip lost literal value")
        let sourceKey=try keyboard(owner,"t",.option)
        try require(!sourceKey && !model.setAuthor,"Option composition was consumed by a source mnemonic inside an editable field")
        let stale=try await readyItem(context,owner,"noAutoSubmodules")
        model.busy=true;model.busy=false;try press(stale)
        try require(!model.doNotAutoselectSubmodules,"Retained option revived across busy generation")
        try await command(context,owner,"noAutoSubmodules")
        try require(model.doNotAutoselectSubmodules && context.preferences.bool(forKey:"Commit.DoNotAutoselectSubmodules"),"Source submodule policy command did not persist")
        let consumed=try await readyItem(context,owner,"noAutoSubmodules")
        try press(consumed);try press(consumed)
        try require(!model.doNotAutoselectSubmodules,"Consumed menu item toggled an option twice")
        let before=model.formReceipt
        model.confirmingQuit=true;model.confirmingQuit=false
        model.setFormOption(.messageOnly,value:true,receipt:before)
        try require(!model.messageOnly,"Retained form binding revived after cancelled Quit")
        try await command(context,owner,"author")
        try await wait(owner.window,"Author option read did not settle"){model.setAuthor && !model.loadingAuthorIdentity}
        try await command(context,owner,"focusAuthor")
        guard let nativeAuthor=field(owner,"Commit author") else{throw Failure(description:"Actual author field missing")}
        try require(nativeAuthor.currentEditor() != nil,"Native author focus command did not select actual field")
        try await command(context,owner,"amend")
        try await wait(owner.window,"Amend metadata did not settle"){model.amend && !model.loadingAmendMessage && !model.loadingAuthorIdentity && !model.busy}
        let comparison=try await readyItem(context,owner,"amendComparison")
        try require(comparison.isEnabled,"Real parent revision did not expose amend comparison")
        try await command(context,owner,"authorDate")
        try await wait(owner.window,"Amend author date did not settle"){model.setAuthorDate && !model.loadingAuthorDate}
        try await command(context,owner,"focusDate")
        let datePicker=views(owner.window?.contentView).first{$0.identifier?.rawValue=="Commit author date"}
        let responder=owner.window?.firstResponder as? NSView
        try require(datePicker != nil && (responder === datePicker || responder?.isDescendant(of:datePicker!)==true),"Author date focus command lost actual date responder")
        try await command(context,owner,"resetDate")
        try require(model.resetAuthorDate && !model.nativeAuthorDateInputAvailable,"Reset did not disable date/time edits")
        _=try await readyItem(context,owner,"resetDate");try await command(context,owner,"resetDate")
        model.author=String(repeating:"Long author identity ",count:16)+"<qa@example.invalid>"
        owner.window?.makeFirstResponder(nil)
        try await wait(owner.window,"Long form values did not settle"){field(owner,"Commit author")?.toolTip==model.author}
        guard let window=owner.window else{throw Failure(description:"Commit window missing")}
        guard let currentBranch=field(owner,"Commit new branch"),let currentAuthor=field(owner,"Commit author") else{throw Failure(description:"Current conditional native fields missing")}
        window.minSize = .zero;window.contentMinSize = .zero
        try require(window.contentMinSize.width>=900 && window.contentMinSize.height>=680,"Hosting erased the Commit content floor")
        window.setContentSize(.init(width:900,height:680));window.contentView?.layoutSubtreeIfNeeded()
        for control in [currentBranch,currentAuthor] {
            guard let content=window.contentView else{throw Failure(description:"Commit content missing")}
            let rect=control.convert(control.bounds,to:content)
            try require(rect.minX>=0 && rect.maxX<=content.bounds.width+1 && rect.minY>=0 && rect.maxY<=content.bounds.height+1,"Long native form field escaped minimum content bounds: \(rect)")
        }
        try await PrimaryParityCapture.save(window,"commit-source-options")
        // Keep the original delegate, then move the actual control to another
        // owned window. No model callback may acquire that replacement owner.
        let delegate=currentBranch.delegate,previous=model.newBranch
        let foreign=NSWindow(contentRect:.init(x:-18000,y:-18000,width:300,height:100),styleMask:[.titled],backing:.buffered,defer:false)
        foreign.alphaValue=0;foreign.isReleasedWhenClosed=false
        currentBranch.removeFromSuperview();foreign.contentView?.addSubview(currentBranch)
        currentBranch.stringValue="retargeted-owner"
        delegate?.controlTextDidChange?(Notification(name:NSControl.textDidChangeNotification,object:currentBranch))
        try require(model.newBranch==previous,"Reparented branch field changed original owner draft")
        foreign.close();owner.close()
        delegate?.controlTextDidChange?(Notification(name:NSControl.textDidChangeNotification,object:currentBranch))
        try require(model.newBranch==previous,"Retired branch delegate changed closed owner")
    }
    @MainActor static func metadata(_ context:Context)async throws {
        let owner=try await context.owner(),model=owner.model,repository=context.repository
        model.author="Retained author draft"
        let author=context.gate();var authorToken:OperationCancellation?
        model.queryCommitAuthor={_,token in
            authorToken=token;let identity=try await repository.replayUserIdentity(cancellation:token)
            await author.hold();return identity.authorName+" <"+identity.authorEmail+">"
        }
        try await command(context,owner,"author")
        try await wait(owner.window,"Actual author read did not enter held completion"){author.entered}
        let count=CommitWindowModel.activeMetadataOperations
        model.confirmingQuit=true;model.confirmingQuit=false
        try require(authorToken?.isCancelled==true && count>0 && CommitWindowModel.activeMetadataOperations==count,"Quit abandoned actual held author ownership")
        author.release();try await wait(owner.window,"Author operation did not drain"){!model.loadingAuthorIdentity}
        try require(model.author=="Retained author draft" && model.error==nil,"Late author success published across Quit epoch")
        let errorGate=context.gate();var errorToken:OperationCancellation?
        model.queryCommitAuthor={_,token in
            errorToken=token;let result:Result<String?,Error>
            do{_=try await repository.run(["rev-parse","--verify","refs/heads/private-missing-author"],cancellation:token);result = .success("unexpected")}
            catch{result = .failure(error)}
            await errorGate.hold();return try result.get()
        }
        try await command(context,owner,"author")
        try await wait(owner.window,"Actual failing author read did not enter hold"){errorGate.entered}
        model.confirmingQuit=true;model.confirmingQuit=false
        try require(errorToken?.isCancelled==true,"Quit did not cancel failing metadata request")
        errorGate.release();try await wait(owner.window,"Failing author operation did not drain"){!model.loadingAuthorIdentity}
        try require(model.error==nil && model.author=="Retained author draft","Late author error or value published across Quit epoch")
        model.queryCommitAuthor=nil
        try await command(context,owner,"amend")
        try await wait(owner.window,"Initial amend snapshot did not settle"){model.amend && !model.loadingAmendMessage && !model.loadingAuthorIdentity && !model.busy}
        let oldDate=Date(timeIntervalSince1970:900_000_000);model.authorDate=oldDate
        let dateGate=context.gate();var dateToken:OperationCancellation?
        model.queryCommitAuthorDate={token in
            dateToken=token
            guard case .commit(let details)=try await repository.singleCommitDetails(revision:"HEAD",cancellation:token) else{throw Failure(description:"HEAD date missing")}
            let value=Date(timeIntervalSince1970:TimeInterval(details.author.time));await dateGate.hold();return value
        }
        try await command(context,owner,"authorDate")
        try await wait(owner.window,"Actual author date read did not enter hold"){dateGate.entered}
        model.confirmingQuit=true;model.confirmingQuit=false
        try require(dateToken?.isCancelled==true,"Quit did not cancel author date")
        dateGate.release();try await wait(owner.window,"Date worker did not drain"){!model.loadingAuthorDate}
        try require(model.authorDate==oldDate && model.error==nil,"Late author date published across Quit epoch")
        model.queryCommitAuthorDate=nil;owner.close()
        let amendOwner=try await context.owner(),amendModel=amendOwner.model
        amendModel.message="Retained pre-amend message"
        let amendGate=context.gate();var amendToken:OperationCancellation?
        amendModel.queryAmendMessage={token in
            amendToken=token
            guard case .commit(let details)=try await repository.singleCommitDetails(revision:"HEAD",cancellation:token) else{throw Failure(description:"HEAD message missing")}
            let value=details.subject+"\n"+details.body;await amendGate.hold();return value
        }
        try await command(context,amendOwner,"amend")
        try await wait(amendOwner.window,"Actual amend message read did not enter hold"){amendGate.entered}
        amendModel.confirmingQuit=true;amendModel.confirmingQuit=false
        try require(amendToken?.isCancelled==true && amendModel.amendMessageReadFailed,"Interrupted amend did not require a fresh read")
        amendGate.release();try await wait(amendOwner.window,"Amend worker did not drain"){!amendModel.loadingAmendMessage}
        try require(amendModel.message=="Retained pre-amend message" && amendModel.error==nil && !amendModel.canCommit,"Late amend result published or permitted stale commit")
        amendModel.queryAmendMessage=nil;amendModel.reload()
        try await wait(amendOwner.window,"F5 did not retry interrupted amend metadata"){!amendModel.busy && !amendModel.loadingAmendMessage && !amendModel.amendMessageReadFailed}
        try require(amendModel.message.contains("second source revision"),"Amend retry did not install actual HEAD message")
        amendOwner.close()
    }
    @MainActor static func run(root:URL,git:URL)async throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repository=GitRepository(root:root,executable:git,diffDetection:.init(),libgit2Configuration:.init(enabled:false))
        _=try await repository.run(["init","-b","main"])
        for(key,value)in [("user.name","Primary Commit QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await repository.run(["config",key,value])}
        let file=root.appendingPathComponent("literal.txt")
        for index in 0..<2 {try Data("\(index)\n".utf8).write(to:file);try await repository.stage(["literal.txt"]);_=try await repository.run(["commit","-m",index==0 ? "first source revision":"second source revision"])}
        try Data("private pending bytes\n".utf8).write(to:file)
        let beforeHead=try await repository.run(["rev-parse","HEAD"]).stdout,beforeIndex=try Data(contentsOf:root.appendingPathComponent(".git/index")),beforeFile=try Data(contentsOf:file)
        let context=Context(repository:repository)
        do {
            try await options(context);try await metadata(context);try await context.clean()
            let afterHead=try await repository.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:root.appendingPathComponent(".git/index")),afterFile=try Data(contentsOf:file)
            try require(afterHead==beforeHead && afterIndex==beforeIndex && afterFile==beforeFile,"Read-only Commit form interactions changed Git or working bytes")
            print("PASS: Commit source option/focus commands, native owner receipts/minimum geometry and held metadata Quit success/error/cancel/retry")
        }catch{try? await context.clean();throw error}
    }
}
