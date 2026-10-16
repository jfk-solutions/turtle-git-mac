import AppKit
import TurtleGitCore

@main struct ToolbarRenderingDiagnostic {
    @MainActor static func image(_ image:NSImage?) -> String {
        guard let image,let bytes=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:bytes) else {return "none"}
        var alpha:CGFloat=0,colors=0
        for y in 0..<bitmap.pixelsHigh {for x in 0..<bitmap.pixelsWide {if let c=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.sRGB) {alpha=max(alpha,c.alphaComponent);if c.alphaComponent>0.5 && max(c.redComponent,c.greenComponent,c.blueComponent)-min(c.redComponent,c.greenComponent,c.blueComponent)>0.15 {colors+=1}}}}
        return "pixels=\(bitmap.pixelsWide)x\(bitmap.pixelsHigh), maxAlpha=\(alpha), colored=\(colors), template=\(image.isTemplate)"
    }
    @MainActor static func views(_ view:NSView,depth:Int=0) {
        let name=String(describing:type(of:view))
        if name.contains("Toolbar") || view is NSButton || view.alphaValue != 1 || view.layer?.opacity != nil && view.layer?.opacity != 1 {
            let control=view as? NSControl
            print("VIEW \(depth) \(name), alpha=\(view.alphaValue), layer=\(String(describing:view.layer?.opacity)), presentation=\(String(describing:view.layer?.presentation()?.opacity)), enabled=\(String(describing:control?.isEnabled)), cell=\(String(describing:control?.cell?.isEnabled)), action=\(control?.action?.description ?? "none"), label=\(view.accessibilityLabel() ?? "none"), image=\(image((view as? NSButton)?.image))")
        }
        for child in view.subviews { views(child,depth:depth+1) }
    }
    @MainActor static func dump(_ owner:FileComparisonWindowController,name:String,folder:URL) async throws {
        let window=owner.window!,bar=owner.editorToolbar!
        window.alphaValue=1;window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        try await Task.sleep(nanoseconds:800_000_000);bar.refresh();window.displayIfNeeded()
        print("PHASE \(name): active=\(NSApp.isActive), key=\(window.isKeyWindow), alpha=\(window.alphaValue)")
        for item in bar.toolbar.items {print("ITEM \(item.label): enabled=\(item.isEnabled), custom=\(String(describing:item.view.map{type(of:$0)})), \(image(item.image)), ownViewImage=\(image((item.view as? NSButton)?.image))")}
        print("ORIGINAL Open: \(image(MenuIcon.mergeOpen.image(size:20)))")
        if let root=window.contentView?.superview {views(root)}
        let capture=Process();capture.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");capture.arguments=["-x","-o","-l",String(window.windowNumber),folder.appendingPathComponent(name+".png").path]
        try capture.run();capture.waitUntilExit();print("CAPTURE \(name): status=\(capture.terminationStatus), visible=\(window.isVisible), number=\(window.windowNumber)");fflush(stdout)
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.accessory)
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),suite="TurtleGit.ToolbarDiagnostic."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs)
        let a=folder.appendingPathComponent("base.txt"),b=folder.appendingPathComponent("mine.txt")
        try Data("head\nold\ntail\n".utf8).write(to:a);try Data("head\nnew\ntail\n".utf8).write(to:b)
        let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:a,destination:b),permissions:[],preferences:prefs)
        defer {(owner.replacementOwner?.current ?? owner).close()}
        owner.window!.orderFront(nil);owner.model.load();try await TwoPaneEngineVerification.settled(owner.model)
        try await dump(owner,name:"initial",folder:folder)
        owner.model.setToolbarVisible(false);owner.editorToolbar!.refresh()
        try owner.replaceEditor(.compare(base:a,mine:b,single:false),permissions:[])
        let replacement=owner.replacementOwner!.current as! FileComparisonWindowController
        try await TwoPaneEngineVerification.settled(replacement.model)
        replacement.model.setToolbarVisible(true);replacement.editorToolbar!.refresh()
        try await dump(replacement,name:"replacement",folder:folder)
        replacement.window!.toolbarStyle = .unified;replacement.window!.toolbarStyle = .expanded
        try await dump(replacement,name:"style-reset",folder:folder)
        replacement.window!.toolbar = nil
        try await Task.sleep(nanoseconds:20_000_000)
        replacement.window!.toolbar = replacement.editorToolbar!.toolbar
        try await dump(replacement,name:"reattach",folder:folder)
        func invalidate(_ view:NSView) {view.needsDisplay=true;view.layer?.setNeedsDisplay();for child in view.subviews {invalidate(child)}}
        if let root=replacement.window!.contentView?.superview {invalidate(root)}
        try await dump(replacement,name:"redraw",folder:folder)
        print("PASS: owned toolbar rendering diagnostic completed")
    }
}
