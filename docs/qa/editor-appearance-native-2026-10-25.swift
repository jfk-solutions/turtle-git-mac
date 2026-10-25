// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import ObjectiveC
import TurtleGitCore

@MainActor enum EditorAppearanceVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    // Objective-C subview enumeration avoids forcing Swift's array bridge over
    // decorated SwiftUI row classes; production editor objects remain unchanged.
    static func views(_ root:NSView?)->[NSView] {
        guard let root else{return []};var result=[root]
        if let children=root.value(forKey:"subviews") as? NSArray {
            for index in 0..<children.count {let object=children.object(at:index) as AnyObject
                if let viewObject=object as? NSObject,viewObject.isKind(of:NSView.self) {result += views(unsafeBitCast(object,to:NSView.self))}
            }
        };return result
    }
    static func wait(_ window:NSWindow?=nil,line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {window?.contentView?.layoutSubtreeIfNeeded();if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Appearance readiness timeout at \(line)")
    }
    static func rgb(_ color:NSColor,appearance:NSAppearance)->UInt32? {
        var value:UInt32?;appearance.performAsCurrentDrawingAppearance {if let c=color.usingColorSpace(.sRGB) {value=UInt32((c.redComponent*255).rounded())<<16|UInt32((c.greenComponent*255).rounded())<<8|UInt32((c.blueComponent*255).rounded())}};return value
    }
    static func texts(_ window:NSWindow?)->[NSTextView] {views(window?.contentView).compactMap{$0 as? NSTextView}}
    static func panes(_ window:NSWindow?)->[NSTextView] {texts(window).filter{$0 is MergeFindProviding}}
    static func color(_ text:NSTextView,_ expected:UInt32,foreground:UInt32?=nil)throws {
        try require(rgb(text.backgroundColor,appearance:text.effectiveAppearance)==expected,"Native backdrop differs: expected \(String(expected,radix:16)) actual \(String(describing:rgb(text.backgroundColor,appearance:text.effectiveAppearance)))")
        if let clip=text.enclosingScrollView?.contentView {try require(rgb(clip.backgroundColor,appearance:text.effectiveAppearance)==expected,"Clip backdrop did not follow text appearance")}
        if let foreground {try require(rgb(text.insertionPointColor,appearance:text.effectiveAppearance)==foreground,"Native insertion point lost private foreground")}
        try require(text.selectedTextAttributes[.backgroundColor] is NSColor && text.selectedTextAttributes[.foregroundColor] is NSColor,"Native selection colors are incomplete")
    }
    static func captures(_ window:NSWindow,_ name:String) throws {
        guard let directory=ProcessInfo.processInfo.environment["TURTLEGIT_APPEARANCE_CAPTURE"] else{return}
        guard let content=window.contentView,content.bounds.width>500,content.bounds.height>300 else{throw Failure(description:"Incomplete capture surface")}
        content.layoutSubtreeIfNeeded();content.displayIfNeeded()
        guard let bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds) else{throw Failure(description:"Public native view bitmap unavailable")}
        content.cacheDisplay(in:content.bounds,to:bitmap)
        guard let data=bitmap.representation(using:.png,properties:[:]),data.count>1000 else{throw Failure(description:"Blank native surface capture")}
        let folder=URL(fileURLWithPath:directory,isDirectory:true);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        try data.write(to:folder.appendingPathComponent(name+".png"))
    }
    @MainActor final class Context {
        let root:URL,git:URL,suite:String,prefs:UserDefaults
        var owners=[NSWindowController](),additionalSuites=[String]()
        init(){root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true);git=URL(fileURLWithPath:CommandLine.arguments[2]);suite="TurtleGit.EditorAppearance."+UUID().uuidString;prefs=UserDefaults(suiteName:suite)!
            for key in ["HintStagingMode","HintHierarchicalConfig","Commit.SkipCancelConfirmation"] {prefs.set(true,forKey:key)}
            prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"SelectFilesForCommit")
            MergeGeneralPreferences(fontName:"Menlo",fontSize:13,firstDifference:false,firstConflict:false).save(to:prefs)
        }
        func own<T:NSWindowController>(_ controller:T)->T {owners.append(controller);if let w=controller.window {w.isReleasedWhenClosed=false;w.alphaValue=0;w.setFrameOrigin(.init(x:-12000,y:-12000));w.orderFront(nil)};return controller}
        func repository(_ name:String,_ content:String)async throws->GitRepository {
            let folder=root.appendingPathComponent(name,isDirectory:true);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let repo=GitRepository(root:folder,executable:git,libgit2Configuration:.init(enabled:false));_=try await repo.run(["init","-b","main"])
            for(key,value)in[("user.name","Appearance QA"),("user.email","appearance@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("tgit.commitstagingsupport","true")] {_=try await repo.run(["config",key,value])}
            try Data(content.utf8).write(to:folder.appendingPathComponent("sample.txt"));try await repo.stage(["sample.txt"]);_=try await repo.commit(message:"base");return repo
        }
        func drained()->Bool {CommitWindowModel.activeReloads==0 && CommitWindowModel.activeFileOperations==0 && CommitWindowModel.activeMetadataOperations==0 && CommitWindowModel.activePreferenceOperations==0 && MergeRegexOperations.activeRequests==0 && PatchWindowModel.activeOperations==0 && owners.allSatisfy{owner in (owner as? FileComparisonWindowController)?.model.mergeToolHasPendingWork != true && (owner as? TextConflictWindowController)?.model.mergeToolHasPendingWork != true}}
        func cleanup()async {for owner in owners.reversed(){owner.close()};for window in NSApp.windows {if let parent=window.sheetParent {parent.endSheet(window,returnCode:.cancel)};window.orderOut(nil);window.close()};for _ in 0..<3000 {if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)};prefs.removePersistentDomain(forName:suite);for name in additionalSuites {UserDefaults.standard.removePersistentDomain(forName:name)}}
    }
    static func commitReady(_ owner:CommitWindowController)async throws {
        try await wait(owner.window){let m=owner.model;return !m.busy && !m.fileWorkPending && !m.stagingStateNeedsRefresh && m.changelistsLoaded && m.commitIdentityPrepared && !m.loadingAuthorIdentity && !m.loadingAuthorDate && !m.loadingAmendMessage && !m.stagingHintVisible && m.guiPatch?.busy != true}
    }
    static func commit(_ c:Context)async throws {
        let before=(0..<160).map{"unchanged \($0)"}.joined(separator:"\n")+"\n",repo=try await c.repository("commit",before)
        let file=repo.root.appendingPathComponent("sample.txt"),changed=before.replacingOccurrences(of:"unchanged 90",with:"changed 90 🦎")
        try Data(changed.utf8).write(to:file)
        var appearance=UnifiedDiffAppearance();appearance.fontName="Menlo";appearance.fontSize=13
        appearance.light[.context] = .init(0x18222c,0xf6f3ed);appearance.dark[.context] = .init(0xe6dcc9,0x192534)
        appearance.light[.added] = .init(0x123b16,0xd5f2d7);appearance.dark[.added] = .init(0xc8f1ca,0x174025);appearance.save(to:c.prefs)
        c.prefs.set(true,forKey:"TurtleGit.Commit.GitGuiInterface")
        let owner=c.own(CommitWindowController(repository:repo,access:nil,defaults:c.prefs)),model=owner.model
        owner.window?.setContentSize(.init(width:1180,height:850));model.reload(paths:["."]);try await commitReady(owner)
        model.refreshGuiPatch();try await commitReady(owner)
        guard let patch=model.guiPatch else{throw Failure(description:"Actual GitGui embedded patch missing")}
        for (name,dark) in [("light",false),("dark",true)] {
            owner.window?.appearance=NSAppearance(named:dark ? .darkAqua:.aqua);model.objectWillChange.send()
            try await wait(owner.window){patch.darkMode==dark && texts(owner.window).contains{$0 is PatchTextView.PatchText}}
            let text=texts(owner.window).first{$0 is PatchTextView.PatchText}!
            try color(text,appearance.colors(.context,dark:dark).background,foreground:appearance.colors(.context,dark:dark).foreground)
            try require(text.font?.pointSize==13,"Embedded patch ignored configured font size")
            try require(text.string.isEmpty,"Empty embedded patch acquired unrelated document")
            if let window=owner.window {try captures(window,"commit-empty-"+name)}
        }
        model.selectGuiFiles(["sample.txt"],staged:false);try await commitReady(owner)
        try await wait(owner.window){texts(owner.window).contains{$0 is PatchTextView.PatchText && $0.string.contains("changed 90")}}
        guard let text=texts(owner.window).first(where:{$0 is PatchTextView.PatchText}),let scroll=text.enclosingScrollView else{throw Failure(description:"Embedded text/scroll missing")}
        let indexBefore=try await repo.run(["write-tree"]).stdout,head=try await repo.run(["rev-parse","HEAD"]).stdout
        let range=(text.string as NSString).range(of:"changed 90"),document=Data(patch.document.text.utf8)
        text.setSelectedRange(range);text.scrollRangeToVisible(range)
        if let message=owner.messageEditor() {owner.window?.makeFirstResponder(message);message.insertText("Retained appearance draft",replacementRange:NSRange(location:0,length:0))}
        let draft=model.message,selection=text.selectedRange(),origin=scroll.contentView.bounds.origin
        scroll.isFindBarVisible=true
        for (name,dark) in [("light",false),("dark",true)] {
            owner.window?.appearance=NSAppearance(named:dark ? .darkAqua:.aqua);model.objectWillChange.send()
            try await wait(owner.window){patch.darkMode==dark && rgb(text.backgroundColor,appearance:text.effectiveAppearance)==appearance.colors(.context,dark:dark).background}
            try color(text,appearance.colors(.context,dark:dark).background,foreground:appearance.colors(.context,dark:dark).foreground)
            try require(Data(patch.document.text.utf8)==document && text.selectedRange()==selection && abs(scroll.contentView.bounds.origin.y-origin.y)<1 && scroll.isFindBarVisible && model.message==draft,"Appearance reset embedded patch state or Commit message")
            if let window=owner.window {try captures(window,"commit-populated-"+name)}
        }
        guard let message=owner.messageEditor(),message.undoManager?.canUndo==true else{throw Failure(description:"Actual Commit message Undo missing")}
        message.undoManager?.undo();try await wait(owner.window){model.message != draft}
        let revision=patch.appearanceRevision
        let sameSuite=UserDefaults(suiteName:c.suite)!
        var sameSettings=appearance;sameSettings.fontSize=14;sameSettings.save(to:sameSuite)
        NotificationCenter.default.post(name:.unifiedDiffAppearanceChanged,object:sameSuite)
        try await wait(owner.window){patch.appearanceRevision>revision && text.font?.pointSize==14}
        let acceptedRevision=patch.appearanceRevision,foreignSuite=c.suite+".foreign",foreign=UserDefaults(suiteName:foreignSuite)!
        c.additionalSuites.append(foreignSuite);var foreignSettings=sameSettings;foreignSettings.fontSize=23;foreignSettings.save(to:foreign)
        NotificationCenter.default.post(name:.unifiedDiffAppearanceChanged,object:foreign)
        await Task.yield();await Task.yield()
        try require(patch.appearanceRevision==acceptedRevision && text.font?.pointSize==14,"Unrelated preferences changed embedded palette/font")
        let preAppearanceTree=try await repo.run(["write-tree"]).stdout
        try require(preAppearanceTree==indexBefore,"Appearance altered Git index")
        patch.selectedLines=Set(0..<patch.document.lines.count);patch.apply(entireHunks:true);try await commitReady(owner)
        let staged=try await repo.run(["show",":sample.txt"]).stdout;try require(staged==Data(changed.utf8),"Actual embedded staging did not apply selected chunk")
        model.selectGuiFiles(["sample.txt"],staged:true);try await commitReady(owner)
        guard let stagedPatch=model.guiPatch else{throw Failure(description:"Staged preview missing")}
        stagedPatch.selectedLines=Set(0..<stagedPatch.document.lines.count);stagedPatch.apply(entireHunks:true);try await commitReady(owner)
        let treeAfter=try await repo.run(["write-tree"]).stdout,headAfter=try await repo.run(["rev-parse","HEAD"]).stdout
        let workingAfter=try Data(contentsOf:file)
        try require(treeAfter==indexBefore && headAfter==head && workingAfter==Data(changed.utf8),"Stage/Unstage changed HEAD or working content")
        let standalone=c.own(PatchWindowController(documentDirectory:c.root,preferences:c.prefs))
        try require(standalone.window?.appearance==nil,"Standalone Patch default forces a stale appearance")
        let source="diff --git a/example b/example\n--- a/example\n+++ b/example\n@@ -1 +1 @@\n-old\n+new\n"
        standalone.presentDocument(Data(source.utf8),title:"Appearance patch",comparison:"Private standalone",information:"Unsaved appearance fixture")
        try await wait(standalone.window){texts(standalone.window).contains{$0 is PatchTextView.PatchText && $0.isEditable && $0.string==source}}
        let editable=texts(standalone.window).first{$0 is PatchTextView.PatchText}!
        standalone.window?.makeFirstResponder(editable);editable.insertText("retained",replacementRange:(editable.string as NSString).range(of:"new"))
        try await wait(standalone.window){standalone.model.document.text.contains("retained")}
        let retained=standalone.model.document.text,caret=editable.selectedRange();editable.enclosingScrollView?.isFindBarVisible=true
        for dark in [true,false] {standalone.setDarkMode(dark);try await wait(standalone.window){rgb(editable.backgroundColor,appearance:editable.effectiveAppearance)==sameSettings.colors(.context,dark:dark).background};try require(standalone.model.document.text==retained && editable.selectedRange()==caret && editable.undoManager?.canUndo==true && editable.enclosingScrollView?.isFindBarVisible==true,"Standalone appearance override reset native editing state")}
        editable.undoManager?.undo();try await wait(standalone.window){standalone.model.document.text==source}
        // colorSchemeContrast is a read-only SwiftUI environment value. This
        // receiver does not mutate global accessibility preferences or add a
        // production test seam; increased-contrast runtime acceptance is open.

    }
    static func mergePalette(_ prefs:UserDefaults,alternate:Bool=false)throws->MergeColorPreferences {
        var p=MergeColorPreferences();p.light[.normal] = .init(0x172331,alternate ? 0xece5d1:0xf5f1e8);p.dark[.normal] = .init(0xdde6f1,alternate ? 0x302418:0x182838)
        p.light[.added] = .init(0x123b16,0xd8efd9);p.dark[.added] = .init(0xd3f4d6,0x214828)
        p.light[.removed] = .init(0x431b1b,0xf1d6d1);p.dark[.removed] = .init(0xf5d5d0,0x4b2823)
        try p.save(to:prefs);return p
    }
    static func comparisonReady(_ owner:FileComparisonWindowController)async throws {
        try await wait(owner.window){let m=owner.model;return !m.busy && !m.filtering && m.alignment != nil && !m.initialNavigationPending && panes(owner.window).count==(m.onePaneActive ? 1:2)}
    }
    static func compare(_ c:Context)async throws {
        let a=c.root.appendingPathComponent("left.txt"),b=c.root.appendingPathComponent("right.txt")
        let baseline=(0..<1500).map{"row \($0) alpha beta"}.joined(separator:"\n")+"\n",changed=baseline.replacingOccurrences(of:"row 1400",with:"changed 1400")
        try Data(baseline.utf8).write(to:a);try Data(changed.utf8).write(to:b)
        let p=try mergePalette(c.prefs),owner=c.own(FileComparisonWindowController(comparison:try WorkingFileComparison(base:a,destination:b),permissions:[],preferences:c.prefs)),model=owner.model
        owner.window?.setContentSize(.init(width:1180,height:800));model.load();try await comparisonReady(owner)
        guard let text=panes(owner.window).first(where:{$0.accessibilityLabel()=="Destination file"}),let scroll=text.enclosingScrollView else{throw Failure(description:"Actual destination editor missing")}
        try require(text.font?.pointSize==13,"Comparison ignored owning font preferences")
        model.activatePane(base:false);model.editingEnabled=true;try await wait(owner.window){text.isEditable}
        let replacement=(text.string as NSString).range(of:"changed 1400");text.insertText("edited 1400",replacementRange:replacement)
        try await comparisonReady(owner)
        let edited=model.draftText(base:false),selected=(text.string as NSString).range(of:"edited 1400");text.setSelectedRange(selected);text.scrollRangeToVisible(selected)
        (text as? MergeFindProviding)?.mergeFindHighlights.mark("alpha",in:text)
        let origin=scroll.contentView.bounds.origin;scroll.isFindBarVisible=true
        for (name,dark) in [("light",false),("dark",true)] {
            owner.window?.appearance=NSAppearance(named:dark ? .darkAqua:.aqua);model.objectWillChange.send()
            try await wait(owner.window){rgb(text.backgroundColor,appearance:text.effectiveAppearance)==p.colors(.normal,dark:dark).background}
            try color(text,p.colors(.normal,dark:dark).background,foreground:p.colors(.normal,dark:dark).foreground)
            try require(model.draftText(base:false)==edited && model.canUndo && text.selectedRange()==selected && abs(scroll.contentView.bounds.origin.y-origin.y)<1 && scroll.isFindBarVisible,"Long-document appearance reset edit/history/viewport")
            if let window=owner.window {try captures(window,"compare-long-"+name)}
        }
        model.undo();try await comparisonReady(owner);try require(model.draftText(base:false)==changed,"Appearance lost comparison Undo")
        model.redo();try await comparisonReady(owner);try require(model.draftText(base:false)==edited,"Appearance lost comparison Redo")
        model.undo();try await comparisonReady(owner);model.editingEnabled=false;model.switchPaneMode(true);try await comparisonReady(owner)
        try require(model.onePaneActive && panes(owner.window).count==1,"Combined one-pane ownership missing")
        for (name,dark) in [("light",false),("dark",true)] {owner.window?.appearance=NSAppearance(named:dark ? .darkAqua:.aqua);model.objectWillChange.send();try await wait(owner.window){panes(owner.window).allSatisfy{rgb($0.backgroundColor,appearance:$0.effectiveAppearance)==p.colors(.normal,dark:dark).background}};if let window=owner.window {try captures(window,"compare-onepane-"+name)}}
        let suite=c.suite+".other",other=UserDefaults(suiteName:suite)!;c.additionalSuites.append(suite);MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:other)
        let secondPalette=try mergePalette(other,alternate:true),second=c.own(FileComparisonWindowController(comparison:try WorkingFileComparison(base:a,destination:b),permissions:[],preferences:other));second.model.load();try await comparisonReady(second)
        second.window?.appearance=NSAppearance(named:.aqua);second.model.objectWillChange.send();try await wait(second.window){panes(second.window).allSatisfy{rgb($0.backgroundColor,appearance:$0.effectiveAppearance)==secondPalette.colors(.normal,dark:false).background}}
        try require(model.palette.preferences != second.model.palette.preferences,"Private windows shared a palette snapshot")
        owner.window?.appearance=NSAppearance(named:.aqua);model.objectWillChange.send()
        let settingsB=MergeColorsSettingsModel(preferences:other,dark:false)
        settingsB.setColor(0xd1e5f4,role:.normal,foreground:false)
        try require(settingsB.apply(),"Actual private B Settings Apply failed")
        try await wait(second.window){second.model.palette.preferences.colors(.normal,dark:false).background==0xd1e5f4 && panes(second.window).allSatisfy{rgb($0.backgroundColor,appearance:$0.effectiveAppearance)==0xd1e5f4}}
        try require(model.palette.preferences.colors(.normal,dark:false).background==p.colors(.normal,dark:false).background,"B Settings Apply changed A palette")
        let distinctA=UserDefaults(suiteName:c.suite)!,settingsA=MergeColorsSettingsModel(preferences:distinctA,dark:false)
        settingsA.setColor(0xe4efd2,role:.normal,foreground:false)
        try require(settingsA.apply(),"Same-suite distinct-instance Settings Apply failed")
        try await wait(owner.window){model.palette.preferences.colors(.normal,dark:false).background==0xe4efd2 && panes(owner.window).allSatisfy{rgb($0.backgroundColor,appearance:$0.effectiveAppearance)==0xe4efd2}}
        try require(second.model.palette.preferences.colors(.normal,dark:false).background==0xd1e5f4,"A Settings Apply changed B palette")

        let retainedA=try Data(contentsOf:a),retainedB=try Data(contentsOf:b)
        try require(retainedA==Data(baseline.utf8) && retainedB==Data(changed.utf8),"Appearance/history checks wrote comparison sources")
    }
    static func merge(_ c:Context)async throws {
        let baseline=(0..<1500).map{"row \($0) alpha"}.joined(separator:"\n")+"\n",repo=try await c.repository("merge",baseline),file=repo.root.appendingPathComponent("sample.txt")
        _=try await repo.run(["checkout","-b","side"]);try Data(baseline.replacingOccurrences(of:"row 1400",with:"theirs 1400").utf8).write(to:file);_=try await repo.run(["commit","-am","theirs"])
        _=try await repo.run(["checkout","main"]);try Data(baseline.replacingOccurrences(of:"row 1400",with:"mine 1400").utf8).write(to:file);_=try await repo.run(["commit","-am","mine"]);_=try await repo.run(["merge","side"],successfulExitCodes:0...1)
        let rawIndex=try Data(contentsOf:repo.root.appendingPathComponent(".git/index")),rawWorking=try Data(contentsOf:file),head=try await repo.run(["rev-parse","HEAD"]).stdout
        let p=try mergePalette(c.prefs),owner=c.own(TextConflictWindowController(repository:repo,access:nil,path:"sample.txt",preferences:c.prefs)),model=owner.model
        owner.window?.setContentSize(.init(width:1280,height:850));model.load()
        try await wait(owner.window){!model.busy && model.document != nil && panes(owner.window).contains{$0.isEditable}}
        guard let text=panes(owner.window).first(where:{$0.isEditable}),let scroll=text.enclosingScrollView else{throw Failure(description:"Actual result editor missing")}
        try require(text.font?.pointSize==13,"Merge ignored owning font preferences")
        let before=model.result;owner.window?.makeFirstResponder(text);text.insertText("approved ",replacementRange:NSRange(location:0,length:0))
        try await wait(owner.window){model.canUndo && model.result != before}
        let edited=model.result,selection=NSRange(location:min(edited.utf16.count,15000),length:0);text.setSelectedRange(selection);text.scrollRangeToVisible(selection)
        (text as? MergeFindProviding)?.mergeFindHighlights.mark("alpha",in:text);scroll.isFindBarVisible=true
        let origin=scroll.contentView.bounds.origin
        for (name,dark) in [("light",false),("dark",true)] {
            owner.window?.appearance=NSAppearance(named:dark ? .darkAqua:.aqua);model.objectWillChange.send()
            try await wait(owner.window){panes(owner.window).allSatisfy{rgb($0.backgroundColor,appearance:$0.effectiveAppearance)==p.colors(.normal,dark:dark).background}}
            for pane in panes(owner.window){try color(pane,p.colors(.normal,dark:dark).background,foreground:p.colors(.normal,dark:dark).foreground)}
            try require(model.result==edited && model.canUndo && text.selectedRange()==selection && abs(scroll.contentView.bounds.origin.y-origin.y)<1 && scroll.isFindBarVisible,"Merge appearance reset draft/Undo/find/viewport")
            if let window=owner.window {try captures(window,"merge-long-"+name)}
        }
        model.undo();try await wait(owner.window){model.result==before};model.redo();try await wait(owner.window){model.result==edited}
        let currentHead=try await repo.run(["rev-parse","HEAD"]).stdout
        let retainedWorking=try Data(contentsOf:file),retainedIndex=try Data(contentsOf:repo.root.appendingPathComponent(".git/index"))
        try require(retainedWorking==rawWorking && retainedIndex==rawIndex && currentHead==head,"Appearance or Undo saved/staged/changed conflict repository")
    }
    static func run(_ name:String)async throws {
        let c=Context();do {switch name {case "commit":try await commit(c);case "compare":try await compare(c);case "merge":try await merge(c);default:throw Failure(description:"Unknown appearance case")};await c.cleanup();try require(c.drained(),"Owned editor workers did not drain")}catch{let failure=error;await c.cleanup();throw failure}
    }
}
