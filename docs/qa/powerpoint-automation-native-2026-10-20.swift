// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum PowerPointAutomationVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    nonisolated static func list(_ values:[NSAppleEventDescriptor])->NSAppleEventDescriptor {
        let result=NSAppleEventDescriptor.list();for (index,value) in values.enumerated(){result.insert(value,at:index+1)};return result
    }
    nonisolated static func row(_ page:Int,_ id:String,_ text:String,_ notes:String)->NSAppleEventDescriptor {
        list([.init(int32:Int32(page)),.init(string:id),.init(string:text),.init(string:notes)])
    }
    nonisolated static func receipt(code:Int32=0,opened:Bool=false,restored:Bool=true,base:[NSAppleEventDescriptor]=[],new:[NSAppleEventDescriptor]=[])->PowerPointComparisonAutomation.ExecutionReply {
        .init(result:list([.init(int32:code),.init(string:code==0 ? "":"Injected Office failure"),.init(boolean:opened),.init(boolean:restored),list(base),list(new)]),error:nil)
    }
    nonisolated static func pdf(_ url:URL)throws {
        let data=NSMutableData();var bounds=CGRect(x:0,y:0,width:96,height:64);guard let consumer=CGDataConsumer(data:data as CFMutableData),let context=CGContext(consumer:consumer,mediaBox:&bounds,nil) else{throw Failure(description:"Cannot create private PDF fixture")}
        context.beginPDFPage(nil)
        context.setFillColor(red:0.1,green:0.3,blue:0.8,alpha:1);context.fill(.init(x:5,y:5,width:50,height:40));context.endPDFPage();context.closePDF()
        try (data as Data).write(to:url,options:.withoutOverwriting)
    }
    static func prepare(_ root:URL)throws->PresentationComparisonPreview {
        let source=root.appendingPathComponent("PowerPointInputs-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer {try? FileManager.default.removeItem(at:source)}
        let name="'雪\n.pptm",base=source.appendingPathComponent("old",isDirectory:true),new=source.appendingPathComponent("new",isDirectory:true)
        for folder in [base,new] {try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}
        let a=base.appendingPathComponent(name),b=new.appendingPathComponent(name)
        let oldBytes=Data([0,255,10,13]),newBytes=Data([1,254,13,10])
        try oldBytes.write(to:a,options:.withoutOverwriting);try newBytes.write(to:b,options:.withoutOverwriting)
        let document=try WorkingFileComparison(base:a,destination:b).read()
        let preview=try PresentationComparisonPreview.prepare(document,in:root,cancellation:.init())
        do {
            try require(preview.base.lastPathComponent==name && preview.destination.lastPathComponent==name,"Private capture changed literal presentation filenames")
            let capturedOld=try Data(contentsOf:preview.base),capturedNew=try Data(contentsOf:preview.destination)
            try require(capturedOld==oldBytes && capturedNew==newBytes,"Private capture changed presentation bytes")
            return preview
        } catch {preview.discard();throw error}
    }
    nonisolated static func stub()throws->NSAppleScript {
        guard let script=NSAppleScript(source:"on run\nreturn 0\nend run") else{throw Failure(description:"Cannot create injected script")}
        var error:NSDictionary?
        guard script.compileAndReturnError(&error) else{throw Failure(description:"Cannot compile injected script")}
        return script
    }
    static func verify(root:URL)async throws {
        // Compilation uses the installed scripting dictionary only. Every
        // execution below is injected; no live Office application is opened.
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier:PowerPointComparisonAutomation.bundleIdentifier) != nil {
            _=try PowerPointComparisonAutomation.compile()
            print("PowerPoint terminology compilation available and checked")
        } else {
            print("PowerPoint terminology compilation unavailable: application is not installed")
        }
        let originalSource=PowerPointComparisonAutomation.source
        try require(!originalSource.contains("active presentation") && !originalSource.contains("activate") && !originalSource.contains("quit") && !originalSource.contains("do shell script"),"Exporter must not target user focus, terminate Office or evaluate shell text")
        // An earlier uncertain invocation must retain the file Office may
        // still own; this exercises the receipt contract independently.
        do {_=try PowerPointComparisonAutomation.decode(receipt(code:-2700,opened:true),cancellation:.init());throw Failure(description:"Already-open refusal was accepted")}
        catch let failure as PowerPointComparisonAutomation.Failure {try require(failure.possiblyOpened,"Already-open refusal must retain the file used by Office")}
        let literal="quote \" tab\t newline\n NFD e\u{301} 😀",notes="speaker\r\nnotes ' \\"
        let success=receipt(base:[row(0,"256",literal,notes)],new:[row(0,"257","new","")])
        let decoded=try PowerPointComparisonAutomation.decode(success,cancellation:.init())
        try require(Data(decoded.base.slides[0].text.utf8)==Data(literal.utf8) && Data(decoded.base.slides[0].notes.utf8)==Data(notes.utf8),"Apple-event strings lost literal slide or notes bytes")
        for failed in [receipt(code:-128,opened:false),receipt(code:-1712,opened:true),receipt(restored:false),.init(result:list([]),error:nil)] {
            do {_=try PowerPointComparisonAutomation.decode(failed,cancellation:.init());throw Failure(description:"Unconfirmed export was accepted")}
            catch is PowerPointComparisonAutomation.Failure {}
        }
        let duplicates=receipt(base:[row(0,"256","a",""),row(1,"256","b","")])
        do {_=try PowerPointComparisonAutomation.decode(duplicates,cancellation:.init());throw Failure(description:"Duplicate slide identity was accepted")}
        catch PresentationComparisonFailure.manifest {}
        let wrongOrder=receipt(base:[row(1,"256","a","")])
        do {_=try PowerPointComparisonAutomation.decode(wrongOrder,cancellation:.init());throw Failure(description:"Noncontiguous page mapping was accepted")}
        catch PresentationComparisonFailure.manifest {}
        let spoofed=list([.init(int32:0),.init(string:"256"),.init(int32:123),.init(string:"")])
        do {_=try PowerPointComparisonAutomation.decode(receipt(base:[spoofed]),cancellation:.init());throw Failure(description:"Nonliteral slide text was coerced")}
        catch PresentationComparisonFailure.manifest {}
        let preview=try prepare(root);defer{preview.discard()}
        let before=try [preview.base,preview.destination].map{try Data(contentsOf:$0)}
        let event=PowerPointComparisonAutomation.event(preview,cancellationFile:preview.directory.appendingPathComponent("automation.cancel"))
        let arguments=event.paramDescriptor(forKeyword:0x2d2d2d2d)
        try require(arguments?.numberOfItems==7 && arguments?.atIndex(1)?.stringValue==preview.base.path && arguments?.atIndex(2)?.stringValue==preview.destination.path && arguments?.atIndex(3)?.stringValue==preview.basePDF.path,"Private paths must be event arguments, never script substitutions")
        let result=try await PowerPointComparisonAutomation.export(preview,cancellation:.init(),dependencies:.init(compile:stub,applicationAvailable:{true},execute:{_,_ in
            do {try pdf(preview.basePDF);try pdf(preview.destinationPDF);return success}
            catch {return .init(result:nil,error:[NSAppleScript.errorNumber:-1,NSAppleScript.errorMessage:"Injected private PDF failed"])}
        }))
        let read=try PresentationSlideManifest.read(from:preview.baseManifest,cancellation:.init())
        try require(result.base.slides==read.slides && result.base.slides[0].text==literal,"Bounded literal manifest publication failed")
        try require(before == (try [preview.base,preview.destination].map{try Data(contentsOf:$0)}),"Automation modified private immutable inputs")
        for output in [preview.basePDF,preview.destinationPDF,preview.baseManifest,preview.destinationManifest] {
            let mode=(try FileManager.default.attributesOfItem(atPath:output.path)[.posixPermissions] as? NSNumber)?.intValue
            try require(mode==0o444,"Completed export artifacts must be immutable")
        }
        let cancelled=try prepare(root);defer{cancelled.discard()};let cancellation=OperationCancellation();cancellation.cancel()
        do {_=try await PowerPointComparisonAutomation.export(cancelled,cancellation:cancellation,dependencies:.init(compile:stub,applicationAvailable:{throwUnexpectedLaunch();return false},execute:{_,_ in throwUnexpectedLaunch();return success}));throw Failure(description:"Cancelled operation dispatched automation")}
        catch OperationCancellationFailure.cancelled {}
        let inFlight=try prepare(root);defer{inFlight.discard()};let runningCancellation=OperationCancellation()
        do {
            _=try await PowerPointComparisonAutomation.export(inFlight,cancellation:runningCancellation,dependencies:.init(compile:stub,applicationAvailable:{true},execute:{_,event in
                DispatchQueue.main.async {runningCancellation.cancel()}
                let marker=event.paramDescriptor(forKeyword:0x2d2d2d2d)?.atIndex(5)?.stringValue ?? ""
                let deadline=ProcessInfo.processInfo.systemUptime+3
                while !FileManager.default.fileExists(atPath:marker),ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.005)}
                return receipt(code:-128,opened:false,restored:true)
            }))
            throw Failure(description:"In-flight cancelled export returned success")
        } catch let failure as PowerPointComparisonAutomation.Failure {
            try require(!failure.possiblyOpened,"Confirmed cancellation cleanup must allow capture retirement")
        }
        try require(FileManager.default.fileExists(atPath:inFlight.directory.appendingPathComponent("automation.cancel").path),"Cooperative cancellation was not delivered while the owned event drained")
        let uncertain=try prepare(root);defer{uncertain.discard()}
        do {_=try await PowerPointComparisonAutomation.export(uncertain,cancellation:.init(),dependencies:.init(compile:stub,applicationAvailable:{true},execute:{_,_ in receipt(code:-1712,opened:true)}));throw Failure(description:"Ambiguous cleanup was treated as success")}
        catch let failure as PowerPointComparisonAutomation.Failure {try require(failure.possiblyOpened,"Ambiguous ownership must retain captures")}
        try require(FileManager.default.fileExists(atPath:uncertain.base.path),"Adapter discarded an uncertain presentation")
    }
    nonisolated private static func throwUnexpectedLaunch(){preconditionFailure("Cancelled private export unexpectedly reached Office")}
}
