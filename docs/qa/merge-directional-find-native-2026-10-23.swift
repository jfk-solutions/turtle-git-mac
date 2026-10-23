// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func directionalFindFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect{rect}
    @objc func directionalFindOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));directionalFindOrder(mode,relativeTo:number)}
}
@MainActor @main enum MergeDirectionalFindVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws{if !value{throw Failure(description:"Directional Find \(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T{guard let value else{throw Failure(description:message)};return value}
    static func wait(_ owner:NSWindow?=nil,line:Int = #line,_ ready:()->Bool)async throws{for _ in 0..<3000{owner?.contentView?.layoutSubtreeIfNeeded();if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Directional Find timeout \(line)")}
    static func views(_ view:NSView?)->[NSView]{guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    static let common="aaa\nxcat\ncatx\naa aa\nsame aa\n"
    @MainActor final class Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.DirectionalFind."+UUID().uuidString,prefs:UserDefaults
        var owners:[NSWindowController]=[]
        init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"UseLibgit2");prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"TurtleGitMerge.Collapsed");prefs.set(true,forKey:"TurtleGitMerge.PreferUTF8")}
        func own<T:NSWindowController>(_ owner:T)->T{owners.append(owner);owner.showWindow(nil);owner.window?.alphaValue=0;owner.window?.orderFront(nil);return owner}
        func pair(readOnly:Bool=false)async throws->FileComparisonWindowController {
            let base=root.appendingPathComponent("base.txt"),mine=root.appendingPathComponent("mine.txt")
            try Data((common+"old aa\n").utf8).write(to:base);try Data((common+"new aa\n").utf8).write(to:mine)
            let owner=own(FileComparisonWindowController(comparison:try WorkingFileComparison(base:base,destination:mine),permissions:[],preferences:prefs,deferInitialLoad:true))
            owner.model.commentProfileURL=root.appendingPathComponent("ignorecomments.txt");owner.model.configureMergeToolReadOnly(readOnly);owner.model.beginTransferredDocument()
            try await wait(owner.window){!owner.model.busy && !owner.model.filtering && owner.model.alignment != nil}
            owner.model.setCollapsed(false)
            try await wait(owner.window){panes(owner).count==2 && panes(owner).allSatisfy{($0 as? MergeFindProviding)?.mergeFindAllowed==true}}
            return owner
        }
        func conflict()async throws->(TextConflictWindowController,GitRepository,Data,Data) {
            let folder=root.appendingPathComponent("repository");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let repo=GitRepository(root:folder,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false)),file=folder.appendingPathComponent("sample.txt")
            _=try await repo.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","Find QA"),("user.email","find@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
            try Data((common+"base aa\n").utf8).write(to:file);try await repo.stage(["sample.txt"]);_=try await repo.commit(message:"private base")
            _=try await repo.run(["checkout","-b","side"]);try Data((common+"theirs aa\n").utf8).write(to:file);_=try await repo.run(["commit","-am","theirs"])
            _=try await repo.run(["checkout","main"]);try Data((common+"mine aa\n").utf8).write(to:file);_=try await repo.run(["commit","-am","mine"])
            _=try await repo.run(["merge","side"],successfulExitCodes:0...1)
            let bytes=try Data(contentsOf:file),index=try Data(contentsOf:folder.appendingPathComponent(".git/index"))
            let owner=own(TextConflictWindowController(repository:repo,access:nil,path:"sample.txt"));owner.model.comparisonDefaults=prefs;owner.model.commentProfileURL=root.appendingPathComponent("ignorecomments.txt");owner.model.load()
            try await wait(owner.window){!owner.model.busy && owner.model.document != nil}
            owner.model.setCollapsed(false);owner.model.choose(.mineThenTheirs)
            // Choosing updates the model before SwiftUI installs the result's
            // source/presentation revision. An old editable pane is not yet an
            // authorized Find target; await its actual production readiness.
            try await wait(owner.window){!owner.model.busy && panes(owner).count==3 && !MergeText.hasMarkers(owner.model.result) && panes(owner).contains {
                $0.isEditable && ($0 as? MergeFindProviding)?.mergeFindAllowed==true &&
                $0.string.contains("mine aa") && $0.string.contains("theirs aa")
            }}
            return(owner,repo,bytes,index)
        }
        func clean()async{for owner in owners{if let window=owner.window,let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.abort);sheet.close()};owner.close()};owners=[];for _ in 0..<3000{if MergeRegexOperations.activeRequests==0{break};try? await Task.sleep(nanoseconds:10_000_000)};prefs.removePersistentDomain(forName:suite)}
    }
    static func panes(_ owner:NSWindowController)->[NSTextView]{views(owner.window?.contentView).compactMap{$0 as? NSTextView}.filter{$0 is MergeFindProviding}}
    static func attach(_ view:NSTextView,_ c:Context)->MergeFindWindowController {
        let find=MergeFindWindowController(text:view,defaults:c.prefs);(view as! MergeFindProviding).mergeFindController=find;c.owners.append(find);find.present(show:false);return find
    }
    static func configure(_ find:MergeFindWindowController,_ query:String,whole:Bool=false,up:Bool=false,modified:Bool=false){find.search.stringValue=query;find.matchCase.state = .on;find.wholeWord.state=whole ? .on:.off;find.searchUp.state=up ? .on:.off;find.modifiedOnly.state=modified ? .on:.off;find.updateGates()}
    static func line(_ text:NSTextView,_ value:String)throws->NSRange{let range=(text.string as NSString).range(of:value,options:.literal);try require(range.location != NSNotFound,"Required actual pane line missing: "+value);return range}
    static func navigation(_ view:NSTextView,_ find:MergeFindWindowController,_ owner:NSWindowController,expectedCount:Int)throws {
        let first=try line(view,"aaa"),target=view as! MergeFindProviding
        try require(target.mergeFindAllowed,"Find pane has not installed the current source/presentation receipt")
        configure(find,"aa");find.count();try require(find.status.stringValue=="\(expectedCount) match(es).","Count changed from nonoverlap projection: expected \(expectedCount), status \(find.status.stringValue), actual lines \(target.mergeFindLines.map(\.text))")
        try require(target.mergeFindHighlights.ranges.contains(.init(location:first.location,length:2)) && !target.mergeFindHighlights.ranges.contains(.init(location:first.location+1,length:2)),"Paint/count projection unexpectedly became overlapping")
        view.setSelectedRange(.init(location:first.location+1,length:0));find.find();try require(view.selectedRange()==NSRange(location:first.location+1,length:2),"Forward caret-bounded search omitted overlap not present in paint projection")
        view.setSelectedRange(.init(location:first.location+3,length:0));find.find(upwards:true);try require(view.selectedRange()==NSRange(location:first.location+1,length:2),"Reverse search omitted final overlapping candidate")
        // Native F3/Shift-F3 route to directional navigation, not painted ranges.
        owner.window?.makeFirstResponder(view)
        for(up,flags)in[(false,NSEvent.ModifierFlags()),(true,NSEvent.ModifierFlags.shift)] {
            view.setSelectedRange(.init(location:first.location+(up ? 3:1),length:0))
            let key=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:owner.window!.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:99)!
            try require(owner.window!.performKeyEquivalent(with:key) && view.selectedRange()==NSRange(location:first.location+1,length:2),"Native F3 directional wrapper fell back to nonoverlap projection")
        }
        let xcat=try line(view,"xcat"),catx=try line(view,"catx")
        configure(find,"cat",whole:true);find.count();try require(find.status.stringValue=="0 match(es).","Whole-line Count admitted partial words")
        view.setSelectedRange(.init(location:xcat.location+1,length:0));find.find();try require(view.selectedRange()==NSRange(location:xcat.location+1,length:3),"Forward whole-word search ignored source caret-cut boundary")
        view.setSelectedRange(.init(location:catx.location+3,length:0));find.find(upwards:true);try require(view.selectedRange()==NSRange(location:catx.location,length:3),"Reverse whole-word search ignored source caret-cut boundary")
        configure(find,"aa");view.setSelectedRange(.init(location:0,length:0));find.find(upwards:true)
        let last=try unwrap(MergeFind.matches("aa",in:target.mergeFindLines,options:MergeFindOptions(matchCase:true)).last,"Missing last wrap match")
        try require(view.selectedRange()==last && find.status.stringValue.contains("Top reached"),"Reverse wrap lost final match/status")
        let four=try line(view,"aa aa");view.setSelectedRange(.init(location:four.location,length:2));view.turtleFindSelectionNext(nil)
        try require(view.selectedRange()==NSRange(location:four.location+3,length:2),"Selected-text Find wrapper lost literal source query")
    }
    static func replacements(_ view:NSTextView,_ find:MergeFindWindowController,_ owner:NSWindowController,undo:()->Void,redo:()->Void)async throws {
        let before=view.string,pair=try line(view,"aa aa")
        configure(find,"aa",up:true);find.replacement.stringValue="X";view.setSelectedRange(.init(location:pair.location+3,length:2));find.replace(all:false)
        let single=(before as NSString).replacingCharacters(in:.init(location:pair.location,length:2),with:"X")
        try await wait(owner.window){view.string==single};try require(view.undoManager?.canUndo==true,"Single reverse Replace did not use native history")
        undo();try await wait(owner.window){view.string==before};redo();try await wait(owner.window){view.string==single};undo();try await wait(owner.window){view.string==before}
        configure(find,"aa");find.replacement.stringValue="Y";find.replace(all:true)
        let all=before.replacingOccurrences(of:"aa",with:"Y")
        try await wait(owner.window){view.string==all};try require(view.string.contains("Ya\n"),"Replace All changed from source nonoverlap consumption")
        undo();try await wait(owner.window){view.string==before}
    }
    static func compare(_ c:Context)async throws {
        let owner=try await c.pair();owner.model.activatePane(base:false);owner.model.editingEnabled=true
        try await wait(owner.window){panes(owner).contains{$0.isEditable && $0.string.contains("new aa")}}
        let view=try unwrap(panes(owner).first{$0.isEditable && $0.string.contains("new aa")},"Missing actual writable Compare pane"),find=attach(view,c)
        try navigation(view,find,owner,expectedCount:5)
        configure(find,"aa",modified:true);view.setSelectedRange(.init(location:0,length:0));find.find();let modified=try line(view,"new aa")
        try require(view.selectedRange()==NSRange(location:modified.location+4,length:2),"Modified-only navigation entered unchanged source lines")
        try await replacements(view,find,owner,undo:{owner.model.undo()},redo:{owner.model.redo()})
        let source=try unwrap(panes(owner).first{$0 !== view},"Missing readonly Compare source"),sourceFind=attach(source,c);configure(sourceFind,"aa");sourceFind.replacement.stringValue="Z";let original=source.string;sourceFind.replace(all:true)
        try require(!sourceFind.replaceButton.isEnabled && source.string==original,"Readonly source allowed Replace")
        try require((try Data(contentsOf:c.root.appendingPathComponent("base.txt")))==Data((common+"old aa\n").utf8) && (try Data(contentsOf:c.root.appendingPathComponent("mine.txt")))==Data((common+"new aa\n").utf8),"Find changed saved Compare input bytes")
    }
    static func merge(_ c:Context)async throws {
        let(owner,repo,working,index)=try await c.conflict()
        let view=try unwrap(panes(owner).first{$0.isEditable},"Missing actual Merge result"),find=attach(view,c)
        // The result keeps the removed base record in its aligned source view,
        // even though that record is excluded from the saved result. Source
        // Search includes IdenticalRemoved, also with Limit to modified lines.
        let intendedRows=["aaa","xcat","catx","aa aa","same aa","base aa","mine aa","theirs aa"]
        let resultLines=(view as! MergeFindProviding).mergeFindLines
        try require(resultLines.map(\.text)==intendedRows,"Resolved result lost the intended retained base/source display records")
        try require(resultLines[5].state.isRemoval && resultLines[5].state.isExcludedFromResult,"Retained base record is not a removed display-only source row")
        try require(owner.model.result==common+"mine aa\ntheirs aa\n","Resolved saved result unexpectedly retained the removed base record")
        // Four matches in common, one in each base/mine/theirs displayed record.
        try navigation(view,find,owner,expectedCount:7)
        configure(find,"aa",modified:true);view.setSelectedRange(.init(location:0,length:0));find.find()
        let changed=try line(view,"base aa")
        try require(view.selectedRange()==NSRange(location:changed.location+5,length:2),"Merge modified-only search skipped the first removed source row or entered unchanged context")
        try await replacements(view,find,owner,undo:{view.undoManager?.undo()},redo:{view.undoManager?.redo()})
        try require((try Data(contentsOf:repo.root.appendingPathComponent("sample.txt")))==working && (try Data(contentsOf:repo.root.appendingPathComponent(".git/index")))==index,"Merge Find changed working markers/index")
    }
    static func ownership(_ c:Context)async throws {
        let owner=try await c.pair();owner.model.activatePane(base:false);owner.model.editingEnabled=true
        try await wait(owner.window){panes(owner).contains{$0.isEditable}}
        let view=try unwrap(panes(owner).first{$0.isEditable},"Missing actual Find owner pane"),find=attach(view,c);configure(find,"aa");find.count()
        let selected=NSRange(location:1,length:0);view.setSelectedRange(selected);let before=view.string
        owner.model.confirmingQuit=true;find.find();find.replacement.stringValue="Z";find.replace(all:true);view.turtleFindSelectionNext(nil)
        try require(view.selectedRange()==selected && view.string==before && !find.findButton.isEnabled,"Quit allowed stale Find navigation or replacement")
        owner.model.confirmingQuit=false;owner.model.busy=true;find.find();find.replace(all:false);try require(view.selectedRange()==selected && view.string==before,"Busy owner accepted Find");owner.model.busy=false
        owner.close();find.find();find.replace(all:true);MergeFindInterface.perform(.nextMatch,in:view)
        try require(view.selectedRange()==selected && view.string==before && find.window?.parent==nil && !(view as! MergeFindProviding).mergeFindAllowed,"Closed pane revived Find or mutated selection/text")
        let readonly=try await c.pair(readOnly:true)
        let output=try unwrap(panes(readonly).first{$0.string.contains("new aa")},"Missing readonly output pane"),readonlyFind=attach(output,c)
        configure(readonlyFind,"aa");readonlyFind.replacement.stringValue="Z";let frozen=output.string
        output.setSelectedRange(.init(location:1,length:0));readonlyFind.find();readonlyFind.replace(all:true)
        try require(output.selectedRange()==NSRange(location:1,length:2) && output.string==frozen && !readonlyFind.replaceButton.isEnabled && !(output as! MergeFindProviding).mergeFindWritable,"Readonly output lost Find or accepted Replace")
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let hooks=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.directionalFindFrame(_:to:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.directionalFindOrder(_:relativeTo:))))]
        for(a,b)in hooks{if let a,let b{method_exchangeImplementations(a,b)}};defer{for(a,b)in hooks.reversed(){if let a,let b{method_exchangeImplementations(a,b)}}}
        let c=Context();DialogGeometry.install(preferences:c.prefs);defer{DialogGeometry.install(preferences:.standard)}
        do{let kind=CommandLine.arguments[3];switch kind{case "compare":try await compare(c);case "merge":try await merge(c);case "ownership":try await ownership(c);default:throw Failure(description:"Unknown search case")};await c.clean();try require(MergeRegexOperations.activeRequests==0 && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Owned Find windows/readers did not drain");print("PASS: directional Merge Find "+kind);fflush(stdout)}catch{await c.clean();fputs("Directional Merge Find failed: \(error)\n",stderr);exit(1)}
    }
}
