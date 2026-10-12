import AppKit
import TurtleGitCore

@main struct BlameSourceEditorVerification {
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func wait(line: Int = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw NSError(domain:"Blame source did not settle at fixture line \(line)",code:1)
    }
    @MainActor static func main() async {
        do { try await verify() } catch { fputs("Blame source editor failed: \(error)\n",stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), git = URL(fileURLWithPath:CommandLine.arguments[2])
        let repo = GitRepository(root:root,executable:git)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Source QA"),("user.email","source@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] { _ = try await repo.run(["config",key,value]) }
        var lines = ["// Native source selection", "let snow = \"雪🦎\";\t// tabs", ""]
        for row in 4...90 { lines.append(row == 64 ? "let needle = \"search target\";" : "let value\(row) = \(row);") }
        lines[79] = "let longLine = \"" + String(repeating:"wide source text ",count:30) + "\";"
        lines.append("final line without LF")
        let path = "demo.swift", file = root.appendingPathComponent(path)
        let original = Data(("\u{feff}" + lines.joined(separator:"\r\n")).utf8)
        try original.write(to:file); try await repo.stage([path]); _ = try await repo.commit(message:"Add native source fixture")
        lines[11] = "let changed = \"second commit\";"
        let current = Data(("\u{feff}" + lines.joined(separator:"\r\n")).utf8)
        try current.write(to:file); try await repo.stage([path])
        _ = try await repo.run(["config","user.name","Reviewer QA"])
        _ = try await repo.commit(message:"Review source line")
        let head = try await repo.run(["rev-parse","HEAD"]).stdout, index = try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite = "TurtleGit.BlameSource.QA." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        let clipboard = NSPasteboard(name:NSPasteboard.Name(suite))
        clipboard.declareTypes([.string],owner:nil)
        defer { prefs.removePersistentDomain(forName:suite); clipboard.clearContents() }
        let controller = BlameWindowController(repository:repo,access:nil,path:path,revision:"HEAD",options:GitBlameOptions(),preferences:prefs)
        defer { controller.close() }
        let model = controller.model, window = controller.window!
        window.setContentSize(NSSize(width:1250,height:850)); model.presentation = GitBlamePresentation()
        window.contentView?.layoutSubtreeIfNeeded()
        func editor() -> NSTextView? { descendants(window.contentView!).compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel() == "Blame source text" } }
        try await wait { !model.busy && model.error == nil && editor()?.string == lines.joined(separator:"\n") }
        let text = editor()!, string = text.string as NSString
        precondition(!text.isEditable && text.isSelectable && text.string.hasSuffix("without LF") && !text.string.hasSuffix("\n"))
        precondition(model.marginFields == [.author])
        let unicode = string.range(of:"雪🦎"); text.setSelectedRange(unicode)
        try await wait { model.selectedSourceText?() == "雪🦎" }
        let wrote = text.writeSelection(to:clipboard,types:[.string])
        if !wrote || clipboard.string(forType:.string) != "雪🦎" {
            print("BLAME COPY DIAGNOSTIC", wrote, text.selectedRange(), clipboard.types ?? [], clipboard.string(forType:.string) ?? "nil"); fflush(stdout)
        }
        precondition(wrote && clipboard.string(forType:.string) == "雪🦎")
        model.onFind?()
        try await wait {
            window.childWindows?.contains { $0.title == "Find – TurtleGit Blame" && descendants($0.contentView!).compactMap { $0 as? NSTextField }.contains { $0.isEditable && $0.stringValue == "雪🦎" } } == true
        }
        window.childWindows?.first { $0.title == "Find – TurtleGit Blame" }?.close()
        let spanning = NSRange(location:0,length:string.range(of:"let value5").location)
        text.setSelectedRange(spanning); let copied = string.substring(with:spanning)
        precondition(text.writeSelection(to:clipboard,types:[.string]) && clipboard.string(forType:.string) == copied)
        for field in BlameMarginField.allCases { model.setMargin(field,visible:true) }
        try await wait {
            let tables = descendants(window.contentView!).compactMap { $0 as? NSTableView }
            return tables.contains { $0.tableColumns.contains { $0.identifier.rawValue == "filename" && !$0.isHidden } }
        }
        precondition(text.selectedRange() == spanning && text.string == lines.joined(separator:"\n"))
        model.presentation.fontSize = 15; model.presentation.tabSize = 8
        try await wait { text.textStorage?.attribute(.font,at:0,effectiveRange:nil) as? NSFont == model.sourceFont }
        precondition(text.selectedRange() == spanning)
        for appearance in [NSAppearance.Name.aqua,.darkAqua] {
            window.appearance = NSAppearance(named:appearance); window.contentView?.appearance = window.appearance
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds:30_000_000)
            precondition(text.selectedRange() == spanning && text.string == lines.joined(separator:"\n"))
        }
        let sourceScroll = text.enclosingScrollView!
        let gutter = descendants(window.contentView!).compactMap { $0 as? NSTableView }.first { $0.tableColumns.contains { $0.identifier.rawValue == "original" } }!
        let annotationScroll = gutter.enclosingScrollView!
        sourceScroll.contentView.scroll(to:NSPoint(x:100,y:400)); sourceScroll.reflectScrolledClipView(sourceScroll.contentView)
        try await wait { abs(sourceScroll.contentView.bounds.minY - annotationScroll.contentView.bounds.minY) < 0.5 }
        annotationScroll.contentView.scroll(to:NSPoint(x:0,y:200)); annotationScroll.reflectScrolledClipView(annotationScroll.contentView)
        try await wait { abs(sourceScroll.contentView.bounds.minY - annotationScroll.contentView.bounds.minY) < 0.5 }
        precondition(sourceScroll.contentView.bounds.minX >= 99)
        model.goToLine(42)
        try await wait { model.selectedSourceText?() == lines[41] }
        model.find = "needle"; model.matchCase = true; model.findLine(previous:false)
        try await wait { model.selectedSourceText?() == lines[63] + "\n" }
        var finds = 0, gotos = 0
        model.onFind = { finds += 1 }; model.onGoTo = { gotos += 1 }
        func key(_ character:String,_ code:UInt16,_ modifiers:NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:character,charactersIgnoringModifiers:character,isARepeat:false,keyCode:code)!
        }
        text.keyDown(with:key("f",3,.command)); text.keyDown(with:key("l",37,.command))
        precondition(finds == 1 && gotos == 1)
        text.selectAll(nil)
        precondition(text.writeSelection(to:clipboard,types:[.string]) && clipboard.string(forType:.string) == lines.joined(separator:"\n"))
        if CommandLine.arguments[3] == "blame-captures" {
            model.onFind = nil; model.setMargin(.date,visible:false); model.setMargin(.filename,visible:false)
            model.setMargin(.original,visible:false); model.setMargin(.logID,visible:false)
            model.presentation.fontSize = 12; model.showProperties = true
            model.goToLine(12); model.highlight(11,additive:false)
            try await capture(window)
        }
        controller.close(); clipboard.clearContents(); clipboard.setString("retired sentinel",forType:.string)
        precondition(!text.isSelectable && !text.writeSelection(to:clipboard,types:[.string]) && clipboard.string(forType:.string) == "retired sentinel")
        let afterHead = try await repo.run(["rev-parse","HEAD"]).stdout
        let afterIndex = try Data(contentsOf:root.appendingPathComponent(".git/index")), afterFile = try Data(contentsOf:file)
        precondition(afterHead == head && afterIndex == index && afterFile == current)
        let reopened = BlameWindowModel(repository:repo,access:nil,path:path,revision:"HEAD",labelDefaults:prefs)
        precondition(reopened.marginFields == model.marginFields)
        print("Blame native source: Unicode/multi-line/private clipboard, exact normalized BOM/CRLF/no-final-LF display, read-only and retired guards, persisted margin fields, range retention across font/themes, two-way scroll with independent horizontal position, Go To/Find selection and native keyboard routes passed. HEAD/index/file bytes retained; owned windows closed.")
    }
    @MainActor static func capture(_ window:NSWindow) async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let output = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/qa/blame-source-captures-2026-10-13")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        for (theme,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance = NSAppearance(named:theme); window.contentView?.appearance = window.appearance
            window.contentView?.layoutSubtreeIfNeeded(); window.center(); window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps:true)
            try await Task.sleep(nanoseconds:400_000_000)
            let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/sbin/screencapture")
            process.arguments = ["-x","-o","-l",String(window.windowNumber),output.appendingPathComponent("blame-source-editor-" + name + ".png").path]
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw NSError(domain:"Owned Blame capture unavailable",code:1) }
            window.orderOut(nil)
        }
    }
}
