import AppKit
import TurtleGitCore

private final class BlameColorCalibrationView:NSView {
    let color:NSColor
    init(frame:NSRect,color:NSColor) { self.color=color;super.init(frame:frame) }
    required init?(coder:NSCoder) { fatalError() }
    override var isOpaque:Bool { true }
    override func draw(_ rect:NSRect) { color.setFill();bounds.fill() }
}
@main struct BlameLexillaVerification {
    @MainActor static func descendants(_ view:NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func wait(_ ready:()->Bool) async throws {
        for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw NSError(domain:"Blame Lexilla native did not settle",code:1)
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Blame Lexilla native failed: \(error)\n",stderr); exit(1) } }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Lexer QA"),("user.email","lexer@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        let text="int value = 42; // comment\nconst char* name = \"雪🦎\";\n"
        let file=root.appendingPathComponent("syntax.cpp");try Data(text.utf8).write(to:file);try await repo.stage(["syntax.cpp"]);_ = try await repo.commit(message:"Native lexical fixture")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.Lexilla.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        let controller=BlameWindowController(repository:repo,access:nil,path:"syntax.cpp",revision:"HEAD",options:GitBlameOptions(),preferences:prefs)
        defer { controller.close() }
        let model=controller.model,window=controller.window!
        window.contentView?.layoutSubtreeIfNeeded()
        func editor()->NSTextView? { descendants(window.contentView!).compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel()=="Blame source text" } }
        try await wait { !model.busy && !model.syntaxWorking && model.syntaxError==nil && editor()?.string==text && BlameWindowModel.activeSyntaxRequests==0 }
        let view=editor()!,source=text as NSString
        func color(_ offset:Int)->NSColor { (view.textStorage!.attribute(.foregroundColor,at:offset,effectiveRange:nil) as! NSColor).usingColorSpace(.sRGB)! }
        window.appearance=NSAppearance(named:.aqua);window.contentView?.appearance=window.appearance
        try await Task.sleep(nanoseconds:30_000_000)
        precondition(abs(color(0).blueComponent-128.0/255)<0.02 && color(0).redComponent<0.02)
        let comment=source.range(of:"// comment").location,unicode=source.range(of:"雪🦎")
        precondition(abs(color(comment).greenComponent-128.0/255)<0.02)
        view.setSelectedRange(unicode)
        model.setSyntaxEnabled(false);try await wait { !model.syntaxWorking }
        precondition(view.selectedRange()==unicode && view.string==text && prefs.object(forKey:"Blame.EnableLexer") as? Bool==false)
        model.setSyntaxEnabled(true);try await wait { !model.syntaxWorking && BlameWindowModel.activeSyntaxRequests==0 }
        precondition(view.selectedRange()==unicode && color(0).blueComponent>0.45)
        window.appearance=NSAppearance(named:.darkAqua);window.contentView?.appearance=window.appearance
        try await Task.sleep(nanoseconds:50_000_000)
        precondition(color(0).blueComponent>0.98 && color(0).redComponent>0.4 && view.selectedRange()==unicode && !view.isEditable)
        // A late provider ignores cancellation: closed owner still cannot paint
        // its output or expose errors, and Quit waits until it has settled.
        var pending:CheckedContinuation<BlameSyntaxResult,Error>?,token:OperationCancellation?
        let original=model.syntaxOperation
        model.syntaxOperation={ _,_,_,_,owned in
            token=owned;return try await withCheckedThrowingContinuation { pending=$0 }
        }
        model.presentation.tabSize += 1
        try await wait { pending != nil && model.syntaxWorking }
        controller.close()
        precondition(token?.isCancelled==true && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        let restored=try await original(text,"syntax.cpp",4,BlameSyntax.executable(),OperationCancellation())
        pending?.resume(returning:restored);pending=nil
        try await wait { BlameWindowModel.activeSyntaxRequests==0 }
        precondition(model.syntaxError==nil && !view.isSelectable && view.string==text)
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:root.appendingPathComponent(".git/index")),afterFile=try Data(contentsOf:file)
        precondition(afterHead==head && afterIndex==index && afterFile==Data(text.utf8))
        let html="<html>\n<script language=\"VBScript\">\nDim value\nvalue = \"雪🦎\"\n</script>\n</html>\n"
        let htmlFile=root.appendingPathComponent("embedded.html")
        try Data(html.utf8).write(to:htmlFile);try await repo.stage(["embedded.html"]);_ = try await repo.commit(message:"Embedded styles")
        let htmlHead=try await repo.run(["rev-parse","HEAD"]).stdout,htmlIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let embedded=BlameWindowController(repository:repo,access:nil,path:"embedded.html",revision:"HEAD",options:GitBlameOptions(),preferences:prefs)
        defer { embedded.close() }
        let embeddedWindow=embedded.window!,embeddedModel=embedded.model
        embeddedModel.presentation.fontName="Courier";embeddedModel.presentation.fontSize=14
        embeddedWindow.contentView?.layoutSubtreeIfNeeded()
        func embeddedEditor()->NSTextView? { descendants(embeddedWindow.contentView!).compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel()=="Blame source text" } }
        try await wait { !embeddedModel.busy && !embeddedModel.syntaxWorking && embeddedEditor()?.string==html && BlameWindowModel.activeSyntaxRequests==0 }
        let htmlView=embeddedEditor()!,offset=(html as NSString).range(of:"value =").location
        let fillKey=NSAttributedString.Key("TurtleGitBlameEOLFill")
        let expectedFont=NSFont(name:"Lucida Console",size:14) ?? NSFont(name:"Menlo",size:14)!
        let actualFont=htmlView.textStorage!.attribute(.font,at:offset,effectiveRange:nil) as! NSFont
        precondition(actualFont.familyName==expectedFont.familyName && actualFont.pointSize==14)
        let selectedHTML=(html as NSString).range(of:"雪🦎");htmlView.setSelectedRange(selectedHTML)
        func paintedTail(reference:NSColor? = nil)->NSColor {
            let manager=htmlView.layoutManager!,glyph=manager.glyphIndexForCharacter(at:offset)
            let fragment=manager.lineFragmentRect(forGlyphAt:glyph,effectiveRange:nil)
            let origin=htmlView.textContainerOrigin
            let area=NSRect(x:htmlView.bounds.maxX-20,y:fragment.midY+origin.y-2,width:4,height:4)
            // Cache rendering is color managed (including HDR on current macOS).
            // Compare to an independently painted reference in the same context,
            // rather than comparing encoded source RGB directly to display pixels.
            let calibration=reference.map { BlameColorCalibrationView(frame:area,color:$0) }
            if let calibration { htmlView.addSubview(calibration) }
            defer { calibration?.removeFromSuperview() }
            let bitmap=htmlView.bitmapImageRepForCachingDisplay(in:area)!
            htmlView.cacheDisplay(in:area,to:bitmap)
            return bitmap.colorAt(x:1,y:1)!.usingColorSpace(.sRGB)!
        }
        for theme in [NSAppearance.Name.aqua,.darkAqua] {
            embeddedWindow.appearance=NSAppearance(named:theme);embeddedWindow.contentView?.appearance=embeddedWindow.appearance
            try await Task.sleep(nanoseconds:50_000_000)
            let stored=htmlView.textStorage!.attribute(fillKey,at:offset,effectiveRange:nil) as! NSColor
            let pixel=paintedTail(),expected=paintedTail(reference:stored)
            print("Embedded tail pixels",theme,"calibrated expected",expected,"actual",pixel);fflush(stdout)
            precondition(abs(pixel.redComponent-expected.redComponent)<0.03 && abs(pixel.greenComponent-expected.greenComponent)<0.03 && abs(pixel.blueComponent-expected.blueComponent)<0.03)
            precondition(htmlView.selectedRange()==selectedHTML)
            if ProcessInfo.processInfo.environment["TURTLEGIT_CAPTURE_BLAME_EMBEDDED"]=="1",repo.executable.path=="/usr/bin/git" {
                NSApplication.shared.setActivationPolicy(.accessory)
                let output=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/qa/blame-embedded-captures-2026-10-13")
                try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
                embeddedWindow.setContentSize(NSSize(width:1120,height:700));embeddedWindow.center();embeddedWindow.makeKeyAndOrderFront(nil);NSApplication.shared.activate(ignoringOtherApps:true)
                try await Task.sleep(nanoseconds:300_000_000)
                let capture=Process();capture.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
                let suffix=theme == .aqua ? "light" : "dark"
                capture.arguments=["-x","-o","-l",String(embeddedWindow.windowNumber),output.appendingPathComponent("blame-embedded-"+suffix+".png").path]
                try capture.run();capture.waitUntilExit();precondition(capture.terminationStatus==0);embeddedWindow.orderOut(nil)
            }
        }
        embeddedModel.setWrapLongLines(true)
        try await wait { htmlView.enclosingScrollView?.hasHorizontalScroller==false }
        precondition(htmlView.selectedRange()==selectedHTML && htmlView.textStorage!.attribute(fillKey,at:offset,effectiveRange:nil) != nil)
        embeddedModel.setSyntaxEnabled(false);try await wait { !embeddedModel.syntaxWorking && htmlView.textStorage!.attribute(fillKey,at:offset,effectiveRange:nil)==nil }
        precondition(htmlView.textStorage!.attribute(fillKey,at:offset,effectiveRange:nil)==nil && htmlView.selectedRange()==selectedHTML)
        let disabledFont=htmlView.textStorage!.attribute(.font,at:offset,effectiveRange:nil) as! NSFont
        precondition(disabledFont.familyName==NSFont(name:"Courier",size:14)!.familyName)
        embeddedModel.setSyntaxEnabled(true);try await wait { !embeddedModel.syntaxWorking && BlameWindowModel.activeSyntaxRequests==0 && htmlView.textStorage!.attribute(fillKey,at:offset,effectiveRange:nil) != nil }
        precondition(htmlView.textStorage!.attribute(fillKey,at:offset,effectiveRange:nil) != nil && htmlView.string==html)
        embedded.close();try await wait { BlameWindowModel.activeSyntaxRequests==0 }
        let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout,finalIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let finalHTML=try Data(contentsOf:htmlFile)
        precondition(finalHead==htmlHead && finalIndex==htmlIndex && finalHTML==Data(html.utf8))
        print("Native pinned Lexilla: actual C++ keyword/comment/Unicode styles, EnableLexer persistence, font-independent selection, dark HSL palette, read-only bytes, late result/retirement and Quit lifetime passed. Owned windows/helpers retired.")
    }
}
