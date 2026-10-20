// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
#if canImport(FoundationXML)
import FoundationXML
#endif
import TurtleGitCore

@MainActor enum PresentationGroupReviewVerification {
    struct Failure:Error,LocalizedError,CustomStringConvertible {let description:String;var errorDescription:String?{description}}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value{throw Failure(description:"\(line): "+message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {for _ in 0..<3000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Group review timeout at \(line)")}
    static func package(new:Bool)throws->PresentationPackage {
        var entries=try PresentationRevisionNativeVerification.package("Unused").entries
        func leaf(_ id:Int,_ name:String,_ text:String,_ x:Int)->String {
            "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"\(name)\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"\(x)\" y=\"100\"/><a:ext cx=\"1000\" cy=\"500\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>\(text)</a:t></a:r></a:p></p:txBody></p:sp>"
        }
        func group(_ id:Int,_ name:String,_ children:String)->String {
            "<p:grpSp><p:nvGrpSpPr><p:cNvPr id=\"\(id)\" name=\"\(name)\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"9000\" cy=\"5000\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"9000\" cy=\"5000\"/></a:xfrm></p:grpSpPr>\(children)</p:grpSp>"
        }
        let alpha=leaf(4,"Alpha",new ? "New Alpha":"Base Alpha",100),beta=leaf(5,"Beta",new ? "New Beta":"Base Beta",2000)
        let inner=group(3,"Inner group",new ? beta+alpha:alpha+beta)
        let variant=new ? leaf(7,"Added leaf","Accepted added child",7500):leaf(6,"Deleted leaf","Retained deleted child",4000)
        let tree="<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"+group(2,"Outer group",inner+variant)
        var slide=String(data:entries["ppt/slides/slide1.xml"]!,encoding:.utf8)!
        let start=slide.range(of:"<p:spTree>")!.upperBound,end=slide.range(of:"</p:spTree>")!.lowerBound
        slide.replaceSubrange(start..<end,with:tree);entries["ppt/slides/slide1.xml"]=Data(slide.utf8)
        return try PresentationPackage(entries:entries)
    }
    final class Gate:@unchecked Sendable {
        private let lock=NSLock();private var entered=false,released=false
        func start(){lock.lock();entered=true;lock.unlock()}
        func isStarted()->Bool{lock.lock();defer{lock.unlock()};return entered}
        func release(){lock.lock();released=true;lock.unlock()}
        func isReleased()->Bool{lock.lock();defer{lock.unlock()};return released}
    }
    @MainActor final class Context {
        let root:URL,a:URL,b:URL,base:PresentationPackage,new:PresentationPackage,review:PresentationRevisionReview,document:FileComparisonDocument
        let suite:String,prefs:UserDefaults,baseData:Data,newData:Data
        var owners:[PresentationComparisonWindowController]=[],gates:[Gate]=[]
        init()throws {
            root=URL(fileURLWithPath:CommandLine.arguments[1]);base=try package(new:false);new=try package(new:true)
            review=try PresentationRevisionReview(base:base,destination:new);a=root.appendingPathComponent("base.pptx");b=root.appendingPathComponent("new.pptx")
            baseData=try base.encoded(cancellation:.init());newData=try new.encoded(cancellation:.init());try baseData.write(to:a);try newData.write(to:b)
            document=try WorkingFileComparison(base:a,destination:b).read()
            suite="TurtleGit.GroupReview."+UUID().uuidString;prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"EnableGravatar")
        }
        func owner()throws->PresentationComparisonWindowController {
            let preview=try PresentationComparisonPreview.prepare(document,in:root,cancellation:.init())
            let owner=PresentationComparisonWindowController(preview:preview,manifest:.init(base:review.baseManifest,destination:review.destinationManifest),permissions:[],preferences:prefs,baseTitle:a.path,destinationTitle:b.path,protectedInputs:[a,b],initialReview:review)
            owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-12000,y:-12000));owner.window?.orderFront(nil);owners.append(owner);return owner
        }
        func cleanup()async {
            gates.forEach{$0.release()};for owner in owners{owner.presentDiscard={_,_,reply in reply(true)};owner.close()}
            for _ in 0..<3000{if PresentationComparisonWindowModel.activeRequests==0 && owners.allSatisfy({$0.model.pending==0}){break};try? await Task.sleep(nanoseconds:10_000_000)}
            owners.forEach{$0.window?.orderOut(nil)};prefs.removePersistentDomain(forName:suite)
        }
        func unchanged()throws{try require(Data(contentsOf:a)==baseData && Data(contentsOf:b)==newData,"Group review modified source packages")}
    }
    static func run(_ body:(Context)async throws->Void)async throws {
        let context=try Context()
        do{try await body(context);try context.unchanged();await context.cleanup();try require(PresentationComparisonWindowModel.activeRequests==0,"Group review left owned workers")}
        catch{await context.cleanup();throw error}
    }
    static func capture(_ window:NSWindow)async throws {
        guard let path=ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_CAPTURE_DIR"] else{return}
        guard #available(macOS 14.4,*) else{throw Failure(description:"Owned group window capture requires macOS 14.4")}
        let original=window.appearance
        window.setFrameOrigin(.init(x:-12000,y:-12000));window.alphaValue=1;window.orderFront(nil)
        defer{window.appearance=original;window.alphaValue=0;window.orderOut(nil)}
        for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",NSAppearance.Name.darkAqua)]{
            window.appearance=NSAppearance(named:appearance);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:400_000_000)
            let content=try await SCShareableContent.currentProcess
            guard let owned=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else{throw Failure(description:"Owned offscreen group window unavailable")}
            let configuration=SCStreamConfiguration();configuration.width=Int(window.frame.width*2);configuration.height=Int(window.frame.height*2);configuration.showsCursor=false;configuration.ignoreShadowsSingleWindow=true;configuration.includeChildWindows=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:configuration)
            guard let png=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else{throw Failure(description:"Cannot encode group capture")}
            try png.write(to:URL(fileURLWithPath:path).appendingPathComponent("presentation-group-review-"+name+".png"),options:.atomic)
        }
    }
    static func capturesOnly()async throws {try await run{context in
        let owner=try context.owner(),model=owner.model.revision;try await wait{owner.model.pending==0}
        model.decideAll(accept:true)
        guard let beta=model.changes.first(where:{$0.title.contains("Beta")}),let deleted=model.changes.first(where:{$0.kind == .shapeDeleted}) else{throw Failure(description:"Missing group capture choices")}
        model.decide(changeID:beta.id,accept:false);model.decide(changeID:deleted.id,accept:false);model.selection=beta.id
        try await capture(owner.window!)
    }}
    static func review()async throws {try await run{context in
        let owner=try context.owner(),model=owner.model.revision;try await wait{owner.model.pending==0}
        try require(!owner.model.sourcePreviewsAvailable && owner.model.renderError==nil,"Package group review depended on PowerPoint/PDF previews")
        let alpha=model.changes.filter{$0.title.contains("Alpha")},beta=model.changes.filter{$0.title.contains("Beta")}
        try require(alpha.count==1 && beta.count==1 && alpha[0].id != beta[0].id,"Nested leaves were collapsed into an atomic group")
        try require(alpha[0].groupPath==["Outer group","Inner group"] && beta[0].groupPath==alpha[0].groupPath,"Nested changes lost full ancestor paths")
        try require(PresentationRevisionChangePresentation.breadcrumb(alpha[0])=="Outer group › Inner group" && PresentationRevisionChangePresentation.location(alpha[0]).contains("Alpha") && PresentationRevisionChangePresentation.icon(alpha[0]).image() != nil,"Native nested revision path/icon presentation is incomplete")
        var panels=0;owner.presentExport={_,_,reply in panels += 1;reply(.OK)};owner.chooseEditableExport()
        try require(panels==0 && !model.canSave,"Unresolved group revisions opened Save As")
        model.selection=alpha[0].id;model.decide(accept:true)
        try require(model.review?.decisions[alpha[0].id]==true && model.review?.decisions[beta[0].id]==nil,"Accepting nested leaf resolved its sibling")
        model.undo();try require(model.review?.decisions[alpha[0].id]==nil && !model.isDirty,"Nested Undo did not restore undecided state")
        model.redo();try require(model.review?.decisions[alpha[0].id]==true,"Nested Redo failed")
        model.decideAll(accept:true);model.decide(changeID:beta[0].id,accept:false)
        guard let deleted=model.changes.first(where:{$0.kind == .shapeDeleted && $0.title.contains("Deleted leaf")}),let added=model.changes.first(where:{$0.kind == .shapeAdded && $0.title.contains("Added leaf")}),let order=model.changes.first(where:{$0.kind == .shapeOrder && $0.groupPath==["Outer group","Inner group"]}) else{throw Failure(description:"Nested add/delete/order revisions missing: \(model.changes)")}
        model.decide(changeID:deleted.id,accept:false)
        try require(model.review?.decisions[added.id]==true && model.review?.decisions[order.id]==true && model.canSave,"Independent nested additions/deletions/order decisions failed")
        model.selection=beta[0].id
        try require(owner.model.reviewText.contains("Outer group › Inner group") && owner.model.reviewText.contains("Accepted New:") && owner.model.reviewText.contains("Rejected Base:"),"Copy/Export Review omitted ancestor paths or mixed group decisions")
        try await capture(owner.window!)
        let output=context.root.appendingPathComponent("group-mixed.pptx")
        owner.selectedExportURL={_ in output};owner.chooseEditableExport();try await wait{owner.model.pending==0 && model.savedURL==output}
        let saved=try PresentationPackage.read(from:output,cancellation:.init()),text=try PresentationRevisionReview(base:saved,destination:saved).baseManifest.slides[0].text
        try require(text.contains("New Alpha") && text.contains("Base Beta") && text.contains("Retained deleted child") && text.contains("Accepted added child") && !text.contains("New Beta") && !text.contains("Base Alpha"),"Editable mixed group output selected wrong leaf bodies")
        try require(!model.isDirty && model.savedURL==output && panels==1,"Group Save As lost checkpoint")
        if let path=ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_OUTPUT_DIR"]{try Data(contentsOf:output).write(to:URL(fileURLWithPath:path).appendingPathComponent("group-mixed.pptx"),options:.atomic)}
        let slide=try XMLDocument(data:saved.entries["ppt/slides/slide1.xml"]!,options:[])
        var pending:[XMLNode]=[slide],groups:[XMLElement]=[]
        while let node=pending.popLast(){
            pending.append(contentsOf:node.children ?? [])
            if let element=node as? XMLElement,element.localName=="grpSp",element.uri=="http://schemas.openxmlformats.org/presentationml/2006/main"{groups.append(element)}
        }
        try require(groups.count==2 && saved.entries["ppt/slideMasters/master.xml"] != nil && saved.entries["ppt/theme/theme.xml"] != nil,"Editable save flattened nested groups or dropped shared dependency graph: groups=\(groups.count), parts=\(saved.entries.keys.sorted())")
        if let path=ProcessInfo.processInfo.environment["TURTLEGIT_GROUP_OUTPUT_DIR"]{try Data(contentsOf:output).write(to:URL(fileURLWithPath:path).appendingPathComponent("group-mixed.pptx"),options:.atomic)}
    }}
    static func lifecycle()async throws {try await run{context in
        let owner=try context.owner(),model=owner.model.revision;try await wait{owner.model.pending==0}
        let output=context.root.appendingPathComponent("unresolved.pptx")
        do{try await model.save(to:output);throw Failure(description:"Unresolved nested deck exported")}catch is PresentationRevisionWindowModel.Failure{}
        try require(!FileManager.default.fileExists(atPath:output.path),"Unresolved group export created output")
        model.decideAll(accept:true);let before=model.review?.decisions
        owner.presentDiscard={_,_,reply in reply(false)};owner.close();try await wait{!owner.model.confirmingQuit}
        try require(!owner.model.retired && model.review?.decisions==before,"Cancelled group close lost choices")
        let gate=Gate();context.gates.append(gate)
        model.write={data,url,token in gate.start();while !gate.isReleased(){Thread.sleep(forTimeInterval:0.01)};try token.check();try data.write(to:url,options:.atomic)}
        let cancelled=context.root.appendingPathComponent("cancelled.pptx"),save=Task{do{try await model.save(to:cancelled)}catch{}}
        try await wait{gate.isStarted()};model.cancel()
        try require(model.exporting && owner.model.pending>0,"Cancel released active nested export worker")
        gate.release();await save.value;try await wait{owner.model.pending==0}
        try require(!FileManager.default.fileExists(atPath:cancelled.path) && model.review?.decisions==before && model.canSave,"Cancelled nested export wrote output/lost choices")
        let closing=try context.owner(),closingModel=closing.model.revision,held=Gate();context.gates.append(held)
        closingModel.decideAll(accept:true);closingModel.write={data,url,token in held.start();while !held.isReleased(){Thread.sleep(forTimeInterval:0.01)};try token.check();try data.write(to:url,options:.atomic)}
        let closedOutput=context.root.appendingPathComponent("closed.pptx"),pending=Task{do{try await closingModel.save(to:closedOutput)}catch{}}
        try await wait{held.isStarted()};closing.presentDiscard={_,_,reply in reply(true)};closing.close();try await wait{closing.model.retired}
        try require(closing.model.pending>0 && FileManager.default.fileExists(atPath:closing.model.preview.directory.path),"Closing group owner deleted private inputs before export retired")
        held.release();await pending.value;try await wait{closing.model.pending==0 && !FileManager.default.fileExists(atPath:closing.model.preview.directory.path)}
        try require(!FileManager.default.fileExists(atPath:closedOutput.path),"Retired nested export wrote output")
        let retired=closingModel.review?.decisions;closingModel.decideAll(accept:false);closingModel.undo();try require(closingModel.review?.decisions==retired,"Late group controls modified retired review")
    }}
}
