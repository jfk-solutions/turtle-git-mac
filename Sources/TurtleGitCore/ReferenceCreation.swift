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
    fileprivate let repositoryRoot:URL
}
/// Local/tag targets are resolved once; a remote branch base retains its
/// reference name so Git preserves native tracking rules.
public struct ReferenceCreationPlan:Sendable {
    public let options:ReferenceCreationOptions
    public let writesBranchDescription:Bool
    public let resolvedHash:String
    public let arguments:[String]
    fileprivate let repositoryRoot:URL
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
        func exists(_ ref: String) throws -> Bool {
            try creationCommand(["show-ref", "--verify", "--quiet", ref], successfulExitCodes: 0...1, cancellation: cancellation).exitCode == 0
        }
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
        return ReferenceCreationForm(options:normalized,writesBranchDescription:!options.isTag && !options.message.isEmpty,repositoryRoot:root)
    }
    public func prepareReferenceCreation(_ form:ReferenceCreationForm,cancellation:OperationCancellation?=nil) throws -> ReferenceCreationPlan {
        try cancellation?.check()
        guard root.path.utf8.elementsEqual(form.repositoryRoot.path.utf8) else {throw ReferenceCreationFailure.preparedRepositoryMismatch}
        let options=form.options,name=options.name,message=options.message
        let hash: String
        do {
            let output = try creationCommand(["rev-parse", "--verify", "--end-of-options", options.revision + "^{commit}"], cancellation: cancellation).stdout
            hash = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .newlines)
            guard [40, 64].contains(hash.count), hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw ReferenceCreationFailure.invalidRevision }
        }
        catch { try cancellation?.check(); throw ReferenceCreationFailure.invalidRevision }
        var args = [options.isTag ? "tag" : "branch"]
        if options.force { args.append("--force") }
        if options.isTag {
            // Override tag.gpgSign for the unchecked Sign option, matching the dialog.
            args = ["-c", "tag.gpgSign=false"] + args
            args.append(options.sign ? "--sign" : "--no-sign")
            if !message.isEmpty { args += ["--annotate", "--message", message] }
            args += ["--", name, hash]
        } else {
            let remote = try options.revision.hasPrefix("refs/remotes/") && creationCommand(["show-ref","--verify","--quiet",options.revision],successfulExitCodes:0...1,cancellation:cancellation).exitCode == 0
            if remote {
                if options.tracking == .track { args.append("--track") }
                if options.tracking == .noTrack { args.append("--no-track") }
            } else { args.append("--no-track") }
            args += ["--", name, remote ? options.revision : hash]
        }
        return ReferenceCreationPlan(options:options,writesBranchDescription:form.writesBranchDescription,resolvedHash:hash,arguments:args,repositoryRoot:root)
    }
    /// Uses the accepted submission without re-reading mutable native form state.
    /// As in Git/source, a captured remote base may move before branch creation.
    public func createReference(_ plan:ReferenceCreationPlan,writeDescription:Bool=true,cancellation:OperationCancellation?=nil) throws -> String {
        try cancellation?.check()
        guard root.path.utf8.elementsEqual(plan.repositoryRoot.path.utf8) else {throw ReferenceCreationFailure.preparedRepositoryMismatch}
        let options=plan.options
        let output = try creationCommand(plan.arguments, cancellation: cancellation).text
        if writeDescription,plan.writesBranchDescription {try updateBranchDescription(options.name,message:options.message,cancellation:cancellation)}
        return output
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
