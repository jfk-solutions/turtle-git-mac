// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@MainActor enum MetafileRasterROIVerification {
    struct Failure:Error,LocalizedError {let message:String;var errorDescription:String?{message}}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws{if !value{throw Failure(message:"\(line): "+message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(message:"Raster workflow did not settle at \(line)")
    }
    static func views(_ view:NSView?)->[NSView]{guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    static func drained()->Bool{FileListComparisonSession.activeOperations==0 && ImageConflictWindowModel.activeOperations==0 && ImageComparisonViewModel.activeFileReads==0 && ImageLoadWindowController.activeReleases==0}
    static func gray(_ image:ComparisonImage?,_ samples:[(Int,Int,Int)],_ label:String)throws {
        guard let image else{throw Failure(message:"Missing decoded image: "+label)}
        let width=image.pixels.width,height=image.pixels.height
        try require(width==65 && height==65,"Incorrect raster canvas: "+label)
        var bytes=[UInt8](repeating:0,count:width*height*4)
        try bytes.withUnsafeMutableBytes{buffer in
            guard let space=CGColorSpace(name:CGColorSpace.sRGB),let context=CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else{throw Failure(message:"Cannot inspect native image pixels")}
            context.interpolationQuality = .none;context.draw(image.pixels,in:CGRect(x:0,y:0,width:width,height:height))
        }
        for(x,y,expected)in samples {
            let offset=(y*width+x)*4,pixel=Array(bytes[offset..<offset+4])
            try require((0..<3).allSatisfy{abs(Int(pixel[$0])-expected)<=1} && pixel[3]==255,"\(label) sample (\(x),\(y)) expected \(expected), actual \(pixel)")
        }
    }
    @MainActor final class Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),corpus=URL(fileURLWithPath:CommandLine.arguments[3])
        let suite:String,prefs:UserDefaults
        var owners:[NSWindowController]=[],inputs:[URL:Data]=[:],unblock:[()->Void]=[]
        init(){let name="TurtleGit.RasterROINative."+UUID().uuidString;suite=name;prefs=UserDefaults(suiteName:name)!;prefs.set(0,forKey:"AutoCloseGitProgress");DialogGeometry.install(preferences:prefs)}
        func sample(_ name:String)throws->URL {let file=corpus.appendingPathComponent(name);inputs[file]=try Data(contentsOf:file);return file}
        func track<T:NSWindowController>(_ owner:T)->T {owners.append(owner);owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-12000,y:-12000));owner.showWindow(nil);return owner}
        func unchanged()throws {for(file,bytes)in inputs{try require(try Data(contentsOf:file)==bytes,"Renderer rewrote captured fixture: "+file.lastPathComponent)}}
        func cleanup()async {
            owners.forEach{$0.close()};unblock.forEach{$0()};unblock=[]
            for _ in 0..<3000{if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)}
            owners.forEach{$0.window?.orderOut(nil)};prefs.removePersistentDomain(forName:suite);prefs.synchronize();DialogGeometry.install(preferences:.standard)
        }
    }
    static func run(_ body:(Context)async throws->Void)async throws {
        let context=Context()
        do{try await body(context);try context.unchanged();await context.cleanup();try require(drained(),"Native raster workers did not drain")}
        catch{await context.cleanup();throw error}
    }
    static func consumers()async throws {try await run{context in
        let state=[(12,12,102),(36,12,236),(12,44,85),(52,44,153)]
        let pairs:[(String,String,[(Int,Int,Int)],[(Int,Int,Int)])]=[
            ("classic-roi-checkpoint-interleave.emf","classic-roi-asymmetric-y.emf",state,[(44,46,64),(44,53,192),(6,9,102),(6,55,170)]),
            ("classic-roi-affine-crop.emf","classic-roi-saved-pattern.emf",[(30,14,192),(34,26,64),(20,10,170)],[(10,10,255),(11,10,0),(16,16,255),(36,12,170),(42,42,255),(43,42,0)]),
            ("classic-roi-pen-fallback.emf","classic-roi-offcanvas.emf",[(24,32,102),(24,40,170)],[(62,62,102),(62,4,170)])
        ]
        for(leftName,rightName,leftSamples,rightSamples)in pairs {
            let left=try context.sample(leftName),right=try context.sample(rightName)
            let owner=context.track(FileComparisonWindowController(images:try ImageFileComparison(base:left,destination:right),permissions:[],preferences:context.prefs))
            owner.model.load()
            try await wait{owner.window?.contentView?.layoutSubtreeIfNeeded();return !owner.model.busy && owner.model.document != nil && views(owner.window?.contentView).filter{$0 is ImageComparisonScrollView}.count==2}
            try require(owner.model.viewerSelection == .image && owner.window?.title.hasSuffix("TurtleGitIDiff")==true,"ROP inputs did not reach actual native IDiff panes: \(owner.model.error ?? "none")")
            try gray(owner.model.imageComparison?.base,leftSamples,leftName);try gray(owner.model.imageComparison?.destination,rightSamples,rightName)
            try require(owner.model.document?.base.bytes==context.inputs[left] && owner.model.document?.destination.bytes==context.inputs[right],"Native comparison replaced original WMF/EMF bytes")
            try require(!views(owner.window?.contentView).contains{($0 as? NSTextView).map{["Base file","Destination file"].contains($0.accessibilityLabel() ?? "")}==true},"Native ROP input fell back to text editor")
            owner.close();try await wait{FileListComparisonSession.activeOperations==0}
        }
        // A failed Boolean input keeps its exact bytes and explicit image route.
        let refused=try context.sample("unsupported-roi-offcanvas-payload.emf")
        let invalid=context.track(FileComparisonWindowController(images:try ImageFileComparison(base:refused,destination:nil),permissions:[],preferences:context.prefs))
        invalid.model.load();try await wait{!invalid.model.busy && invalid.model.document != nil}
        try require(invalid.model.viewerSelection == .image && invalid.model.imageComparison?.base==nil && invalid.model.document?.base.bytes==context.inputs[refused],"Invalid ROP lost native image route or original bytes")
        invalid.close()

        // Hold the receipt after the real ROP decoder has produced its image.
        // Closing must cancel the owned token and fence that late publication.
        let source=try context.sample("classic-roi-checkpoint-interleave.emf")
        let late=context.track(FileComparisonWindowController(comparison:try WorkingFileComparison(base:source,destination:source),permissions:[],preferences:context.prefs,deferInitialLoad:true))
        let decoder=late.model.decodeImages
        var reply:CheckedContinuation<Void,Never>?,token:OperationCancellation?
        late.model.decodeImages={document,request in
            let actual=try await decoder(document,request);token=request
            await withCheckedContinuation{reply=$0};return actual
        }
        context.unblock.append{reply?.resume();reply=nil}
        late.model.beginTransferredDocument();try await wait{reply != nil}
        try require(FileListComparisonSession.activeOperations==1,"ROP receipt lost owned comparison worker")
        late.close()
        try require(token?.isCancelled==true && FileListComparisonSession.activeOperations==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Closing released ROP worker/Quit ownership before its receipt")
        reply?.resume();reply=nil
        try await wait{FileListComparisonSession.activeOperations==0 && !late.model.busy}
        try require(late.model.document==nil && late.model.imageComparison==nil,"Closed ROP comparison published late decoded images")
    }}
    static func conflict()async throws {try await run{context in
        let baseURL=try context.sample("classic-roi-checkpoint-interleave.emf"),theirsURL=try context.sample("classic-roi-saved-pattern.emf"),mineURL=try context.sample("classic-roi-asymmetric-y.emf")
        let base=try Data(contentsOf:baseURL),theirs=try Data(contentsOf:theirsURL),mine=try Data(contentsOf:mineURL)
        let directory=context.root.appendingPathComponent("repository",isDirectory:true);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let repo=GitRepository(root:directory,executable:context.git),file=directory.appendingPathComponent("drawing.emf")
        _=try await repo.run(["init","-b","main"])
        for(key,value)in[("user.name","ROP conflict QA"),("user.email","raster@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
        try base.write(to:file);try await repo.stage(["drawing.emf"]);_=try await repo.commit(message:"Base checkpoint scene")
        _=try await repo.run(["switch","-c","side"]);try theirs.write(to:file);try await repo.stage(["drawing.emf"]);_=try await repo.commit(message:"Incoming saved pattern")
        _=try await repo.run(["switch","main"]);try mine.write(to:file);try await repo.stage(["drawing.emf"]);_=try await repo.commit(message:"Local asymmetric crop")
        do{_=try await repo.run(["merge","--no-edit","side"]);throw Failure(message:"Expected actual binary WMF/EMF conflict")}catch is GitFailure{}
        guard let document=try await repo.imageConflictDocument(path:"drawing.emf") else{throw Failure(message:"ROP conflict did not dispatch to image consumer")}
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:directory.appendingPathComponent(".git/index")),working=try Data(contentsOf:file)
        let owner=context.track(ImageConflictWindowController(repository:repo,access:nil,document:document,preferences:context.prefs))
        try await wait{owner.window?.contentView?.layoutSubtreeIfNeeded();return !owner.model.busy && owner.model.images.count==3 && views(owner.window?.contentView).filter{$0 is ImageComparisonScrollView}.count==3}
        try require(ImageConflictSide.allCases.allSatisfy{owner.model.canSelect($0)},"One Boolean metafile stage is not selectable")
        try gray(owner.model.panes[.base]?.currentImage(base:true),[(12,12,102),(36,12,236),(12,44,85),(52,44,153)],"Conflict base")
        try gray(owner.model.panes[.theirs]?.currentImage(base:true),[(10,10,255),(11,10,0),(16,16,255),(36,12,170),(42,42,255),(43,42,0)],"Conflict theirs")
        try gray(owner.model.panes[.mine]?.currentImage(base:true),[(44,46,64),(44,53,192),(6,9,102),(6,55,170)],"Conflict mine")
        try require(owner.model.document.contents[.base]==base && owner.model.document.contents[.theirs]==theirs && owner.model.document.contents[.mine]==mine,"Conflict rendering changed exact stage bytes")
        let prior=owner.model.images.mapValues(\.id),decoder=owner.model.decodeImages
        var reply:CheckedContinuation<Void,Never>?,token:OperationCancellation?
        owner.model.decodeImages={document,request in
            let actual=try await decoder(document,request);token=request
            await withCheckedContinuation{reply=$0};return actual
        }
        context.unblock.append{reply?.resume();reply=nil}
        owner.model.reload();try await wait{reply != nil}
        owner.close()
        try require(token?.isCancelled==true && owner.model.retired && ImageConflictWindowModel.activeOperations==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"ROP conflict close released pending decoder ownership")
        reply?.resume();reply=nil;try await wait{ImageConflictWindowModel.activeOperations==0}
        try require(owner.model.images.mapValues(\.id)==prior,"Retired ROP reload replaced accepted panes")
        try require(try await repo.run(["rev-parse","HEAD"]).stdout==head,"ROP conflict preview moved HEAD")
        try require((try Data(contentsOf:directory.appendingPathComponent(".git/index")))==index && (try Data(contentsOf:file))==working,"ROP conflict preview changed index/working bytes")
    }}
}
