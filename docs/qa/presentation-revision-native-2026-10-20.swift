// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

@MainActor enum PresentationRevisionNativeVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ message:String)throws {if !condition{throw Failure(description:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Presentation revision timeout at \(line)")
    }
    static func package(_ text:String,macros:Bool=false)throws->PresentationPackage {
        let p="http://schemas.openxmlformats.org/presentationml/2006/main",a="http://schemas.openxmlformats.org/drawingml/2006/main",r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let mainType=macros ? "application/vnd.ms-powerpoint.presentation.macroEnabled.main+xml":"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"
        var entries:[String:Data]=[:]
        func put(_ path:String,_ xml:String){entries[path]=Data(xml.utf8)}
        put("[Content_Types].xml","<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/ppt/presentation.xml\" ContentType=\"\(mainType)\"/><Override PartName=\"/ppt/slides/slide1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/></Types>")
        put("_rels/.rels","<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"office\" Type=\"\(r)/officeDocument\" Target=\"ppt/presentation.xml\"/></Relationships>")
        put("ppt/presentation.xml","<p:presentation xmlns:p=\"\(p)\" xmlns:r=\"\(r)\"><p:sldIdLst><p:sldId id=\"256\" r:id=\"slide1\"/></p:sldIdLst><p:sldSz cx=\"9144000\" cy=\"5143500\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>")
        put("ppt/_rels/presentation.xml.rels","<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"slide1\" Type=\"\(r)/slide\" Target=\"slides/slide1.xml\"/></Relationships>")
        func shape(_ id:Int,_ title:String)->String {"<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"Text \(id)\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>\(title)</a:t></a:r></a:p></p:txBody></p:sp>"}
        put("ppt/slides/slide1.xml","<p:sld xmlns:p=\"\(p)\" xmlns:a=\"\(a)\" xmlns:r=\"\(r)\"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>\(shape(2,text+" first"))\(shape(3,text+" second"))</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>")
        // A normal slide/layout/master/theme cycle, unchanged on both sides.
        let emptyTree="<p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree>"
        func relationships(_ body:String)->String {"<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"+body+"</Relationships>"}
        func edge(_ id:String,_ type:String,_ target:String)->String {"<Relationship Id=\"\(id)\" Type=\"\(r)/\(type)\" Target=\"\(target)\"/>"}
        let presentation=String(data:entries["ppt/presentation.xml"]!,encoding:.utf8)!.replacingOccurrences(of:"<p:sldIdLst>",with:"<p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"master\"/></p:sldMasterIdLst><p:sldIdLst>")
        put("ppt/presentation.xml",presentation)
        put("ppt/_rels/presentation.xml.rels",relationships(edge("master","slideMaster","slideMasters/master.xml")+edge("slide1","slide","slides/slide1.xml")))
        put("ppt/slides/_rels/slide1.xml.rels",relationships(edge("layout","slideLayout","../slideLayouts/layout.xml")))
        put("ppt/slideLayouts/layout.xml","<p:sldLayout xmlns:p=\"\(p)\" xmlns:a=\"\(a)\" type=\"blank\" preserve=\"1\"><p:cSld name=\"Blank\">\(emptyTree)</p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>")
        put("ppt/slideLayouts/_rels/layout.xml.rels",relationships(edge("master","slideMaster","../slideMasters/master.xml")))
        put("ppt/slideMasters/master.xml","<p:sldMaster xmlns:p=\"\(p)\" xmlns:a=\"\(a)\" xmlns:r=\"\(r)\"><p:cSld>\(emptyTree)</p:cSld><p:clrMap accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" bg1=\"lt1\" bg2=\"lt2\" folHlink=\"folHlink\" hlink=\"hlink\" tx1=\"dk1\" tx2=\"dk2\"/><p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"layout\"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>")
        put("ppt/slideMasters/_rels/master.xml.rels",relationships(edge("layout","slideLayout","../slideLayouts/layout.xml")+edge("theme","theme","../theme/theme.xml")))
        let colors=[("dk1","000000"),("lt1","FFFFFF"),("dk2","1F497D"),("lt2","EEECE1"),("accent1","4F81BD"),("accent2","C0504D"),("accent3","9BBB59"),("accent4","8064A2"),("accent5","4BACC6"),("accent6","F79646"),("hlink","0000FF"),("folHlink","800080")].map{"<a:\($0.0)><a:srgbClr val=\"\($0.1)\"/></a:\($0.0)>"}.joined()
        let solid="<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let fonts="<a:latin typeface=\"Arial\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/>"
        let line="<a:ln w=\"9525\">\(solid)<a:prstDash val=\"solid\"/></a:ln>"
        let styles="<a:fillStyleLst>"+String(repeating:solid,count:3)+"</a:fillStyleLst><a:lnStyleLst>"+String(repeating:line,count:3)+"</a:lnStyleLst><a:effectStyleLst>"+String(repeating:"<a:effectStyle><a:effectLst/></a:effectStyle>",count:3)+"</a:effectStyleLst><a:bgFillStyleLst>"+String(repeating:solid,count:3)+"</a:bgFillStyleLst>"
        put("ppt/theme/theme.xml","<a:theme xmlns:a=\"\(a)\" name=\"TurtleGit fixture\"><a:themeElements><a:clrScheme name=\"Fixture\">\(colors)</a:clrScheme><a:fontScheme name=\"Fixture\"><a:majorFont>\(fonts)</a:majorFont><a:minorFont>\(fonts)</a:minorFont></a:fontScheme><a:fmtScheme name=\"Fixture\">\(styles)</a:fmtScheme></a:themeElements></a:theme>")
        let dependencyTypes=[("slideLayouts/layout.xml","application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"),("slideMasters/master.xml","application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"),("theme/theme.xml","application/vnd.openxmlformats-officedocument.theme+xml")].map{"<Override PartName=\"/ppt/\($0.0)\" ContentType=\"\($0.1)\"/>"}.joined()
        put("[Content_Types].xml",String(data:entries["[Content_Types].xml"]!,encoding:.utf8)!.replacingOccurrences(of:"</Types>",with:dependencyTypes+"</Types>"))
        if macros {
            entries["ppt/vbaProject.bin"]=Data([0,1,2,3])
            let types=String(data:entries["[Content_Types].xml"]!,encoding:.utf8)!.replacingOccurrences(of:"</Types>",with:"<Override PartName=\"/ppt/vbaProject.bin\" ContentType=\"application/vnd.ms-office.vbaProject\"/></Types>")
            put("[Content_Types].xml",types)
            let rels=String(data:entries["ppt/_rels/presentation.xml.rels"]!,encoding:.utf8)!.replacingOccurrences(of:"</Relationships>",with:"<Relationship Id=\"vba\" Type=\"http://schemas.microsoft.com/office/2006/relationships/vbaProject\" Target=\"vbaProject.bin\"/></Relationships>")
            put("ppt/_rels/presentation.xml.rels",rels)
        }
        return try PresentationPackage(entries:entries)
    }
    static func capture(_ window:NSWindow)async throws {
        guard let path=ProcessInfo.processInfo.environment["TURTLEGIT_PRESENTATION_REVISION_CAPTURE_DIR"] else{return}
        guard #available(macOS 14.4,*) else{throw Failure(description:"Owned revision capture requires macOS 14.4")}
        let directory=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        window.setFrameOrigin(.init(x:-12000,y:-12000));window.orderFront(nil);window.alphaValue=1;defer{window.alphaValue=0;window.orderOut(nil)}
        for (appearance,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:appearance);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:400_000_000)
            let content=try await SCShareableContent.currentProcess
            guard let owned=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else{throw Failure(description:"Owned revision window unavailable for capture")}
            let configuration=SCStreamConfiguration();configuration.width=Int(window.frame.width*2);configuration.height=Int(window.frame.height*2);configuration.showsCursor=false;configuration.ignoreShadowsSingleWindow=true;configuration.includeChildWindows=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:configuration)
            guard let png=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else{throw Failure(description:"Revision screenshot encoding failed")}
            try png.write(to:directory.appendingPathComponent("presentation-revision-"+name+".png"))
        }
    }
    final class WriteGate:@unchecked Sendable {
        private let lock=NSLock();private var started=false,released=false
        func enter(){lock.lock();started=true;lock.unlock()}
        func isStarted()->Bool {lock.lock();defer{lock.unlock()};return started}
        func release(){lock.lock();released=true;lock.unlock()}
        func isReleased()->Bool {lock.lock();defer{lock.unlock()};return released}
    }
    static func verify(root:URL,git:URL)async throws {
        let directory=root.appendingPathComponent("presentation-revision-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:directory)}
        let base=try package("Base"),new=try package("New"),review=try PresentationRevisionReview(base:base,destination:new)
        let a=directory.appendingPathComponent("original-base.pptx"),b=directory.appendingPathComponent("original-new.pptx")
        let baseData=try base.encoded(cancellation:.init()),newData=try new.encoded(cancellation:.init());try baseData.write(to:a);try newData.write(to:b)
        let document=try WorkingFileComparison(base:a,destination:b).read()
        let suite="TurtleGit.Revision."+UUID().uuidString,preferences=UserDefaults(suiteName:suite)!
        defer{preferences.removePersistentDomain(forName:suite)}
        var owners:[PresentationComparisonWindowController]=[]
        defer{for owner in owners {owner.presentDiscard={_,_,reply in reply(true)};owner.close()}}
        func controller(initial:PresentationRevisionReview?=review)throws->PresentationComparisonWindowController {
            let preview=try PresentationComparisonPreview.prepare(document,in:directory,cancellation:OperationCancellation())
            let owner=PresentationComparisonWindowController(preview:preview,manifest:.init(base:review.baseManifest,destination:review.destinationManifest),permissions:[],preferences:preferences,baseTitle:a.path,destinationTitle:b.path,protectedInputs:[a,b],initialReview:initial)
            owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-12000,y:-12000));owners.append(owner);return owner
        }
        let owner=try controller();owner.window?.orderFront(nil);try await wait{owner.model.pending==0}
        let model=owner.model.revision
        try require(model.changes.count>=2 && model.unresolvedCount==model.changes.count && !owner.model.sourcePreviewsAvailable && owner.model.renderError==nil,"Package review depended on exported PDFs or missed shape revisions")
        var choices=0
        owner.presentExport={_,_,reply in choices+=1;reply(.OK)};owner.chooseEditableExport()
        try require(choices==0,"Unresolved revisions opened Save As")
        model.selection=model.changes[0].id;model.decide(accept:true)
        try require(model.isDirty && model.unresolvedCount==model.changes.count-1,"Selected accept did not record a decision")
        try require(owner.model.reviewText.contains("Accepted New:") && owner.model.reviewText.contains("Unresolved:"),"Text review omitted accepted or unresolved revision decisions")
        model.undo();try require(!model.isDirty && model.unresolvedCount==model.changes.count,"Undo failed to restore undecided state")
        model.redo();try require(model.isDirty,"Redo failed")
        model.decideAll(accept:true);try require(model.canSave,"Accept all did not resolve the deck")
        for target in [a,b] {
            do{try await model.save(to:target);throw Failure(description:"Original presentation overwritten")}catch is PresentationRevisionWindowModel.Failure{}
        }
        let hardlink=directory.appendingPathComponent("alias.pptx"),symlink=directory.appendingPathComponent("symbolic.pptx")
        try FileManager.default.linkItem(at:a,to:hardlink);try FileManager.default.createSymbolicLink(at:symlink,withDestinationURL:b)
        for target in [hardlink,symlink,owner.model.preview.directory.appendingPathComponent("result.pptx"),directory.appendingPathComponent("wrong.txt")] {
            do{try await model.save(to:target);throw Failure(description:"Protected alias, private path or wrong extension accepted")}catch is PresentationRevisionWindowModel.Failure{}
        }
        let output=directory.appendingPathComponent("reviewed.pptx")
        owner.selectedExportURL={_ in output};owner.chooseEditableExport();try await wait{owner.model.pending==0}
        let exported=try PresentationPackage.read(from:output,cancellation:.init()),savedReview=try PresentationRevisionReview(base:new,destination:exported)
        try require(savedReview.changes.isEmpty && !model.isDirty && model.savedURL==output,"Editable Save As lost selected revisions or saved checkpoint: changes=\(savedReview.changes.map{"\($0.id):\($0.title)"}),dirty=\(model.isDirty),saved=\(String(describing:model.savedURL)),expected=\(output)")
        model.decideAll(accept:false);try require(model.isDirty,"New decisions did not dirty saved review")
        model.undo();try require(!model.isDirty,"Undo did not restore saved checkpoint");model.redo()
        let quitDelegate=TurtleGitApplicationDelegate()
        var quitQuestion:((Bool)->Void)?,quitAnswer:Bool?
        owner.presentDiscard={_,_,reply in quitQuestion=reply}
        quitDelegate.replyToTermination={_,answer in quitAnswer=answer}
        try require(quitDelegate.applicationShouldTerminate(NSApp) == .terminateLater,"Dirty presentation bypassed global Quit review")
        try await wait{quitQuestion != nil}
        let quitDecisions=model.review?.decisions,quitSelection=model.selection
        model.selection=nil;model.decideAll(accept:true);model.undo()
        try require(owner.model.confirmingQuit && model.review?.decisions==quitDecisions && model.selection==quitSelection,"Global Quit failed to freeze revision controls")
        quitQuestion?(false);quitQuestion=nil
        try await wait{quitAnswer==false && !owner.model.confirmingQuit}
        try require(model.review?.decisions==quitDecisions && !owner.model.retired,"Quit Cancel discarded revision decisions or failed to thaw controls")
        owner.presentDiscard={_,_,reply in reply(false)};owner.close();try await wait{!owner.model.confirmingQuit}
        try require(!owner.model.retired && model.isDirty,"Cancel dirty-close discarded review decisions")
        model.selection=model.changes[0].id;model.decide(accept:true)
        let clipboard=NSPasteboard.withUniqueName();owner.model.clipboard=clipboard;defer{clipboard.clearContents();clipboard.releaseGlobally()}
        owner.model.copyReview()
        try require(clipboard.string(forType:.string)?.contains("Accepted New:")==true && clipboard.string(forType:.string)?.contains("Rejected Base:")==true,"Copy Review omitted mixed accepted/rejected decisions")
        try await capture(owner.window!)
        owner.presentDiscard={_,_,reply in reply(true)};owner.close();try await wait{!FileManager.default.fileExists(atPath:owner.model.preview.directory.path)}
        try require(owner.model.retired && !model.isDirty,"Confirmed discard did not retire the owner and its dirty-work claim")
        let retiredSelection=model.selection,retiredDecisions=model.review?.decisions
        model.selection=nil;model.decideAll(accept:true);model.undo()
        try require(model.selection==retiredSelection && model.review?.decisions==retiredDecisions,"Late controls changed a retired review")
        let quittingOwner=try controller();quittingOwner.window?.orderFront(nil);try await wait{quittingOwner.model.pending==0}
        quittingOwner.model.revision.decideAll(accept:false)
        quittingOwner.presentDiscard={_,_,reply in reply(true)}
        let discardDelegate=TurtleGitApplicationDelegate();var discardedQuit:Bool?
        discardDelegate.replyToTermination={_,answer in discardedQuit=answer}
        try require(discardDelegate.applicationShouldTerminate(NSApp) == .terminateLater,"Dirty review skipped approved-Quit confirmation")
        do {try await wait{discardedQuit==true && quittingOwner.model.retired && quittingOwner.model.pending==0}}
        catch {
            let states=NSApp.windows.compactMap{$0.delegate as? PresentationComparisonWindowController}.map{"retired=\($0.model.retired),dirty=\($0.model.revision.isDirty),pending=\($0.model.pending),frozen=\($0.model.confirmingQuit)"}.joined(separator:"; ")
            throw Failure(description:"Approved Quit did not drain: answer=\(String(describing:discardedQuit)), targetRetired=\(quittingOwner.model.retired), targetPending=\(quittingOwner.model.pending); windows: \(states); \(error)")
        }
        try require(!FileManager.default.fileExists(atPath:quittingOwner.model.preview.directory.path),"Approved Quit retained discarded private review inputs")
        let loading=try controller(initial:nil);loading.close();try await wait{loading.model.pending==0 && !FileManager.default.fileExists(atPath:loading.model.preview.directory.path)}
        try require(loading.model.revision.retired,"Closed package load retained a live editor")
        let exportingOwner=try controller(),gate=WriteGate(),cancelledOutput=directory.appendingPathComponent("cancelled.pptx")
        defer{gate.release()}
        exportingOwner.model.revision.decideAll(accept:true)
        exportingOwner.model.revision.write={data,url,token in
            gate.enter()
            while !gate.isReleased(){Thread.sleep(forTimeInterval:0.01)}
            try token.check();try data.write(to:url,options:.atomic)
        }
        exportingOwner.presentDiscard={_,_,reply in reply(true)}
        let saving=Task {do{try await exportingOwner.model.revision.save(to:cancelledOutput)}catch{}}
        try await wait{gate.isStarted()}
        exportingOwner.close();try await wait{exportingOwner.model.retired}
        try require(exportingOwner.model.pending>0 && FileManager.default.fileExists(atPath:exportingOwner.model.preview.directory.path) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Retired export released grants, private inputs or Quit before worker drain")
        gate.release();await saving.value
        try await wait{exportingOwner.model.pending==0 && !FileManager.default.fileExists(atPath:exportingOwner.model.preview.directory.path)}
        try require(!FileManager.default.fileExists(atPath:cancelledOutput.path),"Retired export committed after cooperative cancellation")
        let macroReview=try PresentationRevisionReview(base:base,destination:package("Macro",macros:true))
        let macroPreview=try PresentationComparisonPreview.prepare(document,in:directory,cancellation:OperationCancellation())
        let macroModel=PresentationRevisionWindowModel(preview:macroPreview,protectedInputs:[a,b],initialReview:macroReview);defer{macroPreview.discard()}
        macroModel.decideAll(accept:true)
        try require(macroModel.suggestedExtension=="pptm","Macro-bearing review offered .pptx")
        do{try await macroModel.save(to:directory.appendingPathComponent("macros.pptx"));throw Failure(description:"Macro extension was not protected")}catch is PresentationRevisionWindowModel.Failure{}
        let macroOutput=directory.appendingPathComponent("macros.pptm");try await macroModel.save(to:macroOutput)
        try require(try PresentationPackage.read(from:macroOutput,cancellation:.init()).entries["ppt/vbaProject.bin"]==Data([0,1,2,3]),"Editable export lost opaque VBA bytes")
        if let path=ProcessInfo.processInfo.environment["TURTLEGIT_PRESENTATION_REVISION_OUTPUT_DIR"] {
            let artifacts=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:artifacts,withIntermediateDirectories:true)
            try Data(contentsOf:output).write(to:artifacts.appendingPathComponent("reviewed.pptx"),options:.atomic)
            try Data(contentsOf:macroOutput).write(to:artifacts.appendingPathComponent("macros.pptm"),options:.atomic)
        }
        let oldExport=DiffToolApplication.exportPowerPoint,oldPresent=DiffToolApplication.presentPresentation
        defer{DiffToolApplication.exportPowerPoint=oldExport;DiffToolApplication.presentPresentation=oldPresent;DiffToolApplication.discardAll()}
        var published:PresentationComparisonWindowController?
        DiffToolApplication.exportPowerPoint={_,_ in throw PowerPointComparisonAutomation.Failure.application}
        DiffToolApplication.presentPresentation={value in value.window?.alphaValue=0;value.window?.setFrameOrigin(.init(x:-12000,y:-12000));published=value;owners.append(value);return true}
        try require(try await DiffToolApplication.open(document,root:directory,permissions:[],alternate:false,preferences:preferences),"Unavailable PowerPoint did not open package review")
        guard let fallbackController=published else{throw Failure(description:"Package-only controller missing")}
        try await wait{fallbackController.model.pending==0}
        try require(fallbackController.model.revision.review != nil && !FileManager.default.fileExists(atPath:fallbackController.model.preview.basePDF.path),"Unavailable PowerPoint claimed a visual export or lost editable review")
        fallbackController.close();try await wait{fallbackController.model.pending==0}
        var uncertain:URL?;published=nil
        DiffToolApplication.exportPowerPoint={preview,_ in uncertain=preview.directory;throw PowerPointComparisonAutomation.Failure.automation(-1712,"uncertain",possiblyOpened:true)}
        do{_=try await DiffToolApplication.open(document,root:directory,permissions:[],alternate:false,preferences:preferences);throw Failure(description:"Uncertain export silently fell back")}catch let failure as PowerPointComparisonAutomation.Failure {try require(failure.possiblyOpened,"Uncertain export lost retention")}
        try require(published==nil && uncertain.map{FileManager.default.fileExists(atPath:$0.path)}==true,"Uncertain export published fallback or deleted owned inputs")
        if let uncertain {try? FileManager.default.removeItem(at:uncertain)}
        try require(try Data(contentsOf:a)==baseData && Data(contentsOf:b)==newData,"Revision review modified original inputs")
        try require(PresentationComparisonWindowModel.activeRequests==0,"Revision lifecycle left active work")
        print("PASS: native editable shape decisions, undo/redo, unresolved/save checkpoints, macro/alias protections, dirty-close/load retirement and package-only routing; unchanged original files")
    }
}
