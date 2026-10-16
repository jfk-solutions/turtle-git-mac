import AppKit
import TurtleGitCore

@main struct ImageToolRoutingVerification {
    struct Failure:Error,CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String) throws {if !value{throw Failure(description:message)}}
    @MainActor static func wait(_ ready:()->Bool,line:Int = #line) async throws {
        for _ in 0..<2000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Image tool routing timeout at \(line)")
    }
    @MainActor static func main() async {
        do {try await verify()} catch {fputs("Image routing failed: \(error)\n",stderr);exit(1)}
    }
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Image routing QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:3,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        for x in 0..<3 {for y in 0..<2 {bitmap.setColor(.red,atX:x,y:y)}}
        let png=bitmap.representation(using:.png,properties:[:])!,bad=Data("unsupported image payload\n".utf8)
        for name in ["left.png","right.PNG","left.dat","right.dat"] {try png.write(to:root.appendingPathComponent(name))}
        try bad.write(to:root.appendingPathComponent("bad.png"));try Data().write(to:root.appendingPathComponent("empty.png"))
        try await repo.stage(["left.png","right.PNG","left.dat","right.dat","bad.png","empty.png"]);_ = try await repo.commit(message:"inputs")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.ImageRouting."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        let oldPresenter=DiffToolApplication.presentBinary
        var windows:[NSWindowController]=[],reports=0
        defer {for window in windows{window.close()};DiffToolApplication.discardAll();DiffToolApplication.presentBinary=oldPresenter;prefs.removePersistentDomain(forName:suite)}
        DiffToolApplication.presentBinary={_ in reports += 1;return true}
        func reset() throws {try DiffToolPreferences().save(to:prefs)}
        func override(enabled:Bool) throws {
            var value=DiffToolPreferences(),association=DiffToolAssociation();association.pattern=".png";association.program.builtIn = .binaryReport;association.program.enabled=enabled
            value.associations=[association];try value.save(to:prefs)
        }
        func controller(_ left:String="left.png",_ right:String="right.PNG",alternate:Bool=false) throws -> FileComparisonWindowController {
            let value=FileComparisonWindowController(comparison:try WorkingFileComparison(base:root.appendingPathComponent(left),destination:root.appendingPathComponent(right)),permissions:[],preferences:prefs,deferInitialLoad:true)
            value.model.captureToolChoice(alternate);windows.append(value);return value
        }
        func load(_ owner:FileComparisonWindowController) async throws {owner.model.beginTransferredDocument();try await wait{!owner.model.busy && !owner.model.filtering};try require(owner.model.error==nil,"Native load failed: "+(owner.model.error ?? ""))}
        try reset()
        let normal=try controller();try await load(normal)
        try require(normal.model.viewerSelection == .image && normal.model.imageComparison?.base != nil && normal.window!.title.hasSuffix("TurtleGitIDiff"),"Default source extension did not select image viewer")
        try override(enabled:false);normal.model.load();try await wait{!normal.model.busy}
        try require(normal.model.imageComparison != nil && reports==0,"Reload reselected a tool from changed preferences")
        normal.close()
        try reset()
        let shifted=try controller(alternate:true);try await load(shifted)
        try require(shifted.model.imageComparison==nil && shifted.model.document?.destination.bytes==png && shifted.window!.title.hasSuffix("TurtleGitMerge"),"Shift was undone by image content sniffing");shifted.close()
        let opaque=try controller("left.dat","right.dat");try await load(opaque)
        try require(opaque.model.imageComparison==nil && opaque.model.document?.base.bytes==png,"Unregistered extension silently chose IDiff");opaque.close()
        let corrupt=try controller("left.png","bad.png");try await load(corrupt)
        try require(corrupt.model.imageComparison?.base != nil && corrupt.model.imageComparison?.destination==nil && corrupt.model.document?.destination.bytes==bad,"Undecodable image side switched to Merge");corrupt.close()
        let empty=try controller("empty.png","bad.png");try await load(empty)
        try require(empty.model.imageComparison != nil && empty.model.imageComparison?.base==nil && empty.model.imageComparison?.destination==nil,"Empty/unsupported image inputs lost image commands");empty.close()
        try override(enabled:false)
        let disabled=try controller();try await load(disabled)
        try require(disabled.model.imageComparison==nil && reports==0,"Disabled image association did not retain Merge");disabled.close()
        let alternate=try controller(alternate:true);try await load(alternate)
        try require(reports==1 && alternate.model.document==nil,"Shift did not activate disabled image association");alternate.close()
        try override(enabled:true)
        let enabled=try controller();try await load(enabled)
        try require(reports==2 && enabled.model.document==nil,"Enabled image association did not dispatch");enabled.close()
        let inverse=try controller(alternate:true);try await load(inverse)
        try require(reports==2 && inverse.model.imageComparison==nil,"Shift association bypass still selected image viewer");inverse.close()
        // Freeze actual tool selection before dispatch, even if Settings changes
        // inside the asynchronous launch seam.
        let frozen=try controller();let actual=frozen.model.openExternalComparison
        frozen.model.openExternalComparison={document,root,permissions,alternate in try reset();return try await actual(document,root,permissions,alternate)}
        try await load(frozen);try require(reports==3 && frozen.model.document==nil,"Dispatch reread Settings after selection capture");frozen.close()
        try override(enabled:true)
        let explicit=FileComparisonWindowController(images:try ImageFileComparison(base:root.appendingPathComponent("left.png"),destination:root.appendingPathComponent("bad.png")),permissions:[],preferences:prefs);windows.append(explicit)
        explicit.model.load();try await wait{!explicit.model.busy}
        try require(reports==3 && explicit.model.imageComparison != nil,"Explicit Load Images re-entered external associations");explicit.close()
        let forced=try controller();forced.model.useInternalMergeViewer();try await load(forced)
        try require(reports==3 && forced.model.imageComparison==nil && forced.model.document?.base.bytes==png,"Explicit Merge Open/source view re-entered tool routing");forced.close()
        try reset()
        let held=try controller();var answer:CheckedContinuation<Bool,Never>?
        held.model.openExternalComparison={_,_,_,_ in await withCheckedContinuation{answer=$0}}
        held.model.beginTransferredDocument();try await wait{answer != nil};held.close()
        try require(FileListComparisonSession.activeOperations>0,"Retired launch released actual operation too early")
        answer?.resume(returning:false);answer=nil;try await wait{!held.model.busy && FileListComparisonSession.activeOperations==0}
        try require(held.model.imageComparison==nil && held.model.document==nil,"Retired owner published a late image/text viewer")
        let retry=try controller();retry.model.openExternalComparison={_,_,_,_ in throw Failure(description:"injected launch failure")}
        retry.model.beginTransferredDocument();try await wait{!retry.model.busy}
        try require(retry.model.error != nil && retry.model.document==nil,"Failed tool unexpectedly fell back to IDiff")
        retry.model.openExternalComparison={_,_,_,_ in false};retry.model.captureToolChoice(true);try await load(retry)
        try require(retry.model.imageComparison==nil && retry.model.document?.destination.bytes==png,"Failed launch poisoned retry/alternate selection");retry.close()
        try require(try Data(contentsOf:root.appendingPathComponent("left.png"))==png,"Original image changed")
        let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout,finalIndex=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        try require(head==finalHead && index==finalIndex,"Routing changed HEAD/index")
        print("PASS: source image/Merge/tool precedence, captured Shift/Settings, reload, undecodable sides, explicit viewer isolation, failure retry and retired launch ownership; unchanged input/index/HEAD")
    }
}
