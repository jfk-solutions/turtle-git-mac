// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@main struct InputWordConsumersVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    @MainActor static func wait(_ window:NSWindow?,line:UInt = #line,_ ready:()->Bool) async throws {
        for _ in 0..<1800 {window?.contentView?.layoutSubtreeIfNeeded();if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Input consumer wait at \(line)")
    }
    @MainActor static func editor(_ field:NSTextField)throws->NSTextView {
        if let active=field.currentEditor() as? NSTextView {return active}
        field.selectText(nil)
        guard let text=field.currentEditor() as? NSTextView else{throw Failure(description:"No editor: "+(field.accessibilityLabel() ?? "field"))};return text
    }
    @MainActor static func invoke(_ field:NSTextField,_ text:NSTextView,_ command:String)->Bool {field.delegate?.control?(field,textView:text,doCommandBy:NSSelectorFromString(command)) ?? false}
    @MainActor static func check(_ field:NSTextField,prefs:UserDefaults) throws {
        if field.stringValue.isEmpty {field.stringValue="feature/topic-name"}
        let text=try editor(field),saved=text.string
        text.setSelectedRange(.init(location:0,length:0))
        let handled=invoke(field,text,"moveWordForward:")
        if !handled {print("WORD INPUT",field.accessibilityLabel() ?? "field","enabled",field.isEnabled,"visible",field.window?.isVisible as Any,"editor",field.currentEditor() === text,"selectable",text.isSelectable,"marked",text.hasMarkedText(),"delegate",String(describing:field.delegate))}
        try require(handled,"Missing custom word command: "+(field.accessibilityLabel() ?? "field"))
        try require(text.string==saved && text.selectedRange()==NSRange(location:GitInputWordBreak.boundary(saved,from:0,forward:true),length:0),"Navigation changed text or missed source stop")
        prefs.set(0,forKey:"UseCustomWordBreak")
        try require(!invoke(field,text,"moveWordBackward:"),"Mode zero did not return native editing")
        prefs.set(1,forKey:"UseCustomWordBreak")
        try require(invoke(field,text,"moveWordBackward:") == !(field is NSComboBox),"Plain/combo inclusion mismatch")
        prefs.set(2,forKey:"UseCustomWordBreak")
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Input Consumers QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
        try Data("feature/topic-name\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"base")
        _=try await repo.run(["branch","feature/topic-name"])
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),config=try Data(contentsOf:root.appendingPathComponent(".git/config")),refs=try await repo.run(["show-ref"]).stdout
        let suite="TurtleGit.InputConsumers."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        prefs.set(2,forKey:"UseCustomWordBreak");prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"LogIncludeWorkingTreeChanges")
        var value="feature/topic-name"
        let version=NSHostingView(rootView:VersionRevisionField(text:Binding(get:{value},set:{value=$0}),choices:[value],focusRequest:0,onFocus:{_ in}).padding(12).defaultAppStorage(prefs))
        let versionWindow=NSWindow(contentRect:.init(x:0,y:0,width:500,height:80),styleMask:[.titled],backing:.buffered,defer:false)
        versionWindow.isReleasedWhenClosed=false;versionWindow.contentView=version;versionWindow.alphaValue=0;versionWindow.orderFront(nil);defer {versionWindow.close()}
        try await wait(versionWindow) {views(version).contains{$0 is NSComboBox}}
        let revision=views(version).compactMap{$0 as? NSComboBox}.first!,revisionEditor=try editor(revision)
        revisionEditor.setSelectedRange(.init(location:0,length:0));try require(invoke(revision,revisionEditor,"moveWordRight:") && revisionEditor.selectedRange().location==8,"Version revision selector not connected")
        versionWindow.close()
        let board=NSPasteboard.withUniqueName();defer {board.releaseGlobally()}
        let open=MergeOpenWindowController(preferences:prefs,pasteboard:board);defer {open.close()}
        open.window!.alphaValue=0;open.window!.orderFront(nil)
        for field in views(open.window?.contentView).compactMap({$0 as? MergeOpenPathField}).filter({$0.isEnabled}) {field.stringValue="feature/topic-name";try check(field,prefs:prefs)}
        open.close()
        let remote=RemoteSettingsWindowController(repository:repo,access:nil,preferences:prefs,noFetch:true);defer {remote.close()}
        remote.window!.alphaValue=0;remote.window!.orderFront(nil);remote.model.load()
        try await wait(remote.window) {!remote.model.busy}
        guard let surface=remote.window?.contentView as? RemoteSettingsNativeView else{throw Failure(description:"Remote native surface missing")}
        for field in [surface.remote,surface.url,surface.pushURL,surface.sshKey] where field.isEnabled {field.stringValue="feature/topic-name";try check(field,prefs:prefs)}
        // Two fields share the same AppKit editor and controller. Their identical
        // text/range must not reuse the first field's anchored selection.
        surface.url.stringValue="feature/topic-name";surface.pushURL.stringValue="feature/topic-name"
        let first=try editor(surface.url);first.setSelectedRange(.init(location:8,length:0))
        try require(invoke(surface.url,first,"moveWordForwardAndModifySelection:") && first.selectedRange()==NSRange(location:8,length:6),"First field anchor setup")
        let second=try editor(surface.pushURL);second.setSelectedRange(.init(location:8,length:6))
        try require(first === second,"Remote inputs did not exercise their shared field editor")
        try require(invoke(surface.pushURL,second,"moveWordBackwardAndModifySelection:") && second.selectedRange()==NSRange(location:0,length:14),"Shared field editor leaked another input's anchor")
        remote.close()
        let containing=CommitContainingReferencesWindowController(repository:repo,access:nil,revision:"HEAD",preferences:prefs);defer {containing.close()}
        containing.window!.alphaValue=0;containing.window!.orderFront(nil);containing.refresh(reloadCompletion:true)
        try await wait(containing.window) {!containing.busy && containing.snapshot != nil}
        try check(containing.revision,prefs:prefs);try check(containing.filter,prefs:prefs)
        containing.filter.stringValue="feature/topic-name";let containingEditor=try editor(containing.filter)
        try require(invoke(containing.filter,containingEditor,"cancelOperation:") && containing.filter.stringValue.isEmpty,"Containing-ref Escape filter route changed")
        containing.close()
        let find=RevisionGraphFindController(repository:repo,access:nil,preferences:prefs);defer {find.close()}
        find.canSearch={true};find.updateAvailability();find.loadReferences()
        find.window!.alphaValue=0;find.window!.orderFront(nil)
        try await wait(find.window) {find.searchBox.isEnabled && find.referenceFilter.isEnabled}
        try check(find.searchBox,prefs:prefs);try check(find.referenceFilter,prefs:prefs);find.close()
        let log=LogWindowController(repository:repo,access:nil,labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false);defer {log.close()}
        log.window!.alphaValue=0;log.window!.orderFront(nil)
        try await wait(log.window) {!log.model.busy && !log.model.entries.isEmpty}
        let filters=views(log.window?.contentView).compactMap{$0 as? NSSearchField}.filter{["Filter revisions","Filter changed paths"].contains($0.accessibilityLabel() ?? "")}
        try require(filters.count==2,"Log filters missing")
        for field in filters {try check(field,prefs:prefs)};log.close()
        let browser=ReferenceBrowserWindowController(repository:repo,access:nil,initial:"HEAD",preferences:prefs,picking:false,onChoose:{_ in});defer {browser.close()}
        browser.window!.alphaValue=0;browser.window!.orderFront(nil)
        try await wait(browser.window) {!browser.model.busy && browser.model.snapshot != nil}
        browser.model.folder=GitReferenceName("refs/heads/feature");browser.model.select([GitReferenceName("refs/heads/feature/topic-name")],last:GitReferenceName("refs/heads/feature/topic-name"))
        try await wait(browser.window) {browser.model.canRename}
        guard let table=views(browser.window?.contentView).compactMap({$0 as? NSTableView}).first(where:{!($0 is NSOutlineView)}),let coordinator=table.delegate as? ReferenceBrowserNativeView.Coordinator else{throw Failure(description:"Reference table missing")}
        try await wait(browser.window) {table.numberOfRows==1 && table.selectedRow==0}
        coordinator.beginRename()
        try await wait(browser.window) {views(table).compactMap{$0 as? NSTextField}.contains{$0.accessibilityLabel()=="Rename branch" && $0.currentEditor() != nil}}
        let rename=views(table).compactMap{$0 as? NSTextField}.first{$0.accessibilityLabel()=="Rename branch"}!
        try check(rename,prefs:prefs);let renameEditor=try editor(rename)
        try require(invoke(rename,renameEditor,"cancelOperation:") && browser.model.renameReference==nil,"Reference rename Escape was replaced")
        browser.close()
        let old=root.appendingPathComponent("old.txt"),new=root.appendingPathComponent("new.txt")
        try Data("feature/old-name\n".utf8).write(to:old);try Data("feature/new-name\n".utf8).write(to:new)
        let comparison=FileComparisonWindowController(comparison:try WorkingFileComparison(base:old,destination:new),permissions:[],preferences:prefs);defer {comparison.close()}
        comparison.window!.alphaValue=0;comparison.window!.orderFront(nil);comparison.model.load()
        comparison.model.activatePane(base:false);comparison.model.editingEnabled=true
        try await wait(comparison.window) {!comparison.model.busy && comparison.model.document != nil && MergeMarkedWordInterface.panes(in:comparison.window?.contentView).contains{$0.string.contains("new-name") && $0.isEditable}}
        guard let text=MergeMarkedWordInterface.panes(in:comparison.window?.contentView).first(where:{$0.string.contains("new-name")}) else{throw Failure(description:"Comparison text missing")}
        guard let target=text as? MergeFindProviding else{throw Failure(description:"Comparison Find provider missing")}
        try await wait(comparison.window) {target.mergeFindAllowed}
        let mergeFind=MergeFindWindowController(text:text,defaults:prefs);defer {mergeFind.close()}
        target.mergeFindController=mergeFind;mergeFind.present(show:false)
        mergeFind.window!.alphaValue=0;mergeFind.window!.orderFront(nil)
        try await wait(mergeFind.window) {mergeFind.search.isEnabled}
        try require(mergeFind.replacement.isEnabled,"Editable destination Find replacement was not enabled")
        try check(mergeFind.search,prefs:prefs);try check(mergeFind.replacement,prefs:prefs)
        mergeFind.close();comparison.close()
        let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout,finalRefs=try await repo.run(["show-ref"]).stdout
        try require(finalHead==head && finalRefs==refs && Data(contentsOf:root.appendingPathComponent(".git/index"))==index && Data(contentsOf:root.appendingPathComponent(".git/config"))==config,"Input consumers changed repository")
        print("PASS: native revision/Open/Remote/ref-search/Log/rename/Merge Find word consumers, mode distinction, shared-editor anchor isolation, preserved Escape routes and repository invariants; owned windows closed")
    }
}
