// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import CryptoKit
import TurtleGitCore

/// Actual native consumers and bundled decoder; expected pixels are independent
/// Windows Bitmap(file,FALSE) captures, never another local renderer invocation.
@MainActor enum MetafileSpatialEffectsVerification {
    typealias Shared=MetafileImageEffectsVerification
    struct CaptureParameters:Decodable,Equatable {
        let radius:Double?,expandEdge:Bool?,amount:Double?,numberOfAreas:Int?,areas:[[Int]]?
    }
    struct Item:Decodable {
        let file:String,family:String,referenceRGBA:String,rgbaSHA256:String
        let width:Int,height:Int,parameters:CaptureParameters
    }
    static var fullReferences:[String:Data]=[:]
    struct Manifest:Decodable {let cases:[Item]}
    struct CaptureCase:Decodable {
        let file:String,sourceSHA256:String,referenceRGBA:String,rgbaSHA256:String
        let width:Int,height:Int,samples:[Shared.Sample]
        let family:String,parameters:CaptureParameters
        var shared:Shared.ReferenceCase {.init(file:file,sourceSHA256:sourceSHA256,samples:samples,width:width,height:height)}
    }
    struct PlaybackContexts:Decodable {
        struct Replacement:Decodable {
            let file:String,sourceSHA256:String,previousReferenceRGBA:String,previousRGBA_SHA256:String
            let referenceCase:CaptureCase
            enum CodingKeys:String,CodingKey {
                case file,sourceSHA256,previousReferenceRGBA,previousRGBA_SHA256
                case referenceCase="case"
            }
        }
        let originalManifestSHA256:String
        let replacements:[Replacement],additionalCases:[CaptureCase]
    }
    static func loadContexts(_ c:Shared.Context,original:Data,manifest:Manifest)throws->[String] {
        let contexts=try JSONDecoder().decode(PlaybackContexts.self,from:Data(contentsOf:c.corpus.appendingPathComponent("playback-context-reference.json")))
        try Shared.require(SHA256.hash(data:original).map{String(format:"%02x",$0)}.joined()==contexts.originalManifestSHA256,"Changed original native context manifest")
        var selected:[String]=[]
        for replacement in contexts.replacements {
            guard let old=manifest.cases.first(where:{$0.file==replacement.file}),
                  let index=Shared.reference.firstIndex(where:{$0.file==replacement.file}) else {throw Shared.Failure(message:"Missing original stateful observation")}
            try Shared.require(old.referenceRGBA==replacement.previousReferenceRGBA && old.rgbaSHA256==replacement.previousRGBA_SHA256 && Shared.reference[index].sourceSHA256==replacement.sourceSHA256,"Changed original stateful context identity")
            let prior=try Data(contentsOf:c.corpus.appendingPathComponent(old.referenceRGBA))
            try Shared.require(SHA256.hash(data:prior).map{String(format:"%02x",$0)}.joined()==old.rgbaSHA256,"Changed prior stateful reference buffer")
            try Shared.require(replacement.referenceCase.file==replacement.file && replacement.referenceCase.sourceSHA256==replacement.sourceSHA256,"Fresh context retargeted source")
            try Shared.require(replacement.referenceCase.family==old.family && replacement.referenceCase.parameters==old.parameters && replacement.referenceCase.width==old.width && replacement.referenceCase.height==old.height,"Fresh context changed source dimensions/family/parameters")
            Shared.reference[index]=replacement.referenceCase.shared
        }
        for item in contexts.additionalCases {Shared.reference.append(item.shared)}
        for item in contexts.replacements.map(\.referenceCase)+contexts.additionalCases {
            try Shared.require(item.width>0 && item.height>0 && !item.samples.isEmpty && item.samples.allSatisfy{$0.rgba.count==4 && $0.rgba.allSatisfy{(0...255).contains($0)} && $0.tolerance==1 && $0.x>=0 && $0.y>=0 && $0.x<item.width && $0.y<item.height},"Invalid independent context samples")
            let wire=try Data(contentsOf:c.input(item.file))
            let expected=try Data(contentsOf:c.corpus.appendingPathComponent(item.referenceRGBA))
            try Shared.require(SHA256.hash(data:wire).map{String(format:"%02x",$0)}.joined()==item.sourceSHA256 && SHA256.hash(data:expected).map{String(format:"%02x",$0)}.joined()==item.rgbaSHA256 && expected.count==item.width*item.height*4,"Changed independent first-use/ROI reference")
            fullReferences[item.file]=expected;selected.append(item.file)
        }
        return selected
    }
    static func verify()async throws {
        let c=Shared.Context()
        do {
            let bytes=try Data(contentsOf:c.corpus.appendingPathComponent("windows-reference.json"))
            Shared.reference=try JSONDecoder().decode(Shared.Reference.self,from:bytes).cases
            let manifest=try JSONDecoder().decode(Manifest.self,from:bytes)
            try Shared.require(Set(manifest.cases.map(\.family))==Set(["blur","sharpen","redEyeCorrection"]),"Missing spatial effect family")
            for item in Shared.reference {
                let wire=try c.input(item.file)
                let digest=SHA256.hash(data:try Data(contentsOf:wire)).map{String(format:"%02x",$0)}.joined()
                try Shared.require(digest==item.sourceSHA256,"Changed independent spatial wire: "+item.file)
                try Shared.require(!item.samples.isEmpty && item.samples.allSatisfy{$0.rgba.count==4 && $0.tolerance==1 && $0.x>=0 && $0.y>=0 && $0.x<item.width && $0.y<item.height},"Invalid spatial reference samples")
            }
            let representatives=["blur-asymmetric-r6-e1.emf","sharpen-asymmetric-r7-a50.emf","eye-1.emf"]
            let noPaint=["paint-outside-negative.emf","paint-outside-positive.emf","paint-valid-then-outside.emf","paint-outside-then-valid.emf"]
            fullReferences=[:]
            let extra=try loadContexts(c,original:bytes,manifest:manifest)
            let selected=representatives+["blur-alpha-expanded-500.emf","blur-asymmetric-crop-scale.emf","eye-12.emf"]+noPaint+extra
            for name in noPaint {
                guard let record=manifest.cases.first(where:{$0.file==name}),let dimensions=Shared.reference.first(where:{$0.file==name}) else {throw Shared.Failure(message:"Missing no-paint native reference "+name)}
                let expected=try Data(contentsOf:c.corpus.appendingPathComponent(record.referenceRGBA))
                let digest=SHA256.hash(data:expected).map{String(format:"%02x",$0)}.joined()
                try Shared.require(digest==record.rgbaSHA256 && expected.count==dimensions.width*dimensions.height*4,"Changed full no-paint native raster "+name)
                try Shared.require(stride(from:0,to:expected.count,by:4).allSatisfy{Array(expected[$0..<$0+4])==[17,61,173,255]},"Native no-paint witness did not preserve its opaque sentinel "+name)
                fullReferences[name]=expected
            }
            try Shared.require(selected.allSatisfy{name in Shared.reference.contains{$0.file==name}},"Missing independent active/expanded/cropped/blank spatial witnesses")
            try await consumers(c,selected:selected)
            try await conflict(c,names:representatives)
            try c.unchanged();await c.clean()
            try Shared.require(Shared.drained() && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Owned spatial consumer resources did not drain")
            print("PASS: Blur, Sharpen and active RedEye correction; padded/cropped, native blank and opaque no-paint outcomes; actual IDiff routes, retirement and original-byte conflict resolution")
        } catch {await c.clean();throw error}
    }
    static func pixels(_ image:ComparisonImage?,_ expected:[Shared.Sample],_ name:String)throws {
        guard let image,let record=Shared.reference.first(where:{$0.file==name}) else {throw Shared.Failure(message:"Missing actual spatial image/reference "+name)}
        let width=image.pixels.width,height=image.pixels.height
        let rgbTolerance=1
        try Shared.require(width==record.width && height==record.height && !expected.isEmpty,"Spatial canvas/reference mismatch")
        try Shared.require(expected.allSatisfy{$0.tolerance==rgbTolerance},"Unexpected spatial RGB tolerance")
        var bytes=[UInt8](repeating:0,count:width*height*4)
        try bytes.withUnsafeMutableBytes {buffer in
            guard let color=CGColorSpace(name:CGColorSpace.sRGB),let context=CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:color,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else {throw Shared.Failure(message:"Spatial pixel inspection failed")}
            context.interpolationQuality = .none;context.draw(image.pixels,in:CGRect(x:0,y:0,width:width,height:height))
        }
        if let full=fullReferences[name] {
            try Shared.require(full.count==bytes.count,"Full raster extent mismatch "+name)
            try Shared.require(bytes.indices.allSatisfy{index in
                let channel=index%4,alpha=Int(full[index-channel+3])
                let expected=channel==3 ? alpha:Int((Double(Int(full[index])*alpha)/255).rounded())
                return abs(Int(bytes[index])-expected)<=1
            },"Independent Picture/SourceCopy full raster mismatch: "+name)
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
                try Shared.require(owner.model.viewerSelection == .image && owner.window?.title.hasSuffix("TurtleGitIDiff")==true,"Spatial file did not route to actual IDiff: "+(owner.model.error ?? "none"))
                try pixels(owner.model.imageComparison?.base,Shared.samples(name),name)
                try pixels(owner.model.imageComparison?.destination,Shared.samples(name),name)
                try Shared.require(owner.model.document?.base.bytes==c.inputs[source] && owner.model.document?.destination.bytes==c.inputs[source],"Native spatial comparison changed original bytes")
                owner.close();try await Shared.wait{Shared.drained()}
            }
        }
        for family in ["blur","sharpen","redEyeCorrection"] {
            let name="refused-"+family+"-late-invalid-after-paint.emf",source=try c.input(name)
            let owner=c.track(FileComparisonWindowController(images:try ImageFileComparison(base:source,destination:nil),permissions:[],preferences:c.preferences))
            owner.model.load();try await Shared.wait{!owner.model.busy && owner.model.document != nil}
            try Shared.require(owner.model.viewerSelection == .image && owner.model.imageComparison?.base==nil && owner.model.document?.base.bytes==c.inputs[source],"Malformed spatial record exposed partial paint or lost raw bytes: "+name)
            owner.close();try await Shared.wait{Shared.drained()}
        }
        let source=try c.input(selected[0])
        let owner=c.track(FileComparisonWindowController(comparison:try WorkingFileComparison(base:source,destination:source),permissions:[],preferences:c.preferences,deferInitialLoad:true))
        let decode=owner.model.decodeImages
        var reply:CheckedContinuation<Void,Never>?,token:OperationCancellation?
        owner.model.decodeImages={document,request in let actual=try await decode(document,request);token=request;await withCheckedContinuation{reply=$0};return actual}
        c.releases.append{reply?.resume();reply=nil}
        owner.model.beginTransferredDocument();try await Shared.wait{reply != nil};owner.close()
        try Shared.require(token?.isCancelled==true && FileListComparisonSession.activeOperations==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Spatial close lost actual-helper lifetime/Quit fence")
        reply?.resume();reply=nil;try await Shared.wait{Shared.drained() && !owner.model.busy}
        try Shared.require(owner.model.document==nil && owner.model.imageComparison==nil,"Retired spatial comparison published late pixels")
    }
    static func conflict(_ c:Shared.Context,names:[String])async throws {
        let originals=try names.map{try Data(contentsOf:c.input($0))}
        let root=c.base.appendingPathComponent("spatial-repository",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:c.git,askpass:nil,libgit2Configuration:.init(enabled:false))
        let path="spatial 雪.emf",file=root.appendingPathComponent(path)
        _=try await repo.run(["init","--template=","-b","main"])
        for(key,value)in[("user.name","Spatial QA"),("user.email","spatial@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_=try await repo.run(["config",key,value])}
        try originals[0].write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"base")
        _=try await repo.run(["switch","-c","side"]);try originals[1].write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"theirs")
        _=try await repo.run(["switch","main"]);try originals[2].write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"mine")
        do {_=try await repo.run(["merge","--no-edit","side"]);throw Shared.Failure(message:"Expected actual binary image conflict")}
        catch is GitFailure {}
        guard let document=try await repo.imageConflictDocument(path:path) else {throw Shared.Failure(message:"Missing actual spatial conflict stages")}
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),working=try Data(contentsOf:file),mergeHead=try Data(contentsOf:root.appendingPathComponent(".git/MERGE_HEAD"))
        let owner=c.track(ImageConflictWindowController(repository:repo,access:nil,document:document,preferences:c.preferences))
        try await Shared.wait{owner.window?.contentView?.layoutSubtreeIfNeeded();return !owner.model.busy && owner.model.images.count==3 && Shared.views(owner.window?.contentView).filter{$0 is ImageComparisonScrollView}.count==3}
        for(side,i)in [(ImageConflictSide.base,0),(.theirs,1),(.mine,2)] {
            try Shared.require(owner.model.canSelect(side),"Spatial conflict pane not selectable")
            try pixels(owner.model.panes[side]?.currentImage(base:true),Shared.samples(names[i]),names[i])
            try Shared.require(owner.model.document.contents[side]==originals[i],"Conflict stage bytes replaced by decoded PNG")
        }
        let previewHead=try await repo.run(["rev-parse","HEAD"]).stdout,previewIndex=try Data(contentsOf:root.appendingPathComponent(".git/index")),previewWorking=try Data(contentsOf:file)
        try Shared.require(previewHead==head && previewIndex==index && previewWorking==working,"Spatial preview mutated Git state")
        owner.model.askMarkResolved={_ in true};owner.model.select(.theirs)
        try await Shared.wait{!owner.model.busy && Shared.drained()}
        let saved=try Data(contentsOf:file),staged=try await repo.run(["show",":"+path]).stdout,unmerged=try await repo.run(["ls-files","--unmerged","--",path]).stdout
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterMerge=try Data(contentsOf:root.appendingPathComponent(".git/MERGE_HEAD"))
        try Shared.require(owner.model.error==nil && saved==originals[1] && staged==originals[1] && unmerged.isEmpty,"Spatial resolution failed to preserve original EMF bytes")
        try Shared.require(afterHead==head && afterMerge==mergeHead,"Spatial resolution committed or cleared merge metadata")
        owner.close()
    }
}
