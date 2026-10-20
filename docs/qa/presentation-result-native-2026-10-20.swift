// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

@MainActor enum PresentationResultNativeVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ condition:Bool,_ message:String)throws {if !condition{throw Failure(description:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Result preview timeout at \(line)")
    }
    static func package(_ text:String)throws->PresentationPackage {
        var entries=try PresentationRevisionNativeVerification.package(text).entries
        func append(_ path:String,before:String,content:String){entries[path]=Data(String(data:entries[path]!,encoding:.utf8)!.replacingOccurrences(of:before,with:content+before).utf8)}
        entries["ppt/slides/slide2.xml"]=Data(String(data:entries["ppt/slides/slide1.xml"]!,encoding:.utf8)!.replacingOccurrences(of:text,with:"Second slide").utf8)
        entries["ppt/slides/_rels/slide2.xml.rels"]=entries["ppt/slides/_rels/slide1.xml.rels"]
        append("[Content_Types].xml",before:"</Types>",content:"<Override PartName=\"/ppt/slides/slide2.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>")
        append("ppt/presentation.xml",before:"</p:sldIdLst>",content:"<p:sldId id=\"257\" r:id=\"slide2\"/>")
        append("ppt/_rels/presentation.xml.rels",before:"</Relationships>",content:"<Relationship Id=\"slide2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide2.xml\"/>")
        return try .init(entries:entries)
    }
    static func pdf(_ url:URL,manifest:PresentationSlideManifest)throws {
        var media=CGRect(x:0,y:0,width:640,height:360)
        guard let context=CGContext(url as CFURL,mediaBox:&media,nil) else{throw Failure(description:"Result PDF fixture unavailable")}
        for slide in manifest.slides {
            context.beginPDFPage(nil);context.setFillColor(CGColor(gray:1,alpha:1));context.fill(media)
            context.setFillColor(slide.text.contains("New") ? CGColor(red:0.1,green:0.7,blue:0.2,alpha:1):CGColor(red:0.2,green:0.4,blue:0.9,alpha:1));context.fill(CGRect(x:80,y:60,width:400,height:220));context.endPDFPage()
        }
        context.closePDF();try FileManager.default.setAttributes([.posixPermissions:0o444],ofItemAtPath:url.path)
    }
    static func render(_ package:URL,_ output:URL,_ token:OperationCancellation)async throws->PresentationSlideManifest {
        try token.check();let attributes=try FileManager.default.attributesOfItem(atPath:package.path)
        try require((attributes[.posixPermissions] as? NSNumber)?.intValue==0o444,"Result snapshot was not immutable")
        let value=try PresentationPackage.read(from:package,cancellation:token),manifest=try PresentationRevisionReview(base:value,destination:value,cancellation:token).baseManifest
        try pdf(output,manifest:manifest);return manifest
    }
    static func capture(_ window:NSWindow)async throws {
        guard let path=ProcessInfo.processInfo.environment["TURTLEGIT_PRESENTATION_RESULT_CAPTURE_DIR"] else{return}
        guard #available(macOS 14.4,*) else{throw Failure(description:"Owned result capture requires macOS14.4")}
        let directory=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        window.setFrameOrigin(.init(x:-12000,y:-12000));window.orderFront(nil);window.alphaValue=1;defer{window.alphaValue=0;window.orderOut(nil)}
        for (appearance,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:appearance);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:400_000_000)
            let content=try await SCShareableContent.currentProcess
            guard let owned=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else{throw Failure(description:"Owned result capture missing")}
            let configuration=SCStreamConfiguration();configuration.width=Int(window.frame.width*2);configuration.height=Int(window.frame.height*2);configuration.showsCursor=false;configuration.ignoreShadowsSingleWindow=true;configuration.includeChildWindows=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:configuration)
            guard let png=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else{throw Failure(description:"Result screenshot encoding failed")}
            try png.write(to:directory.appendingPathComponent("presentation-result-"+name+".png"))
        }
    }
    static func verify(root:URL,git:URL)async throws {
        let directory=root.appendingPathComponent("presentation-result-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:directory)}
        let base=try package("Base"),new=try package("New"),review=try PresentationRevisionReview(base:base,destination:new)
        let a=directory.appendingPathComponent("original-base.pptx"),b=directory.appendingPathComponent("original-new.pptx")
        let oldBytes=try base.encoded(cancellation:.init()),newBytes=try new.encoded(cancellation:.init())
        try oldBytes.write(to:a);try newBytes.write(to:b)
        let legacyBase=directory.appendingPathComponent("old.ppt"),legacyNew=directory.appendingPathComponent("new.ppt"),legacyBytes=Data([0xD0,0xCF,0x11,0xE0,0xA1,0xB1,0x1A,0xE1,1,2])
        try legacyBytes.write(to:legacyBase);try (legacyBytes+Data([3])).write(to:legacyNew)
        let repository=GitRepository(root:directory,executable:git)
        _=try await repository.run(["init","-b","main"])
        for (key,value) in [("user.name","Presentation Result QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repository.run(["config",key,value])}
        try await repository.stage([a.lastPathComponent,b.lastPathComponent,legacyBase.lastPathComponent,legacyNew.lastPathComponent])
        _=try await repository.commit(message:"private comparison inputs")
        let index=directory.appendingPathComponent(".git/index"),indexBefore=try Data(contentsOf:index),headBefore=try await repository.run(["rev-parse","HEAD"]).stdout
        func unchangedRepository()async throws {
            try require(try await repository.run(["rev-parse","HEAD"]).stdout==headBefore,"Presentation workflow changed repository HEAD")
            try require(try Data(contentsOf:index)==indexBefore,"Presentation workflow changed repository index")
            try require(try Data(contentsOf:a)==oldBytes && Data(contentsOf:b)==newBytes && Data(contentsOf:legacyBase)==legacyBytes && Data(contentsOf:legacyNew)==legacyBytes+Data([3]),"Presentation workflow changed tracked source files")
        }

        let suite="TurtleGit.Result."+UUID().uuidString,preferences=UserDefaults(suiteName:suite)!;defer{preferences.removePersistentDomain(forName:suite)}
        let document=try WorkingFileComparison(base:a,destination:b).read()
        var owners:[PresentationComparisonWindowController]=[]
        defer{for owner in owners {owner.presentDiscard={_,_,reply in reply(true)};owner.close()}}
        func controller()throws->PresentationComparisonWindowController {
            let preview=try PresentationComparisonPreview.prepare(document,in:directory,cancellation:.init())
            let value=PresentationComparisonWindowController(preview:preview,manifest:.init(base:review.baseManifest,destination:review.destinationManifest),permissions:[],preferences:preferences,baseTitle:a.path,destinationTitle:b.path,protectedInputs:[a,b],initialReview:review)
            value.window?.alphaValue=0;value.window?.setFrameOrigin(.init(x:-12000,y:-12000));value.presentDiscard={_,_,reply in reply(true)};owners.append(value);return value
        }
        let owner=try controller();try await wait{owner.model.pending==0};let model=owner.model.revision
        var renders=0,artifacts:[URL]=[]
        model.renderResult={package,pdf,token in renders+=1;artifacts.append(package.deletingLastPathComponent());return try await render(package,pdf,token)}
        model.previewResult();try require(renders==0,"Unresolved result launched PowerPoint")
        model.decideAll(accept:false);model.decide(changeID:model.changes[0].id,accept:true)
        model.previewResult();try await wait{owner.model.pending==0 && model.resultImages != nil}
        try require(renders==1 && model.resultIsCurrent && model.previewMode == .result && model.resultManifest?.slides.count==2,"Combined result did not publish actual rendered snapshot")
        try await unchangedRepository()
        let text=model.resultManifest!.slides[0].text
        try require(text.contains("New first") && text.contains("Base second"),"Result metadata did not match mixed decisions")
        if let path=ProcessInfo.processInfo.environment["TURTLEGIT_PRESENTATION_RESULT_OUTPUT_DIR"] {
            let output=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
            try Data(contentsOf:artifacts[0].appendingPathComponent("reviewed.pptx")).write(to:output.appendingPathComponent("mixed.pptx"))
        }
        model.previewResult();try require(renders==1,"Current result was rendered again without a changed snapshot")
        model.navigateResult(1);try await wait{model.resultSelection==1 && !model.resultRendering && model.resultImages != nil}
        try require(model.resultSlide?.text.contains("Second slide")==true,"Result navigation did not use result slide metadata")
        model.navigateResult(-1);try await wait{model.resultSelection==0 && !model.resultRendering}
        try await capture(owner.window!)
        model.decide(changeID:model.changes[0].id,accept:false)
        try require(!model.resultIsCurrent && renders==1 && model.resultManifest!.slides[0].text==text,"Decision change silently replaced or rerendered stale result")
        var held:CheckedContinuation<PresentationSlideManifest,Error>?,heldManifest:PresentationSlideManifest?,heldToken:OperationCancellation?
        defer{held?.resume(throwing:CancellationError())}
        model.renderResult={package,pdf,token in renders+=1;heldToken=token;heldManifest=try await render(package,pdf,token);return try await withCheckedThrowingContinuation{held=$0}}
        model.previewResult();try await wait{held != nil}
        model.decideAll(accept:true)
        try require(heldToken?.isCancelled==true && owner.model.pending>0,"New choices failed to cancel and retain in-flight rendering")
        held?.resume(returning:heldManifest!);held=nil;try await wait{owner.model.pending==0}
        try require(!model.resultIsCurrent && model.resultManifest!.slides[0].text==text,"Late stale result replaced current decision generation")
        model.renderResult={_,_,_ in throw PowerPointComparisonAutomation.Failure.application}
        model.previewResult();try await wait{owner.model.pending==0}
        try require(model.resultError != nil && model.canPreviewResult,"Unavailable renderer lost explicit retry state")
        model.renderResult={package,output,token in
            let full=try await render(package,output,token);try FileManager.default.removeItem(at:output)
            try pdf(output,manifest:.init(slides:Array(full.slides.prefix(1))))
            return full
        }
        model.previewResult();try await wait{owner.model.pending==0}
        try require(model.resultError != nil && !model.resultIsCurrent && model.resultManifest!.slides[0].text==text,"Mismatched PDF metadata replaced the prior review result")
        model.renderResult={package,pdf,token in try await render(package,pdf,token)}
        model.previewResult();try await wait{owner.model.pending==0 && model.resultIsCurrent}
        try require(model.resultManifest!.slides[0].text.contains("New second"),"Retry did not render current decisions")
        model.decideAll(accept:false)
        model.renderResult={package,pdf,token in heldToken=token;heldManifest=try await render(package,pdf,token);return try await withCheckedThrowingContinuation{held=$0}}
        model.previewResult();try await wait{held != nil};model.cancel()
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Quit escaped result worker")
        owner.close();try await wait{owner.model.retired}
        try require(heldToken?.isCancelled==true && FileManager.default.fileExists(atPath:owner.model.preview.directory.path),"Retired result released captured inputs before receipt")
        held?.resume(throwing:PowerPointComparisonAutomation.Failure.automation(-128,"cancelled",possiblyOpened:false));held=nil
        try await wait{owner.model.pending==0 && !FileManager.default.fileExists(atPath:owner.model.preview.directory.path)}
        let uncertain=try controller();try await wait{uncertain.model.pending==0};let uncertainModel=uncertain.model.revision
        uncertainModel.decideAll(accept:true)
        uncertainModel.renderResult={_,_,token in heldToken=token;return try await withCheckedThrowingContinuation{held=$0}}
        uncertainModel.previewResult();try await wait{held != nil};uncertain.close();try await wait{uncertain.model.retired}
        held?.resume(throwing:PowerPointComparisonAutomation.Failure.automation(-1712,"uncertain",possiblyOpened:true));held=nil
        try await wait{uncertain.model.pending==0}
        try require(uncertainModel.retainPrivateArtifacts && FileManager.default.fileExists(atPath:uncertain.model.preview.directory.path),"Uncertain closed render deleted possibly opened snapshot")
        // The injected renderer opened no Office process, so this fixture owns
        // and can explicitly retire its deliberately retained uncertainty files.
        try FileManager.default.removeItem(at:uncertain.model.preview.directory)
        let oldExport=DiffToolApplication.exportPowerPoint,oldPresent=DiffToolApplication.presentPresentation
        defer{DiffToolApplication.exportPowerPoint=oldExport;DiffToolApplication.presentPresentation=oldPresent;DiffToolApplication.discardAll()}

        var binaryOwner:PresentationComparisonWindowController?
        DiffToolApplication.exportPowerPoint={preview,token in
            try require(try Data(contentsOf:preview.base)==legacyBytes,"Binary input changed before normalization")
            try oldBytes.write(to:preview.basePackage);try newBytes.write(to:preview.destinationPackage)
            for file in [preview.basePackage,preview.destinationPackage]{try FileManager.default.setAttributes([.posixPermissions:0o444],ofItemAtPath:file.path)}
            try pdf(preview.basePDF,manifest:review.baseManifest);try pdf(preview.destinationPDF,manifest:review.destinationManifest)
            return .init(base:review.baseManifest,destination:review.destinationManifest)
        }
        DiffToolApplication.presentPresentation={value in value.window?.alphaValue=0;value.window?.setFrameOrigin(.init(x:-12000,y:-12000));value.presentDiscard={_,_,reply in reply(true)};binaryOwner=value;owners.append(value);return true}
        try require(try await DiffToolApplication.open(WorkingFileComparison(base:legacyBase,destination:legacyNew).read(),root:directory,permissions:[],alternate:false,preferences:preferences),"Binary normalized route failed")
        guard let binaryOwner else{throw Failure(description:"Binary normalized controller missing")}
        try await wait{binaryOwner.model.pending==0};let binary=binaryOwner.model.revision
        try require(binary.review != nil && binary.changes.count==2 && binary.preferredSaveExtension=="ppt","Binary normalization did not enable editable review with explicit binary Save As")
        binary.decideAll(accept:true)
        var conversions=0
        binary.convertLegacyResult={package,output,token in
            conversions+=1;let value=try PresentationPackage.read(from:package,cancellation:token)
            try require(try PresentationRevisionReview(base:value,destination:value).baseManifest.slides[0].text.contains("New second"),"Binary conversion did not receive chosen revisions")
            try token.check();try legacyBytes.write(to:output)
        }
        do{try await binary.save(to:legacyBase);throw Failure(description:"Binary Save As overwrote its source")}catch is PresentationRevisionWindowModel.Failure{}
        try require(conversions==0,"Original-path refusal launched a binary conversion")
        let legacyOutput=directory.appendingPathComponent("reviewed.ppt");try await binary.save(to:legacyOutput)
        try require(conversions==1 && (try Data(contentsOf:legacyOutput))==legacyBytes,"Binary Save As did not commit confirmed private conversion")
        try await unchangedRepository()
        binary.saveFormat = .openXML;let openXMLOutput=directory.appendingPathComponent("reviewed.pptx");try await binary.save(to:openXMLOutput)
        try require(conversions==1 && (try PresentationPackage.read(from:openXMLOutput,cancellation:.init())).entries["ppt/slides/slide1.xml"] != nil,"OpenXML Save As unexpectedly roundtripped binary")
        var conversionReply:CheckedContinuation<Void,Error>?,conversionToken:OperationCancellation?
        defer{conversionReply?.resume(throwing:CancellationError())}
        binary.convertLegacyResult={_,_,token in conversionToken=token;try await withCheckedThrowingContinuation{conversionReply=$0}}
        let cancelledBinary=directory.appendingPathComponent("cancelled-binary.ppt")
        let converting=Task {do{try await binary.save(to:cancelledBinary)}catch{}}
        try await wait{conversionReply != nil};binaryOwner.close();try await wait{binaryOwner.model.retired}
        try require(conversionToken?.isCancelled==true && binaryOwner.model.pending>0 && FileManager.default.fileExists(atPath:binaryOwner.model.preview.directory.path),"Binary conversion released owner or inputs before cleanup receipt")
        conversionReply?.resume(throwing:PowerPointComparisonAutomation.Failure.automation(-128,"cancelled",possiblyOpened:false));conversionReply=nil
        await converting.value
        try await wait{binaryOwner.model.pending==0 && !FileManager.default.fileExists(atPath:binaryOwner.model.preview.directory.path)}
        try require(!FileManager.default.fileExists(atPath:cancelledBinary.path),"Cancelled binary conversion committed output")
        let uncertainConversion=try controller();try await wait{uncertainConversion.model.pending==0}
        let conversionModel=uncertainConversion.model.revision;conversionModel.decideAll(accept:true)
        conversionModel.convertLegacyResult={_,_,token in conversionToken=token;try await withCheckedThrowingContinuation{conversionReply=$0}}
        let uncertainOutput=directory.appendingPathComponent("uncertain-binary.ppt")
        let convertingUncertain=Task {do{try await conversionModel.save(to:uncertainOutput)}catch{}}
        try await wait{conversionReply != nil};uncertainConversion.close();try await wait{uncertainConversion.model.retired}
        conversionReply?.resume(throwing:PowerPointComparisonAutomation.Failure.automation(-1712,"uncertain",possiblyOpened:true));conversionReply=nil
        await convertingUncertain.value;try await wait{uncertainConversion.model.pending==0}
        try require(conversionModel.retainPrivateArtifacts && FileManager.default.fileExists(atPath:uncertainConversion.model.preview.directory.path) && !FileManager.default.fileExists(atPath:uncertainOutput.path),"Uncertain binary conversion lost private ownership or committed unconfirmed output")
        try FileManager.default.removeItem(at:uncertainConversion.model.preview.directory)
        let rawCancelledRender=try controller();try await wait{rawCancelledRender.model.pending==0}
        rawCancelledRender.model.revision.decideAll(accept:true)
        rawCancelledRender.model.revision.renderResult={_,_,_ in throw OperationCancellationFailure.cancelled}
        rawCancelledRender.model.revision.previewResult();try await wait{rawCancelledRender.model.pending==0}
        try require(rawCancelledRender.model.revision.retainPrivateArtifacts,"Untyped post-dispatch render cancellation falsely proved closure")
        rawCancelledRender.close();try await wait{rawCancelledRender.model.retired}
        try require(FileManager.default.fileExists(atPath:rawCancelledRender.model.preview.directory.path),"Untyped cancellation removed potentially open render input")
        try FileManager.default.removeItem(at:rawCancelledRender.model.preview.directory)
        let rawCancelledConversion=try controller();try await wait{rawCancelledConversion.model.pending==0}
        let rawConversion=rawCancelledConversion.model.revision;rawConversion.decideAll(accept:true)
        rawConversion.convertLegacyResult={_,_,_ in throw OperationCancellationFailure.cancelled}
        do{try await rawConversion.save(to:directory.appendingPathComponent("raw-cancelled.ppt"));throw Failure(description:"Untyped conversion cancellation succeeded")}catch is OperationCancellationFailure{}
        try require(rawConversion.retainPrivateArtifacts,"Untyped post-dispatch conversion cancellation falsely proved closure")
        rawCancelledConversion.close();try await wait{rawCancelledConversion.model.retired}
        try require(FileManager.default.fileExists(atPath:rawCancelledConversion.model.preview.directory.path),"Untyped cancellation removed potentially open conversion input")
        try FileManager.default.removeItem(at:rawCancelledConversion.model.preview.directory)
        try await unchangedRepository()
        try require(PresentationComparisonWindowModel.activeRequests==0,"Result workflow left live work")
        print("PASS: explicit rendered result snapshot, mixed decisions, result navigation, stale generation, retry/cancel/closed receipt ownership, binary normalization + private binary Save As; private repository HEAD/index and original inputs unchanged")
    }
}
