// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CoreFoundation
import Darwin

public struct GitRepositoryDiagnosis: Sendable {
    public enum Reason: Int, Sendable { case accessible, ownershipDenied, notRepository, inaccessible }
    public let root: URL
    public let reason: Reason
    public let detail: String
    public let errorCode: Int32, errorClass: Int32
    public let gitFile: Bool
    public let acceptedBackend: GitLibGit2Configuration
    public var canTrust: Bool { reason != .accessible && reason != .notRepository && (reason == .ownershipDenied || gitFile) }
    fileprivate let environment: [String:String]
    fileprivate let witness: DiagnosisRootWitness
    fileprivate let requestedRoot: URL
    fileprivate let requestedWitness: DiagnosisFileWitness?
}

public struct GitSafeDirectoryTrustPlan: Sendable {
    public let root: URL, configurationFile: URL, configurationDirectory: URL
    public let value: String
    fileprivate let environment: [String:String]
    fileprivate let witness: DiagnosisRootWitness
    fileprivate let requestedRoot: URL
    fileprivate let requestedWitness: DiagnosisFileWitness?
    fileprivate let configurationWitness: DiagnosisFileWitness?
    fileprivate let executable: URL
}

public struct GitSafeDirectoryTrustReceipt: Sendable {
    public enum Outcome: Sendable { case added, alreadyRecordedAfterFailure }
    public let root: URL, configurationFile: URL
    public let value: String
    public let outcome: Outcome
}

public enum GitRepositoryDiagnosisFailure: LocalizedError {
    case input, output, notEligible, changed, configurationTarget, uncertain(String)
    public var errorDescription: String? {
        switch self {
        case .input:return "The repository path cannot be represented as an exact trusted directory."
        case .output:return "The repository diagnostic returned invalid or incomplete metadata."
        case .notEligible:return "This repository diagnostic does not offer a safe-directory exception."
        case .changed:return "The repository or configuration destination changed. Inspect it again before adding an exception."
        case .configurationTarget:return "The global Git configuration destination is unavailable."
        case .uncertain(let detail):return "Git configuration may already have changed. Inspect the safe-directory list before retrying.\n\n"+detail
        }
    }
}

fileprivate struct DiagnosisFileWitness: Sendable, Equatable {
    let device: UInt64, inode: UInt64, mode: UInt32
    static func read(_ url:URL) throws -> Self? {
        var value=stat()
        guard lstat(url.path,&value)==0 else {
            if errno==ENOENT {return nil}
            throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))
        }
        return .init(device:UInt64(value.st_dev),inode:UInt64(value.st_ino),mode:UInt32(value.st_mode))
    }
}
fileprivate struct DiagnosisRootWitness: Sendable, Equatable {
    let root: DiagnosisFileWitness?
    let marker: DiagnosisFileWitness?
    let markerTarget: DiagnosisFileWitness?
    let gitFileBytes: Data?
    static func read(_ url:URL) throws -> Self {
        let root=try DiagnosisFileWitness.read(url), markerURL=FileTransferPaths.fileURL((url.path=="/" ? "":url.path)+"/.git")
        let marker=try DiagnosisFileWitness.read(markerURL)
        let markerTarget=try DiagnosisFileWitness.read(diagnosisCanonicalURL(markerURL))
        var bytes:Data?
        if let markerTarget, markerTarget.mode & UInt32(S_IFMT)==UInt32(S_IFREG) {
            let handle=try FileHandle(forReadingFrom:markerURL);defer{try? handle.close()}
            bytes=try handle.read(upToCount:1_048_577) ?? Data()
            guard bytes!.count<=1_048_576 else{throw GitRepositoryDiagnosisFailure.input}
        }
        return .init(root:root,marker:marker,markerTarget:markerTarget,gitFileBytes:bytes)
    }
}

// Resolve filesystem spelling through POSIX bytes, preserving Unicode argv.
// Missing destination leaves are appended lexically to a resolved ancestor.
fileprivate func diagnosisCanonicalURL(_ value:URL)throws->URL {
    let path=FileTransferPaths.lexicalPath(value.path)
    guard path.hasPrefix("/"),!path.utf8.contains(0) else{throw GitRepositoryDiagnosisFailure.input}
    if let pointer=realpath(path,nil) {
        defer{free(pointer)}
        guard let exact=String(validatingUTF8:pointer) else{throw GitRepositoryDiagnosisFailure.input}
        return FileTransferPaths.fileURL(exact)
    }
    guard errno==ENOENT else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
    guard path != "/",let slash=path.utf8.lastIndex(of:47) else{throw GitRepositoryDiagnosisFailure.input}
    let parent=String(decoding:path.utf8[..<slash],as:UTF8.self)
    let leaf=String(decoding:path.utf8[path.utf8.index(after:slash)...],as:UTF8.self)
    let resolved=try diagnosisCanonicalURL(FileTransferPaths.fileURL(parent.isEmpty ? "/":parent))
    return FileTransferPaths.fileURL((resolved.path=="/" ? "":resolved.path)+"/"+leaf)
}

