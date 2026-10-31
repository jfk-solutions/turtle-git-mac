// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import UniformTypeIdentifiers
import CoreText
import ImageIO
import CryptoKit
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
    private static var phaseHistory=[[String:Any]]()
    private static var currentPhase="setup"
    private struct ConsumerCohortPlan:Decodable {
        let version:Int
        let historical_positive:[String]
        let historical_positive_sha256:[String:String]
        let negative_batches:[[String]]
        let negative_sha256:[String:String]
    }
    static func phase(_ name:String,sample:String="",state:String="") throws {
        currentPhase=name+(sample.isEmpty ? "":" "+sample)
        let entry:[String:Any]=["phase":name,"sample":sample,"state":String(state.prefix(16384)),"uptime":ProcessInfo.processInfo.systemUptime,
            "sessions":FileListComparisonSession.activeOperations,"drops":ImageComparisonViewModel.activeFileReads,"conflicts":ImageConflictWindowModel.activeOperations,"chooserReleases":ImageLoadWindowController.activeReleases]
        phaseHistory.append(entry);if phaseHistory.count>32 {phaseHistory.removeFirst(phaseHistory.count-32)}
        let url=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("phase.json")
        try JSONSerialization.data(withJSONObject:["current":entry,"history":phaseHistory],options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)
        print("Metafile phase: "+currentPhase+"; "+String(state.prefix(1024)));fflush(stdout)
    }
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(message:message)}}
    static func wait(line:Int = #line,diagnostic:()->String={""},_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(message:"Metafile consumers did not settle at \(line), phase=\(currentPhase); \(diagnostic())")
    }
    static func descendants(_ view:NSView)->[NSView] {[view]+view.subviews.flatMap(descendants)}
    static func verify(dibProfiles:Bool=false,wmfBitmap16:Bool=false,wmfText:Bool=false,classicTextRecords:Bool=false,formattedDigits:Bool=false,compressedPaths:Bool=false,positionedText:Bool=false,classicPens:Bool=false,classicRegions:Bool=false,classicPatternBrushes:Bool=false,embeddedMetafiles:Bool=false,compressedRaster:Bool=false)async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),suppliedCorpus=URL(fileURLWithPath:CommandLine.arguments[3])
        let corpus=dibProfiles ? suppliedCorpus.appendingPathComponent("DIBProfiles"):suppliedCorpus
        phaseHistory=[];try phase("setup",state:"case="+(ProcessInfo.processInfo.environment["TURTLEGIT_METAFILE_CASE"] ?? "direct"))
        if wmfText {try JSONSerialization.data(withJSONObject:try textRuntimeIdentity(),options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("wmf-text-runtime-identity.json"),options:.atomic)}
        let corpusFiles=try FileManager.default.contentsOfDirectory(at:corpus,includingPropertiesForKeys:nil).filter { ["wmf","emf"].contains($0.pathExtension.lowercased()) }.sorted {$0.lastPathComponent < $1.lastPathComponent}
        let legacySamples:Set<String>=["clip-vector.wmf","classic-vector.emf","classic-bitmap.emf","plus-transform.emf","plus-bitmap-text.emf","plus-compressed-crop.emf","plus-gradient-transform.emf","plus-image-attributes.emf","plus-region-path.emf","plus-region-state.emf","plus-hatch-atlas.emf","plus-texture-world.emf","plus-region-texture.emf","plus-raw-indexed1-positive.emf","plus-raw-indexed4-negative.emf","plus-raw-indexed8-positive.emf","plus-raw-rgb555-negative.emf","plus-raw-rgb565-positive.emf","plus-raw-argb1555-negative.emf","plus-raw-texture-indexed-alpha.emf","plus-raw-texture-rgb565-positive.emf","plus-formatted-tabs.emf","plus-formatted-rtl.emf","plus-formatted-vertical.emf","plus-formatted-tracking.emf","plus-formatted-ellipsis.emf","plus-formatted-gradient.emf","classic-clip-region-xor.emf","classic-clip-region-diff.emf","classic-clip-meta-repeated.emf","classic-clip-offset-offcanvas.emf","classic-clip-path-and.emf","classic-clip-rect-world.emf","plus-pen-compound.emf","plus-pen-transform.emf","plus-pen-inset.emf","plus-pen-asymmetric-caps.emf","plus-pen-dash-round.emf","plus-pen-gradient.emf","plus-pen-custom-fill.emf","plus-pen-custom-stroke.emf","plus-pen-custom-both-paths.emf","plus-pen-custom-arrow-filled.emf","plus-pen-custom-arrow-notch.emf","plus-pen-custom-world-clip.emf"]
        let acceptedLegacyBitmap16Samples:Set<String>=["unsupported-raster-device-bitblt.wmf","unsupported-raster-device-stretchblt.wmf","unsupported-raster-wmf-without-bitmap-source-bitblt.wmf","unsupported-raster-wmf-without-bitmap-source-stretchblt.wmf"]
        // Historical names are retained byte-for-byte. Their positive Core
        // checks now prove exact BGRX/self-copy colors and ROP2 cyan/yellow ink.
        let acceptedHistoricalRasterSamples=acceptedLegacyBitmap16Samples.union(["unsupported-rop.emf"])
        // Core MetafileImageTests establishes ordinary E-without-effect image
        // fallback, ROP2 XOR, complete BGRX and empty prior-DC WMF positives.
        let acceptedHistoricalSamples=acceptedHistoricalRasterSamples.union(["unsupported-image-effect.emf"])
        let wmfBitmap16Samples:Set<String>=Set(["wmf-bitmap16-bitblt-native.wmf","wmf-bitmap16-stretch-upscale.wmf","wmf-bitmap16-word-padding17.wmf","wmf-bitmap16-crop.wmf","wmf-bitmap16-mirror-dest-x.wmf","wmf-bitmap16-live-colors.wmf","wmf-bitmap16-save-restore.wmf","wmf-bitmap16-rop-66.wmf","wmf-bitmap16-rop-c0.wmf","wmf-bitmap16-clip.wmf","wmf-bitmap16-mapped.wmf","wmf-bitmap16-source-independent-color24-bitblt.wmf","wmf-bitmap16-embedded-affine.emf","wmf-bitmap16-pattern-bitmap16.wmf","wmf-bitmap16-bgrx32-stretch.wmf","wmf-bitmap16-widthbytes-negative.wmf","wmf-bitmap16-self-bitblt-overlap.wmf","wmf-bitmap16-self-stretchblt-copy.wmf","wmf-bitmap16-shrink-mode1.wmf","wmf-bitmap16-shrink-mode2.wmf","wmf-bitmap16-shrink-mode3.wmf","wmf-bitmap16-halftone-integer-box.wmf","wmf-bitmap16-halftone-lanczos-quality.wmf","wmf-bitmap16-self-bitblt-mapped.wmf","wmf-bitmap16-self-stretchblt-outside-preserve.wmf"]).union(acceptedLegacyBitmap16Samples).union(["classic-gdi-empty-prior-bitblt-white-patcopy-control.wmf","classic-gdi-empty-prior-stretchblt-white-patcopy-control.wmf"])
        let wmfTextSamples:Set<String>=["wmf-text-textout-odd.wmf","wmf-text-ext-dx.wmf","wmf-text-ext-clip-opaque.wmf","wmf-text-ext-empty-opaque.wmf","wmf-text-ext-updatecp-dx.wmf","wmf-text-font-decorated.wmf","wmf-text-font-cell.wmf","wmf-text-font-angle.wmf","wmf-text-restore.wmf","wmf-text-translated.wmf","wmf-text-charset-204.wmf","wmf-text-dbcs-128.wmf","wmf-text-embedded-affine.emf","wmf-text-charset-oem437.wmf","wmf-text-dbcs-johab.wmf","wmf-text-extra-dx-positive.wmf","wmf-text-justify-dx-positive.wmf","wmf-text-extra-natural-negative.wmf","wmf-text-embedded-clip-affine.emf","wmf-text-justify-natural-positive.wmf","wmf-text-ext-pdy-ignored.wmf","wmf-text-dbcs-single-johab.wmf","wmf-text-dbcs-repeat-128.wmf"]
        let classicTextSamples:Set<String>=["classic-text-compact-small.emf","classic-text-compact-low-unicode.emf","classic-text-compact-clip-opaque.emf","classic-text-compact-updatecp.emf","classic-text-compact-world.emf","classic-text-poly-wide-dx.emf","classic-text-poly-wide-pdy.emf","classic-text-poly-ansi-clip-opaque.emf","classic-text-poly-ansi-updatecp.emf","classic-text-ext-ansi-cp1252.emf","classic-text-poly-ansi-cp1252.emf","classic-text-ext-charset-204.emf","classic-text-poly-charset-222.emf","classic-text-ext-dbcs-128.emf","classic-text-poly-dbcs-pdy-134.emf","classic-text-compact-no-rect-opaque.emf","classic-text-poly-wide-offdx-zero-updatecp.emf"]
        let formattedDigitSamples:Set<String>=["clip-vector.wmf","classic-vector.emf","plus-formatted-digits-thai-national.emf","plus-formatted-digits-thai-traditional.emf","plus-formatted-digits-arabic-national.emf","plus-formatted-digits-persian-traditional.emf","plus-formatted-digits-thai-hotkey.emf","plus-formatted-digits-thai-vertical.emf","plus-formatted-digits-thai-wrap.emf","plus-formatted-digits-thai-gradient.emf","plus-formatted-controls-lrm-context-display.emf","plus-formatted-controls-zwj-alone-display.emf","plus-formatted-controls-vertical-display.emf","plus-formatted-controls-trim-removed-display.emf","plus-formatted-controls-path-trim-display.emf","windows-formatted-lrm-latin-display.emf","windows-formatted-rlm-alone-display.emf","windows-formatted-zwj-alone-display.emf","windows-formatted-zwnj-latin-display.emf","windows-formatted-digits-thai-traditional-plain.emf","windows-formatted-digits-arabic-national-arabic-rtl.emf","plus-formatted-controls-lrm-gradient-display.emf"]
        let compressedSamples:Set<String> = Set(["fill","region","cap"].flatMap { family in ["relative","float"].map {"plus-compressed-path-"+family+"-"+$0+".emf"} })
        let positionedSamples:Set<String> = ["plus-driver-positioned-full-background.emf","plus-driver-compatible-dx-full-background.emf","plus-driver-positioned.emf","plus-driver-natural.emf","plus-driver-vertical-natural.emf","plus-driver-linear-matrix.emf","plus-driver-vertical-matrix.emf","plus-driver-gradient.emf","classic-positioned-dx.emf","classic-positioned-pdy.emf","classic-positioned-opaque.emf","classic-positioned-compatible-dx.emf","plus-driver-compatible-dx.emf"]
        let classicPenSamples:Set<String>=["classic-extpen-custom.emf","classic-extpen-hatch-4.emf","classic-extpen-dib.emf","classic-extpen-state.emf","classic-extpen-inside-rectangle.emf"]
        let classicRegionSamples:Set<String>=Set(["classic-region-fill-preserve.emf","classic-region-frame-union.emf","classic-flood-surface.emf","wmf-classic-region-fill-preserve.wmf","wmf-classic-region-frame-union.wmf","wmf-classic-flood-border.wmf"])
            .union(["wmf-classic-flood-surface.wmf","wmf-classic-flood-legacy-border.wmf","wmf-classic-flood-hatch.wmf","classic-gdi-scanlines-full-white-patcopy-control.wmf"])
            .union(["surface","border","legacy-border","hatch"].map{"wmf-classic-flood-"+$0+"-sealed-white-patcopy-control.wmf"})
        let classicPatternSamples:Set<String>=["wmf-classic-patternbrush-mono.wmf","wmf-classic-patternbrush-state.wmf","classic-monobrush-dynamic.emf","classic-monobrush-colored.emf","classic-monobrush-palette-select.emf"]
        let embeddedSamples:Set<String>=["embedded-image-wmf.emf","embedded-image-placeable.emf","embedded-image-emf.emf","embedded-image-plus-only.emf","embedded-image-plus-dual.emf","embedded-image-recursive.emf","embedded-image-affine.emf","embedded-image-classic-text-affine.emf","embedded-image-wmf-round-clip-affine.emf","embedded-image-attributes-3.emf","embedded-texture-4.emf","embedded-texture-glyph.emf","embedded-compositing-copy.emf","embedded-image-destination-rop.emf","embedded-checkpoint-scopes.emf"]
        let compressedRasterSamples:Set<String>=["compressed-raster-image-gif-two-frames-visible.emf","compressed-raster-image-gif-two-frames-delay10-loop.emf","compressed-raster-image-tiff-two-pages.emf","compressed-raster-image-exif-orientation6.emf","compressed-raster-image-gif.emf","compressed-raster-image-tiff.emf","compressed-raster-image-gif-alpha.emf","compressed-raster-image-tiff-alpha.emf","compressed-raster-texture-tiff-alpha.emf","compressed-raster-pen-gif.emf","compressed-raster-alpha-tiff-alpha-copy.emf","compressed-raster-affine-gif.emf","compressed-raster-clip-tiff.emf","compressed-raster-attributes-3.emf","compressed-raster-stretch-png-emf.emf","compressed-raster-stretch-jpeg-wmf.wmf","compressed-raster-stretch-mirror-png-wmf.wmf"]
        let dibConsumers=["emf-raster","emf-scanlines","emf-brush","wmf-raster","wmf-scanlines","wmf-brush"]
        let dibProfileSamples:Set<String>=Set(dibConsumers.map {$0+"-embedded-linear-rgb-after."+($0.hasPrefix("wmf-") ? "wmf":"emf")}).union([
            "emf-raster-embedded-linear-rgb-before-icm-on.emf",
            "emf-raster-embedded-linear-rgb-before-icm-save-off-restore-on.emf"])
        let dibProfileRefusals:Set<String>=Set(dibConsumers.map {$0+"-malformed-profile-overlap-bits."+($0.hasPrefix("wmf-") ? "wmf":"emf")}).union(["wmf-raster-embedded-linear-rgb-before.wmf"])
        let nativeSamples = dibProfiles ? dibProfileSamples : wmfBitmap16 ? wmfBitmap16Samples : wmfText ? wmfTextSamples : classicTextRecords ? classicTextSamples : formattedDigits ? formattedDigitSamples : compressedRaster ? compressedRasterSamples : embeddedMetafiles ? embeddedSamples : classicPatternBrushes ? classicPatternSamples : classicRegions ? classicRegionSamples : classicPens ? classicPenSamples : positionedText ? positionedSamples : compressedPaths ? compressedSamples : legacySamples.union(compressedSamples).union(positionedSamples).union(acceptedHistoricalSamples)
        var samples=corpusFiles.filter {nativeSamples.contains($0.lastPathComponent)},unsupported=corpusFiles.filter {dibProfiles ? dibProfileRefusals.contains($0.lastPathComponent) : wmfBitmap16 ? $0.lastPathComponent.hasPrefix("unsupported-wmf-bitmap16-") : wmfText ? $0.lastPathComponent.hasPrefix("unsupported-wmf-text-") : classicTextRecords ? $0.lastPathComponent.hasPrefix("unsupported-classic-text-") : formattedDigits ? $0.lastPathComponent.hasPrefix("unsupported-formatted-digits-") : compressedRaster ? $0.lastPathComponent.hasPrefix("refused-compressed-raster-") : embeddedMetafiles ? $0.lastPathComponent.hasPrefix("embedded-refused-") : classicPatternBrushes ? $0.lastPathComponent.hasPrefix("unsupported-classic-patternbrush-") : classicRegions ? ($0.lastPathComponent.hasPrefix("unsupported-classic-region-") || $0.lastPathComponent.hasPrefix("unsupported-wmf-classic-region-")) : classicPens ? $0.lastPathComponent.hasPrefix("unsupported-extpen-") : positionedText ? $0.lastPathComponent.hasPrefix("unsupported-positioned-text-") : compressedPaths ? $0.lastPathComponent.hasPrefix("unsupported-compressed-path-") : $0.lastPathComponent.hasPrefix("unsupported-") && !acceptedHistoricalSamples.contains($0.lastPathComponent)}
        if dibProfiles || wmfBitmap16 || wmfText || classicTextRecords || formattedDigits || compressedRaster || embeddedMetafiles || compressedPaths || positionedText || classicPens || classicRegions || classicPatternBrushes {try require(!unsupported.isEmpty,"Requested native metafile refusal corpus missing")}
        try require(samples.count == nativeSamples.count,"Representative native metafile corpus incomplete")
        if !dibProfiles && !wmfBitmap16 && !wmfText && !classicTextRecords && !compressedRaster && !embeddedMetafiles && !compressedPaths && !positionedText && !classicPens && !classicRegions && !classicPatternBrushes {try require(samples.contains {$0.pathExtension.lowercased()=="wmf"} && samples.filter {$0.pathExtension.lowercased()=="emf"}.count >= 2 && samples.contains {$0.lastPathComponent.lowercased().contains("plus")},"Provide representative WMF, EMF and EMF+ corpus files")}
        if positionedText {
            for name in ["plus-driver-positioned","classic-positioned-dx"] {
                let bytes=try rawGlyphCopy(Data(contentsOf:corpus.appendingPathComponent(name+".emf"))),copy=root.appendingPathComponent(name+"-native-glyphs.emf")
                try bytes.write(to:copy);samples.append(copy)
            }
        }
        var negativeOnly=false,historicalOnly=false
        let cohort=ProcessInfo.processInfo.environment["TURTLEGIT_METAFILE_COHORT"]
        if let cohort {
            try require(ProcessInfo.processInfo.environment["TURTLEGIT_METAFILE_CASE"]=="consumers","Cohort applied to another workflow")
            guard let planPath=ProcessInfo.processInfo.environment["TURTLEGIT_METAFILE_COHORT_PLAN"] else {throw Failure(message:"Missing complete consumer cohort plan")}
            let plan=try JSONDecoder().decode(ConsumerCohortPlan.self,from:Data(contentsOf:URL(fileURLWithPath:planPath)))
            let complete=unsupported.sorted{$0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8)}
            let flattened=plan.negative_batches.flatMap{$0},names=complete.map{Data($0.lastPathComponent.utf8)}
            try require(plan.version==2 && flattened.map{Data($0.utf8)}==names && Set(names).count==names.count && plan.negative_batches.allSatisfy{!$0.isEmpty && $0.count<=64},"Consumer partitions omitted/duplicated/reordered malformed corpus")
            try require(Set(plan.negative_sha256.keys.map{Data($0.utf8)})==Set(names),"Consumer fingerprint inventory differs from complete malformed corpus")
            for file in complete {
                let digest=SHA256.hash(data:try Data(contentsOf:file)).map{String(format:"%02x",$0)}.joined()
                try require(plan.negative_sha256[file.lastPathComponent]==digest,"Consumer cohort source fingerprint differs: "+file.lastPathComponent)
            }
            let historical=corpusFiles.filter{acceptedHistoricalSamples.contains($0.lastPathComponent)}.sorted{$0.lastPathComponent.utf8.lexicographicallyPrecedes($1.lastPathComponent.utf8)}
            let historicalNames=historical.map{Data($0.lastPathComponent.utf8)}
            try require(plan.historical_positive.map{Data($0.utf8)}==historicalNames && historicalNames.count==acceptedHistoricalSamples.count && Set(plan.historical_positive_sha256.keys.map{Data($0.utf8)})==Set(historicalNames),"Historical positive inventory differs from independently supported names")
            for file in historical {
                let digest=SHA256.hash(data:try Data(contentsOf:file)).map{String(format:"%02x",$0)}.joined()
                try require(plan.historical_positive_sha256[file.lastPathComponent]==digest,"Historical positive fingerprint differs: "+file.lastPathComponent)
            }
            if cohort=="positive" {samples.removeAll{acceptedHistoricalSamples.contains($0.lastPathComponent)};unsupported=[]}
            else if cohort=="historical-positive" {samples=historical;unsupported=[];historicalOnly=true}
            else {
                guard cohort.hasPrefix("negative-"),let index=Int(cohort.dropFirst(9)),cohort=="negative-"+String(index),plan.negative_batches.indices.contains(index) else {throw Failure(message:"Unknown consumer cohort: "+cohort)}
                negativeOnly=true
                let selected=Set(plan.negative_batches[index].map{Data($0.utf8)})
                unsupported=complete.filter{selected.contains(Data($0.lastPathComponent.utf8))}
                try require(unsupported.count==plan.negative_batches[index].count,"Negative cohort selection is incomplete")
            }
            try phase("cohort inventory",state:"cohort=\(cohort) positives=\(samples.count) selectedNegatives=\(unsupported.count) completeNegatives=\(complete.count)")
        }
        func renderedDimensions(_ sample:URL)->(Int,Int) {
            let interior=(acceptedLegacyBitmap16Samples.contains(sample.lastPathComponent) || dibProfiles || wmfBitmap16 || compressedRaster || embeddedMetafiles || classicPens || classicRegions || classicPatternBrushes) ? (64,64) : (sample.lastPathComponent.hasPrefix("plus-formatted-") || sample.lastPathComponent.hasPrefix("windows-formatted-")) ? (240,180):(96,64)
            // Original Windows recordings use their measured 240x180 canvas;
            // handwritten fixtures retain the inclusive frame profile.
            let border=sample.pathExtension.lowercased()=="emf" && !sample.lastPathComponent.hasPrefix("windows-formatted-") ? 1:0
            return (interior.0+border,interior.1+border)
        }
        let inputs=try samples.map {try Data(contentsOf:$0)},bad=Data("unsupported image side\n".utf8)
        let suite="TurtleGit.MetafileConsumers.QA."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(0,forKey:"AutoCloseGitProgress");DialogGeometry.install(preferences:prefs)
        defer {prefs.removePersistentDomain(forName:suite);DialogGeometry.install(preferences:.standard)}
        var owners:[NSWindowController]=[],previewModels:[ImageComparisonViewModel]=[]
        var comparisonHold:CheckedContinuation<ImageComparisonDocument,Never>?,dropHold:CheckedContinuation<ComparisonImage?,Never>?,conflictHold:CheckedContinuation<[ImageConflictSide:ComparisonImage],Never>?
        func track<T:NSWindowController>(_ owner:T)->T {owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-12000,y:-12000));owners.append(owner);return owner}
        func comparisonState(_ owner:FileComparisonWindowController)->String {
            let model=owner.model,views=owner.window?.contentView.map(descendants) ?? []
            return "busy=\(model.busy) filtering=\(model.filtering) deferred=\(model.initialLoadDeferred) viewer=\(model.viewerSelection) alternate=\(model.alternateTool) images=\(model.imageComparison != nil) baseImage=\(String(describing:model.imageComparison?.base?.size)) destinationImage=\(String(describing:model.imageComparison?.destination?.size)) document=\(model.document != nil) imagePanes=\(views.filter {$0 is ImageComparisonScrollView}.count) textEditors=\(views.compactMap {$0 as? NSTextView}.filter {["Base file","Destination file"].contains($0.accessibilityLabel() ?? "")}.count) title=\(owner.window?.title ?? "none") error=\(model.error ?? "none") sessions=\(FileListComparisonSession.activeOperations) drops=\(ImageComparisonViewModel.activeFileReads) conflicts=\(ImageConflictWindowModel.activeOperations) chooserReleases=\(ImageLoadWindowController.activeReleases)"
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
            for (index,sample) in (negativeOnly ? []:samples).enumerated() {
                try phase("positive input",sample:sample.lastPathComponent,state:"ordinal=\(index+1)/\(samples.count)")
                let left=root.appendingPathComponent("sample-\(index)."+sample.pathExtension),right=root.appendingPathComponent("unsupported-\(index)."+sample.pathExtension)
                try inputs[index].write(to:left);try bad.write(to:right)
                let owner=track(FileComparisonWindowController(comparison:try WorkingFileComparison(base:left,destination:right),permissions:[],preferences:prefs))
                owner.model.load();try phase("positive native load",sample:sample.lastPathComponent,state:comparisonState(owner))
                try await wait(diagnostic:{comparisonState(owner)}) {owner.window?.contentView?.layoutSubtreeIfNeeded();return !owner.model.busy && owner.model.document != nil}
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
                let dimensions=renderedDimensions(sample)
                try require(owner.model.imageComparison?.base?.pixels.width == dimensions.0 && owner.model.imageComparison?.base?.pixels.height == dimensions.1 && owner.window?.title.hasSuffix("TurtleGitIDiff") == true,"Metafile \(sample.lastPathComponent) was not rendered at its expected \(dimensions.0)x\(dimensions.1) dimensions in native IDiff; actual=\(owner.model.imageComparison?.base?.pixels.width ?? -1)x\(owner.model.imageComparison?.base?.pixels.height ?? -1); title=\(owner.window?.title ?? "none")")
                try require(owner.model.document?.base.bytes == inputs[index] && owner.model.document?.destination.bytes == bad && (try Data(contentsOf:left)) == inputs[index] && (try Data(contentsOf:right)) == bad,"Metafile rendering rewrote original bytes")
                if acceptedHistoricalSamples.contains(sample.lastPathComponent),let image=owner.model.imageComparison?.base?.pixels {
                    let pixels=try textRGBA(image,fullCanvas:true)
                    func color(_ x:Int,_ y:Int)->[UInt8] {let start=(y*image.width+x)*4;return Array(pixels[start..<(start+4)])}
                    if sample.lastPathComponent=="unsupported-image-effect.emf" {
                        for (channel,x,y) in [(0,16,16),(1,32,16),(2,16,32)] {
                            let rgba=color(x,y)
                            try require(rgba[channel]>204 && (0..<3).filter{$0 != channel}.allSatisfy{rgba[$0]<64} && rgba[3]==255,"Ordinary image fallback lost independently specified source primary at \(x),\(y): \(rgba)")
                        }
                    } else if sample.lastPathComponent=="unsupported-rop.emf" {
                        try require(color(12,12)==[0,255,255,255] && color(58,12)==[255,255,0,255],"ROP2 XOR against opaque white lost independent cyan/yellow pixels")
                    } else if sample.lastPathComponent.hasPrefix("unsupported-raster-device-") {
                        try require(color(2,2)==[204,204,204,255],"Complete legacy BGRX record lost independently specified gray204 pixel")
                    }
                }
                if let expected=classicGDIFullCanvasExpected(sample.lastPathComponent),let image=owner.model.imageComparison?.base?.pixels {
                    try require(image.width==64 && image.height==64,"Classic GDI contract needs the entire native64x64 canvas")
                    try require(try raster(image)==Data(expected),"Native full-canvas original alpha/explicit PATCOPY/wall connectivity differs: \(sample.lastPathComponent)")
                }
                if classicPatternBrushes,let image=owner.model.imageComparison?.base?.pixels {
                    let colored=sample.lastPathComponent=="classic-monobrush-colored.emf" || sample.lastPathComponent=="classic-monobrush-palette-select.emf"
                    try patternRGB(image,8,8,colored ? [255,0,0]:[0,0,255],sample.lastPathComponent+" native bit1 palette")
                    try patternRGB(image,9,8,colored ? [0,255,0]:[255,0,0],sample.lastPathComponent+" native bit0 palette")
                    if sample.lastPathComponent.contains("state") || sample.lastPathComponent.contains("palette-select") {try patternRGB(image,8,24,[255,255,0],"Native saved/live brush state")}
                }
                if first == nil {first=owner} else {owner.close()}
                try phase("positive complete",sample:sample.lastPathComponent,state:comparisonState(owner))
            }
            if compressedRaster {
                for names in [["compressed-raster-image-gif.emf","compressed-raster-control-image-opaque.emf"],["compressed-raster-texture-tiff-alpha.emf","compressed-raster-control-texture-tiff-alpha.emf"],["compressed-raster-alpha-tiff-alpha-copy.emf","compressed-raster-control-tiff-alpha-copy.emf"]] {
                    let left=corpus.appendingPathComponent(names[0]),right=corpus.appendingPathComponent(names[1]),leftBytes=try Data(contentsOf:left),rightBytes=try Data(contentsOf:right)
                    let pair=track(FileComparisonWindowController(images:try ImageFileComparison(base:left,destination:right),permissions:[],preferences:prefs))
                    pair.model.load();try await wait{!pair.model.busy && pair.model.document != nil}
                    guard let a=pair.model.imageComparison?.base?.pixels,let b=pair.model.imageComparison?.destination?.pixels else{throw Failure(message:"Compressed raster control failed; \(comparisonState(pair))")}
                    try require(try raster(a)==raster(b),"Compressed native independent pixel control mismatch: \(names)")
                    try require(pair.model.document?.base.bytes==leftBytes && pair.model.document?.destination.bytes==rightBytes,"Compressed comparison replaced source containers")
                    pair.close()
                }
            }
            if embeddedMetafiles {
                for names in [["embedded-image-plus-only.emf","embedded-image-control.png"],["embedded-texture-wrap-3.emf","embedded-texture-wrap-3-control.emf"],["embedded-image-classic-text-affine.emf","embedded-image-classic-text-affine-control.emf"]] {
                    let left=corpus.appendingPathComponent(names[0]),right=corpus.appendingPathComponent(names[1]),leftBytes=try Data(contentsOf:left),rightBytes=try Data(contentsOf:right)
                    let pair=track(FileComparisonWindowController(images:try ImageFileComparison(base:left,destination:right),permissions:[],preferences:prefs))
                    pair.model.load();try await wait{!pair.model.busy && pair.model.document != nil}
                    guard let a=pair.model.imageComparison?.base?.pixels,let b=pair.model.imageComparison?.destination?.pixels else{throw Failure(message:"Embedded independent control failed; \(comparisonState(pair))")}
                    if names[1].hasSuffix(".png") {
                        try require(a.width==65 && a.height==65 && b.width==64 && b.height==64,"EMF natural extent and independent PNG extent differ from their source contracts")
                        try require(try raster(a,interior:CGSize(width:64,height:64))==raster(b),"Embedded native independent top-left pixel control mismatch: \(names)")
                    } else {
                        try require(try raster(a)==raster(b),"Embedded native independent pixel control mismatch: \(names)")
                    }
                    try require(pair.model.document?.base.bytes==leftBytes && pair.model.document?.destination.bytes==rightBytes,"Embedded comparison replaced original wire bytes")
                    pair.close()
                }
            }
            if compressedPaths {
                // Compare the actual compact records against independently
                // encoded float paths in both native IDiff panes.
                for family in ["fill","region","cap"] {
                    let left=corpus.appendingPathComponent("plus-compressed-path-"+family+"-relative.emf"),right=corpus.appendingPathComponent("plus-compressed-path-"+family+"-float.emf")
                    let leftBytes=try Data(contentsOf:left),rightBytes=try Data(contentsOf:right)
                    try require(leftBytes != rightBytes,"Compressed native control must use distinct wire encodings")
                    let pair=track(FileComparisonWindowController(images:try ImageFileComparison(base:left,destination:right),permissions:[],preferences:prefs))
                    pair.model.load();try await wait{!pair.model.busy && pair.model.document != nil}
                    guard let compact=pair.model.imageComparison?.base?.pixels,let control=pair.model.imageComparison?.destination?.pixels else {throw Failure(message:"Compressed/control native pair failed for \(family); \(comparisonState(pair))")}
                    try require(try raster(compact)==raster(control),"Native compressed/control raster mismatch for \(family)")
                    try require(pair.model.document?.base.bytes==leftBytes && pair.model.document?.destination.bytes==rightBytes,"Compressed comparison replaced wire bytes")
                    pair.close()
                }
            }
            if wmfBitmap16 {
                for name in ["bitblt-native","stretch-upscale","word-padding17","crop","mirror-dest-x","live-colors","save-restore","rop-66","rop-c0","clip","mapped","source-independent-color24-bitblt","embedded-affine","pattern-bitmap16","bgrx32-stretch","widthbytes-negative","self-bitblt-overlap","self-stretchblt-copy","shrink-mode1","shrink-mode2","shrink-mode3","self-bitblt-mapped","self-stretchblt-outside-preserve"] {
                    let ext=name=="embedded-affine" ? ".emf":".wmf",left=corpus.appendingPathComponent("wmf-bitmap16-"+name+ext),right=corpus.appendingPathComponent("wmf-bitmap16-"+name+"-control"+ext)
                    let leftBytes=try Data(contentsOf:left),rightBytes=try Data(contentsOf:right)
                    let pair=track(FileComparisonWindowController(images:try ImageFileComparison(base:left,destination:right),permissions:[],preferences:prefs))
                    pair.model.load();try await wait{!pair.model.busy && pair.model.document != nil}
                    guard let a=pair.model.imageComparison?.base?.pixels,let b=pair.model.imageComparison?.destination?.pixels else {throw Failure(message:"Bitmap16 native pair failed; \(comparisonState(pair))")}
                    try require(try raster(a,interior:CGSize(width:64,height:64))==raster(b,interior:CGSize(width:64,height:64)),"Native Bitmap16/DIB raster mismatch: \(name)")
                    try require(pair.model.document?.base.bytes==leftBytes && pair.model.document?.destination.bytes==rightBytes,"Bitmap16 native comparison changed source bytes")
                    pair.close()
                }
                // Both controls use original immutable wires and actual
                // Windows pixels, including the historical integer-box input.
                let basisURL=corpus.appendingPathComponent("Bitmap16Halftone/windows-basis-2026-10-30.json")
                let basis=try JSONSerialization.jsonObject(with:Data(contentsOf:basisURL)) as? [String:Any]
                let signedURL=corpus.appendingPathComponent("Bitmap16Halftone/windows-signed-geometry-2026-10-30.json")
                let signed=try JSONSerialization.jsonObject(with:Data(contentsOf:signedURL)) as? [String:Any]
                guard let continuity=basis?["continuityControl"] as? [String:Any],
                      let signedCases=signed?["cases"] as? [[String:Any]],
                      let integerBox=signedCases.first(where:{$0["id"] as? String == "integer-box"}) else {throw Failure(message:"Missing retained Windows HALFTONE controls")}
                for (name,control,rect) in [("continuity",continuity,[8,8,3,2]),("integer-box",integerBox,[8,8,4,2])] {
                    guard let encoded=control["wireBase64"] as? String,let wire=Data(base64Encoded:encoded),
                          let encodedExpected=control["expectedRGBABase64"] as? String,let measured=Data(base64Encoded:encodedExpected),
                          let frame=control["frame"] as? [Int],frame.count==2,
                          let measuredRect=control["sampleRect"] as? [Int],measuredRect.count==4 else {throw Failure(message:"Invalid Windows HALFTONE control")}
                    if name == "integer-box" {
                        try require(wire == Data(contentsOf:corpus.appendingPathComponent("wmf-bitmap16-halftone-integer-box.wmf")),"Integer-box oracle changed the historical input wire")
                    }
                    var expected=Data()
                    for y in rect[1]..<(rect[1]+rect[3]) {
                        let p=((y-measuredRect[1])*measuredRect[2]+rect[0]-measuredRect[0])*4
                        expected.append(measured[p..<(p+rect[2]*4)])
                    }
                    let left=root.appendingPathComponent("windows-halftone-"+name+"-left.wmf"),right=root.appendingPathComponent("windows-halftone-"+name+"-right.wmf")
                    try wire.write(to:left);try wire.write(to:right)
                    let pair=track(FileComparisonWindowController(images:try ImageFileComparison(base:left,destination:right),permissions:[],preferences:prefs))
                    pair.model.load();try await wait{!pair.model.busy && pair.model.document != nil}
                    guard let a=pair.model.imageComparison?.base?.pixels,let b=pair.model.imageComparison?.destination?.pixels else {throw Failure(message:"Windows HALFTONE native control failed; \(comparisonState(pair))")}
                    for image in [a,b] {
                        try require(image.width==frame[0] && image.height==frame[1],"Windows HALFTONE intrinsic frame changed: "+name)
                        var rgba=Data(count:frame[0]*frame[1]*4)
                        let rendered=rgba.withUnsafeMutableBytes {storage -> Bool in
                            guard let context=CGContext(data:storage.baseAddress,width:frame[0],height:frame[1],bitsPerComponent:8,bytesPerRow:frame[0]*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else{return false}
                            context.interpolationQuality = .none
                            context.draw(image,in:CGRect(x:0,y:0,width:frame[0],height:frame[1]));return true
                        }
                        try require(rendered,"Cannot inspect Windows HALFTONE native pane")
                        var actual=Data()
                        for y in rect[1]..<(rect[1]+rect[3]) {let p=(y*frame[0]+rect[0])*4;actual.append(rgba[p..<(p+rect[2]*4)])}
                        try require(actual==expected,"Native HALFTONE pane differs from exact retained Windows RGBA: "+name)
                    }
                    try require(pair.model.document?.base.bytes==wire && pair.model.document?.destination.bytes==wire,"Windows HALFTONE native comparison changed original wire bytes")
                    pair.close()
                }
            }
            if wmfText {
                for name in ["textout-odd","ext-dx","ext-clip-opaque","ext-updatecp-dx","font-decorated","font-cell","font-angle","restore","translated","charset-204","dbcs-128","embedded-affine","charset-oem437","dbcs-johab","extra-dx-positive","justify-dx-positive","embedded-clip-affine","ext-pdy-ignored","dbcs-single-johab","dbcs-repeat-128"] {
                    let embedded=name.hasPrefix("embedded-")
                    let original=corpus.appendingPathComponent("wmf-text-"+name+(embedded ? ".emf":".wmf"))
                    let originalBytes=try Data(contentsOf:original)
                    // The original WMF's PS_NULL Rectangle intentionally leaves
                    // the last row/column transparent. Its independently framed
                    // EMF control paints those pixels white. Use the original
                    // text records over an explicit full-surface PATCOPY for
                    // exact RGBA equality; retain the differing originals above
                    // and establish their edge-alpha contract separately below.
                    let left=embedded ? original:corpus.appendingPathComponent("wmf-text-"+name+"-full-background.wmf"),right=corpus.appendingPathComponent("wmf-text-"+name+"-control.emf")
                    let leftBytes=try Data(contentsOf:left),rightBytes=try Data(contentsOf:right)
                    if name=="textout-odd" {
                        let raw=track(FileComparisonWindowController(images:try ImageFileComparison(base:original,destination:right),permissions:[],preferences:prefs))
                        raw.model.load();try await wait{!raw.model.busy && raw.model.document != nil}
                        guard let a=raw.model.imageComparison?.base?.pixels,let b=raw.model.imageComparison?.destination?.pixels else {throw Failure(message:"Original WMF edge-alpha witness failed; \(comparisonState(raw))")}
                        let aBytes=try textRGBA(a),bBytes=try textRGBA(b)
                        var differences=0,edgeContract=true
                        for y in 0..<64 {for x in 0..<96 {
                            let start=(y*96+x)*4,aPixel=Array(aBytes[start..<(start+4)]),bPixel=Array(bBytes[start..<(start+4)])
                            if aPixel != bPixel {differences += 1}
                            if x==95 || y==63 {edgeContract = edgeContract && aPixel==[0,0,0,0] && bPixel==[255,255,255,255]}
                            else {edgeContract = edgeContract && aPixel==bPixel}
                        }}
                        if !edgeContract || differences != 159 {
                            do {try retainTextMismatch(name:"original-textout-odd-edge",left:a,right:b,leftSource:original,leftBytes:originalBytes,rightSource:right,rightBytes:rightBytes,leftOracle:try raster(a,interior:CGSize(width:96,height:64)),rightOracle:try raster(b,interior:CGSize(width:96,height:64)),root:root)}catch{print("Original edge diagnostic retention failed: "+error.localizedDescription)}
                        }
                        try require(edgeContract && differences==159,"Original PS_NULL WMF must retain exactly159 transparent right/bottom pixels versus the opaque Unicode EMF control; glyph interior must remain identical")
                        try require(raw.model.document?.base.bytes==originalBytes && raw.model.document?.destination.bytes==rightBytes,"Original edge-alpha inspection changed source bytes")
                        raw.close()
                    }
                    let pair=track(FileComparisonWindowController(images:try ImageFileComparison(base:left,destination:right),permissions:[],preferences:prefs))
                    pair.model.load();try await wait{!pair.model.busy && pair.model.document != nil}
                    guard let a=pair.model.imageComparison?.base?.pixels,let b=pair.model.imageComparison?.destination?.pixels else {throw Failure(message:"WMF text native pair failed; \(comparisonState(pair))")}
                    let leftRaster=try raster(a,interior:CGSize(width:96,height:64)),rightRaster=try raster(b,interior:CGSize(width:96,height:64))
                    let leftSRGB=try textRGBA(a),rightSRGB=try textRGBA(b)
                    if leftRaster != rightRaster || leftSRGB != rightSRGB || ProcessInfo.processInfo.environment["TURTLEGIT_METAFILE_TEXT_CAPTURE"]==name {
                        do {try retainTextMismatch(name:name,left:a,right:b,leftSource:left,leftBytes:leftBytes,rightSource:right,rightBytes:rightBytes,leftOracle:leftRaster,rightOracle:rightRaster,root:root)}
                        catch {print("WMF text mismatch diagnostic retention failed: "+error.localizedDescription)}
                    }
                    try require(leftRaster==rightRaster,"Native WMF/Unicode EMF raster mismatch: \(name)")
                    try require(leftSRGB==rightSRGB,"Native matched-background WMF/Unicode EMF named-sRGB RGBA mismatch: \(name)")
                    if name=="textout-odd" {
                        for y in 0..<64 {for x in 0..<96 where x==95 || y==63 {
                            let start=(y*96+x)*4
                            try require(Array(leftSRGB[start..<(start+4)])==[255,255,255,255] && Array(rightSRGB[start..<(start+4)])==[255,255,255,255],"Matched-background derivative and Unicode control must both paint every original right/bottom background pixel opaque white")
                        }}
                    }
                    try require(pair.model.document?.base.bytes==leftBytes && pair.model.document?.destination.bytes==rightBytes,"WMF native comparison changed source bytes")
                    try require(try Data(contentsOf:original)==originalBytes,"Matched-background control changed its original WMF/embedded source")
                    pair.close()
                }
            }
            if classicTextRecords {
                for name in ["compact-small","compact-low-unicode","compact-clip-opaque","compact-updatecp","poly-wide-dx","poly-wide-pdy","poly-ansi-clip-opaque","ext-ansi-cp1252","ext-charset-204","poly-charset-222","ext-dbcs-128","poly-dbcs-pdy-134","compact-no-rect-opaque","poly-wide-offdx-zero-updatecp"] {
                    let left=corpus.appendingPathComponent("classic-text-"+name+".emf"),right=corpus.appendingPathComponent("classic-text-"+name+"-control.emf")
                    let leftBytes=try Data(contentsOf:left),rightBytes=try Data(contentsOf:right)
                    let pair=track(FileComparisonWindowController(images:try ImageFileComparison(base:left,destination:right),permissions:[],preferences:prefs))
                    pair.model.load();try await wait{!pair.model.busy && pair.model.document != nil}
                    guard let a=pair.model.imageComparison?.base?.pixels,let b=pair.model.imageComparison?.destination?.pixels else {throw Failure(message:"Compact/batched classic native pair failed; \(comparisonState(pair))")}
                    try require(try raster(a)==raster(b),"Native compact/batched/wide raster mismatch: \(name)")
                    try require(pair.model.document?.base.bytes==leftBytes && pair.model.document?.destination.bytes==rightBytes,"Classic text native comparison changed source bytes")
                    pair.close()
                }
            }
            if positionedText {
                let pairs=[["plus-driver-positioned","classic-positioned-dx"],["plus-driver-positioned-full-background","classic-positioned-dx"],["classic-positioned-compatible-dx","plus-driver-compatible-dx"],["classic-positioned-compatible-dx","plus-driver-compatible-dx-full-background"],["plus-driver-positioned","plus-driver-positioned-native-glyphs"],["classic-positioned-dx","classic-positioned-dx-native-glyphs"]]
                for names in pairs {
                    func url(_ name:String)->URL {name.hasSuffix("native-glyphs") ? root.appendingPathComponent(name+".emf") : corpus.appendingPathComponent(name+".emf")}
                    let left=url(names[0]),right=url(names[1]),leftBytes=try Data(contentsOf:left),rightBytes=try Data(contentsOf:right)
                    let pair=track(FileComparisonWindowController(images:try ImageFileComparison(base:left,destination:right),permissions:[],preferences:prefs))
                    pair.model.load();try await wait{!pair.model.busy && pair.model.document != nil}
                    guard let a=pair.model.imageComparison?.base?.pixels,let b=pair.model.imageComparison?.destination?.pixels else {throw Failure(message:"Positioned glyph native pair failed; \(comparisonState(pair))")}
                    try require(a.width==97 && a.height==65 && b.width==97 && b.height==65,"Positioned comparisons must retain their entire inclusive97x65 canvas")
                    let leftOracle=try raster(a),rightOracle=try raster(b),leftRGBA=try textRGBA(a,fullCanvas:true),rightRGBA=try textRGBA(b,fullCanvas:true)
                    let originalBackgroundPair=names==pairs[0] || names==pairs[2]
                    if originalBackgroundPair {
                        @MainActor func requireOriginal(_ condition:Bool,_ message:String)throws {
                            if !condition {try retainTextMismatch(name:names.joined(separator:"--"),left:a,right:b,leftSource:left,leftBytes:leftBytes,rightSource:right,rightBytes:rightBytes,leftOracle:leftOracle,rightOracle:rightOracle,root:root,fullCanvas:true)}
                            try require(condition,message)
                        }
                        if ProcessInfo.processInfo.environment["TURTLEGIT_METAFILE_CAPTURE_TEXT_DIAGNOSTICS"]=="1" {try retainTextMismatch(name:names.joined(separator:"--"),left:a,right:b,leftSource:left,leftBytes:leftBytes,rightSource:right,rightBytes:rightBytes,leftOracle:leftOracle,rightOracle:rightOracle,root:root,fullCanvas:true)}
                        // Original EMF+ explicitly paints96x64; classic supplies
                        // an opaque97x65 canvas. Every nonedge pixel, including
                        // all glyph coverage/antialiasing, must still match.
                        var differences=0
                        for y in 0..<65 {for x in 0..<97 {
                            let p=(y*97+x)*4,l=Array(leftRGBA[p..<(p+4)]),r=Array(rightRGBA[p..<(p+4)])
                            if x==96 || y==64 {
                                let transparent:[UInt8]=[0,0,0,0],white:[UInt8]=[255,255,255,255]
                                try requireOriginal(l==(names==pairs[0] ? transparent:white) && r==(names==pairs[0] ? white:transparent),"Original positioned background alpha contract changed at \(x),\(y)")
                                differences += 1
                            } else {try requireOriginal(l==r,"Original positioned glyph/content mismatch at \(x),\(y)")}
                        }}
                        try require(differences==161,"Original positioned full-canvas difference must be exactly161 outer edge pixels")
                    } else {
                        if leftOracle != rightOracle || leftRGBA != rightRGBA || ProcessInfo.processInfo.environment["TURTLEGIT_METAFILE_CAPTURE_TEXT_DIAGNOSTICS"]=="1" {
                            try retainTextMismatch(name:names.joined(separator:"--"),left:a,right:b,leftSource:left,leftBytes:leftBytes,rightSource:right,rightBytes:rightBytes,leftOracle:leftOracle,rightOracle:rightOracle,root:root,fullCanvas:true)
                        }
                        try require(leftOracle==rightOracle && leftRGBA==rightRGBA,"Native positioned/cmap/raw-glyph full-canvas raster mismatch: \(names)")
                        if names.contains(where:{$0.hasSuffix("full-background")}) {
                            for y in 0..<65 {for x in 0..<97 where x==96 || y==64 {
                                let p=(y*97+x)*4
                                try require(Array(leftRGBA[p..<(p+4)])==[255,255,255,255] && Array(rightRGBA[p..<(p+4)])==[255,255,255,255],"Matched positioned derivative must paint all161 outer pixels opaque white")
                            }}
                        }
                    }
                    try require(pair.model.document?.base.bytes==leftBytes && pair.model.document?.destination.bytes==rightBytes,"Positioned native comparison changed source bytes")
                    pair.close()
                }
            }
            if historicalOnly {
                for (sample,bytes) in zip(samples,inputs) {try require(try Data(contentsOf:sample)==bytes,"Historical positive conversion modified source bytes")}
                try phase("historical positive cleanup");try await cleanup();try phase("historical positive cohort complete")
                print("PASS: all supported historical metafile names, independent native pixel/route/byte oracles, closed/drained owners")
                return
            }
            for (ordinal,sample) in unsupported.enumerated() {
                try phase("negative input",sample:sample.lastPathComponent,state:"ordinal=\(ordinal+1)/\(unsupported.count)")
                let bytes=try Data(contentsOf:sample),owner=track(FileComparisonWindowController(images:try ImageFileComparison(base:sample,destination:nil),permissions:[],preferences:prefs))
                owner.model.load();try phase("negative native load",sample:sample.lastPathComponent,state:comparisonState(owner))
                try await wait(diagnostic:{comparisonState(owner)}) {!owner.model.busy && owner.model.document != nil}
                try require(owner.model.viewerSelection == .image && owner.model.imageComparison != nil && owner.model.imageComparison?.base == nil && owner.model.imageComparison?.destination == nil && owner.model.document?.base.bytes == bytes,"Unsupported metafile escaped explicit IDiff or lost original bytes; \(comparisonState(owner))")
                owner.close()
                try await wait(diagnostic:{comparisonState(owner)}) {drained() && owner.window?.attachedSheet==nil && owner.window?.isVisible != true}
                try require(try Data(contentsOf:sample)==bytes,"Malformed-image refusal modified source bytes")
                try phase("negative complete",sample:sample.lastPathComponent,state:comparisonState(owner))
            }
            if negativeOnly {
                for (sample,bytes) in zip(samples,inputs) {try require(try Data(contentsOf:sample)==bytes,"Negative cohort modified positive corpus bytes")}
                try phase("negative cleanup");try await cleanup();try phase("negative cohort complete",state:cohort ?? "missing")
                print("PASS: complete deterministic malformed consumer cohort \(cohort ?? "missing"), \(unsupported.count) native refusals with unchanged bytes and drained owners/helpers")
                return
            }
            guard let first else {throw Failure(message:"No metafile comparison")}
            try phase("preview drop and reload")
            let original=first.model.document!,pane=first.model.imageViewerModel,drop=root.appendingPathComponent("preview.emf")
            let preview:URL
            if wmfBitmap16 {preview=corpus.appendingPathComponent("wmf-bitmap16-embedded-affine.emf")}
            else if wmfText {preview=corpus.appendingPathComponent("wmf-text-embedded-affine.emf")}
            else if classicTextRecords {preview=corpus.appendingPathComponent("classic-text-compact-small.emf")}
            else if formattedDigits {preview=corpus.appendingPathComponent("windows-formatted-lrm-latin-display.emf")}
            else if positionedText {preview=corpus.appendingPathComponent("plus-driver-positioned.emf")}
            else if compressedPaths {preview=corpus.appendingPathComponent("plus-compressed-path-fill-relative.emf")}
            else {preview=try firstSample(samples,withExtension:"emf")}
            let previewBytes=try Data(contentsOf:preview)
            try previewBytes.write(to:drop)
            try require(pane.dropFile(drop,base:false),"Metafile pane drop refused")
            try await wait {!pane.receivingDrop}
            try require(pane.currentImage(base:false) != nil && pane.droppedFiles[false]?.bytes == previewBytes && first.model.document?.destination.bytes == bad,"Metafile preview failed or replaced original comparison")
            if formattedDigits {
                let dimensions=renderedDimensions(preview)
                try require(pane.currentImage(base:false)?.pixels.width==dimensions.0 && pane.currentImage(base:false)?.pixels.height==dimensions.1,"Formatted-digit drop preview lost its source extent")
            }
            first.model.load();try await wait {!first.model.busy && pane.droppedFiles.isEmpty}
            try require(first.model.document?.base.bytes == original.base.bytes && pane.currentImage(base:false) == nil,"Reload did not restore original metafile inputs")

            // Exercise actual IDiff Open acceptance through its owned chooser,
            // including the native detach before the captured reload is admitted.
            try phase("owned image Open chooser")
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

            if !wmfBitmap16 && !wmfText && !classicTextRecords && !formattedDigits && !compressedRaster && !embeddedMetafiles && !compressedPaths && !positionedText && !classicPens && !classicRegions && !classicPatternBrushes {
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

            }
            // A noncooperative decoder must not block the main actor or release
            // the captured comparison session before its true completion.
            try phase("held comparison decoder")
            let late=track(FileComparisonWindowController(comparison:try WorkingFileComparison(base:samples[0],destination:samples[0]),permissions:[],preferences:prefs,deferInitialLoad:true))
            var comparisonToken:OperationCancellation?
            late.model.decodeImages={_,token in comparisonToken=token;return await withCheckedContinuation {comparisonHold=$0}}
            late.model.beginTransferredDocument();try await wait(diagnostic:{comparisonState(late)}) {comparisonHold != nil}
            try require(late.model.busy && FileListComparisonSession.activeOperations == 1,"Detached comparison lost complete session lifetime; \(comparisonState(late))")
            late.close();try require(comparisonToken?.isCancelled == true && FileListComparisonSession.activeOperations == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Closing comparison lost live decoder/Quit ownership; \(comparisonState(late)); tokenCancelled=\(String(describing:comparisonToken?.isCancelled))")
            comparisonHold?.resume(returning:ImageComparisonDocument(base:nil,destination:nil));comparisonHold=nil
            try await wait {!late.model.busy && FileListComparisonSession.activeOperations == 0}
            try require(late.model.document == nil && late.model.imageComparison == nil,"Retired comparison published late decoder result; \(comparisonState(late))")

            try phase("held dropped-image decoder")
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
            try phase("replacement dropped-image decoder")
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
            try phase("three-stage conflict fixture")
            let work=root.appendingPathComponent("repository");try FileManager.default.createDirectory(at:work,withIntermediateDirectories:true)
            let repo=GitRepository(root:work,executable:git),path="drawing.emf",file=work.appendingPathComponent(path)
            _ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","Metafile consumers QA"),("user.email","metafile@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
            var compressedConflictIndices:[Int]=[]
            if compressedRaster {
                for name in ["compressed-raster-stretch-jpeg-wmf.wmf","compressed-raster-stretch-png-emf.emf","compressed-raster-image-tiff-alpha.emf"] {
                    guard let index=samples.firstIndex(where:{$0.lastPathComponent==name}) else {throw Failure(message:"Missing compressed conflict source: "+name)}
                    compressedConflictIndices.append(index)
                }
            }
            let wmfIndex:Int,classicIndex:Int,plusIndex:Int
            if dibProfiles {
                func profileIndex(_ name:String)throws->Int {
                    guard let index=samples.firstIndex(where:{$0.lastPathComponent==name}) else {throw Failure(message:"Missing DIB profile conflict source: "+name)}
                    return index
                }
                wmfIndex=try profileIndex("wmf-raster-embedded-linear-rgb-after.wmf")
                classicIndex=try profileIndex("emf-raster-embedded-linear-rgb-before-icm-on.emf")
                plusIndex=try profileIndex("emf-brush-embedded-linear-rgb-after.emf")
            } else if formattedDigits {
                func digitIndex(_ name:String)throws->Int {
                    guard let index=samples.firstIndex(where:{$0.lastPathComponent==name}) else {throw Failure(message:"Missing formatted-digit conflict source: "+name)}
                    return index
                }
                wmfIndex=try digitIndex("windows-formatted-lrm-latin-display.emf")
                classicIndex=try digitIndex("windows-formatted-zwj-alone-display.emf")
                plusIndex=try digitIndex("plus-formatted-controls-lrm-context-display.emf")
            } else {
                let legacyWMF=wmfBitmap16 ? samples.firstIndex{$0.lastPathComponent=="wmf-bitmap16-bitblt-native.wmf"}! : wmfText ? samples.firstIndex{$0.lastPathComponent=="wmf-text-textout-odd.wmf"}! : classicTextRecords ? samples.firstIndex{$0.lastPathComponent=="classic-text-compact-small.emf"}! : compressedRaster ? compressedConflictIndices[0] : embeddedMetafiles ? samples.firstIndex{$0.lastPathComponent=="embedded-image-wmf.emf"}! : classicPatternBrushes ? samples.firstIndex{$0.lastPathComponent=="wmf-classic-patternbrush-mono.wmf"}! : classicRegions ? samples.firstIndex{$0.lastPathComponent=="wmf-classic-region-fill-preserve.wmf"}! : classicPens ? samples.firstIndex{$0.lastPathComponent=="classic-extpen-custom.emf"}! : positionedText ? samples.firstIndex{$0.lastPathComponent=="classic-positioned-dx.emf"}! : compressedPaths ? samples.firstIndex{$0.lastPathComponent=="plus-compressed-path-fill-relative.emf"}! : samples.firstIndex {$0.pathExtension.lowercased()=="wmf"}!,legacyClassic=wmfBitmap16 ? samples.firstIndex{$0.lastPathComponent=="wmf-bitmap16-rop-66.wmf"}! : wmfText ? samples.firstIndex{$0.lastPathComponent=="wmf-text-ext-clip-opaque.wmf"}! : classicTextRecords ? samples.firstIndex{$0.lastPathComponent=="classic-text-poly-wide-pdy.emf"}! : compressedRaster ? compressedConflictIndices[1] : embeddedMetafiles ? samples.firstIndex{$0.lastPathComponent=="embedded-image-emf.emf"}! : classicPatternBrushes ? samples.firstIndex{$0.lastPathComponent=="classic-monobrush-dynamic.emf"}! : classicRegions ? samples.firstIndex{$0.lastPathComponent=="classic-region-frame-union.emf"}! : classicPens ? samples.firstIndex{$0.lastPathComponent=="classic-extpen-hatch-4.emf"}! : positionedText ? samples.firstIndex{$0.lastPathComponent=="plus-driver-positioned.emf"}! : compressedPaths ? samples.firstIndex{$0.lastPathComponent=="plus-compressed-path-region-relative.emf"}! : samples.firstIndex {$0.pathExtension.lowercased()=="emf" && !$0.lastPathComponent.lowercased().contains("plus")}!,legacyPlus=wmfBitmap16 ? samples.firstIndex{$0.lastPathComponent=="wmf-bitmap16-embedded-affine.emf"}! : wmfText ? samples.firstIndex{$0.lastPathComponent=="wmf-text-embedded-affine.emf"}! : classicTextRecords ? samples.firstIndex{$0.lastPathComponent=="classic-text-ext-ansi-cp1252.emf"}! : compressedRaster ? compressedConflictIndices[2] : embeddedMetafiles ? samples.firstIndex{$0.lastPathComponent=="embedded-compositing-copy.emf"}! : classicPatternBrushes ? samples.firstIndex{$0.lastPathComponent=="classic-monobrush-colored.emf"}! : classicRegions ? samples.firstIndex{$0.lastPathComponent=="classic-flood-surface.emf"}! : classicPens ? samples.firstIndex{$0.lastPathComponent=="classic-extpen-dib.emf"}! : positionedText ? samples.firstIndex{$0.lastPathComponent=="plus-driver-gradient.emf"}! : compressedPaths ? samples.firstIndex{$0.lastPathComponent=="plus-compressed-path-cap-relative.emf"}! : samples.firstIndex {$0.pathExtension.lowercased()=="emf" && $0.lastPathComponent.lowercased().contains("plus")}!
                (wmfIndex,classicIndex,plusIndex)=(legacyWMF,legacyClassic,legacyPlus)
            }
            try inputs[wmfIndex].write(to:file);try await repo.stage([path]);_ = try await repo.commit(message:"base WMF")
            _ = try await repo.run(["switch","-c","side"]);try inputs[classicIndex].write(to:file);try await repo.stage([path]);_ = try await repo.commit(message:"incoming EMF")
            _ = try await repo.run(["switch","main"]);try inputs[plusIndex].write(to:file);try await repo.stage([path]);_ = try await repo.commit(message:"mine EMF+")
            do {_ = try await repo.run(["merge","--no-edit","side"]);throw Failure(message:"Expected metafile conflict")}catch is GitFailure {}
            guard let conflictDocument=try await repo.imageConflictDocument(path:path) else {throw Failure(message:"Metafile conflict did not dispatch to IDiff")}
            let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:work.appendingPathComponent(".git/index")),working=try Data(contentsOf:file)
            let conflict=track(ImageConflictWindowController(repository:repo,access:nil,document:conflictDocument,preferences:prefs))
            try await wait {!conflict.model.busy}
            let conflictDimensions=ImageConflictSide.allCases.map {side in "\(side)=\(conflict.model.panes[side]?.currentImage(base:true)?.pixels.width ?? -1)x\(conflict.model.panes[side]?.currentImage(base:true)?.pixels.height ?? -1)"}.joined(separator:", ")
            let sourceIndices:[ImageConflictSide:Int]=[.base:wmfIndex,.theirs:classicIndex,.mine:plusIndex]
            try require(conflict.model.images.count == 3 && ImageConflictSide.allCases.allSatisfy {side in
                guard let source=sourceIndices[side] else{return false}
                let dimensions=renderedDimensions(samples[source])
                return conflict.model.canSelect(side) && conflict.model.panes[side]?.currentImage(base:true)?.pixels.width==dimensions.0 && conflict.model.panes[side]?.currentImage(base:true)?.pixels.height==dimensions.1
            },"Three-side metafile conflict failed expected source dimensions; samples=\([samples[wmfIndex].lastPathComponent,samples[classicIndex].lastPathComponent,samples[plusIndex].lastPathComponent]); actual \(conflictDimensions); error=\(conflict.model.error ?? "none")")
            conflict.model.reload();try await wait {!conflict.model.busy}
            try require(conflict.model.images.count == 3,"Metafile conflict reload lost an image")
            try require(conflict.model.document.contents[.base]==inputs[wmfIndex] && conflict.model.document.contents[.theirs]==inputs[classicIndex] && conflict.model.document.contents[.mine]==inputs[plusIndex],"Metafile conflict decoding rewrote source stage encodings")
            if !wmfBitmap16 && !wmfText && !classicTextRecords && !formattedDigits && !compressedRaster && !embeddedMetafiles && !compressedPaths && !positionedText && !classicPens && !classicRegions && !classicPatternBrushes {
            // The newly accepted region, hatch and texture families also enter
            // actual three-stage conflict panes, not only standalone decoders.
            let patternWork=root.appendingPathComponent("pattern repository")
            try FileManager.default.createDirectory(at:patternWork,withIntermediateDirectories:true)
            let patternRepo=GitRepository(root:patternWork,executable:git),patternFile=patternWork.appendingPathComponent(path)
            _ = try await patternRepo.run(["init","-b","main"])
            for (key,value) in [("user.name","Pattern consumers QA"),("user.email","patterns@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await patternRepo.run(["config",key,value])}
            let regionBytes=try Data(contentsOf:suppliedCorpus.appendingPathComponent("plus-region-path.emf")),hatchBytes=try Data(contentsOf:suppliedCorpus.appendingPathComponent("plus-hatch-atlas.emf")),textureBytes=try Data(contentsOf:suppliedCorpus.appendingPathComponent("plus-texture-world.emf"))
            try regionBytes.write(to:patternFile);try await patternRepo.stage([path]);_ = try await patternRepo.commit(message:"base region")
            _ = try await patternRepo.run(["switch","-c","side"]);try hatchBytes.write(to:patternFile);try await patternRepo.stage([path]);_ = try await patternRepo.commit(message:"incoming hatch")
            _ = try await patternRepo.run(["switch","main"]);try textureBytes.write(to:patternFile);try await patternRepo.stage([path]);_ = try await patternRepo.commit(message:"mine texture")
            do {_ = try await patternRepo.run(["merge","--no-edit","side"]);throw Failure(message:"Expected region/pattern metafile conflict")}catch is GitFailure {}
            guard let patternDocument=try await patternRepo.imageConflictDocument(path:path) else {throw Failure(message:"Region/pattern conflict did not dispatch to IDiff")}
            let patternHead=try await patternRepo.run(["rev-parse","HEAD"]).stdout,patternIndex=try Data(contentsOf:patternWork.appendingPathComponent(".git/index")),patternWorking=try Data(contentsOf:patternFile)
            let patternConflict=track(ImageConflictWindowController(repository:patternRepo,access:nil,document:patternDocument,preferences:prefs))
            try await wait {!patternConflict.model.busy}
            try require(patternConflict.model.images.count==3 && ImageConflictSide.allCases.allSatisfy {patternConflict.model.canSelect($0) && patternConflict.model.panes[$0]?.currentImage(base:true)?.pixels.width==97 && patternConflict.model.panes[$0]?.currentImage(base:true)?.pixels.height==65},"Region/hatch/texture conflict panes failed to decode: \(patternConflict.model.error ?? "none")")
            try require(patternConflict.model.document.contents[.base]==regionBytes && patternConflict.model.document.contents[.theirs]==hatchBytes && patternConflict.model.document.contents[.mine]==textureBytes,"Region/pattern conflict decoding rewrote original stages")
            patternConflict.model.reload();try await wait {!patternConflict.model.busy}
            try require(patternConflict.model.images.count==3,"Region/pattern conflict reload lost a side")
            patternConflict.close();try await wait {ImageConflictWindowModel.activeOperations==0 && patternConflict.window?.isVisible != true}
            try require(try await patternRepo.run(["rev-parse","HEAD"]).stdout==patternHead,"Region/pattern preview moved HEAD")
            try require((try Data(contentsOf:patternWork.appendingPathComponent(".git/index")))==patternIndex && (try Data(contentsOf:patternFile))==patternWorking,"Region/pattern preview mutated conflict index/working bytes")
            // Newly supported raw formats traverse real conflict stages too;
            // decoding and reload retain the exact original stage bytes.
            let rawWork=root.appendingPathComponent("raw repository")
            try FileManager.default.createDirectory(at:rawWork,withIntermediateDirectories:true)
            let rawRepo=GitRepository(root:rawWork,executable:git),rawFile=rawWork.appendingPathComponent(path)
            _ = try await rawRepo.run(["init","-b","main"])
            for (key,value) in [("user.name","Raw consumers QA"),("user.email","raws@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await rawRepo.run(["config",key,value])}
            let indexedBytes=try Data(contentsOf:suppliedCorpus.appendingPathComponent("plus-raw-indexed4-negative.emf")),packedBytes=try Data(contentsOf:suppliedCorpus.appendingPathComponent("plus-raw-rgb565-positive.emf")),rawTextureBytes=try Data(contentsOf:suppliedCorpus.appendingPathComponent("plus-raw-texture-indexed-alpha.emf"))
            try indexedBytes.write(to:rawFile);try await rawRepo.stage([path]);_ = try await rawRepo.commit(message:"base indexed")
            _ = try await rawRepo.run(["switch","-c","side"]);try packedBytes.write(to:rawFile);try await rawRepo.stage([path]);_ = try await rawRepo.commit(message:"incoming packed16")
            _ = try await rawRepo.run(["switch","main"]);try rawTextureBytes.write(to:rawFile);try await rawRepo.stage([path]);_ = try await rawRepo.commit(message:"mine indexed texture")
            do {_ = try await rawRepo.run(["merge","--no-edit","side"]);throw Failure(message:"Expected indexed/16-bit metafile conflict")}catch is GitFailure {}
            guard let rawDocument=try await rawRepo.imageConflictDocument(path:path) else {throw Failure(message:"Indexed/16-bit conflict did not dispatch to IDiff")}
            let rawHead=try await rawRepo.run(["rev-parse","HEAD"]).stdout,rawIndex=try Data(contentsOf:rawWork.appendingPathComponent(".git/index")),rawWorking=try Data(contentsOf:rawFile)
            let rawConflict=track(ImageConflictWindowController(repository:rawRepo,access:nil,document:rawDocument,preferences:prefs))
            try await wait {!rawConflict.model.busy}
            try require(rawConflict.model.images.count==3 && ImageConflictSide.allCases.allSatisfy {rawConflict.model.canSelect($0) && rawConflict.model.panes[$0]?.currentImage(base:true)?.pixels.width==97 && rawConflict.model.panes[$0]?.currentImage(base:true)?.pixels.height==65},"Indexed/16-bit/texture conflict panes failed to decode: \(rawConflict.model.error ?? "none")")
            try require(rawConflict.model.document.contents[.base]==indexedBytes && rawConflict.model.document.contents[.theirs]==packedBytes && rawConflict.model.document.contents[.mine]==rawTextureBytes,"Indexed/16-bit conflict decoding rewrote original stages")
            rawConflict.model.reload();try await wait {!rawConflict.model.busy}
            try require(rawConflict.model.images.count==3,"Indexed/16-bit conflict reload lost a side")
            rawConflict.close();try await wait {ImageConflictWindowModel.activeOperations==0 && rawConflict.window?.isVisible != true}
            try require(try await rawRepo.run(["rev-parse","HEAD"]).stdout==rawHead,"Indexed/16-bit preview moved HEAD")
            try require((try Data(contentsOf:rawWork.appendingPathComponent(".git/index")))==rawIndex && (try Data(contentsOf:rawFile))==rawWorking,"Indexed/16-bit preview mutated conflict index/working bytes")
            }
            try phase("held conflict reload and retirement")
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
            try phase("final cleanup");try await cleanup();try phase("workflow complete")
            if formattedDigits {print("PASS: formatted Windows numeric paint, zero-advance controls and native recordings, hotkey/vertical/wrap/gradient native IDiff, malformed refusal, WMF/classic baselines, preview/reload and actual three-stage conflict with held cancellation/retirement; original bytes and HEAD/index unchanged")}
            else if embeddedMetafiles {print("PASS: embedded WMF/placeable/EMF/EMF+ live image and isolated texture native IDiff, malformed refusal, drop/Open, actual conflict stages and held cancel/retire/Quit ownership; original bytes preserved")}
            else if classicPatternBrushes {print("PASS: classic mono/DDB/DIB pattern brushes native default and explicit IDiff, live/fixed/palette colors, actual three-stage conflict and held owner retirement; original bytes and HEAD/index preserved")}
            else if classicRegions {print("PASS: classic EMF/WMF region/frame/flood native default and explicit IDiff, malformed whole-image refusal, preview/reload, actual three-stage conflict and held owner retirement; original source bytes and HEAD/index unchanged")}
            else if classicPens {print("PASS: classic extended-pen dash/hatch/DIB/InsideFrame/state native default and explicit IDiff, malformed whole-image refusal, preview/reload, actual three-stage conflict and held owner retirement; original source bytes and HEAD/index unchanged")}
            else if wmfBitmap16 {print("PASS: WMF Bitmap16/DIB native pairs, malformed refusal, dropped preview, three-stage conflict, chooser/cancel/late-result/grant/Quit ownership; source bytes and HEAD/index unchanged")}
            else if wmfText {print("PASS: WMF outlined text/Unicode EMF native pairs, malformed refusal, dropped preview, three-stage conflict, chooser/cancel/late-result/grant/Quit ownership; source bytes and HEAD/index unchanged")}
            else if classicTextRecords {print("PASS: compact/batched/ANSI native pairs, malformed refusal, dropped preview, three-stage conflict, chooser/cancel/late-result/grant/Quit ownership; source bytes and HEAD/index unchanged")}
            else if positionedText {print("PASS: positioned Unicode/raw glyph native pairs, malformed refusal, dropped preview, three-stage conflict, chooser/cancel/late-result/grant/Quit ownership; source bytes and HEAD/index unchanged")}
            else if compressedPaths {print("PASS: compressed EMF+ normal/region/custom-cap native IDiff raster controls, malformed refusal, drop/reload, exact Git conflict stages, chooser/cancel/late-result/grant/Quit ownership; original bytes and HEAD/index unchanged")}
            else {print("PASS: actual WMF/EMF/EMF+, indexed/16bit raw and region/hatch/texture default two-side and conflict decode/reload, unsupported-side IDiff and explicit Merge routing, preview-only drop, cancellation/late-result/session/grant/Quit ownership; original corpus/comparison/conflict HEAD/index/working bytes unchanged")}
        } catch {
            let record:[String:Any]=["phase":currentPhase,"error":String(String(reflecting:error).prefix(16384)),"history":phaseHistory]
            try? JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("fixture-failure.json"),options:.atomic)
            let original=error
            do {try await cleanup()} catch {throw Failure(message:"\(original); cleanup: \(error)")}
            throw original
        }
    }
    private static func rawGlyphCopy(_ original:Data)throws->Data {
        var bytes=original
        func u32(_ p:Int)throws->Int {try { guard p>=0,p+4<=bytes.count else{throw Failure(message:"Native glyph fixture offset")};return (0..<4).reduce(0){$0|Int(bytes[p+$1])<<($1*8)} }()}
        func put32(_ value:Int,_ p:Int){for k in 0..<4{bytes[p+k]=UInt8(truncatingIfNeeded:value>>(k*8))}}
        func replace(_ p:Int,_ count:Int)throws {
            try require(count>0 && count<1024,"Native glyph fixture count")
            let chars=try (0..<count).map { index -> UniChar in let q=p+index*2;guard q+2<=bytes.count else{throw Failure(message:"Native glyph fixture truncated")};return UInt16(bytes[q])|UInt16(bytes[q+1])<<8 }
            let font=CTFontCreateWithName("Helvetica" as CFString,18,nil)
            var glyphs=[CGGlyph](repeating:0,count:count)
            let mapped=chars.withUnsafeBufferPointer{characters in glyphs.withUnsafeMutableBufferPointer{output in CTFontGetGlyphsForCharacters(font,characters.baseAddress!,output.baseAddress!,count)}}
            try require(mapped,"Native Helvetica cmap unavailable")
            for (index,glyph) in glyphs.enumerated(){try require(glyph>0,"Native Helvetica glyph missing");let q=p+index*2;bytes[q]=UInt8(truncatingIfNeeded:glyph);bytes[q+1]=UInt8(truncatingIfNeeded:glyph>>8)}
        }
        var cursor=88,found=false
        while cursor+8<=bytes.count {
            let type=try u32(cursor),size=try u32(cursor+4);guard size>=8,cursor+size<=bytes.count else{throw NSError(domain:"Positioned fixture framing",code:1)}
            if type==84 {let body=cursor+8,count=try u32(body+36),offset=try u32(body+40);try replace(cursor+offset,count);put32(try u32(body+44)|0x10,body+44);found=true}
            if type==70,cursor+16<=bytes.count,bytes.subdata(in:cursor+12..<cursor+16)==Data("EMF+".utf8) {
                var item=cursor+16
                while item+12<=cursor+size {
                    let kind=Int(bytes[item])|Int(bytes[item+1])<<8,length=try u32(item+4)
                    guard length>=12,item+length<=cursor+size else{throw NSError(domain:"Positioned plus fixture framing",code:1)}
                    if kind==0x4036 {let body=item+12,count=try u32(body+12);try replace(body+16,count);put32((try u32(body+4)) & ~1,body+4);found=true}
                    item+=length
                }
            }
            cursor+=size
        }
        try require(found && bytes != original,"Native glyph fixture unchanged");return bytes
    }
    private static func patternRGB(_ image:CGImage,_ x:Int,_ y:Int,_ expected:[Int],_ label:String)throws {
        var bytes=[UInt8](repeating:0,count:image.width*image.height*4)
        let rendered=bytes.withUnsafeMutableBytes{storage->Bool in guard let context=CGContext(data:storage.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else{return false};context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));return true}
        try require(rendered,"Native bitmap brush raster failed")
        let p=(y*image.width+x)*4,actual=Array(bytes[p..<p+4]).map(Int.init)
        try require(zip(actual.prefix(3),expected).allSatisfy{pair in abs(pair.0-pair.1)<=3} && actual[3]==255,label+" sample(\(x),\(y))=\(actual), expected=\(expected)")
    }
    private static func textRuntimeIdentity()throws->[String:Any] {
        let helper=try MetafileImageDecoder.executable()
        func identity(_ url:URL)throws->[String:Any] {
            let bytes=try Data(contentsOf:url)
            return ["path":url.path,"bytes":bytes.count,"sha256":SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()]
        }
        var result:[String:Any]=["helper":try identity(helper),"phase":"Diagnostic-time resolver identity; no conversion result is substituted for the failed native image."]
        for leaf in ["renderer.js","provenance.json"] {
            let url=helper.deletingLastPathComponent().appendingPathComponent(leaf)
            if FileManager.default.fileExists(atPath:url.path) {result[leaf]=try identity(url)}
        }
        return result
    }
    private static func textRGBA(_ image:CGImage,fullCanvas:Bool=false)throws->Data {
        let width=fullCanvas ? image.width:96,height=fullCanvas ? image.height:64
        guard let crop=fullCanvas ? image:image.cropping(to:CGRect(x:0,y:0,width:width,height:height)),crop.width==width,crop.height==height,let space=CGColorSpace(name:CGColorSpace.sRGB) else {throw Failure(message:"Cannot normalize diagnostic native text image")}
        var bytes=Data(count:width*height*4)
        let success=bytes.withUnsafeMutableBytes {storage->Bool in
            guard let context=CGContext(data:storage.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else{return false}
            context.interpolationQuality = .none;context.draw(crop,in:CGRect(x:0,y:0,width:width,height:height));return true
        }
        guard success else {throw Failure(message:"Cannot normalize diagnostic native text image")};return bytes
    }
    /// Diagnostic output never replaces the original exact equality oracle.
    /// Native backing bytes and normalized bytes remain separate so a host
    /// color/byte-order difference is not mistaken for a renderer difference.
    private static func retainTextMismatch(name:String,left:CGImage,right:CGImage,leftSource:URL,leftBytes:Data,rightSource:URL,rightBytes:Data,leftOracle:Data,rightOracle:Data,root:URL,fullCanvas:Bool=false)throws {
        let width=fullCanvas ? left.width:96,height=fullCanvas ? left.height:64
        let directory=root.appendingPathComponent("metafile-text-mismatch",isDirectory:true).appendingPathComponent(name,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        func save(_ bytes:Data,_ leaf:String)throws {try bytes.write(to:directory.appendingPathComponent(leaf),options:.atomic)}
        func hash(_ bytes:Data)->String {SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
        func png(_ image:CGImage,_ leaf:String)throws {
            let data=NSMutableData()
            guard let destination=CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil) else {throw Failure(message:"Cannot encode mismatch PNG")}
            CGImageDestinationAddImage(destination,image,nil)
            guard CGImageDestinationFinalize(destination) else {throw Failure(message:"Cannot finish mismatch PNG")}
            try save(data as Data,leaf)
        }
        func metadata(_ image:CGImage,_ side:String)throws->[String:Any] {
            var result:[String:Any]=["width":image.width,"height":image.height,"bitsPerComponent":image.bitsPerComponent,"bitsPerPixel":image.bitsPerPixel,"bytesPerRow":image.bytesPerRow,"alphaInfo":image.alphaInfo.rawValue,"bitmapInfo":image.bitmapInfo.rawValue,"byteOrderMask":image.bitmapInfo.intersection(.byteOrderMask).rawValue,"shouldInterpolate":image.shouldInterpolate,"renderingIntent":image.renderingIntent.rawValue]
            if let space=image.colorSpace {
                result["colorSpace"]=["name":space.name.map{$0 as String} ?? "unnamed","model":space.model.rawValue,"components":space.numberOfComponents]
                if let profile=space.copyICCData() as Data? {try save(profile,side+"-profile.icc");result["profileSHA256"]=hash(profile)}
            }
            if let storage=image.dataProvider?.data as Data?,storage.count<=16*1024*1024 {try save(storage,side+"-native-storage.bin");result["nativeStorageBytes"]=storage.count;result["nativeStorageSHA256"]=hash(storage)}
            try png(image,side+"-native.png")
            return result
        }
        func difference(_ a:Data,_ b:Data)->[String:Any] {
            guard a.count==b.count,a.count==width*height*4 else{return ["leftBytes":a.count,"rightBytes":b.count,"sizeMismatch":true]}
            var pixels=0,channels=0,maxDelta=0,minX=width,minY=height,maxX = -1,maxY = -1,first:[[String:Any]]=[]
            for pixel in 0..<(width*height) {
                var changed=false
                for channel in 0..<4 {let delta=abs(Int(a[pixel*4+channel])-Int(b[pixel*4+channel]));if delta>0 {changed=true;channels += 1;maxDelta=max(maxDelta,delta)}}
                if changed {let x=pixel%width,y=pixel/width;pixels += 1;minX=min(minX,x);minY=min(minY,y);maxX=max(maxX,x);maxY=max(maxY,y);if first.count<32 {first.append(["x":x,"y":y,"left":Array(a[(pixel*4)..<(pixel*4+4)]),"right":Array(b[(pixel*4)..<(pixel*4+4)])])}}
            }
            return ["equal":a==b,"differentPixels":pixels,"differentChannels":channels,"maximumChannelDelta":maxDelta,"bounds":pixels==0 ? []:[minX,minY,maxX,maxY],"firstDifferentPixels":first,"leftSHA256":hash(a),"rightSHA256":hash(b)]
        }
        try save(leftBytes,"left-source."+leftSource.pathExtension);try save(rightBytes,"right-source."+rightSource.pathExtension)
        try save(leftOracle,"left-original-oracle.rgba");try save(rightOracle,"right-original-oracle.rgba")
        var report:[String:Any]=["schema":1,"runtime":try textRuntimeIdentity(),"case":name,"operatingSystem":ProcessInfo.processInfo.operatingSystemVersionString,"inspectionRegion":[0,0,width,height],"fullCanvas":fullCanvas,"sourceFiles":[leftSource.lastPathComponent,rightSource.lastPathComponent],"sourceSHA256":[hash(leftBytes),hash(rightBytes)],"originalOracle":difference(leftOracle,rightOracle),"originalOracleLayout":"Existing DeviceRGB premultipliedLast bitmapInfo; retained without reinterpretation."]
        report["leftNative"]=try metadata(left,"left");report["rightNative"]=try metadata(right,"right")
        let a=try textRGBA(left,fullCanvas:fullCanvas),b=try textRGBA(right,fullCanvas:fullCanvas)
        try save(a,"left-srgb-rgba8.bin");try save(b,"right-srgb-rgba8.bin")
        report["namedSRGBRGBA8"]=difference(a,b)
        report["captureKind"]=leftOracle==rightOracle && a==b ? "requested exact matched comparison evidence":"failed exact comparison evidence"
        report["normalizedLayout"]="Named sRGB, RGBA8 big-endian, premultiplied alpha, \(width*4) bytes per row; \(fullCanvas ? "entire native canvas, no crop":"exact top-left96x64 crop"); no interpolation, matte or tolerance."
        // This probe describes the fixture's common nominal font independently;
        // the retained generated SVG records the actual helper-produced paths.
        let font=CTFontCreateWithName("Helvetica" as CFString,18,nil)
        report["nominalFontProbe"]=["requested":"Helvetica 18 regular","postScript":CTFontCopyPostScriptName(font) as String,"family":CTFontCopyFamilyName(font) as String,"fullName":CTFontCopyFullName(font) as String,"ascent":CTFontGetAscent(font),"descent":CTFontGetDescent(font),"unitsPerEm":CTFontGetUnitsPerEm(font)]
        // Save evidence before optional reconversion, which may itself fail.
        try save(try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),"report.json")
        var conversions:[String:String]=[:]
        for (side,source) in [("left",leftBytes),("right",rightBytes)] {
            do {if let svg=try MetafileImageDecoder.convert(source) {try save(svg,side+"-reconverted.svg");conversions[side]="Retained fresh helper conversion; the failed CGImage remains separately retained."}else{conversions[side]="No converted SVG returned."}}
            catch {conversions[side]=error.localizedDescription}
        }
        report["diagnosticReconversion"]=conversions
        try save(try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),"report.json")
        print("Metafile text comparison evidence: "+directory.path)
    }
    /// Handwritten full-canvas expected paint, independent of SVG/raster output.
    /// Original WMF PS_NULL walls leave row9/row53 gaps; sealed controls contain
    /// actual PATCOPY records. No decoded image is cropped or composited here.
    private static func classicGDIFullCanvasExpected(_ name:String)->[UInt8]? {
        let clear:[UInt8]=[0,0,0,0],white:[UInt8]=[255,255,255,255],red:[UInt8]=[255,0,0,255],blue:[UInt8]=[0,0,255,255],green:[UInt8]=[0,255,0,255],yellow:[UInt8]=[255,255,0,255],black:[UInt8]=[0,0,0,255]
        var expected=[UInt8]();expected.reserveCapacity(64*64*4)
        let emptyOriginal=name.hasPrefix("unsupported-raster-wmf-without-bitmap-source-")
        let emptyControl=name.hasPrefix("classic-gdi-empty-prior-")
        let scanline=name=="classic-gdi-scanlines-full-white-patcopy-control.wmf"
        let flood=name.hasPrefix("wmf-classic-flood-") && ["surface","border","legacy-border","hatch"].contains(where:{name=="wmf-classic-flood-"+$0+".wmf" || name=="wmf-classic-flood-"+$0+"-sealed-white-patcopy-control.wmf"})
        guard emptyOriginal || emptyControl || scanline || flood else{return nil}
        let sealed=name.contains("-sealed-"),surface=name.contains("-surface") || name.contains("-hatch"),hatch=name.contains("-hatch")
        let walls=[[8,8,56,10],[8,54,56,56],[8,10,10,54],[54,10,56,54],[30,10,34,54]]
        for y in 0..<64 {for x in 0..<64 {
            let color:[UInt8]
            if emptyControl {color=white}
            else if emptyOriginal {color=name.contains("-bitblt.") && (8..<24).contains(x) && (8..<24).contains(y) ? white:clear}
            else if scanline {color=(8..<40).contains(x) && (8..<40).contains(y) ? (y<24 ? (x<24 ? red:green):(x<24 ? blue:yellow)):white}
            else if walls.contains(where:{r in x>=r[0] && y>=r[1] && x<r[2]-(sealed ? 0:1) && y<r[3]-(sealed ? 0:1)}) {color=black}
            else if surface && (20..<23).contains(x) && (20..<23).contains(y) {color=blue}
            else if sealed && !((10..<30).contains(x) && (10..<54).contains(y)) {color=white}
            else {color = !hatch || x%8==0 || y%8==0 ? red:white}
            expected.append(contentsOf:color)
        }}
        return expected
    }
    private static func raster(_ source:CGImage,interior:CGSize?=nil)throws->Data {
        let image:CGImage
        if let interior {
            guard let cropped=source.cropping(to:CGRect(origin:.zero,size:interior)),cropped.width==Int(interior.width),cropped.height==Int(interior.height) else{throw Failure(message:"Cannot inspect exact top-left reference region")}
            image=cropped
        } else {image=source}
        var bytes=Data(count:image.width*image.height*4)
        let rendered=bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context=CGContext(data:storage.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return false}
            context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));return true
        }
        try require(rendered,"Could not rasterize native compressed path pair");return bytes
    }
    private static func firstSample(_ files:[URL],withExtension ext:String)throws->URL {
        guard let file=files.first(where:{$0.pathExtension.lowercased()==ext}) else {throw Failure(message:"Missing "+ext+" corpus")};return file
    }
}
