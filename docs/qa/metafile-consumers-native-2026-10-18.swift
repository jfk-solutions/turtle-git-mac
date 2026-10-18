// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import UniformTypeIdentifiers
import TurtleGitCore

private final class MetafileConsumerScopeLog {var starts=0,stops=0}
private final class MetafileConsumerBookmarks:RepositoryBookmarkProvider {
    let log:MetafileConsumerScopeLog
    init(_ log:MetafileConsumerScopeLog) {self.log=log}
    func create(for url:URL)throws->Data {Data(url.path.utf8)}
    func resolve(_ data:Data)throws->ResolvedBookmark {ResolvedBookmark(url:URL(fileURLWithPath:String(decoding:data,as:UTF8.self)),stale:false)}
    func startAccessing(_ url:URL)->Bool {log.starts += 1;return true}
    func stopAccessing(_ url:URL) {log.stops += 1}
}
@MainActor enum MetafileConsumersVerification {
    struct Failure:Error,LocalizedError {let message:String;var errorDescription:String? {message}}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(message:message)}}
    static func wait(line:Int = #line,diagnostic:()->String={""},_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(message:"Metafile consumers did not settle at \(line); \(diagnostic())")
    }
    static func descendants(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(descendants)}
    static func verify()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),corpus=URL(fileURLWithPath:CommandLine.arguments[3])
        let corpusFiles=try FileManager.default.contentsOfDirectory(at:corpus,includingPropertiesForKeys:nil).filter { ["wmf","emf"].contains($0.pathExtension.lowercased()) }.sorted {$0.lastPathComponent < $1.lastPathComponent}
        let nativeSamples:Set<String>=["clip-vector.wmf","classic-vector.emf","classic-bitmap.emf","plus-transform.emf","plus-bitmap-text.emf","plus-compressed-crop.emf","plus-gradient-transform.emf","plus-image-attributes.emf","plus-region-path.emf","plus-region-state.emf","plus-hatch-atlas.emf","plus-texture-world.emf","plus-region-texture.emf"]
        let samples=corpusFiles.filter {nativeSamples.contains($0.lastPathComponent)},unsupported=corpusFiles.filter {$0.lastPathComponent.hasPrefix("unsupported-")}
        try require(samples.count == nativeSamples.count,"Representative native metafile corpus incomplete")
        try require(samples.contains {$0.pathExtension.lowercased()=="wmf"} && samples.filter {$0.pathExtension.lowercased()=="emf"}.count >= 2 && samples.contains {$0.lastPathComponent.lowercased().contains("plus")},"Provide representative WMF, EMF and EMF+ corpus files")
        let inputs=try samples.map {try Data(contentsOf:$0)},bad=Data("unsupported image side\n".utf8)
        let suite="TurtleGit.MetafileConsumers.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(0,forKey:"AutoCloseGitProgress");DialogGeometry.install(preferences:prefs)
        defer {prefs.removePersistentDomain(forName:suite);DialogGeometry.install(preferences:.standard)}
        var owners:[NSWindowController]=[],previewModels:[ImageComparisonViewModel]=[]
        var comparisonHold:CheckedContinuation<ImageComparisonDocument,Never>?,dropHold:CheckedContinuation<ComparisonImage?,Never>?,conflictHold:CheckedContinuation<[ImageConflictSide:ComparisonImage],Never>?
        func track<T:NSWindowController>(_ owner:T)->T {owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-12000,y:-12000));owners.append(owner);return owner}
        func comparisonState(_ owner:FileComparisonWindowController)->String {
            let model=owner.model,views=owner.window?.contentView.map(descendants) ?? []
            return "busy=\(model.busy) filtering=\(model.filtering) deferred=\(model.initialLoadDeferred) viewer=\(model.viewerSelection) images=\(model.imageComparison != nil) baseImage=\(String(describing:model.imageComparison?.base?.size)) destinationImage=\(String(describing:model.imageComparison?.destination?.size)) document=\(model.document != nil) imagePanes=\(views.filter {$0 is ImageComparisonScrollView}.count) textEditors=\(views.compactMap {$0 as? NSTextView}.filter {["Base file","Destination file"].contains($0.accessibilityLabel() ?? "")}.count) title=\(owner.window?.title ?? "none") error=\(model.error ?? "none") sessions=\(FileListComparisonSession.activeOperations) drops=\(ImageComparisonViewModel.activeFileReads) conflicts=\(ImageConflictWindowModel.activeOperations) chooserReleases=\(ImageLoadWindowController.activeReleases)"
        }
        func drained()->Bool {FileListComparisonSession.activeOperations==0 && ImageComparisonViewModel.activeFileReads==0 && ImageConflictWindowModel.activeOperations==0 && ImageLoadWindowController.activeReleases==0}
        func cleanup()async throws {
            for case let owner as FileComparisonWindowController in owners {owner.model.makeImageLoader={ImageLoadWindowController(leftPath:$0,permissions:$1)}}
            previewModels.forEach {$0.retire()};owners.forEach {$0.close()}
            comparisonHold?.resume(returning:ImageComparisonDocument(base:nil,destination:nil));comparisonHold=nil
            dropHold?.resume(returning:nil);dropHold=nil
            conflictHold?.resume(returning:[:]);conflictHold=nil
            try await wait {drained() && owners.allSatisfy {$0.window?.attachedSheet == nil && $0.window?.isVisible != true}}
        }
        do {
            // Default filename dispatch and explicit IDiff remain image viewers
            // even if one side is empty/unsupported. Source bytes remain intact.
            var first:FileComparisonWindowController?
            for (index,sample) in samples.enumerated() {
                let left=root.appendingPathComponent("sample-\(index)."+sample.pathExtension),right=root.appendingPathComponent("unsupported-\(index)."+sample.pathExtension)
                try inputs[index].write(to:left);try bad.write(to:right)
                let owner=track(FileComparisonWindowController(comparison:try WorkingFileComparison(base:left,destination:right),permissions:[],preferences:prefs))
                owner.model.load();try await wait {owner.window?.contentView?.layoutSubtreeIfNeeded();return !owner.model.busy && owner.model.document != nil}
                if !(owner.model.viewerSelection == .image && owner.model.imageComparison?.base != nil && owner.model.imageComparison?.destination == nil) {
                    let failedState=comparisonState(owner),bytes=inputs[index]
                    let inputMatches=owner.model.document?.base.bytes == bytes && owner.model.document?.destination.bytes == bad
                    // Diagnostic only: never replace the failed native result or
                    // relax its assertion with a successful second conversion.
                    let conversion=await Task.detached { ()->String in
                        do {
                            let helper=try MetafileImageDecoder.executable()
                            guard let svg=try MetafileImageDecoder.convert(bytes) else {return "helper=\(helper.path) convert=nil format=\(String(describing:MetafileImageFormat.identify(bytes)))"}
                            let native=NSImage(data:svg),pixels=native?.cgImage(forProposedRect:nil,context:nil,hints:nil)
                            return "helper=\(helper.path) svgBytes=\(svg.count) nativeSize=\(String(describing:native?.size)) rasterWidth=\(String(describing:pixels?.width)) rasterHeight=\(String(describing:pixels?.height)) svgPrefix=\(String(reflecting:String(decoding:svg.prefix(160),as:UTF8.self)))"
                        } catch {return "conversionError=\(String(reflecting:error)) description=\(error.localizedDescription)"}
                    }.value
                    throw Failure(message:"Default metafile route or unsupported-side IDiff policy failed for \(sample.lastPathComponent); original=\(failedState); inputMatches=\(inputMatches); directDiagnostic=\(conversion); afterDiagnostic=\(comparisonState(owner))")
                }
                try await wait {owner.window?.contentView?.layoutSubtreeIfNeeded();return descendants(owner.window!.contentView!).filter {$0 is ImageComparisonScrollView}.count == 2}
                try require(!descendants(owner.window!.contentView!).contains {($0 as? NSTextView).map {["Base file","Destination file"].contains($0.accessibilityLabel() ?? "")} == true},"IDiff installed a Merge text editor")
                try require(owner.model.imageComparison?.base?.pixels.width == 96 && owner.model.imageComparison?.base?.pixels.height == 64 && owner.window?.title.hasSuffix("TurtleGitIDiff") == true,"Metafile was not rendered at its actual dimensions in native IDiff")
                try require(owner.model.document?.base.bytes == inputs[index] && owner.model.document?.destination.bytes == bad && (try Data(contentsOf:left)) == inputs[index] && (try Data(contentsOf:right)) == bad,"Metafile rendering rewrote original bytes")
                if first == nil {first=owner} else {owner.close()}
            }
            for sample in unsupported {
                let bytes=try Data(contentsOf:sample),owner=track(FileComparisonWindowController(images:try ImageFileComparison(base:sample,destination:nil),permissions:[],preferences:prefs))
                owner.model.load();try await wait {!owner.model.busy && owner.model.document != nil}
                try require(owner.model.viewerSelection == .image && owner.model.imageComparison != nil && owner.model.imageComparison?.base == nil && owner.model.imageComparison?.destination == nil && owner.model.document?.base.bytes == bytes,"Unsupported metafile escaped explicit IDiff or lost original bytes; \(comparisonState(owner))")
                owner.close()
            }
            guard let first else {throw Failure(message:"No metafile comparison")}
            let original=first.model.document!,pane=first.model.imageViewerModel,drop=root.appendingPathComponent("preview.emf")
            let preview=try firstSample(samples,withExtension:"emf"),previewBytes=try Data(contentsOf:preview)
            try previewBytes.write(to:drop)
            try require(pane.dropFile(drop,base:false),"Metafile pane drop refused")
            try await wait {!pane.receivingDrop}
            try require(pane.currentImage(base:false) != nil && pane.droppedFiles[false]?.bytes == previewBytes && first.model.document?.destination.bytes == bad,"Metafile preview failed or replaced original comparison")
            first.model.load();try await wait {!first.model.busy && pane.droppedFiles.isEmpty}
            try require(first.model.document?.base.bytes == original.base.bytes && pane.currentImage(base:false) == nil,"Reload did not restore original metafile inputs")

            // Exercise actual IDiff Open acceptance through its owned chooser,
            // including the native detach before the captured reload is admitted.
            var loader:ImageLoadWindowController?
            first.model.makeImageLoader={path,permissions in
                let value=track(ImageLoadWindowController(leftPath:path,permissions:permissions));value.requiresScopes=false;loader=value;return value
            }
            first.model.chooseImageFiles();try await wait {loader != nil && first.window?.attachedSheet === loader?.window}
            guard let loader else {throw Failure(message:"Native image chooser missing")}
            try require(loader.window?.alphaValue == 0 && loader.window?.appearance == first.window?.appearance,"Metafile Open lost captured presentation")
            let allowed=Set(ImageLoadWindowController.imageContentTypes.compactMap(\.preferredFilenameExtension))
            try require(allowed.contains("wmf") && allowed.contains("emf"),"Native image filter excluded Windows metafiles")
            loader.left.stringValue=samples[0].path;loader.right.stringValue=preview.path;loader.accept()
            try await wait {first.window?.attachedSheet == nil && !first.model.busy && first.model.document?.base.path == samples[0].path}
            try require(loader.retired && first.model.imageComparison?.base != nil && first.model.imageComparison?.destination != nil && ImageLoadWindowController.activeReleases == 0,"Open did not reload after actual native chooser detach; \(comparisonState(first)); chooserRetired=\(loader.retired)")

            let merge=track(FileComparisonWindowController(comparison:try WorkingFileComparison(base:samples[0],destination:samples[0]),permissions:[],preferences:prefs,deferInitialLoad:true))
            var unexpectedDecodes=0
            merge.model.useInternalMergeViewer();merge.model.decodeImages={_,_ in unexpectedDecodes += 1;throw Failure(message:"Merge entered image decoder")}
            merge.model.beginTransferredDocument();try await wait {!merge.model.busy && merge.model.document != nil}
            merge.window?.contentView?.layoutSubtreeIfNeeded()
            try require(merge.model.imageComparison == nil && merge.model.viewerSelection == .merge && unexpectedDecodes == 0 && merge.window?.title.hasSuffix("TurtleGitMerge") == true && !descendants(merge.window!.contentView!).contains {$0 is ImageComparisonScrollView},"Explicit Merge silently switched to IDiff; \(comparisonState(merge)); unexpectedDecodes=\(unexpectedDecodes)")
            // A textual image format must produce the actual Merge text editors
            // when explicitly selected, without entering the image decoder.
            let svg=root.appendingPathComponent("explicit-merge.svg"),svgBytes=Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"96\" height=\"64\"><rect width=\"96\" height=\"64\" fill=\"red\"/></svg>\n".utf8)
            try svgBytes.write(to:svg)
            let textMerge=track(FileComparisonWindowController(comparison:try WorkingFileComparison(base:svg,destination:svg),permissions:[],preferences:prefs,deferInitialLoad:true))
            textMerge.model.useInternalMergeViewer();textMerge.model.decodeImages={_,_ in unexpectedDecodes += 1;throw Failure(message:"Explicit text Merge entered image decoder")}
            textMerge.model.beginTransferredDocument()
            try await wait(diagnostic:{comparisonState(textMerge)}) {textMerge.window?.contentView?.layoutSubtreeIfNeeded();return !textMerge.model.busy && !textMerge.model.filtering && descendants(textMerge.window!.contentView!).compactMap {$0 as? NSTextView}.filter {["Base file","Destination file"].contains($0.accessibilityLabel() ?? "")}.count == 2}
            try require(textMerge.model.viewerSelection == .merge && textMerge.model.imageComparison == nil && textMerge.model.draftText(base:true) == String(decoding:svgBytes,as:UTF8.self) && unexpectedDecodes == 0,"Explicit Merge did not expose the original text in native editors; \(comparisonState(textMerge)); unexpectedDecodes=\(unexpectedDecodes)")

            // A noncooperative decoder must not block the main actor or release
            // the captured comparison session before its true completion.
            let late=track(FileComparisonWindowController(comparison:try WorkingFileComparison(base:samples[0],destination:samples[0]),permissions:[],preferences:prefs,deferInitialLoad:true))
            var comparisonToken:OperationCancellation?
            late.model.decodeImages={_,token in comparisonToken=token;return await withCheckedContinuation {comparisonHold=$0}}
            late.model.beginTransferredDocument();try await wait(diagnostic:{comparisonState(late)}) {comparisonHold != nil}
            try require(late.model.busy && FileListComparisonSession.activeOperations == 1,"Detached comparison lost complete session lifetime; \(comparisonState(late))")
            late.close();try require(comparisonToken?.isCancelled == true && FileListComparisonSession.activeOperations == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Closing comparison lost live decoder/Quit ownership; \(comparisonState(late)); tokenCancelled=\(String(describing:comparisonToken?.isCancelled))")
            comparisonHold?.resume(returning:ImageComparisonDocument(base:nil,destination:nil));comparisonHold=nil
            try await wait {!late.model.busy && FileListComparisonSession.activeOperations == 0}
            try require(late.model.document == nil && late.model.imageComparison == nil,"Retired comparison published late decoder result; \(comparisonState(late))")

            let scope=MetafileConsumerScopeLog(),dropModel=ImageComparisonViewModel();previewModels.append(dropModel)
            dropModel.requiresDropScope=true;dropModel.makeDropPermission={RepositoryAccessLease(url:$0,provider:MetafileConsumerBookmarks(scope))}
            var dropToken:OperationCancellation?
            dropModel.decodeDroppedImage={_,token in dropToken=token;return await withCheckedContinuation {dropHold=$0}}
            try require(dropModel.dropFile(drop,base:true),"Owned metafile decode drop refused")
            try await wait {dropHold != nil}
            dropModel.retire()
            try require(dropToken?.isCancelled == true && scope.starts == 1 && scope.stops == 0 && ImageComparisonViewModel.activeFileReads == 1,"Retirement released in-flight decoder/grant")
            dropHold?.resume(returning:nil);dropHold=nil;try await wait {ImageComparisonViewModel.activeFileReads == 0 && scope.stops == 1}
            try require(dropModel.droppedFiles.isEmpty && dropModel.currentImage(base:true) == nil,"Retired drop published original bytes or decoder image")

            // Replacement/reload cancels only the old preview receipt. A late
            // decoder cannot overwrite the newer accepted drop or its grants.
            let replacementScope=MetafileConsumerScopeLog(),replacement=ImageComparisonViewModel();previewModels.append(replacement)
            replacement.requiresDropScope=true;replacement.makeDropPermission={RepositoryAccessLease(url:$0,provider:MetafileConsumerBookmarks(replacementScope))}
            let defaultDropDecoder=replacement.decodeDroppedImage
            var oldDropToken:OperationCancellation?
            replacement.decodeDroppedImage={_,token in oldDropToken=token;return await withCheckedContinuation {dropHold=$0}}
            try require(replacement.dropFile(drop,base:true),"Held replacement drop refused")
            try await wait {dropHold != nil}
            replacement.configureImages(base:first.model.imageComparison?.base,destination:first.model.imageComparison?.destination,force:true)
            try require(oldDropToken?.isCancelled == true && ImageComparisonViewModel.activeFileReads == 1,"Replacing inputs released old decoder before drain")
            replacement.decodeDroppedImage=defaultDropDecoder
            try require(replacement.dropFile(samples[0],base:true),"New preview refused while canceled decoder retired")
            try await wait {!replacement.receivingDrop && replacement.droppedFiles[true]?.bytes == inputs[0]}
            let acceptedID=replacement.currentImage(base:true)?.id
            dropHold?.resume(returning:nil);dropHold=nil
            try await wait {ImageComparisonViewModel.activeFileReads == 0}
            try require(acceptedID != nil && replacement.currentImage(base:true)?.id == acceptedID && replacement.droppedFiles[true]?.bytes == inputs[0] && replacementScope.stops == 1,"Canceled decoder overwrote newer drop or released its permission")
            replacement.retire();try require(replacementScope.starts == 2 && replacementScope.stops == 2,"Replacement preview permission leaked")

            // Actual three-stage conflict uses the same decoder and keeps every
            // original stage selectable independently of successful rendering.
            let work=root.appendingPathComponent("repository");try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true)
            let repo=GitRepository(root:work,executable:git),path="drawing.emf",file=work.appendingPathComponent(path)
            _ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Metafile consumers QA"),("user.email","metafile@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
            let wmfIndex=samples.firstIndex {$0.pathExtension.lowercased()=="wmf"}!,classicIndex=samples.firstIndex {$0.pathExtension.lowercased()=="emf" && !$0.lastPathComponent.lowercased().contains("plus")}!,plusIndex=samples.firstIndex {$0.pathExtension.lowercased()=="emf" && $0.lastPathComponent.lowercased().contains("plus")}!
            try inputs[wmfIndex].write(to:file);try await repo.stage([path]);_ = try await repo.commit(message:"base WMF")
            _ = try await repo.run(["switch","-c","side"]);try inputs[classicIndex].write(to:file);try await repo.stage([path]);_ = try await repo.commit(message:"incoming EMF")
            _ = try await repo.run(["switch","main"]);try inputs[plusIndex].write(to:file);try await repo.stage([path]);_ = try await repo.commit(message:"mine EMF+")
            do {_ = try await repo.run(["merge","--no-edit","side"]);throw Failure(message:"Expected metafile conflict")}catch is GitFailure {}
            guard let conflictDocument=try await repo.imageConflictDocument(path:path) else {throw Failure(message:"Metafile conflict did not dispatch to IDiff")}
            let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:work.appendingPathComponent(".git/index")),working=try Data(contentsOf:file)
            let conflict=track(ImageConflictWindowController(repository:repo,access:nil,document:conflictDocument,preferences:prefs))
            try await wait {!conflict.model.busy}
            try require(conflict.model.images.count == 3 && ImageConflictSide.allCases.allSatisfy {conflict.model.canSelect($0) && conflict.model.panes[$0]?.currentImage(base:true)?.pixels.width == 96 && conflict.model.panes[$0]?.currentImage(base:true)?.pixels.height == 64},"Three-side WMF/EMF/EMF+ conflict failed to decode: \(conflict.model.error ?? "none")")
            conflict.model.reload();try await wait {!conflict.model.busy}
            try require(conflict.model.images.count == 3,"Metafile conflict reload lost an image")
            // The newly accepted region, hatch and texture families also enter
            // actual three-stage conflict panes, not only standalone decoders.
            let patternWork=root.appendingPathComponent("pattern repository")
            try FileManager.default.createDirectory(at:patternWork,withIntermediateDirectories:true)
            let patternRepo=GitRepository(root:patternWork,executable:git),patternFile=patternWork.appendingPathComponent(path)
            _ = try await patternRepo.run(["init","-b","main"])
            for (key,value) in [("user.name","Pattern consumers QA"),("user.email","patterns@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await patternRepo.run(["config",key,value])}
            let regionBytes=try Data(contentsOf:corpus.appendingPathComponent("plus-region-path.emf")),hatchBytes=try Data(contentsOf:corpus.appendingPathComponent("plus-hatch-atlas.emf")),textureBytes=try Data(contentsOf:corpus.appendingPathComponent("plus-texture-world.emf"))
            try regionBytes.write(to:patternFile);try await patternRepo.stage([path]);_ = try await patternRepo.commit(message:"base region")
            _ = try await patternRepo.run(["switch","-c","side"]);try hatchBytes.write(to:patternFile);try await patternRepo.stage([path]);_ = try await patternRepo.commit(message:"incoming hatch")
            _ = try await patternRepo.run(["switch","main"]);try textureBytes.write(to:patternFile);try await patternRepo.stage([path]);_ = try await patternRepo.commit(message:"mine texture")
            do {_ = try await patternRepo.run(["merge","--no-edit","side"]);throw Failure(message:"Expected region/pattern metafile conflict")}catch is GitFailure {}
            guard let patternDocument=try await patternRepo.imageConflictDocument(path:path) else {throw Failure(message:"Region/pattern conflict did not dispatch to IDiff")}
            let patternHead=try await patternRepo.run(["rev-parse","HEAD"]).stdout,patternIndex=try Data(contentsOf:patternWork.appendingPathComponent(".git/index")),patternWorking=try Data(contentsOf:patternFile)
            let patternConflict=track(ImageConflictWindowController(repository:patternRepo,access:nil,document:patternDocument,preferences:prefs))
            try await wait {!patternConflict.model.busy}
            try require(patternConflict.model.images.count==3 && ImageConflictSide.allCases.allSatisfy {patternConflict.model.canSelect($0) && patternConflict.model.panes[$0]?.currentImage(base:true)?.pixels.width==96 && patternConflict.model.panes[$0]?.currentImage(base:true)?.pixels.height==64},"Region/hatch/texture conflict panes failed to decode: \(patternConflict.model.error ?? "none")")
            try require(patternConflict.model.document.contents[.base]==regionBytes && patternConflict.model.document.contents[.theirs]==hatchBytes && patternConflict.model.document.contents[.mine]==textureBytes,"Region/pattern conflict decoding rewrote original stages")
            patternConflict.model.reload();try await wait {!patternConflict.model.busy}
            try require(patternConflict.model.images.count==3,"Region/pattern conflict reload lost a side")
            patternConflict.close();try await wait {ImageConflictWindowModel.activeOperations==0 && patternConflict.window?.isVisible != true}
            try require(try await patternRepo.run(["rev-parse","HEAD"]).stdout==patternHead,"Region/pattern preview moved HEAD")
            try require((try Data(contentsOf:patternWork.appendingPathComponent(".git/index")))==patternIndex && (try Data(contentsOf:patternFile))==patternWorking,"Region/pattern preview mutated conflict index/working bytes")
            let priorImages=conflict.model.images.mapValues(\.id)
            var reloadToken:OperationCancellation?
            conflict.model.decodeImages={_,token in reloadToken=token;return await withCheckedContinuation {conflictHold=$0}}
            conflict.model.reload();try await wait {conflictHold != nil}
            let escape=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:conflict.window!.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)!
            try require(conflict.windowShouldClose(conflict.window!) && conflict.window!.performKeyEquivalent(with:escape),"User Escape could not close a held reload preview")
            try require(conflict.model.retired && reloadToken?.isCancelled == true && ImageConflictWindowModel.activeOperations == 1,"Reload retirement released actual metafile decoder")
            conflictHold?.resume(returning:[:]);conflictHold=nil;try await wait {ImageConflictWindowModel.activeOperations == 0}
            try require(conflict.model.images.mapValues(\.id) == priorImages,"Retired conflict reload replaced captured images")
            var conflictToken:OperationCancellation?
            let retiring=track(ImageConflictWindowController(repository:repo,access:nil,document:conflictDocument,preferences:prefs,decodeImages:{_,token in conflictToken=token;return await withCheckedContinuation {conflictHold=$0}}))
            try await wait {conflictHold != nil}
            try require(retiring.model.busy && retiring.model.decoding && !retiring.model.canSelect(.mine),"Initial decode did not own conflict inputs")
            try require(retiring.windowShouldClose(retiring.window!),"User close refused initial preview decode")
            retiring.window!.performClose(nil)
            try require(retiring.model.retired && conflictToken?.isCancelled == true && ImageConflictWindowModel.activeOperations == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"User Close did not retire preview or retain actual decoder/Quit ownership")
            conflictHold?.resume(returning:[:]);conflictHold=nil;try await wait {ImageConflictWindowModel.activeOperations == 0}
            try require(retiring.model.images.isEmpty && retiring.model.retired,"Retired conflict published a late decoded image")
            try require(try await repo.run(["rev-parse","HEAD"]).stdout == head,"Metafile preview moved HEAD")
            try require((try Data(contentsOf:work.appendingPathComponent(".git/index"))) == index && (try Data(contentsOf:file)) == working,"Metafile preview mutated conflict state")
            for (sample,bytes) in zip(samples,inputs) {try require(try Data(contentsOf:sample) == bytes,"Metafile renderer modified corpus bytes")}
            try await cleanup()
            print("PASS: actual WMF/EMF/EMF+ and region/hatch/texture default two-side and conflict decode/reload, unsupported-side IDiff and explicit Merge routing, preview-only drop, cancellation/late-result/session/grant/Quit ownership; original corpus/comparison/conflict HEAD/index/working bytes unchanged")
        } catch {let original=error;do {try await cleanup()}catch {throw Failure(message:"\(original); cleanup: \(error)")};throw original}
    }
    private static func firstSample(_ files:[URL],withExtension ext:String)throws->URL {
        guard let file=files.first(where:{$0.pathExtension.lowercased()==ext}) else {throw Failure(message:"Missing "+ext+" corpus")};return file
    }
}
