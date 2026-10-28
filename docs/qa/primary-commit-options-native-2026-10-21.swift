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
        var temporaryDirectories:[URL]=[]
        init(repository:GitRepository){
            self.repository=repository;suite="TurtleGit.PrimaryCommitOptions."+UUID().uuidString;preferences=UserDefaults(suiteName:suite)!
            preferences.set(false,forKey:"UseLibgit2");preferences.set(true,forKey:"ShowAppContextMenuIcons")
            preferences.set(true,forKey:"SelectFilesForCommit");preferences.set(true,forKey:"AddBeforeCommit")
            preferences.set(false,forKey:"ConfirmKillProcess");preferences.set(1,forKey:"CommitMergeHint");preferences.set(1,forKey:"HintStagingMode")
        }
        func owner()async throws->CommitWindowController {
            let owner=CommitWindowController(repository:repository,access:nil,defaults:preferences)
            try PrimaryCommitOptionsVerification.require(!owner.model.canChangeFormOption(.staging),"Unloaded preferences exposed a native staging mode action")
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
            for directory in temporaryDirectories {try? FileManager.default.removeItem(at:directory)};temporaryDirectories=[]
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
    /// Compare native menu admission with the shared form-binding setter.
    /// A separately requested checkbox acceptance requires a genuine installed
    /// native/public AX action; an unavailable invisible-host control is not a pass.
    @MainActor static func amendCheckboxAction(_ owner:CommitWindowController)->(()throws->Void)? {
        if let button=views(owner.window?.contentView).compactMap({$0 as? NSButton}).first(where:{$0.isEnabled && ($0.title=="Amend Last Commit" || $0.accessibilityLabel()=="Amend Last Commit")}) {
            return {button.performClick(nil)}
        }
        // SwiftUI may render Toggle without an NSButton. Use the actual public
        // same-process accessibility checkbox action, never a model substitute.
        var seen=Set<ObjectIdentifier>(),remaining=4096
        func property(_ object:NSObject,_ name:String)->Any? {
            let selector=NSSelectorFromString(name);guard object.responds(to:selector) else{return nil}
            return object.perform(selector)?.takeUnretainedValue()
        }
        func find(_ value:Any,_ depth:Int)->(()throws->Void)? {
            guard depth<48,remaining>0,let object=value as? NSObject,seen.insert(ObjectIdentifier(object)).inserted else{return nil}
            remaining -= 1
            let label=property(object,"accessibilityLabel") as? String,title=property(object,"accessibilityTitle") as? String,role=property(object,"accessibilityRole") as? String
            if (label=="Amend Last Commit" || title=="Amend Last Commit"),role==NSAccessibility.Role.checkBox.rawValue {
                if let element=value as? NSAccessibilityProtocol,element.isAccessibilityEnabled() {
                    return {try require(element.accessibilityPerformPress(),"Actual accessible Amend checkbox refused its press")}
                }
                let selector=NSSelectorFromString("accessibilityPerformPress"),enabled=NSSelectorFromString("isAccessibilityEnabled")
                if object.responds(to:selector),object.responds(to:enabled) {
                    typealias BooleanMethod = @convention(c) (AnyObject,Selector)->Bool
                    let can=unsafeBitCast(object.method(for:enabled),to:BooleanMethod.self)
                    if can(object,enabled) {
                        return {let action=unsafeBitCast(object.method(for:selector),to:BooleanMethod.self);try require(action(object,selector),"Actual SwiftUI Amend accessibility press refused")}
                    }
                }
            }
            let children=(property(object,"accessibilityChildren") as? [Any] ?? [])+(property(object,"accessibilityChildrenInNavigationOrder") as? [Any] ?? [])
            for child in children{if let action=find(child,depth+1){return action}}
            return nil
        }
        for view in views(owner.window?.contentView){if let action=find(view,0){return action}}
        return nil
    }
    @MainActor static func nativeAmendRoutes(_ context:Context)async throws {
        let routes=["menu","form-binding"]+(ProcessInfo.processInfo.environment["TURTLEGIT_COMMIT_NATIVE_CHECKBOX_ACCEPTANCE"]=="1" ? ["checkbox"]:[])
        for route in routes {
            let owner=try await context.owner(),model=owner.model,repository=context.repository
            defer{owner.close()}
            let gate=context.gate();var token:OperationCancellation?
            model.message="Native \(route) pre-amend draft"
            model.queryAmendMessage={cancellation in
                token=cancellation
                guard case .commit(let value)=try await repository.singleCommitDetails(revision:"HEAD",cancellation:cancellation) else{throw Failure(description:"Actual Amend HEAD unavailable")}
                await gate.hold();return value.subject+"\n"+value.body
            }
            let previous=model.formReceipt,stale=try await readyItem(context,owner,"noAutoSubmodules")
            let before=model.doNotAutoselectSubmodules,reads=CommitWindowModel.activeMetadataOperations
            if route=="menu" {
                try press(try await readyItem(context,owner,"amend"))
            } else if route=="form-binding" {
                // This is the actual shared setter used by formBinding. It
                // verifies admission/lifecycle, not native checkbox delivery.
                model.setFormOption(.amend,value:true,receipt:model.formReceipt)
            } else {
                do{try await wait(owner.window,"Actual native/accessibility Amend checkbox unavailable"){amendCheckboxAction(owner) != nil}}catch{
                    var seen=Set<ObjectIdentifier>(),count=0
                    func dump(_ value:Any,_ depth:Int){
                        guard depth<30,count<250,let object=value as? NSObject,seen.insert(ObjectIdentifier(object)).inserted else{return};count += 1
                        func property(_ name:String)->Any?{let selector=NSSelectorFromString(name);return object.responds(to:selector) ? object.perform(selector)?.takeUnretainedValue():nil}
                        fputs("COMMIT_AX \(type(of:value)) role=\(property("accessibilityRole") ?? "nil") label=\(property("accessibilityLabel") ?? "nil") title=\(property("accessibilityTitle") ?? "nil")\n",stderr)
                        for child in (property("accessibilityChildren") as? [Any] ?? [])+(property("accessibilityChildrenInNavigationOrder") as? [Any] ?? []){dump(child,depth+1)}
                    }
                    for view in views(owner.window?.contentView){dump(view,0)}
                    throw error
                }
                guard let action=amendCheckboxAction(owner) else{throw Failure(description:"Actual Amend checkbox disappeared")}
                try action()
            }
            try require(model.amend && model.loadingAmendMessage && CommitWindowModel.activeMetadataOperations==reads+1,
                        "Native \(route) Amend returned before admitting its metadata worker")
            let accepted=model.formReceipt,acceptedReads=CommitWindowModel.activeMetadataOperations
            model.formOptionViewChanged(.amend);model.formOptionViewChanged(.amend)
            try require(model.formReceipt==accepted && CommitWindowModel.activeMetadataOperations==acceptedReads,
                        "Native \(route) duplicate observer restarted accepted Amend")
            try press(stale)
            model.setFormOption(.noAutoSubmodules,value:!before,receipt:previous)
            try require(model.doNotAutoselectSubmodules==before,"Native \(route) metadata admitted a retired menu/binding receipt")
            try await wait(owner.window,"Native Amend actual metadata did not enter owned hold"){gate.entered}
            try require(token?.isCancelled==false && model.loadingAmendMessage,"Native Amend did not retain actual worker ownership")
            gate.release()
            try await wait(owner.window,"Native Amend route did not settle actual metadata and comparison"){!model.loadingAmendMessage && !model.loadingAuthorIdentity && !model.loadingAuthorDate && !model.busy}
            try require(model.error==nil && model.message.contains("second source revision"),"Native \(route) Amend failed to install actual HEAD metadata")
            let settled=model.formReceipt,settledReads=CommitWindowModel.activeMetadataOperations
            model.formOptionViewChanged(.amend);model.formOptionViewChanged(.amend)
            try require(model.formReceipt==settled && CommitWindowModel.activeMetadataOperations==settledReads && !model.busy,
                        "Native \(route) settled delayed callback retired the form")
            owner.close()
            try await wait(nil,"Native Amend route owner did not drain"){CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activeReloads==0}
        }
    }
    @MainActor static func unchangedOptionsAndSignOff(_ context:Context)async throws {
        let owner=try await context.owner(),model=owner.model
        defer{owner.close()}
        context.preferences.set(false,forKey:"RememberFileListPosition")
        defer{context.preferences.removeObject(forKey:"RememberFileListPosition")}
        model.selection=["literal.txt"]
        let position=model.selection,visible=model.showUnversioned
        let defaults=context.preferences.persistentDomain(forName:context.suite) as NSDictionary?
        model.setFormOption(.unversioned,value:visible,receipt:model.formReceipt)
        try require(model.selection==position,"Unchanged visible-files option reset user's selected row")
        try require((context.preferences.persistentDomain(forName:context.suite) as NSDictionary?)==defaults,"Unchanged option rewrote private preferences")
        let stale=model.formReceipt;model.confirmingQuit=true;model.confirmingQuit=false
        var queries=0
        model.querySignOff={token in queries += 1;return try await context.repository.commitSignOffLine(cancellation:token)}
        let draft="Private receipt-owned sign-off draft";model.message=draft
        model.addSignOff(receipt:stale)
        try require(queries==0 && !model.busy && model.message==draft,"Retired sign-off binding started a Git identity read")
        guard let window=owner.window else{throw Failure(description:"Actual Sign-off owner missing")}
        let sheet=NSWindow(contentRect:.init(x:-18000,y:-18000,width:220,height:90),styleMask:[.titled],backing:.buffered,defer:true)
        sheet.isReleasedWhenClosed=false;sheet.alphaValue=0
        defer{if sheet.sheetParent != nil{window.endSheet(sheet)};sheet.orderOut(nil);sheet.close()}
        window.beginSheet(sheet,completionHandler:nil)
        try require(window.attachedSheet === sheet,"Private sign-off modal ownership missing")
        model.addSignOff(receipt:model.formReceipt)
        try require(queries==0 && !model.busy && model.message==draft,"Sign-off bypassed its actual owned modal sheet")
        window.endSheet(sheet);sheet.orderOut(nil);sheet.close()
        try await wait(window,"Private sign-off sheet did not drain"){window.attachedSheet==nil}
        model.addSignOff(receipt:model.formReceipt)
        try require(model.busy,"Accepted sign-off did not synchronously retain operation ownership")
        try await wait(window,"Accepted actual signing identity did not settle"){!model.busy && CommitWindowModel.activeFileOperations==0}
        try require(queries==1 && model.error==nil && model.message.contains("Signed-off-by: Primary Commit QA <qa@example.invalid>"),"Current sign-off receipt did not append actual Git identity exactly once")
    }
    @MainActor static func unchangedSubmodulePolicy(_ context:Context)async throws {
        let saved=context.preferences.object(forKey:"Commit.DoNotAutoselectSubmodules")
        defer{if let saved{context.preferences.set(saved,forKey:"Commit.DoNotAutoselectSubmodules")}else{context.preferences.removeObject(forKey:"Commit.DoNotAutoselectSubmodules")}}
        let root=context.repository.root.appendingPathComponent(".git/manual-gitlink-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);context.temporaryDirectories.append(root)
        let repository=GitRepository(root:root,executable:context.repository.executable,libgit2Configuration:.init(enabled:false))
        _=try await repository.run(["init","--template=","-b","main"])
        for(key,value)in[("user.name","Gitlink option QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await repository.run(["config",key,value])}
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repository.stage(["file"]);_=try await repository.commit(message:"base")
        let base=try await repository.rebaseCommit("HEAD").hash
        let modules="""
        [submodule "module"]
            path = module
            url = https://example.invalid/module.git
        """
        try Data(modules.utf8).write(to:root.appendingPathComponent(".gitmodules"))
        try await repository.stage([".gitmodules"]);_=try await repository.run(["update-index","--add","--cacheinfo","160000",base,"module"]);_=try await repository.commit(message:"actual gitlink")
        let moduleRoot=root.appendingPathComponent("module",isDirectory:true)
        try FileManager.default.createDirectory(at:moduleRoot,withIntermediateDirectories:false)
        let module=GitRepository(root:moduleRoot,executable:context.repository.executable,libgit2Configuration:.init(enabled:false))
        _=try await module.run(["init","--template=","-b","main"])
        for(key,value)in[("user.name","Actual submodule QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await module.run(["config",key,value])}
        try Data("actual nested checkout\n".utf8).write(to:moduleRoot.appendingPathComponent("nested"));try await module.stage(["nested"]);_=try await module.commit(message:"distinct actual module HEAD")
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let owner=CommitWindowController(repository:repository,access:nil,defaults:context.preferences),model=owner.model;context.owners.append(owner)
        defer{owner.close()};owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-18000,y:-18000));owner.showWindow(nil);model.reload(paths:["."])
        try await wait(owner.window,"Actual changed gitlink did not settle"){!model.busy && model.changelistsLoaded && model.submodules.contains("module") && model.visibleEntries.contains{$0.path=="module"}}
        model.setFormOption(.noAutoSubmodules,value:true,receipt:model.formReceipt)
        guard let row=model.visibleEntries.first(where:{$0.path=="module"})else{throw Failure(description:"Actual gitlink row missing")}
        model.setFileChecked(row,files:model.visibleEntries,highlighted:[row.id],checked:true,receipt:model.fileCheckReceipt)
        try require(model.checked.contains("module"),"Actual manual gitlink check was refused")
        let before=model.formReceipt,checks=model.checked
        model.setFormOption(.noAutoSubmodules,value:true,receipt:before)
        try require(model.checked==checks && model.formReceipt==before && context.preferences.bool(forKey:"Commit.DoNotAutoselectSubmodules"),"Unchanged submodule policy erased manual gitlink choice or retired form")
        try require((try Data(contentsOf:root.appendingPathComponent(".git/index")))==index,"Checkbox policy changed actual gitlink index")
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
        let authorOption=try await readyItem(context,owner,"author")
        try press(authorOption)
        let authorOptionReceipt=model.formReceipt
        try require(model.loadingAuthorIdentity,"Author action returned before starting its metadata transition")
        try await wait(owner.window,"Author option read did not settle"){model.setAuthor && !model.loadingAuthorIdentity}
        try require(model.formReceipt==authorOptionReceipt,"Delayed author view callback retired the accepted option form")
        try await command(context,owner,"focusAuthor")
        guard let nativeAuthor=field(owner,"Commit author") else{throw Failure(description:"Actual author field missing")}
        try await wait(owner.window,"Native author focus command did not select actual field") {
            nativeAuthor.currentEditor()?.selectedRange==NSRange(location:0,length:nativeAuthor.stringValue.utf16.count)
        }
        // Model identity is ready while the installed native field still has
        // an older value. Selecting that value would be undone by its update.
        owner.window?.makeFirstResponder(nil)
        nativeAuthor.stringValue="Pending native identity update"
        try require(owner.focusFormField("Commit author") && owner.formFocusPending,"Stale native value was focused synchronously")
        try await Task.sleep(nanoseconds:30_000_000)
        try require(owner.formFocusPending && nativeAuthor.currentEditor()==nil,"Focus selected the stale native author value")
        nativeAuthor.stringValue=model.author
        try await wait(owner.window,"Current native author value did not fulfill accepted focus") {
            !owner.formFocusPending && nativeAuthor.currentEditor()?.selectedRange==NSRange(location:0,length:model.author.utf16.count)
        }
        owner.window?.makeFirstResponder(nil)
        nativeAuthor.stringValue="Superseded native identity update"
        try require(owner.focusFormField("Commit author"),"Superseded author focus was not accepted")
        try require(owner.focusFormField("Commit new branch"),"New branch focus did not supersede pending author focus")
        try await wait(owner.window,"Superseding branch focus did not settle") {
            !owner.formFocusPending && nativeBranch.currentEditor()?.selectedRange==NSRange(location:0,length:model.newBranch.utf16.count)
        }
        nativeAuthor.stringValue=model.author
        try await Task.sleep(nanoseconds:30_000_000)
        try require(nativeAuthor.currentEditor()==nil && nativeBranch.currentEditor() != nil,"Superseded author focus stole later branch editing")
        // The same shared NSTextView can move to another control without a
        // responder identity change. That still revokes the earlier request.
        guard let sharedEditor=nativeBranch.currentEditor() else{throw Failure(description:"Branch field editor missing")}
        let foreignField=NSTextField(string:"Other editable control")
        foreignField.frame=NSRect(x:10,y:10,width:180,height:22)
        owner.window?.contentView?.addSubview(foreignField)
        defer{foreignField.removeFromSuperview()}
        nativeAuthor.isEditable=false
        try require(owner.focusFormField("Commit author") && owner.formFocusPending,"Shared-editor revocation request was not retained")
        try require(owner.window?.makeFirstResponder(foreignField)==true,"Other control could not receive field editor")
        foreignField.selectText(nil)
        try require(foreignField.currentEditor() === sharedEditor,"Fixture did not exercise shared field-editor reuse")
        try await wait(owner.window,"Changing the shared editor's control did not revoke pending focus"){!owner.formFocusPending}
        nativeAuthor.isEditable=true
        try require(foreignField.currentEditor() === sharedEditor && owner.window?.firstResponder === sharedEditor,"Pending author focus stole another control's shared editor")
        owner.window?.makeFirstResponder(nil);foreignField.removeFromSuperview()
        // Reproduce model-ready/native-not-yet-editable delivery with the real
        // installed field. Accepted focus must complete when that view is ready.
        owner.window?.makeFirstResponder(nil);nativeAuthor.isEditable=false
        try require(owner.focusFormField("Commit author") && owner.formFocusPending,"Native readiness request was not retained")
        nativeAuthor.isEditable=true
        try await wait(owner.window,"Accepted author focus did not complete on native readiness") {
            !owner.formFocusPending && nativeAuthor.currentEditor()?.selectedRange==NSRange(location:0,length:nativeAuthor.stringValue.utf16.count)
        }
        owner.window?.makeFirstResponder(nil);nativeAuthor.isEditable=false
        try require(owner.focusFormField("Commit author") && owner.formFocusPending,"Responder-change test did not defer focus")
        guard let messageEditor=owner.messageEditor(),owner.window?.makeFirstResponder(messageEditor)==true else{throw Failure(description:"Actual message responder unavailable")}
        try await wait(owner.window,"Another actual responder did not revoke pending focus"){!owner.formFocusPending}
        try require(owner.window?.firstResponder === messageEditor,"Deferred field request stole later message focus")
        owner.window?.makeFirstResponder(nil);nativeAuthor.isEditable=false
        try require(owner.focusFormField("Commit author") && owner.formFocusPending,"Revocation test did not defer actual native focus")
        model.confirmingQuit=true
        try await wait(owner.window,"Quit did not retire deferred form focus"){!owner.formFocusPending}
        model.confirmingQuit=false;nativeAuthor.isEditable=true
        try require(nativeAuthor.currentEditor()==nil,"Cancelled Quit revived an old focus command")
        owner.window?.makeFirstResponder(nil);nativeAuthor.isEditable=false
        try require(owner.focusFormField("Commit author") && owner.formFocusPending,"Form-change test did not defer focus")
        model.setFormOption(.author,value:false,receipt:model.formReceipt)
        try await wait(owner.window,"Form change did not revoke accepted focus"){!owner.formFocusPending}
        try require(nativeAuthor.currentEditor()==nil,"Changed author option accepted stale focus")
        try await command(context,owner,"author")
        try await wait(owner.window,"Author option did not restore native editing"){model.setAuthor && !model.loadingAuthorIdentity && nativeAuthor.isEditable}
        try await command(context,owner,"amend")
        try await wait(owner.window,"Amend metadata did not settle"){model.amend && !model.loadingAmendMessage && !model.loadingAuthorIdentity && !model.busy}
        // Different SDKs can replay delayed observers after metadata and busy
        // transitions have already settled. Every option's current identity
        // stays acknowledged; another view callback must not restart it.
        let settledAmendReceipt=model.formReceipt
        let settledMetadata=CommitWindowModel.activeMetadataOperations
        for option in [CommitWindowModel.FormOption.amend,.amendComparison,.author] {
            model.formOptionViewChanged(option);model.formOptionViewChanged(option)
            try require(model.formReceipt==settledAmendReceipt && CommitWindowModel.activeMetadataOperations==settledMetadata && !model.busy,"Duplicate settled option observer \(option) restarted metadata or retired the form (receiptChanged=\(model.formReceipt != settledAmendReceipt), metadata=\(CommitWindowModel.activeMetadataOperations)/\(settledMetadata), busy=\(model.busy))")
        }
        try require(model.formReceipt==settledAmendReceipt && CommitWindowModel.activeMetadataOperations==settledMetadata && !model.busy,"Duplicate settled option observers restarted metadata or retired the form")
        let comparison=try await readyItem(context,owner,"amendComparison")
        try require(comparison.isEnabled,"Real parent revision did not expose amend comparison")
        let dateOption=try await readyItem(context,owner,"authorDate")
        try press(dateOption)
        let dateOptionReceipt=model.formReceipt
        try require(model.loadingAuthorDate,"Date action returned before starting its metadata transition")
        let acceptedDateReads=CommitWindowModel.activeMetadataOperations
        model.formOptionViewChanged(.authorDate);model.formOptionViewChanged(.authorDate)
        try require(model.formReceipt==dateOptionReceipt && CommitWindowModel.activeMetadataOperations==acceptedDateReads,"Duplicate pending date observers restarted accepted metadata")
        try await wait(owner.window,"Amend author date did not settle"){model.setAuthorDate && !model.loadingAuthorDate}
        try require(model.formReceipt==dateOptionReceipt,"Delayed date view callback retired the accepted option form")
        try await command(context,owner,"focusDate")
        try await wait(owner.window,"Author date focus command lost actual date responder") {
            guard let picker=views(owner.window?.contentView).first(where:{$0.identifier?.rawValue=="Commit author date"}),let responder=owner.window?.firstResponder as? NSView else{return false}
            return responder===picker || responder.isDescendant(of:picker)
        }
        try await command(context,owner,"focusTime")
        try await wait(owner.window,"Author time focus command lost actual time responder") {
            guard let picker=views(owner.window?.contentView).first(where:{$0.identifier?.rawValue=="Commit author time"}),let responder=owner.window?.firstResponder as? NSView else{return false}
            return responder===picker || responder.isDescendant(of:picker)
        }
        try await command(context,owner,"resetDate")
        try require(model.resetAuthorDate && !model.nativeAuthorDateInputAvailable,"Reset did not disable date/time edits")
        _=try await readyItem(context,owner,"resetDate");try await command(context,owner,"resetDate")
        // The final bool may equal an already handled value after SwiftUI
        // coalesces an off/on pair. Its actual transition identity is new and
        // must be serviced once, then remain stable for duplicate observers.
        model.setAuthorDate=false;model.setAuthorDate=true
        model.formOptionViewChanged(.authorDate)
        let coalescedDateReceipt=model.formReceipt,coalescedReads=CommitWindowModel.activeMetadataOperations
        try require(model.loadingAuthorDate,"Coalesced date option changes lost the new metadata request")
        model.formOptionViewChanged(.authorDate);model.formOptionViewChanged(.authorDate)
        try require(model.formReceipt==coalescedDateReceipt && CommitWindowModel.activeMetadataOperations==coalescedReads,"Coalesced option observers restarted current metadata")
        try await wait(owner.window,"Coalesced author date metadata did not settle"){!model.loadingAuthorDate}
        try require(model.formReceipt==coalescedDateReceipt,"Delayed coalesced date callback retired the new form")
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
        foreign.close()
        owner.window?.makeFirstResponder(nil);currentAuthor.isEditable=false
        try require(owner.focusFormField("Commit author") && owner.formFocusPending,"Closing-owner test did not defer focus")
        owner.close()
        try require(!owner.formFocusPending,"Closed Commit owner retained a focus request")
        delegate?.controlTextDidChange?(Notification(name:NSControl.textDidChangeNotification,object:currentBranch))
        try require(model.newBranch==previous,"Retired branch delegate changed closed owner")
    }
    /// Flush already admitted main-queue focus deliveries without changing
    /// native undo event grouping or posting desktop input.
    @MainActor static func focusDeliveryTurn()async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {continuation.resume()}
        }
    }
    @MainActor static func focusIntents(_ context:Context)async throws {
        let owner=try await context.owner(),model=owner.model
        defer {owner.close()}
        model.message="Private focus intent draft 雪"
        try await command(context,owner,"author")
        try await wait(owner.window,"Focus-intent author metadata did not settle"){
            model.setAuthor && !model.loadingAuthorIdentity && field(owner,"Commit author")?.isEditable==true
        }
        guard let window=owner.window,let author=field(owner,"Commit author"),
              let message=owner.messageEditor(),let files=owner.fileTable() else {
            throw Failure(description:"Actual focus-intent native controls missing")
        }
        // This coordinator executes the same production delivery code against
        // the actual installed editor, allowing its queued work to be admitted
        // before the next explicit target without timing a SwiftUI update.
        let coordinator=CommitMessageEditor.Coordinator(model)
        defer {coordinator.invalidate()}

        window.makeFirstResponder(nil);author.isEditable=false
        try require(owner.focusFormField("Commit author") && owner.formFocusPending,
                    "Deferred author focus intent was not admitted")
        let authorIntent=model.focusIntent
        try require(model.acceptsFocusIntent(authorIntent),"New author focus receipt was not current")
        model.focusMessage()
        let messageIntent=model.focusIntent
        try require(messageIntent != authorIntent && !model.acceptsFocusIntent(authorIntent),
                    "Explicit message focus did not supersede the deferred author receipt")
        coordinator.updateFocus(message);author.isEditable=true
        try await wait(window,"Explicit message focus did not replace deferred author focus"){
            !owner.formFocusPending && window.firstResponder === message
        }
        await focusDeliveryTurn()
        try require(window.firstResponder === message && author.currentEditor()==nil,
                    "Retired author intent stole explicit message focus")

        window.makeFirstResponder(nil)
        model.focusMessage();let queuedMessage=model.focusIntent
        coordinator.updateFocus(message)
        try require(owner.focusFormField("Commit author"),"Author target did not supersede queued message delivery")
        try require(!model.acceptsFocusIntent(queuedMessage),"Queued message receipt remained current after explicit author focus")
        try await wait(window,"Explicit author focus lost to an older message delivery"){
            !owner.formFocusPending && author.currentEditor()?.selectedRange==NSRange(location:0,length:model.author.utf16.count)
        }
        await focusDeliveryTurn()
        try require(author.currentEditor() != nil && window.firstResponder !== message,
                    "Queued message callback stole the newer author target")

        window.makeFirstResponder(nil)
        model.focusMessage();let queuedBeforeFiles=model.focusIntent
        coordinator.updateFocus(message)
        try require(owner.focusFileList(),"Actual file-list focus target was unavailable")
        try require(!model.acceptsFocusIntent(queuedBeforeFiles),"File-list target retained the old message receipt")
        await focusDeliveryTurn();await focusDeliveryTurn()
        try require(window.firstResponder === files,
                    "Queued message delivery stole explicit native file-list focus")

        // Retiring a coordinator must leave its already queued callback inert
        // even while the same editor/window remains valid for another target.
        window.makeFirstResponder(nil)
        model.focusMessage();coordinator.updateFocus(message);coordinator.invalidate()
        try require(owner.focusFormField("Commit author"),"Retired-coordinator target did not admit author focus")
        try await wait(window,"Retired coordinator displaced the current author target"){
            !owner.formFocusPending && author.currentEditor() != nil
        }
        await focusDeliveryTurn()
        try require(window.firstResponder !== message && author.currentEditor() != nil,
                    "Invalidated message coordinator revived queued focus")
        // An owned sheet temporarily receives key status without representing
        // a different focus target in the parent. An external resignation does.
        let sheetIntent=model.supersedeFocusIntent()
        do {
            let sheet=NSWindow(contentRect:NSRect(x:-18000,y:-18000,width:240,height:100),
                               styleMask:[.titled],backing:.buffered,defer:true)
            sheet.isReleasedWhenClosed=false;sheet.alphaValue=0
            defer {
                if sheet.sheetParent != nil || window.attachedSheet === sheet {window.endSheet(sheet)}
                sheet.orderOut(nil);sheet.close()
            }
            window.beginSheet(sheet,completionHandler:nil)
            try require(window.attachedSheet === sheet,"Private owned sheet did not attach")
            owner.windowDidResignKey(Notification(name:NSWindow.didResignKeyNotification,object:window))
            try require(model.acceptsFocusIntent(sheetIntent),
                        "Owned sheet key transfer revoked its parent's return-focus receipt")
        }
        try await wait(window,"Private focus sheet did not retire"){window.attachedSheet==nil}
        owner.windowDidResignKey(Notification(name:NSWindow.didResignKeyNotification,object:window))
        try require(!model.acceptsFocusIntent(sheetIntent),
                    "External key resignation retained an old parent focus receipt")
        let retiredIntent=model.focusIntent
        owner.close()
        try require(!model.acceptsFocusIntent(retiredIntent),"Closed Commit owner retained a usable focus receipt")
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
    @MainActor static func initialAndNormalizedTransitions(_ context:Context)async throws {
        // This independent one-commit repository forces the source's root-HEAD
        // comparison normalization. It does not alter the main fixture's HEAD,
        // index or pending draft; cleanup follows actual worker drainage.
        let root=context.repository.root.appendingPathComponent(".git/form-normalization-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);context.temporaryDirectories.append(root)
        let repository=GitRepository(root:root,executable:context.repository.executable,diffDetection:.init(),libgit2Configuration:.init(enabled:false))
        _=try await repository.run(["init","-b","main"])
        for(key,value)in [("user.name","Form identity QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await repository.run(["config",key,value])}
        try Data("root source\n".utf8).write(to:root.appendingPathComponent("literal.txt"));try await repository.stage(["literal.txt"]);_=try await repository.run(["commit","-m","root source revision"])
        try Data("pending root draft\n".utf8).write(to:root.appendingPathComponent("literal.txt"))
        let owner=CommitWindowController(repository:repository,access:nil,defaults:context.preferences),model=owner.model
        context.owners.append(owner);owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-18000,y:-18000));owner.showWindow(nil)
        model.reload(paths:["literal.txt"])
        try await wait(owner.window,"Root comparison fixture did not load"){!model.busy && model.changelistsLoaded && owner.commandsAvailable}
        model.message="Independent root draft"
        let initial=model.formReceipt,initialReads=CommitWindowModel.activeMetadataOperations
        for option in [CommitWindowModel.FormOption.amend,.amendComparison,.author,.authorDate] {
            model.formOptionViewChanged(option);model.formOptionViewChanged(option)
            try require(model.formReceipt==initial && CommitWindowModel.activeMetadataOperations==initialReads && !model.busy && model.message=="Independent root draft","Initial unchanged observer \(option) invented a metadata transition")
        }
        model.setFormOption(.amend,value:true,receipt:model.formReceipt)
        try await wait(owner.window,"Root Amend normalization did not settle"){model.amend && model.amendDiffToLastCommit && !model.hasParent && !model.busy && !model.loadingAmendMessage && !model.loadingAuthorIdentity && !model.loadingAuthorDate}
        let normalized=model.formReceipt,normalizedReads=CommitWindowModel.activeMetadataOperations
        for option in [CommitWindowModel.FormOption.amend,.amendComparison,.author,.authorDate] {
            model.formOptionViewChanged(option);model.formOptionViewChanged(option)
            try require(model.formReceipt==normalized && CommitWindowModel.activeMetadataOperations==normalizedReads && !model.busy,"Snapshot-owned root normalization \(option) started a second metadata transition")
        }
        owner.close()
        try await wait(nil,"Root normalization owner did not drain"){!model.messageFocusAvailable && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activeReloads==0}
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
            try await initialAndNormalizedTransitions(context);try await nativeAmendRoutes(context);try await unchangedOptionsAndSignOff(context);try await unchangedSubmodulePolicy(context);try await options(context);try await focusIntents(context);try await metadata(context);try await context.clean()
            let afterHead=try await repository.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:root.appendingPathComponent(".git/index")),afterFile=try Data(contentsOf:file)
            try require(afterHead==beforeHead && afterIndex==beforeIndex && afterFile==beforeFile,"Read-only Commit form interactions changed Git or working bytes")
            print("PASS: Commit source option/focus commands, superseding native focus intents, native owner receipts/minimum geometry and held metadata Quit success/error/cancel/retry")
        }catch{try? await context.clean();throw error}
    }
}
