// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public struct SubmoduleAddOptions: Sendable {
    public var source = ""
    public var path = ""
    public var branch: String?
    public var force = false
    public var sshKey: URL?
    public init() {}
    /// SubmoduleAddDlg uses GetFileNameFromPath: only slash/backslash separate
    /// components; preserve case, whitespace, trailing emptiness and scp colons.
    public static func moduleName(from source:String)->String {
        var name=source.replacingOccurrences(of:"\\",with:"/").components(separatedBy:"/").last ?? ""
        if name.hasSuffix(".git") {name.removeLast(4)}
        return name
    }
    public func relativePath(root: URL) throws -> String {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let relative: String
        if let suffix = GitReferenceName.removingPrefix(root.path + "/", from: value) { relative = suffix }
        else { relative = value }
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\0"),
              !relative.components(separatedBy: "/").contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.caseInsensitiveCompare(".git") == .orderedSame }) else { throw SubmoduleAddFailure.path }
        return relative
    }
    public func arguments(root: URL) throws -> [String] {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !source.contains("\0") else { throw SubmoduleAddFailure.source }
        if let branch { guard !branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !branch.contains("\0") else { throw SubmoduleAddFailure.branch } }
        if let key = sshKey { guard key.isFileURL, key.path.hasPrefix("/"), !key.path.contains("\0") else { throw SubmoduleAddFailure.key } }
        var args = ["submodule", "add"]
        // Pinned SubmoduleCommand replaces its branch arguments when Force is set.
        if force { args.append("--force") }
        else if let branch { args += ["-b", branch.trimmingCharacters(in: .whitespacesAndNewlines)] }
        return args + ["--", source, try relativePath(root: root)]
    }
}

public enum SubmoduleAddFailure: LocalizedError {
    case source, path, branch, key
    public var errorDescription: String? {
        switch self {
        case .source: return "Enter a repository URL or local repository path."
        case .path: return "Choose a submodule path inside this working tree."
        case .branch: return "Enter a branch name."
        case .key: return "Choose an OpenSSH private key."
        }
    }
}

