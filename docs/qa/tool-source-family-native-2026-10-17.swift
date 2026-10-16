// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import ScreenCaptureKit
import TurtleGitCore

struct ToolSourceFormHost:View {
    @ObservedObject var model:ToolSettingsDraft<DiffToolPreferences>
    let preferences:UserDefaults
    var body:some View {DiffProgramForm(program:$model.value.program,preferences:preferences).padding(20).defaultAppStorage(preferences)}
}
@main struct ToolSourceVerification {
    enum Failure:Error {case assertion(String),timeout(UInt)}
    @MainActor static func require(_ yes:Bool,_ message:String)throws {if !yes {throw Failure.assertion(message)}}
    @MainActor static func wait(line:UInt = #line,_ yes:()->Bool)async throws {for _ in 0..<1500 {if yes(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure.timeout(line)}
    @MainActor static func views(_ root:NSView?)->[NSView] {guard let root else {return []};return [root]+root.subviews.flatMap {views($0)}}
    @MainActor static func capture(_ window:NSWindow,name:String,to folder:URL)async throws {
        guard #available(macOS 14.4,*) else {throw Failure.assertion("Capture requires macOS 14.4")}
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        for (appearance,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:appearance);window.alphaValue=1;window.orderFront(nil);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
            let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
            guard let own=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else {throw Failure.assertion("Capture owner missing")}
            let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:own),configuration:config)
            guard let data=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else {throw Failure.assertion("PNG missing")}
            try data.write(to:folder.appendingPathComponent(name+"-"+suffix+".png"))
        };window.orderOut(nil);window.alphaValue=0
    }
    @MainActor static func main()async {NSApplication.shared.setActivationPolicy(.prohibited);do {try await verify();print("PASS Tool source family: labelled native program completion, captured Browse context and validation, duplicate/Cancel/owner retirement, Quit ownership, grouped Advanced layout, table focus return and merge-only acceptance")}catch {fputs("Tool source failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify()async throws {
        let fm=FileManager.default,root=URL(fileURLWithPath:CommandLine.arguments[1]);try fm.createDirectory(at:root,withIntermediateDirectories:true)
        let suite="TurtleGit.ToolSource."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        let executable=root.appendingPathComponent("fixture tool"),ordinary=root.appendingPathComponent("plain.txt")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to:executable);try fm.setAttributes([.posixPermissions:0o755],ofItemAtPath:executable.path);try Data("plain".utf8).write(to:ordinary)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:520),styleMask:[.titled,.closable],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.alphaValue=0
        defer {window.contentView=nil;window.close()}
        let chooser=ToolApplicationChooser();chooser.window=window;defer {chooser.cancel()}
        var replies:[(NSApplication.ModalResponse)->Void]=[],panels:[NSOpenPanel]=[],selected=executable,bookmarks=0,accepted=0,errors=0,current=true
        chooser.present={panel,_,reply in panels.append(panel);replies.append(reply)};chooser.selectedURL={_ in selected};chooser.bookmark={_ in bookmarks += 1;return Data("private tool grant".utf8)}
        func browse(){chooser.choose({_,_ in accepted += 1},failure:{_ in errors += 1},allowExecutables:true,currentPath:executable.path,isCurrent:{current})}
        browse();browse()
        try require(replies.count==1 && chooser.selecting && ToolApplicationChooser.activeChoosers==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Browse duplicate/Quit gate missing")
        try require(panels[0].directoryURL?.path==root.path,"Browse did not start in the configured program folder")
        current=false;replies[0](.OK);try require(bookmarks==0 && accepted==0 && !chooser.selecting,"Changed draft accepted a bookmark")
        current=true;browse();replies[1](.OK);replies[1](.OK);try require(accepted==1 && bookmarks==1 && ToolApplicationChooser.activeChoosers==0,"Picker adopted twice")
        selected=ordinary;browse();replies[2](.OK);try require(errors==1 && bookmarks==1,"Non-executable file bookmarked")
        selected=root;browse();replies[3](.OK);try require(errors==2 && bookmarks==1,"Directory bookmarked as a tool")
        selected=executable;browse();replies[4](.cancel);try require(!chooser.selecting && accepted==1,"Cancel adopted picker")
        browse();chooser.cancel();replies[5](.OK);try require(!chooser.selecting && bookmarks==1,"Cancelled owner accepted late reply")
        browse();window.close();replies[6](.OK);try require(!chooser.selecting && ToolApplicationChooser.activeChoosers==0 && bookmarks==1,"Closed owner accepted a grant")
        // Actual shared Diff/Merge form, with captured draft identity in its Browse callback.
        let formWindow=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:420),styleMask:[.titled,.closable],backing:.buffered,defer:false);formWindow.isReleasedWhenClosed=false;formWindow.alphaValue=0
        let model=ToolSettingsDraft(DiffToolPreferences(),valid:{$0.valid},persist:{try $0.save(to:prefs)})
        model.value.program.enabled=true;model.value.program.applicationPath=executable.path
        let host=NSHostingView(rootView:ToolSourceFormHost(model:model,preferences:prefs));formWindow.contentView=host
        defer {formWindow.contentView=nil;formWindow.close()}
        host.layoutSubtreeIfNeeded();try await wait {views(host).contains {($0 as? PathEntryField.Field)?.accessibilityLabel()=="diff program"}}
        let field=views(host).compactMap {$0 as? PathEntryField.Field}.first!
        try require(field.isEnabled && field.isEditable && field.stringValue==executable.path && field.frame.height>=20,"Native path input missing/clipped")
        // SwiftUI static captions are drawing/AX elements, not NSTextFields.
        // Caption visibility is reviewed in the raw editor captures below.
        try require(views(host).compactMap {$0 as? NSTextField}.contains {$0 !== field && $0.stringValue==model.value.program.arguments},"Native arguments field lost its separate command template")
        model.value.program.bookmark=Data("old grant".utf8);field.coordinator?.changed("/usr/bin/diff")
        try require(model.value.program.applicationPath=="/usr/bin/diff" && model.value.program.bookmark==nil,"Typed program retained stale bookmark")
        model.value.program.enabled=false;try await wait {!field.isEnabled};model.value.program.enabled=true;try await wait {field.isEnabled}
        var a=DiffToolAssociation();a.pattern=".swift";a.program.enabled=true;a.program.applicationPath="/usr/bin/diff"
        var b=a;b.id=UUID();b.pattern=".txt"
        let associations=ToolAssociationsModel(associations:[b,a],tool:"diff")
        let advanced=NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:450),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);advanced.isReleasedWhenClosed=false;advanced.alphaValue=0;advanced.title="Advanced Diff Settings – TurtleGit"
        let advancedHost=NSHostingView(rootView:DiffToolAssociations(model:associations,completed:{_ in}).defaultAppStorage(prefs));advanced.contentView=advancedHost
        defer {advanced.contentView=nil;advanced.close()}
        advancedHost.layoutSubtreeIfNeeded();try await wait {views(advancedHost).contains {$0 is NSTableView}}
        let table=views(advancedHost).compactMap {$0 as? NSTableView}.first!
        associations.selected=b.id;advanced.makeFirstResponder(nil);associations.remove();try await wait {advanced.firstResponder === table}
        try require(associations.selected==a.id && table.selectedRow==0,"Remove focus/selection differs")
        associations.edit();advanced.makeFirstResponder(nil);associations.accept(nil);try await wait {advanced.firstResponder === table}
        associations.selected=a.id;associations.edit();let retired=associations.editorIdentity;associations.accept(nil,for:retired);associations.edit();let currentEditor=associations.editorIdentity
        associations.accept(nil,for:retired);try require(associations.editing?.id==a.id && associations.editorIdentity==currentEditor,"Retired Cancel dismissed a new association editor");associations.accept(nil,for:currentEditor)
        let merge=ToolAssociationsModel(associations:[],tool:"merge");merge.add();var unsupported=merge.editing!;unsupported.pattern=".png";unsupported.program.builtIn = .binaryReport
        merge.accept(unsupported);try require(merge.draft.isEmpty && merge.valid,"Diff-only adapter accepted into merge settings")
        if let output=ProcessInfo.processInfo.environment["TURTLEGIT_TOOL_CAPTURE"] {
            let folder=URL(fileURLWithPath:output);try await capture(advanced,name:"tool-associations",to:folder)
            let editor=NSWindow(contentRect:NSRect(x:0,y:0,width:650,height:500),styleMask:[.titled,.closable],backing:.buffered,defer:false);editor.isReleasedWhenClosed=false;editor.alphaValue=0;editor.title="Edit Diff Tool – TurtleGit"
            editor.contentView=NSHostingView(rootView:DiffToolAssociationEditor(entry:a,existing:[a],tool:"diff",completed:{_ in}).defaultAppStorage(prefs))
            defer {editor.contentView=nil;editor.close()}
            try await capture(editor,name:"tool-association-editor",to:folder)
        }
        try require(ToolApplicationChooser.activeChoosers==0,"Tool chooser count leaked")
    }
}
