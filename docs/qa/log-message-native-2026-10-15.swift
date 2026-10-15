// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

@main struct LogMessageVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<1800 { if condition() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Log message did not settle at fixture line \(line)")
    }
    @MainActor static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    actor Gate {
        var token: OperationCancellation?, reply: CheckedContinuation<Void,Never>?
        func hold(_ token: OperationCancellation) async { self.token=token; await withCheckedContinuation { reply=$0 } }
        func started() -> Bool { reply != nil }
        func cancelled() -> Bool { token?.isCancelled == true }
        func release() { reply?.resume(); reply=nil }
    }
    @MainActor static func capture(_ owner: LogWindowController) async throws {
        guard let folder=ProcessInfo.processInfo.environment["TURTLEGIT_LOG_MESSAGE_CAPTURE"],let window=owner.window else { return }
        guard #available(macOS 14.4,*) else { throw Failure(description:"Screen capture unavailable") }
        window.setContentSize(NSSize(width:1120,height:780)); window.alphaValue=1; window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        if let split=views(window.contentView!).compactMap({$0 as? NSSplitView}).first(where:{!$0.isVertical && $0.arrangedSubviews.count==3}) {
            split.setPosition(250,ofDividerAt:0); split.setPosition(530,ofDividerAt:1)
        }
        defer { window.alphaValue=0 }
        for (theme,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:theme); window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds:250_000_000)
            let content=try await SCShareableContent.currentProcess
            guard let own=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else { throw Failure(description:"Missing owned Log compositor window") }
            let options=SCStreamConfiguration(); options.width=Int(window.frame.width*window.backingScaleFactor); options.height=Int(window.frame.height*window.backingScaleFactor); options.showsCursor=false; options.ignoreShadowsSingleWindow=true
            let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:own),configuration:options)
            try NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:folder).appendingPathComponent("log-message-"+suffix+".png"))
        }
    }
    @MainActor static func main() async {
        do { try await verify(); print("PASS: Log rich message source links/traits/highlights, visible hash navigation, selection and stale menu guards, private preferences and retired styling lifetime") }
        catch { fputs("Log message failed: \(error)\n",stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        _=NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]), repository=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        let suite="TurtleGit.LogMessage.QA."+UUID().uuidString, prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        prefs.set(false,forKey:"Gravatar"); prefs.set(false,forKey:"LogIncludeWorkingTreeChanges");prefs.set(false,forKey:"AsteriskLogPrefix"); prefs.set("Menlo",forKey:"LogFontName");prefs.set(13,forKey:"LogFontSize")
        _=try await repository.run(["init","-b","main"])
        for (key,value) in [("user.name","Log Message QA"),("user.email","log@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("bugtraq.logregex","issue #(\\d+)"),("bugtraq.url","https://tickets.invalid/%BUGID%")] { _=try await repository.run(["config",key,value]) }
        try Data("base\n".utf8).write(to:root.appendingPathComponent("sample.txt"));try await repository.stage(["sample.txt"]);_=try await repository.commit(message:"Base revision")
        let base=try await repository.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines), prefix=String(base.prefix(8))
        try Data("second\n".utf8).write(to:root.appendingPathComponent("sample.txt"));try await repository.stage(["sample.txt"])
        _=try await repository.commit(message:"Fix issue #42\n\nReferences \(prefix) in the visible history.\n *bold ^both^ end* and _underlined_ text\nhttps://example.invalid/project\nSigned-off-by: deadbeef <log@example.invalid>")
        let second=try await repository.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _=try await repository.run(["notes","add","-m","A note with issue #73",second])
        _=try await repository.run(["commit","--allow-empty","-m","Newest revision"])
        let head=try await repository.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let owner=LogWindowController(repository:repository,access:nil,labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false), model=owner.model
        defer { owner.close() }
        owner.window?.alphaValue=0;owner.window?.orderFront(nil)
        try await wait { !model.busy && model.entries.count==3 }
        model.select([second]); try await wait { !model.files.isEmpty }
        try await wait { views(owner.window!.contentView!).contains{$0 is LogMessageTextView} }
        let editor=views(owner.window!.contentView!).compactMap{$0 as? LogMessageTextView}.first!
        func links() -> [(NSRange,String)] {
            var found:[(NSRange,String)]=[]
            editor.textStorage?.enumerateAttribute(.link,in:NSRange(location:0,length:(editor.string as NSString).length)) { value,range,_ in if let value=value as? String {found.append((range,value))} }
            return found
        }
        try await wait { links().count>=4 && LogMessageView.Coordinator.activeOperations==0 }
        let coordinator=editor.coordinator!
        var opened:[URL]=[];coordinator.openURL={opened.append($0)}
        let content=editor.string as NSString
        let hashRange=content.range(of:prefix,range:NSRange(location:50,length:content.length-50)), issueRange=NSRange(location:content.range(of:"issue #42").location+7,length:2), bothRange=content.range(of:"both")
        func linkValue(_ range:NSRange) -> String { editor.textStorage!.attribute(.link,at:range.location,effectiveRange:nil) as! String }
        func click(_ range:NSRange) { _=coordinator.textView(editor,clickedOnLink:linkValue(range),at:range.location) }
        try require(!editor.isEditable && editor.string==model.message && links().allSatisfy{$0.0.location>40},"Read-only document excludes hash header")
        let font=editor.textStorage!.attribute(.font,at:bothRange.location,effectiveRange:nil) as! NSFont
        try require(NSFontManager.shared.traits(of:font).contains([.boldFontMask,.italicFontMask]),"Overlapping RichEdit font traits accumulate")
        try require(editor.textStorage!.attribute(.underlineStyle,at:content.range(of:"underlined").location,effectiveRange:nil) as? Int==NSUnderlineStyle.single.rawValue,"Source underline style")
        editor.setSelectedRange(NSRange(location:2,length:3));click(issueRange);try require(opened.isEmpty,"Selected text suppresses link activation")
        editor.setSelectedRange(NSRange(location:0,length:0));click(issueRange)
        try require(opened.last?.absoluteString=="https://tickets.invalid/42","Issue URL callback")
        let oldMenu=coordinator.menu(at:hashRange.location), oldAction=oldMenu.item(at:0)!
        model.busy=true;click(hashRange);try require(model.selected==[second],"Busy hash activation refused");model.busy=false
        click(hashRange);try await wait { model.selected==[base] }
        try require(model.scrollRevision==base,"Hash link selects and scrolls within visible history")
        model.select([second]);coordinator.refresh();try await wait { links().count>=4 && LogMessageView.Coordinator.activeOperations==0 }
        _=NSApp.sendAction(oldAction.action!,to:oldAction.target,from:oldAction)
        try require(model.selected==[second],"Old menu rejected after navigating away and returning")
        let selection=NSRange(location:content.range(of:"References").location,length:10);editor.setSelectedRange(selection)
        prefs.set(false,forKey:"StyleCommitMessages");prefs.set(17,forKey:"LogFontSize");coordinator.refresh()
        try await wait { LogMessageView.Coordinator.activeOperations==0 }
        let plain=editor.textStorage!.attribute(.font,at:bothRange.location,effectiveRange:nil) as! NSFont
        try require(!NSFontManager.shared.traits(of:plain).contains(.boldFontMask) && plain.pointSize==17 && editor.selectedRange()==selection,"Preference restyle preserves text selection and uses private font")
        prefs.set(40,forKey:"ShortHashLengthForHyperLinkInLogMessage");coordinator.refresh();try await wait { LogMessageView.Coordinator.activeOperations==0 }
        try require(editor.textStorage!.attribute(.link,at:hashRange.location,effectiveRange:nil)==nil,"Minimum hash preference removes short link")
        prefs.set(8,forKey:"ShortHashLengthForHyperLinkInLogMessage");prefs.set(true,forKey:"StyleCommitMessages");prefs.set(13,forKey:"LogFontSize");coordinator.refresh();try await wait { LogMessageView.Coordinator.activeOperations==0 }
        editor.setSelectedRange(NSRange(location:0,length:0));try await capture(owner)
        let gate=Gate(), auxiliary=NSWindow(contentRect:.init(x:0,y:0,width:400,height:200),styleMask:[.titled],backing:.buffered,defer:false)
        auxiliary.isReleasedWhenClosed=false;defer { auxiliary.close() }
        let heldEditor=LogMessageTextView(), held=LogMessageView.Coordinator(model:model,query:{ doc,properties,options,token in await gate.hold(token);return HistoryMessageStyles() })
        auxiliary.contentView=heldEditor;held.attach(heldEditor)
        for _ in 0..<1800 { if await gate.started() {break};try await Task.sleep(nanoseconds:10_000_000) }
        try require(await gate.started(),"Held style started")
        auxiliary.close();try require(await gate.cancelled(),"Closing owner cancels style token")
        try require(LogMessageView.Coordinator.activeOperations>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Retired styles retain Quit accounting")
        await gate.release();try await wait { LogMessageView.Coordinator.activeOperations==0 }
        try require(heldEditor.delegate==nil && heldEditor.coordinator==nil,"Retired style cannot republish")
        model.followMessageHash("00000000");try await wait { owner.window?.attachedSheet != nil }
        let sheet=owner.window!.attachedSheet!, buttons=views(sheet.contentView!).compactMap{$0 as? NSButton}
        let suppression=buttons.first{$0.title=="Do not show this message again"}!
        suppression.state = .on;buttons.first{$0.title=="OK"}!.performClick(nil)
        try await wait { owner.window?.attachedSheet==nil && prefs.bool(forKey:"NoJumpNotFoundWarning") }
        prefs.set(false,forKey:"NoJumpNotFoundWarning");model.followMessageHash("00000000");try await wait { owner.window?.attachedSheet != nil }
        owner.close();try await wait { owner.window?.attachedSheet==nil && LogMessageView.Coordinator.activeOperations==0 }
        try require(model.isInvalidated && !prefs.bool(forKey:"NoJumpNotFoundWarning"),"Forced close fences missing-hash alert preference reply")
        let finalHead=try await repository.run(["rev-parse","HEAD"]).stdout
        try require(finalHead==head && (try Data(contentsOf:root.appendingPathComponent(".git/index")))==index,"Message pane preserves Git state")
    }
}
