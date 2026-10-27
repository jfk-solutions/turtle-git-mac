// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import CryptoKit
import TurtleGitCore

/// Actual native consumers and bundled decoder; expected pixels are independent
/// Windows Bitmap(file,FALSE) captures, never another local renderer invocation.
@MainActor enum MetafilePointwiseEffectsVerification {
    typealias Shared=MetafileImageEffectsVerification
    struct Item:Decodable {
        let file:String
        let family:String?
        let profile:String?
        let parameters:[String:Int]?
    }
    struct Manifest:Decodable {let cases:[Item];let states:[Item]}
    struct StateReference:Decodable {let states:[Shared.ReferenceCase]}
    static var tintFiles=Set<String>()
    static let families=["colorBalance","hueSaturationLightness","levels","colorCurve","tint"]
    static func verify()async throws {
        let c=Shared.Context()
        do {
            let bytes=try Data(contentsOf:c.corpus.appendingPathComponent("windows-reference.json"))
            Shared.reference=try JSONDecoder().decode(Shared.Reference.self,from:bytes).cases
            Shared.reference += try JSONDecoder().decode(StateReference.self,from:bytes).states
            let manifest=try JSONDecoder().decode(Manifest.self,from:bytes)
            let metadata=manifest.cases
            tintFiles=Set(metadata.filter{$0.family=="tint"}.map(\.file))
            for item in Shared.reference {
                let wire=try c.input(item.file)
                let digest=SHA256.hash(data:try Data(contentsOf:wire)).map{String(format:"%02x",$0)}.joined()
                try Shared.require(digest==item.sourceSHA256,"Changed independent pointwise wire: "+item.file)
                try Shared.require(!item.samples.isEmpty && item.samples.allSatisfy{$0.rgba.count==4 && $0.x>=0 && $0.y>=0 && $0.x<item.width && $0.y<item.height},"Invalid pointwise reference samples")
            }
            var representatives=[String]()
            for family in families {
                guard let item=metadata.first(where:{$0.family==family && $0.profile=="normative" && !isEndpoint($0)}) else {throw Shared.Failure(message:"Missing normative family "+family)}
                representatives.append(item.file)
            }
            guard let ignored=metadata.first(where:{$0.family=="colorCurve" && $0.profile=="recordedIgnored"}) else {throw Shared.Failure(message:"Missing measured ignored-serialization Curve")}
            let endpoints=metadata.filter{isEndpoint($0) && $0.profile=="normative"}.map(\.file)
            try Shared.require(endpoints.count==8,"Expected all8 measured normative Curve endpoint fallback profiles")
            let states=manifest.states.map(\.file)
            try Shared.require(states.count==3,"Missing three independently measured effect-consumption witnesses")
            let selected=representatives+[ignored.file]+endpoints+states
            try await consumers(c,selected:selected)
            try await conflict(c,names:Array(representatives.prefix(3)))
            try c.unchanged();await c.clean()
            try Shared.require(Shared.drained() && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Owned pointwise consumer resources did not drain")
            print("PASS: all five pointwise effects, correct/ignored Curve GUIDs and endpoint fallbacks, measured pending-effect witnesses, actual IDiff routes, retirement and original-byte conflict resolution")
        } catch {await c.clean();throw error}
    }
    static func isEndpoint(_ item:Item)->Bool {
        guard item.family=="colorCurve",let p=item.parameters else{return false}
        return p["adjustment"]==6 && p["adjustValue"]==0 || p["adjustment"]==7 && p["adjustValue"]==255
    }
    static func pixels(_ image:ComparisonImage?,_ expected:[Shared.Sample],_ name:String)throws {
        guard let image,let record=Shared.reference.first(where:{$0.file==name}) else {throw Shared.Failure(message:"Missing actual pointwise image/reference "+name)}
        let width=image.pixels.width,height=image.pixels.height
        let rgbTolerance=tintFiles.contains(name) ? 3:1
        try Shared.require(width==record.width && height==record.height && !expected.isEmpty,"Pointwise canvas/reference mismatch")
        try Shared.require(expected.allSatisfy{$0.tolerance==rgbTolerance},"Unexpected pointwise RGB tolerance")
        var bytes=[UInt8](repeating:0,count:width*height*4)
        try bytes.withUnsafeMutableBytes {buffer in
            guard let color=CGColorSpace(name:CGColorSpace.sRGB),let context=CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:color,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else {throw Shared.Failure(message:"Pointwise pixel inspection failed")}
            context.interpolationQuality = .none;context.draw(image.pixels,in:CGRect(x:0,y:0,width:width,height:height))
        }
        for sample in expected {
            let offset=(sample.y*width+sample.x)*4,channels=[sample.red,sample.green,sample.blue]
            let actual=Array(bytes[offset..<offset+4])
            try Shared.require((0..<3).allSatisfy{abs(Int(actual[$0])-channels[$0])<=rgbTolerance} && abs(Int(actual[3])-sample.alpha)<=1,"\(name) (\(sample.x),\(sample.y)) expectedRGB \(channels) alpha\(sample.alpha), actual\(actual)")
        }
    }
    static func consumers(_ c:Shared.Context,selected:[String])async throws {
        for explicit in [false,true] {
            for name in selected {
                let source=try c.input(name),owner:FileComparisonWindowController
                if explicit {owner=c.track(FileComparisonWindowController(images:try ImageFileComparison(base:source,destination:source),permissions:[],preferences:c.preferences))}
                else {owner=c.track(FileComparisonWindowController(comparison:try WorkingFileComparison(base:source,destination:source),permissions:[],preferences:c.preferences))}
                owner.model.load()
                try await Shared.wait {owner.window?.contentView?.layoutSubtreeIfNeeded();return !owner.model.busy && owner.model.document != nil && Shared.views(owner.window?.contentView).filter{$0 is ImageComparisonScrollView}.count==2}
                try Shared.require(owner.model.viewerSelection == .image && owner.window?.title.hasSuffix("TurtleGitIDiff")==true,"Pointwise file did not route to actual IDiff: "+(owner.model.error ?? "none"))
                try pixels(owner.model.imageComparison?.base,Shared.samples(name),name)
                try pixels(owner.model.imageComparison?.destination,Shared.samples(name),name)
                try Shared.require(owner.model.document?.base.bytes==c.inputs[source] && owner.model.document?.destination.bytes==c.inputs[source],"Native pointwise comparison changed original bytes")
                owner.close();try await Shared.wait{Shared.drained()}
            }
        }
        for family in families {
            let name="refused-"+family+"-late-invalid-after-paint.emf",source=try c.input(name)
            let owner=c.track(FileComparisonWindowController(images:try ImageFileComparison(base:source,destination:nil),permissions:[],preferences:c.preferences))
            owner.model.load();try await Shared.wait{!owner.model.busy && owner.model.document != nil}
            try Shared.require(owner.model.viewerSelection == .image && owner.model.imageComparison?.base==nil && owner.model.document?.base.bytes==c.inputs[source],"Malformed pointwise record exposed partial paint or lost raw bytes: "+name)
            owner.close();try await Shared.wait{Shared.drained()}
        }
        let source=try c.input(selected[0])
        let owner=c.track(FileComparisonWindowController(comparison:try WorkingFileComparison(base:source,destination:source),permissions:[],preferences:c.preferences,deferInitialLoad:true))
        let decode=owner.model.decodeImages
        var reply:CheckedContinuation<Void,Never>?,token:OperationCancellation?
        owner.model.decodeImages={document,request in let actual=try await decode(document,request);token=request;await withCheckedContinuation{reply=$0};return actual}
        c.releases.append{reply?.resume();reply=nil}
        owner.model.beginTransferredDocument();try await Shared.wait{reply != nil};owner.close()
        try Shared.require(token?.isCancelled==true && FileListComparisonSession.activeOperations==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Pointwise close lost actual-helper lifetime/Quit fence")
        reply?.resume();reply=nil;try await Shared.wait{Shared.drained() && !owner.model.busy}
        try Shared.require(owner.model.document==nil && owner.model.imageComparison==nil,"Retired pointwise comparison published late pixels")
    }
    static func conflict(_ c:Shared.Context,names:[String])async throws {
        let originals=try names.map{try Data(contentsOf:c.input($0))}
        let root=c.base.appendingPathComponent("pointwise-repository",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:c.git,askpass:nil,libgit2Configuration:.init(enabled:false))
        let path="pointwise 雪.emf",file=root.appendingPathComponent(path)
        _=try await repo.run(["init","--template=","-b","main"])
        for(key,value)in[("user.name","Pointwise QA"),("user.email","pointwise@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_=try await repo.run(["config",key,value])}
        try originals[0].write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"base")
        _=try await repo.run(["switch","-c","side"]);try originals[1].write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"theirs")
        _=try await repo.run(["switch","main"]);try originals[2].write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"mine")
        do {_=try await repo.run(["merge","--no-edit","side"]);throw Shared.Failure(message:"Expected actual binary image conflict")}
        catch is GitFailure {}
        guard let document=try await repo.imageConflictDocument(path:path) else {throw Shared.Failure(message:"Missing actual pointwise conflict stages")}
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),working=try Data(contentsOf:file),mergeHead=try Data(contentsOf:root.appendingPathComponent(".git/MERGE_HEAD"))
        let owner=c.track(ImageConflictWindowController(repository:repo,access:nil,document:document,preferences:c.preferences))
        try await Shared.wait{owner.window?.contentView?.layoutSubtreeIfNeeded();return !owner.model.busy && owner.model.images.count==3 && Shared.views(owner.window?.contentView).filter{$0 is ImageComparisonScrollView}.count==3}
        for(side,i)in [(ImageConflictSide.base,0),(.theirs,1),(.mine,2)] {
            try Shared.require(owner.model.canSelect(side),"Pointwise conflict pane not selectable")
            try pixels(owner.model.panes[side]?.currentImage(base:true),Shared.samples(names[i]),names[i])
            try Shared.require(owner.model.document.contents[side]==originals[i],"Conflict stage bytes replaced by decoded PNG")
        }
        let previewHead=try await repo.run(["rev-parse","HEAD"]).stdout,previewIndex=try Data(contentsOf:root.appendingPathComponent(".git/index")),previewWorking=try Data(contentsOf:file)
        try Shared.require(previewHead==head && previewIndex==index && previewWorking==working,"Pointwise preview mutated Git state")
        owner.model.askMarkResolved={_ in true};owner.model.select(.theirs)
        try await Shared.wait{!owner.model.busy && Shared.drained()}
        let saved=try Data(contentsOf:file),staged=try await repo.run(["show",":"+path]).stdout,unmerged=try await repo.run(["ls-files","--unmerged","--",path]).stdout
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterMerge=try Data(contentsOf:root.appendingPathComponent(".git/MERGE_HEAD"))
        try Shared.require(owner.model.error==nil && saved==originals[1] && staged==originals[1] && unmerged.isEmpty,"Pointwise resolution failed to preserve original EMF bytes")
        try Shared.require(afterHead==head && afterMerge==mergeHead,"Pointwise resolution committed or cleared merge metadata")
        owner.close()
    }
}
