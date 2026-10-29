import Foundation

public struct ReferenceCreationOptions: Sendable {
    public var isTag = false
    public var name = ""
    public var revision = "HEAD"
    public var message = ""
    public var force = false
    public var sign = false
    public var tracking = CheckoutTracking.automatic
    public var allowNameConflict = false
    public init() {}
}
/// An accepted dialog form, before resolving its chosen base revision.
public struct ReferenceCreationForm:Sendable {
    public let options:ReferenceCreationOptions
    public let writesBranchDescription:Bool
    public let acceptedBackend:GitLibGit2Configuration
    fileprivate let repositoryRoot:URL
}
/// Local/tag targets are resolved once; a remote branch base retains its
/// reference name so Git preserves native tracking rules.
public struct ReferenceCreationPlan:Sendable {
    public let options:ReferenceCreationOptions
    public let writesBranchDescription:Bool
    public let acceptedBackend:GitLibGit2Configuration
    public let resolvedHash:String
    public let arguments:[String]
    fileprivate let repositoryRoot:URL
}
/// Exit zero is an accepted mutation even if the originating UI subsequently
/// cancels. Verification observes current state; concurrent external writers
/// cannot be excluded, and a moved remote base need not equal the prepared OID.
public struct ReferenceCreationReceipt: Sendable {
    public let output:String,reference:String
    public let actualObjectID:String?,peeledObjectID:String?
    public let cancelledAfterCreation:Bool
    public let verificationError:String?
    public let verificationDiagnostics:String
    public var verified:Bool {actualObjectID != nil && peeledObjectID != nil && verificationError == nil}
    public init(output:String,reference:String,actualObjectID:String?=nil,peeledObjectID:String?=nil,cancelledAfterCreation:Bool=false,verificationError:String?=nil,verificationDiagnostics:String="") {
        self.output=output;self.reference=reference;self.actualObjectID=actualObjectID;self.peeledObjectID=peeledObjectID
        self.cancelledAfterCreation=cancelledAfterCreation;self.verificationError=verificationError;self.verificationDiagnostics=verificationDiagnostics
    }
}
/// Description is a separate post-creation operation. Its failure must not make
/// a caller retry the already accepted branch/tag mutation.
public struct ReferenceCreationPostCreationFailure:LocalizedError {
    public let receipt:ReferenceCreationReceipt
    public let underlying:Error
    public var errorDescription:String? {"The reference was created, but its description could not be saved: " + underlying.localizedDescription}
}

/// Deliberately local to creation APIs: other Git mutations retain their existing
/// cancellation semantics. Never turn a nonzero or pre-spawn failure into success.
func acceptedCreationResult(_ operation:()throws->GitResult)throws->GitResult {
    do {return try operation()}
    catch let failure as GitCommandCancellationFailure where failure.result.exitCode == 0 {return failure.result}
}

