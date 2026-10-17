// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import ScreenCaptureKit
import TurtleGitCore

struct TransportSourceVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ yes:Bool,_ message:String)throws {if !yes {throw Failure(description:message)}}
    @MainActor static func wait(_ ready:()->Bool,line:UInt = #line)async throws {for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Transport source timeout at \(line)")}
    @MainActor static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    @MainActor static func capture(_ window:NSWindow,name:String,folder:URL)async throws {
        guard #available(macOS 14.4,*) else {throw Failure(description:"Capture requires 14.4")}
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        for (appearance,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:appearance);window.alphaValue=1;window.orderFront(nil);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
            try require(window.frame.height<=850,"Transport window escaped content bounds")
            let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
            guard let own=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else {throw Failure(description:"Missing capture owner")}
            let config=SCStreamConfiguration();config.includeChildWindows=false;config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:own),configuration:config)
            guard let png=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else {throw Failure(description:"PNG missing")}
            try png.write(to:folder.appendingPathComponent(name+"-"+suffix+".png"))
        };window.orderOut(nil);window.alphaValue=0
    }
    @MainActor static func verify()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Transport Source"),("user.email","qa@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgSign","false")] {_=try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"base");_=try await repo.run(["branch","topic"])
        let bare=root.appendingPathComponent("remote.git");_=try await repo.run(["init","--bare",bare.path]);_=try await repo.run(["remote","add","origin",bare.path]);_=try await repo.run(["remote","add","second",bare.path])
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.TransportSource."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        let push=PushWindowController(repository:repo,access:nil,preferences:prefs),model=push.model
        defer {push.window?.close()};push.window?.alphaValue=0;push.window?.orderFront(nil);model.load();try await wait {model.canEditForm}
        model.option(\.setUpstream,context:model.formContext).wrappedValue=false
        model.option(\.savePushRemote,context:model.formContext).wrappedValue=true
        model.option(\.setUpstream,context:model.formContext).wrappedValue=true
        try require(model.options.savePushRemote && !model.options.setUpstream,"Push source save/upstream exclusion missing")
        model.option(\.allBranches,context:model.formContext).wrappedValue=true
        let allSource=model.option(\.source,context:model.formContext);allSource.wrappedValue="wrong"
        try require(!model.options.savePushRemote && model.options.source=="main","Push all-branches dependency failed")
        model.option(\.allBranches,context:model.formContext).wrappedValue=false
        model.option(\.forceWithLease,context:model.formContext).wrappedValue=true
        model.option(\.force,context:model.formContext).wrappedValue=true;model.option(\.includeTags,context:model.formContext).wrappedValue=true
        try require(model.options.forceWithLease && !model.options.force && !model.options.includeTags,"Push lease dependency failed")
        model.option(\.forceWithLease,context:model.formContext).wrappedValue=false
        let oldDestination=model.option(\.destination,context:model.formContext),source=model.option(\.source,context:model.formContext)
        source.wrappedValue="topic";source.wrappedValue="main";try await wait {!model.preparing}
        try require(model.localBranch=="main" && model.options.source=="main","Rapid source defaults published old selection")
        model.clipboardText={"git pull /private/transport-source main"};model.selectMode(arbitrary:true,context:model.formContext)
        oldDestination.wrappedValue="stale";try require(model.options.destination != "stale" && model.url=="/private/transport-source","Changed mode accepted old field")
        model.selectMode(arbitrary:false,context:model.formContext);model.options.destination="published"
        model.destinationHistory=["first","second"];let history=model.destinationHistory,historyContext=model.formContext
        model.destinationHistory=["changed","second"];model.deleteHistory(1,at:0,context:historyContext,entries:history)
        try require(model.destinationHistory==["changed","second"],"Old history index deleted newer row")
        if let path=ProcessInfo.processInfo.environment["TURTLEGIT_TRANSPORT_SOURCE_CAPTURE"] {try await capture(push.window!,name:"push-source",folder:URL(fileURLWithPath:path))}
        var firstAnswer:((Bool,Bool)->Void)?,secondAnswer:((Bool,Bool)->Void)?
        model.options.allBranches=true;model.confirmPush={_,_,_,choose in firstAnswer=choose};model.push()
        let questionField=model.option(\.force,context:model.formContext);questionField.wrappedValue=true
        try require(!model.options.force,"Pending confirmation accepted field callback")
        model.options.destination="replaced";firstAnswer?(true,true)
        try require(!model.busy && !prefs.bool(forKey:"PushAllBranches") && model.confirmation==nil,"Replaced confirmation executed/saved another draft")
        model.confirmPush={_,_,_,choose in secondAnswer=choose};model.push();firstAnswer?(false,false)
        try require(model.confirmation != nil,"Old confirmation dismissed current question");secondAnswer?(false,false)
        let retired=model.option(\.source,context:model.formContext);push.window?.close();retired.wrappedValue="closed"
        try require(model.options.source=="main","Closed Push binding accepted write")
        for isPull in [false,true] {
            let owner=FetchWindowController(repository:repo,access:nil,isPull:isPull,preferences:prefs),fetch=owner.model
            defer {owner.window?.close()};owner.window?.alphaValue=0;owner.window?.orderFront(nil);fetch.load();try await wait {fetch.canEditForm}
            let inactiveURL=fetch.field(\.url,context:fetch.formContext);inactiveURL.wrappedValue="disabled"
            try require(fetch.url != "disabled","Disabled Fetch URL accepted write")
            fetch.field(\.squash,context:fetch.formContext).wrappedValue=true
            try require(fetch.squash==isPull,"Fetch-only merge control accepted write")
            if isPull {
                fetch.field(\.noFastForward,context:fetch.formContext).wrappedValue=true;fetch.field(\.fastForwardOnly,context:fetch.formContext).wrappedValue=true
                try require(fetch.noFastForward && !fetch.fastForwardOnly,"Pull mutually exclusive ff options failed")
                fetch.field(\.noFastForward,context:fetch.formContext).wrappedValue=false
            }
            let stale=fetch.option(\.prune,context:fetch.formContext);fetch.clipboardText={"git fetch /private/transport-source main"};fetch.selectMode(arbitrary:true,context:fetch.formContext)
            stale.wrappedValue = .enabled;try require(fetch.options.prune == .configured && !fetch.launchRebase,"Fetch mode retained old controls/rebase")
            fetch.selectMode(arbitrary:false,context:fetch.formContext);try await wait {fetch.canEditForm}
            fetch.remoteBinding(fetch.formContext).wrappedValue="second";try await wait {fetch.canEditForm};try require(fetch.options.remote=="second","Fetch remote switch missing")
            if !isPull {
                fetch.field(\.launchRebase,context:fetch.formContext).wrappedValue=true
                fetch.remoteBinding(fetch.formContext).wrappedValue="*";try await wait {fetch.canEditForm}
                try require(fetch.options.allRemotes && !fetch.launchRebase,"All remotes retained Rebase")
            }
            fetch.shallow=true;fetch.field(\.depthEnabled,context:fetch.formContext).wrappedValue=true;fetch.field(\.depth,context:fetch.formContext).wrappedValue="20"
            try await wait {views(owner.window?.contentView).compactMap{$0 as? NSButton}.contains{$0.title=="Tags" && $0.isEnabled && $0.state == .mixed}}
            let tags=views(owner.window?.contentView).compactMap{$0 as? NSButton}.first{$0.title=="Tags"}!
            try await wait {(tags.target as? FetchOverrideCheckbox.Coordinator)?.value == .configured}
            for expected in [FetchOverride.disabled,.enabled,.configured] {tags.performClick(nil);try require(fetch.options.tags==expected,"Native Tags cycle differs")}
            let coordinator=tags.target as? FetchOverrideCheckbox.Coordinator,guarded=fetch.option(\.prune,context:fetch.formContext)
            fetch.busy=true;try await wait {!tags.isEnabled};coordinator?.clicked(tags);guarded.wrappedValue = .enabled
            try require(fetch.options.tags == .configured && fetch.options.prune == .configured,"Busy Fetch native/form callbacks survived")
            fetch.busy=false;try await wait {tags.isEnabled}
            if let path=ProcessInfo.processInfo.environment["TURTLEGIT_TRANSPORT_SOURCE_CAPTURE"] {try await capture(owner.window!,name:isPull ? "pull-source" : "fetch-source",folder:URL(fileURLWithPath:path))}
            let old=fetch.field(\.depth,context:fetch.formContext);owner.window?.close();old.wrappedValue="999";coordinator?.clicked(tags)
            try require(fetch.depth=="20" && (tags as? ReferenceChoiceButton)?.retired==true,"Retired Fetch form/native target survived")
        }
        // Exercise exact identities and delegate lifetime with production native controls.
        var selected="Café",remoteSelection="Cafe\u{301}"
        let names=["refs/heads/Café","refs/heads/Cafe\u{301}","refs/heads/Café"],host=NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:120),styleMask:[.titled],backing:.buffered,defer:false)
        host.isReleasedWhenClosed=false;defer {host.close()}
        host.contentViewController=NSHostingController(rootView:VStack {PushRefCombo(value:Binding(get:{selected},set:{selected=$0}),choices:names,local:true,normalizeSource:true);PushRemotePopup(values:["Café","Cafe\u{301}"],selection:Binding(get:{remoteSelection},set:{remoteSelection=$0}))})
        host.contentView?.layoutSubtreeIfNeeded()
        let combo=views(host.contentView).compactMap{$0 as? NSComboBox}.first!,delegate=combo.delegate as! PushRefCombo.Coordinator
        try require(delegate.values.count==2 && combo.numberOfItems==2,"Native source collapsed canonical-equivalent refs")
        let nfd=delegate.values.firstIndex{GitReferenceName.equal($0,"Cafe\u{301}")}!;combo.selectItem(at:nfd);delegate.comboBoxSelectionDidChange(Notification(name:NSComboBox.selectionDidChangeNotification,object:combo))
        try require(selected.utf8.elementsEqual("Cafe\u{301}".utf8),"Source combo selected wrong spelling")
        let popup=views(host.contentView).compactMap{$0 as? NSPopUpButton}.first!,popupTarget=popup.target as! PushRemotePopup.Coordinator
        try require(popup.numberOfItems==2 && popup.indexOfSelectedItem==1,"Remote popup collapsed/selected equivalent spelling")
        combo.isEnabled=false;combo.stringValue="disabled";delegate.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:combo))
        try require(selected.utf8.elementsEqual("Cafe\u{301}".utf8),"Disabled native source changed binding")
        host.close();combo.stringValue="closed";delegate.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:combo));popupTarget.changed(popup)
        try require((combo as? EditableHistoryCombo)?.lifetime.retired==true && !popup.isEnabled && selected.utf8.elementsEqual("Cafe\u{301}".utf8),"Retired native combo/popup survived")
        try await wait {PushWindowModel.activePreparationReads==0 && FetchWindowModel.activePreparationReads==0 && PushWindowModel.activePushWorkflows==0}
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(head==afterHead && index == (try Data(contentsOf:root.appendingPathComponent(".git/index"))),"Read-only source interactions mutated HEAD/index")
        print("PASS transport source: actual Push/Fetch/Pull source forms, synchronous option/default dependencies, captured histories/modes/confirmations, exact Unicode native refs/remotes, disabled/retired delegates and three-state controls; private HEAD/index preserved")
    }
}
