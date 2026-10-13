import AppKit
import TurtleGitCore

@main struct BlameMenuVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func wait(_ condition:@escaping ()->Bool) async throws {
        for _ in 0..<1000 { if condition() { return };try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Blame menu did not settle")
    }
    @MainActor static func descendants(_ view:NSView)->[NSView] { [view]+view.subviews.flatMap(descendants) }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Blame menus failed: \(error)\n",stderr);exit(1) } }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Menus QA"),("user.email","menus@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] { _ = try await repo.run(["config",key,value]) }
        let text="int value = 42;\n// needle 雪\n",file=root.appendingPathComponent("menus.cpp")
        try Data(text.utf8).write(to:file);try await repo.stage(["menus.cpp"]);_ = try await repo.commit(message:"Menu baseline")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let name="TurtleGit.BlameMenus.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:name)!
        defer { prefs.removePersistentDomain(forName:name) }
        try Data("Mapped Menus <mapped@example.invalid> Menus QA <menus@example.invalid>\n".utf8).write(to:root.appendingPathComponent(".mailmap"))
        let globals=GitBlamePreferences.load(),findGlobals=GitBlameFindPreferences.load()
        let owner=BlameWindowController(repository:repo,access:nil,path:"menus.cpp",revision:"HEAD",options:GitBlameOptions(),preferences:prefs)
        defer { owner.close() }
        let window=owner.window!,model=owner.model
        window.contentView?.layoutSubtreeIfNeeded()
        func source()->NSTextView? { descendants(window.contentView!).compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel()=="Blame source text" } }
        try await wait { !model.busy && !model.syntaxWorking && source()?.string==text }
        let layout = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/GraphLayout/graph-layout")
        let graph = RevisionGraphWindowModel(repository: repo, access: nil, preferences: prefs, layoutExecutable: layout)
        defer { graph.invalidate() }
        var copied = ""; model.writeClipboard = { copied = $0 }
        for enabled in [false, true] {
            prefs.set(enabled, forKey: "UseMailmap")
            let author = enabled ? "Mapped Menus" : "Menus QA"
            model.reload(); graph.load()
            try await wait { !model.busy && !graph.busy }
            try require(model.lines.first?.author == author, "Annotation identity disagrees with history mailmap policy")
            try require(model.historyEntries.first?.author == author, "Blame history ignored private mailmap policy")
            try require(graph.nodes.first?.author == author, "Graph ignored private mailmap policy")
            model.copyLogMessage(model.historyEntries.first!.hash)
            try await wait { !model.copyingLog }
            try require(copied.contains("Author: " + author + " <"), "Copied Blame Log ignored mailmap policy")
        }
        var focus:NSWindow?=window
        let context=BlameMenuContext(keyWindow:{ focus });context.refresh()
        try require(context.focused && context.available && !context.allowed(.nextChange),"Initial focus/next-change menu gates")
        let selected=(text as NSString).range(of:"雪");source()!.setSelectedRange(selected)
        context.perform(.toolbar);context.perform(.log);context.perform(.properties);context.perform(.statusBar)
        try await wait { !model.showToolbar && !model.showLog && !model.showProperties && !model.showStatusBar }
        try require(context.available && source()?.string==text && source()?.selectedRange()==selected,"Hidden panes disabled menus or lost source selection")
        try require(prefs.object(forKey:"Blame.ShowToolbar") as? Bool==false && prefs.object(forKey:"Blame.ShowLog") as? Bool==false,"Pane visibility not persisted")
        context.perform(.toolbar);context.perform(.log);context.perform(.properties);context.perform(.statusBar)
        try await wait { model.showToolbar && model.showLog && model.showProperties && model.showStatusBar }
        context.perform(.dark);context.refresh()
        let dark=context.checked(.dark)
        try require(model.darkOverride==dark && window.appearance != nil,"Dark mode did not apply/persist window override")
        context.perform(.find);try await wait { owner.findWindow != nil }
        let panel=owner.findWindow!
        try require(panel.window?.appearance?.name==window.appearance?.name,"Find panel did not follow owner appearance")
        focus=panel.window;context.refresh();try require(context.owner===owner && context.available,"Find focus lost active owner")
        panel.window?.performClose(nil);focus=window;context.refresh()
        context.followSystemAppearance();try require(model.darkOverride==nil && window.appearance==nil && prefs.object(forKey:"Blame.DarkMode")==nil,"Follow-system reset did not clear override")
        context.perform(.colorAge);try require(!model.colorAge && !context.checked(.colorAge) && prefs.object(forKey:"Blame.ColorAge") as? Bool==false,"Color Age check/persistence")
        context.perform(.colorAge);context.perform(.wrap);context.perform(.author)
        try await wait { model.wrapLongLines && !model.marginFields.contains(.author) }
        context.perform(.wrap);context.perform(.author)
        // Exercise actual menu routing through both supplemental codecs and a
        // platform legacy codec. ASCII remains byte-identical in all three.
        for page: UInt32 in [720, 858, 28606] {
            let codec = GitBlameEncoding.available.first { $0.windowsCodePage == page }!
            context.setEncoding(codec)
            try await wait { !model.busy && model.snapshot?.encoding.id == codec.id }
            context.refresh()
            try require(context.encoding?.id == codec.id, "Encoding check state did not follow selected codec")
        }
        context.setEncoding(nil); try await wait { !model.busy }; context.refresh()
        try require(source()?.string == text, "Automatic encoding did not restore Unicode text")
        model.openingDocument=true;context.refresh();let before=model.showToolbar
        context.perform(.toolbar);context.setEncoding(.utf16LE);try require(model.sourceEncoding == nil && !context.available && model.showToolbar==before,"Busy menu mutated a blocked owner")
        model.openingDocument=false
        let other=NSWindow(contentRect:NSRect(x:0,y:0,width:50,height:50),styleMask:.titled,backing:.buffered,defer:false);other.isReleasedWhenClosed=false
        defer { other.close() }
        focus=other;context.refresh();context.perform(.properties)
        try require(!context.focused && model.showProperties,"Unrelated focus changed a background Blame")
        focus=window;context.refresh();context.setDetection(.modifiedFiles)
        try await wait { !model.busy && model.detectionMode == .modifiedFiles }
        context.refresh();try require(!context.allowed(.completeLog) && !context.allowed(.followRenames),"Detection mode did not update source Log gates")
        context.setDetection(.disabled);try await wait { !model.busy };context.refresh()
        context.perform(.ignoreWhitespace);try await wait { !model.busy && model.ignoreWhitespace }
        try require(GitBlamePreferences.load(from:prefs).ignoreWhitespace && GitBlamePreferences.load()==globals,"Option menu wrote outside injected preferences")
        // A second owner receives its own routing and restores persisted pane choices.
        model.showToolbar=false;model.showLog=false;model.showProperties=false;model.showStatusBar=false
        let reopened=BlameWindowController(repository:repo,access:nil,path:"menus.cpp",revision:"HEAD",options:GitBlameOptions(),preferences:prefs)
        defer { reopened.close() }
        try await wait { !reopened.model.busy && !reopened.model.syntaxWorking }
        try require(!reopened.model.showToolbar && !reopened.model.showLog && !reopened.model.showProperties && !reopened.model.showStatusBar,"New viewer did not restore pane layout")
        focus=reopened.window;context.refresh();context.perform(.toolbar)
        try require(reopened.model.showToolbar && !model.showToolbar,"Menus targeted a background viewer")
        reopened.close();context.refresh();context.setEncoding(.utf16BE);try require(reopened.model.sourceEncoding == nil, "Retired owner accepted encoding");try require(!context.focused && !context.available,"Retired owner stayed in menu context")
        try require(GitBlameFindPreferences.load()==findGlobals,"Find menu wrote global query preferences")
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:root.appendingPathComponent(".git/index")),afterFile=try Data(contentsOf:file)
        try require(afterHead==head && afterIndex==index && afterFile==Data(text.utf8),"Menu operations changed repository state")
        print("Blame menus: current/Find/unrelated/second/retired window routing, busy/detection gates, persistent pane restoration, source selection retention, window/panel appearance/reset, private option defaults and exact HEAD/index/file preservation passed. Owned windows closed; full physical menu/VoiceOver acceptance remains open.")
    }
}
