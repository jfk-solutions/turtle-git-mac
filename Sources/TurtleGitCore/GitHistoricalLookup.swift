// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public struct RepositoryBrowserRevision:Sendable {
    public let objectID:String?,treeID:String?
    public let unbornHead:Bool
}
public enum HistoricalGitlinkLookup:Sendable,Equatable {case missing,other,gitlink(String)}
public enum GitHistoricalLookupFailure:LocalizedError {
    case revision,path,notSubmodule,input,output
    public var errorDescription:String? {
        switch self {
        case .revision:return "The historical revision is unavailable or has the wrong object type."
        case .path:return "The selected path does not exist at this revision."
        case .notSubmodule:return "The selected path is not a submodule at this revision."
        case .input:return "The historical Git path contains invalid text."
        case .output:return "The selected historical lookup engine returned invalid or incomplete metadata."
        }
    }
}
extension GitRepository {
    /// Pinned libgit2 cannot open SHA-256 repositories. Keep the existing Mac
    /// Browser extension explicit and elected before any helper starts; an
    /// unavailable or malformed SHA-1 helper is never a reason to change engine.
    func repositoryBrowserReader(_ selected:GitLibGit2Configuration,initialization:Bool,cancellation:OperationCancellation?)throws->GitLibGit2Configuration {
        if !initialization && !selected.enabled{return selected}
        let result=try run(["rev-parse","--show-object-format"],cancellation:cancellation)
        let format=String(decoding:result.stdout,as:UTF8.self).trimmingCharacters(in:.newlines)
        guard format=="sha1" || format=="sha256" else{throw RepositoryBrowserFailure.output}
        return GitLibGit2Configuration(enabled:format=="sha1",mask:selected.mask,helperURL:selected.helperURL)
    }
    /// ReadTree opens its libgit2 repository unconditionally; later browser
    /// commands use the master-selected GetHash path. Preserve that distinction.
    public func repositoryBrowserRevision(_ revision:String,initialization:Bool=false,cancellation:OperationCancellation?=nil,backend:GitLibGit2Configuration?=nil)throws->RepositoryBrowserRevision {
        try cancellation?.check()
        guard !revision.isEmpty,!revision.utf8.contains(0),revision.utf8.count<=1_048_576 else{throw RepositoryBrowserFailure.revision}
        let selected=backend ?? libgit2Configuration ?? .load()
        let reader=try repositoryBrowserReader(selected,initialization:initialization,cancellation:cancellation)
        if GitReferenceName.equal(revision,"HEAD"),try revisionLookup(revision,cancellation:cancellation,backend:reader).unbornHead {
            return .init(objectID:nil,treeID:nil,unbornHead:true)
        }
        guard let raw=try revisionLookup(revision,requirement:.existingObject,cancellation:cancellation,backend:reader).objectID else{throw RepositoryBrowserFailure.revision}
        // Commit identity survives tree conversion. A standalone tree remains
        // a tree; never choose an arbitrary commit merely containing it.
        let commit=try revisionLookup(raw,requirement:.commit,cancellation:cancellation,backend:reader).objectID
        guard let tree=try revisionLookup(raw,requirement:.tree,cancellation:cancellation,backend:reader).objectID else{throw RepositoryBrowserFailure.revision}
        return .init(objectID:commit ?? tree,treeID:tree,unbornHead:false)
    }
    public func historicalGitlink(path:String,revision:String,commitOnly:Bool=false,cancellation:OperationCancellation?=nil,backend:GitLibGit2Configuration?=nil)throws->HistoricalGitlinkLookup {
        try cancellation?.check()
        guard !path.isEmpty,path.utf8.count<=1_048_576,!path.utf8.contains(0),!path.hasPrefix("/"),!path.split(separator:"/",omittingEmptySubsequences:false).contains(where:{$0.isEmpty || $0=="." || $0==".."}) else{throw GitHistoricalLookupFailure.input}
        let selected=backend ?? libgit2Configuration ?? .load()
        guard let object=try revisionLookup(revision,requirement:commitOnly ? .commit:.tree,cancellation:cancellation,backend:selected).objectID else{throw GitHistoricalLookupFailure.revision}
        if selected.enabled {
            let input=try JSONSerialization.data(withJSONObject:["version":1,"revision":object,"path":path,"commitOnly":commitOnly],options:.sortedKeys)
            var bytes=Data()
            _ = try run(["-c","core.precomposeunicode=false","turtlegit-historical-gitlink"],cancellation:cancellation,input:input,retainStandardOutput:false,consumeOutput:{chunk in
                if case .stdout=chunk.stream {guard chunk.data.count<=4096-bytes.count else{throw GitHistoricalLookupFailure.output};bytes.append(chunk.data)}
            },executorOverride:try selected.runtimeExecutor())
            let prefix=Data("TurtleGit HistoricalGitlink v1:".utf8)
            guard bytes.last==10,!bytes.dropLast().contains(10),bytes.starts(with:prefix),let payload=Data(base64Encoded:bytes.dropLast().dropFirst(prefix.count)),payload.base64EncodedData()==bytes.dropLast().dropFirst(prefix.count),
                  let reply=(try? JSONSerialization.jsonObject(with:payload)) as? [String:Any],Set(reply.keys)==["status","oid"],let status=reply["status"] as? String else{throw GitHistoricalLookupFailure.output}
            try cancellation?.check()
            if status=="gitlink",let oid=reply["oid"] as? String,GitLocalReferenceProtocol.validOID(oid){return .gitlink(oid)}
            guard reply["oid"] is NSNull else{throw GitHistoricalLookupFailure.output}
            if status=="missing"{return .missing};if status=="other"{return .other};throw GitHistoricalLookupFailure.output
        }
        let tree:String
        if commitOnly {guard let value=try revisionLookup(object,requirement:.tree,cancellation:cancellation,backend:selected).objectID else{throw GitHistoricalLookupFailure.revision};tree=value}else{tree=object}
        let output=try run(["-c","core.precomposeunicode=false","--literal-pathspecs","ls-tree","--full-tree","-z",tree,"--",path],cancellation:cancellation).stdout
        for record in output.split(separator:0) {
            let parts=record.split(separator:9,maxSplits:1)
            guard parts.count==2 else{throw GitHistoricalLookupFailure.output}
            guard parts[1].elementsEqual(path.utf8) else{continue}
            let header=String(decoding:parts[0],as:UTF8.self).split(separator:" ")
            guard header.count==3,GitLocalReferenceProtocol.validOID(String(header[2])) else{throw GitHistoricalLookupFailure.output}
            return header[0]=="160000" && header[1]=="commit" ? .gitlink(String(header[2])):.other
        }
        return .missing
    }
    /// GetSubmoduleHash does nothing when the source master flag is disabled.
    /// Its Log pin consumer requires a real commit and an actual gitlink; it
    /// must not silently reinterpret a failed lookup as a deleted file.
    public func submoduleLogRevision(path:String,revision:String,cancellation:OperationCancellation?=nil,backend:GitLibGit2Configuration?=nil)throws->String? {
        try cancellation?.check();let selected=backend ?? libgit2Configuration ?? .load()
        guard selected.enabled else{return nil}
        switch try historicalGitlink(path:path,revision:revision,commitOnly:true,cancellation:cancellation,backend:selected) {
        case .gitlink(let oid):return oid
        case .missing:throw GitHistoricalLookupFailure.path
        case .other:throw GitHistoricalLookupFailure.notSubmodule
        }
    }
}
