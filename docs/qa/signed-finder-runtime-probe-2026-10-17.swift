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
        } else if mode=="metafile" {
            guard args.count==5 else {throw Failure(description:"Missing captured metafile payload")}
            details["images"]=try await metafiles(args[4]);details["outside_file_grants"]=false;details["shipping_gui_launched"]=false
        } else { throw Failure(description:"Unknown signed QA mode") }
        var result:[String:Any] = ["mode":mode,"passed":true,"group":expected,"snapshot":snapshotURL.path]
        result.merge(details){_,new in new}
        print("TURTLEGIT_SIGNED_QA "+String(decoding:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),as:UTF8.self))
    }
}
