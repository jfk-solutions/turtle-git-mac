import AppKit
import TurtleGitCore

/// Exercises the shipping compile/event/receipt bridge without launching Office.
/// The fixed AppleScript's ownership/security steps are checked independently of
/// the higher-level comparison and merge executor substitutes.
enum WordAutomationContractNativeVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    static func receipt(_ code:Int32=0,opened:Bool=true,restored:Bool=true,identified:Bool=true)->WordComparisonAutomation.ExecutionReply {
        let value=NSAppleEventDescriptor.list()
        let fields:[NSAppleEventDescriptor]=[.init(int32:code),.init(string:"injected response"),.init(boolean:opened),.init(boolean:restored),.init(boolean:identified)]
        for (index,field) in fields.enumerated(){value.insert(field,at:index+1)}
        return .init(result:value,error:nil)
    }
    @MainActor static func verify(root:URL,git:URL)async throws {
        let directory=root.appendingPathComponent("word-contract-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:directory)}
        let old=directory.appendingPathComponent("old ' 雪.docx"),new=directory.appendingPathComponent("new.docx")
        try Data("old".utf8).write(to:old);try Data("new".utf8).write(to:new)
        let token=OperationCancellation()
        let preview=try WordComparisonPreview.prepare(try WorkingFileComparison(base:old,destination:new).read(),in:directory,cancellation:token)
        defer {preview.discard()}
        let source=WordComparisonAutomation.source,merge=WordComparisonAutomation.mergeSource
        try require(!source.contains("saved of active document") && source.contains("document of window id resultWindowID") && source.contains("(count of resultWindows) is not 1") && source.contains("(full name of resultDocument) is in previousDocumentNames"),"Comparison did not identify its unique generated result before marking it saved")
        try require(source.contains("inputViewType is outline view or ((inputViewType is master view or inputViewType is reading view) and (count of subdocuments of openedDocument) is 0)"),"Pinned outline/master/reading view gates changed")
        for script in [source,merge] {
            try require(script.contains("set automation security to msoAutomationSecurityForceDisable") && script.contains("if automation security is not msoAutomationSecurityForceDisable") && script.contains("return automation security is previousSecurity"),"Macro disable/readback or restoration receipt absent")
            try require(script.contains("my checkCancellation(markerPath, started)") && script.contains("with timeout of 20 seconds") && script.contains("if not (my ownedName(theDocument, inputPath)) then return false"),"Cancellation/owned input cleanup absent")
            try require(!script.contains("quit") && !script.contains("close active"),"Word handler could close unrelated user state")
        }
        try require(merge.contains("set theirsClosed to my closeOwned(theirDocument, theirsPath)") && merge.contains("set baseClosed to my closeOwned(baseDocument, basePath)") && merge.contains("if not editingStarted then"),"Merge error cleanup lost captured input ownership or editable-result preservation")
        var dependencies=WordComparisonAutomation.Dependencies()
        dependencies.applicationAvailable={true}
        dependencies.compile={merging in
            try require(!merging,"Comparison used merge script")
            return NSAppleScript(source:"return true")!
        }
        dependencies.execute={_,event in
            let args=event.paramDescriptor(forKeyword:0x2d2d2d2d)
            do {
                try require(event.paramDescriptor(forKeyword:0x736e616d)?.stringValue=="comparedocuments" && args?.numberOfItems==3 && args?.atIndex(1)?.stringValue==preview.base.path && args?.atIndex(2)?.stringValue==preview.destination.path && args?.atIndex(3)?.stringValue==preview.directory.appendingPathComponent("automation.cancel").path,"Shipping bridge changed literal paths or marker")
                return receipt()
            } catch {return .init(result:nil,error:[NSAppleScript.errorNumber:-2700,NSAppleScript.errorMessage:String(describing:error)])}
        }
        try await WordComparisonAutomation.compare(preview,cancellation:token,dependencies:dependencies)
        for (reply,opened) in [(receipt(-128,opened:false,identified:false),false),(receipt(0,opened:false),true),(receipt(0,restored:false),true),(receipt(0,identified:false),true),(.init(result:NSAppleEventDescriptor(string:"bad"),error:nil),true)] {
            do {try WordComparisonAutomation.decode(reply);throw Failure(description:"Invalid Word receipt accepted")}
            catch let failure as WordComparisonFailure {try require(failure.possiblyOpened==opened,"Receipt cleanup/security uncertainty was decoded incorrectly")}
        }
        do {try WordComparisonAutomation.decode(.init(result:nil,error:[NSAppleScript.errorNumber:-1743,NSAppleScript.errorMessage:"denied"]));throw Failure(description:"Denied automation accepted")}
        catch let failure as WordComparisonFailure {try require(!failure.possiblyOpened && failure.localizedDescription.contains("Privacy & Security"),"Denied automation recovery changed")}
        // Cancellation occurs inside the actual dispatch bridge. Its completion
        // waits for the marker and a cleanup receipt rather than abandoning work.
        dependencies.execute={_,event in
            token.cancel()
            guard let path=event.paramDescriptor(forKeyword:0x2d2d2d2d)?.atIndex(3)?.stringValue else{return .init(result:nil,error:nil)}
            for _ in 0..<300 {
                if FileManager.default.fileExists(atPath:path){return receipt(-128,opened:false,identified:false)}
                Thread.sleep(forTimeInterval:0.01)
            }
            return .init(result:nil,error:nil)
        }
        do {try await WordComparisonAutomation.compare(preview,cancellation:token,dependencies:dependencies);throw Failure(description:"Cancelled bridge succeeded")}
        catch let failure as WordComparisonFailure {try require(!failure.possiblyOpened,"Confirmed cancellation cleanup remained uncertain")}
        try require(FileManager.default.fileExists(atPath:preview.directory.appendingPathComponent("automation.cancel").path),"Cancellation marker was not delivered while the event was in flight")
        let cancelled=OperationCancellation();cancelled.cancel()
        dependencies.compile={_ in throw Failure(description:"Cancelled Word request compiled")}
        do {try await WordComparisonAutomation.compare(preview,cancellation:cancelled,dependencies:dependencies);throw Failure(description:"Pre-dispatch cancellation succeeded")}
        catch let failure as WordComparisonFailure {try require(!failure.possiblyOpened,"Pre-dispatch cancellation acquired ownership")}
        let repository=GitRepository(root:directory,executable:git)
        _=try await repository.run(["init","-b","main"])
        for (key,value) in [("user.name","Word Contract QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repository.run(["config",key,value])}
        let conflict=directory.appendingPathComponent("conflict.docx")
        try Data([0,1]).write(to:conflict);try await repository.stage(["conflict.docx"]);_=try await repository.commit(message:"base")
        _=try await repository.run(["checkout","-b","side"])
        try Data([0,2]).write(to:conflict);try await repository.stage(["conflict.docx"]);_=try await repository.commit(message:"theirs")
        _=try await repository.run(["checkout","main"])
        try Data([0,3]).write(to:conflict);try await repository.stage(["conflict.docx"]);_=try await repository.commit(message:"mine")
        _=try await repository.run(["merge","--no-edit","side"],successfulExitCodes:0...1)
        let mergeToken=OperationCancellation(),input=try await repository.externalMergeInputs(path:"conflict.docx")
        let mergePreview=try WordMergePreview.prepare(input,in:directory,cancellation:mergeToken)
        defer {mergePreview.discard()}
        dependencies.compile={merging in try require(merging,"Merge used comparison script");return NSAppleScript(source:"return true")!}
        dependencies.execute={_,event in
            let args=event.paramDescriptor(forKeyword:0x2d2d2d2d)
            do {
                try require(event.paramDescriptor(forKeyword:0x736e616d)?.stringValue=="mergedocuments" && args?.numberOfItems==5 && args?.atIndex(1)?.stringValue==mergePreview.base.path && args?.atIndex(2)?.stringValue==mergePreview.theirs.path && args?.atIndex(3)?.stringValue==mergePreview.mine.path && args?.atIndex(4)?.stringValue==mergePreview.result.path && args?.atIndex(5)?.stringValue==mergePreview.directory.appendingPathComponent("automation.cancel").path,"Merge bridge changed role paths, Save As target or marker")
                return receipt()
            }catch{return .init(result:nil,error:[NSAppleScript.errorNumber:-2700,NSAppleScript.errorMessage:String(describing:error)])}
        }
        try await WordComparisonAutomation.merge(mergePreview,cancellation:mergeToken,dependencies:dependencies)
        dependencies.execute={_,_ in receipt(-2700,opened:false,restored:false,identified:false)}
        do {try await WordComparisonAutomation.merge(mergePreview,cancellation:mergeToken,dependencies:dependencies);throw Failure(description:"Unrestored merge security accepted")}
        catch let failure as WordMergeFailure {try require(failure.possiblyOpened && failure.localizedDescription.contains("Macro-security restoration"),"Merge lost restoration failure mapping")}
        if ProcessInfo.processInfo.environment["TURTLEGIT_CHECK_WORD_TERMINOLOGY"]=="1" {
            _=try WordComparisonAutomation.compile();_=try WordComparisonAutomation.compile(merging:true)
        }
        try require(try Data(contentsOf:old)==Data("old".utf8) && Data(contentsOf:new)==Data("new".utf8),"Word bridge changed original files")
        print("PASS: Word fixed ownership/security/view/cancel contracts and shipping injected compile/event/typed-receipt bridge; no Office launched")
    }
}
