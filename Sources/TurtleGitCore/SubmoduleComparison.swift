import Foundation

public struct SubmoduleComparisonSide: Sendable {
    public let revision: String?
    public let subject: String
    public let available: Bool
    public var canShowLog: Bool { available && revision != nil }
}

/// A read-only comparison of superproject gitlinks and the child checkout.
public struct SubmoduleComparison: Sendable {
    public let path: String
    public let checkout: URL?
    public let from: SubmoduleComparisonSide
    public let to: SubmoduleComparisonSide
    public let toWorkingTree: Bool
    public let dirty: Bool
    public let change: SubmoduleChangeType
}

public enum SubmoduleComparisonFailure: LocalizedError {
    case unsupported, unsafeCheckout, conflicted, unavailable
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "The displayed submodule revision is no longer available. Refresh the comparison."
        case .unsupported: return "Choose a path that is a submodule in at least one revision."
        case .unsafeCheckout: return "The submodule checkout is outside its expected working-tree location."
        case .conflicted: return "Resolve the submodule index conflict before comparing its working checkout."
        }
    }
}

public enum SubmoduleComparisonAction: Sendable {
    case logFrom, logTo, compareRevisions, compareWorkingTree
}

public struct PreparedSubmoduleComparison: Sendable {
    public enum Command: Sendable {
        case log(String), status, compare(ComparisonRevision, ComparisonRevision)
    }
    public let repository: GitRepository
    public let command: Command
}

public enum SubmoduleWorkingHistoryFailure: LocalizedError {
    case uninitialized
    public var errorDescription: String? { "The submodule is not initialized. Initialize its working checkout to show its history." }
}

