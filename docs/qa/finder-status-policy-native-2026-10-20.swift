// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor enum FinderStatusPolicyVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<2000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Finder status settings deadline at \(line)")
    }
    static func views(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(views)}
    static func capture(_ host:NSView,owner:NSWindow,directory:URL)async throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let prior=owner.frame.origin
        defer {owner.alphaValue=0;owner.setFrameOrigin(prior)}
        for (appearance,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            owner.alphaValue=0;owner.appearance=NSAppearance(named:appearance);host.appearance=owner.appearance
            host.layoutSubtreeIfNeeded();owner.displayIfNeeded();try await Task.sleep(nanoseconds:300_000_000)
            let screen=NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1200,height:900)
            owner.setFrameOrigin(NSPoint(x:screen.midX-owner.frame.width/2,y:screen.midY-owner.frame.height/2))
            owner.alphaValue=1;owner.displayIfNeeded()
            let hide=Task { @MainActor in try? await Task.sleep(nanoseconds:1_800_000_000);owner.alphaValue=0 }
            defer {hide.cancel();owner.alphaValue=0}
            try await Task.sleep(nanoseconds:120_000_000)
            let destination=directory.appendingPathComponent("finder-status-policy-"+name+".png")
            let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");process.arguments=["-x","-o","-l",String(owner.windowNumber),destination.path]
            process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
            try process.run();let deadline=Date().addingTimeInterval(5)
            while process.isRunning && Date()<deadline {try await Task.sleep(nanoseconds:10_000_000)}
            if process.isRunning {owner.alphaValue=0;process.terminate();process.waitUntilExit();throw Failure(description:"Owned WindowServer capture timed out")}
            owner.alphaValue=0;hide.cancel()
            try require(process.terminationStatus==0,"WindowServer capture failed; no bitmap fallback")
            try require(NSBitmapImageRep(data:Data(contentsOf:destination)) != nil,"WindowServer PNG unavailable")
        }
    }
    static func verify(root:URL,git:URL,helper:URL,captureDirectory:URL?=nil)async throws {
        let suite="TurtleGit.StatusPolicy.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        let group=root.appendingPathComponent("private-group"),status=group.appendingPathComponent("status.json"),overlays=group.appendingPathComponent("overlay-settings.json"),advanced=status.appendingPathExtension("policy")
        let operationDirectory=root.appendingPathComponent("private-operation-leases")
        let originalAcquire=FinderCommandStatusActivity.acquire
        FinderCommandStatusActivity.acquire={try FinderStatusOperationLease.begin(directory:operationDirectory,notify:{})}
        let commandA=UUID(),commandB=UUID(),dockOwner=UUID()
        var ownedLocalBegins=0
        defer {
            while ownedLocalBegins>0 {LocalGitCommandProgress.end();ownedLocalBegins-=1}
            for owner in [commandA,commandB,dockOwner] {FinderCommandStatusActivity.update(owner,active:false)}
            FinderCommandStatusActivity.acquire=originalAcquire
        }
        var windows=[NSWindow](),notifications=0,publicationFailure=false,acceptedBeforeNotification=true
        DialogGeometry.install(preferences:prefs)
        defer {windows.forEach{$0.contentView=nil;$0.close()};prefs.removePersistentDomain(forName:suite);DialogGeometry.install(preferences:.standard)}
        @MainActor func window(_ view:NSView)->NSWindow {
            let window=NSWindow(contentRect:NSRect(x:-12000,y:-12000,width:940,height:800),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.alphaValue=0;window.contentView=view;view.frame=window.contentLayoutRect;window.orderFront(nil);windows.append(window);view.layoutSubtreeIfNeeded();return window
        }
        let overlay=FinderOverlaySettingsModel(preferences:prefs,publish:{value in
            if publicationFailure {throw Failure(description:"Injected owned overlay publication failure")}
            return try value.write(to:overlays)
        },notify:{
            notifications += 1
            acceptedBeforeNotification = acceptedBeforeNotification && FinderOverlaySettings.read(from:overlays)==FinderOverlaySettings.from(defaults:prefs)
        },extensionState:{false},openExtensionManager:{},readStatusPolicy:{try FinderStatusPolicy.read(from:status)},configureStatusPolicy:FinderStatusSettingsPublication.transaction(statusURL:status,ownedURL:overlays))
        let host=NSHostingView(rootView:FinderOverlaySettingsPage(model:overlay)),owner=window(host)
        overlay.attach(to:owner);try await wait{overlay.formContext.page == .overlays}
        let labels=["Default","Shell Extended","Shell","None"]
        do {try await wait {host.layoutSubtreeIfNeeded();return views(host).compactMap{$0 as? NSButton}.filter{labels.contains($0.title)}.count==4}}
        catch {throw Failure(description:"\(error); views="+views(host).map{String(describing:type(of:$0))}.joined(separator:"; "))}
        let choices=views(host).compactMap{$0 as? NSButton}.filter{labels.contains($0.title)}
        try require(choices.map(\.title)==labels && FinderOverlayCacheMode.allCases.map(\.rawValue)==[1,3,2,0],"Source cache choices/order/raw values differ")
        let checkboxTitles=["Unversioned files mark parent folder as modified","Show status of subrepositories in parent folders"]
        try await wait {host.layoutSubtreeIfNeeded();return views(host).compactMap{$0 as? NSButton}.filter{checkboxTitles.contains($0.title)}.count==2}
        let checkboxes=views(host).compactMap{$0 as? NSButton}.filter{checkboxTitles.contains($0.title)}
        for button in checkboxes {try require(button.isEnabled && button.state == .off,"Initial Default checkbox state differs");button.performClick(nil)}
        try await wait {overlay.draft.unversionedAsModified && overlay.draft.recurseSubmodules}
        overlay.draft.iconSet = .modern;overlay.draft.excludePaths=root.path+"/excluded*"
        overlay.draft.includePaths=root.path+"/excluded/allowed?"
        if ProcessInfo.processInfo.environment["TURTLEGIT_FINDER_POLICY_CAPTURE_ONLY"]=="1" {
            guard let captureDirectory else{throw Failure(description:"Capture-only invocation requires destination")}
            overlay.draft.excludePaths="/Users/example/Projects/Archive*";overlay.draft.includePaths="/Users/example/Projects/Archive/active?"
            try await Task.sleep(nanoseconds:100_000_000)
            try await capture(host,owner:owner,directory:captureDirectory)
            return
        }
        let repoRoot=root.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at:repoRoot.appendingPathComponent("a/b"),withIntermediateDirectories:true)
        let plain=GitRepository(root:repoRoot,executable:git,libgit2Configuration:.init(enabled:false))
        _ = try await plain.run(["init","-b","main"])
        for (key,value) in [("user.name","Finder Policy QA"),("user.email","finder-policy@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await plain.run(["config",key,value])}
        let file=repoRoot.appendingPathComponent("a/b/file")
        try Data("initial\n".utf8).write(to:file);try await plain.stage(["a/b/file"]);_ = try await plain.commit(message:"private baseline")
        try Data("changed private status\n".utf8).write(to:file)
        let head=try await plain.run(["rev-parse","HEAD"]).stdout,index=try await plain.run(["ls-files","--stage","-z"]).stdout
        let collector=GitRepository(root:plain.root,executable:git,libgit2Configuration:.init(helperURL:helper))
        for mode in FinderOverlayCacheMode.allCases {
            guard let choice=choices.first(where:{$0.tag==mode.rawValue}) else{throw Failure(description:"Native radio missing for mode \(mode.rawValue)")}
            choice.performClick(nil)
            try await wait {host.layoutSubtreeIfNeeded();return overlay.draft.cacheMode==mode && choices.allSatisfy{$0.state == ($0.tag==mode.rawValue ? .on:.off)}}
            let context=overlay.formContext
            if mode != .standard {
                overlay.field(\.unversionedAsModified,context:context).wrappedValue=false
                overlay.field(\.recurseSubmodules,context:context).wrappedValue=false
                try require(overlay.draft.unversionedAsModified && overlay.draft.recurseSubmodules,"Disabled Default-only controls changed retained values")
            }
            try await wait {host.layoutSubtreeIfNeeded();let buttons=views(host).compactMap{$0 as? NSButton}.filter{checkboxTitles.contains($0.title)};return buttons.count==2 && buttons.allSatisfy{$0.isEnabled == (mode == .standard)}}
            try require(overlay.apply(),"Source mode Apply failed: \(overlay.error ?? "none")")
            let policy=try FinderStatusPolicy.read(from:status),collection=try await collector.collectFinderOverlay(policy:policy)
            try require(policy.cacheMode==mode && collection.policy==policy,"Selected mode did not reach actual collector")
            if mode == .none {try require(collection.entries.count==1 && collection.entries[plain.root.path] == .normal,"None collected status instead of normal folder")}
            else {
                try require(collection.entries[file.path] == .modified,"Selected status mode lost changed child file")
                try require(collection.entries[plain.root.path] == (mode == .shell ? .normal:.modified),"Shell/Extended recursive rollup differs")
            }
            if mode == .standard,let captureDirectory {try await capture(host,owner:owner,directory:captureDirectory)}
        }
        try require(notifications==4 && acceptedBeforeNotification,"Overlay notification preceded accepted settings")
        let savedOverlay=try Data(contentsOf:overlays)
        overlay.draft.iconSet = .flat;overlay.draft.cacheMode = .shellExtended
        overlay.cancel();try require(try Data(contentsOf:overlays)==savedOverlay && !overlay.modified,"Overlay Cancel published an unaccepted draft")
        // Advanced writes only its own record, even with an unsaved overlay draft.
        overlay.draft.cacheMode = .shell;overlay.draft.iconSet = .win10
        var advancedNotifications=0,failAdvanced=false
        let model=AdvancedSettingsModel(defaults:prefs,publishFinderMenu:{_ in},publishCachePersistence:{_ in},publishCacheTray:{_ in},readStatusPolicy:{try FinderStatusPolicy.read(from:status)},publishStatusPolicy:{value in
            if failAdvanced {throw Failure(description:"Injected owned policy publication failure")};return try value.write(to:status)
        },notifyStatusPolicy:{advancedNotifications += 1},configureStatusPolicy:FinderStatusSettingsPublication.transaction(statusURL:status,ownedURL:advanced))
        let tableHost=NSHostingView(rootView:AdvancedSettingsTable(model:model)),advancedOwner=window(tableHost);model.attach(to:advancedOwner)
        try await wait {tableHost.layoutSubtreeIfNeeded();return views(tableHost).contains{$0 is NSTableView}}
        guard let table=views(tableHost).compactMap({$0 as? NSTableView}).first,let coordinator=table.delegate as? AdvancedSettingsTable.Coordinator,let column=table.tableColumn(withIdentifier:.init("value")) else {throw Failure(description:"Actual Advanced table missing")}
        @MainActor func enter(_ key:String,_ text:String)throws {
            guard let row=AdvancedSettingDefinition.all.firstIndex(where:{$0.name==key}) else{throw Failure(description:"Advanced source key missing")}
            coordinator.tableView(table,setObjectValue:text,for:column,row:row)
            try require(model.values[key]==text,"Owned Advanced table rejected \(key)")
        }
        try enter("OverlaysCaseSensitive","false");try enter("TGitCacheCheckContentMaxSize","1");try enter("BlockStatus","true")
        try require(!FileManager.default.fileExists(atPath:advanced.path),"Advanced draft published before Apply")
        model.apply();try require(model.error==nil && !model.modified,"Advanced Apply failed: \(model.error ?? "none")")
        let accepted=try FinderStatusPolicyPreferences.read(from:status)
        try require(accepted == .init(caseSensitive:false,contentCheckLimitKiB:1,blockStatus:true) && advancedNotifications==1,"Advanced source values not published")
        try require(try Data(contentsOf:overlays)==savedOverlay && overlay.draft.iconSet == .win10 && overlay.draft.cacheMode == .shell,"Advanced overwrote unrelated overlay saved/draft values")
        let beforeFailure=try Data(contentsOf:advanced)
        try enter("TGitCacheCheckContentMaxSize","2");failAdvanced=true;model.apply()
        try require(model.error != nil && model.modified && prefs.integer(forKey:"TGitCacheCheckContentMaxSize")==1 && advancedNotifications==1,"Failed policy Apply committed local state or notified")
        let retainedAdvanced=try Data(contentsOf:advanced),retainedPolicy=try FinderStatusPolicy.read(from:status)
        try require(retainedAdvanced==beforeFailure && retainedPolicy.contentCheckLimitKiB==1,"Failed policy Apply did not restore durable record")
        failAdvanced=false;model.apply();try require(model.error==nil && prefs.integer(forKey:"TGitCacheCheckContentMaxSize")==2 && advancedNotifications==2,"Pending policy Apply could not retry")
        try enter("BlockStatus","false");model.cancel();try require(model.values["BlockStatus"]=="true" && advancedNotifications==2,"Advanced Cancel changed accepted policy")
        for key in ["OverlaysCaseSensitive","TGitCacheCheckContentMaxSize","BlockStatus"] {try enter(key,"")}
        model.apply();let restoredDefaults=try FinderStatusPolicyPreferences.read(from:status)
        try require(model.error==nil && restoredDefaults == .init(),"Blank source defaults were not restored")
        try require(AdvancedSettingsModel.statusPolicyNames.allSatisfy{prefs.object(forKey:$0)==nil},"Blank Advanced values retained explicit overrides")
        model.suspend();try require(!model.edit("BlockStatus",text:"true"),"Hidden Advanced page accepted stale edit");model.activate()
        // A retired owner refuses both field callbacks and a stale Apply.
        let count=advancedNotifications;advancedOwner.close()
        coordinator.tableView(table,setObjectValue:"true",for:column,row:AdvancedSettingDefinition.all.firstIndex{$0.name=="BlockStatus"}!)
        model.values["BlockStatus"]="true";model.apply()
        let retiredPolicy=try FinderStatusPolicyPreferences.read(from:status)
        try require(advancedNotifications==count && retiredPolicy == .init(),"Retired Advanced owner published stale settings")
        overlay.cancel();publicationFailure=true;overlay.draft.cacheMode = .shell
        try require(!overlay.apply() && overlay.modified && notifications==4,"Failed overlay publication was accepted")
        try require(try Data(contentsOf:overlays)==savedOverlay,"Failed overlay publication damaged previous record")
        owner.close();let stale=overlay.formContext;overlay.field(\.cacheMode,context:stale).wrappedValue = .standard
        choices.first?.performClick(nil);checkboxes.first?.performClick(nil)
        try require(overlay.draft.cacheMode == .shell && overlay.draft.unversionedAsModified && overlay.draft.recurseSubmodules,"Closed owner accepted a native control callback")
        try require(!overlay.apply(),"Retired overlay owner accepted Apply")
        // Native owner aggregation holds one private global fence until the
        // last active/paused command drains. Retained failure badges do not.
        try require(FinderCommandStatusActivity.activeOwnerCount==0,"Unexpected unowned command activity in private receiver")
        FinderCommandStatusActivity.update(commandA,active:true);FinderCommandStatusActivity.update(commandB,active:true)
        try require(FinderCommandStatusActivity.activeOwnerCount==2 && FinderStatusOperationLease.isBlocked(directory:operationDirectory),"Nested command owners did not block status")
        FinderCommandStatusActivity.update(commandA,active:false)
        try require(FinderStatusOperationLease.isBlocked(directory:operationDirectory),"First command release ended another owner fence")
        FinderCommandStatusActivity.update(commandB,active:false)
        LocalGitCommandProgress.begin();ownedLocalBegins+=1;LocalGitCommandProgress.begin();ownedLocalBegins+=1
        try require(FinderCommandStatusActivity.activeOwnerCount==1 && FinderStatusOperationLease.isBlocked(directory:operationDirectory),"Nested local progress lost aggregate lease")
        LocalGitCommandProgress.end();ownedLocalBegins-=1
        try require(FinderStatusOperationLease.isBlocked(directory:operationDirectory),"Local progress released before true final end")
        LocalGitCommandProgress.end();ownedLocalBegins-=1
        let registry=DockProgressRegistry{_ in};registry.commandActivity={FinderCommandStatusActivity.update(dockOwner,active:$0)}
        let attachment=DockProgressAttachment.Coordinator(registry:registry);defer {attachment.retire();registry.commandActivity=nil}
        let dockWindow=window(NSView());attachment.attach(dockWindow);attachment.update(DockProgressState(.paused))
        try require(FinderStatusOperationLease.isBlocked(directory:operationDirectory),"Paused owned Dock command did not retain status fence")
        let failed=UUID();registry.update(failed,DockProgressState(.failed))
        try require(registry.current?.kind == .failed && FinderStatusOperationLease.isBlocked(directory:operationDirectory),"Retained failure hid a live paused command fence")
        attachment.update(DockProgressState(.failed))
        try require(!FinderStatusOperationLease.isBlocked(directory:operationDirectory),"Failure-only retained Dock state blocked status")
        attachment.retire();attachment.update(DockProgressState(.running));dockWindow.close();registry.remove(failed)
        try require(FinderCommandStatusActivity.activeOwnerCount==0 && !FinderStatusOperationLease.isBlocked(directory:operationDirectory),"Retired Dock owner recreated command fence")
        let finalHead=try await plain.run(["rev-parse","HEAD"]).stdout,finalIndex=try await plain.run(["ls-files","--stage","-z"]).stdout
        try require(finalHead==head && finalIndex==index && (try Data(contentsOf:file))==Data("changed private status\n".utf8),"Finder policy workflow mutated Git contents")
        windows.forEach{$0.contentView=nil;$0.close()};try await wait{NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil}}
    }
}
