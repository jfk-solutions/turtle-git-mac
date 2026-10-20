// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import ScreenCaptureKit
import TurtleGitCore

private extension NSWindow {
    @objc func turtlePresentationOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int){alphaValue=0;setFrameOrigin(.init(x:-12000,y:-12000));turtlePresentationOrder(place,relativeTo:number)}
}
@MainActor @main enum PresentationComparisonVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ condition:Bool,_ message:String)throws{if !condition{throw Failure(description:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws{for _ in 0..<3000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Presentation timeout at \(line)")}
    static func pdf(_ url:URL,colors:[CGColor],title:String="fixture")throws{
        var media=CGRect(x:0,y:0,width:640,height:360)
        guard let context=CGContext(url as CFURL,mediaBox:&media,[kCGPDFContextTitle as String:title] as CFDictionary) else{throw Failure(description:"PDF fixture unavailable")}
        for color in colors{context.beginPDFPage(nil);context.setFillColor(CGColor(gray:1,alpha:1));context.fill(media);context.setFillColor(color);context.fill(CGRect(x:90,y:70,width:300,height:180));context.endPDFPage()};context.closePDF()
    }
    static func capture(_ window:NSWindow,namePrefix:String="presentation-review-paired")async throws{
        guard let path=ProcessInfo.processInfo.environment["TURTLEGIT_PRESENTATION_CAPTURES"] else{return}
        guard #available(macOS 14.4,*) else{throw Failure(description:"Owned presentation capture unavailable")}
        let directory=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        // The order swizzle keeps the test window outside every desktop screen
        // and resets opacity. Enable compositor drawing only after ordering.
        window.orderFront(nil);window.alphaValue=1;defer{window.alphaValue=0}
        try await Task.sleep(nanoseconds:600_000_000)
        for (appearance,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")]{
            window.appearance=NSAppearance(named:appearance);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:300_000_000)
            let content=try await SCShareableContent.currentProcess
            guard let owned=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else{throw Failure(description:"Owned presentation capture unavailable")}
            let configuration=SCStreamConfiguration();configuration.width=Int(window.frame.width*2);configuration.height=Int(window.frame.height*2);configuration.showsCursor=false;configuration.ignoreShadowsSingleWindow=true;configuration.includeChildWindows=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:configuration)
            guard let png=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else{throw Failure(description:"Review PNG unavailable")}
            try png.write(to:directory.appendingPathComponent(namePrefix+"-"+name+".png"))
        }
    }
    static func routing(root:URL,prefs:UserDefaults)async throws {
        let previousExport=DiffToolApplication.exportPowerPoint,previousPresent=DiffToolApplication.presentPresentation
        defer{DiffToolApplication.exportPowerPoint=previousExport;DiffToolApplication.presentPresentation=previousPresent;DiffToolApplication.discardAll()}
        let manifest=PresentationComparisonManifest(base:.init(slides:[.init(pageIndex:0,stableID:"1",text:"Base",notes:"")]),destination:.init(slides:[.init(pageIndex:0,stableID:"1",text:"New",notes:"")]))
        let color=CGColor(red:0,green:0.4,blue:1,alpha:1)
        var exported=0,published:[PresentationComparisonWindowController]=[]
        DiffToolApplication.exportPowerPoint={preview,_ in exported+=1;try pdf(preview.basePDF,colors:[color]);try pdf(preview.destinationPDF,colors:[color]);return manifest}
        DiffToolApplication.presentPresentation={controller in published.append(controller);controller.showWindow(nil);return true}
        for ext in ["ppt","pptm","pptx"] {
            let a=root.appendingPathComponent("base."+ext),b=root.appendingPathComponent("new."+ext);try Data([0,1]).write(to:a);try Data([2,3]).write(to:b)
            let document=try WorkingFileComparison(base:a,destination:b).read()
            let handled=try await DiffToolApplication.open(document,root:root,permissions:[],alternate:false,preferences:prefs)
            try require(handled && published.count==exported,"PowerPoint extension did not route to native review")
            let review=published.last!;try await wait{review.model.pending==0};review.close();try await wait{!FileManager.default.fileExists(atPath:review.model.preview.directory.path)}
            let count=exported,bypassed=try await DiffToolApplication.open(document,root:root,permissions:[],alternate:true,preferences:prefs)
            try require(!bypassed && exported==count,"Shift did not bypass PowerPoint association")
        }
        let a=root.appendingPathComponent("base.pptx"),b=root.appendingPathComponent("new.pptx"),document=try WorkingFileComparison(base:a,destination:b).read()
        var held:CheckedContinuation<PresentationComparisonManifest,Never>?,heldPreview:PresentationComparisonPreview?,heldToken:OperationCancellation?
        defer{held?.resume(returning:manifest)}
        DiffToolApplication.exportPowerPoint={preview,token in heldPreview=preview;heldToken=token;try pdf(preview.basePDF,colors:[color]);try pdf(preview.destinationPDF,colors:[color]);return await withCheckedContinuation{held=$0}}
        let parent=NSWindow(contentRect:.init(x:0,y:0,width:300,height:200),styleMask:[.titled,.closable],backing:.buffered,defer:false);parent.isReleasedWhenClosed=false;parent.orderFront(nil)
        let count=published.count,task=Task{() -> Bool in do{return try await DiffToolApplication.open(document,root:root,permissions:[],alternate:false,preferences:prefs,owner:parent)}catch{return false}}
        try await wait{held != nil};try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit escaped PowerPoint export ownership")
        parent.close();try require(heldToken?.isCancelled==true,"Caller close did not cancel presentation export")
        held?.resume(returning:manifest);held=nil;let accepted=await task.value
        try require(!accepted && published.count==count,"Closed caller published a late review")
        try await wait{heldPreview.map{!FileManager.default.fileExists(atPath:$0.directory.path)}==true}
        DiffToolApplication.exportPowerPoint={preview,_ in try pdf(preview.basePDF,colors:[color]);try pdf(preview.destinationPDF,colors:[color]);return manifest}
        var refused:PresentationComparisonWindowController?
        DiffToolApplication.presentPresentation={controller in refused=controller;return false}
        do{_ = try await DiffToolApplication.open(document,root:root,permissions:[],alternate:false,preferences:prefs);throw Failure(description:"Rejected presentation was accepted")}catch is Failure{throw Failure(description:"Rejected presentation was accepted")}catch{}
        guard let refused else{throw Failure(description:"Refused controller missing")}
        if refused.model.pending>0 {try require(FileManager.default.fileExists(atPath:refused.model.preview.directory.path),"Rejected review discarded files before reader drain")}
        try await wait{refused.model.pending==0 && !FileManager.default.fileExists(atPath:refused.model.preview.directory.path)}
    }
    static func refusedControls(_ model:PresentationComparisonWindowModel)throws {
        let selection=model.selection,mode=model.mode,zoom=model.zoom,fit=model.fit,filter=model.changesOnly,pending=model.pending
        let keys=["PresentationReview.Mode","PresentationReview.Zoom","PresentationReview.Fit","PresentationReview.ChangesOnly"]
        let saved=keys.map{model.preferences.object(forKey:$0).map{String(describing:$0)} ?? "absent"}
        model.selection=selection==nil ? 0:nil;model.mode=mode == .paired ? .difference:.paired
        model.zoom=zoom==2 ? 3:2;model.fit = !fit;model.changesOnly = !filter
        try require(model.selection==selection && model.mode==mode && model.zoom==zoom && model.fit==fit && model.changesOnly==filter && model.pending==pending,"Blocked presentation control changed state or started work")
        let retained=keys.map{model.preferences.object(forKey:$0).map{String(describing:$0)} ?? "absent"}
        try require(retained==saved,"Blocked presentation control persisted stale preferences")
    }
    static func lifecycle(root:URL,prefs:UserDefaults)async throws {
        let a=root.appendingPathComponent("cancel-base.pptx"),b=root.appendingPathComponent("cancel-new.pptx");try Data([0]).write(to:a);try Data([1]).write(to:b)
        let preview=try PresentationComparisonPreview.prepare(WorkingFileComparison(base:a,destination:b).read(),in:root,cancellation:OperationCancellation()),color=CGColor(gray:0.4,alpha:1)
        try pdf(preview.basePDF,colors:[color]);try pdf(preview.destinationPDF,colors:[color])
        let manifest=PresentationComparisonManifest(base:.init(slides:[.init(pageIndex:0,text:"Base",notes:"")]),destination:.init(slides:[.init(pageIndex:0,text:"New",notes:"")]))
        let owner=PresentationComparisonWindowController(preview:preview,manifest:manifest,permissions:[],preferences:prefs,baseTitle:"Base",destinationTitle:"New")
        defer{owner.close()};owner.showWindow(nil);owner.model.cancel();try await wait{!owner.model.busy && owner.model.pending==0}
        try require(owner.model.error != nil,"Cancelled review falsely reported no slides")
        owner.model.start();try await wait{!owner.model.busy && owner.model.pending==0};try require(owner.model.error==nil && !owner.model.rows.isEmpty,"Cancelled review could not retry")
        owner.model.renderSelection();owner.model.cancel();try await wait{!owner.model.rendering && owner.model.pending==0}
        try require(owner.model.renderError != nil,"Cancelled selected slide has no retry outcome")
        owner.model.renderSelection();try await wait{!owner.model.rendering && owner.model.pending==0};try require(owner.model.renderError==nil && owner.model.images != nil,"Cancelled selected slide could not retry")
        owner.model.zoom=100;try require(owner.model.zoom==8,"Review zoom did not clamp upper bound")
        owner.model.zoom = -100;try require(owner.model.zoom==0.1,"Review zoom did not clamp lower bound")
        owner.model.zoom = .nan;try require(owner.model.zoom==0.1,"NaN zoom replaced finite value")
        owner.model.zoom = .infinity;try require(owner.model.zoom==0.1,"Infinite zoom replaced finite value")
        owner.model.confirmingQuit=true;try refusedControls(owner.model);owner.model.confirmingQuit=false
        let allowed=owner.model.actionsAllowed;owner.model.actionsAllowed={false};try refusedControls(owner.model);owner.model.actionsAllowed=allowed
        owner.model.mode = .difference;owner.model.zoom=1.75;owner.model.fit=false;owner.model.changesOnly=true
        owner.close();try refusedControls(owner.model);try await wait{!FileManager.default.fileExists(atPath:preview.directory.path)}
        let next=try PresentationComparisonPreview.prepare(WorkingFileComparison(base:a,destination:b).read(),in:root,cancellation:OperationCancellation());try pdf(next.basePDF,colors:[color]);try pdf(next.destinationPDF,colors:[color])
        let reopened=PresentationComparisonWindowController(preview:next,manifest:manifest,permissions:[],preferences:prefs,baseTitle:"Base",destinationTitle:"New")
        defer{reopened.close()};try require(reopened.model.mode == .difference && reopened.model.zoom==1.75 && !reopened.model.fit && reopened.model.changesOnly,"Review controls lost owning-domain persistence")
        reopened.showWindow(nil);try await wait{reopened.model.pending==0 && !reopened.model.rows.isEmpty}
        let absent=root.appendingPathComponent("nonexistent export parent/report.txt")
        var exportChoices=0
        reopened.selectedExportURL={_ in absent}
        reopened.presentExport={_,_,reply in exportChoices+=1;reply(.OK)}
        reopened.chooseExport()
        try await wait{reopened.exportErrorWindow != nil && reopened.window?.attachedSheet===reopened.exportErrorWindow}
        try refusedControls(reopened.model)
        try require(exportChoices==1 && reopened.model.pending>0 && reopened.exportErrorWindow?.alphaValue==0 && !reopened.windowShouldClose(reopened.window!),"Failed export did not retain actual hidden error sheet/owner")
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit escaped export error acknowledgement")
        try require(FileManager.default.fileExists(atPath:next.directory.path) && !FileManager.default.fileExists(atPath:absent.path),"Export error lost captured inputs or created target")
        reopened.close()
        try await wait{reopened.exportErrorWindow==nil && reopened.window?.attachedSheet==nil && reopened.model.pending==0 && !FileManager.default.fileExists(atPath:next.directory.path)}
        try require(PresentationComparisonWindowModel.activeRequests==0,"Error sheet retained work after owner closure")
    }
    static func main()async throws{
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtlePresentationOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden);defer{method_exchangeImplementations(original,hidden)}
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),suite="TurtleGit.PresentationNative."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,clipboard=NSPasteboard.withUniqueName()
        prefs.set(true,forKey:"ShowAppContextMenuIcons");DialogGeometry.install(preferences:prefs)
        var owners:[PresentationComparisonWindowController]=[]
        func cleanup()async throws{owners.forEach{$0.close()};for window in NSApp.windows{if let parent=window.sheetParent{parent.endSheet(window,returnCode:.cancel)};window.close()};try await wait{PresentationComparisonWindowModel.activeRequests==0 && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil && $0.sheetParent==nil}};prefs.removePersistentDomain(forName:suite);clipboard.releaseGlobally()}
        do{
            let test=ProcessInfo.processInfo.environment["TURTLEGIT_PRESENTATION_CASE"] ?? "review"
            if test != "review" {
                switch test {case "automation":try await PowerPointAutomationVerification.verify(root:root);case "routing":try await routing(root:root,prefs:prefs);case "lifecycle":try await lifecycle(root:root,prefs:prefs);case "revision":try await PresentationRevisionNativeVerification.verify(root:root,git:URL(fileURLWithPath:CommandLine.arguments.count>2 ? CommandLine.arguments[2]:"/usr/bin/git"));case "revision-automation":try await PowerPointRevisionAutomationVerification.verify(root:root,git:URL(fileURLWithPath:CommandLine.arguments.count>2 ? CommandLine.arguments[2]:"/usr/bin/git"));case "result":try await PresentationResultNativeVerification.verify(root:root,git:URL(fileURLWithPath:CommandLine.arguments.count>2 ? CommandLine.arguments[2]:"/usr/bin/git"));default:throw Failure(description:"Unknown presentation case")}
                try await cleanup();print("PASS: presentation native review completed");return
            }
            let a=root.appendingPathComponent("old 雪.pptx"),b=root.appendingPathComponent("new.pptx"),old=Data([0,1,2,3]),new=Data([4,5,6,7])
            try old.write(to:a);try new.write(to:b)
            func preview()throws->PresentationComparisonPreview{try PresentationComparisonPreview.prepare(WorkingFileComparison(base:a,destination:b).read(),in:root,cancellation:OperationCancellation())}
            let manifest=PresentationComparisonManifest(base:.init(slides:[.init(pageIndex:0,stableID:"10",text:"Old title",notes:"Old note"),.init(pageIndex:1,stableID:"20",text:"Shared café",notes:""),.init(pageIndex:2,stableID:"30",text:"Deleted",notes:"")]),destination:.init(slides:[.init(pageIndex:0,stableID:"20",text:"Shared cafe\u{301}",notes:""),.init(pageIndex:1,stableID:"10",text:"New title",notes:"New note"),.init(pageIndex:2,stableID:"40",text:"Added",notes:"")]))
            let red=CGColor(red:1,green:0,blue:0,alpha:1),green=CGColor(red:0,green:1,blue:0,alpha:1),blue=CGColor(red:0,green:0,blue:1,alpha:1),yellow=CGColor(red:1,green:1,blue:0,alpha:1),gray=CGColor(gray:0.5,alpha:1)
            let prepared=try preview();try pdf(prepared.basePDF,colors:[red,green,blue]);try pdf(prepared.destinationPDF,colors:[green,yellow,gray])
            let owner=PresentationComparisonWindowController(preview:prepared,manifest:manifest,permissions:[RepositoryAccessLease(url:root)],preferences:prefs,baseTitle:a.lastPathComponent,destinationTitle:b.lastPathComponent);owners.append(owner);owner.model.clipboard=clipboard;owner.showWindow(nil)
            try await wait{!owner.model.busy && owner.model.pending==0}
            try require(owner.model.error==nil && owner.model.rows.contains{$0.change == .added} && owner.model.rows.contains{$0.change == .deleted} && owner.model.rows.contains{$0.change == .modified} && owner.model.rows.contains{$0.isMoved},"Actual review omitted added/deleted/modified/moved classification")
            guard let changed=owner.model.rows.firstIndex(where:{$0.base?.stableID=="10"}) else{throw Failure(description:"Modified slide absent")}
            owner.model.selection=changed;try await wait{!owner.model.rendering && owner.model.images != nil}
            try require(owner.model.images?.base != nil && owner.model.images?.destination != nil && owner.model.images?.difference != nil,"Paired/overlay/difference raster missing")
            try await capture(owner.window!);owner.model.mode = .overlay;try await capture(owner.window!,namePrefix:"presentation-review-overlay");owner.model.mode = .paired
            owner.model.changesOnly=true;try require(owner.model.visibleIndices.allSatisfy{owner.model.rows[$0].change != .unchanged || owner.model.rows[$0].isMoved},"Changes filter included unchanged slides")
            owner.model.selection=owner.model.visibleIndices.first;let selected=owner.model.selection;owner.model.navigate(1);try require(owner.model.selection != selected,"Next change did not navigate");owner.model.navigate(-1);try require(owner.model.selection==selected,"Previous change lost destination")
            for mode in PresentationComparisonWindowModel.Mode.allCases{owner.model.mode=mode};owner.model.fit=false;owner.model.zoom=2;owner.model.fit=true
            owner.model.copyReview();try require(clipboard.string(forType:.string)?.contains("New note")==true,"Copy Review omitted note differences")
            let literalReport=Data(owner.model.reviewText.utf8)
            try require(literalReport.range(of:Data("Shared café".utf8)) != nil && literalReport.range(of:Data("Shared cafe\u{301}".utf8)) != nil,"Review omitted literal NFC/NFD text differences")
            let report=root.appendingPathComponent("review.txt");try owner.model.exportReview(to:report);try require(try String(contentsOf:report,encoding:.utf8)==owner.model.reviewText,"Export Review differs from captured report")
            let duplicate=root.appendingPathComponent("same-pixels.pdf");try pdf(duplicate,colors:[red,green,blue],title:"Different metadata")
            let hashes=try await Task.detached{try PresentationComparisonRendering.fingerprints(base:prepared.basePDF,destination:duplicate,baseCount:3,destinationCount:3,cancellation:OperationCancellation())}.value
            try require(hashes.0==hashes.1,"Visual comparison used PDF metadata rather than pixels")
            // Missing PDFs now intentionally support metadata-only package review.
            // Corrupt present exports must still fail and support an actual retry.
            let failed=try preview();try Data([0]).write(to:failed.basePDF);try Data([0]).write(to:failed.destinationPDF)
            let retry=PresentationComparisonWindowController(preview:failed,manifest:manifest,permissions:[],preferences:prefs,baseTitle:"Old",destinationTitle:"New");owners.append(retry);retry.showWindow(nil)
            try await wait{!retry.model.busy && retry.model.error != nil};try pdf(failed.basePDF,colors:[red,green,blue]);try pdf(failed.destinationPDF,colors:[green,yellow,gray]);retry.model.start();try await wait{!retry.model.busy && retry.model.pending==0};try require(retry.model.error==nil && !retry.model.rows.isEmpty,"Rendering failure could not retry")
            let early=try preview();try pdf(early.basePDF,colors:[red,green,blue]);try pdf(early.destinationPDF,colors:[green,yellow,gray]);let neverShown=PresentationComparisonWindowController(preview:early,manifest:manifest,permissions:[],preferences:prefs,baseTitle:"Old",destinationTitle:"New");owners.append(neverShown)
            try require(neverShown.model.pending>0,"Initial rendering did not reserve lifetime synchronously");neverShown.close();try require(FileManager.default.fileExists(atPath:early.directory.path),"Close discarded preview before worker drain");try await wait{!FileManager.default.fileExists(atPath:early.directory.path)}
            let count=owner.model.rows.count;owner.close();owner.model.navigate(1);owner.model.start();try require(owner.model.retired && owner.model.rows.count==count,"Retired controller restarted review")
            try await wait{!FileManager.default.fileExists(atPath:prepared.directory.path)}
            try require(try Data(contentsOf:a)==old && Data(contentsOf:b)==new,"Review changed original presentation bytes")
            try await cleanup()
        }catch{let original=error;do{try await cleanup()}catch{throw Failure(description:"\(original); cleanup: \(error)")};throw original}
        print("PASS: presentation native review completed")
    }
}