extension GitRepository {
    /// Resolve only an initialized working checkout; never let Git discover the
    /// superproject from an empty/uninitialized child directory.
    public func submoduleWorkingRepository(path: String, cancellation: OperationCancellation? = nil) throws -> GitRepository {
        try submoduleCheckout(path: path, requireCurrentGitlink: true, cancellation: cancellation)
    }
    private func submoduleCheckout(path: String, requireCurrentGitlink: Bool, cancellation: OperationCancellation?) throws -> GitRepository {
        try cancellation?.check()
        let location = try restoreLocation(path)
        if try requireCurrentGitlink && !submoduleUpdatePaths(cancellation: cancellation).contains(path) {
            let previous = try run(["ls-tree", "--full-tree", "-z", "HEAD", "--", path], successfulExitCodes: 0...128, cancellation: cancellation)
            let wasGitlink = previous.exitCode == 0 && previous.stdout.split(separator: 0).contains { record in
                let parts = record.split(separator: 9, maxSplits: 1)
                return parts.count == 2 && String(decoding: parts[1], as: UTF8.self) == path && parts[0].starts(with: Data("160000 ".utf8))
            }
            guard wasGitlink else { throw SubmoduleComparisonFailure.unsupported }
        }
        guard FileManager.default.fileExists(atPath: location.appendingPathComponent(".git").path) else { throw SubmoduleWorkingHistoryFailure.uninitialized }
        let kind = try FileManager.default.attributesOfItem(atPath: location.path)[.type] as? FileAttributeType
        let gitKind = try FileManager.default.attributesOfItem(atPath: location.appendingPathComponent(".git").path)[.type] as? FileAttributeType
        guard kind == .typeDirectory, gitKind == .typeRegular || gitKind == .typeDirectory else { throw SubmoduleComparisonFailure.unsafeCheckout }
        var bytes = try run(["-C", location.path, "rev-parse", "--show-toplevel"], cancellation: cancellation).stdout
        if bytes.last == 10 { bytes.removeLast() }
        let discovered = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).resolvingSymlinksInPath().standardizedFileURL
        guard discovered == location.resolvingSymlinksInPath().standardizedFileURL else { throw SubmoduleComparisonFailure.unsafeCheckout }
        try cancellation?.check()
        return GitRepository(root: location, executable: executable, askpass: askpass)
    }
    /// Revalidate the checkout and immutable displayed objects immediately before
    /// dispatch. Moving parent refs or child HEAD must not retarget this action.
    public func prepareSubmoduleComparison(_ snapshot: SubmoduleComparison, action: SubmoduleComparisonAction, cancellation: OperationCancellation? = nil) async throws -> PreparedSubmoduleComparison {
        try cancellation?.check()
        let child = try submoduleCheckout(path: snapshot.path, requireCurrentGitlink: false, cancellation: cancellation)
        guard child.root == snapshot.checkout else { throw SubmoduleComparisonFailure.unsafeCheckout }
        func validate(_ side: SubmoduleComparisonSide) async throws {
            guard side.available else { throw SubmoduleComparisonFailure.unavailable }
            if let hash = side.revision {
                let resolved = try await child.run(["rev-parse", "--verify", "--end-of-options", hash + "^{commit}"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
                guard resolved == hash else { throw SubmoduleComparisonFailure.unavailable }
            }
        }
        let command: PreparedSubmoduleComparison.Command
        switch action {
        case .logFrom, .logTo:
            let side: SubmoduleComparisonSide
            if case .logFrom = action { side = snapshot.from } else { side = snapshot.to }
            try await validate(side)
            guard let hash = side.revision else { throw SubmoduleComparisonFailure.unavailable }
            command = .log(hash)
        case .compareRevisions, .compareWorkingTree:
            try await validate(snapshot.from); try await validate(snapshot.to)
            if snapshot.change == .identical { command = .status }
            else {
                let working: Bool
                if case .compareWorkingTree = action { working = true } else { working = snapshot.dirty && snapshot.change == .unknown }
                command = .compare(snapshot.from.revision.map(ComparisonRevision.revision) ?? .emptyTree,
                                   working ? .workingTree : snapshot.to.revision.map(ComparisonRevision.revision) ?? .emptyTree)
            }
        }
        try cancellation?.check()
        return PreparedSubmoduleComparison(repository: child, command: command)
    }

    /// `from` and `to` are revisions of this superproject; nil `to` compares
    /// against the actual child HEAD (or indexed gitlink if uninitialized).
    public func submoduleComparison(path: String, from: String = "HEAD", to: String? = nil, cancellation: OperationCancellation? = nil) throws -> SubmoduleComparison {
        try cancellation?.check()
        let location = try restoreLocation(path)
        func gitlink(_ revision: String) throws -> String? {
            if revision.isEmpty { return nil }
            let tree = try run(["rev-parse", "--verify", "--end-of-options", revision + "^{tree}"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
            let records = try run(["ls-tree", "--full-tree", "-z", tree, "--", path], cancellation: cancellation).stdout.split(separator: 0)
            for record in records {
                let parts = record.split(separator: 9, maxSplits: 1)
                guard parts.count == 2, String(decoding: parts[1], as: UTF8.self) == path else { continue }
                let header = String(decoding: parts[0], as: UTF8.self).split(separator: " ")
                if header.count == 3 && header[0] == "160000" { return String(header[2]) }
            }
            return nil
        }
        func workingGitlink() throws -> String? {
            var hash: String?
            let records = try run(["ls-files", "--stage", "-z", "--", path], cancellation: cancellation).stdout.split(separator: 0)
            for record in records {
                let parts = record.split(separator: 9, maxSplits: 1)
                guard parts.count == 2, String(decoding: parts[1], as: UTF8.self) == path else { continue }
                let header = String(decoding: parts[0], as: UTF8.self).split(separator: " ")
                guard header.count == 3 else { continue }
                guard header[2] == "0" else { throw SubmoduleComparisonFailure.conflicted }
                if header[0] == "160000" { hash = String(header[1]) }
            }
            return hash
        }
        var fromHash = try from == "Working tree" ? workingGitlink() : gitlink(from)
        var toHash = try to.map(gitlink) ?? workingGitlink()
        guard fromHash != nil || toHash != nil else { throw SubmoduleComparisonFailure.unsupported }
        var checkout: URL?
        if FileManager.default.fileExists(atPath: location.appendingPathComponent(".git").path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw SubmoduleComparisonFailure.unsafeCheckout }
            var bytes = try run(["-C", location.path, "rev-parse", "--show-toplevel"], cancellation: cancellation).stdout
            if bytes.last == 10 { bytes.removeLast() }
            let discovered = URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).resolvingSymlinksInPath().standardizedFileURL
            guard discovered == location.resolvingSymlinksInPath().standardizedFileURL else { throw SubmoduleComparisonFailure.unsafeCheckout }
            checkout = location
            if to == nil, toHash != nil { toHash = try run(["-C", location.path, "rev-parse", "--verify", "HEAD^{commit}"], cancellation: cancellation).text.trimmingCharacters(in: .newlines) }
            if from == "Working tree", fromHash != nil { fromHash = try run(["-C", location.path, "rev-parse", "--verify", "HEAD^{commit}"], cancellation: cancellation).text.trimmingCharacters(in: .newlines) }
        }
        let dirty = try to == nil && checkout != nil && !run(["-C", location.path, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none"], environmentOverrides: ["GIT_OPTIONAL_LOCKS": "0"], cancellation: cancellation).stdout.isEmpty
        func metadata(_ hash: String?) throws -> (SubmoduleComparisonSide, Int64) {
            guard checkout != nil else { return (SubmoduleComparisonSide(revision: hash, subject: "not initialized", available: false), 0) }
            guard let hash else { return (SubmoduleComparisonSide(revision: nil, subject: "", available: true), 0) }
            do {
                let bytes = try run(["-C", location.path, "log", "--encoding=UTF-8", "-1", "--format=%ct%x00%s", hash, "--"], cancellation: cancellation).stdout
                let fields = bytes.split(separator: 0, maxSplits: 1, omittingEmptySubsequences: false)
                guard fields.count == 2, let time = Int64(String(decoding: fields[0], as: UTF8.self)) else { throw SubmoduleComparisonFailure.unsupported }
                var subject = Data(fields[1]); if subject.last == 10 { subject.removeLast() }
                return (SubmoduleComparisonSide(revision: hash, subject: String(decoding: subject, as: UTF8.self), available: true), time)
            } catch { try cancellation?.check(); return (SubmoduleComparisonSide(revision: hash, subject: error.localizedDescription, available: false), 0) }
        }
        let old = try metadata(fromHash), new = try metadata(toHash)
        var change = SubmoduleChangeType.unknown
        if old.0.available && new.0.available {
            if fromHash == nil { change = .newSubmodule }
            else if toHash == nil { change = .deleteSubmodule }
            else if fromHash == toHash { change = .identical }
            else if let fromHash, let toHash {
                if (try? run(["-C", location.path, "merge-base", "--is-ancestor", fromHash, toHash], cancellation: cancellation)) != nil { change = .fastForward }
                else if (try? run(["-C", location.path, "merge-base", "--is-ancestor", toHash, fromHash], cancellation: cancellation)) != nil { change = .rewind }
                else { change = new.1 > old.1 ? .newerTime : new.1 < old.1 ? .olderTime : .sameTime }
            }
        }
        try cancellation?.check()
        return SubmoduleComparison(path: path, checkout: checkout, from: old.0, to: new.0, toWorkingTree: to == nil, dirty: dirty, change: change)
    }
}
