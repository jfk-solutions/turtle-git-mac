import AppKit
import Darwin
import TurtleGitCore

@main struct RefLogReferenceIdentityVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ message:String)throws {if !condition{throw Failure(description:message)}}
    static func exact(_ left:String?,_ right:String?)->Bool {guard let left else{return right==nil};return GitReferenceName.equal(left,right)}
    static func same(_ left:[String],_ right:[String])->Bool {left.count==right.count && zip(left,right).allSatisfy{exact($0.0,$0.1)}}
    @MainActor static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    @MainActor static func wait(_ ready:()->Bool)async throws {
        for _ in 0..<1500 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"RefLog exact-reference receiver timed out")
    }
    @MainActor static func settle(_ owner:ReferenceLogWindowController)async throws {
        try await wait {owner.window?.contentView?.layoutSubtreeIfNeeded();return !owner.model.busy && !owner.model.hasPendingWork && views(owner.window?.contentView).contains{$0 is ReferenceLogTableView}}
        await Task.yield();owner.window?.contentView?.layoutSubtreeIfNeeded()
        if let table=views(owner.window?.contentView).compactMap({$0 as? ReferenceLogTableView}).first {table.owner?.update(model:owner.model,dates:.load(defaults:owner.model.preferences))}
    }
    @MainActor static func dispatch(_ item:NSMenuItem)throws {guard let action=item.action else{throw Failure(description:"Native item has no action")};try require(NSApp.sendAction(action,to:item.target,from:item),"Native menu action was not dispatched")}
    @MainActor static func main()async throws {
        setbuf(stdout,nil)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),mode=CommandLine.arguments[3]
        let repository=GitRepository(root:root,executable:git),suite="TurtleGit.RefLogReferenceIdentity."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"EnableGravatar");defer{prefs.removePersistentDomain(forName:suite)}
        _=try await repository.run(["init","--template=","-b","main"])
        for (key,value) in [("user.name","Ref identity QA"),("user.email","identity@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_=try await repository.run(["config",key,value])}
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repository.stage(["file"]);_=try await repository.commit(message:"base")
        let head=try await repository.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        let composed="refs/heads/café",decomposed="refs/heads/cafe\u{301}",tagA="refs/tags/résumé",tagB="refs/tags/re\u{301}sume\u{301}"
        // Pack between spellings: APFS may normalize loose filenames, packed ref
        // identity still supports distinct UTF-8 names. Reflog selectors must use
        // the requested raw name even when the volume aliases their log files.
        for reference in [composed,decomposed,tagA,tagB] {
            _=try await repository.run(["update-ref","--create-reflog",reference,head])
            _=try await repository.run(["pack-refs","--all"])
        }
        _=try await repository.run(["symbolic-ref","HEAD",composed])
        let beforeIndex=try Data(contentsOf:root.appendingPathComponent(".git/index")),beforeFile=try Data(contentsOf:root.appendingPathComponent("file"))
        var owners:[ReferenceLogWindowController]=[]
        defer{for owner in owners{owner.model.invalidate();owner.window?.orderOut(nil);owner.close()}}
        func owner(_ reference:String="HEAD")->ReferenceLogWindowController {
            let result=ReferenceLogWindowController(repository:repository,access:nil,reference:reference,preferences:prefs);owners.append(result)
            result.window?.setFrameOrigin(NSPoint(x:-30000,y:-30000));result.window?.alphaValue=0;result.window?.orderFront(nil);return result
        }
        func exists(_ name:String)async throws->Bool {try await repository.run(["show-ref","--verify","--quiet","--",name],successfulExitCodes:0...1).exitCode==0}
        let controller=owner(),model=controller.model;try await settle(controller)
        let native=try {()->ReferenceLogTableView in guard let value=views(controller.window?.contentView).compactMap({$0 as? ReferenceLogTableView}).first else{throw Failure(description:"Actual RefLog table missing")};return value}()
        func selectRow()throws {try require(!model.entries.isEmpty,"RefLog current HEAD has no entries");native.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)}
        if mode == "picker" {
            guard let popup=views(controller.window?.contentView).compactMap({$0 as? ReferenceLogReferencePopup}).first else{throw Failure(description:"Shipping exact-reference popup missing")}
            try await wait{same(popup.itemTitles,model.names) && (popup.target as? ReferenceLogReferencePickerTarget).map{model.acceptsReferencePicker($0.context) && !$0.retired} == true}
            try require(same(popup.itemTitles,model.names),"Native popup discarded/reordered canonically equivalent reference names")
            for name in [composed,decomposed,tagA,tagB] {
                guard let index=popup.itemTitles.firstIndex(where:{exact($0,name)}),let action=popup.action else{throw Failure(description:"Native exact popup item/target missing: "+name)}
                let acceptedTarget=popup.target
                popup.selectItem(at:index);try require(NSApp.sendAction(action,to:acceptedTarget,from:popup),"Popup native action failed")
                try await settle(controller)
                try require(exact(model.reference,name) && exact(popup.titleOfSelectedItem,name),"Native selection collapsed UTF-8 reference identity")
                try require(model.entries.allSatisfy{$0.selector.utf8.starts(with:(name+"@{").utf8)},"Raw named reflog selector was replaced with another spelling")
                popup.selectItem(at:0);_=NSApp.sendAction(action,to:acceptedTarget,from:popup)
                try require(exact(model.reference,name),"Retired accepted popup target dispatched again")
                try await wait{(popup.target as? ReferenceLogReferencePickerTarget).map{model.acceptsReferencePicker($0.context) && !$0.retired} == true}
            }
            let selected=model.reference,oldNames=model.names,action=popup.action!,target=popup.target
            popup.isEnabled=false;popup.selectItem(at:0);_=NSApp.sendAction(action,to:target,from:popup)
            try require(exact(model.reference,selected),"Disabled popup dispatched a reference read")
            popup.isEnabled=true
            let sheet=NSWindow(contentRect:.zero,styleMask:[],backing:.buffered,defer:false)
            sheet.isReleasedWhenClosed=false
            sheet.alphaValue=0;sheet.setFrameOrigin(NSPoint(x:-30000,y:-30000));controller.window!.beginSheet(sheet,completionHandler:{_ in})
            popup.selectItem(at:0);_=NSApp.sendAction(action,to:target,from:popup)
            try require(exact(model.reference,selected),"Popup dispatched while its owner had an attached sheet")
            controller.window!.endSheet(sheet);sheet.orderOut(nil);sheet.close()
            model.names=Array(oldNames.reversed());popup.selectItem(at:0);_=NSApp.sendAction(action,to:target,from:popup)
            try require(exact(model.reference,selected),"Stale popup names accepted old item index")
            model.names=oldNames;model.reload();try await settle(controller)
            let reference=model.reference
            let temporaryWindow=NSWindow(contentRect:.zero,styleMask:[],backing:.buffered,defer:false)
            temporaryWindow.isReleasedWhenClosed=false
            temporaryWindow.setFrameOrigin(NSPoint(x:-30000,y:-30000));defer{temporaryWindow.orderOut(nil);temporaryWindow.close()}
            let detachedAction=popup.action!,detachedTarget=popup.target
            popup.removeFromSuperview();temporaryWindow.contentView?.addSubview(popup);popup.selectItem(at:0);_=NSApp.sendAction(detachedAction,to:detachedTarget,from:popup)
            try require(exact(model.reference,reference),"Reparented popup dispatched against another native owner")
        } else if mode == "menus" {
            try selectRow();let ids=model.selection,candidates=model.referenceDeletionCandidates(ids)
            for name in [decomposed,tagA,tagB] {try require(candidates.contains{exact($0,name)},"Exact sibling/tag candidate lost: "+name)}
            try require(!candidates.contains{exact($0,composed)},"Current branch was offered for deletion")
            let switchNames=model.switchBranches(ids)
            try require(switchNames.contains{exact($0,decomposed)} && !switchNames.contains{exact($0,composed)},"Switch candidates collapsed sibling/current branch identity")
            var switched:[String]=[];model.onSwitchBranch={switched.append($0)}
            let switchMenu=native.owner!.menu(),switchChild=switchMenu.item(withTitle:"Switch branch")!.submenu!
            try dispatch(switchChild.items.first{exact($0.title,String(decomposed.dropFirst(11)))}!)
            try require(same(switched,[decomposed]),"Native Switch menu dispatched another branch spelling")
            let board=NSPasteboard(name:NSPasteboard.Name("TurtleGit.RefLogReferenceIdentity."+UUID().uuidString));defer{board.releaseGlobally()}
            let menu=native.owner!.menu(pasteboard:board),child=menu.item(withTitle:"Delete branch/tag")!.submenu!
            let commands=child.items.filter{$0.action != nil}
            try require(same(commands.dropLast().map(\.title),candidates) && commands.last?.title=="All","Native deletion submenu merged/reordered distinct refs")
            try require(commands.allSatisfy{$0.image != nil},"Source deletion icons missing")
            var prompts:[String]=[],changes=0
            model.onChanged={_ in changes += 1};model.confirmReferenceDeletion={request in prompts.append(request.name);return .delete}
            try dispatch(commands.last!);try await settle(controller)
            try require(same(prompts,candidates),"All did not dispatch every exact named-reference candidate once")
            for name in candidates {try require(!(try await exists(name)),"All retained exact deletion candidate: "+name)}
            try require(try await exists(composed),"Deleting equivalent sibling removed current branch")
            try require(changes==1,"All failed to publish one accepted mutation refresh")
        } else if mode == "lifetime" {
            model.selectReference(composed);try await settle(controller);try selectRow()
            var prompts=0,held:CheckedContinuation<HistoryReferenceDeleteChoice,Never>?
            model.confirmReferenceDeletion={_ in prompts += 1;return await withCheckedContinuation{held=$0}}
            let menu=native.owner!.menu(),child=menu.item(withTitle:"Delete branch/tag")!.submenu!,item=child.items.first{exact($0.title,decomposed)}!
            model.reference=decomposed // same Unicode rendering, different identity
            try dispatch(item);try await Task.sleep(nanoseconds:30_000_000)
            try require(prompts==0,"Captured menu accepted a different byte-identity reference")
            model.reference="HEAD";model.reload();try await settle(controller);try selectRow()
            let live=native.owner!.menu(),liveItem=live.item(withTitle:"Delete branch/tag")!.submenu!.items.first{exact($0.title,decomposed)}!
            model.busy=true;try dispatch(liveItem);model.busy=false
            try require(prompts==0,"Disabled/busy native menu dispatched mutation")
            model.deleteNamedReferences([composed,decomposed],ids:model.selection)
            try await Task.sleep(nanoseconds:30_000_000);try require(prompts==0,"Invalid exact-name batch admitted the current branch")
            model.deleteNamedReferences([decomposed,tagA],ids:model.selection);try await wait{held != nil}
            try require(model.hasPendingWork && ReferenceLogWindowModel.activeRevisionReads>0,"Held confirmation lost owned pending work")
            model.confirmingQuit=true;held!.resume(returning:.delete);held=nil
            try await wait{!model.hasPendingWork}
            let afterCancelSibling=try await exists(decomposed),afterCancelTag=try await exists(tagA)
            try require(prompts==1 && afterCancelSibling && afterCancelTag,"Quit/cancellation dispatched held or later candidate")
            model.confirmingQuit=false;model.reload();try await settle(controller);try selectRow()
            model.deleteNamedReferences([decomposed,tagA],ids:model.selection);try await wait{held != nil}
            controller.window?.close();try require(model.isInvalidated && model.hasPendingWork,"Forced-close lost pending confirmation ownership")
            held!.resume(returning:.delete);held=nil;try await wait{!model.hasPendingWork && ReferenceLogWindowModel.activeRevisionReads==0}
            let afterCloseSibling=try await exists(decomposed),afterCloseTag=try await exists(tagA)
            try require(prompts==2 && afterCloseSibling && afterCloseTag,"Retired confirmation dispatched a late deletion")
            try dispatch(liveItem);try require(prompts==2,"Retired captured native menu dispatched mutation")
        } else {throw Failure(description:"Unknown receiver case")}
        try require(try Data(contentsOf:root.appendingPathComponent(".git/index"))==beforeIndex,"RefLog named actions changed index")
        try require(try Data(contentsOf:root.appendingPathComponent("file"))==beforeFile,"RefLog named actions changed working file")
        for owner in owners{owner.window?.close();owner.window?.orderOut(nil)}
        try await wait{ReferenceLogWindowModel.activeOwnedOperations==0 && ReferenceLogWindowModel.activeRevisionReads==0}
        print("PASS: RefLog reference identity "+mode+"; actual native picker/menu and owned receivers closed")
    }
}
