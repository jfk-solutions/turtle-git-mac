// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import CryptoKit
import TurtleGitCore

/// Native workflows consume independent recorded-mode sample receipts. Expected
/// samples are authored from the checkerboard geometry/Windows phase observation,
/// never from TurtleGit's sampler or its renderer output.
@MainActor enum MetafileImageInterpolationVerification {
    typealias Shared=MetafileImageEffectsVerification
    struct Failure:Error,LocalizedError {let message:String;var errorDescription:String?{message}}
    struct Sample:Decodable {let x:Int,y:Int,rgba:[Int],tolerance:Int}
    struct Entry:Decodable {let file:String,sourceSHA256:String;let width:Int,height:Int;let samples:[Sample]}
    struct Roles:Decodable {let nearest:String,bilinear:String,state:String,affine:String}
    struct Reference:Decodable {let cases:[Entry],refused:[String],nativeRoles:Roles}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value {throw Failure(message:"Interpolation \(line): "+message)}}
    static func pixels(_ image:ComparisonImage?,_ entry:Entry)throws {
        guard let image else {throw Failure(message:"Missing actual native interpolation image: "+entry.file)}
        try require(image.pixels.width==entry.width && image.pixels.height==entry.height,"Natural interpolation canvas changed: "+entry.file)
        let bytes=try Shared.rgba(image.pixels)
        for sample in entry.samples {
            let offset=(sample.y*entry.width+sample.x)*4
            // The independent manifest is already premultiplied sRGB8, matching
            // the inspection CGContext. Never associate source alpha twice.
            let expected=sample.rgba
            let actual=Array(bytes[offset..<(offset+4)]).map(Int.init)
            try require(zip(actual,expected).allSatisfy{abs($0-$1)<=sample.tolerance},"\(entry.file) (\(sample.x),\(sample.y)) expected premultiplied \(expected), got \(actual)")
        }
    }
    @MainActor final class Context {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),corpus=URL(fileURLWithPath:CommandLine.arguments[3])
        let suite="TurtleGit.ImageInterpolation."+UUID().uuidString,prefs:UserDefaults,reference:Reference
        var entries:[String:Entry]=[:],inputs:[URL:Data]=[:],owners:[NSWindowController]=[],unblock:[()->Void]=[]
        init()throws {
            prefs=UserDefaults(suiteName:suite)!;prefs.set(false,forKey:"UseLibgit2");DialogGeometry.install(preferences:prefs)
            reference=try JSONDecoder().decode(Reference.self,from:Data(contentsOf:corpus.appendingPathComponent("native-reference.json")))
            try require(!reference.cases.isEmpty && Set(reference.cases.map(\.file)).count==reference.cases.count,"Missing or repeated interpolation cases")
            for entry in reference.cases {
                try require(entry.width>0 && entry.height>0 && !entry.samples.isEmpty && entry.samples.allSatisfy{$0.x>=0 && $0.y>=0 && $0.x<entry.width && $0.y<entry.height && $0.rgba.count==4 && $0.rgba.allSatisfy{(0...255).contains($0)} && (0...2).contains($0.tolerance)},"Invalid independent interpolation samples: "+entry.file)
                entries[entry.file]=entry
                let bytes=try input(entry.file)
                try require(SHA256.hash(data:bytes.1).map{String(format:"%02x",$0)}.joined()==entry.sourceSHA256.lowercased(),"Recorded interpolation wire changed: "+entry.file)
            }
            let roles=reference.nativeRoles
            try require([roles.nearest,roles.bilinear,roles.state,roles.affine].allSatisfy{entries[$0] != nil},"Explicit native interpolation roles are absent")
            try require(reference.refused.count>=4 && Set(reference.refused).count==reference.refused.count && reference.refused.allSatisfy{entries[$0]==nil},"Invalid refused interpolation inventory")
            guard let nearest=entries[roles.nearest],let bilinear=entries[roles.bilinear] else {throw Failure(message:"Missing nearest/bilinear controls")}
            try require(nearest.samples.contains {a in bilinear.samples.contains{b in a.x==b.x && a.y==b.y && a.rgba != b.rgba}},"Independent samples do not distinguish nearest from bilinear")
        }
        func input(_ name:String)throws->(URL,Data) {
            let url=corpus.appendingPathComponent(name),data=try Data(contentsOf:url);inputs[url]=data;return(url,data)
        }
        func entry(_ name:String)throws->Entry {guard let value=entries[name] else {throw Failure(message:"Unmapped interpolation role "+name)};return value}
        func track<T:NSWindowController>(_ owner:T)->T {owners.append(owner);owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.showWindow(nil);return owner}
        func unchanged()throws {for(url,bytes)in inputs {try require(try Data(contentsOf:url)==bytes,"Native interpolation consumer rewrote source "+url.lastPathComponent)}}
        func cleanup()async {
            owners.forEach{$0.close()};unblock.forEach{$0()};unblock=[]
            for window in NSApp.windows {if let sheet=window.attachedSheet {window.endSheet(sheet,returnCode:.abort)};window.orderOut(nil);window.close()}
            for _ in 0..<3000 {if Shared.drained(){break};try? await Task.sleep(nanoseconds:10_000_000)}
            prefs.removePersistentDomain(forName:suite);DialogGeometry.install(preferences:.standard)
        }
    }
    static func ready(_ owner:FileComparisonWindowController)async throws {
        try await Shared.wait(diagnostic:{"busy=\(owner.model.busy), error=\(owner.model.error ?? "none")"}) {
            owner.window?.contentView?.layoutSubtreeIfNeeded()
            return !owner.model.busy && owner.model.document != nil && Shared.views(owner.window?.contentView).filter{$0 is ImageComparisonScrollView}.count==2
        }
        try require(owner.model.viewerSelection == .image && owner.window?.title.hasSuffix("TurtleGitIDiff")==true,"Interpolation record did not route to ordinary native IDiff")
    }
    static func consumers(_ c:Context)async throws {
        let roles=c.reference.nativeRoles,nearest=try c.entry(roles.nearest),left=try c.input(roles.nearest)
        // Every positive mode/state/crop/affine receipt reaches the ordinary
        // file-comparison consumer with its original EMF bytes intact.
        for entry in c.reference.cases {
            let right=try c.input(entry.file)
            let owner=c.track(FileComparisonWindowController(comparison:try WorkingFileComparison(base:left.0,destination:right.0),permissions:[],preferences:c.prefs,deferInitialLoad:true))
            owner.model.beginTransferredDocument();try await ready(owner)
            try pixels(owner.model.imageComparison?.base,nearest);try pixels(owner.model.imageComparison?.destination,entry)
            try require(owner.model.document?.base.bytes==left.1 && owner.model.document?.destination.bytes==right.1,"Ordinary interpolation Compare replaced original EMF bytes")
            owner.close();try await Shared.wait{Shared.drained()}
        }
        let bilinear=try c.entry(roles.bilinear),affine=try c.entry(roles.affine),right=try c.input(roles.bilinear),drop=try c.input(roles.affine)
        let owner=c.track(FileComparisonWindowController(images:try ImageFileComparison(base:left.0,destination:right.0),permissions:[],preferences:c.prefs))
        owner.model.load();try await ready(owner)
        try pixels(owner.model.imageComparison?.base,nearest);try pixels(owner.model.imageComparison?.destination,bilinear)
        let old=owner.model.imageComparison?.id
        try require(owner.model.imageViewerModel.commandState(.reload).enabled,"Actual image Reload was unavailable")
        owner.model.imageViewerModel.perform(.reload);try require(owner.model.busy,"Interpolation Reload was not admitted")
        try await Shared.wait{!owner.model.busy && owner.model.imageComparison?.id != old};try await ready(owner)
        try pixels(owner.model.imageComparison?.base,nearest);try pixels(owner.model.imageComparison?.destination,bilinear)
        let viewer=owner.model.imageViewerModel
        try require(viewer.dropFile(drop.0,base:true),"Actual affine image drop was refused")
        try await Shared.wait{!viewer.receivingDrop && viewer.droppedFiles[true] != nil}
        try require(viewer.dropError==nil && viewer.droppedFiles[true]?.bytes==drop.1,"Affine preview drop lost original wire bytes")
        try pixels(viewer.currentImage(base:true),affine);try pixels(viewer.currentImage(base:false),bilinear)
        try require(owner.model.document?.base.bytes==left.1 && owner.model.document?.destination.bytes==right.1,"Preview drop rewrote the underlying comparison document")
        let droppedID=owner.model.imageComparison?.id
        viewer.perform(.reload);try await Shared.wait{!owner.model.busy && owner.model.imageComparison?.id != droppedID && viewer.droppedFiles.isEmpty}
        try pixels(viewer.currentImage(base:true),nearest);try pixels(viewer.currentImage(base:false),bilinear)
        owner.close();try await Shared.wait{Shared.drained()}
        // Valid state enums with unsupported kernels, and malformed setter
        // records, retain an explicit unavailable image and the original bytes.
        for name in c.reference.refused {
            let input=try c.input(name),refused=c.track(FileComparisonWindowController(images:try ImageFileComparison(base:input.0,destination:nil),permissions:[],preferences:c.prefs))
            refused.model.load();try await Shared.wait{!refused.model.busy && refused.model.document != nil}
            try require(refused.model.viewerSelection == .image && refused.model.imageComparison?.base==nil && refused.model.imageViewerModel.currentImage(base:true)==nil && refused.model.document?.base.bytes==input.1,"Unsupported interpolation exposed earlier partial paint or lost original source: "+name)
            refused.close();try await Shared.wait{Shared.drained()}
        }
        // Hold only the completion receipt AFTER the real bundled decoder ran.
        let late=c.track(FileComparisonWindowController(comparison:try WorkingFileComparison(base:left.0,destination:right.0),permissions:[],preferences:c.prefs,deferInitialLoad:true))
        let decoder=late.model.decodeImages
        var reply:CheckedContinuation<Void,Never>?,token:OperationCancellation?
        late.model.decodeImages={document,request in let actual=try await decoder(document,request);token=request;await withCheckedContinuation{reply=$0};return actual}
        c.unblock.append{reply?.resume();reply=nil};late.model.beginTransferredDocument();try await Shared.wait{reply != nil}
        late.close()
        try require(token?.isCancelled==true && FileListComparisonSession.activeOperations==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Closed interpolation Compare lost actual decoder/Quit ownership")
        reply?.resume();reply=nil;try await Shared.wait{Shared.drained() && !late.model.busy}
        try require(late.model.document==nil && late.model.imageComparison==nil,"Retired interpolation Compare published late pixels")
    }
    static func conflict(_ c:Context)async throws {
        let roles=c.reference.nativeRoles,base=try c.input(roles.nearest),theirs=try c.input(roles.bilinear),mine=try c.input(roles.state)
        let root=c.root.appendingPathComponent("repository");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:c.git,askpass:nil,libgit2Configuration:.init(enabled:false)),path="recorded interpolation 雪.emf",file=root.appendingPathComponent(path)
        _=try await repo.run(["init","-b","main"])
        for(key,value)in[("user.name","Image interpolation QA"),("user.email","interpolation@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","false")] {_=try await repo.run(["config",key,value])}
        try base.1.write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"nearest base")
        _=try await repo.run(["switch","-c","side"]);try theirs.1.write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"bilinear theirs")
        _=try await repo.run(["switch","main"]);try mine.1.write(to:file);try await repo.stage([path]);_=try await repo.commit(message:"saved state mine")
        do {_=try await repo.run(["merge","--no-edit","side"]);throw Failure(message:"Expected actual binary interpolation conflict")}
        catch is GitFailure {}
        guard let document=try await repo.imageConflictDocument(path:path) else {throw Failure(message:"Actual interpolation conflict stages absent")}
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),working=try Data(contentsOf:file),mergeHead=try Data(contentsOf:root.appendingPathComponent(".git/MERGE_HEAD"))
        let owner=c.track(ImageConflictWindowController(repository:repo,access:nil,document:document,preferences:c.prefs))
        try await Shared.wait{owner.window?.contentView?.layoutSubtreeIfNeeded();return !owner.model.busy && owner.model.images.count==3 && Shared.views(owner.window?.contentView).filter{$0 is ImageComparisonScrollView}.count==3}
        try require(ImageConflictSide.allCases.allSatisfy{owner.model.canSelect($0)},"Interpolation conflict lost selectable original stages")
        try pixels(owner.model.panes[.base]?.currentImage(base:true),c.entry(roles.nearest));try pixels(owner.model.panes[.theirs]?.currentImage(base:true),c.entry(roles.bilinear));try pixels(owner.model.panes[.mine]?.currentImage(base:true),c.entry(roles.state))
        try require(owner.model.document.contents[.base]==base.1 && owner.model.document.contents[.theirs]==theirs.1 && owner.model.document.contents[.mine]==mine.1,"Conflict interpolation replaced original Git stages with rendered pixels")
        let ids=owner.model.images.mapValues(\.id),decoder=owner.model.decodeImages
        var reply:CheckedContinuation<Void,Never>?,token:OperationCancellation?
        owner.model.decodeImages={document,request in let actual=try await decoder(document,request);token=request;await withCheckedContinuation{reply=$0};return actual}
        c.unblock.append{reply?.resume();reply=nil}
        try require(owner.model.commandState(.reload)?.enabled==true,"Actual conflict Reload unavailable")
        owner.model.perform(.reload);try require(owner.model.busy && owner.model.decoding,"Conflict interpolation Reload was not admitted")
        try await Shared.wait{reply != nil};owner.close()
        try require(token?.isCancelled==true && owner.model.retired && ImageConflictWindowModel.activeOperations==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Closed conflict interpolation lost real decoder ownership")
        reply?.resume();reply=nil;try await Shared.wait{Shared.drained()}
        try require(owner.model.images.mapValues(\.id)==ids,"Retired conflict interpolation replaced accepted panes")
        let previewHead=try await repo.run(["rev-parse","HEAD"]).stdout,previewIndex=try Data(contentsOf:root.appendingPathComponent(".git/index")),previewWorking=try Data(contentsOf:file)
        try require(previewHead==head && previewIndex==index && previewWorking==working,"Interpolation preview/cancellation changed HEAD/index/working bytes")
        let accepted=c.track(ImageConflictWindowController(repository:repo,access:nil,document:document,preferences:c.prefs))
        accepted.model.askMarkResolved={_ in true};try await Shared.wait{!accepted.model.busy && accepted.model.images.count==3}
        accepted.model.select(.theirs);try await Shared.wait{!accepted.model.busy && Shared.drained()}
        let saved=try Data(contentsOf:file),staged=try await repo.run(["show",":"+path]).stdout,unmerged=try await repo.run(["ls-files","--unmerged","--",path]).stdout
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterMerge=try Data(contentsOf:root.appendingPathComponent(".git/MERGE_HEAD"))
        try require(accepted.model.error==nil && saved==theirs.1 && staged==theirs.1 && unmerged.isEmpty,"Image resolution did not stage original bilinear EMF bytes")
        try require(afterHead==head && afterMerge==mergeHead,"Interpolation image choice committed or cleared Merge metadata")
        accepted.close()
    }
    static func verify()async throws {
        let c=try Context()
        do {try await consumers(c);try await conflict(c);try c.unchanged();await c.cleanup();try require(Shared.drained() && NSApp.windows.allSatisfy{!$0.isVisible && $0.attachedSheet==nil},"Native interpolation consumers left owned work/windows")}
        catch {await c.cleanup();throw error}
        print("PASS: recorded interpolation native mode/state/affine Compare, Reload, drop, refusal, original-byte conflict resolution and cancellation ownership")
    }
}
