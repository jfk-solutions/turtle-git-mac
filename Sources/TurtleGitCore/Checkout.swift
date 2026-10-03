import Foundation

public enum CheckoutTarget: String, CaseIterable, Identifiable, Sendable {
    case branch, tag, commit
    public var id: String { rawValue }
}
public enum CheckoutTracking: String, CaseIterable, Sendable { case automatic, track, noTrack }
public struct CheckoutReference: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let symbolicTarget: String?
    public var remote: Bool { name.hasPrefix("refs/remotes/") }
    public var label: String {
        for prefix in ["refs/heads/", "refs/tags/"] { if name.hasPrefix(prefix) { return String(name.dropFirst(prefix.count)) } }
        if remote { return "remotes/" + name.dropFirst("refs/remotes/".count) }
        return name
    }
    public var suggestedBranch: String {
        if remote { return String(name.dropFirst("refs/remotes/".count).split(separator: "/", maxSplits: 1).last ?? "") }
        return "Branch_" + label
    }
}
public struct CheckoutOptions: Sendable {
    public var target = CheckoutTarget.branch
    public var revision = ""
    public var createBranch = false
    public var branchName = ""
    public var overwriteChanges = false
    public var merge = false
    public var tracking = CheckoutTracking.automatic
    public var overrideBranch = false
    public var allowTagNameConflict = false
    public init() {}
}
public enum CheckoutFailure: LocalizedError {
    case invalidRevision, invalidBranch, branchExists, tagNameConflict
    public var errorDescription: String? {
        switch self {
        case .invalidRevision: return "Choose a branch, tag or commit that exists in this repository."
        case .invalidBranch: return "Enter a valid new branch name."
        case .branchExists: return "This branch already exists. Choose another name or enable Override branch if exists."
        case .tagNameConflict: return "A tag has the same name as the new branch. Short revision names will be ambiguous. Continue?"
        }
    }
}

extension GitRepository {
    public func checkoutReferences() throws -> [CheckoutReference] {
        let bytes = try run(["for-each-ref", "--sort=refname", "--format=%(refname)%00%(symref)%00", "refs/heads", "refs/remotes", "refs/tags"]).stdout
        let fields = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\0")
        var result: [CheckoutReference] = []
        var i = 0
        while i + 1 < fields.count {
            let name = fields[i].hasPrefix("\n") ? String(fields[i].dropFirst()) : fields[i]
            if !name.isEmpty { result.append(CheckoutReference(name: name, symbolicTarget: fields[i+1].isEmpty ? nil : fields[i+1])) }
            i += 2
        }
        return result
    }
    public func checkout(_ options: CheckoutOptions) throws -> String {
        let revision = options.revision
        guard !revision.isEmpty else { throw CheckoutFailure.invalidRevision }
        let references = try checkoutReferences()
        let reference = references.first { $0.name == revision }
        if options.target == .branch {
            guard let reference, reference.name.hasPrefix("refs/heads/") || reference.remote else { throw CheckoutFailure.invalidRevision }
        } else if options.target == .tag {
            guard reference?.name.hasPrefix("refs/tags/") == true else { throw CheckoutFailure.invalidRevision }
        }
        let resolved: String
        do { resolved = try run(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"]).text.trimmingCharacters(in: .newlines) }
        catch { throw CheckoutFailure.invalidRevision }
        var args = ["switch", "--no-guess"]
        if options.overwriteChanges { args.append("--discard-changes") }
        if options.merge { args.append("--merge") }
        if options.createBranch {
            let name = options.branchName.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                _ = try run(["check-ref-format", "refs/heads/" + name])
                _ = try run(["check-ref-format", "--branch", name])
            } catch { throw CheckoutFailure.invalidBranch }
            if !options.overrideBranch, (try? run(["show-ref", "--verify", "--quiet", "refs/heads/" + name])) != nil { throw CheckoutFailure.branchExists }
            if !options.allowTagNameConflict, (try? run(["show-ref", "--verify", "--quiet", "refs/tags/" + name])) != nil { throw CheckoutFailure.tagNameConflict }
            args += [options.overrideBranch ? "-C" : "-c", name]
            if reference?.remote == true {
                switch options.tracking {
                case .automatic: break
                case .track: args.append("--track")
                case .noTrack: args.append("--no-track")
                }
                args += ["--", revision]
            } else { args += ["--no-track", "--", resolved] }
        } else if options.target == .branch, let reference, !reference.remote {
            args += ["--", reference.label]
        } else { args += ["--detach", "--", resolved] }
        return try run(args).text
    }
}
