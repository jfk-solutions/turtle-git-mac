// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import ScreenCaptureKit
import TurtleGitCore

@main struct AboutSourceVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    @MainActor static var owners=[TurtleGitAboutController]()
    @MainActor static var pending:CheckedContinuation<String,Error>?
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ condition:()->Bool)async throws {
        for _ in 0..<1800 {if condition() {return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"About did not settle at fixture line \(line)")
    }
    @MainActor static func views(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(views)}
    @MainActor static func capture(_ controller:TurtleGitAboutController)async throws {
        guard let directory=ProcessInfo.processInfo.environment["TURTLEGIT_ABOUT_SOURCE_CAPTURE"],let window=controller.window else{return}
        guard #available(macOS 14.4,*) else {throw Failure(description:"Owned screenshot API unavailable")}
        window.alphaValue=1;window.orderFront(nil);defer{window.alphaValue=0}
        for (name,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:name);window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds:250_000_000)
            let content=try await SCShareableContent.currentProcess
            guard let own=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else {throw Failure(description:"Owned About window missing")}
            let options=SCStreamConfiguration();options.width=Int(window.frame.width*2);options.height=Int(window.frame.height*2)
            options.showsCursor=false;options.ignoreShadowsSingleWindow=true;options.includeChildWindows=false
            let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:own),configuration:options)
            try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:directory).appendingPathComponent("about-"+controller.tool.rawValue+"-source-"+suffix+".png"))
            print("Captured About \(controller.tool.rawValue)-\(suffix): \(options.width)x\(options.height)")
        }
    }
    @MainActor static func main()async {
        _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        do {try await verify();print("PASS: About source family, native variants/links/report, selected Git, animation policy/lifetime and singleton retirement")}
        catch {
            owners.forEach{$0.close()};pending?.resume(throwing:OperationCancellationFailure.cancelled);pending=nil
            for _ in 0..<1800 {if TurtleGitAboutController.activeReads==0 {break};try? await Task.sleep(nanoseconds:10_000_000)}
            fputs("About source family failed: \(error)\n",stderr);exit(1)
        }
    }
    @MainActor static func verify()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),engine=URL(fileURLWithPath:CommandLine.arguments[2])
        let bundle=Bundle(url:URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app"))!
        let info=ApplicationAboutInformation(application:bundle.bundleURL,version:bundle.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "",build:bundle.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "")
        let board=NSPasteboard(name:.init("TurtleGit.About.Source."+UUID().uuidString));defer{board.clearContents();owners.forEach{$0.close()};owners=[]}
        for listing in [nil,URL(string:"https://apps.apple.com/app/id123456789")] as [URL?] {
            let storeInfo=ApplicationAboutInformation(application:bundle.bundleURL,version:"0.1.0",build:"local",distribution:.init(appStoreBuild:true,appStoreListing:listing))
            let storeOwner=TurtleGitAboutController(tool:.application,information:storeInfo);owners.append(storeOwner)
            var opens=[URL](),checks=0;storeOwner.open={opens.append($0)};storeOwner.checkUpdates={checks += 1}
            let button=views(storeOwner.window!.contentView!).compactMap{$0 as? NSButton}.first{$0.identifier?.rawValue=="TurtleGit.About.Update"}
            try require(button?.title=="View in App Store…" && button?.isEnabled == (listing != nil),"About Store listing availability/disabled control differs")
            try require(storeOwner.diagnosticText.contains("Build configuration: App Store") && !storeOwner.diagnosticText.contains("Distribution: App Store"),"About confused build configuration with published distribution")
            storeOwner.update(nil)
            try require(opens==(listing.map{[$0]} ?? []) && checks==0,"About opened generic Store or bypassed listing validation")
            storeOwner.close();storeOwner.update(nil)
            try require(opens.count == (listing == nil ? 0:1),"Retired About opened a Store page")
        }

        for tool in TurtleGitAboutTool.allCases {
            let owner=TurtleGitAboutController(tool:tool,information:info);owners.append(owner)
            owner.clipboard=board;owner.banner?.reduceMotion={true}
            owner.window?.alphaValue=0;owner.window?.orderFront(nil)
            var links=[URL](),updates=0,closed=0
            owner.open={links.append($0)};owner.checkUpdates={updates += 1};owner.onClosed={closed += 1}
            owner.checkSelectedGit(engine);owner.checkSelectedGit(engine)
            try await wait {!owner.checkingRuntime && TurtleGitAboutController.activeReads==0}
            try require(owner.diagnosticText.contains("Selected Git: git version ") && owner.diagnosticText.contains("Git executable: "+engine.path) && owner.diagnosticText.contains("Bundled components:"),"Selected engine or manifest report missing")
            owner.window?.contentView?.layoutSubtreeIfNeeded()
            let descendants=views(owner.window!.contentView!),buttons=descendants.compactMap{$0 as? NSButton}
            guard let versions=descendants.compactMap({$0 as? NSTextView}).first(where:{$0.accessibilityLabel()=="Version Information"}),let ok=buttons.first(where:{$0.title=="OK"}),let project=buttons.first(where:{$0.title=="Project website"}) else {throw Failure(description:"Source About controls missing")}
            try require(versions.string==owner.diagnosticText && !versions.isEditable && versions.isSelectable && (ok.keyEquivalent=="\r" || owner.window?.defaultButtonCell === ok.cell),"Report/selectability/default OK: equal=\(versions.string==owner.diagnosticText), editable=\(versions.isEditable), selectable=\(versions.isSelectable), key=\(ok.keyEquivalent.debugDescription), default=\(owner.window?.defaultButtonCell === ok.cell)")
            try require((owner.banner != nil)==tool.hasBanner && tool.artwork(size:48) != nil,"Tool artwork/banner variant")
            try require(tool.artworkName==MenuIcon.turtle.rawValue,"About did not use the custom TurtleGit mascot")
            try require((versions.enclosingScrollView?.bounds.width ?? 0)>=owner.window!.contentView!.bounds.width-80,"Version pane did not fill source group width")
            for button in buttons {
                let frame=button.convert(button.bounds,to:owner.window!.contentView!)
                try require(owner.window!.contentView!.bounds.insetBy(dx:-1,dy:-1).contains(frame),"About button clipped: \(tool.rawValue) / \(button.title) / \(frame)")
            }
            try require(ok.convert(ok.bounds,to:owner.window!.contentView!).minY<32,"Source OK footer floated above window bottom")
            let original=project.identifier;project.identifier = .init("https://example.invalid/wrong-target")
            owner.openLink(project);project.identifier=original
            try require(links.last?.absoluteString=="https://jfk-solutions.github.io/turtle-git-mac/","Link reread mutable identifier")
            let foreign=NSButton(title:"Foreign",target:nil,action:nil);foreign.identifier=original;owner.openLink(foreign)
            try require(links.count==1,"Foreign link control dispatched")
            owner.openLicense(nil);owner.openNotices(nil);owner.update(nil);owner.copyVersionInformation(to:board)
            try require(links==[URL(string:"https://jfk-solutions.github.io/turtle-git-mac/")!,info.license!,info.notices!] && updates==1 && board.string(forType:.string)==versions.string,"Captured links/copy/update routes")
            try await capture(owner)
            if let banner=owner.banner {
                let before=banner.renderedFrames
                banner.disturb(x:200,y:32,pressed:true);banner.advance()
                try require(banner.renderedFrames==before && !banner.animationRunning,"Reduce Motion allowed rendering/timer")
                banner.reduceMotion={false};banner.visible={false};banner.updateAnimation()
                try require(!banner.animationRunning,"Hidden banner retained timer")
                banner.visible={true};banner.disturb(x:200,y:32,pressed:true);banner.advance()
                try require(banner.renderedFrames==before+1,"Live native banner did not render")
                owner.window?.alphaValue=1;owner.window?.orderFront(nil)
                // Prohibited/background receivers get no truthful OS occlusion
                // transitions. Inject that signal; the window stays nonactivating.
                banner.windowVisible={$0.isVisible && !$0.isMiniaturized}
                banner.updateAnimation();let manualFrames=banner.renderedFrames
                try await wait {banner.animationRunning && banner.renderedFrames>manualFrames}
                banner.visible={false};banner.updateAnimation()
                try require(!banner.animationRunning,"Live repeating timer did not pause")
                banner.reduceMotion={true};banner.visible={true};banner.updateAnimation()
                try require(!banner.animationRunning,"Reduce Motion retained a live timer")
                owner.window?.alphaValue=0
            }
            let copied=board.string(forType:.string),count=links.count
            owner.close();owner.closeAbout(nil);owner.copyVersionInformation(to:board);owner.openLink(project);owner.openLicense(nil);owner.update(nil)
            try require(owner.retired && closed==1 && links.count==count && updates==1 && board.string(forType:.string)==copied && buttons.allSatisfy{!$0.isEnabled},"Retired About actions replayed")
            if let banner=owner.banner {let frames=banner.renderedFrames;banner.advance();try require(banner.retired && !banner.animationRunning && banner.renderedFrames==frames,"Closed banner retained work")}
        }
        // Service reuses exact tool owners; an old close cannot remove a replacement.
        let service=TurtleGitAboutService();service.information={info};service.checkRuntime={_ in}
        service.present={$0.banner?.reduceMotion={true};$0.window?.alphaValue=0;$0.window?.orderFront(nil)}
        var creations=0
        service.create={tool,info in creations += 1;let owner=TurtleGitAboutController(tool:tool,information:info);owners.append(owner);return owner}
        let first=service.show(.application),again=service.show(.application),other=service.show(.merge),staleClose=first.onClosed
        try require(first === again && first !== other && creations==2,"Tool singleton reuse")
        first.close();let replacement=service.show(.application);staleClose()
        try require(replacement !== first && service.show(.application) === replacement && creations==3,"Old close removed the replacement owner")
        try require(service.hasOwnedUtilityWindow && service.presentExistingUtility(),"About registry lost existing utility owner")
        replacement.close();other.close()
        try require(!service.hasOwnedUtilityWindow && !service.presentExistingUtility(),"Closed About retained utility owner")
        // Uncooperative read remains in Quit accounting, without late report writes.
        let held=TurtleGitAboutController(tool:.blame,information:info);owners.append(held)
        held.inspectRuntime={_,_,_ in try await withCheckedThrowingContinuation{pending=$0}}
        held.checkSelectedGit(engine);try await wait {pending != nil}
        let frozen=held.diagnosticText;held.close()
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel,"Closed About read lost Quit ownership")
        pending?.resume(returning:"git version late");pending=nil;try await wait {TurtleGitAboutController.activeReads==0}
        try require(held.diagnosticText==frozen,"Retired About published a late version")
        // Actual subprocess cancellation reaps the shell and sleep descendant.
        let helper=root.appendingPathComponent("about-slow-git"),ready=root.appendingPathComponent("about-pids")
        let script="#!/bin/sh\n/bin/sleep 30 &\nabout_child=$!\ntrap 'kill \"$about_child\" 2>/dev/null; wait \"$about_child\" 2>/dev/null; exit 143' TERM INT\nprintf '%s %s\\n' \"$$\" \"$about_child\" > '"+ready.path+"'\nwait \"$about_child\"\n"
        try script.write(to:helper,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        let slow=TurtleGitAboutController(tool:.image,information:info);owners.append(slow);slow.checkSelectedGit(helper)
        try await wait {((try? String(contentsOf:ready)) ?? "").split(whereSeparator:\.isWhitespace).count==2}
        let pids=try String(contentsOf:ready).split(whereSeparator:\.isWhitespace).compactMap{Int32($0)}
        slow.close();try await wait {TurtleGitAboutController.activeReads==0}
        try require(pids.count==2 && pids.allSatisfy{kill($0,0) != 0},"About version check leaked owned processes")
    }
}
