// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin
import ImageIO
import ObjectiveC
import PDFKit
import TurtleGitCore

private extension NSWindow {
    @objc func statisticsExportHiddenOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-20000,y:-20000));statisticsExportHiddenOrder(place,relativeTo:number)
    }
}
actor StatisticsExportWriteProbe {
    private(set) var records:[(Data,URL)]=[]
    func write(_ data:Data,to url:URL,cancellation:OperationCancellation)async throws {
        records.append((data,url));try await StatisticsGraphExport.write(data:data,to:url,cancellation:cancellation)
    }
}
actor StatisticsExportWriteGate {
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
    func finish() {released=true;continuation?.resume();continuation=nil}
}

@MainActor @main enum StatisticsExportFamilyVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value {throw Failure(description:"\(line): "+message)}}
    static func unwrap<T>(_ value:T?,_ message:String)throws->T {guard let value else {throw Failure(description:message)};return value}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Statistics export timeout at \(line)")
    }
    static func drained()->Bool {StatisticsWindowController.activeExports==0 && StatisticsWindowModel.activeOperations==0}
    @MainActor final class Context {
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.StatisticsExport."+UUID().uuidString,prefs:UserDefaults
        var owners:[StatisticsWindowController]=[],entries:[LogEntry]=[],gates:[StatisticsExportWriteGate]=[]
        var index=Data(),head=Data(),config=Data()
        var repo:GitRepository {GitRepository(root:base.appendingPathComponent("repository"),executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))}
        init(){prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"UseLibgit2")}
        func seed()async throws {
            try FileManager.default.createDirectory(at:repo.root,withIntermediateDirectories:true)
            _=try await repo.run(["init","-b","main"])
            for(key,value)in[("user.name","Statistics export QA"),("user.email","statistics@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
            for n in 0..<3 {
                try Data("Statistics \(n)\n".utf8).write(to:repo.root.appendingPathComponent("file.txt"))
                try await repo.stage(["file.txt"]);_=try await repo.commit(message:"Statistics export \(n)")
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
            try require(currentIndex==index && currentConfig==config && currentHead==head,"Statistics export changed repository state")
        }
        func clean()async {
            // Release every accepted writer even when an assertion throws.
            for gate in gates {await gate.finish()}
            owners.forEach{$0.close()}
            for window in NSApp.windows {if let sheet=window.attachedSheet {window.endSheet(sheet,returnCode:.cancel);sheet.orderOut(nil)};window.orderOut(nil);window.close()}
            for _ in 0..<3000 {if drained() && owners.allSatisfy({!$0.hasPendingWork}) {break};try? await Task.sleep(nanoseconds:10_000_000)}
            prefs.removePersistentDomain(forName:suite)
        }
    }
    static func verify(_ data:Data,format:StatisticsGraphFormat,size:CGSize?=nil)throws {
        if format == .pdf {
            let pdf=try unwrap(PDFDocument(data:data),"Invalid PDF statistics output")
            try require(pdf.pageCount==1,"PDF did not contain the captured viewport")
            if let size {try require(pdf.page(at:0)?.bounds(for:.mediaBox).size==size,"PDF viewport changed")}
        } else if format == .wmf || format == .emf {
            func word(_ offset:Int)->UInt32 {
                precondition(offset+4<=data.count,"Truncated EMF field")
                return (0..<4).reduce(UInt32(0)){$0 | UInt32(data[offset+$1]) << ($1*8)}
            }
            try require(data.count>=88 && word(0)==1 && word(40)==0x464d4520 && Int(word(48))==data.count,"Not actual enhanced-metafile bytes")
            var offset=0,fills=0,strokes=0,rasters=0,count=0,last:UInt32=0
            while offset<data.count {
                let type=word(offset),length=Int(word(offset+4))
                try require(length>=8 && length%4==0 && length<=data.count-offset,"Invalid EMF record")
                if type==62 {fills+=1};if type==64 {strokes+=1};if type==81 || type==114 {rasters+=1}
                count+=1;last=type;offset+=length
            }
            try require(last==14 && count==Int(word(52)) && fills>1 && strokes>0 && rasters==0,"Export substituted a whole-graph bitmap for vector shapes/text")
            let decoded=try unwrap(MetafileImageDecoder.convert(data),"Actual helper did not decode graph")
            let image=try unwrap(ComparisonImage(bytes:decoded)?.pixels,"Actual helper SVG did not render EMF pixels")
            if let size {try require(image.width==Int(size.width) && image.height==Int(size.height),"Metafile viewport changed")}
        } else {
            let source=try unwrap(CGImageSourceCreateWithData(data as CFData,nil),"Invalid raster graph")
            let image=try unwrap(CGImageSourceCreateImageAtIndex(source,0,nil),"Missing raster pixels")
            try require(CGImageSourceGetType(source) as String? == format.contentType.identifier,"Filename/actual encoder mismatch")
            if let size {try require(image.width==Int(size.width) && image.height==Int(size.height),"Raster viewport changed")}
        }
    }
    static func formats(_ c:Context)async throws {
        let picker=StatisticsGraphSavePanel()
        try require(picker.formats.itemTitles==["Pictures","All Files"] && picker.filter == .pictures,"Source filter order/default changed")
        let cases:[(Int,String,String,StatisticsGraphFormat)]=[(0,"statistics","statistics.wmf",.wmf),(1,"statistics","statistics.jpg",.jpeg),(0,"typed.PNG","typed.PNG",.png),(1,"typed.JPEG","typed.JPEG",.jpeg),(0,"typed.WMF","typed.WMF",.wmf),(1,"typed.emf","typed.emf",.emf),(0,"custom.suffix","custom.suffix.jpg",.jpeg),(1,".private",".private.jpg",.jpeg),(1,"trailing.","trailing..jpg",.jpeg)]
        for(index,input,expected,format)in cases {
            picker.panel.nameFieldStringValue=input;picker.formats.selectItem(at:index);picker.changeFormat()
            try require(picker.panel.nameFieldStringValue==input,"Filter selection rewrote typed suffix")
            let final=try unwrap(picker.panel(picker.panel,userEnteredFilename:input,confirmed:true),"Filename delegate refused input")
            try require(final==expected,"Wrong native filename normalization: "+final)
            let accepted=c.base.appendingPathComponent(final),target=try picker.destination(for:accepted)
            try require(target.url==accepted && target.format==format,"Final URL or filename encoder drifted")
        }
        picker.formats.selectItem(at:1);picker.changeFormat();try require(picker.panel.allowedContentTypes.isEmpty && picker.panel.allowsOtherFileTypes,"All Files is not unrestricted")
        for name in ["ungranted.custom","no-extension"] {
            do {_=try picker.destination(for:c.base.appendingPathComponent(name));throw Failure(description:"Unapproved final filename accepted")}
            catch is Failure {throw Failure(description:"Unapproved final filename accepted")}
            catch {}
        }
        let owner=try await c.owner(),graph=try unwrap(owner.model.graph,"No actual statistics graph")
        let size=CGSize(width:640,height:360)
        for format in StatisticsGraphFormat.allCases {
            let bytes=try StatisticsGraphExport.data(graph:graph,metric:owner.model.metric,style:owner.model.style,size:size,dark:false,format:format)
            let target=c.base.appendingPathComponent("actual."+format.fileExtension)
            try await StatisticsGraphExport.write(data:bytes,to:target,cancellation:OperationCancellation())
            try verify(Data(contentsOf:target),format:format,size:size)
        }
        let sentinel=c.base.appendingPathComponent("cancel.png"),original=Data("sentinel".utf8);try original.write(to:sentinel)
        let token=OperationCancellation();token.cancel()
        do {try await StatisticsGraphExport.write(data:Data("replacement".utf8),to:sentinel,cancellation:token);throw Failure(description:"Cancelled writer published")}
        catch is Failure {throw Failure(description:"Cancelled writer published")}
        catch {}
        try require(try Data(contentsOf:sentinel)==original,"Cancelled writer changed existing target")
        let directory=c.base.appendingPathComponent("existing-directory",isDirectory:true);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false);try original.write(to:directory.appendingPathComponent("keep"))
        do {try await StatisticsGraphExport.write(data:Data("replacement".utf8),to:URL(fileURLWithPath:directory.path,isDirectory:false),cancellation:OperationCancellation());throw Failure(description:"Writer replaced a directory")}
        catch is Failure {throw Failure(description:"Writer replaced a directory")}
        catch {}
        try require(try Data(contentsOf:directory.appendingPathComponent("keep"))==original,"Failed staged writer changed existing contents")
        picker.retire();try require(picker.panel.delegate==nil && picker.formats.target==nil,"Retired chooser kept callbacks")
        try await c.preserved()
    }
    static func selection(_ c:Context)async throws {
        let owner=try await c.owner(),target=c.base.appendingPathComponent("frozen.PNG"),ignored=c.base.appendingPathComponent("mutated.pdf")
        let probe=StatisticsExportWriteProbe();owner.writeGraph={data,url,token in try await probe.write(data,to:url,cancellation:token)}
        var reply:((NSApplication.ModalResponse)->Void)?,selected=target
        owner.selectedSaveURL={_ in selected};owner.presentSavePanel={panel,parent,completion in reply=completion;parent.beginSheet(panel)}
        owner.model.graphSize=CGSize(width:640,height:360);let metric=owner.model.metric,context=owner.model.formRevision
        owner.saveGraphAs();let choice=try unwrap(owner.savePanel,"Actual save chooser missing")
        try require(owner.hasPendingWork && !owner.windowShouldClose(owner.window!),"Chooser lost owner lock")
        owner.model.selectMetric(.commitsByAuthor,context:context);try require(owner.model.metric==metric,"Chooser allowed stale graph mutation")
        choice.panel.nameFieldStringValue=target.lastPathComponent;choice.formats.selectItem(at:1);choice.changeFormat()
        reply?(.OK)
        // These mutations occur in the same actor turn before the writer Task.
        choice.formats.selectItem(at:0);choice.panel.nameFieldStringValue=ignored.lastPathComponent;choice.changeFormat();selected=ignored;owner.model.graphSize=CGSize(width:800,height:500);reply?(.OK)
        try await wait{!owner.hasPendingWork && owner.canSaveGraph}
        let records=await probe.records
        try require(records.count==1 && records[0].1==target && !FileManager.default.fileExists(atPath:ignored.path),"Accepted callback retargeted or duplicated export")
        try verify(Data(contentsOf:target),format:.png,size:CGSize(width:640,height:360))
        let sentinel=Data("sentinel after save".utf8);try sentinel.write(to:target);reply?(.OK)
        try await Task.sleep(nanoseconds:20_000_000)
        try require(try Data(contentsOf:target)==sentinel,"Completed callback wrote again")
        selected=c.base.appendingPathComponent("quit.png");owner.saveGraphAs();let stale=reply
        owner.model.confirmingQuit=true;owner.model.confirmingQuit=false;stale?(.OK)
        try await wait{!owner.hasPendingWork && owner.canSaveGraph}
        let recordsAfterQuit=await probe.records
        try require(!FileManager.default.fileExists(atPath:selected.path) && recordsAfterQuit.count==1,"Cancelled Quit revived accepted save intent")
        owner.saveGraphAs();reply?(.cancel);reply?(.OK);try await wait{!owner.hasPendingWork}
        try require(!FileManager.default.fileExists(atPath:selected.path),"Cancel then duplicate OK wrote graph")
        try await c.preserved()
    }
    static func ownership(_ c:Context)async throws {
        let owner=try await c.owner(),gate=StatisticsExportWriteGate();c.gates.append(gate)
        let target=c.base.appendingPathComponent("held.png"),sentinel=Data("preserved held destination".utf8);try sentinel.write(to:target)
        owner.writeGraph={data,url,token in try await gate.write(data,to:url,cancellation:token)}
        owner.selectedSaveURL={_ in target};owner.presentSavePanel={_,_,reply in reply(.OK)}
        var closed=0;owner.onClosed={closed += 1};owner.saveGraphAs()
        var entered=false
        for _ in 0..<3000 {if await gate.entered {entered=true;break};try await Task.sleep(nanoseconds:10_000_000)}
        try require(entered,"Accepted cancellable writer never started")
        owner.close()
        try require(closed==0 && owner.hasPendingWork && StatisticsWindowController.activeExports>0,"Visual close released held writer owner")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit ignored accepted writer")
        let tokenCancelled=await gate.cancelled;try require(tokenCancelled,"Owner close did not cancel writer token")
        await gate.finish();try await wait{closed==1 && !owner.hasPendingWork && drained()}
        try require(try Data(contentsOf:target)==sentinel,"Late cancelled writer overwrote existing destination")
        let failed=try await c.owner();var alert:NSAlert?,answer:((NSApplication.ModalResponse)->Void)?
        failed.writeGraph={_,_,_ in throw NSError(domain:"Private statistics writer failure",code:19)}
        failed.selectedSaveURL={_ in target};failed.presentSavePanel={_,_,reply in reply(.OK)}
        failed.presentExportError={question,parent,reply in alert=question;answer=reply;question.beginSheetModal(for:parent,completionHandler:reply)}
        failed.saveGraphAs();try await wait{alert?.window.sheetParent === failed.window}
        try require(failed.hasPendingWork && !failed.windowShouldClose(failed.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Owned export error lost sheet/Quit guard")
        let question=try unwrap(alert,"Actual failure alert missing");question.buttons[0].performClick(nil)
        try await wait{!failed.hasPendingWork && failed.window?.attachedSheet==nil && question.window.sheetParent==nil}
        answer?(.alertFirstButtonReturn);try require(failed.canSaveGraph,"Duplicate error reply blocked fresh export")
        alert=nil;failed.saveGraphAs();try await wait{alert?.window.sheetParent === failed.window}
        let retiredAlert=try unwrap(alert,"Second owned error missing");var failureClosed=0;failed.onClosed={failureClosed += 1}
        failed.close();answer?(.alertFirstButtonReturn);answer?(.alertFirstButtonReturn)
        try await wait{failureClosed==1 && !failed.hasPendingWork && retiredAlert.window.sheetParent==nil && drained()}
        try require(try Data(contentsOf:target)==sentinel,"Failed export/error dismissal changed destination")
        try await c.preserved()
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.statisticsExportHiddenOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden);defer{method_exchangeImplementations(original,hidden)}
        let c=Context();DialogGeometry.install(preferences:c.prefs);defer{DialogGeometry.install(preferences:.standard)}
        do {
            try await c.seed();let which=CommandLine.arguments[3]
            switch which {case "formats":try await formats(c);case "selection":try await selection(c);case "ownership":try await ownership(c);default:throw Failure(description:"Unknown statistics export case")}
            await c.clean();try require(drained() && c.owners.allSatisfy{!$0.hasPendingWork} && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Statistics export ownership did not drain")
            print("PASS: Statistics export family "+which)
        }catch {await c.clean();throw error}
    }
}
