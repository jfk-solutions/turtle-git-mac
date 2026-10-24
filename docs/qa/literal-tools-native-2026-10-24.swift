// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

private struct LiteralToolForm:View {
    @ObservedObject var model:ToolSettingsDraft<DiffToolPreferences>
    let chooser:ToolApplicationChooser
    var body:some View {DiffProgramForm(program:$model.value.program,chooser:chooser).padding(20)}
}
@main struct LiteralToolsVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    @MainActor static var windows:[NSWindow]=[]
    @MainActor static var choosers:[ToolApplicationChooser]=[]
    static let nfc="\u{e9}",nfd="e\u{301}"
    static func require(_ value:Bool,_ message:String)throws{if !value{throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool)async throws {
        for _ in 0..<1800 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Literal tools timeout at \(line)")
    }
    @MainActor static func views(_ view:NSView?)->[NSView]{guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    @MainActor static func browseControl(_ window:NSWindow)->NSView? {
        guard let field=views(window.contentView).compactMap({$0 as? NSTextField}).first(where:{["diff program","Editor application"].contains($0.accessibilityLabel() ?? "")}),field.isEnabled,field.bounds.width>100 else{return nil}
        let fieldRect=field.convert(field.bounds,to:nil)
        return views(window.contentView).last {control in
            let rect=control.convert(control.bounds,to:nil)
            return control !== field && !control.isHiddenOrHasHiddenAncestor && rect.minX>=fieldRect.maxX && rect.minX-fieldRect.maxX<30 && abs(rect.midY-fieldRect.midY)<4 && rect.width>20 && rect.width<200 && rect.height>=20 && rect.height<=32
        }
    }
    @MainActor static func pressBrowse(_ window:NSWindow)throws {
        guard window.attachedSheet==nil,let control=browseControl(window),control.window === window,let content=window.contentView else{throw Failure(description:"Actual adjacent Browse control unavailable")}
        let point=control.convert(NSPoint(x:control.bounds.midX,y:control.bounds.midY),to:nil)
        guard let hit=content.hitTest(content.convert(point,from:nil)),hit.window === window else{throw Failure(description:"Actual Browse center has no owned hit-test target")}
        guard let down=NSEvent.mouseEvent(with:.leftMouseDown,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1),let up=NSEvent.mouseEvent(with:.leftMouseUp,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime+0.01,windowNumber:window.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:0) else{throw Failure(description:"Owned Browse mouse event unavailable")}
        print("Browse pointer control=\(type(of:control)) hit=\(type(of:hit)) point=\(point)")
        window.sendEvent(down);window.sendEvent(up)
    }
    @MainActor static func host<V:View>(_ view:V)->NSWindow {
        let window=NSWindow(contentRect:.init(x:0,y:0,width:900,height:650),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.alphaValue=0
        let hosting=NSHostingController(rootView:view);hosting.sizingOptions=[];window.contentViewController=hosting;window.setContentSize(.init(width:900,height:650));window.orderFront(nil)
        windows.append(window);return window
    }
    @MainActor static func edit(_ field:NSTextField,_ value:String)throws {
        guard let window=field.window else{throw Failure(description:"Native text field has no owner")}
        field.selectText(nil)
        guard let editor=field.currentEditor() as? NSTextView,window.firstResponder === editor else {
            throw Failure(description:"Native text field did not acquire its field editor")
        }
        editor.insertText(value,replacementRange:NSRange(location:0,length:(editor.string as NSString).length))
        print("Native edit bytes=\(Data(editor.string.utf8).base64EncodedString()) field=\(Data(field.stringValue.utf8).base64EncodedString()) delegate=\(String(describing:field.delegate))")
    }
    static func program(_ label:String)->DiffToolProgram {var p=DiffToolProgram();p.enabled=true;p.applicationPath="/Applications/Fixture.app";p.arguments="--label="+label+" %base %mine";return p}
    static func association(_ pattern:String,_ tag:String)->DiffToolAssociation {var a=DiffToolAssociation();a.pattern=pattern;a.program=program(tag);return a}
    @MainActor static func main()async {
        _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let suite="TurtleGit.LiteralTools.Native."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer{prefs.removePersistentDomain(forName:suite)}
        do {
            let root=URL(fileURLWithPath:CommandLine.arguments[1]),mode=CommandLine.arguments[2]
            switch mode {case "forms":try await forms(prefs);case "associations":try await associations(prefs);default:try await chooser(root,prefs)}
            choosers.forEach{$0.cancel()};windows.forEach{$0.contentViewController=nil;$0.close()}
            try await wait{ToolApplicationChooser.activeChoosers==0 && SettingsTransaction.activeApplications==0}
            try require(NSApp.windows.allSatisfy{!$0.isVisible && $0.sheetParent==nil},"Owned settings window/sheet survived cleanup")
            print("PASS: literal tools "+mode)
        } catch {
            choosers.forEach{$0.cancel()};windows.forEach{$0.contentViewController=nil;$0.close()}
            for _ in 0..<1000 {if ToolApplicationChooser.activeChoosers==0{break};try? await Task.sleep(nanoseconds:10_000_000)}
            fputs("Literal tools failure: \(error)\n",stderr);exit(1)
        }
    }
    @MainActor static func forms(_ prefs:UserDefaults)async throws {
        var value=DiffToolPreferences();value.program=program(nfc);try value.save(to:prefs)
        let diff=ToolSettingsDraft(value,valid:{$0.valid},persist:{try $0.save(to:prefs)}),dt=SettingsTransaction()
        let window=host(DiffToolSettings(model:diff,preferences:prefs).environment(\.settingsTransaction,dt))
        try await wait{views(window.contentView).compactMap{$0 as? NSTextField}.contains{$0.stringValue==value.program.arguments}}
        let arguments=views(window.contentView).compactMap{$0 as? NSTextField}.first{$0.stringValue==value.program.arguments}!
        try edit(arguments,"--label="+nfd+" %base %mine")
        print("Diff edit model=\(Data(diff.value.program.arguments.utf8).base64EncodedString()) saved=\(Data(value.program.arguments.utf8).base64EncodedString()) modified=\(diff.modified) transaction=\(dt.modified)")
        try await wait{diff.modified && dt.modified}
        try require(Data(diff.value.program.arguments.utf8)==Data(("--label="+nfd+" %base %mine").utf8),"Native Diff argument edit was canonically collapsed")
        dt.apply(closeAfter:false);try await wait{!dt.busy && !dt.modified}
        try require(Data(DiffToolPreferences.load(from:prefs).program.arguments.utf8)==Data(diff.value.program.arguments.utf8),"Actual Settings Apply did not persist literal Diff arguments")
        var mergeValue=MergeToolPreferences();mergeValue.program=program(nfc)
        let merge=ToolSettingsDraft(mergeValue,valid:{$0.valid},persist:{try $0.save(to:prefs)}),mt=SettingsTransaction()
        let mw=host(MergeToolSettings(model:merge,preferences:prefs).environment(\.settingsTransaction,mt))
        try await wait{views(mw.contentView).compactMap{$0 as? NSTextField}.contains{$0.stringValue==mergeValue.program.arguments}}
        try edit(views(mw.contentView).compactMap{$0 as? NSTextField}.first{$0.stringValue==mergeValue.program.arguments}!,"--label="+nfd+" %base %mine")
        try await wait{mt.modified};mt.apply(closeAfter:false);try await wait{!mt.busy && !mt.modified}
        try require(Data(MergeToolPreferences.load(from:prefs).program.arguments.utf8)==Data(("--label="+nfd+" %base %mine").utf8),"Merge Apply lost literal argument spelling")
        let a="/Applications/"+nfc+".app",b="/Applications/"+nfd+".app"
        AlternativeEditorPreferences(custom:true,applicationPath:a,bookmark:Data([1])).save(to:prefs)
        let at=SettingsTransaction(),aw=host(AlternativeEditorSettings(preferences:prefs).environment(\.settingsTransaction,at))
        try await wait{views(aw.contentView).compactMap{$0 as? NSTextField}.contains{$0.stringValue==a}}
        try edit(views(aw.contentView).compactMap{$0 as? NSTextField}.first{$0.stringValue==a}!,b)
        try await wait{at.modified};at.apply(closeAfter:false);try await wait{!at.busy && !at.modified}
        let saved=AlternativeEditorPreferences.load(from:prefs)
        try require(Data(saved.applicationPath.utf8)==Data(b.utf8) && saved.bookmark==nil,"Alternative Editor ignored literal path edit or retained its old bookmark")
        UnifiedDiffViewerPreferences(enabled:true,applicationPath:"/Applications/Fixture.app",arguments:nfc).save(to:prefs)
        let ut=SettingsTransaction(),uw=host(UnifiedDiffViewerSettings(preferences:prefs).environment(\.settingsTransaction,ut))
        try await wait{views(uw.contentView).compactMap{$0 as? NSTextField}.contains{$0.stringValue==nfc}}
        try edit(views(uw.contentView).compactMap{$0 as? NSTextField}.first{$0.stringValue==nfc}!,nfd)
        try await wait{ut.modified};ut.cancel();try await wait{!ut.modified}
        try require(Data(UnifiedDiffViewerPreferences.load(from:prefs).arguments.utf8)==Data(nfc.utf8),"Cancel wrote Unified Diff literal draft")
        // A cached Settings page can still apply, but a retired presentation
        // cannot accept an earlier Advanced child result after coming back.
        let receipt=diff.presentationGeneration;diff.suspendPresentation();diff.activatePresentation()
        try require(!diff.acceptsPresentation(receipt),"Revisited settings page revived an old child receipt")
        // Retain a real field editor past actual hosting removal. Its late
        // native text notification must not publish into the saved draft.
        arguments.selectText(nil)
        guard let retiredEditor=arguments.currentEditor() as? NSTextView else{throw Failure(description:"Diff field editor was unavailable before retirement")}
        let settled=Data(diff.value.program.arguments.utf8)
        window.contentViewController=nil;window.close()
        retiredEditor.insertText("obsolete",replacementRange:NSRange(location:0,length:(retiredEditor.string as NSString).length))
        try require(Data(diff.value.program.arguments.utf8)==settled,"Retired native tool field published a late edit")
        for t in [dt,mt,at,ut]{t.invalidate()}
    }
    @MainActor static func associations(_ prefs:UserDefaults)async throws {
        let a=association(nfc+".txt","first"),b=association(nfd+".txt","second")
        let model=ToolAssociationsModel(associations:[a,b],tool:"diff",preferences:prefs)
        let window=host(DiffToolAssociations(model:model,completed:{_ in}))
        try await wait{views(window.contentView).contains{$0 is NSTableView}}
        let table=views(window.contentView).compactMap{$0 as? NSTableView}.first!
        try await wait{table.numberOfRows==2}
        try require(model.valid && Set(model.rows.map(\.patternIdentity)).count==2,"Advanced table conflated distinct names")
        let row=model.rows.firstIndex{$0.id==b.id}!;table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
        try require(model.selected==b.id,"Native selection chose canonical sibling")
        model.edit();let receipt=model.editorIdentity
        try await wait{window.attachedSheet != nil}
        var changed=b;changed.program.arguments="--new="+nfd
        model.accept(changed,for:receipt)
        try await wait{window.attachedSheet==nil}
        try require(model.draft.first{$0.id==a.id}==a && model.draft.first{$0.id==b.id}?.program.arguments==changed.program.arguments,"Edit replaced the wrong association")
        model.add();let addReceipt=model.editorIdentity
        var added=model.editing!;added.pattern="***"+nfc.uppercased()+".TXT";added.program=program("duplicate")
        model.accept(added,for:addReceipt)
        try require(model.draft.count==2,"Case-only duplicate was accepted")
        model.selected=a.id;model.remove()
        try require(model.draft.count==1 && model.draft[0].id==b.id,"Remove deleted the canonical sibling")
        model.restoreDefaults()
        try require(model.draft.contains{$0.id==b.id},"Restore Defaults discarded unrelated exact rule")
        var stored=DiffToolPreferences();stored.associations=model.draft;try stored.save(to:prefs)
        try require(DiffToolPreferences.load(from:prefs).associations.contains{$0.id==b.id},"Advanced rules were not persisted")
        model.selected=b.id;model.edit();let old=model.editorIdentity
        window.contentViewController=nil;window.close();try await wait{model.retired};model.accept(a,for:old)
        try require(model.retired && model.draft.contains{$0.id==b.id},"Retired Advanced editor accepted stale action")
    }
    @MainActor static func chooser(_ root:URL,_ prefs:UserDefaults)async throws {
        let file=root.appendingPathComponent("private executable")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:file.path)
        var value=DiffToolPreferences();value.program=program(nfc)
        let model=ToolSettingsDraft(value,valid:{$0.valid},persist:{try $0.save(to:prefs)}),chooser=ToolApplicationChooser();choosers.append(chooser)
        let window=host(LiteralToolForm(model:model,chooser:chooser))
        var response:((NSApplication.ModalResponse)->Void)?,panel:NSOpenPanel?,bookmarks=0
        chooser.present={p,w,reply in panel=p;response=reply;w.beginSheet(p,completionHandler:reply)}
        chooser.selectedURL={_ in file};chooser.bookmark={_ in bookmarks += 1;return Data([4,5])}
        try await wait{chooser.window === window && views(window.contentView).compactMap{$0 as? NSTextField}.contains{$0.accessibilityLabel()=="diff program" && $0.bounds.width>100}}
        do {
            guard browseControl(window) != nil else{throw Failure(description:"Actual adjacent Browse control missing after owner realization")}
        } catch {
            print("Chooser readiness owner=\(chooser.window === window) selecting=\(chooser.selecting) sheet=\(String(describing:window.attachedSheet)) size=\(window.frame)")
            for view in views(window.contentView) {print("Chooser view \(String(reflecting:type(of:view))) frame=\(view.frame) label=\(String(describing:view.accessibilityLabel())) title=\((view as? NSButton)?.title ?? (view as? NSTextField)?.stringValue ?? "")")}
            throw error
        }
        func browse()throws{try pressBrowse(window)}
        try browse();try await wait{window.attachedSheet != nil}
        try require(chooser.selecting && ToolApplicationChooser.activeChoosers>0 && panel?.alphaValue==0,"Actual Browse lost owned invisible sheet")
        model.value.program.arguments="--label="+nfd+" %base %mine"
        response?(.OK);response?(.OK)
        try await wait{!chooser.selecting && window.attachedSheet==nil}
        try require(bookmarks==0 && model.value.program.applicationPath==value.program.applicationPath,"Changed literal draft adopted obsolete program/grant")
        try await wait{browseControl(window) != nil}
        try browse();try await wait{window.attachedSheet != nil};response?(.OK)
        try await wait{!chooser.selecting && window.attachedSheet==nil}
        try require(bookmarks==1 && model.value.program.applicationPath==file.path && model.value.program.bookmark==Data([4,5]),"Accepted executable was not applied exactly once")
        try await wait{browseControl(window) != nil}
        try browse();try await wait{window.attachedSheet != nil}
        let late=response;window.contentViewController=nil;window.close();late?(.OK)
        try await wait{ToolApplicationChooser.activeChoosers==0}
        try require(bookmarks==1,"Closed tool owner accepted retained chooser callback")
        var reopened=false;chooser.choose({_,_ in reopened=true},failure:{_ in reopened=true},allowExecutables:true)
        try require(!chooser.selecting && !reopened,"Closed owner started another picker")
        // The same lifecycle transport is also installed in Alternative Editor.
        let p=AlternativeEditorPreferences(custom:true,applicationPath:file.path);p.save(to:prefs)
        let altChooser=ToolApplicationChooser();choosers.append(altChooser)
        let alt=host(AlternativeEditorSettings(preferences:prefs,chooser:altChooser))
        var altResponse:((NSApplication.ModalResponse)->Void)?
        altChooser.present={p,w,reply in altResponse=reply;w.beginSheet(p,completionHandler:reply)}
        altChooser.selectedURL={_ in file};altChooser.bookmark={_ in bookmarks += 1;return Data([9])}
        try await wait{altChooser.window === alt && browseControl(alt) != nil}
        try pressBrowse(alt)
        try await wait{alt.attachedSheet != nil};alt.contentViewController=nil;alt.close();altResponse?(.OK)
        try await wait{ToolApplicationChooser.activeChoosers==0}
        try require(bookmarks==1,"Alternative Editor adopted after owner retirement")
    }
}
