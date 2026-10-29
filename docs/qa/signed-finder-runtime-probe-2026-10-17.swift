// SPDX-License-Identifier: GPL-2.0-or-later
// Standalone, directly executed QA process. Never registers an app or service.
import Foundation
import Security
import AppKit
import CryptoKit
import CoreText
import Darwin
import TurtleGitCore

@main struct SignedFinderRuntimeProbe {
    struct Failure: Error, CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String)throws { if !value { throw Failure(description:message) } }
    struct PixelSample:Decodable {let point:[Int],min:[Double],max:[Double];let rgba:[Int]?,tolerance:Int?}
    struct MetafileCase:Decodable {
        let name:String,bytes:String,sha256:String,width:Int,height:Int,samples:[PixelSample]
        let refuse:Bool?,svgContains:[String]?,hatchCell:[Int]?,deadline:Bool?
        let minInk:Int?,clipMaxX:Int?,columnRuns:Int?,advance:Int?,nativeFallback:String?
        let windowsRGBAHash:String?
    }
    static func digest(_ bytes:Data)->String {SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
    @MainActor static func metafiles(_ encoded:String)throws->[[String:Any]] {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard let payload=Data(base64Encoded:encoded),payload.count<=192*1024 else {throw Failure(description:"Invalid bounded metafile payload")}
        let inputs=try JSONDecoder().decode([MetafileCase].self,from:payload)
        let required:Set<String>=["clip-vector.wmf","classic-vector.emf","plus-bitmap-text.emf","plus-gradient-blend.emf","plus-region-path.emf","plus-hatch-atlas.emf","plus-raw-indexed4-negative.emf","plus-raw-texture-rgb565-positive.emf","unsupported-raw-palette-index.emf","classic-text-compact-low-unicode.emf","classic-text-poly-ansi-dx.emf","wmf-text-dbcs-single-johab.wmf","wmf-text-ext-clip.wmf","wmf-bitmap16-bgrx32-stretch.wmf","wmf-bitmap16-self-bitblt-overlap.wmf","unsupported-wmf-text-dbcs-johab-lead.wmf","unsupported-wmf-bitmap16-bits-short.wmf","state-seed.emf"]
        try require(inputs.count==required.count && Set(inputs.map(\.name))==required,"Incomplete signed metafile family")
        let helper=try MetafileImageDecoder.executable(),resolved=helper.resolvingSymlinksInPath()
        try require(resolved.deletingLastPathComponent()==Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS"),"Metafile helper escaped the signed MacOS directory")
        let temporary=try TurtleGitTemporaryStorage.root
        func decoderDirectories()throws->Set<String> {Set(try FileManager.default.contentsOfDirectory(atPath:temporary.path).filter{$0.hasPrefix("TurtleGitMetafile-")})}
        let before=try decoderDirectories()
        var results:[[String:Any]]=[]
        for input in inputs {
            guard let captured=Data(base64Encoded:input.bytes) else {throw Failure(description:"Invalid captured bytes for "+input.name)}
            try require(digest(captured)==input.sha256,"Input digest mismatch for "+input.name)
            var entry:[String:Any]=["name":input.name,"source_sha256":input.sha256,"source_bytes":captured.count,"helper":resolved.path]
            if input.refuse == true {
                var refused=false
                do {_ = try MetafileImageDecoder.convert(captured);throw Failure(description:"Malformed metafile returned a successful image")}
                catch is MetafileImageFailure {refused=true}
                try require(refused && ComparisonImage(bytes:captured)==nil,"Malformed metafile was not refused by the actual image consumer")
                entry["refused"]=true
            }else {
                guard let svg=try MetafileImageDecoder.convert(captured),let text=String(data:svg,encoding:.utf8),let image=ComparisonImage(bytes:captured) else {throw Failure(description:"Sandboxed metafile conversion/load failed for "+input.name)}
                try require(image.pixels.width==input.width && image.pixels.height==input.height,"Intrinsic size changed for "+input.name)
                for needle in input.svgContains ?? [] {try require(text.contains(needle),"Metafile lost text/bitmap content: "+needle)}
                let width=image.pixels.width,height=image.pixels.height
                var pixels=[UInt8](repeating:0,count:width*height*4)
                try pixels.withUnsafeMutableBytes {storage in
                    guard let space=CGColorSpace(name:CGColorSpace.sRGB),let context=CGContext(data:storage.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else {throw Failure(description:"Cannot sample native metafile image")}
                    context.interpolationQuality = .none;context.draw(image.pixels,in:CGRect(x:0,y:0,width:width,height:height))
                }
                func pixel(_ x:Int,_ y:Int)throws->[Double] {
                    try require((0..<width).contains(x) && (0..<height).contains(y),"Metafile sample out of bounds")
                    let offset=(y*width+x)*4,alpha=Double(pixels[offset+3])/255
                    return (0..<3).map{alpha>0 ? Double(pixels[offset+$0])/(255*alpha):0}+[alpha]
                }
                var samples:[[String:Any]]=[]
                for sample in input.samples {
                    try require(sample.point.count==2 && sample.min.count==3 && sample.max.count==3,"Invalid sample contract")
                    let actual=try pixel(sample.point[0],sample.point[1])
                    for channel in 0..<3 {try require(actual[channel]>=sample.min[channel]-0.005 && actual[channel]<=sample.max[channel]+0.005,"Native colors changed for \(input.name) at \(sample.point): \(actual)")}
                    var observation:[String:Any]=["point":sample.point,"rgba":actual]
                    if let expected=sample.rgba {
                        let tolerance=sample.tolerance ?? 0
                        try require(expected.count==4 && expected.allSatisfy{(0...255).contains($0)} && (0...3).contains(tolerance),"Invalid native RGBA contract")
                        let offset=(sample.point[1]*width+sample.point[0])*4
                        let associated=(0..<3).map{(expected[$0]*expected[3]+127)/255}+[expected[3]]
                        let actualBytes=Array(pixels[offset..<(offset+4)]).map(Int.init)
                        try require((0..<4).allSatisfy{abs(actualBytes[$0]-associated[$0])<=tolerance},"Native source alpha changed for \(input.name) at \(sample.point): \(actualBytes), expected \(associated)")
                        observation["premultiplied_rgba"]=actualBytes;observation["original_windows_rgba"]=expected;observation["rgba_tolerance"]=tolerance
                    }
                    samples.append(observation)
                }
                if let cell=input.hatchCell {
                    try require(cell.count==4 && cell[2]>0 && cell[3]>0,"Invalid hatch-cell bounds")
                    var red=0,blue=0
                    for y in cell[1]..<(cell[1]+cell[3]) {for x in cell[0]..<(cell[0]+cell[2]) {
                        let color=try pixel(x,y)
                        if color[0]>0.8 && color[1]<0.2 && color[2]<0.2 {red += 1}
                        if color[2]>0.8 && color[0]<0.2 && color[1]<0.2 {blue += 1}
                    }}
                    try require(red>0 && blue>0 && red+blue==cell[2]*cell[3],"Hatch pattern lost actual foreground/background cells")
                    entry["hatch_red_pixels"]=red;entry["hatch_blue_pixels"]=blue
                }
                if let minimum=input.minInk {
                    let ink=Set((0..<width*height).filter{let p=$0*4;return pixels[p+3]>128 && pixels[p]<128 && pixels[p+1]<128 && pixels[p+2]<128})
                    try require(ink.count>minimum,"Outlined text lost actual ink for "+input.name)
                    entry["black_ink_pixels"]=ink.count
                    if let limit=input.clipMaxX {try require(ink.allSatisfy{$0%width<limit},"WMF text escaped its source clip")}
                    if let count=input.columnRuns {
                        let columns=Set(ink.map{$0%width}).sorted()
                        let starts=columns.enumerated().compactMap{index,x in index==0 || columns[index-1]+1 != x ? x:nil}
                        try require(starts.count==count,"Batched ANSI text lost independent supplied origins")
                        if let advance=input.advance {try require(zip(starts,starts.dropFirst()).allSatisfy{$1-$0==advance},"Batched ANSI advances changed")}
                        entry["ink_column_starts"]=starts
                    }
                    if let scalar=input.nativeFallback {
                        try require(width==96 && height==64,"Fallback outline viewport changed")
                        let base=CTFontCreateWithName("Helvetica" as CFString,18,nil),string=scalar as NSString
                        try require(string.length==1,"Unexpected fallback scalar contract")
                        let fallback=CTFontCreateForString(base,scalar as CFString,CFRange(location:0,length:string.length))
                        var character=UniChar(string.character(at:0)),glyph=CGGlyph(),missing=CGGlyph()
                        try require(CTFontGetGlyphsForCharacters(fallback,&character,&glyph,1) && glyph>0,"Native fallback scalar has no real cmap glyph")
                        _=CTFontGetGlyphsForCharacters(base,&character,&missing,1)
                        try require(missing==0,"Johab fixture no longer exercises selected-font fallback")
                        guard let path=CTFontCreatePathForGlyph(fallback,glyph,nil) else {throw Failure(description:"Native fallback glyph has no outline")}
                        var transform=CGAffineTransform(a:1,b:0,c:0,d:-1,tx:8,ty:28)
                        guard let placed=path.copy(using:&transform) else {throw Failure(description:"Cannot place native fallback outline")}
                        var expectedPixels=[UInt8](repeating:0,count:96*64*4)
                        try expectedPixels.withUnsafeMutableBytes {storage in
                            guard let space=CGColorSpace(name:CGColorSpace.sRGB),let context=CGContext(data:storage.baseAddress,width:96,height:64,bitsPerComponent:8,bytesPerRow:96*4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else {throw Failure(description:"Cannot paint independent native fallback outline")}
                            context.translateBy(x:0,y:64);context.scaleBy(x:1,y:-1);context.setFillColor(CGColor(gray:0,alpha:1));context.addPath(placed);context.fillPath()
                        }
                        let expected=Set((0..<96*64).filter{expectedPixels[$0*4+3]>128})
                        func bounds(_ points:Set<Int>)->[Int] {
                            let xs=points.map{$0%96},ys=points.map{$0/96}
                            return [xs.min() ?? -1,ys.min() ?? -1,(xs.max() ?? -1)-(xs.min() ?? 0)+1,(ys.max() ?? -1)-(ys.min() ?? 0)+1]
                        }
                        let actualBounds=bounds(ink),expectedBounds=bounds(expected)
                        try require(zip(actualBounds,expectedBounds).allSatisfy{abs($0-$1)<=1},"Johab native glyph bounds changed")
                        let matched=ink.filter{point in (-1...1).contains{dy in (-1...1).contains{dx in expected.contains(point+dy*96+dx)}}}.count
                        let coverage=Double(matched)/Double(ink.count)
                        try require(coverage>0.9,"Johab rendered .notdef instead of the actual fallback glyph")
                        entry["native_fallback_outline"]=true;entry["fallback_coverage"]=coverage;entry["fallback_font"]=CTFontCopyPostScriptName(fallback) as String;entry["fallback_glyph_id"]=Int(glyph);entry["fallback_bounds"]=actualBounds
                    }
                }
                entry["width"]=width;entry["height"]=height;entry["samples"]=samples;entry["svg_bytes"]=svg.count;entry["consumer_loaded"]=true
                if let oracle=input.windowsRGBAHash {
                    try require(input.name=="state-seed.emf" && oracle=="100bd7a6901f7ce4dd60febb660b70543fd852b70234d509ee9d5948b15d43d3","Unexpected Windows alpha oracle")
                    try require(input.samples.count==3 && Set(input.samples.compactMap{$0.rgba?.last})==Set([0,191,255]),"Missing transparent/partial/opaque alpha samples")
                    entry["windows_rgba_sha256"]=oracle;entry["source_alpha_retained"]=true
                }
            }
            if input.deadline == true {
                // A positive finite deadline passes preflight. The real Core
                // decoder starts its owned child before polling this deadline.
                do {_ = try MetafileImageDecoder.convert(captured,timeout:0.001);throw Failure(description:"Actual signed helper ignored its deadline")}
                catch MetafileImageFailure.timedOut {entry["deadline_terminated_after_spawn"]=true;entry["deadline_seconds"]=0.001}
            }
            try require(digest(captured)==input.sha256,"Rendering changed captured source bytes")
            try require(try decoderDirectories()==before,"Owned metafile request directory survived conversion/refusal")
            entry["source_bytes_unchanged"]=true;entry["private_decoder_directories_removed"]=true;results.append(entry)
        }
        return results
    }
    /// Keep one genuine read request pending until the external OS observer has
    /// identified its exact clone executable and owned process group. The input
    /// is then completed and its real Notes reply is validated; no timing delay
    /// or unrelated helper command substitutes for protocol execution.
    static func observedNotesRead(helper:URL,root:URL,folder:URL,revision:String)async throws->[String:Any] {
        let input=Pipe(),output=Pipe(),errors=Pipe()
        var actions:posix_spawn_file_actions_t?,attributes:posix_spawnattr_t?,pid:pid_t=0
        func check(_ code:Int32)throws {if code != 0 {throw NSError(domain:NSPOSIXErrorDomain,code:Int(code))}}
        try check(posix_spawn_file_actions_init(&actions));defer{posix_spawn_file_actions_destroy(&actions)}
        try check(posix_spawnattr_init(&attributes));defer{posix_spawnattr_destroy(&attributes)}
        try check(posix_spawn_file_actions_addchdir_np(&actions,root.path))
        try check(posix_spawn_file_actions_adddup2(&actions,input.fileHandleForReading.fileDescriptor,STDIN_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions,output.fileHandleForWriting.fileDescriptor,STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions,errors.fileHandleForWriting.fileDescriptor,STDERR_FILENO))
        try check(posix_spawnattr_setpgroup(&attributes,0))
        try check(posix_spawnattr_setflags(&attributes,Int16(POSIX_SPAWN_SETPGROUP|POSIX_SPAWN_CLOEXEC_DEFAULT)))
        func strings<T>(_ values:[String],_ body:(UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>)throws->T)rethrows->T {
            var pointers=values.map{strdup($0)}+[nil];defer{for value in pointers{free(value)}}
            return try pointers.withUnsafeMutableBufferPointer{try body($0.baseAddress!)}
        }
        try strings([helper.path,"turtlegit-notes-read"]){argv in
            try strings(ProcessInfo.processInfo.environment.map{$0.key+"="+$0.value}){environment in
                try check(posix_spawn(&pid,helper.path,&actions,&attributes,argv,environment))
            }
        }
        var reaped=false
        defer {
            try? input.fileHandleForWriting.close()
            if !reaped {if getpgid(pid)==pid{kill(-pid,SIGKILL)};var status:Int32=0;while waitpid(pid,&status,0)<0 && errno==EINTR{}}
        }
        try input.fileHandleForReading.close();try output.fileHandleForWriting.close();try errors.fileHandleForWriting.close()
        try require(getpgid(pid)==pid,"Observed Notes child did not own its process group")
        let acknowledgement=folder.appendingPathComponent("observed-libgit2-\(pid).json")
        var observed=false
        for _ in 0..<500 {
            if let data=try? Data(contentsOf:acknowledgement),let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Int],value["pid"]==Int(pid),value["pgid"]==Int(pid){observed=true;break}
            try await Task.sleep(nanoseconds:10_000_000)
        }
        try require(observed,"External OS observer did not acknowledge actual Notes helper")
        let request=try JSONSerialization.data(withJSONObject:["version":1,"revision":revision,"notesRef":"refs/notes/signed-qa"])
        try input.fileHandleForWriting.write(contentsOf:request);try input.fileHandleForWriting.close()
        let bytes=try output.fileHandleForReading.readToEnd() ?? Data(),diagnostic=try errors.fileHandleForReading.readToEnd() ?? Data()
        var status:Int32=0;while waitpid(pid,&status,0)<0 {if errno != EINTR{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}}
        reaped=true
        try require(status==0 && diagnostic.isEmpty,"Observed Notes request failed: "+String(decoding:diagnostic,as:UTF8.self))
        let prefix=Data("TurtleGit Notes v1:".utf8)
        guard bytes.starts(with:prefix),bytes.last==10,let payload=Data(base64Encoded:bytes.dropLast().dropFirst(prefix.count)),let reply=(try? JSONSerialization.jsonObject(with:payload)) as? [String:Any] else{throw Failure(description:"Observed Notes reply framing invalid")}
        try require(reply["notesRef"] as? String=="refs/notes/signed-qa" && reply["text"] as? String=="" && reply["blobOID"] as? String=="e69de29bb2d1d6434b8b29ae775ad8c2e48c5391","Observed Notes helper lost actual empty note metadata")
        return ["pid":Int(pid),"pgid":Int(pid),"os_observed":true,"valid_notes_read_reply":true,"reaped":true]
    }
    /// Actual public history consumers inside the inherited App Store sandbox.
    /// The only writable location is the existing per-run App Group UUID folder.
    static func history(_ folder:URL)async throws->[String:Any] {
        let root=folder.appendingPathComponent("history-repository",isDirectory:true)
        try require(!FileManager.default.fileExists(atPath:root.path),"Signed history fixture already exists")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let bundle=Bundle.main.bundleURL.resolvingSymlinksInPath(),git=try GitRuntime.executable(bundle:.main,appStore:true)
        let helper=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LibGit2/bin/turtlegit-libgit2").resolvingSymlinksInPath()
        try require(git.resolvingSymlinksInPath().path.hasPrefix(bundle.path+"/Contents/") && helper.deletingLastPathComponent()==bundle.appendingPathComponent("Contents/MacOS") && FileManager.default.isExecutableFile(atPath:helper.path),"History runtimes escaped the signed package")
        // No executor or helper URL injection: these APIs must discover the same
        // packaged runtime used by the shipping app and its inherited children.
        let selected=GitLibGit2Configuration(enabled:true,mask:0)
        let repository=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:selected)
        _=try await repository.run(["init","--template=","--object-format=sha1","--initial-branch=main"])
        for(key,value)in[("user.name","Signed Notes Author"),("user.email","signed-notes@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false"),("tag.gpgsign","false"),("core.precomposeunicode","true"),("core.notesRef","refs/notes/signed-qa")] {_=try await repository.run(["config",key,value])}
        let file=root.appendingPathComponent("file.txt"),nested=root.appendingPathComponent("nested/value.txt")
        try FileManager.default.createDirectory(at:nested.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data("first\n".utf8).write(to:file);try Data("literal nested bytes\n".utf8).write(to:nested)
        try await repository.stage(["file.txt","nested/value.txt"])
        _=try await repository.run(["commit","-m","Signed history base"])
        let old=try await repository.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        try Data("second\n".utf8).write(to:file)
        _=try await repository.run(["update-index","--add","--cacheinfo","160000,"+old+",module"])
        try await repository.stage(["file.txt"]);_=try await repository.run(["commit","-m","Signed history with gitlink"])
        let head=try await repository.run(["rev-parse","HEAD"]).text.trimmingCharacters(in:.newlines)
        _=try await repository.run(["tag","--annotate","--message","Signed historical tag","signed-release",head])
        let rawTag=try await repository.run(["rev-parse","refs/tags/signed-release"]).text.trimmingCharacters(in:.newlines)
        let nfc="refs/heads/caf\u{e9}",nfd="refs/heads/cafe\u{301}"
        // Packed refs preserve two distinct Git identities even where loose
        // filesystem names would share macOS canonical normalization.
        try Data(("# pack-refs with: peeled fully-peeled sorted\n"+old+" "+nfd+"\n"+head+" "+nfc+"\n").utf8).write(to:root.appendingPathComponent(".git/packed-refs"))
        let raw=try await repository.revisionLookup("refs/tags/signed-release",requirement:.existingObject)
        let commit=try await repository.revisionLookup("refs/tags/signed-release",requirement:.commit)
        let tree=try await repository.revisionLookup("refs/tags/signed-release",requirement:.tree)
        let composed=try await repository.revisionLookup(nfc,requirement:.commit),decomposed=try await repository.revisionLookup(nfd,requirement:.commit)
        let hasComposed=try await repository.referenceExists(nfc),hasDecomposed=try await repository.referenceExists(nfd)
        try require(raw.objectID==rawTag && rawTag != head && commit.objectID==head && tree.objectID != nil,"Signed typed tag/commit/tree resolution changed identity")
        try require(composed.objectID==head && decomposed.objectID==old && hasComposed && hasDecomposed,"Signed typed exact references collapsed canonical names")
        let snapshot=try await repository.browseRepository(revision:"refs/tags/signed-release")
        let directory=try await repository.browseRepositoryDirectory(snapshot,directory:"nested")
        guard let entry=directory.entries.first(where:{RepositoryBrowserPathIdentity.equal($0.path,"nested/value.txt")}) else{throw Failure(description:"Signed Browser lost nested entry")}
        let content=try await repository.repositoryBrowserFile(directory,entry:entry)
        try require(snapshot.objectID==head && snapshot.treeID==tree.objectID && content.bytes==Data("literal nested bytes\n".utf8),"Signed Browser lost pinned tree/content")
        let gitlink=try await repository.historicalGitlink(path:"module",revision:head,commitOnly:true)
        try require(gitlink == .gitlink(old),"Signed typed historical gitlink changed metadata")
        let beforeHead=try Data(contentsOf:root.appendingPathComponent(".git/HEAD")),beforeIndex=try Data(contentsOf:root.appendingPathComponent(".git/index")),beforeConfig=try Data(contentsOf:root.appendingPathComponent(".git/config"))
        let beforeFile=try Data(contentsOf:file),beforeNested=try Data(contentsOf:nested)
        let keys=["GIT_NOTES_REF","GIT_AUTHOR_NAME","GIT_AUTHOR_EMAIL","GIT_COMMITTER_NAME","GIT_COMMITTER_EMAIL"]
        let original=Dictionary(uniqueKeysWithValues:keys.map{key in (key,ProcessInfo.processInfo.environment[key])})
        defer{for key in keys{if let value=original[key] ?? nil{setenv(key,value,1)}else{unsetenv(key)}}}
        setenv("GIT_NOTES_REF","refs/notes/environment-ignored",1)
        setenv("GIT_AUTHOR_NAME","Environment Author",1);setenv("GIT_AUTHOR_EMAIL","environment-author@example.invalid",1)
        setenv("GIT_COMMITTER_NAME","Environment Committer",1);setenv("GIT_COMMITTER_EMAIL","environment-committer@example.invalid",1)
        // Notes are unconditional libgit2 consumers, independent of this mask.
        let notes=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(enabled:false,mask:0))
        let accepted=try await notes.editableCommitNote(revision:head)
        try require(accepted.engine == .libgit2 && GitReferenceName.equal(accepted.notesRef,"refs/notes/signed-qa"),"Signed Notes used the master toggle or environment notes ref")
        _=try await repository.run(["config","core.notesRef","refs/notes/later-configuration"])
        let text=String(repeating:"Signed sandbox note caf\u{e9} / cafe\u{301} — exact UTF-8 and LF.\n",count:24_000)
        let expected=Data(text.utf8);try require(expected.count>=1_000_000,"Signed Notes payload does not cover large real wire data")
        let saved=try await notes.saveCommitNote(accepted,text:text)
        try require(saved.utf8.elementsEqual(text.utf8),"Signed Notes readback changed exact text")
        _=try await repository.run(["config","core.notesRef","refs/notes/signed-qa"])
        let readback=try await notes.editableCommitNote(revision:head)
        try require(Data(readback.text.utf8)==expected && GitReferenceName.equal(readback.notesRef,accepted.notesRef),"Signed captured Notes ref/text changed")
        let empty=try await notes.saveCommitNote(readback,text:"")
        let reread=try await notes.editableCommitNote(revision:head)
        let emptyListing=try await repository.run(["notes","--ref=refs/notes/signed-qa","list",head]).text.trimmingCharacters(in:.newlines)
        let emptyBlob=try await repository.run(["cat-file","blob",emptyListing]).stdout
        try require(empty.isEmpty && reread.text.isEmpty && emptyListing=="e69de29bb2d1d6434b8b29ae775ad8c2e48c5391" && emptyBlob.isEmpty,"Signed empty note save did not retain an actual empty note blob")
        let signature=try await repository.run(["show","-s","--format=%an%x00%ae%x00%cn%x00%ce","refs/notes/signed-qa"]).stdout
        let signatureOK=signature==Data("Signed Notes Author\0signed-notes@example.invalid\0Signed Notes Author\0signed-notes@example.invalid\n".utf8)
        try require(signatureOK,"Signed Notes ignored configured default signature")
        let ignored=try await repository.referenceExists("refs/notes/environment-ignored"),later=try await repository.referenceExists("refs/notes/later-configuration")
        try require(!ignored && !later,"Signed Notes wrote an uncaptured/environment ref")
        let finalHead=try await repository.revisionLookup("HEAD",requirement:.commit)
        let headOK=try Data(contentsOf:root.appendingPathComponent(".git/HEAD"))==beforeHead && finalHead.objectID==head,indexOK=try Data(contentsOf:root.appendingPathComponent(".git/index"))==beforeIndex,configOK=try Data(contentsOf:root.appendingPathComponent(".git/config"))==beforeConfig
        let fileOK=try Data(contentsOf:file)==beforeFile,nestedOK=try Data(contentsOf:nested)==beforeNested
        try require(headOK && indexOK && configOK && fileOK && nestedOK,"Signed history/Notes touched unrelated repository state")
        let observation=try await observedNotesRead(helper:helper,root:root,folder:folder,revision:head)
        return ["observed_notes_read":observation,"git":git.path,"libgit2":helper.path,"head":head,"tree":tree.objectID!,"raw_tag_oid":rawTag,"literal_references_distinct":true,"browser_pinned":true,"gitlink_oid":old,"notes_engine":accepted.engine!.rawValue,"notes_ref":accepted.notesRef,"notes_utf8_bytes":expected.count,"notes_sha256":digest(expected),"notes_empty":true,"configured_signature":signatureOK,"head_unchanged":headOK,"index_unchanged":indexOK,"config_unchanged":configOK,"working_unchanged":fileOK && nestedOK]
    }
    /// Executes the candidate's packaged Core framework, not source-linked
    /// native editor types. Value Undo/Redo mirrors their exact snapshot contract;
    /// native gestures, TextKit geometry and NSUndoManager remain separately checked.
    static func unifiedDiff(_ folder:URL)throws->[String:Any] {
        let directory=folder.appendingPathComponent("unified-diff",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let rows=[Data("A日本語\r\n".utf8),Data([0x42,0xff,0x0a]),Data([0x43,0x98,0x00,0xff,0x0d]),Data("Dtail".utf8)]
        let original=rows.reduce(into:Data()){$0.append($1)}
        let input=directory.appendingPathComponent("input.patch"),output=directory.appendingPathComponent("saved.patch")
        try original.write(to:input,options:.atomic)
        let document=UnifiedDiffDocument(bytes:try Data(contentsOf:input),displayLegacyEncoding:.windows1251)
        var buffer=UnifiedDiffEditBuffer(document:document)
        let before=buffer,index=PatchLineIndex(text:buffer.text)
        try require(index.lineCount==4,"Mixed byte document line framing changed")
        let selections=index.lineStarts.enumerated().map{PatchLineEditSelection(id:10+$0.offset,anchor:$0.element,caret:$0.element+1)}
        guard let cut=PatchLineEditing.cutSelections(text:buffer.text,selections:selections,primarySelectionID:13,rectangular:true) else {throw Failure(description:"Packaged rectangle cut rejected valid rows")}
        try require(cut.clipboardRectangular && cut.clipboardText=="A\nB\nC\nD\n","Rectangle clipboard row contract changed")
        try require(try buffer.apply(cut),"Rectangle cut did not change captured bytes")
        let cutExpected=rows.reduce(into:Data()){$0.append($1.dropFirst())}
        try require(try buffer.snapshot().bytes==cutExpected,"Rectangle cut re-encoded untouched raw bytes/endings")
        let afterCut=buffer
        buffer=before
        try require(try buffer.snapshot().bytes==original,"Value Undo lost original bytes")
        buffer=afterCut
        try require(try buffer.snapshot().bytes==cutExpected,"Value Redo lost cut bytes")
        let tail=(buffer.text as NSString).range(of:"tail")
        guard tail.location != NSNotFound,let duplicate=PatchLineEditing.plan(text:buffer.text,anchor:tail.location,caret:NSMaxRange(tail),command:.duplicate) else {throw Failure(description:"Packaged duplicate rejected tail selection")}
        try require(try buffer.apply(duplicate),"Whole-line family duplicate did not edit")
        let edited=Data(cutExpected.dropLast(4))+Data("tailtail".utf8)
        let afterDuplicate=buffer,saved=try buffer.snapshot()
        try require(saved.bytes==edited,"Duplicate changed retained mixed byte spans")
        buffer=afterCut
        try require(try buffer.snapshot().bytes==cutExpected,"Duplicate value Undo failed")
        buffer=afterDuplicate
        try require(try buffer.snapshot().bytes==edited,"Duplicate value Redo failed")
        try saved.write(to:output)
        try require(try Data(contentsOf:output)==edited && Data(contentsOf:input)==original,"Sandbox Save/reload changed input or output bytes")
        let equalSource=Data("я\n".utf8)+Data([0xff,0x0a])
        var equal=UnifiedDiffEditBuffer(document:UnifiedDiffDocument(bytes:equalSource,displayLegacyEncoding:.windows1251))
        let equalBefore=equal,shown=equal.text,second=PatchLineIndex(text:shown).lineStarts[1]
        guard let transpose=PatchLineEditing.plan(text:shown,anchor:second,caret:second,command:.transpose) else {throw Failure(description:"Byte-only transpose rejected")}
        try require(try equal.apply(transpose),"Byte-only transpose was discarded")
        let swapped=Data([0xff,0x0a])+Data("я\n".utf8),equalAfter=equal
        let swappedSnapshot=try equal.snapshot(),swappedDirty=try equal.isModified()
        try require(equal.text==shown && swappedSnapshot.bytes==swapped && swappedDirty,"Equal display transpose lost byte dirty state")
        equal=equalBefore
        let undoSnapshot=try equal.snapshot(),undoDirty=try equal.isModified()
        try require(undoSnapshot.bytes==equalSource && !undoDirty,"Byte-only Undo failed")
        equal=equalAfter
        try require(try equal.snapshot().bytes==swapped,"Byte-only Redo failed")
        let byteOnly=directory.appendingPathComponent("byte-only.patch")
        try equal.snapshot().write(to:byteOnly)
        try require(try Data(contentsOf:byteOnly)==swapped,"Byte-only Save failed")
        return ["framework":"packaged TurtleGitCore.framework",
                "input_sha256":digest(original),"saved_sha256":digest(edited),"byte_only_sha256":digest(swapped),
                "rectangle_cut_raw_bytes":true,"whole_line_duplicate":true,"value_undo_redo":true,"byte_only_transpose_dirty":true,"sandbox_save_reload":true,
                "native_ui_executed":false,"undo_scope":"Core value snapshots; not NSUndoManager"]
    }

    /// Explicit public packaged-Core smoke. No native editor or persistent state.
    static func udiffCoreSmoke()throws->[String:Any] {
        let logical="alpha  beta+gamma_delta\r\n雪🙂"
        let targets:[(Int,PatchBoundary,Int)]=[(0,.nextWord,7),(7,.nextWord,11),(11,.nextWord,12),(12,.nextWord,23),(23,.nextWord,25),(12,.previousWord,11),(0,.documentEnd,(logical as NSString).length)]
        for (caret,boundary,expected) in targets {try require(PatchBoundaryNavigation.position(text:logical,caret:caret,boundary:boundary)==expected,"Packaged logical navigation changed")}
        try require(PatchBoundaryNavigation.position(text:" \talpha\r\n",caret:5,boundary:.smartLineStart)==2 && PatchBoundaryNavigation.position(text:" \talpha\r\n",caret:2,boundary:.smartLineStart)==0,"Packaged smart Home lost toggle")
        try require(PatchBoundaryNavigation.position(text:" \talpha\r\n",caret:5,boundary:.lineEnd)==7 && PatchBoundaryNavigation.position(text:"",caret:0,boundary:.documentEnd)==0,"Packaged empty/line-end navigation changed")
        let blocks="one\r\n \t\r\ntwo\rthree\n\nlast",last=("one\r\n \t\r\ntwo\rthree\n\n" as NSString).length
        try require(PatchParagraphNavigation.position(text:blocks,caret:0,backwards:false)==9 && PatchParagraphNavigation.position(text:blocks,caret:last,backwards:true)==9,"Packaged mixed-EOL block navigation changed")
        func convert(_ bytes:Data,_ selected:Int)throws->(UnifiedDiffEditBuffer,PatchLineEditPlan) {
            var buffer=UnifiedDiffEditBuffer(document:UnifiedDiffDocument(bytes:bytes,displayLegacyEncoding:.windows1251))
            guard let plan=PatchSelectionEditing.plan(text:buffer.text,selections:[.init(id:0,anchor:0,caret:selected)],primarySelectionID:0,rectangular:false,command:.upperCase) else {throw Failure(description:"Packaged case plan refused")}
            _ = try buffer.apply(plan);return (buffer,plan)
        }
        let suffix=Data("\r\nKEEP".utf8)+Data([0x98,0,0xff,13]),original=Data("Straße e\u{301}".utf8)+suffix,expected=Data("STRASSE E\u{301}".utf8)+suffix
        let expanded=try convert(original,("Straße e\u{301}" as NSString).length)
        try require(try expanded.0.snapshot().bytes==expected,"Packaged expansion normalized text or changed opaque packets")
        let legacy=Data([0xe0,0xe1,13,10,0x98,0xff]),regional=try convert(Data([0xe0,0xe1,13,10,0x98,0xff]),2)
        try require(try regional.0.snapshot().bytes==Data([0xc0,0xc1,13,10,0x98,0xff]),"Packaged selected legacy edit changed untouched packets")
        let noOp=try convert(Data("ABC\r\n".utf8),0),noOpBytes=try noOp.0.snapshot().bytes
        try require(!noOp.1.hasReplacement && noOpBytes==Data("ABC\r\n".utf8),"Packaged empty selection mutated")
        var rectangle=UnifiedDiffEditBuffer(document:UnifiedDiffDocument(bytes:Data("ß\nX\n".utf8),displayLegacyEncoding:.windows1251))
        guard let plan=PatchSelectionEditing.plan(text:rectangle.text,selections:[.init(id:1,anchor:0,caret:1),.init(id:2,anchor:2,caret:3)],primarySelectionID:2,rectangular:true,command:.upperCase,rectangleAnchor:0,rectangleCaret:3) else {throw Failure(description:"Packaged rectangle plan refused")}
        _ = try rectangle.apply(plan)
        try require(try rectangle.snapshot().bytes==Data("SS\nX\n".utf8),"Packaged rectangle expansion bytes changed")
        try require(plan.rectangular && plan.rectangleRowsExplicit && plan.selections.map(\.range)==[NSRange(location:0,length:2),NSRange(location:3,length:1)],"Packaged explicit rectangle ranges reflowed")
        var deleting=UnifiedDiffEditBuffer(document:UnifiedDiffDocument(bytes:Data("alpha beta\r\nnext\rfinal\n".utf8),displayLegacyEncoding:.windows1251))
        guard let deletion=PatchSelectionEditing.plan(text:deleting.text,selections:[.init(id:0,anchor:0,caret:5)],primarySelectionID:0,rectangular:false,command:.deleteLineRight) else {throw Failure(description:"Packaged line deletion refused")}
        _ = try deleting.apply(deletion)
        try require(try deleting.snapshot().bytes==Data("alpha\r\nnext\rfinal\n".utf8),"Packaged deletion consumed selected range/EOL")
        let nfd="\u{301}e\u{301}\r\n🙂",upperNFD="\u{301}E\u{301}\r\n🙂"
        var codecs:[String:String]=[:]
        for codec in [ComparisonTextEncoding.utf8BOM,.utf16LEBOM,.utf16BEBOM] {
            let encoded=try codec.encode(nfd)
            guard let decoded=codec.decodeInput(encoded) else {throw Failure(description:"Packaged BOM decoder refused NFD")}
            try require(decoded.utf16.elementsEqual(nfd.utf16),"Packaged public codec normalized leading NFD")
            let document=UnifiedDiffDocument(bytes:encoded,displayLegacyEncoding:.windows1251)
            try require(document.displayText.utf16.elementsEqual(nfd.utf16),"Packaged UDiff BOM autoload normalized NFD")
            let result=try convert(encoded,3)
            try require(try result.0.snapshot().bytes==codec.encode(upperNFD),"Packaged BOM/NFD edited buffer changed encoding")
            codecs[codec.rawValue]=digest(encoded)
        }
        return ["public_core_package_smoke":true,"navigation_boundaries":true,"selection_case_and_rectangle":true,"opaque_legacy_bom_bytes":true,"source_codec_nfd":true,"native_ui_executed":false,"helpers_executed":false,"input_sha256":digest(original),"edited_sha256":digest(expected),"legacy_sha256":digest(legacy),"codec_sha256":codecs]
    }
    /// Public Core package smoke. No AppKit windows, Finder state or App Group access.
    static func localTools(_ directory:URL,payload:String)async throws->[String:Any] {
        struct Input:Decodable{let name:String,bytes:String,sha256:String}
        guard let packet=Data(base64Encoded:payload),packet.count<=64*1024 else{throw Failure(description:"Invalid bounded local-tools payload")}
        let inputs=try JSONDecoder().decode([Input].self,from:packet)
        try require(Set(inputs.map(\.name))==["animated.gif","vector.wmf"] && inputs.count==2,"Missing original image containers")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer{try? FileManager.default.removeItem(at:directory)}
        var originals:[String:Data]=[:]
        for input in inputs {
            guard let bytes=Data(base64Encoded:input.bytes),digest(bytes)==input.sha256 else{throw Failure(description:"Changed image payload")}
            originals[input.name]=bytes;try bytes.write(to:directory.appendingPathComponent(input.name),options:.withoutOverwriting)
        }
        let opaque=Data([0,255,0,1,2,3,128]),opaqueURL=directory.appendingPathComponent("opaque.bin")
        try opaque.write(to:opaqueURL);originals["opaque.bin"]=opaque
        let output=directory.appendingPathComponent("result/selected.image")
        let argv=["--image-tool","--mine",directory.appendingPathComponent("animated.gif").path,"--base",directory.appendingPathComponent("vector.wmf").path,"--theirs",opaqueURL.path,"--result",output.path]
        guard let invocation=try ImageToolInvocation.parse(arguments:argv,currentDirectory:directory.path) else{throw Failure(description:"Packaged image invocation refused")}
        try require(invocation.isSelection && invocation.result==output,"Packaged image selection mode changed")
        var document=try ImageSelectionDocument.capture(invocation:invocation)
        let sides:[ImageConflictSide]=[.mine,.base,.theirs],sources=["animated.gif","vector.wmf","opaque.bin"],statuses:[Int32]=[1,3,2]
        for (index,side) in sides.enumerated() {
            let expected=originals[sources[index]]!
            try require(document.selectionBytes(side)==expected && ImageToolInvocation.selectionExitCode(side)==statuses[index],"Original image/side status changed")
            document=try document.select(side)
            try require(document.selectedSide==side && (try Data(contentsOf:output))==expected,"Image choice re-encoded original container")
        }
        for(name,bytes)in originals{try require(try Data(contentsOf:directory.appendingPathComponent(name))==bytes,"Image selection rewrote input")}
        let git=try GitRuntime.executable(bundle:.main,appStore:true)
        try require(git.path.hasPrefix(Bundle.main.bundleURL.path+"/Contents/"),"Local-tools Git escaped packaged clone")
        let root=directory.appendingPathComponent("repository");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        // Keep one real packaged Git helper blocked on its owned stdin long
        // enough for the independent OS observer; fast repository calls alone
        // can all complete between ps snapshots.
        let observedGit=Process(),observedInput=Pipe(),observedOutput=Pipe(),observedErrors=Pipe()
        let observedExecutable=git.resolvingSymlinksInPath()
        observedGit.executableURL=git;observedGit.arguments=["hash-object","--stdin"];observedGit.currentDirectoryURL=root
        observedGit.standardInput=observedInput;observedGit.standardOutput=observedOutput;observedGit.standardError=observedErrors
        try observedGit.run()
        let observedPID=observedGit.processIdentifier
        defer {
            try? observedInput.fileHandleForWriting.close()
            if observedGit.isRunning{observedGit.terminate()}
            observedGit.waitUntilExit()
        }
        try await Task.sleep(nanoseconds:750_000_000)
        try require(observedGit.isRunning,"Packaged Git did not remain waiting for owned stdin")
        try observedInput.fileHandleForWriting.write(contentsOf:Data("signed packaged Git observation\n".utf8))
        try observedInput.fileHandleForWriting.close()
        for _ in 0..<300 {if !observedGit.isRunning{break};try await Task.sleep(nanoseconds:10_000_000)}
        try require(!observedGit.isRunning,"Packaged Git stdin request did not drain")
        observedGit.waitUntilExit()
        let observedHash=String(decoding:try observedOutput.fileHandleForReading.readToEnd() ?? Data(),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        let observedError=try observedErrors.fileHandleForReading.readToEnd() ?? Data()
        try require(observedGit.terminationStatus==0 && observedHash=="f440016325e65f00c7c09a9989ce0f099f443cdd" && observedError.isEmpty,"Packaged Git stdin hash request failed")
        let repository=GitRepository(root:root,executable:git,askpass:nil,libgit2Configuration:.init(mask:0))
        func oid(_ arguments:[String],input:Data?=nil)async throws->String{try await repository.run(arguments,input:input).text.trimmingCharacters(in:.whitespacesAndNewlines)}
        func tree(_ entries:[(String,String,String,Data)])async throws->String {
            var data=Data();for(mode,type,object,path)in entries{data.append(Data("\(mode) \(type) \(object)\t".utf8));data.append(path);data.append(0)}
            return try await oid(["mktree","-z"],input:data)
        }
        _=try await repository.run(["init","--template=","-b","main"])
        for(key,value)in[("user.name","Signed local-tools QA"),("user.email","signed-local@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")]{_=try await repository.run(["config",key,value])}
        let sentinel=Data("unchanged working sentinel\n".utf8),sentinelURL=root.appendingPathComponent("sentinel.txt")
        try sentinel.write(to:sentinelURL);try await repository.stage(["sentinel.txt"]);_=try await repository.commit(message:"private seed")
        let first=try await oid(["rev-parse","HEAD"]),seed=try await oid(["rev-parse","HEAD:sentinel.txt"])
        let rawFolder=Data([251])+Data(" folder".utf8),rawA=Data([255])+Data(".PNG".utf8),rawB=Data([254])+Data(".PNG".utf8)
        let rawPaths=[rawFolder+Data([47])+rawA,rawFolder+Data([47])+rawB],names=["Git-path-7b650404d2883313a196637e97d928cf61e595391c18bbbc4a65bd76e11362d1.PNG","Git-path-0b22cf05f26aa13949b4b801da54e6973d06e181ef69cdcd7f84f91f7bf46320.PNG"]
        let blob=Data([0,80,78,71,255,16]),blobID=try await oid(["hash-object","-w","--stdin"],input:blob)
        let attrs=try await oid(["hash-object","-w","--stdin"],input:Data("hidden export-ignore\nshown export-subst\n".utf8))
        let shown=try await oid(["hash-object","-w","--stdin"],input:Data("$Format:%H$\n".utf8))
        let child=try await tree([("100755","blob",blobID,rawA),("100644","blob",blobID,rawB),("100644","blob",attrs,Data(".gitattributes".utf8)),("100644","blob",shown,Data("shown".utf8)),("100644","blob",blobID,Data("hidden".utf8))])
        let treeID=try await tree([("100644","blob",seed,Data("sentinel.txt".utf8)),("040000","tree",child,rawFolder)])
        let revision=try await oid(["commit-tree",treeID,"-p",first],input:Data("captured raw namespace\n".utf8))
        _=try await repository.run(["update-ref","refs/heads/main",revision]);_=try await repository.run(["update-ref","refs/heads/captured",revision])
        let head=try await repository.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index")),config=try Data(contentsOf:root.appendingPathComponent(".git/config"))
        let snapshot=try await repository.browseRepository(revision:"captured",backend:.init(mask:0)),scope=try RepositoryBrowserGitPath(rawData:rawFolder).key
        _=try await repository.run(["update-ref","refs/heads/captured",first])
        let archive=directory.appendingPathComponent("raw-folder.zip")
        _=try await repository.archiveRepositoryBrowser(snapshot,directory:scope,to:archive,cancellation:OperationCancellation())
        let oracle=try await repository.run(["archive","--format=zip","--end-of-options",revision,scope],argumentBytes:[4:rawFolder]).stdout
        let archived=try Data(contentsOf:archive);try require(archived==oracle && !archived.isEmpty,"Packaged raw folder archive changed pinned bytes/attributes")
        let paths=try rawPaths.map{try RepositoryBrowserGitPath(rawData:$0).key}
        let files=paths.map{CommitFile(path:$0,oldPath:nil,action:"A",added:nil,removed:nil,hasStatistics:false,isSubmodule:false)}
        let plan=try FileListDragPlan(root:root,revision:.revision(revision),files:files,backend:.init(mask:0))
        try require(plan.items.map(\.path)==paths && plan.items.map(\.name)==names && names[0] != names[1],"Packaged raw file names merged same-blob paths")
        for index in plan.items.indices {
            guard case .historical(let export)=try await repository.materializeFileListDrag(plan,itemAt:index) else{throw Failure(description:"Historical raw file returned working URL")}
            do {
                defer{export.discard()}
                let bytes=try Data(contentsOf:export.item),attributes=try FileManager.default.attributesOfItem(atPath:export.item.path)
                try require(bytes==blob && export.item.lastPathComponent==names[index] && (attributes[.posixPermissions] as? NSNumber)?.intValue==(index==0 ? 0o755:0o644),"Packaged historical materialization changed name/bytes/mode")
            }
            try require(!FileManager.default.fileExists(atPath:export.item.path),"Historical export survived explicit release")
        }
        // Current consolidation: exercise the exported production Core APIs,
        // with no shipping AppKit owner or App Group entitlement.
        try require(MergeMarkedWord.screenRowCount("alpha",fragments:["alpha alpha","al","pha","alpha"])==2,"Packaged marked status counted occurrences or joined wrap fragments")
        let preferenceSuite="TurtleGit.SignedSettings."+UUID().uuidString
        guard let preferences=UserDefaults(suiteName:preferenceSuite) else{throw Failure(description:"Private packaged Settings preferences unavailable")}
        defer{preferences.removePersistentDomain(forName:preferenceSuite)}
        let intents=SettingsPublicationIntents(defaults:preferences)
        let old=intents.request(.finderMenu),new=intents.request(.finderMenu)
        try require(!intents.complete(.finderMenu,request:old) && intents.pending(.finderMenu)==new,"Packaged Settings lost superseding publication request")
        try require(intents.complete(.finderMenu,request:new) && intents.pending(.finderMenu)==nil,"Packaged Settings could not complete current request")
        var create=ReferenceCreationOptions();create.name="runtime-accepted-branch";create.revision=first
        let branchPlan=try await repository.prepareReferenceCreation(create)
        let branch=try await repository.createReferenceAccepted(branchPlan)
        try require(branch.verified && branch.reference=="refs/heads/runtime-accepted-branch" && branch.actualObjectID==first,"Packaged branch creation receipt lost actual identity")
        create.isTag=true;create.name="runtime-accepted-tag"
        let tagPlan=try await repository.prepareReferenceCreation(create)
        let tag=try await repository.createReferenceAccepted(tagPlan)
        try require(tag.verified && tag.reference=="refs/tags/runtime-accepted-tag" && tag.peeledObjectID==first,"Packaged tag creation receipt lost target")
        var worktreeOptions=WorktreeCreationOptions();worktreeOptions.newBranch="runtime-linked";worktreeOptions.revision=first;worktreeOptions.checkout=false
        let linked=try await repository.createWorktreeAccepted(at:directory.appendingPathComponent("runtime-linked"),options:worktreeOptions)
        try require(linked.verified && linked.worktree?.head==first,"Packaged worktree creation receipt lost registered checkout")
        let afterHead=try await repository.run(["rev-parse","HEAD"]).stdout,afterIndex=try Data(contentsOf:root.appendingPathComponent(".git/index")),afterConfig=try Data(contentsOf:root.appendingPathComponent(".git/config")),afterWorking=try Data(contentsOf:sentinelURL)
        try require(afterHead==head && afterIndex==index && afterConfig==config && afterWorking==sentinel,"Local-tools smoke changed HEAD/index/config/worktree")
        try require(try FileManager.default.contentsOfDirectory(atPath:root.path).sorted()==[".git","sentinel.txt"],"Historical raw files leaked into checkout")
        return ["public_core_package_smoke":true,"marked_screen_row_status":true,"settings_publication_intents":true,"creation_acceptance_receipts":true,"image_original_bytes_selection":true,"raw_folder_archive":true,"raw_individual_materialization":true,"captured_revision_backend":true,"head_index_working_unchanged":true,"native_ui_executed":false,"git":git.path,"observed_git":["pid":Int(observedPID),"executable":observedExecutable.path,"hash":observedHash,"reaped":true],"image_sha256":originals.mapValues(digest),"archive_sha256":digest(archived),"raw_blob_sha256":digest(blob)]
    }

    static func main() async throws {
        let args=CommandLine.arguments
        guard args.count>=4, let uuid=UUID(uuidString:args[2]), let expected=FinderIntegration.groupIdentifier(team:args[3]) else { throw Failure(description:"Invalid signed QA request") }
        let mode=args[1]
        try require(GitRuntime.isAppStoreBuild,"Probe did not link the AppStore Core build")
        try require(try FinderCacheServiceIdentity.currentTeam()==args[3],"Signature team mismatch")
        let task=SecTaskCreateFromSelf(nil)!
        try require((SecTaskCopyValueForEntitlement(task,"com.apple.security.app-sandbox" as CFString,nil) as? Bool)==true,"Probe is not sandbox entitled")
        if mode=="local-tools" {
            guard args.count==5 else{throw Failure(description:"Missing local-tools payload")}
            let directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/TurtleGitSignedLocalTools-"+uuid.uuidString,isDirectory:true)
            try require(!FileManager.default.fileExists(atPath:directory.path),"Local-tools UUID directory already exists")
            let value=try await localTools(directory,payload:args[4])
            try require(!FileManager.default.fileExists(atPath:directory.path),"Private local-tools directory survived cleanup")
            let receipt:[String:Any]=["mode":mode,"passed":true,"local_tools":value,"outside_file_grants":false,"shipping_gui_launched":false,"app_group_files_created":false,"private_container_cleaned":true]
            print("TURTLEGIT_SIGNED_QA "+String(decoding:try JSONSerialization.data(withJSONObject:receipt,options:.sortedKeys),as:UTF8.self));return
        }
        if mode=="denied" {
            try require(FinderIntegration.container==nil,"A process without the group entitlement acquired the container")
            guard args.count==5 else { throw Failure(description:"Missing negative read target") }
            do { _=try Data(contentsOf:URL(fileURLWithPath:args[4]));throw Failure(description:"Sandbox allowed a group file read without group membership") }
            catch let failure as Failure { throw failure }
            catch { print("TURTLEGIT_SIGNED_QA {\"mode\":\"denied\",\"passed\":true}");return }
        }
        try require(FinderIntegration.group==expected,"Runtime group differs from signature team")
        guard let container=FinderIntegration.container else { throw Failure(description:"Signed group container access failed") }
        let folder=container.appendingPathComponent("TurtleGitSignedQA-"+uuid.uuidString,isDirectory:true)
        let snapshotURL=folder.appendingPathComponent("snapshot.json"),root=folder.appendingPathComponent("repository",isDirectory:true)
        let file=root.appendingPathComponent("file.txt")
        var details:[String:Any]=[:]
        if mode=="location" {
            try require(args.count==4,"Unexpected location arguments")
        } else if mode=="cleanup" {
            if FileManager.default.fileExists(atPath:folder.path) { try FileManager.default.removeItem(at:folder) }
        } else if mode=="writer" {
            try require(!FileManager.default.fileExists(atPath:folder.path),"QA directory already exists")
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let git=try GitRuntime.executable(bundle:.main,appStore:true)
            try require(git.path.hasPrefix(Bundle.main.bundleURL.path+"/Contents/"),"Git escaped the signed bundle")
            let lexilla=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Lexilla/lexilla")
            let process=Process(),output=Pipe(),errors=Pipe()
            process.executableURL=lexilla;process.arguments=["--version"];process.standardOutput=output;process.standardError=errors
            try process.run()
            let version=try output.fileHandleForReading.readToEnd() ?? Data()
            _=try errors.fileHandleForReading.readToEnd();process.waitUntilExit()
            try require(process.terminationStatus==0 && String(decoding:version,as:UTF8.self).contains("ef08a1a00ce151ccdddf7da700fbe1a4934a9c71"),"Signed inherited Lexilla failed in its sandboxed parent")
            let repository=GitRepository(root:root,executable:git)
            _=try await repository.run(["init","--initial-branch=main"])
            _=try await repository.run(["config","user.name","Signed Sandbox QA"])
            _=try await repository.run(["config","user.email","signed-qa@example.invalid"])
            try Data("base\n".utf8).write(to:file)
            try await repository.stage(["file.txt"])
            _=try await repository.run(["-c","core.hooksPath=/dev/null","-c","commit.gpgsign=false","commit","-m","Signed sandbox fixture"])
            try Data("modified\n".utf8).write(to:file)
            let snapshot=FinderSnapshot.build(root:root,tracked:try await repository.trackedPaths(),changes:try await repository.status())
            let store=FinderSnapshotStore(url:snapshotURL),ticket=try store.begin(root:root)
            try require(try store.publish(ticket,snapshots:[snapshot]).published,"Signed publication was superseded")
        } else if mode=="reader" {
            let value=try JSONDecoder().decode(FinderSnapshot.self,from:Data(contentsOf:snapshotURL))
            try require(value.roots.contains(root.path) && value.states[file.path] == .modified,"Independent signed reader lost published status")
            try require(try Data(contentsOf:file)==Data("modified\n".utf8),"Independent signed reader lost group-file access")
        } else if mode=="history" {
            guard args.count==4 else{throw Failure(description:"Unexpected signed history arguments")}
            details["history"]=try await history(folder);details["outside_file_grants"]=false;details["shipping_gui_launched"]=false
        } else if mode=="unified-diff" {
            guard args.count==4 else {throw Failure(description:"Unexpected Unified Diff arguments")}
            details["unified_diff"]=try unifiedDiff(folder);details["outside_file_grants"]=false;details["shipping_gui_launched"]=false
        } else if mode=="udiff" {
            guard args.count==4 else {throw Failure(description:"Unexpected public UDiff smoke arguments")}
            let existed=FileManager.default.fileExists(atPath:folder.path)
            details["udiff"]=try udiffCoreSmoke();details["outside_file_grants"]=false;details["shipping_gui_launched"]=false;details["app_group_files_created"]=false
            try require(FileManager.default.fileExists(atPath:folder.path)==existed,"Pure public UDiff smoke created App Group state")
        } else if mode=="metafile" {
            guard args.count==5 else {throw Failure(description:"Missing captured metafile payload")}
            details["images"]=try await metafiles(args[4]);details["outside_file_grants"]=false;details["shipping_gui_launched"]=false
        } else { throw Failure(description:"Unknown signed QA mode") }
        var result:[String:Any] = ["mode":mode,"passed":true,"group":expected,"snapshot":snapshotURL.path]
        result.merge(details){_,new in new}
        print("TURTLEGIT_SIGNED_QA "+String(decoding:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),as:UTF8.self))
    }
}
