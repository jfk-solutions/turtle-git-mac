// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// Only fixed script syntax is compiled. Paths arrive as Apple-event arguments,
/// never as source text or shell commands. A private input cannot alias a user's
/// existing Word document, so cleanup closes only the input opened by this call.
enum WordComparisonAutomation {
    private static let queue = DispatchQueue(label:"org.turtlegit.word-comparison")
    static let source = """
    on compareDocuments(basePath, newPath)
        set openedDocument to missing value
        set previousSecurity to missing value
        try
            tell application id "com.microsoft.Word"
                activate
                set previousSecurity to automation security
                set automation security to 3
                set openedDocument to open (POSIX file basePath) read only true add to recent files false
                compare openedDocument path newPath author name "Comparison" target compare target new detect format changes true ignore all comparison warnings true add to recent files false
                set saved of active document to true
                close openedDocument saving no
                set automation security to previousSecurity
                activate
            end tell
            return {0, "", true}
        on error errorMessage number errorNumber
            set wasOpened to openedDocument is not missing value
            if wasOpened then
                try
                    tell application id "com.microsoft.Word" to close openedDocument saving no
                end try
            end if
            if previousSecurity is not missing value then
                try
                    tell application id "com.microsoft.Word" to set automation security to previousSecurity
                end try
            end if
            return {errorNumber, errorMessage, wasOpened}
        end try
    end compareDocuments
    """
    static let mergeSource = """
    on mergeDocuments(basePath, theirsPath, minePath, resultPath)
        set previousSecurity to missing value
        set theirDocument to missing value
        set baseDocument to missing value
        set mineDocument to missing value
        try
            tell application id "com.microsoft.Word"
                activate
                set previousSecurity to automation security
                set automation security to 3
                set theirDocument to open (POSIX file theirsPath) read only false add to recent files false
                set baseDocument to open (POSIX file basePath) read only false add to recent files false
                set mineDocument to open (POSIX file minePath) read only false add to recent files false
                activate object baseDocument
                compare baseDocument path theirsPath author name "theirs" target compare target selected detect format changes true ignore all comparison warnings true add to recent files false
                activate object baseDocument
                compare baseDocument path minePath author name "mine" target compare target selected detect format changes true ignore all comparison warnings true add to recent files false
                activate object mineDocument
                merge mineDocument file name theirsPath
                close theirDocument saving no
                close baseDocument saving no
                set automation security to previousSecurity
                activate
            end tell
            return {0, "", true}
        on error errorMessage number errorNumber
            set wasOpened to theirDocument is not missing value or baseDocument is not missing value or mineDocument is not missing value
            if previousSecurity is not missing value then
                try
                    tell application id "com.microsoft.Word" to set automation security to previousSecurity
                end try
            end if
            return {errorNumber, errorMessage, wasOpened}
        end try
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
    static func event(_ preview: WordComparisonPreview) -> NSAppleEventDescriptor {
        let arguments=NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string:preview.base.path),at:1)
        arguments.insert(NSAppleEventDescriptor(string:preview.destination.path),at:2)
        let event=NSAppleEventDescriptor(eventClass:0x61736372,eventID:0x70736272,targetDescriptor:nil,returnID:-1,transactionID:0)
        event.setParam(NSAppleEventDescriptor(string:"comparedocuments"),forKeyword:0x736e616d)
        event.setParam(arguments,forKeyword:0x2d2d2d2d); return event
    }
    static func mergeEvent(_ preview:WordMergePreview) -> NSAppleEventDescriptor {
        let arguments=NSAppleEventDescriptor.list()
        for (index,path) in [preview.base.path,preview.theirs.path,preview.mine.path,preview.result.path].enumerated() { arguments.insert(NSAppleEventDescriptor(string:path),at:index+1) }
        let event=NSAppleEventDescriptor(eventClass:0x61736372,eventID:0x70736272,targetDescriptor:nil,returnID:-1,transactionID:0)
        event.setParam(NSAppleEventDescriptor(string:"mergedocuments"),forKeyword:0x736e616d); event.setParam(arguments,forKeyword:0x2d2d2d2d); return event
    }
    private static func checkBeforeDispatch(_ cancellation: OperationCancellation) throws {
        if cancellation.isCancelled { throw WordComparisonFailure.automation(-128,"Operation cancelled.",possiblyOpened:false) }
    }
    @MainActor static func compare(_ preview: WordComparisonPreview, cancellation: OperationCancellation) async throws {
        try checkBeforeDispatch(cancellation)
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.microsoft.Word") != nil else { throw WordComparisonFailure.application }
        try await perform(merging:false,cancellation:cancellation) { event(preview) }
    }
    @MainActor static func merge(_ preview:WordMergePreview,cancellation:OperationCancellation) async throws {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.microsoft.Word") != nil else { throw WordMergeFailure.application }
        do { try await perform(merging:true,cancellation:cancellation) { mergeEvent(preview) } }
        catch let failure as WordComparisonFailure {
            switch failure {
            case .automation(let code,let message,let opened): throw WordMergeFailure.automation(code,message,possiblyOpened:opened)
            default: throw WordMergeFailure.application
            }
        }
    }
    private static func perform(merging:Bool,cancellation:OperationCancellation,eventSource:@escaping @Sendable () -> NSAppleEventDescriptor) async throws {
        try await withCheckedThrowingContinuation { (reply:CheckedContinuation<Void,Error>) in
            queue.async {
                do {
                    try checkBeforeDispatch(cancellation); let script=try compile(merging:merging); try checkBeforeDispatch(cancellation)
                    var details:NSDictionary?
                    let result=script.executeAppleEvent(eventSource(),error:&details) as NSAppleEventDescriptor?
                    if let details {
                        let code=(details[NSAppleScript.errorNumber] as? Int) ?? -1
                        throw WordComparisonFailure.automation(code,(details[NSAppleScript.errorMessage] as? String) ?? "Word did not confirm the operation.",possiblyOpened:code != -1743)
                    }
                    guard let result, result.numberOfItems==3 else { throw WordComparisonFailure.automation(-1,"Word returned an incomplete result.",possiblyOpened:true) }
                    let code=Int(result.atIndex(1)?.int32Value ?? -1)
                    guard code==0 else { throw WordComparisonFailure.automation(code,result.atIndex(2)?.stringValue ?? "Operation failed.",possiblyOpened:result.atIndex(3)?.booleanValue ?? true) }
                    reply.resume()
                } catch { reply.resume(throwing:error) }
            }
        }
    }
}
