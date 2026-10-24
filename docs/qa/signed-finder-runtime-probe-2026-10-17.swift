// SPDX-License-Identifier: GPL-2.0-or-later
// Standalone, directly executed QA process. Never registers an app or service.
import Foundation
import Security
import AppKit
import CryptoKit
import TurtleGitCore

@main struct SignedFinderRuntimeProbe {
    struct Failure: Error, CustomStringConvertible { let description:String }
    static func require(_ value:Bool,_ message:String)throws { if !value { throw Failure(description:message) } }
    struct PixelSample:Decodable {let point:[Int],min:[Double],max:[Double]}
    struct MetafileCase:Decodable {
        let name:String,bytes:String,sha256:String,width:Int,height:Int,samples:[PixelSample]
        let refuse:Bool?,svgContains:[String]?,hatchCell:[Int]?,deadline:Bool?
    }
    static func digest(_ bytes:Data)->String {SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
    @MainActor static func metafiles(_ encoded:String)throws->[[String:Any]] {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard let payload=Data(base64Encoded:encoded),payload.count<=192*1024 else {throw Failure(description:"Invalid bounded metafile payload")}
        let inputs=try JSONDecoder().decode([MetafileCase].self,from:payload)
        try require(inputs.count==9,"Incomplete signed metafile family")
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
                    samples.append(["point":sample.point,"rgba":actual])
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
                entry["width"]=width;entry["height"]=height;entry["samples"]=samples;entry["svg_bytes"]=svg.count;entry["consumer_loaded"]=true
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
        return ["git":git.path,"libgit2":helper.path,"head":head,"tree":tree.objectID!,"raw_tag_oid":rawTag,"literal_references_distinct":true,"browser_pinned":true,"gitlink_oid":old,"notes_engine":accepted.engine!.rawValue,"notes_ref":accepted.notesRef,"notes_utf8_bytes":expected.count,"notes_sha256":digest(expected),"notes_empty":true,"configured_signature":signatureOK,"head_unchanged":headOK,"index_unchanged":indexOK,"config_unchanged":configOK,"working_unchanged":fileOK && nestedOK]
    }
    static func main() async throws {
        let args=CommandLine.arguments
        guard args.count>=4, let uuid=UUID(uuidString:args[2]), let expected=FinderIntegration.groupIdentifier(team:args[3]) else { throw Failure(description:"Invalid signed QA request") }
        let mode=args[1]
        try require(GitRuntime.isAppStoreBuild,"Probe did not link the AppStore Core build")
        try require(try FinderCacheServiceIdentity.currentTeam()==args[3],"Signature team mismatch")
        let task=SecTaskCreateFromSelf(nil)!
        try require((SecTaskCopyValueForEntitlement(task,"com.apple.security.app-sandbox" as CFString,nil) as? Bool)==true,"Probe is not sandbox entitled")
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
        if mode=="cleanup" {
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
        } else if mode=="metafile" {
            guard args.count==5 else {throw Failure(description:"Missing captured metafile payload")}
            details["images"]=try await metafiles(args[4]);details["outside_file_grants"]=false;details["shipping_gui_launched"]=false
        } else { throw Failure(description:"Unknown signed QA mode") }
        var result:[String:Any] = ["mode":mode,"passed":true,"group":expected,"snapshot":snapshotURL.path]
        result.merge(details){_,new in new}
        print("TURTLEGIT_SIGNED_QA "+String(decoding:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),as:UTF8.self))
    }
}
