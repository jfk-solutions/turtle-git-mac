import AppKit
import TurtleGitCore

@main struct WordComparisonNativeVerification {
    struct Failure: Error, CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws { if !value { throw Failure(description:message) } }
    @MainActor static var owners:[NSWindowController]=[]
    @MainActor static func wait(_ ready:()->Bool,line:Int = #line) async throws {
        for _ in 0..<1500 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Word native timeout at \(line)")
    }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do { try await verify(); owners.forEach { $0.close() }; DiffToolApplication.discardAll() }
        catch { owners.forEach { $0.close() }; DiffToolApplication.discardAll(); fputs("Word comparison failed: \(error)\n",stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),a=root.appendingPathComponent("old \" 雪.docx"),b=root.appendingPathComponent("new.docx")
        let old=try Data(contentsOf:a),new=try Data(contentsOf:b)
        let suite="TurtleGit.WordNative."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        let saved=DiffToolApplication.compareWord,savedLibreOffice=DiffToolApplication.compareLibreOffice
        defer { DiffToolApplication.compareWord=saved;DiffToolApplication.compareLibreOffice=savedLibreOffice }
        var libreOfficeCalls=0
        DiffToolApplication.compareLibreOffice={ _,_ in libreOfficeCalls += 1;throw Failure(description:"Unexpected LibreOffice fallback") }
        var copies:[URL]=[],calls=0
        defer { for copy in copies { try? FileManager.default.removeItem(at:copy) } }
        DiffToolApplication.compareWord={ preview,_ in
            calls += 1; copies.append(preview.directory)
            try require((try Data(contentsOf:preview.base))==old && (try Data(contentsOf:preview.destination))==new,"Word private inputs changed selected bytes")
            let event=WordComparisonAutomation.event(preview),arguments=event.paramDescriptor(forKeyword:0x2d2d2d2d)
            try require(event.paramDescriptor(forKeyword:0x736e616d)?.stringValue=="comparedocuments" && arguments?.numberOfItems==3 && arguments?.atIndex(1)?.stringValue==preview.base.path && arguments?.atIndex(2)?.stringValue==preview.destination.path && arguments?.atIndex(3)?.stringValue==preview.directory.appendingPathComponent("automation.cancel").path,"Word paths were interpolated or retargeted")
            try require(preview.base.lastPathComponent==a.lastPathComponent && preview.destination.lastPathComponent==b.lastPathComponent,"Word lost original filenames")
        }
        func controller() throws -> FileComparisonWindowController {
            let value=try FileComparisonWindowController(comparison:WorkingFileComparison(base:a,destination:b),permissions:[],preferences:prefs,deferInitialLoad:true)
            owners.append(value); return value
        }
        let success=try controller(); success.model.beginTransferredDocument(); try await wait { !success.model.busy && calls==1 }
        try require(success.model.error==nil && FileManager.default.fileExists(atPath:copies[0].path),"Successful Word handoff lost inputs")
        DiffToolApplication.discardAll(); try require(FileManager.default.fileExists(atPath:copies[0].path),"Shared cleanup removed a successful Word result's inputs")
        let raw=try controller(); raw.model.captureToolChoice(true); raw.model.beginTransferredDocument(); try await wait { !raw.model.busy }
        try require(calls==1 && raw.model.document?.destination.bytes==new,"Word Shift bypass did not preserve raw bytes")
        var refused:URL?
        DiffToolApplication.compareWord={ preview,_ in refused=preview.directory; copies.append(preview.directory); throw WordComparisonFailure.automation(-1743,"denied",possiblyOpened:false) }
        let denied=try controller(); denied.model.beginTransferredDocument(); try await wait { !denied.model.busy }
        try require(denied.model.error?.contains("Privacy & Security")==true && refused != nil && !FileManager.default.fileExists(atPath:refused!.path),"Denied Word automation lost recovery or leaked unopened inputs")
        var uncertain:URL?
        DiffToolApplication.compareWord={ preview,_ in uncertain=preview.directory; copies.append(preview.directory); throw WordComparisonFailure.automation(-1712,"timed out",possiblyOpened:true) }
        let timeout=try controller(); timeout.model.beginTransferredDocument(); try await wait { !timeout.model.busy }
        try require(timeout.model.error != nil && uncertain != nil && FileManager.default.fileExists(atPath:uncertain!.path),"Uncertain Word receipt deleted possibly opened inputs")
        var reply:CheckedContinuation<Void,Error>?,late:URL?,wordToken:OperationCancellation?
        DiffToolApplication.compareWord={ preview,token in wordToken=token;late=preview.directory; copies.append(preview.directory); try await withCheckedThrowingContinuation { reply=$0 } }
        let closing=try controller(); closing.model.beginTransferredDocument(); try await wait { reply != nil }; closing.model.load(); closing.close()
        try require(wordToken?.isCancelled==true && DiffToolApplication.activeRequests==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Closed Word dispatch released actual worker/Quit lifetime")
        reply?.resume(); reply=nil; try await wait { DiffToolApplication.activeRequests==0 && !closing.model.busy }
        try require(closing.model.error==nil && late != nil && FileManager.default.fileExists(atPath:late!.path),"Late successful Word dispatch lost accepted inputs or published an obsolete error")
        try require(libreOfficeCalls==0,"Word permission/uncertain errors unexpectedly fell back")
        let document=try WorkingFileComparison(base:a,destination:b).read()
        var fallbackWord:URL?,fallbackLibreOffice:URL?
        DiffToolApplication.compareWord={ preview,_ in fallbackWord=preview.directory;copies.append(preview.directory);throw WordComparisonFailure.application }
        DiffToolApplication.compareLibreOffice={ preview,_ in
            libreOfficeCalls += 1;fallbackLibreOffice=preview.directory;copies.append(preview.directory)
            try require((try Data(contentsOf:preview.base))==old && (try Data(contentsOf:preview.destination))==new,"Fallback changed captured input bytes")
        }
        _=try await DiffToolApplication.open(document,root:root,permissions:[],alternate:false,preferences:prefs)
        try require(libreOfficeCalls==1 && fallbackWord != nil && !FileManager.default.fileExists(atPath:fallbackWord!.path) && fallbackLibreOffice != nil && FileManager.default.fileExists(atPath:fallbackLibreOffice!.path),"Unavailable Word fallback leaked unused Word inputs or removed accepted LibreOffice files")
        var direct=DiffToolProgram();direct.enabled=true;direct.builtIn = .libreOfficeDocument
        var worker:CheckedContinuation<Void,Error>?,workerToken:OperationCancellation?,retiring:URL?
        DiffToolApplication.compareLibreOffice={ preview,token in
            workerToken=token;retiring=preview.directory;copies.append(preview.directory)
            try await withCheckedThrowingContinuation {worker=$0}
        }
        let owner=NSWindow(contentRect:.init(x:-10000,y:-10000,width:100,height:100),styleMask:[.titled,.closable],backing:.buffered,defer:false);owner.isReleasedWhenClosed=false
        defer {owner.close()}
        let ownerTask=Task {try await DiffToolApplication.open(document,root:root,permissions:[],alternate:false,preferences:prefs,owner:owner,selection:.program(direct))}
        try await wait {worker != nil};owner.close()
        try require(workerToken?.isCancelled==true && DiffToolApplication.activeRequests==1,"Owner closure failed to cancel or drain LibreOffice")
        worker?.resume(throwing:LibreOfficeComparisonFailure.worker("cancelled",possiblyOpened:false));worker=nil
        do {_=try await ownerTask.value;throw Failure(description:"Closed LibreOffice worker succeeded")}catch is LibreOfficeComparisonFailure {}
        try require(retiring != nil && !FileManager.default.fileExists(atPath:retiring!.path) && DiffToolApplication.activeRequests==0,"Proven retired LibreOffice inputs leaked")
        let task=Task {try await DiffToolApplication.open(document,root:root,permissions:[],alternate:false,preferences:prefs,selection:.program(direct))}
        try await wait {worker != nil};task.cancel();try await wait {workerToken?.isCancelled==true}
        try require(DiffToolApplication.activeRequests==1,"Task cancellation released actual document worker early")
        worker?.resume(throwing:LibreOfficeComparisonFailure.worker("uncertain",possiblyOpened:true));worker=nil
        do {_=try await task.value;throw Failure(description:"Cancelled LibreOffice worker succeeded")}catch is LibreOfficeComparisonFailure {}
        try require(retiring != nil && FileManager.default.fileExists(atPath:retiring!.path) && DiffToolApplication.activeRequests==0,"Uncertain cancelled LibreOffice inputs were deleted")
        let cancelled=OperationCancellation(); cancelled.cancel()
        do { _=try await DiffToolApplication.open(try WorkingFileComparison(base:a,destination:b).read(),root:root,permissions:[],alternate:false,preferences:prefs,cancellation:cancelled); throw Failure(description:"Cancelled Word dispatch opened") }
        catch is OperationCancellationFailure {}
        if ProcessInfo.processInfo.environment["TURTLEGIT_CHECK_WORD_TERMINOLOGY"]=="1" {
            _=try WordComparisonAutomation.compile()
            print("PASS: fixed Word handler compiled against installed Microsoft Word terminology; no comparison executed")
        }
        try require((try Data(contentsOf:a))==old && (try Data(contentsOf:b))==new,"Word adapter modified original files")
        print("PASS: shipping Word comparison route, literal Apple-event arguments and exact input copies, Shift, permission/retry ownership, uncertain failure retention, owner/task cancellation, unavailable-only LibreOffice fallback and closed-worker/Quit; unchanged originals")
    }
}
