// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// Actual production bridge with injected Apple-event execution. No Office
/// presentation is opened; dictionary compilation is optional when installed.
@MainActor enum PowerPointRevisionAutomationVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    nonisolated static func list(_ values:[NSAppleEventDescriptor])->NSAppleEventDescriptor {
        let value=NSAppleEventDescriptor.list();for (index,item) in values.enumerated(){value.insert(item,at:index+1)};return value
    }
    nonisolated static func receipt(code:Int32=0,opened:Bool=false,restored:Bool=true,both:Bool=false)->PowerPointComparisonAutomation.ExecutionReply {
        var slideRows:[NSAppleEventDescriptor]=[]
        for index in 0..<2 {
            let number=NSAppleEventDescriptor(int32:Int32(index))
            let identifier=NSAppleEventDescriptor(string:String(256+index))
            let text=NSAppleEventDescriptor(string:index==0 ? "visible":"hidden slide")
            let notes=NSAppleEventDescriptor(string:"speaker notes")
            let fields:[NSAppleEventDescriptor]=[number,identifier,text,notes]
            slideRows.append(list(fields))
        }
        let rows=list(slideRows)
        let status=NSAppleEventDescriptor(int32:code)
        let message=NSAppleEventDescriptor(string:code==0 ? "":"Injected export refusal")
        let openedResult=NSAppleEventDescriptor(boolean:opened)
        let restoredResult=NSAppleEventDescriptor(boolean:restored)
        let secondRows:NSAppleEventDescriptor=both ? rows:list([])
        let fields:[NSAppleEventDescriptor]=[status,message,openedResult,restoredResult,rows,secondRows]
        return PowerPointComparisonAutomation.ExecutionReply(result:list(fields),error:nil)
    }
    nonisolated static func stub()throws->NSAppleScript {
        guard let script=NSAppleScript(source:"on run\nreturn 0\nend run") else{throw Failure(description:"No injected script")}
        var error:NSDictionary?;guard script.compileAndReturnError(&error) else{throw Failure(description:"Injected script did not compile")};return script
    }
    nonisolated static func pdf(_ url:URL,pages:Int=2)throws {
        let data=NSMutableData();var bounds=CGRect(x:0,y:0,width:96,height:64)
        guard let consumer=CGDataConsumer(data:data as CFMutableData),let context=CGContext(consumer:consumer,mediaBox:&bounds,nil) else{throw Failure(description:"Cannot create PDF")}
        for _ in 0..<pages {context.beginPDFPage(nil);context.setFillColor(red:0.2,green:0.7,blue:0.1,alpha:1);context.fill(.init(x:4,y:4,width:64,height:48));context.endPDFPage()};context.closePDF()
        try (data as Data).write(to:url,options:.withoutOverwriting)
    }
    nonisolated static func binary(_ url:URL,valid:Bool=true)throws {
        var bytes=Data(repeating:0,count:512)
        if valid {bytes.replaceSubrange(0..<8,with:[0xd0,0xcf,0x11,0xe0,0xa1,0xb1,0x1a,0xe1])}
        try bytes.write(to:url,options:.withoutOverwriting)
    }
    nonisolated static func package()throws->Data {
        // Includes VBA and a hidden slide. The bridge must retain opaque VBA
        // bytes and require metadata/PDF page counts for every slide, incl hidden.
        let p="http://schemas.openxmlformats.org/presentationml/2006/main",r="http://schemas.openxmlformats.org/officeDocument/2006/relationships",rels="http://schemas.openxmlformats.org/package/2006/relationships"
        let entries:[String:Data]=[
            "[Content_Types].xml":Data("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.ms-powerpoint.presentation.macroEnabled.main+xml\"/><Override PartName=\"/ppt/vbaProject.bin\" ContentType=\"application/vnd.ms-office.vbaProject\"/></Types>".utf8),
            "_rels/.rels":Data("<Relationships xmlns=\"\(rels)\"><Relationship Id=\"office\" Type=\"\(r)/officeDocument\" Target=\"ppt/presentation.xml\"/></Relationships>".utf8),
            "ppt/presentation.xml":Data("<p:presentation xmlns:p=\"\(p)\" xmlns:r=\"\(r)\"><p:sldIdLst><p:sldId id=\"256\" r:id=\"one\"/><p:sldId id=\"257\" r:id=\"two\"/></p:sldIdLst></p:presentation>".utf8),
            "ppt/_rels/presentation.xml.rels":Data("<Relationships xmlns=\"\(rels)\"><Relationship Id=\"one\" Type=\"\(r)/slide\" Target=\"slides/one.xml\"/><Relationship Id=\"two\" Type=\"\(r)/slide\" Target=\"slides/two.xml\"/><Relationship Id=\"vba\" Type=\"http://schemas.microsoft.com/office/2006/relationships/vbaProject\" Target=\"vbaProject.bin\"/></Relationships>".utf8),
            "ppt/slides/one.xml":Data("<p:sld xmlns:p=\"\(p)\"><p:cSld><p:spTree/></p:cSld></p:sld>".utf8),
            "ppt/slides/two.xml":Data("<p:sld xmlns:p=\"\(p)\" show=\"0\"><p:cSld><p:spTree/></p:cSld></p:sld>".utf8),
            "ppt/vbaProject.bin":Data([0,255,18,77,0,11])]
        return try PresentationPackage(entries:entries).encoded(cancellation:.init())
    }
    static func directory(_ root:URL)throws->URL {
        let url=root.appendingPathComponent("revision-automation-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);return url
    }
    static func input(_ directory:URL)throws->URL {
        let url=directory.appendingPathComponent("reviewed-'雪\n.pptm")
        try package().write(to:url,options:.withoutOverwriting);try FileManager.default.setAttributes([.posixPermissions:0o444],ofItemAtPath:url.path);return url
    }
    nonisolated static func failed(_ error:Error)->PowerPointComparisonAutomation.ExecutionReply {.init(result:nil,error:[NSAppleScript.errorNumber:-1,NSAppleScript.errorMessage:error.localizedDescription])}
    static func verify(root:URL,git:URL)async throws {
        _=git
        let root=try directory(root);defer{try? FileManager.default.removeItem(at:root)}
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier:PowerPointComparisonAutomation.bundleIdentifier) != nil {_=try PowerPointComparisonAutomation.compile()}
        let source=PowerPointComparisonAutomation.source
        try require(source.contains("save as Open XML presentation macro enabled") && source.contains("save as presentation") && source.contains("print hidden slides") && source.contains("automation security is not msoAutomationSecurityForceDisable"),"Source omitted binary/macro-safe normalization, legacy Save As or hidden slides")
        try require(!source.contains("active presentation") && !source.contains("do shell script") && !source.contains("activate") && !source.contains("quit"),"Exporter targeted user focus or shell text")
        let original=root.appendingPathComponent("original.ppt");try binary(original)
        let bytes=try Data(contentsOf:original),document=try WorkingFileComparison(base:original,destination:original).read(),preview=try PresentationComparisonPreview.prepare(document,in:root,cancellation:.init())
        defer{preview.discard()}
        let event=PowerPointComparisonAutomation.event(preview,cancellationFile:preview.directory.appendingPathComponent("automation.cancel")),args=event.paramDescriptor(forKeyword:0x2d2d2d2d)
        try require(args?.numberOfItems==7 && args?.atIndex(6)?.stringValue==preview.basePackage.path && args?.atIndex(7)?.stringValue==preview.destinationPackage.path && preview.basePackage.pathExtension=="pptm","Binary normalization paths were not literal private event arguments")
        _=try await PowerPointComparisonAutomation.export(preview,cancellation:.init(),dependencies:.init(compile:stub,applicationAvailable:{true},execute:{_,event in
            do {
                let args=event.paramDescriptor(forKeyword:0x2d2d2d2d)!
                for index in [3,4] {try pdf(URL(fileURLWithPath:args.atIndex(index)!.stringValue!))}
                for index in [6,7] {try package().write(to:URL(fileURLWithPath:args.atIndex(index)!.stringValue!),options:.withoutOverwriting)}
                return receipt(both:true)
            }catch{return failed(error)}
        }))
        try require(try Data(contentsOf:original)==bytes && Data(contentsOf:preview.base)==bytes,"Normalization changed the original or captured binary input")
        for normalized in [preview.basePackage,preview.destinationPackage] {
            let package=try PresentationPackage.read(from:normalized,cancellation:.init())
            try require(package.entries["ppt/vbaProject.bin"]==Data([0,255,18,77,0,11]),"Normalization adapter lost opaque VBA bytes")
            try require((try FileManager.default.attributesOfItem(atPath:normalized.path)[.posixPermissions] as? NSNumber)?.intValue==0o444,"Normalized package remained writable")
        }
        let modernFolder=try directory(root),modern=try input(modernFolder)
        let modernPreview=try PresentationComparisonPreview.prepare(try WorkingFileComparison(base:modern,destination:modern).read(),in:root,cancellation:.init());defer{modernPreview.discard()}
        try require(modernPreview.basePackage==modernPreview.base && modernPreview.destinationPackage==modernPreview.destination,"OOXML capture unnecessarily redirected package identity")
        let folder=try directory(root),snapshot=try input(folder),output=folder.appendingPathComponent("result.pdf"),before=try Data(contentsOf:snapshot)
        let manifest=try await PowerPointComparisonAutomation.renderResult(package:snapshot,pdf:output,cancellation:.init(),dependencies:.init(compile:stub,applicationAvailable:{true},execute:{_,event in
            do {
                let args=event.paramDescriptor(forKeyword:0x2d2d2d2d)!
                guard args.numberOfItems==3,args.atIndex(1)?.stringValue==snapshot.path,event.paramDescriptor(forKeyword:0x736e616d)?.stringValue=="renderpresentation" else{return receipt(code:-2700)}
                try pdf(URL(fileURLWithPath:args.atIndex(2)!.stringValue!));return receipt()
            }catch{return failed(error)}
        }))
        try require(manifest.slides.count==2 && manifest.slides[1].text=="hidden slide" && (try Data(contentsOf:snapshot))==before,"Reviewed preview omitted hidden slides or modified its source")
        try require((try FileManager.default.attributesOfItem(atPath:output.path)[.posixPermissions] as? NSNumber)?.intValue==0o444,"Reviewed preview remained writable")
        let legacy=folder.appendingPathComponent("result.ppt")
        try await PowerPointComparisonAutomation.convertLegacyResult(package:snapshot,output:legacy,cancellation:.init(),dependencies:.init(compile:stub,applicationAvailable:{true},execute:{_,event in
            do {guard event.paramDescriptor(forKeyword:0x736e616d)?.stringValue=="convertpresentation" else{return receipt(code:-2700)};try binary(legacy);return receipt()}catch{return failed(error)}
        }))
        try require((try FileManager.default.attributesOfItem(atPath:legacy.path)[.posixPermissions] as? NSNumber)?.intValue==0o444,"Legacy Save As result remained writable")
        // A success receipt does not make missing/malformed outputs successful.
        for mode in 0..<4 {
            let folder=try directory(root),snapshot=try input(folder),output=folder.appendingPathComponent(mode==3 ? "bad.ppt":"bad.pdf")
            do {
                let deps=PowerPointComparisonAutomation.Dependencies(compile:stub,applicationAvailable:{true},execute:{_,_ in
                    do {if mode==1 {try pdf(output,pages:1)};if mode==2 {try Data("not a PDF".utf8).write(to:output)};if mode==3 {try binary(output,valid:false)};return receipt()}catch{return failed(error)}
                })
                if mode==3 {try await PowerPointComparisonAutomation.convertLegacyResult(package:snapshot,output:output,cancellation:.init(),dependencies:deps)}else{_=try await PowerPointComparisonAutomation.renderResult(package:snapshot,pdf:output,cancellation:.init(),dependencies:deps)}
                throw Failure(description:"Missing/malformed output was accepted")
            }catch let failure as PowerPointComparisonAutomation.Failure {try require(!failure.possiblyOpened,"Confirmed closure became an uncertain result")}
        }
        for reply in [receipt(code:-1712,opened:true),receipt(restored:false)] {
            let folder=try directory(root),snapshot=try input(folder)
            do {_=try await PowerPointComparisonAutomation.renderResult(package:snapshot,pdf:folder.appendingPathComponent("uncertain.pdf"),cancellation:.init(),dependencies:.init(compile:stub,applicationAvailable:{true},execute:{_,_ in reply}));throw Failure(description:"Uncertain output was accepted")}
            catch let failure as PowerPointComparisonAutomation.Failure {try require(failure.possiblyOpened && FileManager.default.fileExists(atPath:snapshot.path),"Uncertain receipt discarded owned inputs")}
        }
        let cancelled=OperationCancellation();cancelled.cancel()
        do {_=try await PowerPointComparisonAutomation.renderResult(package:snapshot,pdf:folder.appendingPathComponent("cancelled.pdf"),cancellation:cancelled,dependencies:.init(compile:stub,applicationAvailable:{preconditionFailure("Cancelled job checked Office")},execute:{_,_ in preconditionFailure("Cancelled job dispatched Office")}));throw Failure(description:"Cancelled render succeeded")}
        catch OperationCancellationFailure.cancelled {}
        let pendingFolder=try directory(root),pending=try input(pendingFolder),token=OperationCancellation()
        do {
            _=try await PowerPointComparisonAutomation.renderResult(package:pending,pdf:pendingFolder.appendingPathComponent("cancel.pdf"),cancellation:token,dependencies:.init(compile:stub,applicationAvailable:{true},execute:{_,event in
                DispatchQueue.main.async{token.cancel()}
                let marker=event.paramDescriptor(forKeyword:0x2d2d2d2d)?.atIndex(3)?.stringValue ?? "",deadline=ProcessInfo.processInfo.systemUptime+3
                while !FileManager.default.fileExists(atPath:marker),ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.005)}
                return receipt(code:-128)
            }))
            throw Failure(description:"In-flight cancelled render returned success")
        }catch let failure as PowerPointComparisonAutomation.Failure {try require(!failure.possiblyOpened,"Drained cancelled render lost confirmed closure")}
        try require((try FileManager.default.contentsOfDirectory(atPath:pendingFolder.path)).contains(where:{$0.hasSuffix(".cancel")}),"Cancellation marker was not delivered while draining")
        let missingNormalization=try PresentationComparisonPreview.prepare(document,in:root,cancellation:.init());defer{missingNormalization.discard()}
        do {
            _=try await PowerPointComparisonAutomation.export(missingNormalization,cancellation:.init(),dependencies:.init(compile:stub,applicationAvailable:{true},execute:{_,_ in
                do {try pdf(missingNormalization.basePDF);try pdf(missingNormalization.destinationPDF);return receipt(both:true)}catch{return failed(error)}
            }))
            throw Failure(description:"A binary normalization receipt without normalized packages was accepted")
        }catch let failure as PowerPointComparisonAutomation.Failure {try require(!failure.possiblyOpened,"Confirmed missing normalization lost closure certainty")}
        let linkedFolder=try directory(root),linkedInput=try input(linkedFolder),hardlink=linkedFolder.appendingPathComponent("alias.pptm")
        try FileManager.default.linkItem(at:linkedInput,to:hardlink)
        do {_=try await PowerPointComparisonAutomation.renderResult(package:linkedInput,pdf:linkedFolder.appendingPathComponent("linked.pdf"),cancellation:.init(),dependencies:.init(compile:stub,applicationAvailable:{true},execute:{_,_ in preconditionFailure("Hard-linked snapshot reached Office")}));throw Failure(description:"Hard-linked snapshot was accepted")}
        catch let failure as PowerPointComparisonAutomation.Failure {try require(!failure.possiblyOpened,"Predispatch alias refusal lost closure certainty")}
        let changedFolder=try directory(root),changed=try input(changedFolder)
        do {_=try await PowerPointComparisonAutomation.renderResult(package:changed,pdf:changedFolder.appendingPathComponent("changed.pdf"),cancellation:.init(),dependencies:.init(compile:stub,applicationAvailable:{true},execute:{_,_ in
            do {try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:changed.path);try Data([0,1,2,3]).write(to:changed);try FileManager.default.setAttributes([.posixPermissions:0o444],ofItemAtPath:changed.path);return receipt()}catch{return failed(error)}
        }));throw Failure(description:"Changed immutable snapshot was accepted")}
        catch let failure as PowerPointComparisonAutomation.Failure {try require(failure.possiblyOpened,"Changed input lost conservative ownership retention")}
        let existing=folder.appendingPathComponent("existing.pdf");try Data([1]).write(to:existing)
        do {_=try await PowerPointComparisonAutomation.renderResult(package:snapshot,pdf:existing,cancellation:.init(),dependencies:.init(compile:stub,applicationAvailable:{true},execute:{_,_ in preconditionFailure("Pre-existing output reached Office")}));throw Failure(description:"Existing output was overwritten")}
        catch let failure as PowerPointComparisonAutomation.Failure {try require(!failure.possiblyOpened,"Predispatch refusal reported opened inputs")}
    }
}
