// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@main struct SourceMessageLinksVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description:message) } }
    @MainActor static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<1800 { if condition() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Message links did not settle at fixture line \(line)")
    }
    @MainActor static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    static func trace(_ stage: String) {
        fputs("Source links: " + stage + "\n",stderr)
        try? stage.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("source-link-phase.txt"),atomically:true,encoding:.utf8)
    }
    static let text = "🐢 issue #42\nhttps://example.invalid/doc?q=a%20b\nqa@example.invalid"
    @MainActor static func main() async throws { try await verify() }
    @MainActor static func exercise(_ editor: ProjectMessageTextView, preferences: UserDefaults, label: String) async throws {
        trace(label + ": begin")
        let value = "https://example.invalid/doc?q=a%20b"
        try await wait { (editor.string as NSString).range(of:value).location != NSNotFound }
        let range = (editor.string as NSString).range(of:value)
        try await wait { editor.textStorage?.attribute(.link,at:range.location,effectiveRange:nil) as? String == value }
        trace(label + ": styles ready")
        let helper=editor.sourceLinks
        var opened:[URL]=[], copied:[String]=[]
        helper.openURL={opened.append($0)};helper.writeClipboard={copied.append($0)}
        let text=editor.string, undo=editor.undoManager?.canUndo
        editor.setSelectedRange(NSRange(location:0,length:0))
        editor.clicked(onLink:value,at:range.location)
        try require(opened.count==1 && opened[0].absoluteString==value,label+": explicit hotspot preserves escapes")
        editor.clicked(onLink:"https://example.invalid/stale",at:range.location)
        try require(opened.count==1,label+": mismatched link event rejected")
        editor.setSelectedRange(NSRange(location:range.location,length:4));editor.clicked(onLink:value,at:range.location)
        try require(opened.count==1,label+": selected text does not open hotspot")
        editor.setSelectedRange(NSRange(location:0,length:0))
        trace(label + ": click/selection ready")
        let menu=NSMenu();let copy=NSMenuItem(title:"Native copy",action:#selector(NSTextView.copy(_:)),keyEquivalent:"");copy.target=editor;menu.addItem(copy)
        let unsafe=NSMenuItem(title:"Localized native link item",action:NSSelectorFromString("_openLink:"),keyEquivalent:"");menu.addItem(unsafe)
        helper.prepareMenu(menu,at:range.location)
        let open=menu.item(withTitle:"Open link")!, address=menu.item(withTitle:"Copy link address")!
        try require(menu.items.filter{$0.title=="Open link"}.count==1 && menu.item(withTitle:unsafe.title)==nil && open.image != nil && address.image != nil && copy.image != nil,label+": replaces inherited actions and keeps original icons")
        _=NSApp.sendAction(address.action!,to:address.target,from:address)
        try require(copied==[value],label+": captured link copy writes literal target only")
        editor.isEditable=false;_=NSApp.sendAction(open.action!,to:open.target,from:open)
        try require(opened.count==1,label+": disabled editor gates old menu")
        editor.isEditable=true
        let sheet=NSWindow(contentRect:.init(x:0,y:0,width:250,height:100),styleMask:[.titled],backing:.buffered,defer:false);sheet.isReleasedWhenClosed=false
        sheet.alphaValue=0;trace(label + ": presenting modal")
        editor.window!.beginSheet(sheet,completionHandler:{ (_: NSApplication.ModalResponse) in });_=NSApp.sendAction(open.action!,to:open.target,from:open)
        try require(opened.count==1,label+": owned modal blocks link")
        trace(label + ": ending modal")
        editor.window!.endSheet(sheet);sheet.orderOut(nil);sheet.close();try await wait { editor.window?.attachedSheet==nil }
        _=NSApp.sendAction(open.action!,to:open.target,from:open)
        try require(opened.count==2,label+": unchanged link works after modal ends")
        trace(label + ": modal ended")
        editor.string += " later";editor.didChangeText()
        _=NSApp.sendAction(open.action!,to:open.target,from:open)
        try require(opened.count==2,label+": edited text fences menu")
        editor.string=text;editor.didChangeText()
        try await wait { editor.textStorage?.attribute(.link,at:range.location,effectiveRange:nil) as? String==value && MessageEditorStylingSession.activeOperations==0 }
        _=NSApp.sendAction(open.action!,to:open.target,from:open)
        try require(opened.count==2,label+": leaving and restoring identical text does not revive menu")
        trace(label + ": restyle ready")
        preferences.set(false,forKey:"ShowAppContextMenuIcons")
        let hidden=NSMenu();helper.prepareMenu(hidden,at:range.location)
        try require(hidden.item(withTitle:"Open link")?.image==nil && hidden.item(withTitle:"Copy link address")?.image==nil,label+": owning icon preference")
        preferences.set(true,forKey:"ShowAppContextMenuIcons")
        try require(editor.string.utf8.elementsEqual(text.utf8) && editor.undoManager?.canUndo==undo,label+": link actions do not edit text or Undo")
        let current=helper.snapshot(at:range.location)!
        trace(label + ": retiring")
        editor.retireSourceStyling();helper.activate(current);helper.copy(current)
        try require(opened.count==2 && copied==[value],label+": retired owner cannot activate or copy old target")
    }
    @MainActor static func verify() async throws {
        trace("starting")
        _=NSApplication.shared;trace("application ready")
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        let suite="TurtleGit.SourceLinks.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        prefs.set(false,forKey:"Spellchecker");prefs.set(true,forKey:"ShowAppContextMenuIcons");prefs.set("Menlo",forKey:"LogFontName");prefs.set(13,forKey:"LogFontSize")
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Link QA"),("user.email","links@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("tgit.projectlanguage","-1"),("bugtraq.logregex","issue #([0-9]+)"),("bugtraq.url","https://tickets.invalid/%BUGID%")] {_=try await repo.run(["config",key,value])}
        for message in ["base","next"] {_=try await repo.run(["commit","--allow-empty","-m",message])}
        _=try await repo.run(["notes","add","-m",text])
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try? Data(contentsOf:root.appendingPathComponent(".git/index"))
        let originalNote = try await repo.run(["notes","show","HEAD"]).stdout
        let properties=try await repo.issueTrackerProperties()
        trace("repository ready")
        let input=InputWindowController(text:text,issueProperties:properties,preferences:prefs) {_,_,_ in}
        defer {input.close()};input.window?.alphaValue=0;input.window?.orderFront(nil)
        try await exercise(input.editor as! ProjectMessageTextView,preferences:prefs,label:"Input");input.close()
        let notes=HistoryNotesWindowController(repository:repo,access:nil,revision:"HEAD",preferences:prefs)
        defer {notes.close()};notes.window?.alphaValue=0;notes.window?.orderFront(nil);notes.model.load()
        try await wait {!notes.model.loading && notes.model.snapshot != nil}
        try await exercise(notes.editor as! ProjectMessageTextView,preferences:prefs,label:"Notes");notes.cancel()
        let description=ReferenceDescriptionWindowController(text:text,preferences:prefs) {_,_ in}
        defer {description.close()};description.window?.alphaValue=0;description.window?.orderFront(nil)
        try await exercise(description.editor as! ProjectMessageTextView,preferences:prefs,label:"Description");description.close()
        let merge=MergeWindowController(repository:repo,access:nil,preferences:prefs)
        defer {merge.close()};merge.window?.alphaValue=0;merge.window?.orderFront(nil);merge.model.load()
        try await wait {!merge.model.busy && !merge.model.issueProperties.checkExpression.isEmpty};merge.model.message=text
        try await wait {views(merge.window!.contentView!).contains{$0 is MergeMessageTextView}}
        let mergeEditor=views(merge.window!.contentView!).compactMap{$0 as? MergeMessageTextView}.first!
        try await exercise(mergeEditor,preferences:prefs,label:"Merge");merge.close()
        let rebase=RebaseWindowController(repository:repo,access:nil,preferences:prefs);defer {rebase.close()};rebase.model.load()
        try await wait {!rebase.model.busy && !rebase.model.issueProperties.checkExpression.isEmpty}
        var draft=text
        let host=NSHostingView(rootView:ProjectMessageEditor(text:Binding(get:{draft},set:{draft=$0}),settings:rebase.model.projectSettings,label:"Rebase message",preferences:prefs,issueProperties:rebase.model.issueProperties))
        let rebaseWindow=NSWindow(contentRect:.init(x:0,y:0,width:600,height:200),styleMask:[.titled],backing:.buffered,defer:false);rebaseWindow.isReleasedWhenClosed=false;rebaseWindow.contentView=host;rebaseWindow.alphaValue=0;rebaseWindow.orderFront(nil);defer {rebaseWindow.close()}
        try await wait {views(host).contains{$0 is ProjectMessageTextView}}
        try await exercise(views(host).compactMap{$0 as? ProjectMessageTextView}.first!,preferences:prefs,label:"Rebase shared editor");rebaseWindow.close();rebase.close()
        let commit=CommitWindowController(repository:repo,access:nil,defaults:prefs);defer {commit.close()};commit.window?.alphaValue=0;commit.window?.orderFront(nil);commit.model.reload()
        try await wait {!commit.model.busy && !commit.model.issueProperties.checkExpression.isEmpty};commit.model.message=text
        try await wait {views(commit.window!.contentView!).contains{$0 is ProjectMessageTextView}}
        let commitEditor=views(commit.window!.contentView!).compactMap{$0 as? ProjectMessageTextView}.first!
        try await exercise(commitEditor,preferences:prefs,label:"Commit");commit.close()
        let transient=InputWindowController(text:text,issueProperties:properties,preferences:prefs) {_,_,_ in}
        transient.window?.alphaValue=0;transient.window?.orderFront(nil);defer {transient.close()}
        let editor=transient.editor as! ProjectMessageTextView, location=(editor.string as NSString).range(of:"https://").location
        try await wait {editor.sourceLinks.snapshot(at:location) != nil}
        var late=0;editor.sourceLinks.openURL={_ in late += 1}
        let menu=NSMenu();editor.sourceLinks.prepareMenu(menu,at:location);let item=menu.item(withTitle:"Open link")!
        transient.close();_=NSApp.sendAction(item.action!,to:item.target,from:item)
        try require(late==0 && editor.sourceLinks.snapshot(at:location)==nil,"Closed window invalidates its link menu")
        try require(SourceMessageLinkURL.url("")==nil && SourceMessageLinkURL.url("https://example.invalid/\0tail")==nil,"Invalid empty/NUL targets do not dispatch")
        try await wait {MessageEditorStylingSession.activeOperations==0}
        let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout, note=try await repo.run(["notes","show","HEAD"]).stdout
        try require(finalHead==head,"Message-only actions preserve HEAD")
        try require((try? Data(contentsOf:root.appendingPathComponent(".git/index")))==index,"Message-only actions preserve exact index bytes")
        try require(note==originalNote,"Message-only actions preserve exact saved note bytes, including Git trailing LF")
        print("PASS: shared message hotspots and captured icon menus across Input/Notes/Description/Merge/Rebase/Commit; modal/edit/retirement/clipboard guards and literal targets")
    }
}
