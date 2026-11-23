// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import TurtleGitCore

private extension NSWindow {
    @objc func quietClassicPathOrder(_ mode:NSWindow.OrderingMode,relativeTo number:Int) {alphaValue=0;setFrameOrigin(.init(x:-24000,y:-24000));quietClassicPathOrder(mode,relativeTo:number)}
    @objc func quietClassicPathSheet(_ sheet:NSWindow,completionHandler:((NSApplication.ModalResponse)->Void)?) {sheet.alphaValue=0;sheet.setFrameOrigin(.init(x:-24000,y:-24000));quietClassicPathSheet(sheet,completionHandler:completionHandler)}
}
@MainActor @main enum MetafileClassicPathVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ text:String,line:Int = #line)throws {if !value{throw Failure(description:"Classic paths \(line): "+text)}}
    static func wait(_ text:String,_ ready:()->Bool)async throws {for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:text)}
    static func drained()->Bool {FileListComparisonSession.activeOperations==0 && ImageComparisonViewModel.activeFileReads==0 && ImageConflictWindowModel.activeOperations==0 && ImageLoadWindowController.activeReleases==0}
    static func rgba(_ image:CGImage)throws->Data {
        var data=Data(count:image.width*image.height*4)
        let success=data.withUnsafeMutableBytes {memory->Bool in
            guard let ctx=CGContext(data:memory.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue)else{return false}
            ctx.interpolationQuality = .none;ctx.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));return true
        }
        try require(success,"Cannot inspect actual native classic path image");return data
    }
    @MainActor final class Context {
        let root:URL,git:URL,corpus:URL,suite:String,prefs:UserDefaults
        var owners:[NSWindowController]=[],previews:[ImageComparisonViewModel]=[],unblock:[()->Void]=[]
        init()throws {
            root=URL(fileURLWithPath:CommandLine.arguments[1]).standardizedFileURL;git=URL(fileURLWithPath:CommandLine.arguments[2]).standardizedFileURL;corpus=URL(fileURLWithPath:CommandLine.arguments[3]).standardizedFileURL
            suite="TurtleGit.ClassicPaths."+UUID().uuidString;prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"UseLibgit2");DialogGeometry.install(preferences:prefs)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        }
        func track<T:NSWindowController>(_ owner:T)->T {owners.append(owner);owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.showWindow(nil);return owner}
        func sample(_ name:String)throws->URL {let source=corpus.appendingPathComponent(name),target=root.appendingPathComponent(name);try Data(contentsOf:source).write(to:target);return target}
        func cleanup()async throws {
            previews.forEach{$0.retire()};owners.forEach{$0.close()};unblock.forEach{$0()};unblock=[]
            try await wait("Classic path native owners/helpers did not drain"){drained() && self.owners.allSatisfy{$0.window?.attachedSheet==nil && $0.window?.isVisible != true}}
            prefs.removePersistentDomain(forName:suite)
        }
    }
    static func consumers(_ c:Context)async throws {
        let pairs=[("polydraw16-cubic.emf","polydraw32-cubic.emf"),("widen-flat-fill.emf","widen-flat-fill-control.emf"),("flatten-active-save-restore.emf","flatten-active-save-restore-control.emf"),("widen-device-capture.emf","widen-device-capture-control.emf"),("widen-normal-thin.emf","widen-normal-thin-control.emf"),("widen-null.emf","widen-null-control.emf"),("widen-default-pen.emf","widen-default-pen-control.emf")]
        var sources:[Data]=[]
        for (leftName,rightName) in pairs {
            let left=try c.sample(leftName),right=try c.sample(rightName),bytes=try Data(contentsOf:left)
            let owner=c.track(FileComparisonWindowController(comparison:try WorkingFileComparison(base:left,destination:right),permissions:[],preferences:c.prefs));owner.model.load()
            try await wait("Classic path native comparison did not load: "+leftName){owner.window?.contentView?.layoutSubtreeIfNeeded();return !owner.model.busy && owner.model.document != nil}
            try require(owner.model.viewerSelection == .image && owner.model.document?.base.bytes==bytes,"Classic path default viewer lost original bytes")
            guard let a=owner.model.imageComparison?.base,let b=owner.model.imageComparison?.destination else{throw Failure(description:"Classic path native pair failed: "+leftName+"; "+(owner.model.error ?? "no error"))}
            try require(a.pixels.width==65 && a.pixels.height==65 && b.pixels.width==65 && b.pixels.height==65,"Native classic path allocation changed")
            let ar=try rgba(a.pixels),br=try rgba(b.pixels)
            let maxDelta=zip(ar,br).map{abs(Int($0)-Int($1))}.max() ?? 0
            try require(maxDelta<=2,"Native independent path controls differ: "+leftName+" max\(maxDelta)")
            try require(try Data(contentsOf:left)==bytes,"Native image viewing rewrote source metafile")
            sources.append(bytes);owner.close();try await wait("Classic path comparison close did not drain"){drained() && owner.window?.isVisible != true}
        }
        for name in ["refused-polydraw16-mixed-cubic.emf","refused-flatten-active.emf","refused-widen-body.emf"] {
            let url=try c.sample(name),bytes=try Data(contentsOf:url),owner=c.track(FileComparisonWindowController(images:try ImageFileComparison(base:url,destination:nil),permissions:[],preferences:c.prefs));owner.model.load()
            try await wait("Classic path refusal did not settle"){!owner.model.busy && owner.model.document != nil}
            try require(owner.model.viewerSelection == .image && owner.model.imageComparison?.base==nil && owner.model.document?.base.bytes==bytes,"Malformed classic path leaked an earlier painted prefix")
            owner.close();try await wait("Classic path refusal owner did not drain"){drained() && owner.window?.isVisible != true}
        }
        let folder=c.root.appendingPathComponent("conflict"),path="classic.emf"
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let repo=GitRepository(root:folder,executable:c.git,askpass:nil,libgit2Configuration:.init(enabled:false)),file=folder.appendingPathComponent(path)
        _=try await repo.run(["init","--template=","-b","main"])
        for(key,value)in[("user.name","Classic path QA"),("user.email","classic-path@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
        try sources[0].write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"Classic path source")
        var packet=Data("0 \(String(repeating:"0",count:40))\t\(path)\0".utf8)
        for (index,bytes) in sources.prefix(3).enumerated() {
            let oid=try await repo.run(["hash-object","-w","--stdin"],input:bytes).text.trimmingCharacters(in:.whitespacesAndNewlines)
            packet.append(Data("100644 \(oid) \(index+1)\t\(path)\0".utf8))
        }
        _=try await repo.run(["update-index","-z","--index-info"],input:packet);try sources[2].write(to:file)
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:folder.appendingPathComponent(".git/index")),working=try Data(contentsOf:file)
        guard let document=try await repo.imageConflictDocument(path:path)else{throw Failure(description:"Actual classic path conflict stages unavailable")}
        let owner=c.track(ImageConflictWindowController(repository:repo,access:nil,document:document,preferences:c.prefs))
        try await wait("Classic path actual three-stage images did not load"){!owner.model.busy && owner.model.images.count==3}
        for side in ImageConflictSide.allCases {try require(owner.model.canSelect(side) && owner.model.panes[side]?.currentImage(base:true)?.pixels.width==65,"Native classic path conflict pane missing: \(side)")}
        owner.model.reload();try await wait("Classic path conflict reload did not drain"){!owner.model.busy}
        try require(owner.model.document.contents[.base]==sources[0] && owner.model.document.contents[.theirs]==sources[2] && owner.model.document.contents[.mine]==sources[1],"Actual conflict stage identity/bytes changed")
        owner.close();try await wait("Classic path conflict owner did not drain"){drained() && owner.window?.isVisible != true}
        try require(try await repo.run(["rev-parse","HEAD"]).stdout==head && (try Data(contentsOf:folder.appendingPathComponent(".git/index")))==index && (try Data(contentsOf:file))==working,"Classic path image review mutated its repository")
        let drop=c.root.appendingPathComponent("dropped.emf");try sources[0].write(to:drop)
        let preview=ImageComparisonViewModel();c.previews.append(preview)
        try require(preview.dropFile(drop,base:true),"Actual classic path image drop refused")
        try await wait("Classic path dropped image did not decode"){preview.currentImage(base:true) != nil && ImageComparisonViewModel.activeFileReads==0}
        try require(preview.currentImage(base:true)?.pixels.width==65 && (try Data(contentsOf:drop))==sources[0],"Classic path drop changed original input")
        preview.retire()
    }
    static func ownership(_ c:Context)async throws {
        let url=try c.sample("widen-flat-fill.emf"),owner=c.track(FileComparisonWindowController(comparison:try WorkingFileComparison(base:url,destination:url),permissions:[],preferences:c.prefs,deferInitialLoad:true))
        var reply:CheckedContinuation<ImageComparisonDocument,Never>?,token:OperationCancellation?
        c.unblock.append{reply?.resume(returning:ImageComparisonDocument(base:nil,destination:nil));reply=nil}
        owner.model.decodeImages={_,operation in token=operation;return await withCheckedContinuation{reply=$0}}
        owner.model.beginTransferredDocument();try await wait("Owned classic path decoder did not suspend"){reply != nil}
        owner.close()
        try require(token?.isCancelled==true && FileListComparisonSession.activeOperations>0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Closing classic path owner released a live decoder")
        reply?.resume(returning:ImageComparisonDocument(base:nil,destination:nil));reply=nil
        try await wait("Retired classic path decoder did not drain"){!owner.model.busy && drained()}
        try require(owner.model.document==nil && owner.model.imageComparison==nil,"Retired classic path viewer accepted a late decode")
    }
    static func main()async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let a=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,b=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietClassicPathOrder(_:relativeTo:)))!,s=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.beginSheet(_:completionHandler:)))!,t=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.quietClassicPathSheet(_:completionHandler:)))!
        method_exchangeImplementations(a,b);method_exchangeImplementations(s,t);defer{method_exchangeImplementations(s,t);method_exchangeImplementations(a,b)}
        let selected=Set(CommandLine.arguments.dropFirst(4));try require(selected.isSubset(of:["consumers","ownership"]),"Unknown classic path cohort")
        let c=try Context()
        do {if selected.isEmpty || selected.contains("consumers"){try await consumers(c)};if selected.isEmpty || selected.contains("ownership"){try await ownership(c)};try await c.cleanup()}
        catch {do{try await c.cleanup()}catch let cleanup{throw Failure(description:"\(error); cleanup: \(cleanup)")};throw error}
        print("PASS: Classic EMF typed paths, flatten/widen native comparison/conflict/drop, malformed whole-image refusal, original-byte identity and owned decoder/Close/Quit drainage")
    }
}
