// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import ScreenCaptureKit
import TurtleGitCore

struct BranchTagSourceVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ yes:Bool,_ message:String)throws {if !yes {throw Failure(description:message)}}
    @MainActor static func wait(_ yes:()->Bool,line:UInt = #line)async throws {for _ in 0..<2500 {if yes(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Branch source timeout at \(line)")}
    @MainActor static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    @MainActor static func capture(_ window:NSWindow,name:String,folder:URL)async throws {
        guard #available(macOS 14.4,*) else {throw Failure(description:"Capture requires macOS 14.4")}
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        for (appearance,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:appearance);window.alphaValue=1;window.orderFront(nil);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
            try require(window.frame.height<=850,"Creation form escaped native bounds")
            let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
            guard let own=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else {throw Failure(description:"Capture owner missing")}
            let config=SCStreamConfiguration();config.includeChildWindows=false;config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:own),configuration:config)
            guard let png=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else {throw Failure(description:"PNG missing")}
            try png.write(to:folder.appendingPathComponent(name+"-"+suffix+".png"))
        };window.orderOut(nil);window.alphaValue=0
    }
    @MainActor static func verify()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git)
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Source QA"),("user.email","qa@example.invalid"),("core.precomposeUnicode","true"),("core.hooksPath","/dev/null"),("commit.gpgSign","false"),("tag.gpgSign","false"),("user.signingkey","QA-key")] {_=try await repo.run(["config",key,value])}
        try Data("source\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"base")
        let hash=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines),index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let bare=root.deletingLastPathComponent().appendingPathComponent("bare-"+root.lastPathComponent),remote=GitRepository(root:bare,executable:git)
        try FileManager.default.createDirectory(at:bare,withIntermediateDirectories:true);_=try await remote.run(["init","--bare"]);_=try await repo.run(["remote","add","origin",bare.path])
        for ref in ["refs/remotes/origin/Café","refs/remotes/origin/Other"] {_=try await repo.run(["update-ref",ref,hash])}
        let suite="TurtleGit.BranchSource."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        let owner=BranchTagWindowController(repository:repo,access:nil,isTag:false,preferences:prefs),model=owner.model
        defer {owner.window?.close()};owner.window?.alphaValue=0;owner.window?.orderFront(nil);model.load(revision:nil)
        try await wait {!model.busy && !model.chooser.busy && model.canEditForm}
        let oldName=model.option(\.name,context:model.formContext)
        model.chooser.branchRevision="refs/remotes/origin/Café";model.selectBase(.branch,context:model.formContext)
        try require(model.options.name=="Café" && model.remote,"Remote suggestion/source base missing")
        oldName.wrappedValue="old base";try require(model.options.name=="Café","Old base callback changed current form")
        let nfd="Cafe\u{301}"
        model.option(\.name,context:model.formContext).wrappedValue=nfd;model.nameChanged()
        model.chooser.branchRevision="refs/remotes/origin/Other";model.changedBase()
        try require(model.options.name.utf8.elementsEqual(nfd.utf8) && model.options.tracking == .noTrack,"Equivalent custom spelling overwritten or tracking retained")
        model.options.tracking = .automatic
        try await wait {views(owner.window?.contentView).compactMap{$0 as? NSButton}.contains{$0.title=="Track" && $0.isEnabled}}
        let track=views(owner.window?.contentView).compactMap{$0 as? NSButton}.first{$0.title=="Track"}!
        try require(track is ReferenceChoiceButton && track.allowsMixedState,"Owned source Track control missing")
        try await wait { track.state == .mixed && (track.target as? TrackingCheckbox.Coordinator)?.value == .automatic }
        for expected in [CheckoutTracking.noTrack,.track,.automatic] {track.performClick(nil);try require(model.options.tracking==expected,"Track cycle differs from source: expected=\(expected), model=\(model.options.tracking), native=\(track.state.rawValue)")}
        let target=track.target as? TrackingCheckbox.Coordinator,originalTracking=model.options.tracking,force=model.option(\.force,context:model.formContext)
        model.busy=true;try await wait {!track.isEnabled}
        target?.clicked(track);force.wrappedValue=true
        try require(model.options.tracking==originalTracking && !model.options.force,"Disabled native/form callback remained active")
        model.busy=false;try await wait {track.isEnabled}
        model.options.name="topic-e\u{301}";model.options.message="Description e\u{301}";model.options.tracking = .noTrack
        if let path=ProcessInfo.processInfo.environment["TURTLEGIT_BRANCH_SOURCE_CAPTURE"] {try await capture(owner.window!,name:"create-branch-source",folder:URL(fileURLWithPath:path))}
        let name=model.options.name,message=model.options.message,staleForce=model.option(\.force,context:model.formContext)
        var closes=0,created=0;model.close={closes+=1};model.onCreated={_ in created+=1};model.create()
        try await wait {!model.busy && BranchTagWindowModel.activeCreations==0}
        try require(closes==1 && created==1 && model.createdBranch?.utf8.elementsEqual(name.utf8)==true,"Branch creation did not settle once")
        let catalog=try await repo.checkoutReferences();try require(catalog.contains{GitReferenceName.equal($0.name,"refs/heads/"+name)},"Branch spelling changed")
        let description=try await repo.run(["-c","core.precomposeunicode=false","config","--local","--get","branch."+name+".description"]).text
        try require(description.utf8.elementsEqual((message+"\n").utf8),"Description spelling changed")
        staleForce.wrappedValue=true;try require(!model.options.force,"Created form callback survived completion")
        owner.window?.close();target?.clicked(track)
        try require((track as? ReferenceChoiceButton)?.retired==true && !track.isEnabled && model.options.tracking == .noTrack,"Closed native Track target survived")
        let tag=BranchTagWindowController(repository:repo,access:nil,isTag:true,preferences:prefs);defer {tag.window?.close()}
        tag.window?.alphaValue=0;tag.window?.orderFront(nil);tag.model.load(revision:nil);try await wait {!tag.model.busy && !tag.model.chooser.busy}
        tag.model.option(\.name,context:tag.model.formContext).wrappedValue="release-e\u{301}"
        tag.model.option(\.message,context:tag.model.formContext).wrappedValue="Tag message e\u{301}"
        tag.model.boolean(\.pushAfterCreation,context:tag.model.formContext).wrappedValue=true
        try require(!tag.model.remote && tag.model.canSign,"Tag-specific options not loaded")
        if let path=ProcessInfo.processInfo.environment["TURTLEGIT_BRANCH_SOURCE_CAPTURE"] {try await capture(tag.window!,name:"create-tag-source",folder:URL(fileURLWithPath:path))}
        var push:String?,tagCreated=0;tag.model.close={};tag.model.onPushTag={push=$0};tag.model.onCreated={_ in tagCreated+=1};tag.model.create()
        try await wait {!tag.model.busy && BranchTagWindowModel.activeCreations==0}
        try require(tagCreated==1 && push?.utf8.elementsEqual("refs/tags/release-e\u{301}".utf8)==true,"Tag Push handoff changed spelling or duplicated")
        var options=PushOptions();options.remote="origin";options.source=push!;options.destination="source-published"
        _=try await repo.push(options)
        let remoteHash=try await remote.run(["rev-parse","refs/tags/source-published^{commit}"]).text.trimmingCharacters(in:.newlines)
        let afterIndex=try Data(contentsOf:root.appendingPathComponent(".git/index")),head=try await repo.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try require(remoteHash==hash && afterIndex==index && head==hash,"Creation/Push changed wrong object, HEAD or index")
        tag.window?.close();try await wait {BranchTagWindowModel.activeReads==0 && BranchTagWindowModel.activeCreations==0}
        print("PASS native Branch/Tag source: source base/options, exact custom suggestions, native three-state/disabled/retired controls, captured form callbacks, actual exact-name branch/description/tag/Push handoff and private remote push; HEAD/index preserved")
    }
}