public enum SubmoduleAddPhase: String, Sendable { case preparing, adding, configuringKey, completed }
public struct SubmoduleAddReceipt: Sendable {
    public let superproject: URL
    public let path: String
    public let gitDirectory: URL
    public let key: URL
    let directoryDevice: UInt64
    let directoryInode: UInt64
}
public struct SubmoduleAddOutcome: Sendable {
    public let phase: SubmoduleAddPhase
    public let attempted: Bool
    public let added: Bool
    public let configured: Bool
    public let cancelled: Bool
    public let output: String
    public let receipt: SubmoduleAddReceipt?
    public let verified:Bool
    public let verificationError:String?
    public var success: Bool { phase == .completed && !cancelled }
    public init(phase: SubmoduleAddPhase = .preparing, attempted: Bool = false, added: Bool = false, configured: Bool = false, cancelled: Bool = false, output: String = "", receipt: SubmoduleAddReceipt? = nil, verified:Bool?=nil,verificationError:String?=nil) {
        self.phase=phase;self.attempted=attempted;self.added=added;self.configured=configured;self.cancelled=cancelled;self.output=output;self.receipt=receipt;self.verified=verified ?? added;self.verificationError=verificationError
    }
}
public struct SubmoduleAddExecutionFailure: LocalizedError {
    public let outcome: SubmoduleAddOutcome
    public let underlying: Error
    public var errorDescription: String? {
        (outcome.added ? "The submodule was added, but its SSH key configuration did not complete.\n" : "") + underlying.localizedDescription
    }
}
public enum SubmoduleAddRecoveryFailure: LocalizedError {
    case replaced
    public var errorDescription: String? { "The added submodule checkout changed. Refresh and review it before configuring its SSH key." }
}
extension GitRepository {
    public func addSubmodule(_ options: SubmoduleAddOptions, cancellation: OperationCancellation? = nil, prepareTransport: SSHTransportPreparation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) async throws -> String {
        do {return try await addSubmoduleWithOutcome(options,cancellation:cancellation,prepareTransport:prepareTransport,onOutput:onOutput).output}
        catch let failure as SubmoduleAddExecutionFailure {throw failure.underlying}
    }
    public func addSubmoduleWithOutcome(_ options: SubmoduleAddOptions, cancellation: OperationCancellation? = nil, prepareTransport: SSHTransportPreparation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) async throws -> SubmoduleAddOutcome {
        let token=cancellation ?? OperationCancellation();try token.check()
        let args=try options.arguments(root:root),path=try options.relativePath(root:root)
        guard try !isBare(cancellation:token) else {throw SubmoduleAddFailure.path}
        let location=try restoreLocation(path)
        if let type=try? FileManager.default.attributesOfItem(atPath:location.path)[.type] as? FileAttributeType,type != .typeDirectory {throw SubmoduleAddFailure.path}
        let session=try await prepareSSHTransport([],cancellation:token,preparation:prepareTransport)
        defer {withExtendedLifetime(session) {}}
        if options.sshKey != nil && session == nil {throw CloneFailure.keyRuntime}
        _ = try restoreLocation(path)
        if let type=try? FileManager.default.attributesOfItem(atPath:location.path)[.type] as? FileAttributeType,type != .typeDirectory {throw SubmoduleAddFailure.path}
        let result:GitResult
        do {
            result=try acceptedCreationResult {try run(["-c","core.precomposeunicode=false"]+args,environmentOverrides:session?.transportEnvironment ?? [:],literalPathspecs:false,cancellation:token,onOutput:onOutput)}
        }catch {
            throw SubmoduleAddExecutionFailure(outcome:.init(phase:.adding,attempted:true,cancelled:token.isCancelled,output:submoduleAddFailureOutput(error)),underlying:error)
        }
        // Retain the actual exit-zero Add before inspecting or configuring it.
        // A failed inspection is recovery-only; it never licenses another Add.
        let inspected:SubmoduleAddOutcome
        do {inspected=try inspectSubmoduleAdd(options,output:result.text)}
        catch {
            return .init(phase:.adding,attempted:true,added:true,cancelled:token.isCancelled,output:result.text,verified:false,
                         verificationError:"The submodule was added, but its checkout could not be verified: "+error.localizedDescription)
        }
        guard let receipt=inspected.receipt else {
            return .init(phase:.completed,attempted:true,added:true,configured:true,cancelled:token.isCancelled,output:result.text,verified:true)
        }
        if token.isCancelled {
            return .init(phase:.configuringKey,attempted:true,added:true,cancelled:true,output:result.text,receipt:receipt,verified:true)
        }
        do {
            let configured=try retrySubmoduleAddKeyConfiguration(receipt,cancellation:token,onOutput:onOutput)
            return .init(phase:.completed,attempted:true,added:true,configured:true,cancelled:token.isCancelled,output:result.text+configured.output,receipt:receipt,verified:true)
        }catch {
            let diagnostic=submoduleAddFailureOutput(error)
            throw SubmoduleAddExecutionFailure(outcome:.init(phase:.configuringKey,attempted:true,added:true,cancelled:token.isCancelled,
                output:result.text+(result.text.isEmpty || result.text.hasSuffix("\n") ? "":"\n")+diagnostic,receipt:receipt,verified:true),underlying:(error as? SubmoduleAddExecutionFailure)?.underlying ?? error)
        }
    }
    /// Read-only recovery after an accepted Add. The private checkout identity
    /// is captured before a later explicit key-only retry; Add is never repeated.
    public func inspectSubmoduleAdd(_ options:SubmoduleAddOptions,output:String="",cancellation:OperationCancellation?=nil)throws->SubmoduleAddOutcome {
        try cancellation?.check()
        let path=try options.relativePath(root:root)
        let identity=try boundedCreationVerification {try addedSubmoduleIdentity(path:path,cancellation:$0)}
        let receipt=options.sshKey.map {SubmoduleAddReceipt(superproject:root,path:path,gitDirectory:identity.0,key:$0,directoryDevice:identity.1,directoryInode:identity.2)}
        return .init(phase:receipt == nil ? .completed:.configuringKey,attempted:true,added:true,configured:receipt == nil,cancelled:cancellation?.isCancelled == true,output:output,receipt:receipt,verified:true)
    }
    private func submoduleAddFailureOutput(_ error:Error)->String {
        if let failure=error as? SubmoduleAddExecutionFailure,!failure.outcome.output.isEmpty {return failure.outcome.output}
        let underlying=(error as? SubmoduleAddExecutionFailure)?.underlying ?? error
        if let failure=underlying as? GitCommandCancellationFailure {return failure.result.text + "\n" + failure.localizedDescription}
        if let failure=underlying as? GitFailure {return failure.message}
        return underlying.localizedDescription
    }
    private func addedSubmoduleIdentity(path:String,cancellation:OperationCancellation?) throws -> (URL,UInt64,UInt64) {
        try cancellation?.check()
        let location=try restoreLocation(path)
        guard try submoduleUpdatePaths(cancellation:cancellation).contains(where:{GitReferenceName.equal($0,path)}),
              let type=try? FileManager.default.attributesOfItem(atPath:location.path)[.type] as? FileAttributeType,type == .typeDirectory,
              FileManager.default.fileExists(atPath:location.appendingPathComponent(".git").path) else {throw SubmoduleAddRecoveryFailure.replaced}
        var bytes=try run(["-C",location.path,"rev-parse","--absolute-git-dir"],cancellation:cancellation).stdout
        if bytes.last == 10 {bytes.removeLast()}
        guard !bytes.isEmpty else {throw SubmoduleAddRecoveryFailure.replaced}
        let directory=URL(fileURLWithPath:String(decoding:bytes,as:UTF8.self)).standardizedFileURL.resolvingSymlinksInPath()
        let attributes=try FileManager.default.attributesOfItem(atPath:directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let device=attributes[.systemNumber] as? NSNumber,let inode=attributes[.systemFileNumber] as? NSNumber else{throw SubmoduleAddRecoveryFailure.replaced}
        return (directory,device.uint64Value,inode.uint64Value)
    }
    /// Retry only the local post-add setting. No transport or key-agent load is
    /// needed; the original captured repository and checkout identity must match.
    public func retrySubmoduleAddKeyConfiguration(_ receipt:SubmoduleAddReceipt,cancellation:OperationCancellation? = nil,onOutput:(@Sendable (GitOutputChunk)->Void)? = nil) throws -> SubmoduleAddOutcome {
        try cancellation?.check()
        guard receipt.superproject == root else{throw SubmoduleAddRecoveryFailure.replaced}
        let identity=try addedSubmoduleIdentity(path:receipt.path,cancellation:cancellation)
        guard identity.0 == receipt.gitDirectory,identity.1 == receipt.directoryDevice,identity.2 == receipt.directoryInode else{throw SubmoduleAddRecoveryFailure.replaced}
        let location=try restoreLocation(receipt.path)
        do {
            let output=try acceptedCreationResult {try run(["-C",location.path,"-c","core.precomposeunicode=false","config","--local","remote.origin.turtlegitsshkeyfile",receipt.key.path],cancellation:cancellation,onOutput:onOutput)}.text
            return SubmoduleAddOutcome(phase:.completed,attempted:true,added:true,configured:true,output:output,receipt:receipt)
        } catch {
            throw SubmoduleAddExecutionFailure(outcome:SubmoduleAddOutcome(phase:.configuringKey,attempted:true,added:true,cancelled:cancellation?.isCancelled == true,output:submoduleAddFailureOutput(error),receipt:receipt),underlying:error)
        }
    }
}
