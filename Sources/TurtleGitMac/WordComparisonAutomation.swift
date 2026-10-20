// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// Only fixed script syntax is compiled. Paths arrive as Apple-event arguments,
/// never as source text or shell commands. A private input cannot alias a user's
/// existing Word document, so cleanup closes only the input opened by this call.
enum WordComparisonAutomation {
    struct ExecutionReply { let result:NSAppleEventDescriptor?; let error:NSDictionary? }
    struct Dependencies {
        var compile:(Bool)throws->NSAppleScript = {try WordComparisonAutomation.compile(merging:$0)}
        var applicationAvailable:@MainActor ()->Bool = {NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.microsoft.Word") != nil}
        var execute:(NSAppleScript,NSAppleEventDescriptor)->ExecutionReply = {script,event in
            var error:NSDictionary?
            let result=script.executeAppleEvent(event,error:&error)
            return .init(result:result,error:error)
        }
    }
    private static let queue = DispatchQueue(label:"org.turtlegit.word-comparison")
    // Paths are literal event arguments. Only exact private inputs are closed;
    // generated review documents are retained, including uncertain completions.
    private static let helpers = """
    on checkCancellation(markerPath, started)
        set markerFound to false
        try
            info for (POSIX file markerPath)
            set markerFound to true
        on error errorMessage number errorNumber
            if errorNumber is not -43 and errorNumber is not -37 then error errorMessage number errorNumber
        end try
        if markerFound then error "Word operation cancelled." number -128
        if (current date) - started > 180 then error "Word operation timed out." number -1712
    end checkCancellation
    on ownedName(theDocument, inputPath)
        tell application id "com.microsoft.Word" to set actualName to full name of theDocument
        considering case
            considering diacriticals
                return actualName is inputPath or actualName is ((POSIX file inputPath) as text)
            end considering
        end considering
    end ownedName
    on openOwned(inputPath, immutable)
        tell application id "com.microsoft.Word"
            repeat with candidate in every document
                if my ownedName(candidate, inputPath) then error "Private Word input is already open; ownership was not acquired." number -2700
            end repeat
            -- Preflight above proves this private path was not already open.
            set theDocument to missing value
            try
                set theDocument to open (POSIX file inputPath) read only immutable add to recent files false
                if not (my ownedName(theDocument, inputPath)) then error "Word did not identify the private input." number -2700
                return theDocument
            on error errorMessage number errorNumber
                -- Open can create a document before returning an error. Recover
                -- only one exact private-path match, never the active document.
                try
                    if theDocument is missing value then
                        set recoveredDocuments to {}
                        repeat with candidate in every document
                            if my ownedName(candidate, inputPath) then set end of recoveredDocuments to contents of candidate
                        end repeat
                        if (count of recoveredDocuments) is 1 then set theDocument to item 1 of recoveredDocuments
                    end if
                    my closeOwned(theDocument, inputPath)
                end try
                error errorMessage number errorNumber
            end try
        end tell
    end openOwned
    on closeOwned(theDocument, inputPath)
        if theDocument is missing value then return true
        try
            if not (my ownedName(theDocument, inputPath)) then return false
            tell application id "com.microsoft.Word" to close theDocument saving no
            return true
        end try
        return false
    end closeOwned
    on restoreSecurity(previousSecurity)
        if previousSecurity is missing value then return true
        try
            tell application id "com.microsoft.Word"
                set automation security to previousSecurity
                return automation security is previousSecurity
            end tell
        end try
        return false
    end restoreSecurity
    """
    static let source = helpers + """

    on compareDocuments(basePath, newPath, markerPath)
        set openedDocument to missing value
        set previousSecurity to missing value
        set possiblyOpened to false
        set resultIdentified to false
        set comparisonStarted to false
        set started to current date
        with timeout of 20 seconds
            try
                my checkCancellation(markerPath, started)
                tell application id "com.microsoft.Word"
                    set previousSecurity to automation security
                    set automation security to msoAutomationSecurityForceDisable
                    if automation security is not msoAutomationSecurityForceDisable then error "Word did not disable automation macros." number -2700
                end tell
                my checkCancellation(markerPath, started)
                set possiblyOpened to true
                set openedDocument to my openOwned(basePath, true)
                tell application id "com.microsoft.Word"
                    set inputView to view of active window of openedDocument
                    set inputViewType to view type of inputView
                    if inputViewType is outline view or ((inputViewType is master view or inputViewType is reading view) and (count of subdocuments of openedDocument) is 0) then set view type of inputView to normal view
                    set previousWindows to id of every window
                    set previousDocumentNames to full name of every document
                end tell
                my checkCancellation(markerPath, started)
                tell application id "com.microsoft.Word"
                    set comparisonStarted to true
                    compare openedDocument path newPath author name "Comparison" target compare target new detect format changes true ignore all comparison warnings true add to recent files false
                    set resultWindows to {}
                    repeat with candidate in every window
                        if (id of candidate) is not in previousWindows then set end of resultWindows to id of candidate
                    end repeat
                    if (count of resultWindows) is not 1 then error "Word comparison result identity is ambiguous; review documents were retained." number -2700
                    set resultWindowID to item 1 of resultWindows
                    set resultDocument to document of window id resultWindowID
                    if my ownedName(resultDocument, basePath) or my ownedName(resultDocument, newPath) then error "Word did not create a separate comparison result." number -2700
                    if (full name of resultDocument) is in previousDocumentNames then error "The new window belongs to a pre-existing document; its saved state was not changed." number -2700
                    set resultIdentified to true
                    set saved of resultDocument to true
                end tell
                my checkCancellation(markerPath, started)
                if not (my closeOwned(openedDocument, basePath)) then error "Word private input closure was not confirmed." number -2700
                set openedDocument to missing value
                if not (my restoreSecurity(previousSecurity)) then error "Word did not restore automation security." number -2700
                set previousSecurity to missing value
                tell application id "com.microsoft.Word" to activate
                return {0, "", true, true, resultIdentified}
            on error errorMessage number errorNumber
                set inputClosed to my closeOwned(openedDocument, basePath)
                set securityRestored to my restoreSecurity(previousSecurity)
                -- Before Compare, a captured and closed input proves retirement.
                -- After dispatch, an unidentified generated result is retained.
                if inputClosed and openedDocument is not missing value and not comparisonStarted then set possiblyOpened to false
                return {errorNumber, errorMessage, possiblyOpened, securityRestored, resultIdentified}
            end try
        end timeout
    end compareDocuments
    """
    static let mergeSource = helpers + """

    on mergeDocuments(basePath, theirsPath, minePath, resultPath, markerPath)
        set previousSecurity to missing value
        set theirDocument to missing value
        set baseDocument to missing value
        set mineDocument to missing value
        set possiblyOpened to false
        set editingStarted to false
        set resultIdentified to false
        set started to current date
        with timeout of 20 seconds
            try
                my checkCancellation(markerPath, started)
                tell application id "com.microsoft.Word"
                    set previousSecurity to automation security
                    set automation security to msoAutomationSecurityForceDisable
                    if automation security is not msoAutomationSecurityForceDisable then error "Word did not disable automation macros." number -2700
                end tell
                set possiblyOpened to true
                set theirDocument to my openOwned(theirsPath, false)
                my checkCancellation(markerPath, started)
                set baseDocument to my openOwned(basePath, false)
                my checkCancellation(markerPath, started)
                set mineDocument to my openOwned(minePath, false)
                my checkCancellation(markerPath, started)
                if not (my ownedName(baseDocument, basePath)) or not (my ownedName(theirDocument, theirsPath)) or not (my ownedName(mineDocument, minePath)) then error "Private merge ownership changed." number -2700
                set editingStarted to true
                tell application id "com.microsoft.Word"
                    activate object baseDocument
                    compare baseDocument path theirsPath author name "theirs" target compare target selected detect format changes true ignore all comparison warnings true add to recent files false
                end tell
                my checkCancellation(markerPath, started)
                tell application id "com.microsoft.Word"
                    if not (my ownedName(baseDocument, basePath)) then error "Private merge base ownership changed." number -2700
                    activate object baseDocument
                    compare baseDocument path minePath author name "mine" target compare target selected detect format changes true ignore all comparison warnings true add to recent files false
                end tell
                my checkCancellation(markerPath, started)
                tell application id "com.microsoft.Word"
                    if not (my ownedName(mineDocument, minePath)) then error "Private merge result ownership changed." number -2700
                    activate object mineDocument
                    merge mineDocument file name theirsPath
                end tell
                if not (my ownedName(mineDocument, minePath)) then error "Word merge result ownership changed." number -2700
                set resultIdentified to true
                my checkCancellation(markerPath, started)
                set theirsClosed to my closeOwned(theirDocument, theirsPath)
                set baseClosed to my closeOwned(baseDocument, basePath)
                if not theirsClosed or not baseClosed then error "Word private merge input closure was not confirmed." number -2700
                set theirDocument to missing value
                set baseDocument to missing value
                if not (my restoreSecurity(previousSecurity)) then error "Word did not restore automation security." number -2700
                set previousSecurity to missing value
                tell application id "com.microsoft.Word" to activate
                return {0, "", true, true, resultIdentified}
            on error errorMessage number errorNumber
                set theirsClosed to my closeOwned(theirDocument, theirsPath)
                set baseClosed to my closeOwned(baseDocument, basePath)
                if not editingStarted then
                    set mineClosed to my closeOwned(mineDocument, minePath)
                    if theirsClosed and baseClosed and mineClosed and mineDocument is not missing value then set possiblyOpened to false
                end if
                set securityRestored to my restoreSecurity(previousSecurity)
                return {errorNumber, errorMessage, possiblyOpened, securityRestored, resultIdentified}
            end try
        end timeout
    end mergeDocuments
    """
    static func compile(merging:Bool = false) throws -> NSAppleScript {
        guard let script = NSAppleScript(source:merging ? mergeSource : source) else { throw WordComparisonFailure.automation(-1,"AppleScript is unavailable.",possiblyOpened:false) }
        var details: NSDictionary?
        guard script.compileAndReturnError(&details) else {
            throw WordComparisonFailure.automation((details?[NSAppleScript.errorNumber] as? Int) ?? -1,
                (details?[NSAppleScript.errorMessage] as? String) ?? "Could not compile the Word comparison handler.",possiblyOpened:false)
        }
        return script
    }
    static func event(_ preview: WordComparisonPreview, cancellationFile:URL? = nil) -> NSAppleEventDescriptor {
        let arguments=NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string:preview.base.path),at:1)
        arguments.insert(NSAppleEventDescriptor(string:preview.destination.path),at:2)
        arguments.insert(NSAppleEventDescriptor(string:(cancellationFile ?? preview.directory.appendingPathComponent("automation.cancel")).path),at:3)
        let event=NSAppleEventDescriptor(eventClass:0x61736372,eventID:0x70736272,targetDescriptor:nil,returnID:-1,transactionID:0)
        event.setParam(NSAppleEventDescriptor(string:"comparedocuments"),forKeyword:0x736e616d)
        event.setParam(arguments,forKeyword:0x2d2d2d2d); return event
    }
    static func mergeEvent(_ preview:WordMergePreview,cancellationFile:URL? = nil) -> NSAppleEventDescriptor {
        let arguments=NSAppleEventDescriptor.list()
        for (index,path) in [preview.base.path,preview.theirs.path,preview.mine.path,preview.result.path,(cancellationFile ?? preview.directory.appendingPathComponent("automation.cancel")).path].enumerated() { arguments.insert(NSAppleEventDescriptor(string:path),at:index+1) }
        let event=NSAppleEventDescriptor(eventClass:0x61736372,eventID:0x70736272,targetDescriptor:nil,returnID:-1,transactionID:0)
        event.setParam(NSAppleEventDescriptor(string:"mergedocuments"),forKeyword:0x736e616d); event.setParam(arguments,forKeyword:0x2d2d2d2d); return event
    }
    private static func checkBeforeDispatch(_ cancellation: OperationCancellation) throws {
        if cancellation.isCancelled { throw WordComparisonFailure.automation(-128,"Operation cancelled.",possiblyOpened:false) }
    }
    /// A successful receipt identifies the retained review result and confirms
    /// macro-security restoration. Unknown or malformed replies retain inputs.
    static func decode(_ reply:ExecutionReply)throws {
        if let error=reply.error {
            let code=(error[NSAppleScript.errorNumber] as? Int) ?? -1
            throw WordComparisonFailure.automation(code,(error[NSAppleScript.errorMessage] as? String) ?? "Word did not confirm the operation.",possiblyOpened:code != -1743)
        }
        guard let value=reply.result,value.descriptorType==typeAEList,value.numberOfItems==5,
              let code=value.atIndex(1),code.descriptorType==typeSInt32,
              let message=value.atIndex(2),[typeUnicodeText,typeUTF8Text,typeChar].contains(message.descriptorType),
              let opened=value.atIndex(3),opened.descriptorType==typeBoolean,
              let restored=value.atIndex(4),restored.descriptorType==typeBoolean,
              let identified=value.atIndex(5),identified.descriptorType==typeBoolean else {
            throw WordComparisonFailure.automation(-1,"Word returned an incomplete ownership or security receipt.",possiblyOpened:true)
        }
        let resultCode=Int(code.int32Value)
        guard resultCode==0,restored.booleanValue,identified.booleanValue,opened.booleanValue else {
            let reason = !restored.booleanValue ? "Macro-security restoration was not confirmed. " : resultCode==0 && !identified.booleanValue ? "The review result was not identified. " : ""
            throw WordComparisonFailure.automation(resultCode==0 ? -1:resultCode,reason + (message.stringValue ?? "Word operation failed."),possiblyOpened:opened.booleanValue || identified.booleanValue || !restored.booleanValue || resultCode==0)
        }
    }
    private final class Job:@unchecked Sendable {
        private let lock=NSLock()
        private var value:Result<Void,Error>?
        func finish(_ result:Result<Void,Error>){lock.lock();value=result;lock.unlock()}
        func result()->Result<Void,Error>? {lock.lock();defer{lock.unlock()};return value}
    }
    @MainActor static func compare(_ preview:WordComparisonPreview,cancellation:OperationCancellation,dependencies:Dependencies = .init())async throws {
        if Task.isCancelled {cancellation.cancel()}
        try checkBeforeDispatch(cancellation)
        guard dependencies.applicationAvailable() else {throw WordComparisonFailure.application}
        let marker=preview.directory.appendingPathComponent("automation.cancel")
        try await perform(merging:false,marker:marker,cancellation:cancellation,dependencies:dependencies){event(preview,cancellationFile:marker)}
    }
    @MainActor static func merge(_ preview:WordMergePreview,cancellation:OperationCancellation,dependencies:Dependencies = .init())async throws {
        if Task.isCancelled {cancellation.cancel()}
        if cancellation.isCancelled {throw WordMergeFailure.automation(-128,"Operation cancelled.",possiblyOpened:false)}
        guard dependencies.applicationAvailable() else {throw WordMergeFailure.application}
        let marker=preview.directory.appendingPathComponent("automation.cancel")
        do {try await perform(merging:true,marker:marker,cancellation:cancellation,dependencies:dependencies){mergeEvent(preview,cancellationFile:marker)}}
        catch let failure as WordComparisonFailure {
            switch failure {
            case .automation(let code,let message,let opened):throw WordMergeFailure.automation(code,message,possiblyOpened:opened)
            default:throw WordMergeFailure.application
            }
        }
    }
    private static func perform(merging:Bool,marker:URL,cancellation:OperationCancellation,dependencies:Dependencies,eventSource:@escaping @Sendable ()->NSAppleEventDescriptor)async throws {
        if Task.isCancelled {cancellation.cancel()}
        try checkBeforeDispatch(cancellation)
        let job=Job()
        queue.async {
            do {
                try checkBeforeDispatch(cancellation)
                let script=try dependencies.compile(merging)
                try checkBeforeDispatch(cancellation)
                try decode(dependencies.execute(script,eventSource()))
                job.finish(.success(()))
            } catch {job.finish(.failure(error))}
        }
        let began=ProcessInfo.processInfo.systemUptime
        var markerWritten=false
        while job.result()==nil {
            if cancellation.isCancelled || Task.isCancelled || ProcessInfo.processInfo.systemUptime-began>=180 {
                if !markerWritten {
                    do {try Data().write(to:marker,options:.withoutOverwriting);markerWritten=true}
                    catch { /* Retry while draining; never claim a marker was delivered. */ }
                }
            }
            // Drain the serialized Apple event, owned input cleanup and security
            // restoration before releasing the caller's grants and Quit guard.
            await withCheckedContinuation {continuation in DispatchQueue.main.asyncAfter(deadline:.now()+0.05){continuation.resume()}}
        }
        try job.result()!.get()
        if cancellation.isCancelled || Task.isCancelled || markerWritten {
            throw WordComparisonFailure.automation(-128,"Word operation cancelled; its review result was retained.",possiblyOpened:true)
        }
    }
}
