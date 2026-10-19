// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum GitDiffEngineFailure:LocalizedError {
    case request,metadata,budget
    public var errorDescription:String? {
        switch self {
        case .request:return "The requested comparison cannot be represented by the selected diff engine."
        case .metadata:return "The selected history diff engine returned incomplete or invalid file metadata."
        case .budget:return "The selected diff engine output exceeded the supported size."
        }
    }
}
struct GitHistoryDiffDelta:Sendable {
    let parentIndex:Int,status:String,path:String,oldPath:String?,oldOID:String,newOID:String
    let oldMode:UInt32,newMode:UInt32,binary:Bool,added:Int?,deleted:Int?
    var file:CommitFile {
        .init(path:path,oldPath:oldPath,action:status,added:added,removed:deleted,hasStatistics:true,
              isSubmodule:newMode==0o160000 || newMode==0 && oldMode==0o160000,
              oldObjectID:oldOID,newObjectID:newOID,oldMode:oldMode,newMode:newMode)
    }
}
struct GitHistoryDiffResult:Sendable {
    let revision:String,parents:[String],deltas:[GitHistoryDiffDelta],paths:[String]
    var groups:[[CommitFile]] {
        (0..<max(1,parents.count)).map {index in deltas.filter {$0.parentIndex==index}.map(\.file)}
    }
}
/// Metadata remains private until the complete header/delta/end transaction is
/// validated. No diagnostic string or partial helper result becomes a file row.
final class GitHistoryDiffDecoder {
    static let prefix=Data("TurtleGit HistoryDiff v1:".utf8)
    private let revision:String,simple:Bool
    private var pending=Data(),bytes=0,events=0,count=0,lastParent=0,ended=false
    private var parents:[String]?,deltas:[GitHistoryDiffDelta]=[],paths:[String]=[]
    private var identities=Set<Data>()
    init(revision:String,simple:Bool){self.revision=revision;self.simple=simple}
    func append(_ data:Data)throws {
        guard data.count<=64*1024*1024-bytes else{throw GitDiffEngineFailure.budget};bytes+=data.count;pending.append(data)
        while let newline=pending.firstIndex(of:10) {
            let line=Data(pending[..<newline]);pending.removeSubrange(...newline)
            guard !ended,line.count<=2*1024*1024,events<100_000,line.starts(with:Self.prefix),let payload=Data(base64Encoded:line.dropFirst(Self.prefix.count)),payload.base64EncodedData()==Data(line.dropFirst(Self.prefix.count)),String(data:payload,encoding:.utf8) != nil,let object=try? JSONSerialization.jsonObject(with:payload) as? [String:Any],let kind=object["kind"] as? String else{throw GitDiffEngineFailure.metadata}
            struct Strings:Decodable {let path:String?,oldPath:String?,revision:String?,parents:[String]?}
            guard (try? JSONDecoder().decode(Strings.self,from:payload)) != nil else{throw GitDiffEngineFailure.metadata}
            events+=1
            switch kind {
            case "header":
                guard parents==nil,Set(object.keys)==["kind","revision","parents"],object["revision"] as? String==revision,let values=object["parents"] as? [String],values.count<=4096,values.allSatisfy({Self.oid($0,length:revision.utf8.count,zero:false)}) else{throw GitDiffEngineFailure.metadata}
                parents=values
            case "path":
                guard simple,parents != nil,Set(object.keys)==["kind","path"],let path=object["path"] as? String,GitTransferNotificationDecoder.validPath(path),identities.insert(Data(path.utf8)).inserted else{throw GitDiffEngineFailure.metadata}
                paths.append(path);count+=1
            case "delta":
                struct Delta:Decodable {let parentIndex:UInt64,status:String,path:String,oldPath:String?,oldOID:String,newOID:String,oldMode:UInt32,newMode:UInt32,binary:Bool,added:UInt64?,deleted:UInt64?}
                guard !simple,let parents,Set(object.keys)==["kind","parentIndex","status","path","oldPath","oldOID","newOID","oldMode","newMode","binary","added","deleted"],let value=try? JSONDecoder().decode(Delta.self,from:payload),value.parentIndex<UInt64(max(1,parents.count)),value.parentIndex>=UInt64(lastParent),["A","D","M","R","C","T"].contains(value.status),GitTransferNotificationDecoder.validPath(value.path),value.oldPath.map({GitTransferNotificationDecoder.validPath($0)}) != false,Self.oid(value.oldOID,length:revision.utf8.count),Self.oid(value.newOID,length:revision.utf8.count),Self.mode(value.oldMode),Self.mode(value.newMode),value.added.map({$0<=UInt64(Int.max)}) != false,value.deleted.map({$0<=UInt64(Int.max)}) != false,(value.added==nil)==(value.deleted==nil),!value.binary || value.added==nil,!["R","C"].contains(value.status) || value.oldPath != nil else{throw GitDiffEngineFailure.metadata}
                let oldZero=value.oldOID.allSatisfy{$0=="0"},newZero=value.newOID.allSatisfy{$0=="0"}
                switch value.status {
                case "A":guard oldZero,value.oldMode==0,!newZero,value.newMode != 0 else{throw GitDiffEngineFailure.metadata}
                case "D":guard newZero,value.newMode==0,!oldZero,value.oldMode != 0 else{throw GitDiffEngineFailure.metadata}
                default:guard !oldZero,!newZero,value.oldMode != 0,value.newMode != 0 else{throw GitDiffEngineFailure.metadata}
                }
                let index=Int(value.parentIndex)
                guard identities.insert(Data((String(index)+"\0"+value.path).utf8)).inserted else{throw GitDiffEngineFailure.metadata}
                lastParent=index;count+=1
                deltas.append(.init(parentIndex:index,status:value.status,path:value.path,oldPath:value.oldPath,oldOID:value.oldOID,newOID:value.newOID,oldMode:value.oldMode,newMode:value.newMode,binary:value.binary,added:value.added.map(Int.init),deleted:value.deleted.map(Int.init)))
            case "end":
                struct End:Decodable {let count:UInt64}
                guard parents != nil,Set(object.keys)==["kind","count"],let end=try? JSONDecoder().decode(End.self,from:payload),end.count==UInt64(count) else{throw GitDiffEngineFailure.metadata};ended=true
            default:throw GitDiffEngineFailure.metadata
            }
        }
        guard pending.count<=2*1024*1024 else{throw GitDiffEngineFailure.budget}
    }
    func finish()throws->GitHistoryDiffResult {
        guard pending.isEmpty,ended,let parents else{throw GitDiffEngineFailure.metadata}
        return .init(revision:revision,parents:parents,deltas:deltas,paths:paths)
    }
    static func oid(_ value:String,length:Int,zero:Bool=true)->Bool {
        [40,64].contains(length) && value.utf8.count==length && value.utf8.allSatisfy {(48...57).contains($0) || (97...102).contains($0)} && (zero || value.contains(where:{$0 != "0"}))
    }
    private static func mode(_ value:UInt32)->Bool {[0,0o100644,0o100755,0o120000,0o160000,0o040000].contains(value)}
}

