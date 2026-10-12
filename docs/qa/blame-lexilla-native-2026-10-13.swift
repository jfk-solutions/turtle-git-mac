import AppKit
import TurtleGitCore

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
        print("Native pinned Lexilla: actual C++ keyword/comment/Unicode styles, EnableLexer persistence, font-independent selection, dark HSL palette, read-only bytes, late result/retirement and Quit lifetime passed. Owned windows/helpers retired.")
    }
}
