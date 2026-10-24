// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CoreFoundation

public enum GitLocalReferenceEngineFailure: LocalizedError {
    case output
    public var errorDescription: String? { "The selected reference engine returned invalid or incomplete reference metadata." }
}
struct GitLocalReferenceRecord: Sendable {
    let name: String, oid: String, objectType: String
    let peeledOID:String?
    let symbolicTarget: String?, upstream: String?, subject: String
    let authorName: String, authorEmail: String, committerName: String, committerEmail: String
    let authorTime: Int64?, committerTime: Int64?
}
struct GitLocalReferenceReply: Sendable {
    let references: [GitLocalReferenceRecord]
    let names: [String]
    let choices:[CheckoutReference]
    let deleted: (name:String,oid:String,symbolicTarget:String?)?
}
enum GitLocalReferenceProtocol {
    static let prefix = Data("TurtleGit LocalRefs v1:".utf8)
    static func validOID(_ value:String) -> Bool { [40,64].contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func validName(_ value:String) -> Bool {
        let bytes=Array(value.utf8)
        return bytes.starts(with:Array("refs/".utf8)) && bytes.count <= 1024*1024 && !bytes.contains(where: {$0<=32 || $0==127 || [126,94,58,63,42,91,92].contains($0)}) &&
            !value.contains("..") && !value.contains("@{") && !value.hasSuffix(".") &&
            !value.components(separatedBy:"/").contains(where: {$0.isEmpty || $0.hasPrefix(".") || $0.hasSuffix(".lock")})
    }
    static func decode(_ bytes:Data,operation:String,cancellation:OperationCancellation?=nil) throws -> GitLocalReferenceReply {
        guard bytes.count <= 64*1024*1024,bytes.last == 10 else { throw GitLocalReferenceEngineFailure.output }
        let lines=bytes.split(separator:10,omittingEmptySubsequences:false)
        var choices=[CheckoutReference](),references=[GitLocalReferenceRecord](),names=[String](),deleted:(String,String,String?)?,seen=Set<Data>(),started=false,ended=false,count=0
        func string(_ obj:[String:Any],_ key:String) throws -> String {
            guard let value=obj[key] as? String,value.utf8.count<=1024*1024,!value.utf8.contains(0) else { throw GitLocalReferenceEngineFailure.output };return value
        }
        func optional(_ obj:[String:Any],_ key:String) throws -> String? {
            if obj[key] == nil || obj[key] is NSNull {return nil};return try string(obj,key)
        }
        func time(_ obj:[String:Any],_ key:String) throws -> Int64? {
            guard let value=obj[key],!(value is NSNull) else {return nil}
            guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,n.doubleValue.rounded()==n.doubleValue,
                  n.doubleValue >= Double(Int64.min), n.doubleValue < Double(Int64.max) else { throw GitLocalReferenceEngineFailure.output };return n.int64Value
        }
        for line in lines.dropLast() {
            try cancellation?.check()
            guard !ended,line.count<=2*1024*1024,line.starts(with:prefix),let data=Data(base64Encoded:Data(line.dropFirst(prefix.count))),data.base64EncodedData()==Data(line.dropFirst(prefix.count)),
                  let obj=try JSONSerialization.jsonObject(with:data) as? [String:Any],let kind=obj["kind"] as? String else { throw GitLocalReferenceEngineFailure.output }
            switch kind {
            case "header":
                guard !started,count==0,Set(obj.keys)==["kind","operation"],obj["operation"] as? String==operation else { throw GitLocalReferenceEngineFailure.output };started=true
            case "reference":
                guard started,operation=="inventory",count<100000 else { throw GitLocalReferenceEngineFailure.output }
                let allowed:Set<String>=["kind","name","oid","objectType","symbolicTarget","upstream","subject","authorName","authorEmail","authorTime","committerName","committerEmail","committerTime"]
                guard Set(obj.keys)==allowed || Set(obj.keys)==allowed.union(["peeledOID"]) else {throw GitLocalReferenceEngineFailure.output}
                let name=try string(obj,"name"),oid=try string(obj,"oid"),type=try string(obj,"objectType"),symbolic=try optional(obj,"symbolicTarget"),upstream=try optional(obj,"upstream")
                guard validName(name),validOID(oid),["commit","tag","tree","blob"].contains(type),symbolic.map(validName) ?? true,upstream.map({$0.isEmpty || validName($0)}) ?? true,seen.insert(Data(name.utf8)).inserted else {throw GitLocalReferenceEngineFailure.output}
                let peeled=try optional(obj,"peeledOID");guard peeled.map(validOID) ?? true else{throw GitLocalReferenceEngineFailure.output}
                references.append(.init(name:name,oid:oid,objectType:type,peeledOID:peeled,symbolicTarget:symbolic,upstream:upstream,subject:try string(obj,"subject"),authorName:try string(obj,"authorName"),authorEmail:try string(obj,"authorEmail"),committerName:try string(obj,"committerName"),committerEmail:try string(obj,"committerEmail"),authorTime:try time(obj,"authorTime"),committerTime:try time(obj,"committerTime")));count+=1
            case "choice":
                guard started,operation=="choices",Set(obj.keys)==["kind","name","symbolicTarget"],count<100000 else{throw GitLocalReferenceEngineFailure.output}
                let name=try string(obj,"name"),symbolic=try optional(obj,"symbolicTarget")
                guard validName(name),symbolic.map(validName) ?? true,seen.insert(Data(name.utf8)).inserted else{throw GitLocalReferenceEngineFailure.output}
                choices.append(.init(name:name,symbolicTarget:symbolic));count+=1
            case "contains":
                guard started,["contains","names","remotes"].contains(operation),Set(obj.keys)==["kind","name"],count<100000 else {throw GitLocalReferenceEngineFailure.output}
                let name=try string(obj,"name");guard (operation=="remotes" ? !name.isEmpty : validName(name)),seen.insert(Data(name.utf8)).inserted else {throw GitLocalReferenceEngineFailure.output};names.append(name);count+=1
            case "deleted":
                guard started,operation=="delete",count==0,Set(obj.keys)==["kind","name","oid","symbolicTarget"] else {throw GitLocalReferenceEngineFailure.output}
                let name=try string(obj,"name"),oid=try string(obj,"oid"),symbolic=try optional(obj,"symbolicTarget")
                guard validName(name),validOID(oid),symbolic.map(validName) ?? true else {throw GitLocalReferenceEngineFailure.output};deleted=(name,oid,symbolic);count=1
            case "end":
                guard started,Set(obj.keys)==["kind","count"],let n=obj["count"] as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue==Double(count),operation != "delete" || count==1 else {throw GitLocalReferenceEngineFailure.output};ended=true
            default:throw GitLocalReferenceEngineFailure.output
            }
        }
        guard started,ended else {throw GitLocalReferenceEngineFailure.output};try cancellation?.check()
        return .init(references:references,names:names,choices:choices,deleted:deleted)
    }
}

extension GitRepository {
    func localReferenceReply(verb:String,operation:String,request:[String:Any],backend:GitLibGit2Configuration,command:GitLibGit2Operation,cancellation:OperationCancellation?) throws -> GitLocalReferenceReply {
        guard let executor=try backend.executor(for:command) else {throw GitLocalReferenceEngineFailure.output}
        let input=try JSONSerialization.data(withJSONObject:request,options:[.sortedKeys])
        guard input.count<=2*1024*1024 else {throw GitLocalReferenceEngineFailure.output}
        var output=Data()
        _ = try run(["-c","core.precomposeunicode=false",verb],cancellation:cancellation,input:input,retainStandardOutput:false,consumeOutput:{ chunk in
            if case .stdout = chunk.stream {
                guard output.count + chunk.data.count <= 64*1024*1024 else {throw GitLocalReferenceEngineFailure.output}
                output.append(chunk.data)
            }
        },executorOverride:executor)
        return try GitLocalReferenceProtocol.decode(output,operation:operation,cancellation:cancellation)
    }
    /// GetBranchList/GetTagList/GetRemoteList/GetMapHashToFriendName use the
    /// master setting independently of the Reference Browser's command mask.
    func masterReferenceBackend(_ backend:GitLibGit2Configuration?=nil) -> GitLibGit2Configuration? {
        let selected=backend ?? libgit2Configuration ?? .load()
        return selected.enabled ? .init(enabled:true,mask:GitLibGit2Operation.forEachRef.mask,helperURL:selected.helperURL) : nil
    }
    func masterRemoteNames(cancellation:OperationCancellation?,backend:GitLibGit2Configuration?=nil) throws -> [String]? {
        guard let backend=masterReferenceBackend(backend) else{return nil}
        let names=try localReferenceReply(verb:"turtlegit-configured-remotes",operation:"remotes",request:["version":1],backend:backend,command:.forEachRef,cancellation:cancellation).names
        return names.sorted {let order=$0.localizedStandardCompare($1);return order == .orderedSame ? $0.utf8.lexicographicallyPrecedes($1.utf8) : order == .orderedAscending}
    }
    public func localReferenceBackendIdentity(cancellation:OperationCancellation?=nil,backend:GitLibGit2Configuration?=nil) throws -> String {
        try cancellation?.check();let selected=backend ?? libgit2Configuration ?? .load()
        guard selected.enabled else {return "local-references-cli-v1"}
        // GetRefList completion is selected by the master switch independently
        // of operation bits. Identity lookup must not block another CLI read.
        let enabled = GitLibGit2Configuration(enabled:true,mask:GitLibGit2Operation.forEachRef.mask,helperURL:selected.helperURL)
        guard let helper = try? enabled.executor(for:.forEachRef) else {return "local-references-v1:missing:\(selected.mask):\(selected.helperURL?.path ?? "bundled")"}
        let attrs=(try? FileManager.default.attributesOfItem(atPath:helper.path)) ?? [:]
        return "local-references-v1:\(selected.mask):\(helper.path):\(attrs[.systemNumber] ?? ""):\(attrs[.systemFileNumber] ?? ""):\(attrs[.size] ?? ""):\(attrs[.modificationDate] ?? "")"
    }
    func localReferenceCatalog(scope:String = "all",backend:GitLibGit2Configuration,cancellation:OperationCancellation?) throws -> [GitLocalReferenceRecord] {
        try localReferenceReply(verb:"turtlegit-local-refs",operation:"inventory",request:["version":1,"scope":scope],backend:backend,command:.forEachRef,cancellation:cancellation).references
    }
    func localReferenceSymbolicTarget(_ name:String,cancellation:OperationCancellation?) throws -> String? {
        let output=try run(["symbolic-ref","--quiet","--no-recurse",name],successfulExitCodes:0...1,cancellation:cancellation)
        if output.exitCode != 0{return nil}
        var bytes=output.stdout;if bytes.last==10{bytes.removeLast()}
        guard let name=String(data:bytes,encoding:.utf8),GitLocalReferenceProtocol.validName(name) else{throw GitLocalReferenceEngineFailure.output};return name
    }
    func deleteLocalReference(name:String,expectedOID:String,expectedSymbolicTarget:String?,backend:GitLibGit2Configuration,cancellation:OperationCancellation?) throws -> String {
        let reply=try localReferenceReply(verb:"turtlegit-delete-local-ref",operation:"delete",request:["version":1,"reference":name,"expectedOID":expectedOID,"expectedSymbolicTarget":expectedSymbolicTarget as Any? ?? NSNull()],backend:backend,command:.deleteTagBranch,cancellation:cancellation)
        guard let deleted=reply.deleted,GitReferenceName.equal(deleted.name,name),deleted.oid==expectedOID,deleted.symbolicTarget.map({Data($0.utf8)})==expectedSymbolicTarget.map({Data($0.utf8)}) else {throw GitLocalReferenceEngineFailure.output}
        return ""
    }
}
