import AppKit
import TurtleGitCore
@main struct MergeResultColorsVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String)throws{if !value{throw Failure(description:message)}}
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool)async throws{for _ in 0..<2000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Merge result color timeout line \(line)")}
    @MainActor static func editors(_ view:NSView?)->[NSTextView]{guard let view else{return []};return (view as? NSTextView).map{[$0]} ?? view.subviews.flatMap{editors($0)}}
    @MainActor static func rgb(_ color:NSColor,_ appearance:NSAppearance)->UInt32?{var value:UInt32?;appearance.performAsCurrentDrawingAppearance{if let c=color.usingColorSpace(.sRGB){value=UInt32((c.redComponent*255).rounded())<<16|UInt32((c.greenComponent*255).rounded())<<8|UInt32((c.blueComponent*255).rounded())}};return value}
    @MainActor static func main()async{do{try await verify()}catch{fputs("Merge result colors failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify()async throws{
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),base=root.appendingPathComponent("base.txt"),mine=root.appendingPathComponent("mine.txt"),theirs=root.appendingPathComponent("theirs.txt"),output=root.appendingPathComponent("result.txt")
        let baseText="prefix\nbase\nmiddle\nfooter\n",mineText="prefix\nmine\nmiddle\nfooter\n",theirText="prefix\ntheirs\nmiddle\nfooter\n"
        for (file,text) in [(base,baseText),(mine,mineText),(theirs,theirText)]{try Data(text.utf8).write(to:file)}
        let suite="TurtleGit.ResultColors."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!;defer{prefs.removePersistentDomain(forName:suite);MergePalette.reload()}
        MergeGeneralPreferences(firstDifference:false,firstConflict:false).save(to:prefs)
        var colors=MergeColorPreferences();colors.light[.resolved]=UnifiedDiffColors(0x112233,0x123456);colors.dark[.resolved]=UnifiedDiffColors(0xabcdef,0x234567);colors.light[.modified]=UnifiedDiffColors(0,0x345678);colors.dark[.modified]=UnifiedDiffColors(0,0x456789);colors.light[.added]=UnifiedDiffColors(0x552211,0xffff00);colors.dark[.added]=UnifiedDiffColors(0x998877,0x535300);try colors.save(to:prefs);MergePalette.reload(defaults:prefs)
        let owner=TextConflictWindowController(repository:GitRepository(root:root,executable:git),access:nil,path:"mine.txt",workingMerge:try WorkingTextMerge(base:base,theirs:theirs,mine:mine),preferences:prefs),model=owner.model;defer{owner.close()}
        model.load();try await wait{!model.busy && !model.preparing && model.blocks.count==1};owner.window?.contentView?.layoutSubtreeIfNeeded();try await wait{editors(owner.window?.contentView).contains{$0.isEditable}}
        let view=editors(owner.window?.contentView).first{$0.isEditable}!
        model.choose(.mine);try await wait{model.result==mineText && model.resultStates.contains(.resolved) && view.string==model.resultDisplayText}
        let resolved=model.resultPresentation
        try require(model.resultStates==[.normal,.resolved,.normal,.normal] && model.locatorMap.columns[1].contains{$0.state == .resolved},"Resolved choice did not color actual result/locator")
        for (name,expected) in [(NSAppearance.Name.aqua,UInt32(0x123456)),(.darkAqua,0x234567)]{let appearance=NSAppearance(named:name)!;owner.window?.appearance=appearance;owner.window?.contentView?.layoutSubtreeIfNeeded();let offset=(view.string as NSString).range(of:"mine").location;let color=view.textStorage?.attribute(.backgroundColor,at:offset,effectiveRange:nil) as? NSColor;try require(color.flatMap{rgb($0,appearance)}==expected,"Resolved custom palette not painted")}
        view.insertText("PREFIX",replacementRange:NSRange(location:0,length:6));try await wait{model.result.hasPrefix("PREFIX") && model.canUndo}
        try require(model.resultStates==[.edited,.resolved,.normal,.normal],"Manual typing lost unaffected resolved/middle states")
        let typed=model.resultPresentation;model.undo();try await wait{model.result==mineText};try require(model.resultPresentation==resolved,"Typing Undo did not restore provenance")
        model.redo();try await wait{model.result.hasPrefix("PREFIX")};try require(model.resultPresentation==typed,"Typing Redo did not restore provenance")
        let appearance=NSAppearance(named:.darkAqua)!;owner.window?.appearance=appearance;owner.window?.contentView?.layoutSubtreeIfNeeded();try await wait{view.string==model.resultDisplayText}
        let background=view.textStorage?.attribute(.backgroundColor,at:0,effectiveRange:nil) as? NSColor,foreground=view.textStorage?.attribute(.foregroundColor,at:0,effectiveRange:nil) as? NSColor
        try require(background.flatMap{rgb($0,appearance)}==0x456789 && foreground.flatMap{rgb($0,appearance)}==0x998877,"Edited source channels not consumed")
        model.chooseStandaloneOutput={_,_ in output};model.save(markResolved:false);try await wait{!model.busy};try require(model.error==nil && String(contentsOf:output)==model.result && model.resultPresentation==typed,"Save changed provenance or bytes")
        let saved=try Data(contentsOf:output);model.load();try await wait{!model.busy && !model.preparing && model.blocks.count==1};try require(!model.resultStates.contains(.edited) && !model.resultStates.contains(.resolved) && Data(contentsOf:output)==saved,"Reload retained old edit provenance or modified saved result")
        owner.close()
        // Two-pane manual annotations drive colors without changing engine rows.
        let pair=FileComparisonWindowController(comparison:try WorkingFileComparison(base:base,destination:mine),permissions:[]);defer{pair.close()};pair.model.comparisonDefaults=prefs;pair.model.load();try await wait{!pair.model.busy && !pair.model.filtering && pair.model.alignment != nil}
        pair.window?.contentView?.layoutSubtreeIfNeeded();try await wait{editors(pair.window?.contentView).count==2};pair.model.activatePane(base:false);pair.model.editingEnabled=true
        let destination=editors(pair.window?.contentView).first{$0.string.contains("mine")}!;destination.insertText("PREFIX",replacementRange:NSRange(location:0,length:6));try await wait{pair.model.annotations(base:false).edited.count>0}
        try require(pair.model.displayCells(base:false).contains{$0.state == .edited} && pair.model.locatorMap.columns[2].contains{$0.state == .edited},"Two-pane manual edits did not reach color projection")
        pair.model.undo();try await wait{!pair.model.dirty};try require(!pair.model.displayCells(base:false).contains{$0.state == .edited},"Two-pane Undo retained edited state")
        try require(try Data(contentsOf:mine)==Data(mineText.utf8) && Data(contentsOf:base)==Data(baseText.utf8),"Color/history operations wrote source files");pair.close()
        print("Merge result colors: real resolution/locator states, custom light/dark result painting, native typing Undo/Redo provenance, edited foreground/background channels, saved exact bytes with retained states, reload reset, two-pane manual annotations/locator/Undo and unchanged source files. Owned windows closed.")
    }
}
