// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@main struct MergeIgnoredVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool) async throws {
        for _ in 0..<2000 { if ready() {return};try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Ignored merge wait at line \(line)")
    }
    @MainActor static func editors(_ view:NSView) -> [NSTextView] { (view as? NSTextView).map{[$0]} ?? view.subviews.flatMap(editors) }
    @MainActor static func rgb(_ color:NSColor,appearance:NSAppearance) -> UInt32? {
        var value:UInt32?
        appearance.performAsCurrentDrawingAppearance { if let c = color.usingColorSpace(.sRGB) {value = UInt32((c.redComponent*255).rounded())<<16 | UInt32((c.greenComponent*255).rounded())<<8 | UInt32((c.blueComponent*255).rounded())} }
        return value
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath:CommandLine.arguments[1]),repo = GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Merge QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] { _ = try await repo.run(["config",key,value]) }
        let path = "merge 雪🦎.txt",file = root.appendingPathComponent(path)
        let base = "head 雪🦎\nvalue x y\nfooter\n",mine = "head 雪🦎\nvaluexy\nfooter\n",theirs = "head 雪🦎\nvalue x  y\nfooter\n"
        try Data(base.utf8).write(to:file);try Data("other\n".utf8).write(to:root.appendingPathComponent("other.txt"));try await repo.stage([path,"other.txt"]);_ = try await repo.commit(message:"base")
        _ = try await repo.run(["switch","-c","side"]);try Data(theirs.utf8).write(to:file);try await repo.stage([path]);_ = try await repo.commit(message:"theirs")
        _ = try await repo.run(["switch","main"]);try Data(mine.utf8).write(to:file);try await repo.stage([path]);_ = try await repo.commit(message:"mine")
        _ = try await repo.run(["merge","--no-edit","side"],successfulExitCodes:0...1)
        try Data("staged other\n".utf8).write(to:root.appendingPathComponent("other.txt"));try await repo.stage(["other.txt"]);try Data("working other\n".utf8).write(to:root.appendingPathComponent("other.txt"))
        let head = try await repo.run(["rev-parse","HEAD"]).stdout,index = try Data(contentsOf:root.appendingPathComponent(".git/index")),original = try Data(contentsOf:file)
        let suite = "TurtleGit.MergeIgnored.QA."+UUID().uuidString,prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite);MergePalette.reload() }
        MergeComparisonOptions(whitespace:.ignoreAll).save(to:prefs)
        var palette = MergeColorPreferences();palette.light[.conflicted] = .init(0x112233,0x456789);palette.dark[.conflicted] = .init(0xabcdef,0x234567);try palette.save(to:prefs);MergePalette.reload(defaults:prefs)
        let owner = TextConflictWindowController(repository:repo,access:nil,path:path,preferences:prefs,deferInitialLoad:true),model = owner.model
        defer {owner.close()};owner.window!.alphaValue = 0;owner.window!.orderFront(nil);model.beginTransferredDocument()
        try await wait { !model.busy && !model.preparing }
        try require(model.error == nil && model.document != nil && model.blocks.count == 1,"Ignored merge load failed: " + (model.error ?? "unexpected block count"))
        try require(model.blocks[0].isIgnored && model.result == mine && !MergeText.hasMarkers(model.result),"Ignored conflict was hidden or invented marker text")
        try require(model.resultStates == [.normal,.conflictedIgnored,.normal] && model.sourceComparison!.rows[1].mine.state == .conflictAdded,"Ignored source/result identities lost")
        try await wait { editors(owner.window!.contentView!).contains{$0.isEditable && $0.string == mine} }
        let view = editors(owner.window!.contentView!).first{$0.isEditable}!
        let finder = view as! MergeFindProviding
        try require(MergeFind.matches("value",in:finder.mergeFindLines,options:.init(modifiedOnly:true)).count == 1,"Modified Find skipped ignored conflict")
        for (name,dark) in [(NSAppearance.Name.aqua,false),(.darkAqua,true)] {
            let appearance = NSAppearance(named:name)!;owner.window!.appearance = appearance
            let offset = model.blocks[0].range.location
            try await wait { guard let color = view.textStorage?.attribute(.backgroundColor,at:offset,effectiveRange:nil) as? NSColor else {return false};return rgb(color,appearance:appearance) == palette.colors(.conflicted,dark:dark).background }
        }
        var asked = "", cancelled:Bool?, warningOwned = false
        model.confirmUnresolvedSave = { message in
            asked = message; warningOwned = model.busy && MergeRegexOperations.activeRequests > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel
            return false
        }
        model.save(markResolved:false) { cancelled = $0 }
        try await wait {cancelled != nil && !model.busy && view.isEditable}
        try require(cancelled == false && warningOwned && asked.contains("ignored by comparison options") && !model.busy,"Ignored Save did not warn/cancel")
        var blocked:Bool?;model.save(markResolved:true){blocked = $0}
        try require(blocked == false && Data(contentsOf:file) == original && Data(contentsOf:root.appendingPathComponent(".git/index")) == index,"Mark resolved bypassed ignored conflict")
        model.continueResolving();try await wait {model.canChooseConflict};try require(model.selectionRequest == model.blocks[0].range,"Ignored navigation has wrong range")
        try require(view.isEditable,"Result view still disabled after cancelled Save: editable=\(view.isEditable), sourceTools=\(model.sourceToolsAllowed), canChoose=\(model.canChooseConflict), busy=\(model.busy)")
        model.choose(.mine)
        do {try await wait {model.blocks.isEmpty && model.canUndo && view.string == mine}}
        catch {throw Failure(description:"Mine choice failed: blocks=\(model.blocks.count), undo=\(model.canUndo), editable=\(view.isEditable), result=\(model.result.debugDescription), view=\(view.string.debugDescription)")}

        try require(model.resultStates.contains(.resolved) && model.dirty,"Identical-byte Mine choice lost source modified state")
        model.undo();try await wait {model.blocks.first?.isIgnored == true && !model.dirty}
        model.redo();try await wait {model.blocks.isEmpty && model.dirty}
        var savedMine:Bool?;model.save(markResolved:false){savedMine = $0};try await wait {savedMine != nil && !model.busy && view.isEditable}
        try require(savedMine == true && !model.dirty && Data(contentsOf:file) == Data(mine.utf8) && Data(contentsOf:root.appendingPathComponent(".git/index")) == index,"Same-byte resolution Save lost savepoint or staged early")
        model.undo();try await wait {model.blocks.first?.isIgnored == true && model.dirty}
        // Undo clears selections. Select the restored conflict explicitly
        // before exercising the next footer choice, rather than relying on a
        // delayed native selection callback to revive the old footer target.
        model.continueResolving();try await wait {model.canChooseConflict};try require(model.canChooseConflict,"Restored ignored conflict cannot be selected")
        model.choose(.theirs);try await wait {model.blocks.isEmpty && model.result == theirs && view.string == theirs}
        model.undo();try await wait {model.blocks.first?.isIgnored == true && model.result == mine}
        model.redo();try await wait {model.blocks.isEmpty && model.result == theirs}
        var saved:Bool?;model.save(markResolved:true){saved = $0};try await wait {saved != nil && MergeRegexOperations.activeRequests == 0}
        try require(saved == true && model.retired,"Resolved ignored selection did not save/close")
        let staged = try await repo.run(["show",":"+path]).stdout,other = try await repo.run(["show",":other.txt"]).text,afterHead = try await repo.run(["rev-parse","HEAD"]).stdout
        try require(staged == Data(theirs.utf8) && Data(contentsOf:file) == Data(theirs.utf8) && other == "staged other\n" && Data(contentsOf:root.appendingPathComponent("other.txt")) == Data("working other\n".utf8) && afterHead == head,"Ignored resolution changed unrelated state or bytes")
        print("PASS: ignored conflict source/result paint, modified Find/navigation, Save warning and resolution gate, same-byte choices/Undo/Redo, exact staging and unrelated-state preservation; owned window closed")
    }
}