extension GitRepository {
    func historyDiff(revision:String,simple:Bool,backend:GitLibGit2Configuration,cancellation:OperationCancellation?)throws->GitHistoryDiffResult {
        guard GitHistoryDiffDecoder.oid(revision,length:revision.utf8.count,zero:false),let executor=try backend.executor(for:.logListDiff) else{throw GitDiffEngineFailure.request}
        try cancellation?.check()
        let input=try JSONSerialization.data(withJSONObject:["version":1,"revision":revision,"simple":simple,"threshold":diffDetection.percentage],options:.sortedKeys)
        let decoder=GitHistoryDiffDecoder(revision:revision,simple:simple)
        _ = try run(["turtlegit-history-diff"],environmentOverrides:["GIT_OPTIONAL_LOCKS":"0"],cancellation:cancellation,input:input,retainStandardOutput:false,consumeOutput:{chunk in if case .stdout=chunk.stream{try decoder.append(chunk.data)}},executorOverride:executor)
        try cancellation?.check();return try decoder.finish()
    }
    /// Only callers presenting a source unified patch use this entry point.
    /// Index-only staging previews retain their existing CLI implementation;
    /// source GetUnifiedDiff has no index endpoint.
    public func unifiedDiffData(arguments:[String],cancellation:OperationCancellation? = nil,backend:GitLibGit2Configuration? = nil)throws->Data {
        let selected=backend ?? libgit2Configuration ?? .load()
        guard selected.requests(.diff),!arguments.contains("--cached"),!arguments.contains("--staged") else{return try run(arguments,environmentOverrides:["GIT_OPTIONAL_LOCKS":"0"],cancellation:cancellation).stdout}
        guard let executor=try selected.executor(for:.diff) else{throw GitDiffEngineFailure.request}
        try cancellation?.check()
        let identity=GitCommandIdentity(arguments)
        guard ["diff","diff-tree","show"].contains(identity.command ?? ""),!identity.arguments.contains(where:{["--numstat","--name-status","--name-only","--raw","--check","--quiet","--exit-code","--no-index"].contains($0)}) else{throw GitDiffEngineFailure.request}
        let globals=Array(arguments.prefix(arguments.count-identity.arguments.count-1))
        var after=false,paths:[String]=[],revisions:[String]=[],skip=false,noPrefix=false
        for arg in identity.arguments {
            if after {paths.append(arg);continue}
            if skip {skip=false;continue}
            if arg=="--" {after=true;continue}
            if arg=="--no-prefix" {noPrefix=true;continue}
            if arg=="--unified" || arg=="-U" {skip=true;continue}
            if arg.hasPrefix("-") {continue} // Source4 ignores CLI context/merge/detection options.
            revisions.append(arg)
        }
        if paths.contains(".") {paths=[]}
        guard !skip,revisions.count<=2,paths.count<=100_000,paths.allSatisfy({GitTransferNotificationDecoder.validPath($0)}) else{throw GitDiffEngineFailure.request}
        // Source4 returns empty in an unborn repository even for supplied trees.
        let head=try run(["rev-parse","--verify","--quiet","HEAD^{commit}"],successfulExitCodes:0...1,cancellation:cancellation)
        if head.exitCode==1{return Data()}
        func captured(_ revision:String)throws->String {
            let result=try run(["rev-parse","--verify","--end-of-options",revision+"^{object}"],cancellation:cancellation).stdout
            guard var value=String(data:result,encoding:.utf8) else{throw GitDiffEngineFailure.request}
            if value.last=="\n"{value.removeLast()}
            guard GitHistoryDiffDecoder.oid(value,length:value.utf8.count,zero:false) else{throw GitDiffEngineFailure.request};return value
        }
        let old:String,new:String
        if identity.command=="diff" {
            if revisions.count==2 {old=try captured(revisions[0]);new=try captured(revisions[1])}
            else {old=try captured(revisions.first ?? "HEAD");new="WORKTREE"}
        } else {
            guard !revisions.isEmpty else{throw GitDiffEngineFailure.request}
            old=revisions.count==2 ? try captured(revisions[0]):"";new=try captured(revisions.last!)
        }
        let input=try JSONSerialization.data(withJSONObject:["version":1,"old":old,"new":new,"paths":paths,"noPrefix":noPrefix],options:.sortedKeys)
        guard input.count<=2*1024*1024 else{throw GitDiffEngineFailure.budget}
        var output=Data()
        do {
            _ = try run(globals+["turtlegit-unified-diff"],environmentOverrides:["GIT_OPTIONAL_LOCKS":"0"],cancellation:cancellation,input:input,retainStandardOutput:false,consumeOutput:{chunk in
                if case .stdout=chunk.stream {guard chunk.data.count<=128*1024*1024-output.count else{throw GitDiffEngineFailure.budget};output.append(chunk.data)}
            },executorOverride:executor)
        } catch let failure as GitFailure {throw GitFailure(arguments:arguments,code:failure.code,message:failure.message,outputWasDelivered:failure.outputWasDelivered,standardError:failure.standardError)}
        try cancellation?.check();return output
    }
}
