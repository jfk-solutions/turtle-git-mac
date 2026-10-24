// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

@MainActor enum ImageOverlayInspectionVerification {
    struct Failure:Error,LocalizedError {let message:String;var errorDescription:String?{message}}
    static func require(_ value:@autoclosure()throws->Bool,_ message:String,line:Int = #line)throws{
        if try !value(){throw Failure(message:"\(line): "+message)}
    }
    static func wait(_ message:String,line:Int = #line,_ ready:()->Bool)async throws{
        for _ in 0..<600{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(message:"\(line): "+message)
    }
    static func descendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(descendants)}
    static func doubleClick(_ button:ImageComparisonAlphaButton)throws{
        guard let window=button.window,let event=NSEvent.mouseEvent(with:.leftMouseDown,location:button.convert(NSPoint(x:button.bounds.midX,y:button.bounds.midY),to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:2,clickCount:2,pressure:1) else{throw Failure(message:"Missing native alpha click owner")}
        button.mouseDown(with:event)
    }
    static func capture(_ window:NSWindow)async throws{
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_IMAGE_TOOLBAR_CAPTURE"] else{return}
        guard #available(macOS 14.4,*) else{throw Failure(message:"Native capture requires macOS 14.4")}
        let frame=window.frame,alpha=window.alphaValue
        NSApp.setActivationPolicy(.accessory);window.setContentSize(window.contentMinSize);window.center();window.alphaValue=1;window.makeKeyAndOrderFront(nil)
        defer{window.alphaValue=alpha;window.setFrame(frame,display:false);NSApp.setActivationPolicy(.prohibited)}
        for(appearance,suffix)in[(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")]{
            window.appearance=NSAppearance(named:appearance);window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds:300_000_000)
            let content=try await SCShareableContent.currentProcess
            guard let own=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else{throw Failure(message:"Owned overlay capture window missing")}
            let configuration=SCStreamConfiguration();configuration.width=Int(window.frame.width*window.backingScaleFactor);configuration.height=Int(window.frame.height*window.backingScaleFactor);configuration.showsCursor=false;configuration.ignoreShadowsSingleWindow=true
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:own),configuration:configuration)
            let bitmap=NSBitmapImageRep(cgImage:pixels);var colorful=0
            for y in stride(from:0,to:bitmap.pixelsHigh,by:8){for x in stride(from:0,to:bitmap.pixelsWide,by:8){if let c=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.sRGB){let v=[c.redComponent,c.greenComponent,c.blueComponent];if (v.max() ?? 0)-(v.min() ?? 0)>0.25{colorful += 1}}}}
            try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:folder).appendingPathComponent("image-overlay-inspection-"+suffix+".png"))
            try require(colorful>20,"Native overlay capture must contain actual colored input pixels: count=\(colorful), pixels=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh), frame=\(window.frame), minimum=\(window.contentMinSize)")
        }
    }
    static func verify()async throws{
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.ImageOverlay.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(0,forKey:"AutoCloseGitProgress");DialogGeometry.install(preferences:prefs)
        defer{prefs.removePersistentDomain(forName:suite);DialogGeometry.install(preferences:.standard)}
        let a=try ImageFramesVerification.sequence(type:"com.compuserve.gif" as CFString,colors:[.red,.green,.blue]),b=try ImageFramesVerification.sequence(type:"com.compuserve.gif" as CFString,colors:[.blue,.red])
        let left=root.appendingPathComponent("original first.gif"),right=root.appendingPathComponent("other 雪.gif")
        try a.write(to:left);try b.write(to:right)
        let repo=GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for(key,value)in[("user.name","Overlay inspection QA"),("user.email","overlay@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_ = try await repo.run(["config",key,value])}
        try await repo.stage([left.lastPathComponent,right.lastPathComponent]);_ = try await repo.commit(message:"private image inputs")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let owner=FileComparisonWindowController(images:try ImageFileComparison(base:left,destination:right),permissions:[],preferences:prefs)
        guard let window=owner.window else{throw Failure(message:"Missing native image window")}
        window.alphaValue=0;window.setFrameOrigin(.init(x:-12000,y:-12000));window.setContentSize(.init(width:920,height:640));window.orderFront(nil)
        let parent=owner.model,model=parent.imageViewerModel
        var sheet:NSWindow?,endpointControls:[Int:NSColor]=[:]
        func cleanup()async throws{
            if let sheet,window.attachedSheet===sheet{window.endSheet(sheet,returnCode:.abort);sheet.orderOut(nil)}
            owner.close();model.retire()
            try await wait("Overlay timer/owned window did not retire"){ImageComparisonViewModel.activeBlinkTimers==0 && window.attachedSheet==nil && !window.isVisible}
        }
        func controls()->[NSView]{window.contentView.map(descendants) ?? []}
        func alphaButton()throws->ImageComparisonAlphaButton{guard let button=controls().compactMap({$0 as? ImageComparisonAlphaButton}).first else{throw Failure(message:"Native alpha button missing")};return button}
        func slider()throws->ImageComparisonAlphaSlider{guard let slider=controls().compactMap({$0 as? ImageComparisonAlphaSlider}).first else{throw Failure(message:"Native alpha slider missing")};return slider}
        func frameButtons()->[NSButton]{controls().compactMap{$0 as? NSButton}.filter{($0.accessibilityLabel() ?? "").hasPrefix("Next image") || ($0.accessibilityLabel() ?? "").hasPrefix("Play images")}}
        func canvas()throws->NSView{guard let value=controls().compactMap({$0 as? ImageComparisonScrollView}).first?.documentView else{throw Failure(message:"Overlay canvas missing")};return value}
        func endpoint(_ component:Int)throws{
            guard let expected=endpointControls[component] else{throw Failure(message:"Missing independent native endpoint control")}
            let color=ImageFramesVerification.pixel(try canvas()),channels=[color.redComponent,color.greenComponent,color.blueComponent],control=[expected.redComponent,expected.greenComponent,expected.blueComponent]
            try require(zip(channels,control).allSatisfy{abs($0-$1)<0.015},"Blink endpoint differs from its independently displayed source in the same native color profile: actual=\(channels), expected=\(control)")
        }
        do{
            parent.load()
            try await wait("Image inputs/key owner did not load"){window.contentView?.layoutSubtreeIfNeeded();return !parent.busy && parent.imageComparison != nil && (window as? ImageComparisonKeyRouting)?.imageKeyModel === model && frameButtons().count>=4}
            try require(window.contentMinSize.width>=800 && window.contentMinSize.height>=440,"Hosting layout replaced the comparison window minimum: \(window.contentMinSize)")
            // NSColor.red/blue pass through GIF encoding and the current display
            // profile. Capture each independently displayed input before overlay;
            // assuming device RGB(1,0,0) would reject a valid calibrated red.
            for(component,label)in[(0,"Base image"),(2,"Destination image")]{
                guard let view=controls().compactMap({$0 as? ImageComparisonScrollView}).compactMap({$0.documentView}).first(where:{$0.accessibilityLabel()==label}) else{throw Failure(message:"Missing independent source pane "+label)}
                endpointControls[component]=ImageFramesVerification.pixel(view)
            }
            let red=endpointControls[0]!,blue=endpointControls[2]!
            try require(max(abs(red.redComponent-blue.redComponent),abs(red.blueComponent-blue.blueComponent))>0.5,"Independent input controls must have distinct colors")
            let retainedNext=try {()->NSButton in guard let value=frameButtons().first(where:{$0.accessibilityLabel()=="Next image (Base)"}) else{throw Failure(message:"Original Next control missing")};return value}()
            model.togglePlayback(base:true);try require(!model.playing.isEmpty,"Initial frame playback unavailable")
            model.perform(.overlay)
            try await wait("Overlay did not stop/hide competing players"){window.contentView?.layoutSubtreeIfNeeded();return model.playing.isEmpty && frameButtons().isEmpty && model.alphaControlAllowed && (try? alphaButton().isEnabled)==true}
            let startFrames=[model.currentImage(base:true)!.frameIndex,model.currentImage(base:false)!.frameIndex]
            model.stepImage(base:true,forward:true);model.togglePlayback(base:true);retainedNext.performClick(nil)
            try require([model.currentImage(base:true)!.frameIndex,model.currentImage(base:false)!.frameIndex]==startFrames && model.playing.isEmpty,"Overlay admitted a competing or retained player action")
            // Restore exact source frames before pixel controls. Input replacement
            // itself is a production timer-retirement boundary.
            parent.load()
            try await wait("Replacement alpha controls not enabled"){window.contentView?.layoutSubtreeIfNeeded();return !parent.busy && model.currentImage(base:true)?.frameIndex==0 && model.currentImage(base:false)?.frameIndex==0 && model.alphaControlAllowed && (try? alphaButton().isEnabled)==true}
            var button=try alphaButton(),channel=try slider()
            try require(button.image != nil && channel.numberOfTickMarks==17 && channel.allowsTickMarkValuesOnly,"Source icon/channel positions missing")
            let shortHeight=channel.bounds.height
            try require(shortHeight>240,"Alpha channel remains a fixed short slider: \(shortHeight)")
            window.setContentSize(.init(width:920,height:920))
            try await wait("Alpha channel did not follow native pane resize"){window.contentView?.layoutSubtreeIfNeeded();return ((try? slider().bounds.height) ?? 0) > shortHeight+180}
            try require(window.contentMinSize.width>=800 && window.contentMinSize.height>=440,"Resizing replaced the comparison minimum: \(window.contentMinSize)")
            channel=try slider();channel.setAccessibilityValue(25)
            try await wait("Slider did not publish live source percentage help"){window.contentView?.layoutSubtreeIfNeeded();return model.alpha==0.25 && channel.toolTip=="25% alpha" && (try? alphaButton().toolTip?.hasPrefix("25% alpha"))==true}
            button=try alphaButton();button.performClick(nil)
            try require(model.alpha==0 && !model.alphaBlinking,"Single click must stop and toggle nonzero alpha to zero")
            try endpoint(0)
            let started=Date();try doubleClick(button)
            try require(model.alphaBlinking && model.alpha==0,"Double click must arm timer without an immediate second toggle")
            try await Task.sleep(nanoseconds:220_000_000)
            try require(model.alpha==0,"Automatic blend toggled before its one-second source interval")
            try await wait("Automatic alpha did not reach second image"){window.contentView?.layoutSubtreeIfNeeded();return model.alpha==1 && button.state == .on && button.isHighlighted}
            try require(Date().timeIntervalSince(started)>=0.8,"Blink clock ignored source interval")
            try endpoint(2)
            try await wait("Automatic alpha did not return to first image"){window.contentView?.layoutSubtreeIfNeeded();return model.alpha==0}
            try endpoint(0)
            channel.setAccessibilityValue(25)
            try require(model.alphaBlinking && model.alpha==0.25,"Source slider adjustment unexpectedly stopped its active blink")
            button.performClick(nil)
            try await wait("Single click did not release automatic timer"){!model.alphaBlinking && ImageComparisonViewModel.activeBlinkTimers==0}
            try require(model.alpha==0,"Single click stop must still apply the source toggle")
            button.performClick(nil);try require(model.alpha==1,"Second manual click must toggle zero back to one")
            try doubleClick(button);model.perform(.blend)
            let xorAlpha=model.alpha
            try await wait("XOR retained hidden alpha clock/controls"){window.contentView?.layoutSubtreeIfNeeded();return !model.blendAlpha && !model.alphaBlinking && ImageComparisonViewModel.activeBlinkTimers==0 && !controls().contains{$0 is ImageComparisonAlphaButton}}
            button.performClick(nil);try doubleClickIfAttached(button)
            try require(model.alpha==xorAlpha && !model.alphaBlinking,"Removed alpha control mutated XOR state")
            model.perform(.blend)
            try await wait("Returning from XOR did not restore idle controls"){window.contentView?.layoutSubtreeIfNeeded();return (try? alphaButton().isEnabled)==true}
            button=try alphaButton();try require(!model.alphaBlinking && model.alpha==xorAlpha,"Returning from XOR silently restarted blinking or reset alpha")
            try doubleClick(button)
            let ownedSheet=NSWindow(contentRect:.init(x:0,y:0,width:200,height:100),styleMask:.titled,backing:.buffered,defer:false)
            ownedSheet.alphaValue=0;ownedSheet.setFrameOrigin(.init(x:-12000,y:-12000));sheet=ownedSheet
            window.beginSheet(ownedSheet,completionHandler:{_ in})
            try await wait("Owned sheet did not suspend both image timer families"){!model.alphaBlinking && model.playing.isEmpty && ImageComparisonViewModel.activeBlinkTimers==0}
            let modalAlpha=model.alpha;button.performClick(nil);try doubleClick(button)
            try require(model.alpha==modalAlpha && !model.alphaBlinking,"Modal owner admitted retained alpha action")
            window.endSheet(ownedSheet,returnCode:.cancel);ownedSheet.orderOut(nil)
            try await wait("Owned sheet failed to detach"){window.attachedSheet==nil}
            try require(!model.alphaBlinking,"Modal dismissal restarted hidden work")
            try doubleClick(button);parent.busy=true
            try await wait("Busy owner did not fence the next timer callback"){!model.alphaBlinking && ImageComparisonViewModel.activeBlinkTimers==0}
            parent.busy=false;let ownerRestoredAlpha=model.alpha
            do{try await wait("Owner did not become available"){window.contentView?.layoutSubtreeIfNeeded();return model.alphaControlAllowed && (try? alphaButton().isEnabled)==true}}
            catch{throw Failure(message:"Owner did not become available: interaction=\(model.interactionAllowed), alphaAllowed=\(model.alphaControlAllowed), commands=\(model.commandsAllowed()), overlay=\(model.overlay), blend=\(model.blendAlpha), busy=\(parent.busy), context=\(parent.contextCommandsAllowed), imageCommands=\(parent.imageCommandsAllowed), keyModel=\((window as? ImageComparisonKeyRouting)?.imageKeyModel === model), keysRetired=\((window as? ImageComparisonKeyRouting)?.imageKeysRetired ?? true), sheet=\(window.attachedSheet != nil), controls=\(controls().compactMap{$0 as? ImageComparisonAlphaButton}.map{"enabled=\($0.isEnabled),target=\($0.target != nil),window=\($0.window === window)"})") }
            try require(model.alpha==ownerRestoredAlpha && !model.alphaBlinking,"Re-enabling the native control must not change alpha or restart its clock")
            button=try alphaButton();try doubleClick(button)
            try require(model.dropFile(right,base:false),"Actual image preview replacement refused")
            try await wait("Replacement did not retire clock and drain read"){!model.receivingDrop && !model.alphaBlinking && ImageComparisonViewModel.activeBlinkTimers==0 && ImageComparisonViewModel.activeFileReads==0}
            try require(model.droppedFiles[false]?.bytes==b,"Dropped preview replaced original encoded input")
            parent.load();try await wait("Reload failed after preview"){window.contentView?.layoutSubtreeIfNeeded();return !parent.busy && model.droppedFiles.isEmpty && model.alphaControlAllowed}
            model.perform(.overlay)
            try await wait("Leaving overlay did not restore source player controls"){window.contentView?.layoutSubtreeIfNeeded();return !model.overlay && frameButtons().count>=4}
            model.togglePlayback(base:true);try require(!model.playing.isEmpty,"Frame playback did not return after leaving overlay")
            model.perform(.overlay);try require(model.playing.isEmpty,"Re-entering overlay did not stop frame playback")
            try await wait("Final alpha control missing"){window.contentView?.layoutSubtreeIfNeeded();return (try? alphaButton().isEnabled)==true}
            if ProcessInfo.processInfo.environment["TURTLEGIT_IMAGE_TOOLBAR_CAPTURE"] != nil{
                try await capture(window)
            }
            button=try alphaButton();try doubleClick(button)
            try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateNow,"A display-only blink should not block ordinary Quit")
            NotificationCenter.default.post(name:NSApplication.willTerminateNotification,object:NSApp)
            try await wait("Accepted Quit failed to retire native clock"){!model.alphaBlinking && ImageComparisonViewModel.activeBlinkTimers==0}
            let quitAlpha=model.alpha;button.performClick(nil);try doubleClick(button)
            try require(model.alpha==quitAlpha && !model.alphaBlinking,"A terminated timer owner accepted a retained control")
            try await cleanup()
            let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout
            try require(finalHead==head && (try Data(contentsOf:root.appendingPathComponent(".git/index")))==index && (try Data(contentsOf:left))==a && (try Data(contentsOf:right))==b,"Overlay controls changed Git/index/original image bytes")
            print("PASS: actual overlay native double-click/pressed1sblink, manual stop, resized17-position slider/livehelp, frame/XOR/sheet/busy/drop/reload/Quit ownership; original GIFs and Git bytes unchanged")
        }catch{try? await cleanup();throw error}
    }
    private static func doubleClickIfAttached(_ button:ImageComparisonAlphaButton)throws{if button.window != nil{try doubleClick(button)}}
}
