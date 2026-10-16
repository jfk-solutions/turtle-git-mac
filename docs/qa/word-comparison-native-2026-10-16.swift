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
        let saved=DiffToolApplication.compareWord
        defer { DiffToolApplication.compareWord=saved }
        var copies:[URL]=[],calls=0
        defer { for copy in copies { try? FileManager.default.removeItem(at:copy) } }
        DiffToolApplication.compareWord={ preview,_ in
            calls += 1; copies.append(preview.directory)
            try require((try Data(contentsOf:preview.base))==old && (try Data(contentsOf:preview.destination))==new,"Word private inputs changed selected bytes")
            let event=WordComparisonAutomation.event(preview),arguments=event.paramDescriptor(forKeyword:0x2d2d2d2d)
            try require(event.paramDescriptor(forKeyword:0x736e616d)?.stringValue=="comparedocuments" && arguments?.numberOfItems==2 && arguments?.atIndex(1)?.stringValue==preview.base.path && arguments?.atIndex(2)?.stringValue==preview.destination.path,"Word paths were interpolated or retargeted")
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
        var reply:CheckedContinuation<Void,Error>?,late:URL?
        DiffToolApplication.compareWord={ preview,_ in late=preview.directory; copies.append(preview.directory); try await withCheckedThrowingContinuation { reply=$0 } }
        let closing=try controller(); closing.model.beginTransferredDocument(); try await wait { reply != nil }; closing.model.load(); closing.close()
        try require(DiffToolApplication.activeRequests==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Closed Word dispatch released actual worker/Quit lifetime")
        reply?.resume(); reply=nil; try await wait { DiffToolApplication.activeRequests==0 && !closing.model.busy }
        try require(closing.model.error==nil && late != nil && FileManager.default.fileExists(atPath:late!.path),"Late successful Word dispatch lost accepted inputs or published an obsolete error")
        let cancelled=OperationCancellation(); cancelled.cancel()
        do { _=try await DiffToolApplication.open(try WorkingFileComparison(base:a,destination:b).read(),root:root,permissions:[],alternate:false,preferences:prefs,cancellation:cancelled); throw Failure(description:"Cancelled Word dispatch opened") }
        catch is OperationCancellationFailure {}
        if ProcessInfo.processInfo.environment["TURTLEGIT_CHECK_WORD_TERMINOLOGY"]=="1" {
            _=try WordComparisonAutomation.compile()
            print("PASS: fixed Word handler compiled against installed Microsoft Word terminology; no comparison executed")
        }
        try require((try Data(contentsOf:a))==old && (try Data(contentsOf:b))==new,"Word adapter modified original files")
        print("PASS: shipping Word comparison route, literal Apple-event arguments and exact input copies, Shift, permission/retry ownership, uncertain failure retention and closed-worker/Quit; unchanged originals")
    }
}
