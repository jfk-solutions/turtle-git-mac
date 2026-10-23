// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func statisticsInteractionHiddenOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-20000,y:-20000));statisticsInteractionHiddenOrder(place,relativeTo:number)
    }
}
actor StatisticsInteractionWriterGate {
    private var continuation:CheckedContinuation<Void,Never>?
    private var released=false
    private(set) var entered=false
    private var token:OperationCancellation?
    var cancelled:Bool {token?.isCancelled==true}
    func write(_ data:Data,to url:URL,cancellation:OperationCancellation)async throws {
        entered=true;token=cancellation
        if !released {await withCheckedContinuation{continuation=$0}}
        try await StatisticsGraphExport.write(data:data,to:url,cancellation:cancellation)
    }
    func finish(){released=true;continuation?.resume();continuation=nil}
}
@MainActor @main enum StatisticsInteractionOwnershipVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value {throw Failure(description:"\(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else {throw Failure(description:message)};return value}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Statistics interaction timeout at \(line)")
    }
    static func drained()->Bool {StatisticsWindowController.activeExports==0 && StatisticsWindowModel.activeOperations==0}
    @MainActor final class Context {
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.StatisticsInteraction."+UUID().uuidString,prefs:UserDefaults
        var owners:[StatisticsWindowController]=[],entries:[LogEntry]=[],gates:[StatisticsInteractionWriterGate]=[]
        var index=Data(),head=Data(),config=Data()
        var repo:GitRepository {GitRepository(root:base.appendingPathComponent("repository"),executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))}
        init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"UseLibgit2")}
        func seed()async throws {
            try FileManager.default.createDirectory(at:repo.root,withIntermediateDirectories:true)
            _=try await repo.run(["init","-b","main"])
            for(key,value)in[("user.name","Statistics interaction QA"),("user.email","statistics@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
            for n in 0..<3 {
                try Data("Statistics \(n)\n".utf8).write(to:repo.root.appendingPathComponent("file.txt"))
                try await repo.stage(["file.txt"]);_=try await repo.commit(message:"Statistics interaction \(n)")
            }
            entries=try await repo.history()
            index=try Data(contentsOf:repo.root.appendingPathComponent(".git/index"));config=try Data(contentsOf:repo.root.appendingPathComponent(".git/config"));head=try await repo.run(["rev-parse","HEAD"]).stdout
        }
        func owner()async throws->StatisticsWindowController {
            let owner=StatisticsWindowController(repository:repo,access:RepositoryAccessLease(url:repo.root),entries:entries,defaults:prefs)
            owners.append(owner);owner.window?.orderFront(nil);owner.model.selectMetric(.commitsByDate);owner.model.selectStyle(.bar)
            try await wait{owner.canSaveGraph && owner.model.graph != nil};return owner
        }
        func preserved()async throws {
            let currentIndex=try Data(contentsOf:repo.root.appendingPathComponent(".git/index")),currentConfig=try Data(contentsOf:repo.root.appendingPathComponent(".git/config")),currentHead=try await repo.run(["rev-parse","HEAD"]).stdout
            try require(currentIndex==index && currentConfig==config && currentHead==head,"Statistics interaction changed repository state")
        }
        func clean()async {
            for gate in gates {await gate.finish()}
            owners.forEach{$0.close()}
            for window in NSApp.windows {if let sheet=window.attachedSheet {window.endSheet(sheet,returnCode:.cancel);sheet.orderOut(nil)};window.orderOut(nil);window.close()}
            for _ in 0..<3000 {if drained() && owners.allSatisfy({!$0.hasPendingWork}) {break};try? await Task.sleep(nanoseconds:10_000_000)}
            prefs.removePersistentDomain(forName:suite)
        }
    }
    @MainActor struct TooltipReceipt {
        let view:StatisticsVectorNativeView,tag:NSView.ToolTipTag,generation:Int,point:CGPoint
        func read()->String {view.view(view,stringForToolTip:tag,point:point,userData:UnsafeMutableRawPointer(bitPattern:generation))}
    }
    static func chart(in view:NSView?)->StatisticsVectorNativeView? {
        guard let view else{return nil}
        if let chart=view as? StatisticsVectorNativeView{return chart}
        return view.subviews.lazy.compactMap{chart(in:$0)}.first
    }
    static func receipt(_ owner:StatisticsWindowController)async throws->TooltipReceipt {
        try await wait {
            owner.window?.contentView?.layoutSubtreeIfNeeded()
            guard let view=chart(in:owner.window?.contentView),let bounds=view.drawing?.titleBounds,let tag=view.installedToolTip else{return false}
            return view.view(view,stringForToolTip:tag,point:CGPoint(x:bounds.midX,y:bounds.midY),userData:UnsafeMutableRawPointer(bitPattern:view.projectionGeneration)) == "Title"
        }
        let view=try unwrap(chart(in:owner.window?.contentView),"Actual hosted chart missing")
        let title=try unwrap(view.drawing?.titleBounds,"Hosted chart has no title bounds")
        return TooltipReceipt(view:view,tag:try unwrap(view.installedToolTip,"Hosted chart has no tooltip receipt"),generation:view.projectionGeneration,point:CGPoint(x:title.midX,y:title.midY))
    }
    static func ownerInteractions(_ c:Context)async throws {
        let owner=try await c.owner(),initial=try await receipt(owner)
        try require(initial.read()=="Title","Actual hosted chart did not answer live receipt")
        owner.model.selectStyle(.line)
        try require(initial.read().isEmpty,"Style mutation revived obsolete actual chart receipt")
        let line=try await receipt(owner)
        try require(line.read()=="Title","Style update did not install a live native tooltip")
        let epoch=owner.model.formRevision
        owner.model.confirmingQuit=true
        try require(line.read().isEmpty,"Quit confirmation kept chart hints interactive")
        owner.model.selectStyle(.bar,context:epoch)
        try require(owner.model.style == .line,"Quit allowed stale style command")
        owner.model.confirmingQuit=false
        try require(line.read().isEmpty,"Cancelled Quit revived an obsolete native tooltip")
        _=try await receipt(owner)
        let target=c.base.appendingPathComponent("cancelled.png")
        var reply:((NSApplication.ModalResponse)->Void)?
        owner.selectedSaveURL={_ in target};owner.presentSavePanel={panel,parent,completion in reply=completion;parent.beginSheet(panel)}
        let beforePanel=try await receipt(owner)
        owner.saveGraphAs()
        try require(owner.savePanel?.panel.sheetParent === owner.window && beforePanel.read().isEmpty,"Actual save sheet did not fence chart tooltip")
        try require(!owner.windowShouldClose(owner.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Save sheet lost close/Quit ownership")
        reply?(.cancel);reply?(.OK)
        try await wait{!owner.hasPendingWork && owner.canSaveGraph}
        try require(beforePanel.read().isEmpty && !FileManager.default.fileExists(atPath:target.path),"Cancelled chooser revived stale tooltip or wrote target")
        let afterPanel=try await receipt(owner)
        var closed=0;owner.onClosed={closed += 1};owner.close()
        try await wait{closed==1 && !owner.hasPendingWork}
        try require(afterPanel.read().isEmpty && owner.model.retired,"Closed actual chart retained live receipt")
        try await c.preserved()
    }
    static func writerOwnership(_ c:Context)async throws {
        let owner=try await c.owner(),live=try await receipt(owner),gate=StatisticsInteractionWriterGate();c.gates.append(gate)
        let target=c.base.appendingPathComponent("held.png"),sentinel=Data("held destination".utf8);try sentinel.write(to:target)
        owner.writeGraph={data,url,token in try await gate.write(data,to:url,cancellation:token)}
        owner.selectedSaveURL={_ in target};owner.presentSavePanel={_,_,reply in reply(.OK)}
        var closed=0;owner.onClosed={closed += 1};owner.saveGraphAs()
        var entered=false
        for _ in 0..<3000 {if await gate.entered {entered=true;break};try await Task.sleep(nanoseconds:10_000_000)}
        try require(entered && live.read().isEmpty,"Held accepted writer kept actual chart interactive")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit ignored accepted chart writer")
        owner.close()
        try require(closed==0 && owner.hasPendingWork,"Close released chart before writer settlement")
        let cancelled=await gate.cancelled;try require(cancelled,"Close did not cancel accepted graph writer")
        await gate.finish();try await wait{closed==1 && !owner.hasPendingWork && drained()}
        try require(live.read().isEmpty && (try Data(contentsOf:target))==sentinel,"Late writer revived chart or overwrote cancelled destination")
        let failed=try await c.owner(),beforeFailure=try await receipt(failed)
        var alert:NSAlert?,answer:((NSApplication.ModalResponse)->Void)?
        failed.writeGraph={_,_,_ in throw NSError(domain:"Private Statistics interaction writer failure",code:19)}
        failed.selectedSaveURL={_ in target};failed.presentSavePanel={_,_,reply in reply(.OK)}
        failed.presentExportError={question,parent,reply in alert=question;answer=reply;question.beginSheetModal(for:parent,completionHandler:reply)}
        failed.saveGraphAs();try await wait{alert?.window.sheetParent === failed.window}
        try require(beforeFailure.read().isEmpty && failed.hasPendingWork,"Actual error sheet allowed old chart receipt")
        try require(!failed.windowShouldClose(failed.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Actual error sheet lost close/Quit guard")
        let question=try unwrap(alert,"Actual error sheet missing");question.buttons[0].performClick(nil)
        try await wait{!failed.hasPendingWork && failed.canSaveGraph && question.window.sheetParent==nil}
        answer?(.alertFirstButtonReturn)
        try require(beforeFailure.read().isEmpty,"Duplicate error reply revived obsolete actual chart receipt")
        let resumed=try await receipt(failed)
        try require(resumed.read()=="Title" && (try Data(contentsOf:target))==sentinel,"Dismissed error did not restore fresh chart safely")
        try await c.preserved()
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.statisticsInteractionHiddenOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden);defer{method_exchangeImplementations(original,hidden)}
        let c=Context();DialogGeometry.install(preferences:c.prefs);defer{DialogGeometry.install(preferences:.standard)}
        do {
            try await c.seed();let which=CommandLine.arguments[3]
            switch which {case "scene":try StatisticsInteractionVerification.verify();case "owner":try await ownerInteractions(c);case "writer":try await writerOwnership(c);default:throw Failure(description:"Unknown statistics interaction case")}
            await c.clean();try require(drained() && c.owners.allSatisfy{!$0.hasPendingWork} && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Statistics chart ownership did not drain")
            print("PASS: Statistics interaction family "+which)
        }catch {await c.clean();throw error}
    }
}
