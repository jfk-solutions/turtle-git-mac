// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CryptoKit

public enum GitNotesEngineKind:String,Sendable {case libgit2,gitSHA256}
public enum GitNotesEngineFailure:LocalizedError {
    case input,output,revision
    public var errorDescription:String? {
        switch self {
        case .input:return "The notes request contains invalid text."
        case .output:return "The notes engine returned invalid or incomplete metadata."
        case .revision:return "Choose an existing commit to edit its note."
        }
    }
}
struct GitNotesValue {
    let notesRef:String,text:String,blobOID:String?,refOID:String?
}
extension GitRepository {
    func notesEngine(cancellation:OperationCancellation?)throws->GitNotesEngineKind {
        let result=try run(["rev-parse","--show-object-format"],cancellation:cancellation)
        switch String(decoding:result.stdout,as:UTF8.self).trimmingCharacters(in:.newlines) {
        case "sha1":return .libgit2
        case "sha256":return .gitSHA256
        default:throw GitNotesEngineFailure.output
        }
    }
    private func notesReply(revision:String,ref:String?,text:String?,backend:GitLibGit2Configuration,cancellation:OperationCancellation?)throws->[String:Any] {
        guard revision.utf8.count==40,GitLocalReferenceProtocol.validOID(revision),ref.map({!$0.contains("\0") && $0.utf8.count<=1_048_576}) ?? true else{throw GitNotesEngineFailure.input}
        var request:[String:Any]=["version":1,"revision":revision,"notesRef":ref.map{$0 as Any} ?? NSNull()]
        if let text {guard text.utf8.count<=16_777_216,!text.contains("\0"),ref != nil else{throw GitNotesEngineFailure.input};request["text"]=Data(text.utf8).base64EncodedString()}
        let executor=try backend.runtimeExecutor(),input=try JSONSerialization.data(withJSONObject:request,options:[.sortedKeys,.withoutEscapingSlashes])
        var bytes=Data()
        _ = try run(["-c","core.precomposeunicode=false",text == nil ? "turtlegit-notes-read":"turtlegit-notes-write"],cancellation:cancellation,input:input,retainStandardOutput:false,consumeOutput:{chunk in
            if case .stdout=chunk.stream {guard chunk.data.count<=33_554_432-bytes.count else{throw GitNotesEngineFailure.output};bytes.append(chunk.data)}
        },executorOverride:executor)
        let prefix=Data("TurtleGit Notes v1:".utf8)
        guard bytes.last==10,!bytes.dropLast().contains(10),bytes.starts(with:prefix),let data=Data(base64Encoded:bytes.dropLast().dropFirst(prefix.count)),data.base64EncodedData()==bytes.dropLast().dropFirst(prefix.count),let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else{throw GitNotesEngineFailure.output}
        try cancellation?.check();return object
    }
    private func notesOID(_ value:Any?)throws->String? {
        if value is NSNull{return nil}
        guard let value=value as? String,value.utf8.count==40,GitLocalReferenceProtocol.validOID(value) else{throw GitNotesEngineFailure.output};return value
    }
    func readNotes(revision:String,ref:String?,engine:GitNotesEngineKind,backend:GitLibGit2Configuration,cancellation:OperationCancellation?)throws->GitNotesValue {
        try cancellation?.check()
        if engine == .libgit2 {
            let reply=try notesReply(revision:revision,ref:ref,text:nil,backend:backend,cancellation:cancellation)
            guard Set(reply.keys)==["notesRef","text","blobOID","refOID"],let name=reply["notesRef"] as? String,!name.contains("\0"),name.utf8.count<=1_048_576,ref.map({GitReferenceName.equal($0,name)}) ?? true,let encoded=reply["text"] as? String,let bytes=Data(base64Encoded:encoded),bytes.base64EncodedString()==encoded,bytes.count<=16_777_216 else{throw GitNotesEngineFailure.output}
            let blob=try notesOID(reply["blobOID"]),refOID=try notesOID(reply["refOID"])
            guard (blob == nil || refOID != nil),(blob != nil || bytes.isEmpty) else{throw GitNotesEngineFailure.output}
            guard let value=String(data:bytes,encoding:.utf8),!value.contains("\0") else{throw CommitNoteFailure.invalidText}
            return .init(notesRef:name,text:value,blobOID:blob,refOID:refOID)
        }
        let name:String
        if let ref {name=ref}else{
            let configured=try run(["config","--null","--get","core.notesRef"],successfulExitCodes:0...1,cancellation:cancellation)
            if configured.exitCode==1{name="refs/notes/commits"}else{guard configured.stdout.last==0,let raw=String(data:configured.stdout.dropLast(),encoding:.utf8),!raw.contains("\0") else{throw GitNotesEngineFailure.output};name=raw}
        }
        guard !name.contains("\0") else{throw GitNotesEngineFailure.input}
        let state=try run(["-c","core.precomposeunicode=false","rev-parse","--verify","--quiet","--end-of-options",name],successfulExitCodes:0...1,cancellation:cancellation)
        let refOID=state.exitCode==0 ? String(decoding:state.stdout,as:UTF8.self).trimmingCharacters(in:.newlines):nil
        let note=try run(["-c","core.precomposeunicode=false","notes","list",revision],environmentOverrides:["GIT_NOTES_REF":name],successfulExitCodes:0...1,cancellation:cancellation)
        guard note.exitCode==0 else{return .init(notesRef:name,text:"",blobOID:nil,refOID:refOID)}
        let blob=String(decoding:note.stdout,as:UTF8.self).trimmingCharacters(in:.newlines)
        guard GitLocalReferenceProtocol.validOID(blob),refOID.map(GitLocalReferenceProtocol.validOID) ?? true else{throw GitNotesEngineFailure.output}
        let bytes=try run(["cat-file","blob",blob],cancellation:cancellation).stdout
        guard bytes.count<=16_777_216,let text=String(data:bytes,encoding:.utf8),!text.contains("\0") else{throw CommitNoteFailure.invalidText}
        return .init(notesRef:name,text:text,blobOID:blob,refOID:refOID)
    }
    func writeNotes(revision:String,ref:String,text:String,engine:GitNotesEngineKind,backend:GitLibGit2Configuration,cancellation:OperationCancellation?)throws {
        if engine == .libgit2 {
            let reply=try notesReply(revision:revision,ref:ref,text:text,backend:backend,cancellation:cancellation)
            guard Set(reply.keys)==["blobOID"],let oid=try notesOID(reply["blobOID"]),oid==Self.notesBlobOID(text,engine:engine) else{throw GitNotesEngineFailure.output}
            return
        }
        // Explicit SHA-256 extension: Git's environment selects the literal ref
        // without the --ref shorthand expansion. Both signatures use config only.
        func config(_ key:String)throws->String {
            let bytes=try run(["config","--null","--get",key],cancellation:cancellation).stdout
            guard bytes.last==0,let value=String(data:bytes.dropLast(),encoding:.utf8),!value.contains("\0") else{throw GitNotesEngineFailure.output};return value
        }
        let name=try config("user.name"),email=try config("user.email")
        let now=Date(),offset=TimeZone.current.secondsFromGMT(for:now),zone=String(format:"%@%02d%02d",offset<0 ? "-":"+",abs(offset)/3600,abs(offset)%3600/60)
        let date="\(Int(now.timeIntervalSince1970)) \(zone)"
        let environment=["GIT_NOTES_REF":ref,"GIT_AUTHOR_NAME":name,"GIT_AUTHOR_EMAIL":email,"GIT_AUTHOR_DATE":date,"GIT_COMMITTER_NAME":name,"GIT_COMMITTER_EMAIL":email,"GIT_COMMITTER_DATE":date]
        let directory=try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGitNote-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:directory)}
        let file=directory.appendingPathComponent("note.txt");try Data(text.utf8).write(to:file);try cancellation?.check()
        let blob=String(decoding:try run(["hash-object","-w","--",file.path],cancellation:cancellation).stdout,as:UTF8.self).trimmingCharacters(in:.newlines)
        guard blob==Self.notesBlobOID(text,engine:engine) else{throw GitNotesEngineFailure.output}
        _ = try run(["-c","core.precomposeunicode=false","notes","add","--force","--allow-empty","--reuse-message",blob,revision],environmentOverrides:environment,cancellation:cancellation)
    }
    static func notesBlobOID(_ text:String,engine:GitNotesEngineKind)->String {
        let body=Data(text.utf8),bytes=Data("blob \(body.count)\0".utf8)+body
        let digest=engine == .libgit2 ? Array(Insecure.SHA1.hash(data:bytes)):Array(SHA256.hash(data:bytes))
        return digest.map{String(format:"%02x",$0)}.joined()
    }
}
