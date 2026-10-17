// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor private final class InputDraft:ObservableObject {
    @Published var path="/Users/name/project_file.swift"
    @Published var clone="https://user@host/project.git"
    @Published var fetch="feature/topic-name"
    @Published var branch="feature/topic-name"
    @Published var author="Name <person@example.invalid>"
    @Published var editable=true
}
private struct InputFields:View {
    @ObservedObject var draft:InputDraft
    let preferences:UserDefaults
    let base:URL
    var body:some View {VStack {
        PathEntryField(text:$draft.path,label:"Word path",base:base,preferences:preferences)
        CloneHistoryCombo(value:$draft.clone,choices:[],label:"Word Clone")
        FetchHistoryCombo(value:$draft.fetch,choices:[],label:"Word Fetch")
        CommitNewBranchField(name:$draft.branch)
        CommitAuthorField(author:$draft.author,editable:draft.editable)
    }.padding(16).defaultAppStorage(preferences)}
}
@main struct InputWordNavigationVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func views(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(views)}
    @MainActor static func wait(_ window:NSWindow?,line:UInt = #line,_ ready:()->Bool) async throws {
        for _ in 0..<1500 {window?.contentView?.layoutSubtreeIfNeeded();if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Input word wait at \(line)")
    }
    @MainActor static func editor(_ field:NSTextField)throws->NSTextView {
        field.selectText(nil)
        guard let text=field.currentEditor() as? NSTextView else {throw Failure(description:"Missing editor for "+(field.accessibilityLabel() ?? "field"))}
        return text
    }
    @MainActor static func invoke(_ field:NSTextField,_ text:NSTextView,_ command:String)->Bool {
        field.delegate?.control?(field,textView:text,doCommandBy:NSSelectorFromString(command)) ?? false
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Word Navigation QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:root.appendingPathComponent("file"));try await repo.stage(["file"]);_=try await repo.commit(message:"base")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),config=try Data(contentsOf:root.appendingPathComponent(".git/config"))
        let suite="TurtleGit.InputWords."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        prefs.set(2,forKey:"UseCustomWordBreak")
        let draft=InputDraft(),host=NSHostingView(rootView:InputFields(draft:draft,preferences:prefs,base:root))
        let window=NSWindow(contentRect:.init(x:0,y:0,width:700,height:240),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=host;window.alphaValue=0;window.orderFront(nil);defer {window.close()}
        try await wait(window) {views(host).compactMap{$0 as? NSTextField}.filter{$0.isEditable}.count>=5}
        func field(_ label:String)throws->NSTextField {
            guard let value=views(host).compactMap({$0 as? NSTextField}).first(where:{$0.accessibilityLabel()==label}) else {throw Failure(description:"Missing "+label)};return value
        }
        let path=try field("Word path"),clone=try field("Word Clone"),fetch=try field("Word Fetch"),branch=try field("New branch name"),author=try field("Author identity")
        for field in [path,clone,fetch,branch,author] {
            let text=try editor(field);text.setSelectedRange(.init(location:0,length:0))
            let expected=GitInputWordBreak.boundary(text.string,from:0,forward:true)
            try require(invoke(field,text,"moveWordRight:") && text.selectedRange()==NSRange(location:expected,length:0),"Missing forward URL/path command")
            try require(invoke(field,text,"moveWordLeft:") && text.selectedRange()==NSRange(location:0,length:0),"Missing backward URL/path command")
            try require(invoke(field,text,"moveWordForwardAndModifySelection:") && text.selectedRange()==NSRange(location:0,length:expected),"Word extension lost anchor")
            try require(invoke(field,text,"moveWordBackwardAndModifySelection:") && text.selectedRange()==NSRange(location:0,length:0),"Reversed extension lost anchor")
        }
        // A real native deletion must update the bound draft and remain Undoable.
        let text=try editor(path),original=draft.path
        text.undoManager?.removeAllActions();text.setSelectedRange(.init(location:text.string.utf16.count,length:0))
        let tail=GitInputWordBreak.boundary(original,from:original.utf16.count,forward:false)
        try require(invoke(path,text,"deleteWordBackward:"),"Backward word deletion missing")
        try await wait(window) {draft.path==String((original as NSString).substring(to:tail))}
        try require(text.undoManager?.canUndo==true,"Word deletion lost native Undo")
        text.undoManager?.undo();try await wait(window) {draft.path==original && text.string==original}
        text.undoManager?.removeAllActions();text.setSelectedRange(.init(location:0,length:0))
        try require(invoke(path,text,"deleteWordForward:"),"Forward word deletion missing")
        let next=GitInputWordBreak.boundary(original,from:0,forward:true)
        try await wait(window) {draft.path==String((original as NSString).substring(from:next))}
        text.undoManager?.undo();try await wait(window) {draft.path==original}
        // Modes retain the source plain-field/combobox distinction live.
        for mode in [1,3,0,2] {
            prefs.set(mode,forKey:"UseCustomWordBreak")
            try await wait(window) {(fetch.delegate as? FetchHistoryCombo.Coordinator)?.wordCommands.policy.mode==UInt32(mode) && (branch.delegate as? CommitNewBranchField.Coordinator)?.wordCommands.policy.mode==UInt32(mode)}
            for field in [path,clone,fetch,branch,author] {
                let text=try editor(field);text.setSelectedRange(.init(location:0,length:0))
                let handled=invoke(field,text,"moveWordForward:")
                try require(handled == (mode != 0 && (!(field is NSComboBox) || mode==2)),"Plain/history policy distinction changed")
            }
        }
        // Read-only copies still navigate; deletion remains native and refused.
        draft.editable=false;try await wait(window) {!author.isEditable}
        let readOnly=try editor(author);readOnly.setSelectedRange(.init(location:0,length:0))
        try require(invoke(author,readOnly,"moveWordRight:"),"Read-only selection navigation unavailable")
        let retained=draft.author
        try require(!invoke(author,readOnly,"deleteWordForward:") && draft.author==retained,"Read-only author changed")
        let marked=try editor(fetch);marked.setMarkedText("composing",selectedRange:.init(location:0,length:0),replacementRange:.init(location:0,length:0))
        try require(marked.hasMarkedText() && !invoke(fetch,marked,"moveWordRight:"),"Custom word command intercepted IME composition")
        marked.unmarkText()
        let hiddenText=try editor(branch);window.orderOut(nil)
        try require(!invoke(branch,hiddenText,"deleteWordBackward:"),"Hidden owner accepted custom edit")
        window.orderFront(nil)
        // The actual Bisect good/bad controls share mode 2, without starting Bisect.
        let bisect=BisectWindowController(repository:repo,access:nil,preferences:prefs);defer {bisect.close()}
        bisect.window!.alphaValue=0;bisect.window!.orderFront(nil)
        try await wait(bisect.window) {!bisect.model.busy && views(bisect.window!.contentView!).compactMap{$0 as? NSComboBox}.count>=2}
        for combo in views(bisect.window!.contentView!).compactMap({$0 as? NSComboBox}) {
            let text=try editor(combo);text.setSelectedRange(.init(location:0,length:0))
            try require(invoke(combo,text,"moveWordRight:"),"Bisect revision word command missing")
        }
        bisect.close();window.close()
        let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(finalHead==head && Data(contentsOf:root.appendingPathComponent(".git/index"))==index && Data(contentsOf:root.appendingPathComponent(".git/config"))==config,"Input navigation changed repository")
        print("PASS: URL/path field and history navigation, native extension reversal, deletion/bindings/Undo, live modes, read-only/IME/hidden fences, actual Bisect fields and unchanged repository; owned windows closed")
    }
}
