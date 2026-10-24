// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CoreFoundation

/// Source GetHash accepts an object identity without necessarily looking it up.
/// Native preparation requiring a real commit/tree must request that explicitly.
public enum GitRevisionRequirement:String,Sendable {case sourceObject,existingObject,commit,tree}
public struct GitRevisionLookup:Sendable {
    public let objectID:String?
    public let unbornHead:Bool
}
public enum GitRevisionLookupFailure:LocalizedError {
    case input,output
    public var errorDescription:String? {
        switch self {
        case .input:return "The revision or reference contains invalid text."
        case .output:return "The selected revision engine returned invalid or incomplete metadata."
        }
    }
}
extension GitRepository {
    private func lookupInput(_ value:String)throws {
        guard value.utf8.count<=1_048_576,!value.utf8.contains(0) else{throw GitRevisionLookupFailure.input}
    }
    private func lookupCommand(_ arguments:[String],cancellation:OperationCancellation?)throws->GitResult {
        do{return try run(["-c","core.precomposeunicode=false"]+arguments,successfulExitCodes:0...1,cancellation:cancellation)}
        catch let failure as GitFailure {throw GitFailure(arguments:arguments,code:failure.code,message:failure.message)}
    }
    private func lookupReply(_ request:[String:Any],backend:GitLibGit2Configuration,cancellation:OperationCancellation?)throws->[String:Any] {
        let executor=try backend.runtimeExecutor(),input=try JSONSerialization.data(withJSONObject:request,options:.sortedKeys)
        var bytes=Data()
        _ = try run(["-c","core.precomposeunicode=false","turtlegit-revision-lookup"],cancellation:cancellation,input:input,retainStandardOutput:false,consumeOutput:{chunk in
            if case .stdout=chunk.stream {guard chunk.data.count<=2_097_152-bytes.count else{throw GitRevisionLookupFailure.output};bytes.append(chunk.data)}
        },executorOverride:executor)
        let prefix=Data("TurtleGit RevisionLookup v1:".utf8)
        guard bytes.last==10,!bytes.dropLast().contains(10),bytes.starts(with:prefix),let data=Data(base64Encoded:bytes.dropLast().dropFirst(prefix.count)),data.base64EncodedData()==bytes.dropLast().dropFirst(prefix.count),
              let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else{throw GitRevisionLookupFailure.output}
        try cancellation?.check();return object
    }
    public func revisionLookup(_ revision:String,requirement:GitRevisionRequirement = .sourceObject,cancellation:OperationCancellation?=nil,backend:GitLibGit2Configuration?=nil)throws->GitRevisionLookup {
        try cancellation?.check();try lookupInput(revision)
        if requirement == .sourceObject,revision.utf8.count==40,revision.utf8.allSatisfy({(48...57).contains($0)||(65...70).contains($0)||(97...102).contains($0)}) {
            return .init(objectID:revision.lowercased(),unbornHead:false)
        }
        guard !revision.isEmpty else{return .init(objectID:nil,unbornHead:false)}
        let selected=backend ?? libgit2Configuration ?? .load()
        if selected.enabled {
            let reply=try lookupReply(["version":1,"operation":"revision","revision":revision,"requirement":requirement.rawValue],backend:selected,cancellation:cancellation)
            guard Set(reply.keys)==["operation","oid","unbornHead"],reply["operation"] as? String=="revision",let unborn=reply["unbornHead"] as? NSNumber,CFGetTypeID(unborn)==CFBooleanGetTypeID() else{throw GitRevisionLookupFailure.output}
            let oid:String?
            if reply["oid"] is NSNull {oid=nil} else {guard let value=reply["oid"] as? String,GitLocalReferenceProtocol.validOID(value) else{throw GitRevisionLookupFailure.output};oid=value}
            guard !unborn.boolValue || oid==nil && requirement == .sourceObject && GitReferenceName.equal(revision,"HEAD") else{throw GitRevisionLookupFailure.output}
            return .init(objectID:oid,unbornHead:unborn.boolValue)
        }
        // Resolve the user's expression before appending a type requirement.
        // In revision:path syntax a suffix belongs to the filename, so e.g.
        // HEAD:payload^{object} would ask for a different historical path.
        let raw=try lookupCommand(["rev-parse","--verify","--quiet","--end-of-options",revision],cancellation:cancellation)
        if raw.exitCode==0 {
            let oid=String(decoding:raw.stdout,as:UTF8.self).trimmingCharacters(in:.newlines).lowercased()
            guard GitLocalReferenceProtocol.validOID(oid) else{throw GitRevisionLookupFailure.output}
            if requirement == .sourceObject {return .init(objectID:oid,unbornHead:false)}
            let suffix=requirement == .commit ? "^{commit}" : requirement == .tree ? "^{tree}" : "^{object}"
            let verified=try lookupCommand(["rev-parse","--verify","--quiet","--end-of-options",oid+suffix],cancellation:cancellation)
            guard verified.exitCode==0 else{return .init(objectID:nil,unbornHead:false)}
            let resolved=String(decoding:verified.stdout,as:UTF8.self).trimmingCharacters(in:.newlines).lowercased()
            guard GitLocalReferenceProtocol.validOID(resolved) else{throw GitRevisionLookupFailure.output}
            return .init(objectID:resolved,unbornHead:false)
        }
        if requirement == .sourceObject,GitReferenceName.equal(revision,"HEAD") {
            let symbolic=try lookupCommand(["symbolic-ref","--quiet","HEAD"],cancellation:cancellation)
            if symbolic.exitCode==0 {return .init(objectID:nil,unbornHead:true)}
        }
        return .init(objectID:nil,unbornHead:false)
    }
    public func referenceExists(_ exactFullRef:String,cancellation:OperationCancellation?=nil,backend:GitLibGit2Configuration?=nil)throws->Bool {
        try cancellation?.check();try lookupInput(exactFullRef)
        guard exactFullRef.hasPrefix("refs/") else{return false}
        let selected=backend ?? libgit2Configuration ?? .load()
        if selected.enabled {
            let reply=try lookupReply(["version":1,"operation":"reference","reference":exactFullRef],backend:selected,cancellation:cancellation)
            guard Set(reply.keys)==["operation","exists"],reply["operation"] as? String=="reference",let exists=reply["exists"] as? NSNumber,CFGetTypeID(exists)==CFBooleanGetTypeID() else{throw GitRevisionLookupFailure.output}
            return exists.boolValue
        }
        // show-ref follows symbolic targets. First inspect the literal symbolic
        // ref itself so a dangling symbolic name remains an existing reference.
        // Reject syntax semantically before symbolic-ref: its fatal exit 128
        // also covers real repository I/O failures, which must remain visible.
        guard try lookupCommand(["check-ref-format",exactFullRef],cancellation:cancellation).exitCode==0 else{return false}
        if try lookupCommand(["symbolic-ref","--quiet","--no-recurse",exactFullRef],cancellation:cancellation).exitCode==0{return true}
        return try lookupCommand(["show-ref","--verify","--quiet","--",exactFullRef],cancellation:cancellation).exitCode==0
    }
    public func branchTagNameIsUnique(_ literalShortName:String,cancellation:OperationCancellation?=nil,backend:GitLibGit2Configuration?=nil)throws->Bool {
        try cancellation?.check();try lookupInput(literalShortName)
        let selected=backend ?? libgit2Configuration ?? .load()
        let branch=try referenceExists("refs/heads/"+literalShortName,cancellation:cancellation,backend:selected)
        let tag=try referenceExists("refs/tags/"+literalShortName,cancellation:cancellation,backend:selected)
        return !(branch && tag)
    }
}