/// Verification owns a fresh cancellation scope, independent of a cancelled UI,
/// and cannot wait indefinitely for a wrapper/config/metadata read to finish.
func boundedCreationVerification<Value>(_ body:(OperationCancellation)throws->Value)throws->Value {
    let token=OperationCancellation()
    let deadline=DispatchWorkItem {token.cancel()}
    DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+5,execute:deadline)
    defer {deadline.cancel()}
    return try body(token)
}
public enum ReferenceCreationFailure: LocalizedError {
    case invalidName, invalidRevision, exists, nameConflict, signingMessageRequired, preparedRepositoryMismatch
    public var errorDescription: String? {
        switch self {
        case .invalidName: return "Enter a valid branch or tag name."
        case .invalidRevision: return "Choose an existing revision."
        case .exists: return "This reference already exists. Choose another name or enable Force."
        case .nameConflict: return "A branch and tag will share this name. Short revision names will be ambiguous. Continue?"
        case .signingMessageRequired: return "A signed tag requires a message."
        case .preparedRepositoryMismatch: return "This reference was prepared for another repository."
        }
    }
}
extension GitRepository {
    /// Reference names, base revisions and messages are data, not filesystem
    /// spellings. Git on macOS otherwise precomposes all command-line arguments.
    private func creationCommand(_ arguments: [String], successfulExitCodes: ClosedRange<Int32> = 0...0, cancellation: OperationCancellation? = nil) throws -> GitResult {
        do { return try run(["-c", "core.precomposeunicode=false"] + arguments, successfulExitCodes: successfulExitCodes, cancellation: cancellation) }
        catch let failure as GitFailure { throw GitFailure(arguments: arguments, code: failure.code, message: failure.message) }
    }
    public func createReference(_ options: ReferenceCreationOptions, writeDescription: Bool = true, cancellation: OperationCancellation? = nil) throws -> String {
        try createReference(prepareReferenceCreation(options,cancellation:cancellation),writeDescription:writeDescription,cancellation:cancellation)
    }
    /// Performs validation without changing references, HEAD, the index or config.
    public func prepareReferenceCreation(_ options:ReferenceCreationOptions,cancellation:OperationCancellation?=nil) throws -> ReferenceCreationPlan {
        try prepareReferenceCreation(prepareReferenceCreationForm(options,cancellation:cancellation),cancellation:cancellation)
    }
    /// Source OnOK accepts these controls before persisting Switch/Push. Resolving
    /// the base revision and the actual Git creation command happen afterward.
    public func prepareReferenceCreationForm(_ options:ReferenceCreationOptions,cancellation:OperationCancellation?=nil) throws -> ReferenceCreationForm {
        try cancellation?.check()
        let backend=libgit2Configuration ?? .load()
        func exists(_ ref:String)throws->Bool {try referenceExists(ref,cancellation:cancellation,backend:backend)}
        // The source dialog reports a missing signed-tag message before name errors.
        let message = options.message.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if options.isTag,options.sign,message.isEmpty {throw ReferenceCreationFailure.signingMessageRequired}
        let name = options.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = options.isTag ? "refs/tags/" : "refs/heads/"
        do {
            _ = try creationCommand(["check-ref-format", prefix + name], cancellation: cancellation)
            // Git's branch-name rules also reject leading dashes and checkout shorthand.
            _ = try creationCommand(["check-ref-format", "--branch", name], cancellation: cancellation)
        } catch { try cancellation?.check(); throw ReferenceCreationFailure.invalidName }
        if !options.force, try exists(prefix + name) { throw ReferenceCreationFailure.exists }
        let other = options.isTag ? "refs/heads/" : "refs/tags/"
        if !options.allowNameConflict, try exists(other + name) { throw ReferenceCreationFailure.nameConflict }
        var normalized=options;normalized.name=name;normalized.message=message
        return ReferenceCreationForm(options:normalized,writesBranchDescription:!options.isTag && !options.message.isEmpty,acceptedBackend:backend,repositoryRoot:root)
    }
    public func prepareReferenceCreation(_ form:ReferenceCreationForm,cancellation:OperationCancellation?=nil) throws -> ReferenceCreationPlan {
        try cancellation?.check()
        guard root.path.utf8.elementsEqual(form.repositoryRoot.path.utf8) else {throw ReferenceCreationFailure.preparedRepositoryMismatch}
        let options=form.options,name=options.name,message=options.message
        guard let hash=try revisionLookup(options.revision,requirement:options.isTag ? .existingObject : .commit,cancellation:cancellation,backend:form.acceptedBackend).objectID else{throw ReferenceCreationFailure.invalidRevision}
        var args = [options.isTag ? "tag" : "branch"]
        if options.force { args.append("--force") }
        if options.isTag {
            // Override tag.gpgSign for the unchecked Sign option, matching the dialog.
            args = ["-c", "tag.gpgSign=false"] + args
            args.append(options.sign ? "--sign" : "--no-sign")
            if !message.isEmpty { args += ["--annotate", "--message", message] }
            args += ["--", name, hash]
        } else {
            let remote = try options.revision.hasPrefix("refs/remotes/") && referenceExists(options.revision,cancellation:cancellation,backend:form.acceptedBackend)
            if remote {
                if options.tracking == .track { args.append("--track") }
                if options.tracking == .noTrack { args.append("--no-track") }
            } else { args.append("--no-track") }
            args += ["--", name, remote ? options.revision : hash]
        }
        return ReferenceCreationPlan(options:options,writesBranchDescription:form.writesBranchDescription,acceptedBackend:form.acceptedBackend,resolvedHash:hash,arguments:args,repositoryRoot:root)
    }
    /// Uses the accepted submission without re-reading mutable native form state.
    /// As in Git/source, a captured remote base may move before branch creation.
    public func createReference(_ plan:ReferenceCreationPlan,writeDescription:Bool=true,cancellation:OperationCancellation?=nil) throws -> String {
        let receipt=try createReferenceAccepted(plan,cancellation:cancellation)
        if writeDescription,plan.writesBranchDescription {
            do {try updateBranchDescription(plan.options.name,message:plan.options.message,cancellation:cancellation)}
            catch {throw ReferenceCreationPostCreationFailure(receipt:receipt,underlying:error)}
        }
        return receipt.output
    }
    /// Creation and bounded verification only; branch description remains a
    /// separate native phase after optional Switch, matching source ordering.
    public func createReferenceAccepted(_ plan:ReferenceCreationPlan,cancellation:OperationCancellation?=nil) throws -> ReferenceCreationReceipt {
        try cancellation?.check()
        guard root.path.utf8.elementsEqual(plan.repositoryRoot.path.utf8) else {throw ReferenceCreationFailure.preparedRepositoryMismatch}
        let result=try acceptedCreationResult {try creationCommand(plan.arguments,cancellation:cancellation)}
        let reference=(plan.options.isTag ? "refs/tags/":"refs/heads/")+plan.options.name
        var actual:String?,peeled:String?,issue:String?,diagnostics=""
        do {
            (actual,peeled)=try boundedCreationVerification {token in
                let direct=try creationCommand(["show-ref","--verify","--hash",reference],cancellation:token)
                diagnostics=String(decoding:direct.stderr,as:UTF8.self)
                let dereferenced=try creationCommand(["rev-parse","--verify","--end-of-options",reference+"^{}"],cancellation:token)
                diagnostics+=String(decoding:dereferenced.stderr,as:UTF8.self)
                // Successful Git warnings belong to stderr, never an OID.
                let actual=String(decoding:direct.stdout,as:UTF8.self).trimmingCharacters(in:.newlines)
                let peeled=String(decoding:dereferenced.stdout,as:UTF8.self).trimmingCharacters(in:.newlines)
                func valid(_ value:String)->Bool {[40,64].contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }}
                guard valid(actual),valid(peeled) else {throw ReferenceCreationFailure.invalidRevision}
                return (actual,peeled)
            }
        }catch {issue="Creation completed, but the current reference could not be verified: "+error.localizedDescription}
        return .init(output:result.text,reference:reference,actualObjectID:actual,peeledObjectID:peeled,cancelledAfterCreation:cancellation?.isCancelled == true,verificationError:issue,verificationDiagnostics:diagnostics)
    }
    /// Source CreateBranchTag writes the description after PerformSwitch returns,
    /// even when checkout failed. Keep this phase separable for native ownership.
    public func updateBranchDescription(_ name: String, message: String, cancellation: OperationCancellation? = nil, expectedHash: String? = nil) throws {
        try cancellation?.check()
        do { _ = try creationCommand(["check-ref-format", "refs/heads/" + name], cancellation: cancellation) }
        catch OperationCancellationFailure.cancelled { throw OperationCancellationFailure.cancelled }
        catch { throw ReferenceCreationFailure.invalidName }
        try validateBrowserReference(GitReferenceName("refs/heads/" + name), expectedHash: expectedHash, cancellation: cancellation)
        let value = message.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "branch." + name + ".description"
        if value.isEmpty {
            do { _ = try creationCommand(["config", "--local", "--unset-all", key], cancellation: cancellation) }
            catch let failure as GitFailure where failure.code == 5 { /* Already absent. */ }
        } else { _ = try creationCommand(["config", "--local", key, value], cancellation: cancellation) }
    }
}