fileprivate func diagnosisParentURL(_ value:URL)->URL {
    let bytes=value.path.utf8
    guard let slash=bytes.lastIndex(of:47),slash != bytes.startIndex else{return FileTransferPaths.fileURL("/")}
    return FileTransferPaths.fileURL(String(decoding:bytes[..<slash],as:UTF8.self))
}

extension GitRepository {
    /// This explicit diagnostic always uses libgit2, as InaccessibleCommand does,
    /// independently of the ordinary command backend/mask. Construction of this
    /// actor does not require a successful repository discovery/open.
    public func diagnoseRepositoryAccess(environmentOverrides:[String:String]=[:],cancellation:OperationCancellation?=nil,backend:GitLibGit2Configuration?=nil) throws -> GitRepositoryDiagnosis {
        try cancellation?.check()
        let path=try diagnosisCanonicalURL(root)
        guard path.isFileURL,path.path.hasPrefix("/"),!path.path.utf8.contains(0) else{throw GitRepositoryDiagnosisFailure.input}
        var environment=ProcessInfo.processInfo.environment.merging(environmentOverrides){_,new in new}
        if environment["HOME"] == nil {environment["HOME"]=FileManager.default.homeDirectoryForCurrentUser.path}
        guard environment.allSatisfy({!$0.key.isEmpty && !$0.key.utf8.contains(0) && !$0.key.contains("=") && !$0.value.utf8.contains(0)}) else{throw GitRepositoryDiagnosisFailure.input}
        // Relative environment paths are relative to the accepted invocation,
        // not the later neutral config writer's temporary directory.
        for key in ["HOME","XDG_CONFIG_HOME","GIT_CONFIG_GLOBAL","GIT_CONFIG_SYSTEM"] {
            if let value=environment[key],!value.isEmpty,!value.hasPrefix("/") {
                environment[key]=FileTransferPaths.lexicalPath(root.path+"/"+value)
            }
        }
        let witness=try DiagnosisRootWitness.read(path),requestedWitness=try DiagnosisFileWitness.read(root)
        let selected=backend ?? libgit2Configuration ?? .load(),helper=try selected.runtimeExecutor()
        var bytes=Data()
        _ = try diagnosisRun(["-C",path.path,"turtlegit-repository-diagnosis"],environment:environment,cancellation:cancellation,helper:helper,consume:{chunk in
            if case .stdout=chunk.stream {
                guard chunk.data.count<=3_000_000-bytes.count else{throw GitRepositoryDiagnosisFailure.output};bytes.append(chunk.data)
            }
        })
        let prefix=Data("TurtleGit RepositoryDiagnosis v1:".utf8)
        guard bytes.last==10,!bytes.dropLast().contains(10),bytes.starts(with:prefix),
              let data=Data(base64Encoded:bytes.dropLast().dropFirst(prefix.count)),data.base64EncodedData()==bytes.dropLast().dropFirst(prefix.count),
              let reply=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
              Set(reply.keys)==["reason","errorCode","errorClass","gitFile","detail","workdir","gitdir"] else{throw GitRepositoryDiagnosisFailure.output}
        func integer(_ key:String)throws->Int32 {
            guard let number=reply[key] as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),number.doubleValue==Double(number.int32Value) else{throw GitRepositoryDiagnosisFailure.output};return number.int32Value
        }
        let code=try integer("errorCode"),klass=try integer("errorClass")
        guard let reason=GitRepositoryDiagnosis.Reason(rawValue:Int(try integer("reason"))),
              let marker=reply["gitFile"] as? NSNumber,CFGetTypeID(marker)==CFBooleanGetTypeID(),
              let detail=reply["detail"] as? String,!detail.utf8.contains(0),
              (reason == .accessible ? code==0:code<0),klass>=0 else{throw GitRepositoryDiagnosisFailure.output}
        switch reason {
        case .accessible:
            guard klass==0,detail.isEmpty,reply["gitdir"] is String else{throw GitRepositoryDiagnosisFailure.output}
        case .ownershipDenied:
            guard code == -36,klass>0,!(reply["workdir"] is String),!(reply["gitdir"] is String) else{throw GitRepositoryDiagnosisFailure.output}
        case .notRepository:
            guard code == -3,!(reply["workdir"] is String),!(reply["gitdir"] is String) else{throw GitRepositoryDiagnosisFailure.output}
        case .inaccessible:
            guard code != -36,code != -3,!(reply["workdir"] is String),!(reply["gitdir"] is String) else{throw GitRepositoryDiagnosisFailure.output}
        }
        for key in ["workdir","gitdir"] {
            guard reply[key] is NSNull || (reply[key] as? String).map({$0.hasPrefix("/") && !$0.utf8.contains(0)}) == true else{throw GitRepositoryDiagnosisFailure.output}
        }
        guard try witness==DiagnosisRootWitness.read(path),try requestedWitness==DiagnosisFileWitness.read(root),try diagnosisCanonicalURL(root).path.utf8.elementsEqual(path.path.utf8) else{throw GitRepositoryDiagnosisFailure.changed}
        try cancellation?.check()
        return .init(root:path,reason:reason,detail:detail,errorCode:code,errorClass:klass,gitFile:marker.boolValue,acceptedBackend:selected,environment:environment,witness:witness,requestedRoot:root,requestedWitness:requestedWitness)
    }

    /// Candidate global files are computed without filesystem access. Native
    /// sandbox consumers authorize their parent directories before asking which
    /// destination actually exists or resolving any configured symlinks.
    public func safeDirectoryConfigurationCandidates(_ diagnosis:GitRepositoryDiagnosis)throws->[URL] {
        guard diagnosis.canTrust else{throw GitRepositoryDiagnosisFailure.notEligible}
        let value=diagnosis.root.path
        guard value.hasPrefix("/"),!value.utf8.contains(0),!value.hasSuffix("/*") else{throw GitRepositoryDiagnosisFailure.input}
        return try diagnosisGlobalCandidates(environment:diagnosis.environment)
    }

    /// After candidate-directory authorization, capture the authoritative global
    /// destination for the explicit confirmation. No exception is written here.
    public func prepareSafeDirectoryTrust(_ diagnosis:GitRepositoryDiagnosis,cancellation:OperationCancellation?=nil)throws->GitSafeDirectoryTrustPlan {
        try cancellation?.check()
        guard diagnosis.canTrust else{throw GitRepositoryDiagnosisFailure.notEligible}
        let value=diagnosis.root.path
        // '*' and a trailing '/*' have broad trust semantics in Git, even when
        // an actual directory happens to have that literal filename.
        guard (diagnosis.witness.root?.mode ?? 0) & UInt32(S_IFMT) == UInt32(S_IFDIR),
              value.hasPrefix("/"),!value.utf8.contains(0),!value.hasSuffix("/*"),value.utf8.count<=1_048_576 else{throw GitRepositoryDiagnosisFailure.input}
        guard try diagnosisCanonicalURL(root).path.utf8.elementsEqual(value.utf8),try diagnosis.requestedWitness==DiagnosisFileWitness.read(diagnosis.requestedRoot),try diagnosis.witness==DiagnosisRootWitness.read(diagnosis.root) else{throw GitRepositoryDiagnosisFailure.changed}
        let destination=try diagnosisGlobalTarget(environment:diagnosis.environment)
        return .init(root:diagnosis.root,configurationFile:destination,configurationDirectory:diagnosisParentURL(destination),value:value,environment:diagnosis.environment,witness:diagnosis.witness,requestedRoot:diagnosis.requestedRoot,requestedWitness:diagnosis.requestedWitness,configurationWitness:try DiagnosisFileWitness.read(destination),executable:executable)
    }

    public func addSafeDirectoryTrust(_ plan:GitSafeDirectoryTrustPlan,cancellation:OperationCancellation?=nil)async throws->GitSafeDirectoryTrustReceipt {
        try cancellation?.check()
        guard try diagnosisCanonicalURL(root).path.utf8.elementsEqual(plan.root.path.utf8),
              try plan.requestedWitness==DiagnosisFileWitness.read(plan.requestedRoot),
              try plan.witness==DiagnosisRootWitness.read(plan.root),
              try diagnosisGlobalTarget(environment:plan.environment).path.utf8.elementsEqual(plan.configurationFile.path.utf8),
              try DiagnosisFileWitness.read(plan.configurationFile)==plan.configurationWitness else{throw GitRepositoryDiagnosisFailure.changed}
        let neutral=try TurtleGitTemporaryStorage.root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:neutral,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        defer{try? FileManager.default.removeItem(at:neutral)}
        let command=GitRepository(root:neutral,executable:plan.executable,askpass:nil,diffDetection:diffDetection,libgit2Configuration:libgit2Configuration)
        let before=try await command.diagnosisValues(plan,cancellation:cancellation)
        try cancellation?.check()
        guard try plan.witness==DiagnosisRootWitness.read(plan.root),
              try plan.requestedWitness==DiagnosisFileWitness.read(plan.requestedRoot),
              try diagnosisGlobalTarget(environment:plan.environment).path.utf8.elementsEqual(plan.configurationFile.path.utf8),
              try DiagnosisFileWitness.read(plan.configurationFile)==plan.configurationWitness else{throw GitRepositoryDiagnosisFailure.changed}
        // The selected destination is a protected global file on future reads.
        // Pin that file rather than allowing --global to select a different file
        // after its directory grant or follow a newly replaced symlink.
        let arguments=GitSettingsCommand.config+["--file",plan.configurationFile.path,"--add","safe.directory",plan.value]
        do {
            _ = try await command.run(arguments,environmentOverrides:plan.environment,cancellation:cancellation)
            return .init(root:plan.root,configurationFile:plan.configurationFile,value:plan.value,outcome:.added)
        } catch {
            let original=error
            // Cancellation may arrive after Git committed the rename. Inspect
            // the exact file independently; never turn that completed append
            // into a claim that nothing was written, or blindly retry it.
            let recovery=OperationCancellation()
            let timer=DispatchWorkItem{recovery.cancel()};DispatchQueue.global().asyncAfter(deadline:.now()+2,execute:timer)
            defer{timer.cancel()}
            do {
                let after=try await command.diagnosisValues(plan,cancellation:recovery)
                if after==before+[Data(plan.value.utf8)] {
                    return .init(root:plan.root,configurationFile:plan.configurationFile,value:plan.value,outcome:.alreadyRecordedAfterFailure)
                }
                if after==before {throw original}
                throw GitRepositoryDiagnosisFailure.uncertain(original.localizedDescription)
            } catch let failure as GitRepositoryDiagnosisFailure {throw failure}
            catch {
                // Preserve a known unchanged failure; unreadable recovery or
                // concurrent changes cannot establish an unchanged outcome.
                if (try? await command.diagnosisValues(plan,cancellation:recovery))==before {throw original}
                throw GitRepositoryDiagnosisFailure.uncertain(original.localizedDescription)
            }
        }
    }

    private func diagnosisGlobalCandidates(environment:[String:String])throws->[URL] {
        func path(_ value:String)throws->URL {
            guard !value.isEmpty,!value.utf8.contains(0) else{throw GitRepositoryDiagnosisFailure.configurationTarget}
            return FileTransferPaths.fileURL(FileTransferPaths.lexicalPath(value.hasPrefix("/") ? value:root.path+"/"+value))
        }
        if let explicit=environment["GIT_CONFIG_GLOBAL"] {return [try path(explicit)]}
        guard let homeValue=environment["HOME"] else{throw GitRepositoryDiagnosisFailure.configurationTarget}
        let home=try path(homeValue)
        let global=FileTransferPaths.fileURL(home.path+"/.gitconfig")
        let xdgHome=try path(environment["XDG_CONFIG_HOME"].flatMap{$0.isEmpty ? nil:$0} ?? home.path+"/.config")
        return FileTransferPaths.uniqueURLs([global,FileTransferPaths.fileURL(xdgHome.path+"/git/config")])
    }
    private func diagnosisGlobalTarget(environment:[String:String])throws->URL {
        let candidates=try diagnosisGlobalCandidates(environment:environment)
        guard let first=candidates.first else{throw GitRepositoryDiagnosisFailure.configurationTarget}
        let target:URL
        if candidates.count==1 {target=first}
        else {target=FileManager.default.fileExists(atPath:first.path) || !FileManager.default.fileExists(atPath:candidates[1].path) ? first:candidates[1]}
        return try diagnosisCanonicalURL(target)
    }
    private func diagnosisValues(_ plan:GitSafeDirectoryTrustPlan,cancellation:OperationCancellation?)throws->[Data] {
        var bytes=Data()
        let result=try run(GitSettingsCommand.config+["--file",plan.configurationFile.path,"--null","--get-all","safe.directory"],environmentOverrides:plan.environment,successfulExitCodes:0...1,cancellation:cancellation,retainStandardOutput:false,consumeOutput:{chunk in
            if case .stdout=chunk.stream {
                guard chunk.data.count<=16_777_216-bytes.count else{throw GitRepositoryDiagnosisFailure.output}
                bytes.append(chunk.data)
            }
        })
        guard result.exitCode==0 else{guard bytes.isEmpty else{throw GitRepositoryDiagnosisFailure.output};return []}
        guard bytes.last==0 else{throw GitRepositoryDiagnosisFailure.output}
        return bytes.dropLast().split(separator:0,omittingEmptySubsequences:false).map{Data($0)}
    }
    // Calls remain synchronous within this actor; the explicit helper path does
    // not require a usable repository and receives the ordinary owned token.
    private func diagnosisRun(_ arguments:[String],environment:[String:String],cancellation:OperationCancellation?,helper:URL,consume:@escaping (GitOutputChunk)throws->Void)throws->GitResult {
        try run(arguments,environmentOverrides:environment,cancellation:cancellation,retainStandardOutput:false,consumeOutput:consume,executorOverride:helper)
    }
}
