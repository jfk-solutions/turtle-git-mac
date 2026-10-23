// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func groupedBlameFrame(_ rect:NSRect,to screen:NSScreen?)->NSRect{rect}
    @objc func groupedBlameOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));groupedBlameOrder(mode,relativeTo:number)}
}
@MainActor @main enum BlameGroupedComparisonsVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws{if !value{throw Failure(description:"Grouped Blame \(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T{guard let value else{throw Failure(description:message)};return value}
    static func views(_ root:NSView?)->[NSView]{guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func wait(_ window:NSWindow?=nil,line:Int = #line,_ ready:()->Bool)async throws{for _ in 0..<4000{window?.contentView?.layoutSubtreeIfNeeded();if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Grouped Blame timeout \(line)")}
    static func drained()->Bool{BlameWindowModel.activeHistoryOperations==0 && FileListComparisonSession.activeOperations==0 && BlameDocumentOpener.activeReads==0 && BlameWindowModel.activeSyntaxRequests==0}
    @MainActor final class Context {
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.GroupedBlame."+UUID().uuidString,prefs:UserDefaults
        let old="old 雪\n.txt",renamed="renamed 雪\n.txt",combined="combined 🧪.txt"
        var sourcePaths:[String]{[renamed,"origin β.txt","origin 🧪.txt","fourth.txt"]}
        var root:URL{base.appendingPathComponent("repository")};var repo:GitRepository!,workspace:RepositoryModel!,host:NSWindow!
        var owners:[NSWindowController]=[],children:[FileComparisonWindowController]=[],alternates:[Bool]=[],release:[()->Void]=[]
        var merge="",head=Data(),index=Data(),before=GitPathMap<Data>()
        init(){prefs=UserDefaults(suiteName:suite)!;for key in ["UseLibgit2","EnableLogCache","EnableGravatar"]{prefs.set(false,forKey:key)};prefs.set(3,forKey:"NumDiffWarning");var options=GitBlameOptions();options.detectionMode = .existingFiles;options.betweenFileCharacters=1;options.showCompleteLog=false;GitBlamePreferences.save(options,to:prefs)}
        func source(_ ordinal:Int,_ kind:String)->String {
            (0..<24).map{line in line==12 ? "\(kind) unique origin \(ordinal) payload with many alphanumeric characters repeated for reliable attribution\n":"stable origin \(ordinal) logical record \(line) retained as independent rename similarity context\n"}.joined()
        }
        func write(_ path:String,_ text:String)throws{try Data(text.utf8).write(to:root.appendingPathComponent(path))}
        func prepare()async throws {
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            repo=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
            _=try await repo.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","Grouped Blame QA"),("user.email","blame@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_=try await repo.run(["config",key,value])}
            let initial=[old]+Array(sourcePaths.dropFirst())
            for(index,path)in initial.enumerated(){try write(path,source(index,"base"))};try await repo.stage(["."]);_=try await repo.commit(message:"base origins")
            _=try await repo.run(["switch","-c","side"])
            for(index,path)in initial.enumerated(){try write(path,source(index,"side"))};try await repo.stage(["."]);_=try await repo.commit(message:"side origins")
            _=try await repo.run(["switch","main"])
            for(index,path)in initial.enumerated(){try write(path,source(index,"main"))};try await repo.stage(["."]);_=try await repo.commit(message:"main origins")
            let result=try await repo.run(["merge","--no-ff","--no-commit","side"],successfulExitCodes:0...1);try require(result.exitCode==1,"Private multi-origin merge did not conflict")
            for(index,path)in initial.enumerated(){try write(path,source(index,"merged"))};try await repo.stage(initial)
            _=try await repo.run(["mv","--",old,renamed]);_=try await repo.commit(message:"resolve and rename four origins");merge=try await repo.rebaseCommit("HEAD").hash
            try write(combined,sourcePaths.enumerated().map{source($0.offset,"merged")}.joined());try await repo.stage([combined]);_=try await repo.commit(message:"copy all origins for blame")
            head=try await repo.run(["rev-parse","HEAD"]).stdout;index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
            for path in sourcePaths+[combined]{before[path]=try Data(contentsOf:root.appendingPathComponent(path))}
            let store=try RepositoryAccessStore(storageURL:base.appendingPathComponent("access.json"))
            workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{[git] in GitRepository(root:$0,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))},snapshotWriter:{_ in false},savedAccessStore:store,cachePersistenceDefaults:prefs,publishCachePersistence:{_ in})
            workspace.fileComparisonPreferences=prefs;workspace.notifyFinder={}
            host=NSWindow(contentRect:.init(x:-24000,y:-24000,width:500,height:300),styleMask:[.titled,.closable],backing:.buffered,defer:false);host.isReleasedWhenClosed=false;host.alphaValue=0;host.orderFront(nil);workspace.workspaceWindow=host
            workspace.fileComparisonWindowPresentation={ [weak self] owner in guard let self else{return};self.children.append(owner);self.owners.append(owner);self.alternates.append(ComparisonToolInvocation.capture);owner.showWindow(nil);owner.window?.orderFront(nil)}
            workspace.open(root);try await wait(host){self.workspace.root?.resolvingSymlinksInPath()==self.root.resolvingSymlinksInPath() && !self.workspace.busy}
        }
        func blame()async throws->BlameWindowController {
            workspace.activate(.blame,paths:[combined])
            try await wait{self.workspace.blameWindows.values.contains{!$0.model.retired && $0.model.path==self.combined}}
            let owner=try unwrap(workspace.blameWindows.values.first{!$0.model.retired && $0.model.path==combined},"Workspace did not publish actual Blame owner")
            owners.append(owner)
            try await wait(owner.window){!owner.model.busy && !owner.model.syntaxWorking && owner.model.historyEntries.contains{$0.hash==self.merge} && owner.model.onOwnedChanges != nil && drained()}
            let origins=GitPathSet(owner.model.lines.filter{$0.hash==merge}.map(\.filename))
            try require(origins==GitPathSet(sourcePaths),"Actual copied-line Blame did not retain four UTF-8 origin paths: \(origins)")
            return owner
        }
        func choices(_ owner:BlameWindowController)async throws->(BlameWindowModel.HistoryTarget,[GitBlameParentComparison]) {
            let model=owner.model,entry=try unwrap(model.historyEntries.first{$0.hash==merge},"Merge history entry missing")
            model.selectedLogHashes=[merge]
            let target=try unwrap(model.historyTarget([entry]),"Actual history action target refused")
            var answer:[GitBlameParentComparison]?
            model.prepareHistoryParents(target){answer=$0};try await wait{answer != nil && drained()}
            let choices=try unwrap(answer,"Parent reader returned no answer")
            try require(choices.count==8 && Set(choices.map(\.parentNumber))==[1,2],"Actual merge parent/origin choices omitted paths: \(choices.map{($0.parentNumber,$0.path)})")
            try require(choices.filter{$0.comparison.files.first?.oldPath==old}.count==2,"Both parent comparisons lost rename preimage")
            return(target,choices)
        }
        func closeChildren()async throws{let closing=children;closing.forEach{$0.close()};children=[];alternates=[];try await wait{self.workspace.fileComparisonWindows.isEmpty && closing.allSatisfy{!$0.model.mergeToolHasPendingWork}}}
        func preserved()async throws{let final=try await repo.run(["rev-parse","HEAD"]).stdout;try require(final==head && (try Data(contentsOf:root.appendingPathComponent(".git/index")))==index,"Blame comparison changed repository/index");for(path,bytes)in before{try require((try Data(contentsOf:root.appendingPathComponent(path)))==bytes,"Blame changed working bytes")}}
        func clean()async{release.forEach{$0()};release=[];owners.forEach{owner in if let window=owner.window,let sheet=window.attachedSheet{window.endSheet(sheet,returnCode:.abort);sheet.close()};owner.close()};workspace?.stopMonitoringForTermination();host?.close();for _ in 0..<4000{if drained() && workspace?.busy != true{break};try? await Task.sleep(nanoseconds:10_000_000)};prefs.removePersistentDomain(forName:suite)}
    }
    static func aggregate(_ c:Context)async throws {
        let owner=try await c.blame(),model=owner.model
        var confirmations:[Int]=[]
        c.workspace.fileComparisonQuestion={count in confirmations.append(count);return false}
        let(target,all)=try await c.choices(owner),first=all.filter{$0.parentNumber==1}
        model.performHistoryParent(target,choices:first,action:.compare)
        try await wait{drained() && !c.workspace.busy}
        try require(confirmations==[4] && c.children.isEmpty,"Denied aggregate confirmation opened a child or counted only one path")
        for (number,alternate) in [(1,false),(2,true)] {
            c.workspace.fileComparisonQuestion={count in confirmations.append(count);return true}
            let(target,all)=try await c.choices(owner),chosen=all.filter{$0.parentNumber==number}
            model.performHistoryParent(target,choices:chosen,action:.compare,alternate:alternate)
            try await wait{drained() && !c.workspace.busy && c.children.count==4 && c.children.allSatisfy{!$0.model.busy && $0.model.document != nil}}
            try require(confirmations.last==4 && confirmations.count==number+1,"Comparison asked repeated/per-file questions")
            try require(c.alternates==Array(repeating:alternate,count:4),"Async aggregate lost captured normal/Shift tool selection")
            for (child,choice) in zip(c.children,chosen) {
                let document=try unwrap(child.model.document,"Actual workspace child did not load")
                let file=try unwrap(choice.comparison.files.first,"Missing selected parent file")
                let expectedBase=try await c.repo.run(["cat-file","blob",choice.revision+":"+choice.path]).stdout
                let expectedNew=try await c.repo.run(["cat-file","blob",c.merge+":"+file.path]).stdout
                try require(document.base.path==choice.path && document.destination.path==file.path && document.base.revision==choice.comparison.from && document.destination.revision==choice.comparison.to,"Child order/rename/captured revisions changed")
                try require(document.base.bytes==expectedBase && document.destination.bytes==expectedNew,"Actual parent child loaded another occurrence's bytes")
                try require(child.model.comparisonDefaults === c.prefs && child.window?.alphaValue==0,"Child lost owning private settings/hidden presentation")
            }
            try await c.closeChildren()
        }
        try require(confirmations==[4,4,4],"Aggregate confirmation count/order differs")
    }
    static func held(_ c:Context,kind:String)async throws {
        let owner=try await c.blame(),model=owner.model
        let(target,all)=try await c.choices(owner),chosen=all.filter{$0.parentNumber==1}
        var reply:CheckedContinuation<Bool,Never>?,asked=0,askedCount=0
        c.workspace.fileComparisonQuestion={count in asked+=1;askedCount=count;return await withCheckedContinuation{reply=$0}}
        c.release.append{reply?.resume(returning:false);reply=nil}
        model.performHistoryParent(target,choices:chosen,action:.compare,alternate:true)
        try await wait{reply != nil && FileListComparisonSession.activeOperations==1 && model.hasPendingHistoryComparisons && c.workspace.busy}
        try require(askedCount==4,"Held question lost aggregate count")
        if kind=="close" {owner.close()}
        else if kind=="replace" {
            owner.chooseFile={_,_,answer in answer(c.root.appendingPathComponent(c.sourcePaths[1]))}
            owner.openDocument()
            try await wait{owner.model !== model && model.retired && owner.model.path==c.sourcePaths[1]}
        } else if kind=="busy" {model.busy=true}
        else {model.confirmingQuit=true;c.workspace.confirmingQuit=true}
        try require(c.children.isEmpty && asked==1 && FileListComparisonSession.activeOperations==1 && BlameWindowModel.activeHistoryOperations>0,"Late confirmation lost owned accounting or opened children")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Held comparison reply lost Quit drain fence")
        reply?.resume(returning:true);reply=nil
        try await wait{drained() && !c.workspace.busy}
        try require(c.children.isEmpty,"Cancelled/retired late reply opened comparison children")
        if kind=="quit"{model.confirmingQuit=false;c.workspace.confirmingQuit=false}
        if kind=="busy"{model.busy=false}
        owner.close()
    }
    static func actualQuestions(_ c:Context)async throws {
        let owner=try await c.blame(),model=owner.model,window=try unwrap(owner.window,"Actual question owner missing")
        c.workspace.fileComparisonQuestion=nil
        var pair=try await c.choices(owner)
        model.performHistoryParent(pair.0,choices:pair.1.filter{$0.parentNumber==1},action:.compare)
        try await wait{window.attachedSheet != nil && FileListComparisonSession.activeOperations==1 && model.hasPendingHistoryComparisons}
        let question=try unwrap(window.attachedSheet,"Actual aggregate NSAlert missing")
        try require(question.alphaValue==0 && question.sheetParent === window,"Actual aggregate question lost private invisible owner")
        let no=try unwrap(views(question.contentView).compactMap{$0 as? NSButton}.first{$0.title=="No"},"Actual aggregate NSAlert No button missing")
        no.performClick(nil)
        try await wait{question.sheetParent==nil && window.attachedSheet==nil && drained() && !c.workspace.busy}
        try require(c.children.isEmpty && !question.isVisible,"Actual declined question dispatched children or retained its native sheet")
        pair=try await c.choices(owner)
        model.performHistoryParent(pair.0,choices:pair.1.filter{$0.parentNumber==1},action:.compare)
        try await wait{window.attachedSheet != nil && FileListComparisonSession.activeOperations==1}
        let closingQuestion=try unwrap(window.attachedSheet,"Second actual aggregate NSAlert missing")
        owner.close()
        try await wait{model.retired && closingQuestion.sheetParent==nil && window.attachedSheet==nil && drained() && !c.workspace.busy}
        try require(c.children.isEmpty && !closingQuestion.isVisible,"Source-close cancellation retained actual question or dispatched viewers")
    }
    static func lifecycle(_ c:Context)async throws {
        for kind in ["close","replace","quit","busy"] {try await held(c,kind:kind)}
        try await actualQuestions(c)
        let owner=try await c.blame(),model=owner.model
        let(target,all)=try await c.choices(owner)
        let window=try unwrap(owner.window,"Missing source owner"),sheet=NSWindow(contentRect:.init(x:-24000,y:-24000,width:180,height:80),styleMask:[.titled],backing:.buffered,defer:false)
        sheet.isReleasedWhenClosed=false;sheet.alphaValue=0;window.beginSheet(sheet,completionHandler:{_ in})
        try await wait{window.attachedSheet === sheet}
        model.performHistoryParent(target,choices:all.filter{$0.parentNumber==1},action:.compare)
        try await wait{drained() && !c.workspace.busy};try require(c.children.isEmpty,"Attached source sheet admitted comparison batch")
        window.endSheet(sheet,returnCode:.abort);sheet.close();try await wait{sheet.sheetParent==nil}
        // A delayed actual parent read retains the real worker token and may
        // not publish a menu or viewers after its source owner retires.
        var parentReply:CheckedContinuation<[GitBlameParentComparison],Error>?,token:OperationCancellation?,completed=false
        model.readHistoryParents={_,_,value in token=value;return try await withCheckedThrowingContinuation{parentReply=$0}}
        model.reload();try await wait(owner.window){!model.busy && model.canFind && model.historyEntries.contains{$0.hash==c.merge}}
        let fresh=try unwrap(model.historyTarget([try unwrap(model.historyEntries.first{$0.hash==c.merge},"Missing reloaded merge")]),"Reloaded target unavailable")
        model.prepareHistoryParents(fresh){_ in completed=true};try await wait{parentReply != nil}
        c.release.append{parentReply?.resume(throwing:OperationCancellationFailure.cancelled);parentReply=nil}
        owner.close();try require(token?.isCancelled==true && BlameWindowModel.activeHistoryOperations>0,"Retired parent read lost token/ownership")
        parentReply?.resume(returning:all);parentReply=nil;try await wait{drained()}
        try require(!completed && c.children.isEmpty,"Late retired parent read published menu/viewers")
    }
    static func main()async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let pairs=[(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.groupedBlameFrame(_:to:)))),(class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:))),class_getInstanceMethod(NSWindow.self,#selector(NSWindow.groupedBlameOrder(_:relativeTo:))))]
        for(a,b)in pairs{if let a,let b{method_exchangeImplementations(a,b)}};defer{for(a,b)in pairs.reversed(){if let a,let b{method_exchangeImplementations(a,b)}}}
        let c=Context();DialogGeometry.install(preferences:c.prefs);defer{DialogGeometry.install(preferences:.standard)}
        do{try await c.prepare();let kind=CommandLine.arguments[3];switch kind{case "aggregate":try await aggregate(c);case "lifecycle":try await lifecycle(c);default:throw Failure(description:"Unknown grouped Blame case")};try await c.preserved();await c.clean();try require(drained() && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Grouped Blame windows/work survived cleanup");print("PASS: grouped blame "+kind);fflush(stdout)}catch{await c.clean();fputs("Grouped Blame failed: \(error)\n",stderr);exit(1)}
    }
}
