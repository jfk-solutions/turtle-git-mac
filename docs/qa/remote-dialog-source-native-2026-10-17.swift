// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

struct RemoteDialogSourceVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ yes:@autoclosure () throws -> Bool,_ message:String)throws {if try !yes() {throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ yes:()->Bool)async throws {
        for _ in 0..<1800 {for window in NSApp.windows {window.contentView?.layoutSubtreeIfNeeded()};if yes(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Remote source wait at \(line)")
    }
    @MainActor static func views(_ root:NSView)->[NSView] {[root]+root.subviews.flatMap(views)}
    @MainActor static func field(_ window:NSWindow,_ label:String)throws -> NSTextField {
        guard let field=window.contentView.map(views)?.compactMap({$0 as? NSTextField}).first(where:{$0.accessibilityLabel()==label}) else {throw Failure(description:"Missing native field "+label)};return field
    }
    @MainActor static func type(_ field:NSTextField,_ value:String) {
        field.stringValue=value;field.delegate?.controlTextDidChange?(Notification(name:NSControl.textDidChangeNotification,object:field))
    }
    @MainActor static func capture(_ window:NSWindow,_ name:String)async throws {
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_REMOTE_DIALOG_CAPTURE"] else {return}
        guard #available(macOS 14.4,*) else {throw Failure(description:"Owned capture unavailable")}
        window.alphaValue=1;window.orderFront(nil);defer {window.alphaValue=0}
        for (appearance,theme) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:appearance);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
            let content=try await SCShareableContent.currentProcess
            guard let owned=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else {throw Failure(description:"Owned remote window missing")}
            let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false;config.ignoreShadowsSingleWindow=true;config.includeChildWindows=false
            let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:config)
            guard let bytes=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else {throw Failure(description:"PNG encoding")}
            try bytes.write(to:URL(fileURLWithPath:folder).appendingPathComponent(name+"-"+theme+".png"))
        }
    }
    @MainActor static func verify()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Remote Source QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
        try Data("fixture\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"Remote forms fixture")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.RemoteSource."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        let add=AddRemoteWindowController(repository:repo,access:nil,preferences:prefs);defer {add.close()}
        add.window!.alphaValue=0;add.window!.orderFront(nil)
        try await wait {(try? field(add.window!,"Remote name")) != nil}
        let name=try field(add.window!,"Remote name"),url=try field(add.window!,"Remote URL")
        type(name,"origin");type(url,root.path)
        try require(add.model.name=="origin" && add.model.url==root.path && add.model.canSave,"Native Add Remote fields did not update draft")
        add.window!.makeFirstResponder(url)
        guard let editor=url.currentEditor() as? NSTextView else {throw Failure(description:"No native URL field editor")}
        editor.setSelectedRange(NSRange(location:1,length:4));let selected=editor.selectedRange()
        add.model.error=nil;await Task.yield();add.window?.contentView?.layoutSubtreeIfNeeded()
        try require(editor.selectedRange()==selected,"Ordinary form update reset URL selection")
        add.window?.makeFirstResponder(nil)
        print("Add Remote bounds: frame=\(add.window!.frame), content=\(add.window!.contentView!.bounds), safeLayout=\(add.window!.contentLayoutRect)")
        try await capture(add.window!,"add-remote-source")
        try require(add.window!.contentView!.bounds.width >= 570 && add.window!.contentView!.bounds.height >= 180,"Add Remote compact source content bounds collapsed")
        let oldContext=add.model.formContext,oldBinding=add.model.field(\.name,context:oldContext)
        var persistReply:CheckedContinuation<Void,Error>?
        add.model.persist={_,_ in try await withCheckedThrowingContinuation {persistReply=$0}}
        add.model.save(context:oldContext);try await wait {persistReply != nil}
        oldBinding.wrappedValue="stale-name";type(name,"stale-native-name")
        try require(add.model.name=="origin" && AddRemoteWindowModel.activeOperations==1,"Busy/old Add Remote callback edited captured draft")
        persistReply!.resume(throwing:Failure(description:"Fixture remote collision"));persistReply=nil
        try await wait {!add.model.busy && add.window?.attachedSheet != nil}
        try require(!add.model.canSave && !add.windowShouldClose(add.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Owned Add error did not fence owner/Quit")
        let errorContext=add.model.formContext
        add.model.acknowledgeError(context:oldContext);try require(add.model.error != nil,"Old acknowledgement cleared newer Add error")
        add.window!.endSheet(add.window!.attachedSheet!,returnCode:.OK)
        try await wait {add.model.error == nil && add.window?.attachedSheet == nil}
        oldBinding.wrappedValue="stale-after-error";type(name,"stale-after-rebuild")
        try require(add.model.name=="origin" && add.model.formContext != errorContext,"Rebuilt Add input revived old callback")
        add.model.persist={settings,token in try await repo.applyRemoteSettings(settings,changed:[.name,.url],cancellation:token)}
        add.model.save(context:add.model.formContext);try await wait {add.model.retired && AddRemoteWindowModel.activeOperations==0}
        let savedRemote=try await repo.remoteSettings(name:"origin")
        try require(savedRemote.url == root.path,"Native Add did not retain captured local remote")

        var chosen=[String?]()
        let picker=RemoteReferenceWindowController(repository:repo,access:nil,remote:"origin",preferences:prefs) {chosen.append($0)}
        defer {picker.close()};picker.window!.alphaValue=0;picker.window!.orderFront(nil)
        var reads=0,reply:CheckedContinuation<[String],Error>?
        picker.model.query={remote,_ in try require(remote=="origin","Picker changed captured remote");reads += 1;return try await withCheckedThrowingContinuation {reply=$0}}
        picker.model.refresh();try await wait {reply != nil};let loadingContext=picker.model.formContext
        reply!.resume(returning:["é","e\u{301}","Main"]);reply=nil
        try await wait {!picker.model.busy && (try? field(picker.window!,"Remote Branch"))?.isEnabled == true}
        let readonly=try field(picker.window!,"Remote"),combo=try field(picker.window!,"Remote Branch") as! NSComboBox
        try require(!readonly.isEditable && readonly.isSelectable && readonly.stringValue=="origin","Remote is not a selectable read-only native source field")
        try require(combo.numberOfItems==3 && Data(picker.model.branch.utf8)==Data("é".utf8),"Source first selection or exact Unicode choices lost")
        type(combo,"typed/雪");try require(picker.model.branch=="typed/雪","Typed remote branch was not retained")
        picker.model.setBranch("old-loading",context:loadingContext);try require(picker.model.branch=="typed/雪","Loading form edited ready branch")
        try await capture(picker.window!,"remote-reference-source")
        func f5(_ flags:NSEvent.ModifierFlags = [])->NSEvent {NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:picker.window!.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:96)!}
        _=picker.window!.performKeyEquivalent(with:f5(.shift));try require(reads==1 && !picker.model.busy,"Modified F5 refreshed source picker")
        let stale=picker.model.formContext
        _=picker.window!.performKeyEquivalent(with:f5());try await wait {reply != nil}
        type(combo,"old-popup-choice");picker.model.choose(context:stale)
        try require(picker.model.branch.isEmpty && chosen.isEmpty,"Old combo/OK crossed refresh")
        reply!.resume(throwing:Failure(description:"Fixture remote listing failed"));reply=nil
        try await wait {!picker.model.busy && picker.window?.attachedSheet != nil}
        _=picker.window!.performKeyEquivalent(with:f5());try require(reads==2,"F5 crossed owned error sheet")
        picker.window!.endSheet(picker.window!.attachedSheet!,returnCode:.OK)
        try await wait {picker.model.error == nil && picker.window?.attachedSheet == nil}
        picker.model.query={_,_ in try await repo.remoteReferenceChoices(remote:"origin")}
        picker.model.refresh();try await wait {!picker.model.busy && picker.model.refs.contains("main")}
        let ready=picker.model.formContext;picker.model.setBranch("main",context:ready);picker.model.choose(context:ready);picker.model.choose(context:ready)
        try require(chosen.count==1 && chosen[0]=="main" && picker.model.retired,"Picker completion did not settle exactly once")
        type(combo,"after-close");try require(picker.model.branch=="main","Closed combo edited accepted result")

        _=try await repo.run(["update-ref","refs/remotes/origin/main",String(decoding:head,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)])
        let browser=ReferenceBrowserWindowController(repository:repo,access:nil,initial:"refs/remotes",preferences:prefs,picking:false) {_ in}
        defer {browser.close()};browser.window!.alphaValue=0;browser.window!.appearance=NSAppearance(named:.darkAqua);browser.window!.orderFront(nil)
        browser.model.load();try await wait {!browser.model.busy};browser.model.setFolder("refs/remotes")
        try require(browser.model.canUseFolder && browser.model.folder == "refs/remotes","Fixture did not create the remotes folder")
        browser.presentAddRemote={_,_ in false};browser.showAddRemote()
        try require(browser.addRemoteDialog==nil && !browser.model.hasChild,"Rejected Add sheet leaked Browser gate")
        try await wait {!browser.model.busy};browser.model.setFolder("refs/remotes")
        var inherited=false;browser.configureAddRemote={child in inherited = child.model.preferences === prefs && child.window?.alphaValue==0 && child.window?.appearance?.name == .darkAqua}
        browser.presentAddRemote={owner,child in owner.beginSheet(child);return true};browser.showAddRemote()
        guard let child=browser.addRemoteDialog else {throw Failure(description:"Browser Add child missing")}
        try require(inherited && child.window?.sheetParent === browser.window && browser.model.hasChild,"Browser Add preferences/appearance/ownership missing")
        child.model.requestClose();try await wait {browser.addRemoteDialog==nil && !browser.model.busy}
        browser.close()
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        try require(afterHead == head && afterIndex == index,"Remote forms changed HEAD/index")
        try require(AddRemoteWindowModel.activeOperations==0 && RemoteReferenceWindowModel.activeOperations==0,"Remote operation lease leaked")
        print("PASS: remote source forms, exact editable/read-only fields, preserved selection, stale contexts, owned errors/F5, real local Add/list and Browser child ownership")
    }
}
