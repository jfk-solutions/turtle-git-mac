import AppKit
import TurtleGitCore

@main struct BlameWrapVerification {
    @MainActor static func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
    @MainActor static func wait(line:Int = #line,_ ready:()->Bool) async throws {
        for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw NSError(domain:"Blame wrap did not settle at \(line)",code:1)
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Blame wrap failed: \(error)\n",stderr);exit(1) } }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Wrap QA"),("user.email","wrap@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        var lines=["// Native wrapping and annotation alignment","const char* description = \""+String(repeating:"Unicode 雪🦎 and word wrapping ",count:24)+"\";"]
        for row in 3...80 { lines.append("int value\(row) = \(row);") }
        let text=lines.joined(separator:"\n")+"\n",file=root.appendingPathComponent("wrap.cpp")
        try Data(text.utf8).write(to:file);try await repo.stage(["wrap.cpp"]);_ = try await repo.commit(message:"Add wrapped source")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.BlameWrap.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        let clipboard=NSPasteboard(name:NSPasteboard.Name(suite));clipboard.declareTypes([.string],owner:nil)
        defer { prefs.removePersistentDomain(forName:suite);clipboard.clearContents() }
        let controller=BlameWindowController(repository:repo,access:nil,path:"wrap.cpp",revision:"HEAD",options:GitBlameOptions(),preferences:prefs)
        defer { controller.close() }
        let model=controller.model,window=controller.window!
        window.setContentSize(NSSize(width:1250,height:800));window.contentView?.layoutSubtreeIfNeeded()
        func editor()->NSTextView? { descendants(window.contentView!).compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel()=="Blame source text" } }
        func margin()->NSTableView? { descendants(window.contentView!).compactMap { $0 as? NSTableView }.first { $0.tableColumns.contains { $0.identifier.rawValue=="original" } } }
        try await wait { !model.busy && !model.syntaxWorking && model.syntaxError==nil && editor()?.string==text && margin()?.numberOfRows==lines.count }
        let view=editor()!,table=margin()!,source=text as NSString,scroll=view.enclosingScrollView!
        let originalHeight=table.rect(ofRow:1).height
        precondition(!model.wrapLongLines && scroll.hasHorizontalScroller)
        let selected=source.range(of:"Unicode 雪🦎");view.setSelectedRange(selected)
        model.setWrapLongLines(true)
        try await wait { !scroll.hasHorizontalScroller && table.rect(ofRow:1).height > originalHeight*2 }
        precondition(view.selectedRange()==selected && view.string==text && !view.isEditable && prefs.bool(forKey:"Blame.WrapLongLines"))
        precondition(view.writeSelection(to:clipboard,types:[.string]) && clipboard.string(forType:.string)=="Unicode 雪🦎")
        func glyphRect(_ range:NSRange)->NSRect {
            let glyphs=view.layoutManager!.glyphRange(forCharacterRange:range,actualCharacterRange:nil)
            return view.layoutManager!.lineFragmentRect(forGlyphAt:glyphs.location,effectiveRange:nil)
        }
        let third=source.range(of:lines[2])
        do { try await wait { abs(glyphRect(third).minY-table.rect(ofRow:2).minY)<1 } } catch { fputs("Alignment geometry: source=\(glyphRect(third)) row1=\(table.rect(ofRow:1)) row2=\(table.rect(ofRow:2)) spacing=\(table.intercellSpacing)\n",stderr);throw error }
        let wide=table.rect(ofRow:1).height
        window.setContentSize(NSSize(width:930,height:800));window.contentView?.layoutSubtreeIfNeeded()
        do { try await wait { table.rect(ofRow:1).height > wide } } catch { fputs("Resize geometry: window=\(window.frame) source=\(view.frame) viewport=\(scroll.contentSize) wide=\(wide) row=\(table.rect(ofRow:1)) container=\(view.textContainer!.containerSize)\n",stderr);throw error }
        precondition(view.selectedRange()==selected)
        do { try await wait { abs(glyphRect(third).minY-table.rect(ofRow:2).minY)<1 } } catch { fputs("Alignment geometry: source=\(glyphRect(third)) row1=\(table.rect(ofRow:1)) row2=\(table.rect(ofRow:2)) spacing=\(table.intercellSpacing)\n",stderr);throw error }
        // A pointer on a continuation fragment addresses the same logical line.
        let y=table.rect(ofRow:1).minY+originalHeight*1.5
        let point=view.convert(NSPoint(x:20,y:y),to:nil)
        let event=NSEvent.mouseEvent(with:.rightMouseDown,location:point,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        view.rightMouseDown(with:event);precondition(model.selection==2)
        // Finish the hidden context lookup before capture makes the window visible.
        try await wait { !model.loadingParents }
        model.goToLine(3);try await wait { model.selectedSourceText?()==lines[2] }
        model.find="wrapping";model.findLine(previous:true)
        try await wait { model.selectedSourceText?()==lines[1]+"\n" }
        // Logical row navigation must use variable pixel offsets after wrapping.
        model.scrollSourceRowToTop?(2)
        try await wait { model.firstVisibleSourceRow?()==2 && abs(scroll.contentView.bounds.minY-table.rect(ofRow:2).minY)<1 }
        let anchor=model.firstVisibleSourceRow?()
        window.setContentSize(NSSize(width:1250,height:800));window.contentView?.layoutSubtreeIfNeeded()
        try await wait { table.rect(ofRow:1).height < wide+1 }
        precondition(model.firstVisibleSourceRow?()==anchor)
        for theme in [NSAppearance.Name.aqua,.darkAqua] {
            window.appearance=NSAppearance(named:theme);window.contentView?.appearance=window.appearance
            try await Task.sleep(nanoseconds:40_000_000)
            precondition(view.string==text && !view.isEditable)
        }
        if CommandLine.arguments[3]=="blame-wrap-captures" {
            model.goToLine(2);model.highlight(1,additive:false)
            try await capture(window)
        }
        let held=view.selectedRange()
        model.setWrapLongLines(false);try await wait { scroll.hasHorizontalScroller && abs(table.rect(ofRow:1).height-originalHeight)<1 }
        precondition(view.selectedRange()==held && view.string==text)
        let reopened=BlameWindowModel(repository:repo,access:nil,path:"wrap.cpp",revision:"HEAD",labelDefaults:prefs)
        precondition(!reopened.wrapLongLines)
        controller.close();try await wait { BlameWindowModel.activeSyntaxRequests==0 }
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:root.appendingPathComponent(".git/index")),afterFile=try Data(contentsOf:file)
        precondition(afterHead==head && afterIndex==index && afterFile==Data(text.utf8))
        print("Blame wrap: actual word-wrapped TextKit rows and aligned metadata, narrow/wide resize, source range/private clipboard, continuation context, Go To/Find, logical scroll anchor, light/dark, persisted off/default and no-wrap restoration passed. HEAD/index/file bytes retained; owned window retired.")
    }
    @MainActor static func capture(_ window:NSWindow) async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let output=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/qa/blame-wrap-captures-2026-10-13")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        for (theme,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:theme);window.contentView?.appearance=window.appearance;window.center();window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps:true);try await Task.sleep(nanoseconds:400_000_000)
            let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
            process.arguments=["-x","-o","-l",String(window.windowNumber),output.appendingPathComponent("blame-wrap-"+suffix+".png").path]
            try process.run();process.waitUntilExit();guard process.terminationStatus==0 else { throw NSError(domain:"Owned Blame wrap capture failed",code:1) }
            window.orderOut(nil)
        }
    }
}
