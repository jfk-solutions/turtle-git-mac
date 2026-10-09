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
public enum ReferenceCreationFailure: LocalizedError {
    case invalidName, invalidRevision, exists, nameConflict, signingMessageRequired
    public var errorDescription: String? {
        switch self {
        case .invalidName: return "Enter a valid branch or tag name."
        case .invalidRevision: return "Choose an existing revision."
        case .exists: return "This reference already exists. Choose another name or enable Force."
        case .nameConflict: return "A branch and tag will share this name. Short revision names will be ambiguous. Continue?"
        case .signingMessageRequired: return "A signed tag requires a message."
        }
    }
}
extension GitRepository {
    public func createReference(_ options: ReferenceCreationOptions, writeDescription: Bool = true, cancellation: OperationCancellation? = nil) throws -> String {
        try cancellation?.check()
        func exists(_ ref: String) throws -> Bool {
            do { _ = try run(["show-ref", "--verify", "--quiet", ref], cancellation: cancellation); return true }
            catch { try cancellation?.check(); return false }
        }
        let name = options.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = options.isTag ? "refs/tags/" : "refs/heads/"
        do {
            _ = try run(["check-ref-format", prefix + name], cancellation: cancellation)
            // Git's branch-name rules also reject leading dashes and checkout shorthand.
            _ = try run(["check-ref-format", "--branch", name], cancellation: cancellation)
        } catch { try cancellation?.check(); throw ReferenceCreationFailure.invalidName }
        if !options.force, try exists(prefix + name) { throw ReferenceCreationFailure.exists }
        let other = options.isTag ? "refs/heads/" : "refs/tags/"
        if !options.allowNameConflict, try exists(other + name) { throw ReferenceCreationFailure.nameConflict }
        let hash: String
        do { hash = try run(["rev-parse", "--verify", "--end-of-options", options.revision + "^{commit}"], cancellation: cancellation).text.trimmingCharacters(in: .newlines) }
        catch { try cancellation?.check(); throw ReferenceCreationFailure.invalidRevision }
        let message = options.message.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        var args = [options.isTag ? "tag" : "branch"]
        if options.force { args.append("--force") }
        if options.isTag {
            if options.sign && message.isEmpty { throw ReferenceCreationFailure.signingMessageRequired }
            // Override tag.gpgSign for the unchecked Sign option, matching the dialog.
            args = ["-c", "tag.gpgSign=false"] + args
            args.append(options.sign ? "--sign" : "--no-sign")
            if !message.isEmpty { args += ["--annotate", "--message", message] }
            args += ["--", name, hash]
        } else {
            let remote = try options.revision.hasPrefix("refs/remotes/") && exists(options.revision)
            if remote {
                if options.tracking == .track { args.append("--track") }
                if options.tracking == .noTrack { args.append("--no-track") }
            } else { args.append("--no-track") }
            args += ["--", name, remote ? options.revision : hash]
        }
        let output = try run(args, cancellation: cancellation).text
        if writeDescription, !options.isTag, !message.isEmpty { _ = try run(["config", "--local", "branch." + name + ".description", message], cancellation: cancellation) }
        return output
    }
    /// Source CreateBranchTag writes the description after PerformSwitch returns,
    /// even when checkout failed. Keep this phase separable for native ownership.
    public func updateBranchDescription(_ name: String, message: String, cancellation: OperationCancellation? = nil) throws {
        try cancellation?.check()
        do { _ = try run(["check-ref-format", "refs/heads/" + name], cancellation: cancellation) }
        catch OperationCancellationFailure.cancelled { throw OperationCancellationFailure.cancelled }
        catch { throw ReferenceCreationFailure.invalidName }
        let value = message.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let key = "branch." + name + ".description"
        if value.isEmpty {
            do { _ = try run(["-c", "core.precomposeunicode=false", "config", "--local", "--unset-all", key], cancellation: cancellation) }
            catch let failure as GitFailure where failure.code == 5 { /* Already absent. */ }
        } else { _ = try run(["-c", "core.precomposeunicode=false", "config", "--local", key, value], cancellation: cancellation) }
    }
}
