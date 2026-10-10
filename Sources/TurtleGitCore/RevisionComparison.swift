import Foundation

public enum ComparisonRevision: Hashable, Sendable {
    case revision(String), workingTree, emptyTree
    public var label: String {
        switch self { case .revision(let value): return value; case .workingTree: return "Working tree"; case .emptyTree: return "Empty tree" }
    }
}
public struct RevisionDiffOptions: Equatable, Sendable {
    public var ignoreSpaceAtEnd = false, ignoreSpaceChange = false, ignoreAllSpace = false, ignoreBlankLines = false, commonAncestor = false
    public var detectCopies = false
    public init() {}
    var arguments: [String] {
        (detectCopies ? ["-C50%"] : []) + (ignoreSpaceAtEnd ? ["--ignore-space-at-eol"] : []) + (ignoreSpaceChange ? ["-b"] : []) + (ignoreAllSpace ? ["-w"] : []) + (ignoreBlankLines ? ["--ignore-blank-lines"] : [])
    }
}
public struct ComparisonRevisionDetails: Sendable {
    public let shortHash: String
    public let subject: String
    public let author: String
    public let authorDate: Date?
    public let committerDate: Date?
}
public struct RevisionComparisonSnapshot: Sendable {
    public let root: URL
    public let from: ComparisonRevision
    public let to: ComparisonRevision
    public let fromDetails: ComparisonRevisionDetails?
    public let toDetails: ComparisonRevisionDetails?
    public let files: [CommitFile]
    public let options: RevisionDiffOptions
}
public enum RevisionComparisonFailure: LocalizedError {
    case range, selection
    public var errorDescription: String? {
        switch self { case .range: return "At least one comparison side must be a revision or the empty tree."; case .selection: return "Choose files from this comparison and repository." }
    }
}
extension GitRepository {
    /// Ordinary file Diff uses HEAD-to-working content, including staged edits.
    /// Explicit untracked selections use an empty base without staging them.
    public func workingFileComparison(paths: [String], amendToParent: Bool = false) throws -> RevisionComparisonSnapshot {
        guard !paths.isEmpty else { throw RevisionComparisonFailure.selection }
        for path in paths { _ = try restoreLocation(path) }
        let head = try run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], successfulExitCodes: 0...1)
        let from: ComparisonRevision
        if head.exitCode == 0 {
            let hash = String(decoding: head.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
            if amendToParent {
                let parents = try run(["rev-list", "--parents", "-n", "1", hash]).text.split(whereSeparator: \.isWhitespace)
                from = parents.count > 1 ? .revision(String(parents[1])) : .emptyTree
            } else { from = .revision(hash) }
        }
        else {
            let ref = try run(["symbolic-ref", "--quiet", "HEAD"]).text.trimmingCharacters(in: .newlines)
            guard try run(["show-ref", "--verify", "--quiet", ref], successfulExitCodes: 0...1).exitCode == 1 else { throw RevisionComparisonFailure.range }
            from = .emptyTree
        }
        let snapshot = try revisionComparison(from: from, to: .workingTree)
        let selected = try selectedFileComparison(snapshot, paths: paths)
        // Keep this status-list route limited to changes, while explicit files
        // absent from the base (including ignored paths) use an empty side.
        let changed = Set(snapshot.files.map(\.path))
        let files = selected.files.filter { changed.contains($0.path) || $0.action == "A" }
        return RevisionComparisonSnapshot(root: root, from: snapshot.from, to: snapshot.to, fromDetails: snapshot.fromDetails, toDetails: snapshot.toDetails, files: files, options: snapshot.options)
    }
    /// Selected-file comparisons also display unchanged files. Working bytes
    /// take precedence over an index deletion when the path exists on disk.
    public func revisionFileComparison(from: ComparisonRevision, to: ComparisonRevision, paths: [String]) throws -> RevisionComparisonSnapshot {
        guard !paths.isEmpty else { throw RevisionComparisonFailure.selection }
        for path in paths { _ = try restoreLocation(path) }
        return try selectedFileComparison(revisionComparison(from: from, to: to), paths: paths)
    }
    private func selectedFileComparison(_ snapshot: RevisionComparisonSnapshot, paths: [String]) throws -> RevisionComparisonSnapshot {
        func mode(_ revision: ComparisonRevision, _ path: String) throws -> String? {
            if revision == .emptyTree { return nil }
            if revision == .workingTree {
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: restoreLocation(path).path)
                    switch attributes[.type] as? FileAttributeType {
                    case .typeRegular: return "100644"
                    case .typeSymbolicLink: return "120000"
                    case .typeDirectory: return "160000"
                    default: throw RevisionComparisonFailure.selection
                    }
                } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
            }
            guard case .revision(let hash) = revision else { throw RevisionComparisonFailure.range }
            for record in try run(["ls-tree", "-z", hash, "--", path]).stdout.split(separator: 0) {
                guard let tab = record.firstIndex(of: 9), Data(record[record.index(after: tab)...]) == Data(path.utf8) else { continue }
                let header = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
                guard header.count == 3, ["100644", "100755", "120000", "160000"].contains(String(header[0])) else { throw RevisionComparisonFailure.selection }
                return String(header[0])
            }
            return nil
        }
        var files: [CommitFile] = []
        for path in Set(paths).sorted() {
            let existing = snapshot.files.first { $0.path == path || $0.oldPath == path }
            let destination = existing?.path ?? path, original = existing?.oldPath ?? path
            guard !files.contains(where: { $0.path == destination }) else { continue }
            let oldMode = try mode(snapshot.from, original), newMode = try mode(snapshot.to, destination)
            guard oldMode != nil || newMode != nil else { continue }
            let isSubmodule = oldMode == "160000" || newMode == "160000"
            guard newMode != "160000" || oldMode == "160000" || existing?.isSubmodule == true else { throw RevisionComparisonFailure.selection }
            let action = oldMode == nil ? "A" : newMode == nil ? "D" : existing?.action.hasPrefix("R") == true ? "R" : "M"
            files.append(CommitFile(path: destination, oldPath: existing?.oldPath, action: action, added: existing?.added, removed: existing?.removed, hasStatistics: existing?.hasStatistics ?? false, isSubmodule: isSubmodule))
        }
        return RevisionComparisonSnapshot(root: root, from: snapshot.from, to: snapshot.to, fromDetails: snapshot.fromDetails, toDetails: snapshot.toDetails, files: files, options: snapshot.options)
    }
    public func revisionComparison(from: ComparisonRevision, to: ComparisonRevision, options: RevisionDiffOptions = RevisionDiffOptions(), cancellation: OperationCancellation? = nil) throws -> RevisionComparisonSnapshot {
        let token = cancellation ?? OperationCancellation()
        try token.check()
        func resolve(_ side: ComparisonRevision) throws -> ComparisonRevision {
            if case .revision(let name) = side { return .revision(try run(["rev-parse", "--verify", "--end-of-options", name + "^{commit}"], cancellation: token).text.trimmingCharacters(in: .newlines)) }
            return side
        }
        func isAncestor(_ a: String, _ b: String) throws -> Bool {
            do { return try run(["merge-base", "--is-ancestor", a, b], successfulExitCodes: 0...1, cancellation: token).exitCode == 0 }
            catch { try token.check(); return false }
        }
        var old = try resolve(from), new = try resolve(to)
        // Match FileDiffDlg: replace the base only when its IsFastForward
        // check succeeds; divergent or working-tree pairs keep the direct range.
        if options.commonAncestor, case .revision(let a) = old, case .revision(let b) = new,
           try isAncestor(a, b) {
            old = .revision(try run(["merge-base", a, b], cancellation: token).text.trimmingCharacters(in: .newlines))
        }
        let args = try comparisonArguments(from: old, to: new, options: options, cancellation: token)
        let files = CommitFile.parse(names: try run(args + ["--name-status", "-z", "--"], cancellation: token).stdout, statistics: try run(args + ["--numstat", "-z", "--"], cancellation: token).stdout, raw: try run(args + ["--raw", "-z", "--"], cancellation: token).stdout).filter { $0.hasStatistics || $0.isSubmodule }
        return RevisionComparisonSnapshot(root: root, from: old, to: new, fromDetails: try comparisonDetails(old, cancellation: token), toDetails: try comparisonDetails(new, cancellation: token), files: files, options: options)
    }
    public func revisionComparisonPatch(_ snapshot: RevisionComparisonSnapshot, paths: [String] = []) throws -> String {
        String(decoding: try revisionComparisonPatchData(snapshot, paths: paths), as: UTF8.self)
    }
    public func revisionComparisonPatchData(_ snapshot: RevisionComparisonSnapshot, paths: [String] = [], cancellation: OperationCancellation? = nil) throws -> Data {
        let token = cancellation ?? OperationCancellation(); try token.check()
        guard snapshot.root == root, paths.allSatisfy({ path in snapshot.files.contains { $0.path == path } }) else { throw RevisionComparisonFailure.selection }
        let selected = paths.isEmpty ? [] : snapshot.files.filter { paths.contains($0.path) }.flatMap { [$0.path] + ($0.oldPath.map { [$0] } ?? []) }
        for path in selected { _ = try restoreLocation(path) }
        return try run(comparisonArguments(from: snapshot.from, to: snapshot.to, options: snapshot.options, cancellation: token) + ["--"] + Set(selected).sorted(), cancellation: token).stdout
    }
    private func comparisonDetails(_ side: ComparisonRevision, cancellation: OperationCancellation? = nil) throws -> ComparisonRevisionDetails? {
        guard case .revision(let hash) = side else { return nil }
        let fields = try run(["show", "--encoding=UTF-8", "--no-patch", "--no-notes", "--format=%h%x00%s%x00%aN%x00%at%x00%ct", hash, "--"], cancellation: cancellation).text.trimmingCharacters(in: .newlines).components(separatedBy: "\0")
        guard fields.count == 5 else { throw RevisionComparisonFailure.range }
        return ComparisonRevisionDetails(shortHash: fields[0], subject: fields[1], author: fields[2], authorDate: TimeInterval(fields[3]).map(Date.init(timeIntervalSince1970:)), committerDate: TimeInterval(fields[4]).map(Date.init(timeIntervalSince1970:)))
    }
    private func comparisonArguments(from: ComparisonRevision, to: ComparisonRevision, options: RevisionDiffOptions, cancellation: OperationCancellation? = nil) throws -> [String] {
        guard from != .workingTree || to != .workingTree else { throw RevisionComparisonFailure.range }
        func hash(_ side: ComparisonRevision) throws -> String {
            switch side { case .revision(let value): return value; case .emptyTree: return try run(["mktree"], cancellation: cancellation).text.trimmingCharacters(in: .newlines); case .workingTree: throw RevisionComparisonFailure.range }
        }
        var args = ["diff", "--no-ext-diff", "--no-color", "-M"] + options.arguments
        if from == .workingTree { args += ["-R", try hash(to)] }
        else if to == .workingTree { args += [try hash(from)] }
        else { args += [try hash(from), try hash(to)] }
        return args
    }
}
