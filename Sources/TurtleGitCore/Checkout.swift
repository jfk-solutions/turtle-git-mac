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
    public init(name: String, symbolicTarget: String? = nil) { self.name = name; self.symbolicTarget = symbolicTarget }
    public var isFetchHead: Bool { GitReferenceName.equal(name, "FETCH_HEAD") }
    public var remote: Bool { GitReferenceName.removingPrefix("refs/remotes/", from: name) != nil }
    public var target: CheckoutTarget? {
        if isFetchHead || remote || GitReferenceName.removingPrefix("refs/heads/", from: name) != nil { return .branch }
        if GitReferenceName.removingPrefix("refs/tags/", from: name) != nil { return .tag }
        return nil
    }
    public var label: String {
        for prefix in ["refs/heads/", "refs/tags/"] { if let short = GitReferenceName.removingPrefix(prefix, from: name) { return short } }
        if let short = GitReferenceName.removingPrefix("refs/remotes/", from: name) { return "remotes/" + short }
        return name
    }
    public var suggestedBranch: String {
        if remote {
            let source = symbolicTarget.flatMap { GitReferenceName.removingPrefix("refs/remotes/", from: $0) } ?? GitReferenceName.removingPrefix("refs/remotes/", from: name)!
            return String(decoding: source.utf8.split(separator: 47, maxSplits: 1).last ?? [], as: UTF8.self)
        }
        return "Branch_" + label
    }
}
public enum CheckoutReferenceOrdering {
    public static func sorted(_ values: [CheckoutReference], localBranchesFirst: Bool) -> [CheckoutReference] {
        values.sorted { a, b in
            func category(_ value: CheckoutReference) -> Int { value.isFetchHead ? 3 : value.target == .branch ? 0 : value.target == .tag ? 1 : 2 }
            let ca = category(a), cb = category(b)
            if ca != cb { return ca < cb }
            if ca == 0, localBranchesFirst {
                let ar = a.label.hasPrefix("remotes/"), br = b.label.hasPrefix("remotes/")
                if ar != br { return !ar }
            }
            let order = a.label.compare(b.label, options: [.caseInsensitive, .numeric], locale: Locale(identifier: "en_US_POSIX"))
            return order == .orderedSame ? a.name.utf8.lexicographicallyPrecedes(b.name.utf8) : order == .orderedAscending
        }
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
/// Acceptance of the command is independent of later repository inspection.
/// Only a successful process exit can produce this receipt; observers must not
/// turn a failed read into permission to repeat a successful mutation.
public struct RepositoryTransitionReceipt:Sendable {
    public let output:String
    public let cancelledAfterCommand:Bool
    public init(output:String,cancelledAfterCommand:Bool=false){self.output=output;self.cancelledAfterCommand=cancelledAfterCommand}
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
    public func checkoutReferences(includeAll: Bool = false, includeFetchHead: Bool = false, localBranchesFirst: Bool? = nil, cancellation: OperationCancellation? = nil, backend:GitLibGit2Configuration?=nil) throws -> [CheckoutReference] {
        let selected=backend ?? libgit2Configuration ?? .load()
        var result:[CheckoutReference]
        if let backend=masterReferenceBackend(selected) {
            result=try localReferenceReply(verb:"turtlegit-checkout-refs",operation:"choices",request:["version":1],backend:backend,command:.forEachRef,cancellation:cancellation).choices.filter {includeAll || GitReferenceName.removingPrefix("refs/heads/",from:$0.name) != nil || GitReferenceName.removingPrefix("refs/remotes/",from:$0.name) != nil || GitReferenceName.removingPrefix("refs/tags/",from:$0.name) != nil}
        } else {
        let bytes = try checkoutCommand(["for-each-ref", "--sort=refname", "--format=%(refname)%00%(symref)%00"] + (includeAll ? [] : ["refs/heads", "refs/remotes", "refs/tags"]), cancellation: cancellation).stdout
        let fields = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\0")
        result = []
        var i = 0
        while i + 1 < fields.count {
            let name = fields[i].hasPrefix("\n") ? String(fields[i].dropFirst()) : fields[i]
            if !name.isEmpty { result.append(CheckoutReference(name: name, symbolicTarget: fields[i+1].isEmpty ? nil : fields[i+1])) }
            i += 2
        }
        }
        if includeFetchHead {
            // Exactly one for-merge FETCH_HEAD, matching GetBranchList's choice.
            if let hash = try? fetchHeadForMerge(cancellation: cancellation),
               (hash.count == 40 || hash.count == 64), hash.allSatisfy({ $0.isASCII && $0.isHexDigit }),
               try revisionLookup(hash,requirement:.commit,cancellation:cancellation,backend:selected).objectID != nil {
                result.append(CheckoutReference(name: "FETCH_HEAD", symbolicTarget: nil))
            }
            try cancellation?.check()
        }
        return CheckoutReferenceOrdering.sorted(result, localBranchesFirst: localBranchesFirst ?? AdvancedListBehavior().localBranchesFirst)
    }
    private func checkoutCommand(_ arguments: [String], successfulExitCodes: ClosedRange<Int32> = 0...0, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> GitResult {
        do { return try run(["-c", "core.precomposeunicode=false"] + arguments, successfulExitCodes: successfulExitCodes, cancellation: cancellation, onOutput: onOutput) }
        catch let failure as GitFailure { throw GitFailure(arguments: arguments, code: failure.code, message: failure.message) }
    }
    public func checkout(_ options: CheckoutOptions, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil, onCommand: (@Sendable (GitCommandInvocation) -> Void)? = nil) throws -> String {
        try checkoutAccepted(options,cancellation:cancellation,onOutput:onOutput,onCommand:onCommand).output
    }
    public func checkoutAccepted(_ options:CheckoutOptions,cancellation:OperationCancellation?=nil,onOutput:(@Sendable(GitOutputChunk)->Void)?=nil,onCommand:(@Sendable(GitCommandInvocation)->Void)?=nil)throws->RepositoryTransitionReceipt {
        try cancellation?.check()
        let arguments = try checkoutArguments(options, cancellation: cancellation)
        try cancellation?.check()
        onCommand?(commandInvocation(["-c", "core.precomposeunicode=false"] + arguments))
        let result=try acceptedCreationResult {try checkoutCommand(arguments,cancellation:cancellation,onOutput:onOutput)}
        return .init(output:result.text,cancelledAfterCommand:cancellation?.isCancelled == true)
    }
    /// Read-only validation before a native options dialog hands off to progress.
    public func validateCheckout(_ options: CheckoutOptions, cancellation: OperationCancellation? = nil) throws { _ = try checkoutArguments(options, cancellation: cancellation) }
    private func checkoutArguments(_ options: CheckoutOptions, cancellation: OperationCancellation? = nil) throws -> [String] {
        try cancellation?.check()
        let backend=libgit2Configuration ?? .load()
        let revision = options.revision
        guard !revision.isEmpty else { throw CheckoutFailure.invalidRevision }
        let references = try checkoutReferences(includeFetchHead: GitReferenceName.equal(revision, "FETCH_HEAD"), cancellation: cancellation,backend:backend)
        let reference = references.first { GitReferenceName.equal($0.name, revision) }
        if options.target == .branch {
            guard let reference, reference.target == .branch else { throw CheckoutFailure.invalidRevision }
        } else if options.target == .tag {
            guard reference?.target == .tag else { throw CheckoutFailure.invalidRevision }
        }
        guard let resolved=try revisionLookup(revision,requirement:.commit,cancellation:cancellation,backend:backend).objectID else{throw CheckoutFailure.invalidRevision}
        var args = ["switch", "--no-guess"]
        if options.overwriteChanges { args.append("--discard-changes") }
        if options.merge { args.append("--merge") }
        if options.createBranch {
            let name = options.branchName.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                _ = try checkoutCommand(["check-ref-format", "refs/heads/" + name], cancellation: cancellation)
                _ = try checkoutCommand(["check-ref-format", "--branch", name], cancellation: cancellation)
            } catch { try cancellation?.check(); throw CheckoutFailure.invalidBranch }
            func exists(_ reference: String) throws -> Bool {
                try referenceExists(reference,cancellation:cancellation,backend:backend)
            }
            if !options.overrideBranch, try exists("refs/heads/" + name) { throw CheckoutFailure.branchExists }
            if !options.allowTagNameConflict, try exists("refs/tags/" + name) { throw CheckoutFailure.tagNameConflict }
            args += [options.overrideBranch ? "-C" : "-c", name]
            if reference?.remote == true {
                switch options.tracking {
                case .automatic: break
                case .track: args.append("--track")
                case .noTrack: args.append("--no-track")
                }
                args += ["--", revision]
            } else { args += ["--no-track", "--", resolved] }
        } else if options.target == .branch, let reference, !reference.remote, !reference.isFetchHead {
            args += ["--", reference.label]
        } else { args += ["--detach", "--", resolved] }
        return args
    }
}
