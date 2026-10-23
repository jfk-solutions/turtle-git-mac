// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import ScreenCaptureKit
import TurtleGitCore

private extension NSWindow {
    @objc func drawingStateUnconstrainedFrame(_ requested:NSRect,to screen:NSScreen?)->NSRect {requested}
}
@MainActor enum MetafileDrawingStateVerification {
    struct Failure:Error,LocalizedError {let message:String;var errorDescription:String?{message}}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(message:message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(message:"Drawing-state native timeout at \(line)")
    }
    static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func drained()->Bool {FileListComparisonSession.activeOperations==0 && ImageConflictWindowModel.activeOperations==0 && ImageComparisonViewModel.activeFileReads==0 && ImageLoadWindowController.activeReleases==0}
    static func raster(_ image:CGImage)throws->Data {
        var bytes=Data(count:image.width*image.height*4)
        let painted=bytes.withUnsafeMutableBytes {buffer->Bool in
            guard let context=CGContext(data:buffer.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return false}
            context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));return true
        }
        try require(painted,"Native state-control raster unavailable");return bytes
    }
    static func placeOffscreen(_ window:NSWindow)throws {
        let screens=NSScreen.screens.map(\.frame)
        let union=screens.reduce(NSRect.null){$0.union($1)}
        let bounds=union.isNull ? NSRect.zero:union
        window.setFrameOrigin(NSPoint(x:bounds.minX-window.frame.width-1024,y:bounds.minY-window.frame.height-1024))
        try require(screens.allSatisfy{!$0.intersects(window.frame)},"Drawing-state window intersects a desktop screen: \(window.frame)")
    }
    static func capture(_ window:NSWindow,name:String)async throws {
        guard let path=ProcessInfo.processInfo.environment["TURTLEGIT_DRAWING_STATE_CAPTURES"] else{return}
        guard #available(macOS 14.4,*) else{throw Failure(message:"Owned compositor capture unavailable")}
        let appearance=window.appearance,alpha=window.alphaValue
        defer{window.alphaValue=alpha;window.appearance=appearance}
        window.orderFront(nil);try placeOffscreen(window);window.alphaValue=1
        try await Task.sleep(nanoseconds:600_000_000)
        for(theme,suffix)in[(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:theme);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:300_000_000)
            try require(window.isVisible && window.frame.width>=400 && window.frame.height>=200 && window.frame.width<=8192 && window.frame.height<=8192,"Owned drawing-state capture geometry invalid: \(window.frame), visible=\(window.isVisible)")
            var captured:CGImage?
            for attempt in 0..<3 {
                // A fresh current-process receipt avoids reusing a compositor
                // window snapshot after its backing store/appearance changes.
                window.alphaValue=1;window.contentView?.layoutSubtreeIfNeeded();window.displayIfNeeded()
                try placeOffscreen(window)
                let content=try await SCShareableContent.currentProcess
                guard let owned=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else{throw Failure(message:"Owned drawing-state window missing from compositor")}
                let configuration=SCStreamConfiguration();configuration.width=Int(window.frame.width*2);configuration.height=Int(window.frame.height*2);configuration.showsCursor=false;configuration.ignoreShadowsSingleWindow=true;configuration.includeChildWindows=false
                print("Drawing-state capture \(name)/\(suffix) attempt=\(attempt+1) window=\(window.windowNumber) frame=\(window.frame) compositor=\(owned.frame) alpha=\(window.alphaValue) visible=\(window.isVisible) pixels=\(configuration.width)x\(configuration.height)");fflush(stdout)
                do {
                    try require(NSScreen.screens.allSatisfy{!$0.frame.intersects(window.frame)},"Capture window moved onto a desktop screen")
                    captured=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:configuration);break
                }catch {
                    let failure=error as NSError
                    // The first checkpoint returned SCStreamErrorInternalError
                    // (-3811), not a permission denial. Retry only that bounded
                    // compositor-start failure, retaining real capture or error.
                    guard failure.domain=="com.apple.ScreenCaptureKit.SCStreamErrorDomain",failure.code == -3811,attempt<2 else{throw error}
                    print("Owned compositor internal start failure; refreshing current-process receipt before retry");fflush(stdout)
                    try await Task.sleep(nanoseconds:400_000_000)
                }
            }
            guard let image=captured else{throw Failure(message:"Owned compositor did not produce drawing-state pixels")}
            guard let png=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else{throw Failure(message:"Drawing-state capture encoding failed")}
            try png.write(to:URL(fileURLWithPath:path).appendingPathComponent(name+"-"+suffix+".png"))
        }
    }
    static func verify()async throws {
        // AppKit ordinarily moves an offscreen title bar back to a desktop
        // edge. This receiver-only, case-scoped override preserves the requested
        // frame while all test-owned windows exist; production is untouched.
        guard let constrain=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.constrainFrameRect(_:to:))),let unconstrained=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.drawingStateUnconstrainedFrame(_:to:))) else{throw Failure(message:"Owned offscreen frame override unavailable")}
        method_exchangeImplementations(constrain,unconstrained)
        defer{method_exchangeImplementations(constrain,unconstrained)}
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),corpus=URL(fileURLWithPath:CommandLine.arguments[3])
        let suite="TurtleGit.DrawingState."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        DialogGeometry.install(preferences:prefs)
        var owners:[NSWindowController]=[],inputs:[URL:Data]=[:]
        func sample(_ name:String)throws->URL {let url=corpus.appendingPathComponent(name);inputs[url]=try Data(contentsOf:url);return url}
        func track<T:NSWindowController>(_ owner:T)throws->T {owners.append(owner);owner.window?.alphaValue=0;owner.showWindow(nil);if let window=owner.window {try placeOffscreen(window)};return owner}
        func cleanup()async {owners.forEach{$0.close()};for _ in 0..<3000 {if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)};owners.forEach{$0.window?.orderOut(nil)};prefs.removePersistentDomain(forName:suite);DialogGeometry.install(preferences:.standard)}
        do {
            // Authored serialized state and explicit recorded-object controls
            // are supplied by the same independent fixture corpus as Core.
            let pairs:[(String,String)]=[
                ("classic-dc-stock-consumers.emf","classic-dc-stock-consumers-control.emf"),
                ("classic-default-palette-profile.emf","classic-default-palette-profile-control.emf"),
                ("wmf-default-palette-state.wmf","wmf-default-palette-state-control.wmf")
            ]
            try require(pairs.count>=3,"Drawing-state representative pair contract missing")
            var conflictInputs:[Data]=[],controlRasters:[Data]=[]
            var controlSizes:[(Int,Int)]=[]
            for(index,pair)in pairs.enumerated() {
                let left=try sample(pair.0),right=try sample(pair.1)
                let owner=try track(FileComparisonWindowController(images:try ImageFileComparison(base:left,destination:right),permissions:[],preferences:prefs));owner.model.load()
                try await wait{owner.window?.contentView?.layoutSubtreeIfNeeded();return !owner.model.busy && owner.model.document != nil && views(owner.window?.contentView).filter{$0 is ImageComparisonScrollView}.count==2}
                guard let a=owner.model.imageComparison?.base?.pixels,let b=owner.model.imageComparison?.destination?.pixels else{throw Failure(message:"Actual IDiff could not render drawing state: \(pair); \(owner.model.error ?? "none")")}
                try require(a.width==b.width && a.height==b.height && (try raster(a)) == (try raster(b)),"Native drawing state differs from independent explicit control: \(pair)")
                try require(owner.model.viewerSelection == .image && owner.model.document?.base.bytes==inputs[left] && owner.model.document?.destination.bytes==inputs[right],"Native drawing-state route replaced original records")
                conflictInputs.append(try Data(contentsOf:left));controlRasters.append(try raster(b));controlSizes.append((b.width,b.height))
                if index==0,let window=owner.window {try await capture(window,name:"metafile-drawing-state-compare")}
                owner.close()
            }
            let refused=["unsupported-drawing-state-palette-index.emf","unsupported-drawing-state-hardware-entry.emf","unsupported-drawing-state-wmf-stock-18.wmf"]
            try require(!refused.isEmpty,"Drawing-state refusal contract missing")
            for name in refused {
                let url=try sample(name),owner=try track(FileComparisonWindowController(images:try ImageFileComparison(base:url,destination:nil),permissions:[],preferences:prefs));owner.model.load()
                try await wait{!owner.model.busy && owner.model.document != nil}
                try require(owner.model.viewerSelection == .image && owner.model.imageComparison?.base==nil && owner.model.document?.base.bytes==inputs[url],"Unsupported drawing state escaped whole-image refusal or lost source bytes")
                owner.close()
            }
            let work=root.appendingPathComponent("state-conflict"),path="drawing.emf",file=work.appendingPathComponent(path)
            try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true)
            let repo=GitRepository(root:work,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false))
            _=try await repo.run(["init","--template=","-b","main"])
            for(key,value)in[("user.name","Drawing state QA"),("user.email","state@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_=try await repo.run(["config",key,value])}
            try conflictInputs[0].write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"state base")
            _=try await repo.run(["switch","-c","side"]);try conflictInputs[1].write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"state theirs")
            _=try await repo.run(["switch","main"]);try conflictInputs[2].write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"state mine")
            do{_=try await repo.run(["merge","--no-edit","side"]);throw Failure(message:"Expected genuine metafile conflict")}catch is GitFailure{}
            guard let document=try await repo.imageConflictDocument(path:path) else{throw Failure(message:"Drawing state did not dispatch actual conflict stages")}
            let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:work.appendingPathComponent(".git/index")),working=try Data(contentsOf:file)
            let conflict=try track(ImageConflictWindowController(repository:repo,access:nil,document:document,preferences:prefs))
            try await wait{!conflict.model.busy}
            try require(conflict.model.images.count==3 && ImageConflictSide.allCases.allSatisfy{conflict.model.canSelect($0) && conflict.model.panes[$0]?.currentImage(base:true) != nil},"Actual three-stage drawing-state images failed")
            for(side,sourceIndex)in [(ImageConflictSide.base,0),(.theirs,1),(.mine,2)] {
                guard let image=conflict.model.panes[side]?.currentImage(base:true)?.pixels else{throw Failure(message:"Conflict stage image missing")}
                try require(image.width==controlSizes[sourceIndex].0 && image.height==controlSizes[sourceIndex].1 && (try raster(image))==controlRasters[sourceIndex],"Conflict stage did not retain independent drawing-context state: \(side)")
            }
            conflict.model.reload();try await wait{!conflict.model.busy}
            try require(conflict.model.images.count==3 && conflict.model.document.contents[.base]==conflictInputs[0] && conflict.model.document.contents[.theirs]==conflictInputs[1] && conflict.model.document.contents[.mine]==conflictInputs[2],"Conflict reload replaced original drawing-state encodings")
            if let window=conflict.window {try await capture(window,name:"metafile-drawing-state-conflict")}
            let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout
            try require(head==finalHead && index==(try Data(contentsOf:work.appendingPathComponent(".git/index"))) && working==(try Data(contentsOf:file)),"Drawing-state review mutated actual conflict")
            for(url,bytes)in inputs {try require(try Data(contentsOf:url)==bytes,"Drawing-state rendering modified input corpus")}
            await cleanup();try require(drained() && owners.allSatisfy{$0.window?.isVisible != true && $0.window?.attachedSheet==nil},"Drawing-state owners/decoder work did not drain")
            print("PASS: classic drawing-state actual Compare/control rasters, whole-image refusal, three-stage conflict/reload and original bytes with owned teardown")
        }catch {await cleanup();throw error}
    }
}
