// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor private final class BrandingMenuTarget:NSObject {
    @objc func invoke(_ sender:NSMenuItem){}
}
@MainActor private final class BrandingPreviewView:NSView {
    override var isFlipped:Bool {true}
    override func draw(_ dirtyRect:NSRect){NSColor.windowBackgroundColor.setFill();bounds.fill();super.draw(dirtyRect)}
}
@main struct BrandingNativeVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    @MainActor static func require(_ condition:Bool,_ message:String)throws{if !condition{throw Failure(description:message)}}
    @MainActor static func views(_ view:NSView?)->[NSView]{guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    @MainActor static func pixels(_ image:NSImage,size:Int)throws->Data {
        guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:size*4,bitsPerPixel:32),let context=NSGraphicsContext(bitmapImageRep:bitmap) else{throw Failure(description:"Icon bitmap unavailable")}
        NSGraphicsContext.saveGraphicsState();defer{NSGraphicsContext.restoreGraphicsState()};NSGraphicsContext.current=context
        context.imageInterpolation = .high
        image.draw(in:NSRect(x:0,y:0,width:size,height:size),from:.zero,operation:.copy,fraction:1,respectFlipped:false,hints:nil)
        return Data(bytes:bitmap.bitmapData!,count:bitmap.bytesPerRow*bitmap.pixelsHigh)
    }
    @MainActor static func same(_ actual:NSImage?,_ expected:NSImage,size:Int,message:String)throws {
        guard let actual else{throw Failure(description:message+": missing image")}
        try require(!actual.isTemplate,message+": custom colors became template tinted")
        try require(try pixels(actual,size:size)==pixels(expected,size:size),message+": pixels differ from custom shared512asset")
    }
    @MainActor static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),app=URL(fileURLWithPath:CommandLine.arguments[2]),captures=URL(fileURLWithPath:CommandLine.arguments[3])
        let suite="TurtleGit.Branding.Native."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        DialogGeometry.install(preferences:prefs)
        defer{DialogGeometry.install(preferences:.standard);prefs.removePersistentDomain(forName:suite)}
        let shared=app.appendingPathComponent("Contents/Frameworks/TurtleGitCore.framework/Resources/Icons/TurtleGitApplication.png")
        guard let expected=NSImage(contentsOf:shared) else{throw Failure(description:"Bundled custom shared512image missing")}
        let source=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/TurtleGitCore/Resources/Icons/TurtleGitApplication.png")
        try require(try Data(contentsOf:source)==Data(contentsOf:shared),"Built framework custom sharedasset is stale")
        var proposed=NSRect(x:0,y:0,width:512,height:512)
        let cg=expected.cgImage(forProposedRect:&proposed,context:nil,hints:nil)
        try require(cg?.width==512 && cg?.height==512,"Shared brandasset no longer512pixels")
        let blameResource=app.appendingPathComponent("Contents/Frameworks/TurtleGitCore.framework/Resources/Icons/TurtleGitBlame.png")
        guard let blameArtwork=NSImage(contentsOf:blameResource) else{throw Failure(description:"Bundled custom attribution artwork missing")}
        try require(try Data(contentsOf:blameResource)==Data(contentsOf:URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/TurtleGitCore/Resources/Icons/TurtleGitBlame.png")),"Built attribution asset is stale")
        var owners:[NSWindowController]=[]
        let clipboard=NSPasteboard.withUniqueName()
        defer{owners.forEach{$0.close()};clipboard.releaseGlobally()}
        do {
            let target=BrandingMenuTarget(),snapshot=FinderSnapshot(roots:[root.path],states:[root.path:.normal])
            var settings=FinderMenuSettings(showIcons:true);settings.topLevelMask=0;settings.extendedOnlyMask=0
            let menu=FinderMenuBuilder.make(paths:[root],snapshot:snapshot,settings:settings,comparisonMark:nil,target:target,actionSelector:#selector(BrandingMenuTarget.invoke(_:)))
            guard let finder=menu.items.first(where:{$0.title=="TurtleGit" && $0.submenu != nil}) else{throw Failure(description:"Actual Finder builder has no root menu")}
            try same(finder.image,expected,size:16,message:"Finder root branding")
            let attributedFile=root.appendingPathComponent("owned-attribution.txt")
            try Data("private attribution menu fixture\n".utf8).write(to:attributedFile)
            let attributedSnapshot=FinderSnapshot(roots:[root.path],states:[root.path:.normal,attributedFile.path:.modified])
            let attributedMenu=FinderMenuBuilder.make(paths:[attributedFile],snapshot:attributedSnapshot,settings:settings,comparisonMark:nil,target:target,actionSelector:#selector(BrandingMenuTarget.invoke(_:)))
            func flatten(_ menu:NSMenu)->[NSMenuItem]{menu.items.flatMap{[$0]+($0.submenu.map(flatten) ?? [])}}
            let blameItem=flatten(attributedMenu).first{($0.representedObject as? FinderMenuCommand)?.request.action == .blame}
            try require(blameItem != nil,"Actual Finder file menu has no Blame action")
            try same(blameItem?.image,blameArtwork,size:16,message:"Finder Blame custom attribution artwork")
            settings.showIcons=false
            let hidden=FinderMenuBuilder.make(paths:[root],snapshot:snapshot,settings:settings,comparisonMark:nil,target:target,actionSelector:#selector(BrandingMenuTarget.invoke(_:)))
            try require(hidden.items.first(where:{$0.title=="TurtleGit" && $0.submenu != nil})?.image==nil,"Finder icon preference ignored")
            let info=ApplicationAboutInformation(application:app,version:"Brand QA",build:"private")
            for name in [NSAppearance.Name.aqua,.darkAqua] {
                let appearance=NSAppearance(named:name)!
                var failure:Error?
                appearance.performAsCurrentDrawingAppearance {
                    do {
                        for size in [16,32,40,48,64,128,512] {
                            try same(MenuIcon.turtle.image(size:CGFloat(size)),expected,size:size,message:"MenuIcon.turtle \(name)/\(size)")
                            try same(MenuIcon.blame.image(size:CGFloat(size)),blameArtwork,size:size,message:"MenuIcon.blame \(name)/\(size)")
                            try same(MenuIcon.originalImage(resource:"TortoiseGitBlame",size:CGFloat(size)),blameArtwork,size:size,message:"Source Blame alias \(name)/\(size)")
                            try same(MenuIcon.originalImage(resource:"TurtleGitBlame",size:CGFloat(size)),blameArtwork,size:size,message:"Custom Blame alias \(name)/\(size)")

                            try same(MenuIcon.originalImage(resource:"TortoiseSmall",size:CGFloat(size)),expected,size:size,message:"TortoiseSmall alias \(name)/\(size)")
                        }
                    }catch{failure=error}
                };if let failure{throw failure}
                for tool in TurtleGitAboutTool.allCases {
                    try require(tool.artworkName==MenuIcon.turtle.rawValue,"Tool About retained upstream mascot: \(tool)")
                    try same(tool.artwork(size:48),expected,size:48,message:"About \(tool)")
                    let owner=TurtleGitAboutController(tool:tool,information:info);owners.append(owner)
                    owner.window?.alphaValue=0;owner.window?.setFrameOrigin(NSPoint(x:-12000,y:-12000));owner.window?.appearance=appearance
                    owner.clipboard=clipboard;owner.banner?.reduceMotion={true};owner.showWindow(nil);owner.window?.contentView?.layoutSubtreeIfNeeded()
                    if !tool.hasBanner {
                        let icons=views(owner.window?.contentView).compactMap{$0 as? NSImageView}.compactMap(\.image)
                        try require(!icons.isEmpty,"Actual \(tool) About has no native image view")
                        try same(icons.first,expected,size:48,message:"Actual \(tool) About header")
                    }else{try require(owner.banner != nil && owner.banner?.animationRunning==false,"About native banner missing or started background timer")}
                    owner.close()
                }
                var authAnswers=0
                let auth=GitAskpassWindowController(prompt:GitAskpassPrompt("Username for private branding fixture"),icon:NSImage(contentsOf:shared)){_ in authAnswers+=1}
                owners.append(auth);auth.window?.alphaValue=0;auth.window?.setFrameOrigin(NSPoint(x:-12000,y:-12000));auth.window?.appearance=appearance;auth.showWindow(nil)
                let authImage=views(auth.window?.contentView).compactMap{$0 as? NSImageView}.first?.image
                try same(authImage,expected,size:32,message:"Actual authentication header")
                try await capture(appearance:appearance,expected:expected,finder:finder.image!,auth:authImage!,directory:captures,name:name == .aqua ? "light":"dark",owners:&owners)
                auth.cancel.performClick(nil);try require(auth.finished && authAnswers==1,"Owned authentication fixture did not retire once")
            }
            // These SwiftUI consumers construct against private settings only.
            // Their shared40/48px resource is verified above; the preview plate
            // deliberately does not claim a full SwiftUI screen capture.
            let wizard=FirstStartWizardController(preferences:prefs),introduction=ApplicationIntroductionController(preferences:prefs)
            owners += [wizard,introduction]
            for owner in [wizard as NSWindowController,introduction]{owner.window?.alphaValue=0;owner.window?.setFrameOrigin(NSPoint(x:-12000,y:-12000));owner.showWindow(nil);try require(owner.window?.contentView != nil,"Shared branding consumer failed to construct")}
            wizard.close();introduction.close()
            try require(RepositoryAction.commit.icon == .commit && MenuIcon.normal.rawValue=="status-normal","Brand replacement changed command/status icon mapping")
            if let command=MenuIcon.commit.image(){try require(try pixels(command,size:32) != pixels(expected,size:32),"Command icon was replaced with application mascot")}
        }catch{owners.forEach{$0.close()};throw error}
        owners.forEach{$0.close()}
        for _ in 0..<1500 {
            if TurtleGitAboutController.activeReads==0 && FirstStartWizardModel.activeWrites==0 && GeneralGitSettingsModel.activeOperations==0 && GeneralGitSettingsModel.activeDialogs==0 && owners.allSatisfy({$0.window?.attachedSheet==nil && $0.window?.isVisible != true}){break}
            try await Task.sleep(nanoseconds:10_000_000)
        }
        try require(TurtleGitAboutController.activeReads==0 && FirstStartWizardModel.activeWrites==0 && GeneralGitSettingsModel.activeOperations==0 && GeneralGitSettingsModel.activeDialogs==0 && owners.allSatisfy({$0.window?.attachedSheet==nil && $0.window?.isVisible != true}),"Owned branding windows/work did not drain")
        print("PASS: native custom branding/shared alias/Finder root/all About/authentication consumers, light/dark native asset preview plates; private settings and owned windows cleaned")
    }
    @MainActor static func capture(appearance:NSAppearance,expected:NSImage,finder:NSImage,auth:NSImage,directory:URL,name:String,owners:inout[NSWindowController])async throws {
        let view=BrandingPreviewView(frame:NSRect(x:0,y:0,width:820,height:250))
        let window=NSWindow(contentRect:NSRect(x:-12000,y:-12000,width:820,height:250),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.alphaValue=0;window.appearance=appearance;window.contentView=view
        let controller=NSWindowController(window:window);owners.append(controller)
        let heading=NSTextField(labelWithString:"TurtleGit native asset preview — \(name)");heading.font = .boldSystemFont(ofSize:18);heading.frame=NSRect(x:18,y:12,width:780,height:28);view.addSubview(heading)
        let subheading=NSTextField(labelWithString:"Actual shared NSImage resources; this is not a full application or Finder screenshot.");subheading.frame=NSRect(x:18,y:42,width:780,height:22);view.addSubview(subheading)
        let samples:[(String,Int,NSImage)]=[("Finder16",16,finder),("Auth32",32,auth),("Wizard40",40,MenuIcon.turtle.image(size:40)!),("About48",48,TurtleGitAboutTool.application.artwork(size:48)!),("Alias64",64,MenuIcon.originalImage(resource:"TortoiseSmall",size:64)!),("App128",128,expected)]
        for(index,sample)in samples.enumerated(){
            let(labelText,size,image)=sample
            let icon=NSImageView(image:image);icon.imageScaling = .scaleProportionallyUpOrDown;icon.frame=NSRect(x:18+index*132,y:75,width:size,height:size);view.addSubview(icon)
            let label=NSTextField(labelWithString:labelText);label.frame=NSRect(x:18+index*132,y:214,width:120,height:20);view.addSubview(label)
        }
        controller.showWindow(nil);view.layoutSubtreeIfNeeded()
        guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else{throw Failure(description:"Native brand preview bitmap unavailable")}
        appearance.performAsCurrentDrawingAppearance{view.cacheDisplay(in:view.bounds,to:bitmap)}
        guard let png=bitmap.representation(using:.png,properties:[:]) else{throw Failure(description:"Native preview PNG unavailable")}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try png.write(to:directory.appendingPathComponent("branding-native-"+name+".png"));controller.close()
    }
}
