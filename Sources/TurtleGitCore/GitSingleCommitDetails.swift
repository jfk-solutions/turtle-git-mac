// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CoreFoundation

public enum GitSingleCommitFailure:LocalizedError {
    case output,notCommit,encoding
    public var errorDescription:String? {
        switch self {
        case .output:return "Git returned invalid or incomplete single-commit metadata."
        case .notCommit:return "The selected revision is not a commit."
        case .encoding:return "The commit's declared character encoding cannot be decoded on macOS."
        }
    }
}
public struct GitCommitSignature:Sendable {
    public let nameBytes:Data,emailBytes:Data
    public let name:String,email:String
    public let time:Int64
    public let offsetMinutes:Int32
    public var date:String {
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.calendar=Calendar(identifier:.gregorian)
        formatter.timeZone=TimeZone(secondsFromGMT:0);formatter.dateFormat="yyyy-MM-dd'T'HH:mm:ss"
        let minutes=abs(Int(offsetMinutes)),suffix=String(format:"%@%02d:%02d",offsetMinutes<0 ? "-":"+",minutes/60,minutes%60)
        return formatter.string(from:Date(timeIntervalSince1970:TimeInterval(time)+TimeInterval(offsetMinutes)*60))+suffix
    }
}
public struct GitSingleCommit:Sendable {
    public let objectID:String,tree:String,parents:[String]
    public let encodingBytes:Data?
    public let author:GitCommitSignature,committer:GitCommitSignature
    public let messageBytes:Data,message:String
    public var subject:String {LogEntry.splitHistoryMessage(message).subject}
    public var body:String {LogEntry.splitHistoryMessage(message).body}
    public func asLogEntry()->LogEntry {
        var entry=LogEntry(hash:objectID,author:author.name,date:author.date,subject:subject)
        entry.parents=parents;entry.email=author.email;entry.message=message;entry.committer=committer.name;entry.committerEmail=committer.email;entry.committerDate=committer.date
        return entry
    }
}
public enum GitSingleCommitDetails:Sendable {
    case workingTree
    case tree(objectID:String)
    case commit(GitSingleCommit)
    public func asLogEntry() throws -> LogEntry {
        switch self {
        case .commit(let value):return value.asLogEntry()
        case .workingTree:return LogEntry(hash:"",author:"",date:"",subject:"Working Tree")
        case .tree:throw GitSingleCommitFailure.notCommit
        }
    }
}
struct GitSingleCommitRaw:Sendable {
    var oid:String,tree:String,parents:[String]
    var authorTime:Int64,authorOffset:Int32,committerTime:Int64,committerOffset:Int32
    var fields:[String:Data]
    var hasEncoding:Bool
    func decoded() throws -> GitSingleCommit {
        let encoding=hasEncoding ? fields["encoding"] ?? Data():nil
        let name=encoding.map {String(decoding:$0,as:UTF8.self)} ?? "utf-8"
        func decode(_ field:String) throws -> String {try CommitMessageEncoding.decode(fields[field] ?? Data(),name:name)}
        return try .init(objectID:oid,tree:tree,parents:parents,encodingBytes:encoding,
                         author:.init(nameBytes:fields["authorName"] ?? Data(),emailBytes:fields["authorEmail"] ?? Data(),name:decode("authorName"),email:decode("authorEmail"),time:authorTime,offsetMinutes:authorOffset),
                         committer:.init(nameBytes:fields["committerName"] ?? Data(),emailBytes:fields["committerEmail"] ?? Data(),name:decode("committerName"),email:decode("committerEmail"),time:committerTime,offsetMinutes:committerOffset),messageBytes:fields["message"] ?? Data(),message:decode("message"))
    }
}
enum GitSingleCommitProtocol {
    static let prefix=Data("TurtleGit SingleCommit v1:".utf8)
    static let fieldOrder=["encoding","authorName","authorEmail","committerName","committerEmail","message"]
    static func decode(_ data:Data,cancellation:OperationCancellation?=nil) throws -> GitSingleCommitDetails {
        guard data.count<=64*1024*1024,data.last==10 else {throw GitSingleCommitFailure.output}
        var header=false,ended=false,count=0,raw:GitSingleCommitRaw?,tree:String?,sizes=[String:Int](),fieldIndex=0
        func string(_ obj:[String:Any],_ key:String) throws -> String {guard let s=obj[key] as? String,!s.utf8.contains(0),s.utf8.count<=1024*1024 else{throw GitSingleCommitFailure.output};return s}
        func integer(_ obj:[String:Any],_ key:String) throws -> Int64 {
            guard let number=obj[key] as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),let value=Int64(number.stringValue) else{throw GitSingleCommitFailure.output};return value
        }
        for line in data.split(separator:10,omittingEmptySubsequences:false).dropLast() {
            try cancellation?.check()
            guard !ended,line.count<=2*1024*1024,line.starts(with:prefix),let bytes=Data(base64Encoded:Data(line.dropFirst(prefix.count))),bytes.base64EncodedData()==Data(line.dropFirst(prefix.count)),let obj=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],let kind=obj["kind"] as? String else {throw GitSingleCommitFailure.output}
            switch kind {
            case "header":guard !header,count==0,Set(obj.keys)==["kind"] else{throw GitSingleCommitFailure.output};header=true
            case "tree":
                guard header,count==0,Set(obj.keys)==["kind","oid","objectType"],obj["objectType"] as? String=="tree" else{throw GitSingleCommitFailure.output}
                let oid=try string(obj,"oid");guard GitLocalReferenceProtocol.validOID(oid) else{throw GitSingleCommitFailure.output};tree=oid;count=1
            case "commit":
                let keys:Set<String>=["kind","oid","objectType","tree","parents","authorTime","authorOffset","committerTime","committerOffset","encodingBytes","authorNameBytes","authorEmailBytes","committerNameBytes","committerEmailBytes","messageBytes"]
                guard header,count==0,Set(obj.keys)==keys,obj["objectType"] as? String=="commit",let parents=obj["parents"] as? [String],parents.count<=4096,parents.allSatisfy(GitLocalReferenceProtocol.validOID) else{throw GitSingleCommitFailure.output}
                let oid=try string(obj,"oid"),treeOID=try string(obj,"tree"),a=try integer(obj,"authorOffset"),c=try integer(obj,"committerOffset")
                guard GitLocalReferenceProtocol.validOID(oid),GitLocalReferenceProtocol.validOID(treeOID),treeOID.utf8.count==oid.utf8.count,parents.allSatisfy({$0.utf8.count==oid.utf8.count}),(-1439...1439).contains(a),(-1439...1439).contains(c) else{throw GitSingleCommitFailure.output}
                for field in fieldOrder {
                    if field=="encoding",obj["encodingBytes"] is NSNull {sizes[field]=0;continue}
                    let n=try integer(obj,field+"Bytes"),limit:Int64=field=="message" ? 16*1024*1024:1024*1024
                    guard n>=0,n<=limit else{throw GitSingleCommitFailure.output};sizes[field]=Int(n)
                }
                raw = .init(oid:oid,tree:treeOID,parents:parents,authorTime:try integer(obj,"authorTime"),authorOffset:Int32(a),committerTime:try integer(obj,"committerTime"),committerOffset:Int32(c),fields:[:],hasEncoding:!(obj["encodingBytes"] is NSNull));count=1
            case "bytes":
                guard header,raw != nil,tree==nil,Set(obj.keys)==["kind","field","data"] else{throw GitSingleCommitFailure.output}
                while fieldIndex<fieldOrder.count,(raw!.fields[fieldOrder[fieldIndex]]?.count ?? 0)==sizes[fieldOrder[fieldIndex]] {fieldIndex+=1}
                let field=try string(obj,"field"),encoded=try string(obj,"data")
                guard fieldIndex<fieldOrder.count,field==fieldOrder[fieldIndex],let chunk=Data(base64Encoded:encoded),!chunk.isEmpty,chunk.count<=512*1024,chunk.base64EncodedString()==encoded else{throw GitSingleCommitFailure.output}
                let current=raw!.fields[field]?.count ?? 0
                guard current+chunk.count<=sizes[field]! else{throw GitSingleCommitFailure.output};raw!.fields[field,default:Data()].append(chunk);count+=1
            case "end":
                guard header,count>0,Set(obj.keys)==["kind","count"],try integer(obj,"count")==count else{throw GitSingleCommitFailure.output}
                if let raw {for field in fieldOrder {guard (raw.fields[field]?.count ?? 0)==sizes[field] else{throw GitSingleCommitFailure.output}}}
                ended=true
            default:throw GitSingleCommitFailure.output
            }
        }
        guard ended else{throw GitSingleCommitFailure.output};try cancellation?.check()
        if let tree{return .tree(objectID:tree)};guard let raw else{throw GitSingleCommitFailure.output};return .commit(try raw.decoded())
    }
    static func parseCommit(_ data:Data,oid:String) throws -> GitSingleCommitRaw {
        guard GitLocalReferenceProtocol.validOID(oid),data.count<=32*1024*1024,let split=data.range(of:Data([10,10])) else{throw GitSingleCommitFailure.output}
        let header=data[..<split.lowerBound],message=Data(data[split.upperBound...].prefix(while:{$0 != 0}))
        guard message.count<=16*1024*1024 else{throw GitSingleCommitFailure.output}
        var tree:String?,parents=[String](),encoding:Data?,author:(Data,Data,Int64,Int32)?,committer:(Data,Data,Int64,Int32)?
        func signature(_ bytes:Data) throws -> (Data,Data,Int64,Int32) {
            guard let close=bytes.lastIndex(of:62),let open=bytes[..<close].lastIndex(of:60),open>bytes.startIndex,bytes[bytes.index(before:open)]==32 else{throw GitSingleCommitFailure.output}
            let name=Data(bytes[..<bytes.index(before:open)]),email=Data(bytes[bytes.index(after:open)..<close])
            let tail=String(decoding:bytes[bytes.index(after:close)...],as:UTF8.self).split(separator:" ")
            guard tail.count==2,let time=Int64(tail[0]),tail[1].utf8.count==5,let sign=tail[1].first,[Character("+"),"-"].contains(sign),let h=Int(tail[1].dropFirst().prefix(2)),let m=Int(tail[1].suffix(2)),tail[1].dropFirst().utf8.allSatisfy({(48...57).contains($0)}),h<24,m<60,name.count<=1024*1024,email.count<=1024*1024 else{throw GitSingleCommitFailure.output}
            func trim(_ value:Data)->Data {
                let bytes=Array(value);let crud:Set<UInt8>=[44,58,59,60,62,34,92,39]
                let content=bytes.drop(while:{$0<=32 || crud.contains($0)}).reversed().drop(while:{$0<=32 || crud.contains($0)}).reversed()
                return Data(content.prefix(while:{$0 != 0}))
            }
            return(trim(name),trim(email),time,Int32((h*60+m)*(sign=="-" ? -1:1)))
        }
        for line in header.split(separator:10,omittingEmptySubsequences:false) {
            if line.first==32 {continue}
            guard let space=line.firstIndex(of:32),let key=String(data:line[..<space],encoding:.utf8) else{throw GitSingleCommitFailure.output}
            let bytes=Data(line[line.index(after:space)...])
            switch key {
            case "tree":guard tree==nil,let value=String(data:bytes,encoding:.utf8),GitLocalReferenceProtocol.validOID(value) else{throw GitSingleCommitFailure.output};tree=value
            case "parent":guard parents.count<4096,let value=String(data:bytes,encoding:.utf8),GitLocalReferenceProtocol.validOID(value) else{throw GitSingleCommitFailure.output};parents.append(value)
            case "encoding":guard encoding==nil,bytes.count<=1024*1024 else{throw GitSingleCommitFailure.output};encoding=Data(bytes.prefix(while:{$0 != 0}))
            case "author":guard author==nil else{throw GitSingleCommitFailure.output};author=try signature(bytes)
            case "committer":guard committer==nil else{throw GitSingleCommitFailure.output};committer=try signature(bytes)
            default:continue
            }
        }
        guard let tree,tree.utf8.count==oid.utf8.count,parents.allSatisfy({$0.utf8.count==oid.utf8.count}),let author,let committer else{throw GitSingleCommitFailure.output}
        var fields=["authorName":author.0,"authorEmail":author.1,"committerName":committer.0,"committerEmail":committer.1,"message":message]
        if let encoding {fields["encoding"]=encoding}
        return .init(oid:oid,tree:tree,parents:parents,authorTime:author.2,authorOffset:author.3,committerTime:committer.2,committerOffset:committer.3,fields:fields,hasEncoding:encoding != nil)
    }
}
extension GitRepository {
    public func singleCommitDetails(revision:ComparisonRevision,allowTree:Bool=false,useMailmap:Bool=false,cancellation:OperationCancellation?=nil,backend:GitLibGit2Configuration?=nil) throws -> GitSingleCommitDetails {
        switch revision {
        case .workingTree:try (cancellation ?? replayCancellation)?.check();return .workingTree
        case .revision(let name):return try singleCommitDetails(revision:name,allowTree:allowTree,useMailmap:useMailmap,cancellation:cancellation,backend:backend)
        case .emptyTree:throw GitSingleCommitFailure.notCommit
        }
    }
    public func singleCommitDetails(revision:String,allowTree:Bool=false,useMailmap:Bool=false,cancellation:OperationCancellation?=nil,backend:GitLibGit2Configuration?=nil) throws -> GitSingleCommitDetails {
        let token=cancellation ?? replayCancellation;try token?.check()
        guard !revision.isEmpty,!revision.utf8.contains(0),revision.utf8.count<=1024*1024 else{throw GitSingleCommitFailure.notCommit}
        let selected=backend ?? libgit2Configuration ?? .load()
        var value:GitSingleCommitDetails
        if let helper=try selected.executor(for:.getCommit) {
            let packet=try JSONSerialization.data(withJSONObject:["version":1,"revision":revision,"allowTree":allowTree],options:[.sortedKeys]);var output=Data()
            // Git reference names are byte identities, even on a volume that
            // precomposes working-tree paths. libgit2 otherwise normalizes the
            // reference operand and can resolve a different packed reference.
            // This read-only process override never changes repository config.
            _ = try run(["-c","core.precomposeunicode=false","turtlegit-single-commit"],cancellation:token,input:packet,retainStandardOutput:false,consumeOutput:{chunk in if case .stdout=chunk.stream {guard output.count+chunk.data.count<=64*1024*1024 else{throw GitSingleCommitFailure.output};output.append(chunk.data)}},executorOverride:helper)
            value=try GitSingleCommitProtocol.decode(output,cancellation:token)
        } else {
            let commit=try run(["rev-parse","--verify","--quiet","--end-of-options",revision+"^{commit}"],successfulExitCodes:0...1,cancellation:token)
            if commit.exitCode==0 {
                let oid=commit.text.trimmingCharacters(in:.newlines);guard GitLocalReferenceProtocol.validOID(oid) else{throw GitSingleCommitFailure.output}
                var bytes=Data()
                _ = try run(["cat-file","commit",oid],cancellation:token,retainStandardOutput:false,consumeOutput:{chunk in if case .stdout=chunk.stream {guard bytes.count+chunk.data.count<=32*1024*1024 else{throw GitSingleCommitFailure.output};bytes.append(chunk.data)}})
                value = .commit(try GitSingleCommitProtocol.parseCommit(bytes,oid:oid).decoded())
            } else if allowTree {
                let tree=try run(["rev-parse","--verify","--end-of-options",revision+"^{tree}"],cancellation:token).text.trimmingCharacters(in:.newlines)
                guard GitLocalReferenceProtocol.validOID(tree) else{throw GitSingleCommitFailure.output};value = .tree(objectID:tree)
            } else {throw GitSingleCommitFailure.notCommit}
        }
        if case .tree=value,!allowTree {throw GitSingleCommitFailure.notCommit}
        if useMailmap,case .commit(let commit)=value {
            func mapped(_ signature:GitCommitSignature) throws -> GitCommitSignature {
                let result=try run(["check-mailmap","--",signature.name+" <"+signature.email+">"],cancellation:token)
                var bytes=result.stdout;if bytes.last==10{bytes.removeLast()}
                guard let line=String(data:bytes,encoding:.utf8),let split=line.range(of:" <",options:.backwards),line.hasSuffix(">") else{throw GitSingleCommitFailure.output}
                return .init(nameBytes:signature.nameBytes,emailBytes:signature.emailBytes,name:String(line[..<split.lowerBound]),email:String(line[split.upperBound..<line.index(before:line.endIndex)]),time:signature.time,offsetMinutes:signature.offsetMinutes)
            }
            value = .commit(try .init(objectID:commit.objectID,tree:commit.tree,parents:commit.parents,encodingBytes:commit.encodingBytes,author:mapped(commit.author),committer:mapped(commit.committer),messageBytes:commit.messageBytes,message:commit.message))
        }
        try token?.check();return value
    }
    public nonisolated func singleCommitBackendIdentity(cancellation:OperationCancellation?=nil,backend:GitLibGit2Configuration?=nil) throws -> String {
        try cancellation?.check();let selected=backend ?? libgit2Configuration ?? .load()
        guard selected.requests(.getCommit) else{return "single-commit-cli-v1"}
        guard let helper=try? selected.executor(for:.getCommit) else{return "single-commit-v1:missing:\(selected.helperURL?.path ?? "bundled")"}
        let attributes=(try? FileManager.default.attributesOfItem(atPath:helper.path)) ?? [:]
        let modified=(attributes[.modificationDate] as? Date)?.timeIntervalSince1970.bitPattern
        return "single-commit-v1:\(helper.path):\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? ""):\(attributes[.size] ?? ""):\(modified.map {String($0)} ?? "missing")"
    }
}
