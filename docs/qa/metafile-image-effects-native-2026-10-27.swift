// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import CryptoKit
import TurtleGitCore

@MainActor enum MetafileImageEffectsVerification {
    struct Failure:Error,LocalizedError {let message:String;var errorDescription:String?{message}}
    struct Sample:Decodable {
        let x:Int,y:Int,rgba:[Int],tolerance:Int
        let windowsRGBA:[Int]?
        // Original Picture(FILE,FALSE) alpha, including unpainted pixels. Older
        // compatibility-white samples are never substituted for native alpha.
        var original:[Int] {windowsRGBA ?? rgba}
        var red:Int {Int((Double(original[0]*original[3])/255).rounded())}
        var green:Int {Int((Double(original[1]*original[3])/255).rounded())}
        var blue:Int {Int((Double(original[2]*original[3])/255).rounded())}
        var alpha:Int {original[3]}
    }
    struct RawReference:Decodable {let file:String;let sha256:String}
    struct ReferenceCase:Decodable {
        let file:String;let sourceSHA256:String;let samples:[Sample];let width:Int;let height:Int;let windowsRGBA:RawReference?
        init(file:String,sourceSHA256:String,samples:[Sample],width:Int,height:Int,windowsRGBA:RawReference?=nil) {
            self.file=file;self.sourceSHA256=sourceSHA256;self.samples=samples;self.width=width;self.height=height;self.windowsRGBA=windowsRGBA
        }
    }
    struct Reference:Decodable {let cases:[ReferenceCase]}
    static let generalCubic="state-first-effect-persists.emf"
    static let generalContour="state-two-effects-save-restore.emf"
    static let generalCrossing="brightness-30-25.emf"
    static var reference:[ReferenceCase]=[]
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value {throw Failure(message:"\(line): "+message)}}
    static func wait(line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(message:"Image-effect native timeout at \(line)")
    }
    static func views(_ root:NSView?)->[NSView] {
        guard let root else{return []};var result=[root]
        let children=root.subviews as NSArray
        for index in 0..<children.count {if let child=children.object(at:index) as? NSView {result += views(child)}}
        return result
    }
    static func drained()->Bool {FileListComparisonSession.activeOperations==0 && ImageConflictWindowModel.activeOperations==0 && ImageComparisonViewModel.activeFileReads==0 && ImageLoadWindowController.activeReleases==0}
    static func samples(_ name:String)->[Sample] {reference.first{$0.file==name}?.samples ?? []}
    static var triangle:[Sample] {samples(triangleName)}
    static var rectangle:[Sample] {samples(rectangleName)}
    static var scanlines:[Sample] {samples(scanlineName)}
    static let scanlineName="state-seed.emf"
    static let triangleName="state-first-effect-persists.emf"
    static let rectangleName="state-two-effects-save-restore.emf"
    static func pixels(_ image:ComparisonImage?,_ expected:[Sample],_ name:String)throws {
        guard let image else {throw Failure(message:"Missing actual bundled decoder image "+name)}
        let width=image.pixels.width,height=image.pixels.height
        let record=reference.first{$0.file==name}
        try require(width==(record?.width ?? 65) && height==(record?.height ?? 65) && !expected.isEmpty,"Invalid helper canvas or empty oracle "+name)
        let bytes=try rgba(image.pixels)
        for sample in expected {
            let offset=(sample.y*width+sample.x)*4
            let actual=Array(bytes[offset..<(offset+4)])
            let channels=[sample.red,sample.green,sample.blue]
            try require((0..<3).allSatisfy{abs(Int(bytes[offset+$0])-channels[$0])<=sample.tolerance} && abs(Int(actual[3])-sample.alpha)<=sample.tolerance,"\(name) (\(sample.x),\(sample.y)) expected \(channels), actual \(actual)")
        }
    }
    static func rgba(_ image:CGImage)throws->[UInt8] {
        let width=image.width,height=image.height
        var bytes=[UInt8](repeating:0,count:width*height*4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let color=CGColorSpace(name:CGColorSpace.sRGB),let context=CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:color,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else {throw Failure(message:"Pixel inspection failed")}
            context.interpolationQuality = .none;context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
        }
        return bytes
    }
    static func alphaAndBackground(_ window:NSWindow,_ presentation:ImageWindowPresentation,_ images:[(ComparisonImage,String)])async throws {
        try require(!images.isEmpty,"Missing live alpha consumers")
        let before=try images.map {try rgba($0.0.pixels)}
        for (image,name) in images {
            let witnesses=samples(name)
            try require(witnesses.contains{$0.alpha==0} && witnesses.contains{$0.alpha>0 && $0.alpha<255},"Native oracle lacks transparent and partial-alpha witnesses: "+name)
            try pixels(image,witnesses,name)
        }
        window.appearance=NSAppearance(named:.aqua)
        presentation.chooseTransparentColor()
        try await wait{window.attachedSheet != nil && views(window.attachedSheet?.contentView).contains{$0 is NSColorWell}}
        guard let sheet=window.attachedSheet,let well=views(sheet.contentView).compactMap({$0 as? NSColorWell}).first else {throw Failure(message:"Missing owned Transparent color dialog")}
        try require(!sheet.isVisible || sheet.alphaValue==0,"Owned transparency question became visible")
        well.color=NSColor(deviceRed:0.2,green:0.4,blue:0.6,alpha:1)
        window.endSheet(sheet,returnCode:.alertFirstButtonReturn)
        try await wait {
            window.contentView?.layoutSubtreeIfNeeded()
            let panes=views(window.contentView).compactMap{$0 as? ImageComparisonScrollView}
            return window.attachedSheet==nil && presentation.transparentColor != nil && panes.count==images.count && panes.allSatisfy{$0.transparentColor==presentation.transparentColor}
        }
        let background=[51,102,153]
        guard let color=CGColorSpace(name:CGColorSpace.sRGB),let backdrop=CGColor(colorSpace:color,components:[0.2,0.4,0.6,1]) else {throw Failure(message:"Cannot prepare independent background")}
        for (index,pair) in images.enumerated() {
            let (image,name)=pair,width=image.pixels.width,height=image.pixels.height
            let after=try rgba(image.pixels)
            try require(after==before[index],"Transparency UI flattened or mutated decoded source alpha: "+name)
            guard let raster=ImageComparisonXOR.render(base:image.pixels,destination:nil,width:width,height:height,baseRect:CGRect(x:0,y:0,width:width,height:height),destinationRect:.zero,background:backdrop) else {throw Failure(message:"Shared native image raster failed")}
            let output=try rgba(raster)
            // Standard source-over on an independently chosen opaque color,
            // then the source viewer's inverse-XOR display. Use decoded bytes
            // already checked against Windows, rather than another renderer.
            for sample in samples(name).filter({$0.alpha==0 || $0.alpha>0 && $0.alpha<255}).prefix(24) {
                let offset=(sample.y*width+sample.x)*4,a=Int(after[offset+3])
                for channel in 0..<3 {
                    let over=min(255,Int(after[offset+channel])+(background[channel]*(255-a)+127)/255)
                    let expected=255 ^ (over ^ background[channel])
                    try require(abs(Int(output[offset+channel])-expected)<=1,"Shared raster ignored source alpha/background: \(name) (\(sample.x),\(sample.y))")
                }
                try require(output[offset+3]==255,"Display raster must own its opaque background")
            }
        }
    }
    @MainActor final class Context {
        let base=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),corpus=URL(fileURLWithPath:CommandLine.arguments[3])
        let suite="TurtleGit.ImageEffects."+UUID().uuidString,preferences:UserDefaults
        var owners:[NSWindowController]=[],inputs:[URL:Data]=[:],releases:[()->Void]=[]
        init(){preferences=UserDefaults(suiteName:suite)!;preferences.set(false,forKey:"UseLibgit2");DialogGeometry.install(preferences:preferences)}
        func input(_ name:String)throws->URL {let url=corpus.appendingPathComponent(name);inputs[url]=try Data(contentsOf:url);return url}
        func track<T:NSWindowController>(_ owner:T)->T {owners.append(owner);owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-20000,y:-20000));owner.showWindow(nil);return owner}
        func unchanged()throws {for(url,bytes)in inputs {try require(try Data(contentsOf:url)==bytes,"Decoder rewrote original fixture "+url.lastPathComponent)}}
        func clean()async {
            owners.forEach{$0.close()};releases.forEach{$0()};releases=[]
            for window in NSApp.windows {if let sheet=window.attachedSheet {sheet.isReleasedWhenClosed=false;window.endSheet(sheet,returnCode:.abort);for _ in 0..<100 {if sheet.sheetParent==nil {break};try? await Task.sleep(nanoseconds:10_000_000)};if sheet.sheetParent==nil {sheet.close()}};window.orderOut(nil);window.close()}
            for _ in 0..<3000 {if drained(){break};try? await Task.sleep(nanoseconds:10_000_000)}
            preferences.removePersistentDomain(forName:suite);DialogGeometry.install(preferences:.standard)
        }
    }
    static func consumers(_ c:Context)async throws {
        let pairs:[(String,String,[Sample],[Sample])]=[(scanlineName,triangleName,scanlines,triangle),(rectangleName,scanlineName,rectangle,scanlines),("brightness-30-25.emf","brightness--30--25.emf",samples("brightness-30-25.emf"),samples("brightness--30--25.emf")),(generalCubic,generalContour,samples(generalCubic),samples(generalContour)),(generalCrossing,generalCubic,samples(generalCrossing),samples(generalCubic)),("pending-effect-across-plain-draw.emf","pending-effect-save-restore-before-E.emf",samples("pending-effect-across-plain-draw.emf"),samples("pending-effect-save-restore-before-E.emf")),("pending-effect-container-before-E.emf","fallback-srgb-16bit.emf",samples("pending-effect-container-before-E.emf"),samples("fallback-srgb-16bit.emf"))]
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
                if leftName==scanlineName && rightName==triangleName {
                    guard let window=owner.window,let images=owner.model.imageComparison,let base=images.base,let destination=images.destination else {throw Failure(message:"Missing actual Compare alpha panes")}
                    try await alphaAndBackground(window,owner.model.imagePresentation,[(base,leftName),(destination,rightName)])
                    let previous=images.id
                    owner.model.load()
                    try await wait{!owner.model.busy && owner.model.imageComparison?.id != previous && owner.model.imageComparison != nil}
                    try pixels(owner.model.imageComparison?.base,leftPixels,leftName);try pixels(owner.model.imageComparison?.destination,rightPixels,rightName)
                }

                owner.close();try await wait{drained()}
            }
        }
        for name in ["refused-matrix-nan.emf","refused-lut-short.emf"] {
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
        let baseURL=try c.input(generalCrossing),theirsURL=try c.input(generalContour),mineURL=try c.input(generalCubic)
        let base=try Data(contentsOf:baseURL),theirs=try Data(contentsOf:theirsURL),mine=try Data(contentsOf:mineURL)
        let root=c.base.appendingPathComponent("repository",isDirectory:true);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:c.git,askpass:nil,libgit2Configuration:.init(enabled:false)),path="drawing [effects]; 雪.emf",file=root.appendingPathComponent(path)
        _=try await repo.run(["init","-b","main"])
        for(key,value)in[("user.name","Image effects QA"),("user.email","image@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_=try await repo.run(["config",key,value])}
        try base.write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"path base")
        _=try await repo.run(["switch","-c","side"]);try theirs.write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"focus theirs")
        _=try await repo.run(["switch","main"]);try mine.write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"multicolor mine")
        do {_=try await repo.run(["merge","--no-edit","side"]);throw Failure(message:"Expected real binary conflict")}
        catch is GitFailure {}
        guard let document=try await repo.imageConflictDocument(path:path) else {throw Failure(message:"Actual image conflict stages missing")}
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),working=try Data(contentsOf:file),mergeHead=try Data(contentsOf:root.appendingPathComponent(".git/MERGE_HEAD"))
        let owner=c.track(ImageConflictWindowController(repository:repo,access:nil,document:document,preferences:c.preferences))
        try await wait {owner.window?.contentView?.layoutSubtreeIfNeeded();return !owner.model.busy && owner.model.images.count==3 && views(owner.window?.contentView).filter{$0 is ImageComparisonScrollView}.count==3}
        try require(ImageConflictSide.allCases.allSatisfy{owner.model.canSelect($0)},"New image stages lost selectable native conflict panes")
        try pixels(owner.model.panes[.base]?.currentImage(base:true),samples(generalCrossing),generalCrossing)
        try pixels(owner.model.panes[.theirs]?.currentImage(base:true),samples(generalContour),generalContour)
        try pixels(owner.model.panes[.mine]?.currentImage(base:true),samples(generalCubic),generalCubic)
        try require(owner.model.document.contents[.base]==base && owner.model.document.contents[.theirs]==theirs && owner.model.document.contents[.mine]==mine,"Conflict displayed PNG replaced raw Git stages")
        guard let window=owner.window,let baseImage=owner.model.panes[.base]?.currentImage(base:true),let theirsImage=owner.model.panes[.theirs]?.currentImage(base:true),let mineImage=owner.model.panes[.mine]?.currentImage(base:true) else {throw Failure(message:"Missing actual conflict alpha panes")}
        try await alphaAndBackground(window,owner.model.presentation,[(baseImage,generalCrossing),(theirsImage,generalContour),(mineImage,generalCubic)])

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
    static func verify()async throws {
        let c=Context()
        reference=try JSONDecoder().decode(Reference.self,from:Data(contentsOf:c.corpus.appendingPathComponent("windows-reference.json"))).cases
        for item in reference {
            let wire=try Data(contentsOf:c.corpus.appendingPathComponent(item.file))
            try require(SHA256.hash(data:wire).map{String(format:"%02x",$0)}.joined()==item.sourceSHA256,"Windows reference wire changed: "+item.file)
            if let raw=item.windowsRGBA {
                let buffer=try Data(contentsOf:c.corpus.appendingPathComponent(raw.file))
                try require(buffer.count==item.width*item.height*4 && SHA256.hash(data:buffer).map{String(format:"%02x",$0)}.joined()==raw.sha256,"Original Windows RGBA changed: "+item.file)
                for sample in item.samples {
                    let offset=(sample.y*item.width+sample.x)*4
                    try require(Array(buffer[offset..<(offset+4)]).map(Int.init)==sample.original,"Native alpha sample no longer matches original Windows buffer: "+item.file)
                }
            }
        }
        try require(reference.allSatisfy{item in item.samples.allSatisfy{$0.rgba.count==4 && $0.original.count==4 && $0.original.allSatisfy{(0...255).contains($0)} && $0.x>=0 && $0.x<item.width && $0.y>=0 && $0.y<item.height}},"Invalid independent reference sample bounds")
        do {
            try await consumers(c);try await conflict(c)
            try c.unchanged();await c.clean()
            try require(drained() && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Owned image-effect native images/helpers did not drain")
        }catch {await c.clean();throw error}
    }
}
