// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func scanlineGradientHiddenOrder(_ place:NSWindow.OrderingMode,relativeTo number:Int) {
        alphaValue=0;setFrameOrigin(.init(x:-20000,y:-20000));scanlineGradientHiddenOrder(place,relativeTo:number)
    }
}
@MainActor @main enum MetafileScanlineGradientVerification {
    struct Failure:Error,LocalizedError {let message:String;var errorDescription:String?{message}}
    struct Sample {let x:Int,y:Int,red:Int,green:Int,blue:Int;var tolerance=1}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value {throw Failure(message:"\(line): "+message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(message:"Scanline/gradient native timeout at \(line)")
    }
    static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func drained()->Bool {FileListComparisonSession.activeOperations==0 && ImageConflictWindowModel.activeOperations==0 && ImageComparisonViewModel.activeFileReads==0 && ImageLoadWindowController.activeReleases==0}
    // Independent analytic pixel-center interpolation of the original fixture's
    // red/blue rectangle and red/green/blue triangle, away from covered edges.
    static let triangle=[Sample(x:16,y:16,red:165,green:45,blue:45,tolerance:2),Sample(x:40,y:12,red:58,green:173,blue:24,tolerance:2),Sample(x:56,y:56,red:255,green:255,blue:255)]
    static let rectangle=[Sample(x:20,y:32,red:189,green:0,blue:66,tolerance:2),Sample(x:44,y:32,red:61,green:0,blue:194,tolerance:2),Sample(x:4,y:4,red:255,green:255,blue:255)]
    // A 32x32 bottom-up DIB declares only physical scans 8..<16. At destination
    // (8,8) those eight rows paint y24..<32, not y8..<16 or a stretched32 rows.
    static let scanlines=[Sample(x:16,y:28,red:255,green:0,blue:0),Sample(x:16,y:20,red:255,green:255,blue:255),Sample(x:16,y:36,red:255,green:255,blue:255),Sample(x:4,y:28,red:255,green:255,blue:255)]
    static let scanlineName="classic-scanlines-partial-bottom.emf"
    static let triangleName="classic-gradient-triangle.emf"
    static let rectangleName="classic-gradient-rectangle-horizontal.emf"
    static func pixels(_ image:ComparisonImage?,_ expected:[Sample],_ name:String)throws {
        guard let image else {throw Failure(message:"Missing actual bundled decoder image "+name)}
        let width=image.pixels.width,height=image.pixels.height
        try require(width==64 && height==64 && !expected.isEmpty,"Invalid helper canvas or empty oracle "+name)
        var bytes=[UInt8](repeating:0,count:width*height*4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let color=CGColorSpace(name:CGColorSpace.sRGB),let context=CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:color,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else {throw Failure(message:"Pixel inspection failed")}
            context.interpolationQuality = .none;context.draw(image.pixels,in:CGRect(x:0,y:0,width:width,height:height))
        }
        for sample in expected {
            let offset=(sample.y*width+sample.x)*4
            let actual=Array(bytes[offset..<(offset+4)])
            let channels=[sample.red,sample.green,sample.blue]
            try require((0..<3).allSatisfy{abs(Int(bytes[offset+$0])-channels[$0])<=sample.tolerance} && actual[3]==255,"\(name) (\(sample.x),\(sample.y)) expected \(channels), actual \(actual)")
        }
    }
    @MainActor final class Context {
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),corpus=URL(fileURLWithPath:CommandLine.arguments[3])
        let suite="TurtleGit.ScanlineGradient."+UUID().uuidString,preferences:UserDefaults
        var owners:[NSWindowController]=[],inputs:[URL:Data]=[:],releases:[()->Void]=[]
        init(){preferences=UserDefaults(suiteName:suite)!;preferences.set(false,forKey:"UseLibgit2");DialogGeometry.install(preferences:preferences)}
        func input(_ name:String)throws->URL {let url=corpus.appendingPathComponent(name);inputs[url]=try Data(contentsOf:url);return url}
        func track<T:NSWindowController>(_ owner:T)->T {owners.append(owner);owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-20000,y:-20000));owner.showWindow(nil);return owner}
        func unchanged()throws {for(url,bytes)in inputs {try require(try Data(contentsOf:url)==bytes,"Decoder rewrote original fixture "+url.lastPathComponent)}}
        func clean()async {
            owners.forEach{$0.close()};releases.forEach{$0()};releases=[]
            for window in NSApp.windows {if let sheet=window.attachedSheet {window.endSheet(sheet,returnCode:.abort);sheet.close()};window.orderOut(nil);window.close()}
            for _ in 0..<3000 {if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)}
            preferences.removePersistentDomain(forName:suite);DialogGeometry.install(preferences:.standard)
        }
    }
    static func consumers(_ c:Context)async throws {
        let pairs:[(String,String,[Sample],[Sample])]=[(scanlineName,triangleName,scanlines,triangle),(rectangleName,scanlineName,rectangle,scanlines)]
        for explicit in [false,true] {
            for(leftName,rightName,leftPixels,rightPixels)in pairs {
                let left=try c.input(leftName),right=try c.input(rightName),owner:FileComparisonWindowController
                if explicit {owner=c.track(FileComparisonWindowController(images:try ImageFileComparison(base:left,destination:right),permissions:[],preferences:c.preferences))}
                else {owner=c.track(FileComparisonWindowController(comparison:try WorkingFileComparison(base:left,destination:right),permissions:[],preferences:c.preferences))}
                owner.model.load()
                try await wait {owner.window?.contentView?.layoutSubtreeIfNeeded();return !owner.model.busy && owner.model.document != nil && views(owner.window?.contentView).filter{$0 is ImageComparisonScrollView}.count==2}
                try require(owner.model.viewerSelection == .image && owner.window?.title.hasSuffix("TurtleGitIDiff")==true,"New records did not route to actual native IDiff: "+(owner.model.error ?? "none"))
                try pixels(owner.model.imageComparison?.base,leftPixels,leftName);try pixels(owner.model.imageComparison?.destination,rightPixels,rightName)
                try require(owner.model.document?.base.bytes==c.inputs[left] && owner.model.document?.destination.bytes==c.inputs[right],"Native view replaced original EMF bytes with PNG")
                owner.close();try await wait{drained()}
            }
        }
        for name in ["unsupported-scanlines-truncated-bits.emf","unsupported-gradient-classic-index-after-paint.emf"] {
            let source=try c.input(name)
            let owner=c.track(FileComparisonWindowController(images:try ImageFileComparison(base:source,destination:nil),permissions:[],preferences:c.preferences))
            owner.model.load();try await wait{!owner.model.busy && owner.model.document != nil}
            try require(owner.model.viewerSelection == .image && owner.model.imageComparison?.base==nil && owner.model.document?.base.bytes==c.inputs[source],"Malformed record exposed partial earlier paint or changed raw bytes: "+name)
            owner.close();try await wait{drained()}
        }
        // Hold only the owned receipt after the REAL helper returned its image.
        let source=try c.input(triangleName)
        let late=c.track(FileComparisonWindowController(comparison:try WorkingFileComparison(base:source,destination:source),permissions:[],preferences:c.preferences,deferInitialLoad:true))
        let decode=late.model.decodeImages
        var reply:CheckedContinuation<Void,Never>?,token:OperationCancellation?
        late.model.decodeImages={document,request in let actual=try await decode(document,request);token=request;await withCheckedContinuation{reply=$0};return actual}
        c.releases.append{reply?.resume();reply=nil};late.model.beginTransferredDocument();try await wait{reply != nil}
        late.close()
        try require(token?.isCancelled==true && FileListComparisonSession.activeOperations==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Closed comparison lost owned decode/cancellation/Quit fence")
        reply?.resume();reply=nil;try await wait{drained() && !late.model.busy}
        try require(late.model.document==nil && late.model.imageComparison==nil,"Retired comparison published late actual-helper pixels")
    }
    static func conflict(_ c:Context)async throws {
        let baseURL=try c.input(scanlineName),theirsURL=try c.input(rectangleName),mineURL=try c.input(triangleName)
        let base=try Data(contentsOf:baseURL),theirs=try Data(contentsOf:theirsURL),mine=try Data(contentsOf:mineURL)
        let root=c.base.appendingPathComponent("repository",isDirectory:true);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:c.git,askpass:nil,libgit2Configuration:.init(enabled:false)),path="drawing [scan]; 雪.emf",file=root.appendingPathComponent(path)
        _=try await repo.run(["init","-b","main"])
        for(key,value)in[("user.name","Scanline gradient QA"),("user.email","image@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_=try await repo.run(["config",key,value])}
        try base.write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"scanline base")
        _=try await repo.run(["switch","-c","side"]);try theirs.write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"rectangle theirs")
        _=try await repo.run(["switch","main"]);try mine.write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"triangle mine")
        do {_=try await repo.run(["merge","--no-edit","side"]);throw Failure(message:"Expected real binary conflict")}
        catch is GitFailure {}
        guard let document=try await repo.imageConflictDocument(path:path) else {throw Failure(message:"Actual image conflict stages missing")}
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),working=try Data(contentsOf:file),mergeHead=try Data(contentsOf:root.appendingPathComponent(".git/MERGE_HEAD"))
        let owner=c.track(ImageConflictWindowController(repository:repo,access:nil,document:document,preferences:c.preferences))
        try await wait {owner.window?.contentView?.layoutSubtreeIfNeeded();return !owner.model.busy && owner.model.images.count==3 && views(owner.window?.contentView).filter{$0 is ImageComparisonScrollView}.count==3}
        try require(ImageConflictSide.allCases.allSatisfy{owner.model.canSelect($0)},"New image stages lost selectable native conflict panes")
        try pixels(owner.model.panes[.base]?.currentImage(base:true),scanlines,"scanline conflict base")
        try pixels(owner.model.panes[.theirs]?.currentImage(base:true),rectangle,"gradient rectangle theirs")
        try pixels(owner.model.panes[.mine]?.currentImage(base:true),triangle,"gradient triangle mine")
        try require(owner.model.document.contents[.base]==base && owner.model.document.contents[.theirs]==theirs && owner.model.document.contents[.mine]==mine,"Conflict displayed PNG replaced raw Git stages")
        let ids=owner.model.images.mapValues(\.id),decode=owner.model.decodeImages
        var reply:CheckedContinuation<Void,Never>?,token:OperationCancellation?
        owner.model.decodeImages={document,request in let actual=try await decode(document,request);token=request;await withCheckedContinuation{reply=$0};return actual}
        c.releases.append{reply?.resume();reply=nil};owner.model.reload();try await wait{reply != nil};owner.close()
        try require(token?.isCancelled==true && owner.model.retired && ImageConflictWindowModel.activeOperations==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Closed conflict lost actual decode retirement/Quit ownership")
        reply?.resume();reply=nil;try await wait{drained()}
        try require(owner.model.images.mapValues(\.id)==ids,"Retired conflict replaced accepted native panes")
        let previewHead=try await repo.run(["rev-parse","HEAD"]).stdout,previewIndex=try Data(contentsOf:root.appendingPathComponent(".git/index")),previewWorking=try Data(contentsOf:file)
        try require(previewHead==head && previewIndex==index && previewWorking==working,"Preview/cancellation changed HEAD/index/working bytes")
        let accepted=c.track(ImageConflictWindowController(repository:repo,access:nil,document:document,preferences:c.preferences))
        accepted.model.askMarkResolved={_ in true};try await wait{!accepted.model.busy && accepted.model.images.count==3}
        accepted.model.select(.theirs);try await wait{!accepted.model.busy && drained()}
        let saved=try Data(contentsOf:file),staged=try await repo.run(["show",":"+path]).stdout,unmerged=try await repo.run(["ls-files","--unmerged","--",path]).stdout
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterMerge=try Data(contentsOf:root.appendingPathComponent(".git/MERGE_HEAD"))
        try require(accepted.model.error==nil && saved==theirs && staged==theirs && unmerged.isEmpty,"Accepted image resolution failed to stage original EMF bytes")
        try require(afterHead==head && afterMerge==mergeHead,"Image selection committed or cleared merge metadata")
        accepted.close()
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.scanlineGradientHiddenOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden);defer{method_exchangeImplementations(original,hidden)}
        let c=Context()
        do {
            let which=CommandLine.arguments[4]
            try await ComparisonToolInvocation.$alternate.withValue(false) {
                switch which {case "consumers":try await consumers(c);case "conflict":try await conflict(c);default:throw Failure(message:"Unknown native case")}
            }
            try c.unchanged();await c.clean();try require(drained() && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Owned native images/helpers did not drain")
            print("PASS: scanline gradient native "+which)
        }catch {await c.clean();throw error}
    }
}
