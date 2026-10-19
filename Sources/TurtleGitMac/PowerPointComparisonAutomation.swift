// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import CryptoKit
import Darwin
import TurtleGitCore

/// Mac PowerPoint exposes no presentation Compare command. Export only captured
/// private inputs; no command uses the active presentation or quits the app.
enum PowerPointComparisonAutomation {
    static let bundleIdentifier = "com.microsoft.Powerpoint"
    enum Failure: LocalizedError {
        case application
        case automation(Int,String,possiblyOpened:Bool)
        var possiblyOpened:Bool {if case .automation(_,_,let value)=self{return value};return false}
        var errorDescription:String? {
            switch self {
            case .application:return "Microsoft PowerPoint is required to export this presentation comparison."
            case .automation(let code,let message,_):
                if code == -1743 {return "Allow TurtleGit to control Microsoft PowerPoint in macOS System Settings → Privacy & Security → Automation, then retry."}
                return "PowerPoint could not confirm the private presentation export (\(code)): " + message
            }
        }
    }
    struct ExecutionReply {let result:NSAppleEventDescriptor?;let error:NSDictionary?}
    struct Dependencies {
        var compile:()throws->NSAppleScript = {try PowerPointComparisonAutomation.compile()}
        var applicationAvailable:@MainActor ()->Bool = {NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundleIdentifier) != nil}
        var execute:(NSAppleScript,NSAppleEventDescriptor)->ExecutionReply = {script,event in
            var error:NSDictionary?;let result=script.executeAppleEvent(event,error:&error)
            return .init(result:result,error:error)
        }
    }
    private static let queue=DispatchQueue(label:"org.turtlegit.powerpoint-export")
    /// The installed dictionary inherits standard open/save/close, not Windows'
    /// ReadOnly/WithWindow Open parameters. Read-only private files and exact
    /// full-name checks provide ownership. Only their windows are hidden.
    static let source="""
    property remainingShapes : 20000
    property remainingCharacters : 16777216
    on checkCancellation(markerPath, started)
        set markerFound to false
        try
            info for (POSIX file markerPath)
            set markerFound to true
        on error errorMessage number errorNumber
            if errorNumber is not -43 and errorNumber is not -37 then error errorMessage number errorNumber
        end try
        if markerFound then error "Presentation export cancelled." number -128
        if (current date) - started > 180 then error "Presentation export timed out." number -1712
    end checkCancellation
    on joinText(pieces)
        set oldDelimiters to AppleScript's text item delimiters
        try
            set AppleScript's text item delimiters to linefeed
            set resultText to pieces as text
            set AppleScript's text item delimiters to oldDelimiters
            return resultText
        on error errorMessage number errorNumber
            set AppleScript's text item delimiters to oldDelimiters
            error errorMessage number errorNumber
        end try
    end joinText
    on shapeText(theShape, depth, markerPath, started)
        my checkCancellation(markerPath, started)
        if depth > 16 or remainingShapes < 1 then error "Presentation shape limit exceeded." number -2700
        set remainingShapes to remainingShapes - 1
        set pieces to {}
        tell application id "com.microsoft.Powerpoint"
            if has text frame of theShape then
                set theFrame to text frame of theShape
                if has text of theFrame then
                    set literalText to content of text range of theFrame
                    set remainingCharacters to remainingCharacters - (length of literalText)
                    if remainingCharacters < 0 then error "Presentation text limit exceeded." number -2700
                    set end of pieces to literalText
                end if
            end if
            if shape type of theShape is shape type group then
                repeat with childShape in (every shape of theShape)
                    set end of pieces to my shapeText(childShape, depth + 1, markerPath, started)
                end repeat
            else if has table of theShape then
                set theTable to table object of theShape
                set rowCount to count of rows of theTable
                set columnCount to count of columns of theTable
                if rowCount * columnCount > remainingShapes then error "Presentation table limit exceeded." number -2700
                repeat with rowNumber from 1 to rowCount
                    repeat with columnNumber from 1 to columnCount
                        set theCell to get cell from theTable row rowNumber column columnNumber
                        set end of pieces to my shapeText(shape of theCell, depth + 1, markerPath, started)
                    end repeat
                end repeat
            end if
        end tell
        return my joinText(pieces)
    end shapeText
    on slideText(theSlide, markerPath, started)
        set pieces to {}
        tell application id "com.microsoft.Powerpoint"
            repeat with theShape in every shape of theSlide
                set end of pieces to my shapeText(theShape, 0, markerPath, started)
            end repeat
        end tell
        return my joinText(pieces)
    end slideText
    on ownedName(thePresentation, inputPath, outputPath)
        tell application id "com.microsoft.Powerpoint" to set actualName to full name of thePresentation
        considering case
            considering diacriticals
                return actualName is inputPath or actualName is ((POSIX file inputPath) as text) or actualName is outputPath or actualName is ((POSIX file outputPath) as text)
            end considering
        end considering
    end ownedName
    on exportOne(inputPath, outputPath, markerPath, started)
        set openedPresentation to missing value
        set attemptedOpen to false
        try
            my checkCancellation(markerPath, started)
            tell application id "com.microsoft.Powerpoint"
                repeat with existingPresentation in every presentation
                    if my ownedName(existingPresentation, inputPath, outputPath) then
                        set attemptedOpen to true
                        error "Private presentation is already open; ownership was not acquired." number -2700
                    end if
                end repeat
                set attemptedOpen to true
                open (POSIX file inputPath)
                repeat with candidate in every presentation
                    if my ownedName(candidate, inputPath, inputPath) then
                        if openedPresentation is not missing value then
                            set openedPresentation to missing value
                            error "Private presentation ownership is ambiguous." number -2700
                        end if
                        set openedPresentation to contents of candidate
                    end if
                end repeat
                if openedPresentation is missing value then error "PowerPoint did not identify the private presentation." number -2700
                repeat with ownedWindow in every document window of openedPresentation
                    set visible of ownedWindow to false
                end repeat
                if not (read only of openedPresentation) then error "PowerPoint did not open the immutable presentation read-only." number -2700
                set slideCount to count of slides of openedPresentation
                if slideCount > 512 then error "Presentation slide limit exceeded." number -2700
                set rows to {}
                repeat with slideNumber from 1 to slideCount
                    my checkCancellation(markerPath, started)
                    set theSlide to slide slideNumber of openedPresentation
                    set literalText to my slideText(theSlide, markerPath, started)
                    set literalNotes to my slideText(notes page of theSlide, markerPath, started)
                    set end of rows to {slideNumber - 1, (slide ID of theSlide) as text, literalText, literalNotes}
                end repeat
                set print hidden slides of print options of openedPresentation to true
                set range type of print options of openedPresentation to print range all
                set output type of print options of openedPresentation to print slides
                set print color type of print options of openedPresentation to print color
                my checkCancellation(markerPath, started)
                if not (my ownedName(openedPresentation, inputPath, outputPath)) then error "Private presentation ownership changed." number -2700
                save openedPresentation in (POSIX file outputPath) as save as PDF
                my checkCancellation(markerPath, started)
                if not (my ownedName(openedPresentation, inputPath, outputPath)) then error "Private presentation ownership changed after export." number -2700
                close openedPresentation saving no
                set openedPresentation to missing value
            end tell
            return {0, "", false, rows}
        on error errorMessage number errorNumber
            set uncertainOwnership to attemptedOpen
            if openedPresentation is not missing value then
                try
                    if my ownedName(openedPresentation, inputPath, outputPath) then
                        tell application id "com.microsoft.Powerpoint" to close openedPresentation saving no
                        set uncertainOwnership to false
                    end if
                end try
            end if
            return {errorNumber, errorMessage, uncertainOwnership, {}}
        end try
    end exportOne
    on exportPresentations(basePath, newPath, basePDF, newPDF, markerPath)
        set previousSecurity to missing value
        set possiblyOpened to false
        set remainingShapes to 20000
        set remainingCharacters to 16777216
        set started to current date
        with timeout of 20 seconds
            try
                my checkCancellation(markerPath, started)
                tell application id "com.microsoft.Powerpoint"
                    set previousSecurity to automation security
                    set automation security to msoAutomationSecurityForceDisable
                    if automation security is not msoAutomationSecurityForceDisable then error "PowerPoint did not disable automation macros." number -2700
                end tell
                set baseResult to my exportOne(basePath, basePDF, markerPath, started)
                set possiblyOpened to item 3 of baseResult
                if item 1 of baseResult is not 0 then error (item 2 of baseResult) number (item 1 of baseResult)
                set newResult to my exportOne(newPath, newPDF, markerPath, started)
                set possiblyOpened to item 3 of newResult
                if item 1 of newResult is not 0 then error (item 2 of newResult) number (item 1 of newResult)
                tell application id "com.microsoft.Powerpoint"
                    set automation security to previousSecurity
                    if automation security is not previousSecurity then error "PowerPoint did not restore automation security." number -2700
                end tell
                set previousSecurity to missing value
                return {0, "", false, true, item 4 of baseResult, item 4 of newResult}
            on error errorMessage number errorNumber
                set securityRestored to previousSecurity is missing value
                if previousSecurity is not missing value then
                    try
                        tell application id "com.microsoft.Powerpoint"
                            set automation security to previousSecurity
                            set securityRestored to automation security is previousSecurity
                        end tell
                    end try
                end if
                return {errorNumber, errorMessage, possiblyOpened, securityRestored, {}, {}}
            end try
        end timeout
    end exportPresentations
    """
    static func compile()throws->NSAppleScript {
        guard let script=NSAppleScript(source:source) else{throw Failure.automation(-1,"AppleScript is unavailable.",possiblyOpened:false)}
        var error:NSDictionary?
        guard script.compileAndReturnError(&error) else{throw Failure.automation((error?[NSAppleScript.errorNumber] as? Int) ?? -1,(error?[NSAppleScript.errorMessage] as? String) ?? "Could not compile the PowerPoint exporter.",possiblyOpened:false)}
        return script
    }
    static func event(_ preview:PresentationComparisonPreview,cancellationFile:URL)->NSAppleEventDescriptor {
        let arguments=NSAppleEventDescriptor.list()
        for (index,path) in [preview.base.path,preview.destination.path,preview.basePDF.path,preview.destinationPDF.path,cancellationFile.path].enumerated(){arguments.insert(NSAppleEventDescriptor(string:path),at:index+1)}
        let event=NSAppleEventDescriptor(eventClass:0x61736372,eventID:0x70736272,targetDescriptor:nil,returnID:-1,transactionID:0)
        event.setParam(NSAppleEventDescriptor(string:"exportpresentations"),forKeyword:0x736e616d)
        event.setParam(arguments,forKeyword:0x2d2d2d2d);return event
    }
    static func decode(_ reply:ExecutionReply,cancellation:OperationCancellation)throws->PresentationComparisonManifest {
        if let error=reply.error {
            let code=(error[NSAppleScript.errorNumber] as? Int) ?? -1
            throw Failure.automation(code,(error[NSAppleScript.errorMessage] as? String) ?? "PowerPoint did not confirm cleanup.",possiblyOpened:code != -1743)
        }
        guard let value=reply.result,value.numberOfItems==6,let codeValue=value.atIndex(1),codeValue.descriptorType==typeSInt32,
              let message=value.atIndex(2)?.stringValue,let opened=value.atIndex(3),opened.descriptorType==typeBoolean,
              let restored=value.atIndex(4),restored.descriptorType==typeBoolean else{throw Failure.automation(-1,"Incomplete export or cleanup receipt.",possiblyOpened:true)}
        let code=Int(codeValue.int32Value)
        guard code==0,restored.booleanValue,!opened.booleanValue else {
            let uncertainty = !restored.booleanValue ? "Macro-security restoration was not confirmed. " : opened.booleanValue ? "Private presentation closure was not confirmed. " : ""
            throw Failure.automation(code==0 ? -1:code,uncertainty + (message.isEmpty ? "The export did not complete.":message),possiblyOpened:opened.booleanValue || !restored.booleanValue)
        }
        var metadataBytes=0
        func literal(_ descriptor:NSAppleEventDescriptor?)->String? {
            guard let descriptor,[typeUnicodeText,typeUTF8Text,typeChar].contains(descriptor.descriptorType) else{return nil}
            return descriptor.stringValue
        }
        func side(_ descriptor:NSAppleEventDescriptor?)throws->PresentationSlideManifest {
            guard let descriptor,descriptor.descriptorType==typeAEList,descriptor.numberOfItems<=512 else{throw PresentationComparisonFailure.manifest}
            var slides:[PresentationSlide]=[]
            for index in 0..<descriptor.numberOfItems {
                try cancellation.check()
                guard let row=descriptor.atIndex(index+1),row.descriptorType==typeAEList,row.numberOfItems==4,
                      let page=row.atIndex(1),page.descriptorType==typeSInt32,Int(page.int32Value)==index,
                      let id=literal(row.atIndex(2)),let text=literal(row.atIndex(3)),let notes=literal(row.atIndex(4)) else{throw PresentationComparisonFailure.manifest}
                guard text.utf8.count<=67_108_864-metadataBytes else{throw PresentationComparisonFailure.budget};metadataBytes+=text.utf8.count
                guard notes.utf8.count<=67_108_864-metadataBytes else{throw PresentationComparisonFailure.budget};metadataBytes+=notes.utf8.count
                slides.append(.init(pageIndex:index,stableID:id,text:text,notes:notes))
            }
            let manifest=PresentationSlideManifest(slides:slides);try manifest.validate(cancellation:cancellation);return manifest
        }
        return try .init(base:side(value.atIndex(5)),destination:side(value.atIndex(6)))
    }
    private static func cleanupConfirmed(_ reply:ExecutionReply)->Bool {
        if let error=reply.error {return (error[NSAppleScript.errorNumber] as? Int) == -1743}
        guard let value=reply.result,value.numberOfItems==6,
              let opened=value.atIndex(3),opened.descriptorType==typeBoolean,
              let restored=value.atIndex(4),restored.descriptorType==typeBoolean else{return false}
        return !opened.booleanValue && restored.booleanValue
    }
    private static func validatePDF(_ url:URL)throws {
        let fd=open(url.path,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC)
        guard fd>=0 else{throw PresentationComparisonFailure.manifest}
        let file=FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer{try? file.close()}
        var info=stat()
        guard fstat(fd,&info)==0,(info.st_mode&S_IFMT)==S_IFREG,info.st_nlink==1,info.st_size>=8,info.st_size<=134_217_728,
              try file.read(upToCount:5)==Data("%PDF-".utf8) else{throw PresentationComparisonFailure.manifest}
        guard fchmod(fd,0o444)==0 else{throw PresentationComparisonFailure.manifest}
    }
    private struct InputWitness:Equatable {let device:dev_t,inode:ino_t,size:off_t,digest:Data}
    private static func witness(_ url:URL,cancellation:OperationCancellation)throws->InputWitness {
        let fd=open(url.path,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC)
        guard fd>=0 else{throw PresentationComparisonFailure.absent}
        let file=FileHandle(fileDescriptor:fd,closeOnDealloc:true);defer{try? file.close()}
        var info=stat();guard fstat(fd,&info)==0,(info.st_mode&S_IFMT)==S_IFREG,info.st_mode&0o222==0,info.st_size>=0,info.st_size<=1_073_741_824 else{throw PresentationComparisonFailure.budget}
        var digest=SHA256(),bytes=0
        while let chunk=try file.read(upToCount:262144),!chunk.isEmpty {try cancellation.check();bytes+=chunk.count;guard bytes<=1_073_741_824 else{throw PresentationComparisonFailure.budget};digest.update(data:chunk)}
        guard bytes==info.st_size else{throw PresentationComparisonFailure.manifest}
        return .init(device:info.st_dev,inode:info.st_ino,size:info.st_size,digest:Data(digest.finalize()))
    }
    private final class Job:@unchecked Sendable {
        private let lock=NSLock()
        private var value:Result<PresentationComparisonManifest,Error>?
        func finish(_ result:Result<PresentationComparisonManifest,Error>){lock.lock();value=result;lock.unlock()}
        func result()->Result<PresentationComparisonManifest,Error>? {lock.lock();defer{lock.unlock()};return value}
    }
    @MainActor static func export(_ preview:PresentationComparisonPreview,cancellation:OperationCancellation,dependencies:Dependencies = .init())async throws->PresentationComparisonManifest {
        try cancellation.check();guard dependencies.applicationAvailable() else{throw Failure.application}
        let marker=preview.directory.appendingPathComponent("automation.cancel"),job=Job()
        queue.async {
            var dispatched=false,cleaned=false
            do {
                try cancellation.check()
                let before=try [preview.base,preview.destination].map{try witness($0,cancellation:cancellation)}
                for output in [preview.basePDF,preview.destinationPDF,preview.baseManifest,preview.destinationManifest,marker] {
                    var info=stat();guard lstat(output.path,&info) != 0,errno==ENOENT else{throw PresentationComparisonFailure.manifest}
                }
                let script=try dependencies.compile();try cancellation.check()
                dispatched=true
                let reply=dependencies.execute(script,event(preview,cancellationFile:marker))
                cleaned=cleanupConfirmed(reply)
                let result=try decode(reply,cancellation:cancellation)
                guard before == (try [preview.base,preview.destination].map{try witness($0,cancellation:cancellation)}) else{throw Failure.automation(-1,"Private presentation bytes changed during export.",possiblyOpened:true)}
                try validatePDF(preview.basePDF);try validatePDF(preview.destinationPDF)
                try result.base.write(to:preview.baseManifest,cancellation:cancellation)
                try result.destination.write(to:preview.destinationManifest,cancellation:cancellation)
                for output in [preview.baseManifest,preview.destinationManifest] {try FileManager.default.setAttributes([.posixPermissions:0o444],ofItemAtPath:output.path)}
                job.finish(.success(result))
            }catch{
                if let failure=error as? Failure {job.finish(.failure(failure))}
                else {job.finish(.failure(Failure.automation(error is OperationCancellationFailure || error is CancellationError ? -128:-1,error.localizedDescription,possiblyOpened:dispatched && !cleaned)))}
            }
        }
        let began=ProcessInfo.processInfo.systemUptime
        var markerWritten=false
        while job.result()==nil {
            if cancellation.isCancelled || Task.isCancelled || ProcessInfo.processInfo.systemUptime-began>=180 {
                if !markerWritten {try? Data().write(to:marker,options:.withoutOverwriting);markerWritten=true}
            }
            // Keep draining the serialized event and its exact-document cleanup.
            await withCheckedContinuation {continuation in DispatchQueue.main.asyncAfter(deadline:.now()+0.05){continuation.resume()}}
        }
        let result=try job.result()!.get()
        if cancellation.isCancelled || Task.isCancelled {throw Failure.automation(-128,"Operation cancelled.",possiblyOpened:false)}
        return result
    }
}
