import Foundation
import Darwin

/// Shared source percentage, captured with a repository session so paired name,
/// statistic and patch reads cannot observe different preferences mid-operation.
public struct GitDiffDetection: Equatable, Sendable {
    public let percentage: Int
    public init(percentage: Int = 50) { self.percentage = (0...100).contains(percentage) ? percentage : 50 }
    public static func load(from preferences: UserDefaults = .standard) -> GitDiffDetection {
        guard let value = preferences.object(forKey: "DiffSimilarityIndexThreshold") else { return GitDiffDetection() }
        let number = (value as? NSNumber)?.intValue ?? Int(value as? String ?? "") ?? 50
        return GitDiffDetection(percentage: number)
    }
    public var renameArgument: String { "-M\(percentage)%" }
    public var copyArgument: String { "-C\(percentage)%" }
    public var statusArgument: String { "--find-renames=\(percentage)%" }
    public var comparisonArguments: [String] { [renameArgument, copyArgument] }
    /// GetFiles' libgit2 path skips find-similar entirely at zero, while the CLI
    /// source still emits -C0%/-M0%. Keep that distinction explicit.
    public var historyArguments: [String] { percentage == 0 ? ["--no-renames"] : comparisonArguments }
}

/// FileDiffDlg uses the same literal query grammar as Log, over both rename paths.
public struct ComparisonPathFilter {
    private let query: HistoryTextQuery
    public init(_ text: String) { query = HistoryTextQuery(text, caseSensitive: false) }
    public func matches(path: String, oldPath: String? = nil) -> Bool {
        query.matches(path + (oldPath.map { "\n" + $0 } ?? ""))
    }
}

public enum ComparisonRevision: Hashable, Sendable {
    case revision(String), workingTree, emptyTree
    public var label: String {
        switch self { case .revision(let value): return value; case .workingTree: return "Working tree"; case .emptyTree: return "Empty tree" }
    }
}
public struct RevisionDiffOptions: Equatable, Sendable {
    public var ignoreSpaceAtEnd = false, ignoreSpaceChange = false, ignoreAllSpace = false, ignoreBlankLines = false, commonAncestor = false
    public var detectCopies = true
    public init() {}
    func arguments(detection: GitDiffDetection) -> [String] {
        (detectCopies ? [detection.copyArgument] : []) + (ignoreSpaceAtEnd ? ["--ignore-space-at-eol"] : []) + (ignoreSpaceChange ? ["-b"] : []) + (ignoreAllSpace ? ["-w"] : []) + (ignoreBlankLines ? ["--ignore-blank-lines"] : [])
    }
}
public struct ComparisonRevisionDetails: Sendable {
    public let shortHash: String
    public var isTree = false
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
    public let scopePaths: [String]
    public let diffDetection: GitDiffDetection
    public init(root: URL, from: ComparisonRevision, to: ComparisonRevision, fromDetails: ComparisonRevisionDetails?, toDetails: ComparisonRevisionDetails?, files: [CommitFile], options: RevisionDiffOptions, scopePaths: [String] = [], diffDetection: GitDiffDetection = .load()) {
        self.root = root; self.from = from; self.to = to; self.fromDetails = fromDetails; self.toDetails = toDetails
        self.files = files; self.options = options; self.scopePaths = scopePaths; self.diffDetection = diffDetection
    }
}
public enum RevisionComparisonFailure: LocalizedError {
    case range, selection, localPathCollision
    public var errorDescription: String? {
        switch self { case .range: return "At least one comparison side must be a revision or the empty tree."; case .selection: return "Choose files from this comparison and repository."; case .localPathCollision: return "The selected Git paths map to the same local filename. Choose one path to restore." }
    }
}
extension GitRepository {
    /// Comparisons consume snapshots, so accept both commits and standalone trees.
    /// Preserve a commit's identity for metadata/history; never replace a tree with
    /// an arbitrary commit that happens to contain the same files.
    func comparisonObject(_ name: String, cancellation: OperationCancellation? = nil) throws -> String {
        try cancellation?.check()
        guard !name.isEmpty, !name.utf8.contains(0) else { throw RevisionComparisonFailure.range }
        let object = try run(["-c", "core.precomposeunicode=false", "rev-parse", "--verify", "--end-of-options", name + "^{}"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
        let kind = try run(["cat-file", "-t", object], cancellation: cancellation).text
        guard kind == "commit\n" || kind == "tree\n" else { throw RevisionComparisonFailure.range }
        return object
    }
    /// PrevDiffCommand uses HEAD~1 for directories, and the second commit
    /// touching a selected file for files. Both compare against working bytes.
    public func previousDiffBase(path: String, cancellation: OperationCancellation? = nil) throws -> (revision: String, directory: Bool) {
        try cancellation?.check()
        guard try !isBare(cancellation: cancellation) else { throw FinderCommandFailure.selection }
        let location = path == "." ? root : try restoreLocation(path)
        let attributes = try? FileManager.default.attributesOfItem(atPath: location.path)
        if path == "." || attributes?[.type] as? FileAttributeType == .typeDirectory {
            let result = try run(["rev-parse", "--verify", "--quiet", "HEAD~1^{commit}"], successfulExitCodes: 0...1, cancellation: cancellation)
            guard result.exitCode == 0 else { throw FinderCommandFailure.previousRevisionUnavailable }
            return (result.text.trimmingCharacters(in: .newlines), true)
        }
        let revisions = try run(["log", "--format=%H", "--max-count=2", "--", path], cancellation: cancellation).text.split(separator: "\n")
        guard revisions.count == 2 else { throw FinderCommandFailure.previousRevisionUnavailable }
        return (String(revisions[1]), false)
    }
    /// Ordinary file Diff uses HEAD-to-working content, including staged edits.
    /// Explicit untracked selections use an empty base without staging them.
    public func workingFileComparison(paths: [String], amendToParent: Bool = false, cancellation: OperationCancellation? = nil) throws -> RevisionComparisonSnapshot {
        try cancellation?.check()
        func read(_ args: [String], successfulExitCodes: ClosedRange<Int32> = 0...0) throws -> GitResult {
            try run(args, successfulExitCodes: successfulExitCodes, cancellation: cancellation)
        }

        guard !paths.isEmpty else { throw RevisionComparisonFailure.selection }
        for path in paths { _ = try restoreLocation(path) }
        let head = try read(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], successfulExitCodes: 0...1)
        let from: ComparisonRevision
        if head.exitCode == 0 {
            let hash = String(decoding: head.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
            if amendToParent {
                let parents = try read(["rev-list", "--parents", "-n", "1", hash]).text.split(whereSeparator: \.isWhitespace)
                from = parents.count > 1 ? .revision(String(parents[1])) : .emptyTree
            } else { from = .revision(hash) }
        }
        else {
            let ref = try read(["symbolic-ref", "--quiet", "HEAD"]).text.trimmingCharacters(in: .newlines)
            guard try read(["show-ref", "--verify", "--quiet", ref], successfulExitCodes: 0...1).exitCode == 1 else { throw RevisionComparisonFailure.range }
            from = .emptyTree
        }
        let snapshot = try revisionComparison(from: from, to: .workingTree, cancellation: cancellation)
        let selected = try selectedFileComparison(snapshot, paths: paths, cancellation: cancellation)
        // Keep this status-list route limited to changes, while explicit files
        // absent from the base (including ignored paths) use an empty side.
        let changed = Set(snapshot.files.map(\.path))
        let files = selected.files.filter { changed.contains($0.path) || $0.action == "A" }
        return RevisionComparisonSnapshot(root: root, from: snapshot.from, to: snapshot.to, fromDetails: snapshot.fromDetails, toDetails: snapshot.toDetails, files: files, options: snapshot.options, scopePaths: snapshot.scopePaths, diffDetection: snapshot.diffDetection)
    }
    /// Selected-file comparisons also display unchanged files. Working bytes
    /// take precedence over an index deletion when the path exists on disk.
    public func revisionFileComparison(from: ComparisonRevision, to: ComparisonRevision, paths: [String], cancellation: OperationCancellation? = nil) throws -> RevisionComparisonSnapshot {
        try cancellation?.check()

        guard !paths.isEmpty else { throw RevisionComparisonFailure.selection }
        for path in paths { _ = try restoreLocation(path) }
        return try selectedFileComparison(revisionComparison(from: from, to: to, cancellation: cancellation), paths: paths, cancellation: cancellation)
    }
    private func selectedFileComparison(_ snapshot: RevisionComparisonSnapshot, paths: [String], cancellation: OperationCancellation? = nil) throws -> RevisionComparisonSnapshot {
        try cancellation?.check()
        func read(_ args: [String], successfulExitCodes: ClosedRange<Int32> = 0...0) throws -> GitResult {
            try run(args, successfulExitCodes: successfulExitCodes, cancellation: cancellation)
        }

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
            for record in try read(["-c", "core.precomposeunicode=false", "ls-tree", "-z", hash, "--", path]).stdout.split(separator: 0) {
                guard let tab = record.firstIndex(of: 9), Data(record[record.index(after: tab)...]) == Data(path.utf8) else { continue }
                let header = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
                guard header.count == 3, ["100644", "100755", "120000", "160000"].contains(String(header[0])) else { throw RevisionComparisonFailure.selection }
                return String(header[0])
            }
            return nil
        }
        var files: [CommitFile] = []
        for path in GitPathSet(paths).sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            try cancellation?.check()
            let existing = snapshot.files.first { GitReferenceName.equal($0.path,path) || GitReferenceName.equal(path,$0.oldPath) }
            let destination = existing?.path ?? path, original = existing?.oldPath ?? path
            guard !files.contains(where: { GitReferenceName.equal($0.path,destination) }) else { continue }
            let oldMode = try mode(snapshot.from, original), newMode = try mode(snapshot.to, destination)
            guard oldMode != nil || newMode != nil else { continue }
            let isSubmodule = oldMode == "160000" || newMode == "160000"
            guard newMode != "160000" || oldMode == "160000" || existing?.isSubmodule == true else { throw RevisionComparisonFailure.selection }
            let action = oldMode == nil ? "A" : newMode == nil ? "D" : existing?.action.hasPrefix("R") == true ? "R" : "M"
            files.append(CommitFile(path: destination, oldPath: existing?.oldPath, action: action, added: existing?.added, removed: existing?.removed, hasStatistics: existing?.hasStatistics ?? false, isSubmodule: isSubmodule))
        }
        return RevisionComparisonSnapshot(root: root, from: snapshot.from, to: snapshot.to, fromDetails: snapshot.fromDetails, toDetails: snapshot.toDetails, files: files, options: snapshot.options, scopePaths: snapshot.scopePaths, diffDetection: snapshot.diffDetection)
    }
    public func revisionComparison(from: ComparisonRevision, to: ComparisonRevision, options: RevisionDiffOptions = RevisionDiffOptions(), useMailmap: Bool = GitIdentityDisplay().useMailmap, cancellation: OperationCancellation? = nil, paths: [String] = []) throws -> RevisionComparisonSnapshot {
        let scope = paths.filter { $0 != "." }
        for path in scope { _ = try restoreLocation(path) }
        let token = cancellation ?? OperationCancellation()
        try token.check()
        func resolve(_ side: ComparisonRevision) throws -> ComparisonRevision {
            if case .revision(let name) = side { return .revision(try comparisonObject(name, cancellation: token)) }
            return side
        }
        var old = try resolve(from), new = try resolve(to)
        // FileDiffDlg uses the single IsFastForward/common-ancestor result only
        // for the explicit common-ancestor option. Generic/tree/working-copy
        // comparison and structural merge-base --all requests stay independent.
        if options.commonAncestor, case .revision(let a) = old, case .revision(let b) = new {
            let inspection=try replayMergeBase(from:a,to:b,cancellation:token)
            if inspection.fastForward,let base=inspection.base {old = .revision(base)}
        }
        let args = try comparisonArguments(from: old, to: new, options: options, cancellation: token)
        let files = CommitFile.parse(names: try run(args + ["--name-status", "-z", "--"] + scope, cancellation: token).stdout, statistics: try run(args + ["--numstat", "-z", "--"] + scope, cancellation: token).stdout, raw: try run(args + ["--raw", "-z", "--"] + scope, cancellation: token).stdout).filter { $0.hasStatistics || $0.isSubmodule }
        return RevisionComparisonSnapshot(root: root, from: old, to: new, fromDetails: try comparisonDetails(old, useMailmap: useMailmap, cancellation: token), toDetails: try comparisonDetails(new, useMailmap: useMailmap, cancellation: token), files: files, options: options, scopePaths: scope, diffDetection: diffDetection)
    }
    public func revisionComparisonPatch(_ snapshot: RevisionComparisonSnapshot, paths: [String] = []) throws -> String {
        String(decoding: try revisionComparisonPatchData(snapshot, paths: paths), as: UTF8.self)
    }
    public func revisionComparisonPatchData(_ snapshot: RevisionComparisonSnapshot, paths: [String] = [], cancellation: OperationCancellation? = nil,backend:GitLibGit2Configuration? = nil) throws -> Data {
        let token = cancellation ?? OperationCancellation(); try token.check()
        guard snapshot.root == root, paths.allSatisfy({ path in snapshot.files.contains { GitReferenceName.equal($0.path,path) } }) else { throw RevisionComparisonFailure.selection }
        let selected = paths.isEmpty ? snapshot.scopePaths : snapshot.files.filter { GitPathSet(paths).contains($0.path) }.flatMap { [$0.path] + ($0.oldPath.map { [$0] } ?? []) }
        for path in selected { _ = try restoreLocation(path) }
        return try unifiedDiffData(arguments:comparisonArguments(from: snapshot.from, to: snapshot.to, options: snapshot.options, detection: snapshot.diffDetection, cancellation: token) + ["--"] + GitPathSet(selected).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) },cancellation:token,backend:backend)
    }
    private func comparisonDetails(_ side: ComparisonRevision, useMailmap: Bool, cancellation: OperationCancellation? = nil) throws -> ComparisonRevisionDetails? {
        guard case .revision(let hash) = side else { return nil }
        if try run(["cat-file", "-t", hash], cancellation: cancellation).text == "tree\n" {
            return ComparisonRevisionDetails(shortHash: String(hash.prefix(12)), isTree: true, subject: "Tree", author: "", authorDate: nil, committerDate: nil)
        }
        let fields = try run(["show", "--encoding=UTF-8", "--no-patch", "--no-notes", "--format=%h%x00%s%x00" + GitIdentityDisplay(useMailmap: useMailmap).authorName + "%x00%at%x00%ct", hash, "--"], cancellation: cancellation).text.trimmingCharacters(in: .newlines).components(separatedBy: "\0")
        guard fields.count == 5 else { throw RevisionComparisonFailure.range }
        return ComparisonRevisionDetails(shortHash: fields[0], subject: fields[1], author: fields[2], authorDate: TimeInterval(fields[3]).map(Date.init(timeIntervalSince1970:)), committerDate: TimeInterval(fields[4]).map(Date.init(timeIntervalSince1970:)))
    }
    private func comparisonArguments(from: ComparisonRevision, to: ComparisonRevision, options: RevisionDiffOptions, detection: GitDiffDetection? = nil, cancellation: OperationCancellation? = nil) throws -> [String] {
        guard from != .workingTree || to != .workingTree else { throw RevisionComparisonFailure.range }
        func hash(_ side: ComparisonRevision) throws -> String {
            switch side { case .revision(let value): return value; case .emptyTree: return try run(["mktree"], cancellation: cancellation).text.trimmingCharacters(in: .newlines); case .workingTree: throw RevisionComparisonFailure.range }
        }
        let detection = detection ?? diffDetection
        var args = ["-c", "core.precomposeunicode=false", "diff", "--no-ext-diff", "--no-color", detection.renameArgument] + options.arguments(detection: detection)
        if from == .workingTree { args += ["-R", try hash(to)] }
        else if to == .workingTree { args += [try hash(from)] }
        else { args += [try hash(from), try hash(to)] }
        return args
    }
}

/// FileDiffDlg's checkout/rm recipe, pinned before any protected working-tree step.
public struct ComparisonFileRevert: Sendable {
    public let path: String
    public let revision: String
    fileprivate let root: URL
    fileprivate let unstage: Bool
    fileprivate let ignoreUnmatched: Bool
    fileprivate let submodule: Bool
    fileprivate let removals: [(path: String, always: Bool)]
}
/// Validated invocation shared by per-file preparation and protected checkout.
/// A missing file/object must not reject unrelated selected files before the
/// native source-style Ignore/Abort question can run.
public struct ComparisonRevertBatch: Sendable {
    public let files: [CommitFile]
    public let revision: String
    fileprivate let snapshot: RevisionComparisonSnapshot
    fileprivate let base: Bool
}
public struct ComparisonFileExport: Sendable {
    public let paths: [String]
    fileprivate let snapshot: RevisionComparisonSnapshot
    fileprivate let folder: URL
    fileprivate let backend: GitLibGit2Configuration
}
extension GitRepository {
    private func checkedComparisonSelection(_ snapshot: RevisionComparisonSnapshot, files: [CommitFile], cancellation: OperationCancellation?) throws {
        try cancellation?.check()
        guard snapshot.root == root, !files.isEmpty, GitPathSet(files.map(\.path)).count == files.count,
              files.allSatisfy({ snapshot.files.contains($0) }) else { throw RevisionComparisonFailure.selection }
        for side in [snapshot.from, snapshot.to] {
            if case .revision(let hash) = side {
                guard [40,64].contains(hash.count), hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw RevisionComparisonFailure.range }
            }
        }
        for file in files { _ = try restoreLocation(file.path); if let old=file.oldPath { _ = try restoreLocation(old) } }
    }
    public func prepareComparisonRevertBatch(_ snapshot: RevisionComparisonSnapshot, files: [CommitFile], base: Bool, cancellation: OperationCancellation? = nil) throws -> ComparisonRevertBatch {
        try checkedComparisonSelection(snapshot, files: files, cancellation: cancellation)
        guard try !isBare(cancellation: cancellation) else { throw RevisionComparisonFailure.selection }
        // This map deliberately compares local destination names, not Git IDs.
        // Multiple exact index removals can share a local alias; a restore that
        // writes bytes must never collide with another selected local action.
        var destinations: [String:Bool] = [:]
        for file in files {
            let path = base && file.action.hasPrefix("R") ? file.oldPath ?? file.path:file.path
            let destination = root.appendingPathComponent(path).standardizedFileURL.path
            let writes = !(base ? file.action.hasPrefix("A"):file.action.hasPrefix("D"))
            if let previousWrites = destinations[destination], previousWrites || writes { throw RevisionComparisonFailure.localPathCollision }
            destinations[destination] = writes
        }
        let revision: String
        switch base ? snapshot.from : snapshot.to {
        case .workingTree: throw RevisionComparisonFailure.selection
        case .revision(let hash): revision = hash
        case .emptyTree:
            revision = String(decoding: try run(["mktree"], cancellation: cancellation).stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
            guard [40, 64].contains(revision.count), revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw RevisionComparisonFailure.range }
        }
        return ComparisonRevertBatch(files: files, revision: revision, snapshot: snapshot, base: base)
    }
    public func prepareComparisonRevertFile(_ batch: ComparisonRevertBatch, file: CommitFile, cancellation: OperationCancellation? = nil) throws -> ComparisonFileRevert {
        try cancellation?.check()
        let snapshot = batch.snapshot, base = batch.base, revision = batch.revision
        guard snapshot.root == root, batch.files.contains(file) else { throw RevisionComparisonFailure.selection }
        if snapshot.from == .workingTree || snapshot.to == .workingTree {
            let fresh = try revisionComparison(from: snapshot.from, to: snapshot.to, options: snapshot.options, cancellation: cancellation, paths: snapshot.scopePaths)
            guard fresh.files.contains(where: { GitReferenceName.equal($0.path,file.path) && $0.oldPath.map({GitReferenceName($0)}) == file.oldPath.map({GitReferenceName($0)}) && $0.action == file.action && $0.isSubmodule == file.isSubmodule }) else { throw WorkingFileRestoreFailure.changed }
        }
        let added=file.action.hasPrefix("A"),deleted=file.action.hasPrefix("D"),renamed=file.action.hasPrefix("R")
        let unstage=base ? added : deleted
        let otherWorking=(base ? snapshot.to : snapshot.from) == .workingTree
        let path=base && renamed ? file.oldPath ?? file.path : file.path
        var removals:[(String,Bool)]=[]
        if unstage { removals.append((file.path,otherWorking)) }
        else {
            if renamed,otherWorking { removals.append((base ? file.path : file.oldPath ?? file.path,true)) }
            removals.append((path,false))
            // Validate the chosen tree entry before deleting or recycling anything.
            let records=try run(["-c","core.precomposeunicode=false","ls-tree","-z",revision,"--",path],cancellation:cancellation).stdout.split(separator:0)
            guard records.contains(where: { record in
                guard let tab=record.firstIndex(of:9),Data(record[record.index(after:tab)...])==Data(path.utf8) else { return false }
                let mode=String(decoding:record[..<tab],as:UTF8.self).split(separator:" ").first
                return ["100644","100755","120000","160000"].contains(mode.map(String.init) ?? "")
            }) else { throw RevisionComparisonFailure.selection }
        }
        for removal in removals { _ = try restoreLocation(removal.0) }
        return ComparisonFileRevert(path:path,revision:revision,root:root,unstage:unstage,ignoreUnmatched:base && added,submodule:file.isSubmodule,removals:removals)
    }
    public func prepareComparisonRevert(_ snapshot: RevisionComparisonSnapshot, files: [CommitFile], base: Bool, cancellation: OperationCancellation? = nil) throws -> [ComparisonFileRevert] {
        let batch = try prepareComparisonRevertBatch(snapshot, files: files, base: base, cancellation: cancellation)
        return try files.map { try prepareComparisonRevertFile(batch, file: $0, cancellation: cancellation) }
    }
    /// Recycle/remove + index/working-tree checkout is one protected step. Cancel
    /// is checked before it starts and between files, never halfway through it.
    public func revertComparisonFile(_ target: ComparisonFileRevert, recycle: Bool, cancellation: OperationCancellation? = nil) throws -> [URL] {
        try cancellation?.check()
        guard target.root==root,try !isBare(cancellation:cancellation) else { throw RevisionComparisonFailure.selection }
        _ = try restoreLocation(target.path)
        var trash:[URL]=[]
        do {
            for removal in target.removals {
                let url=try restoreLocation(removal.path)
                guard let type=(try? FileManager.default.attributesOfItem(atPath:url.path)[.type]) as? FileAttributeType else { continue }
                guard [.typeRegular,.typeSymbolicLink].contains(type) || target.submodule && type == .typeDirectory else { throw WorkingFileRestoreFailure.unsupported }
                guard removal.always || recycle && type != .typeDirectory else { continue }
                if recycle {
                    var moved:NSURL?;try FileManager.default.trashItem(at:url,resultingItemURL:&moved)
                    if let moved { trash.append(moved as URL) }
                } else { try FileManager.default.removeItem(at:url) }
            }
            if target.unstage { _ = try run(["-c","core.precomposeunicode=false","rm","--cached"] + (target.ignoreUnmatched ? ["--ignore-unmatch"] : []) + ["--",target.path]) }
            else { _ = try run(["-c","core.precomposeunicode=false","checkout",target.revision,"--",target.path]) }
            return trash
        } catch { throw WorkingFileRevertFailure(gitError:error.localizedDescription,wasCancelled:false,trashedFiles:trash) }
    }
    public func prepareComparisonExport(_ snapshot: RevisionComparisonSnapshot, files: [CommitFile], to folder: URL, cancellation: OperationCancellation? = nil, backend: GitLibGit2Configuration? = nil) throws -> ComparisonFileExport {
        let backend = backend ?? libgit2Configuration ?? .load()
        try checkedComparisonSelection(snapshot,files:files,cancellation:cancellation)
        let folder=folder.standardizedFileURL.resolvingSymlinksInPath()
        guard try folder.resourceValues(forKeys:[.isDirectoryKey]).isDirectory==true,!folder.pathComponents.contains(where:{$0.caseInsensitiveCompare(".git") == .orderedSame}) else { throw WorkingFileExportFailure.location }
        let paths=files.filter{!$0.isSubmodule && !$0.action.hasPrefix("D")}.map(\.path)
        let destinations = paths.map { folder.appendingPathComponent($0).standardizedFileURL.path }
        guard Set(destinations).count == paths.count else { throw WorkingFileExportFailure.collision }
        let sources=try paths.map { try restoreLocation($0).resolvingSymlinksInPath().path }
        for path in paths {
            let destination=folder.appendingPathComponent(path).standardizedFileURL
            guard RepositoryAccessLease.pathIsContained(destination.deletingLastPathComponent(),by:folder),!destination.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents.contains(where:{$0.caseInsensitiveCompare(".git") == .orderedSame}) else { throw WorkingFileExportFailure.location }
            guard !sources.contains(destination.resolvingSymlinksInPath().path) else { throw WorkingFileExportFailure.source }
        }
        return ComparisonFileExport(paths:paths,snapshot:snapshot,folder:folder,backend:backend)
    }
    public func exportComparisonFile(_ export: ComparisonFileExport, path: String, cancellation: OperationCancellation? = nil) throws {
        try cancellation?.check()
        guard export.snapshot.root==root,GitPathSet(export.paths).contains(path) else { throw RevisionComparisonFailure.selection }
        let destination=export.folder.appendingPathComponent(path),parent=destination.deletingLastPathComponent()
        guard RepositoryAccessLease.pathIsContained(parent,by:export.folder),!parent.resolvingSymlinksInPath().pathComponents.contains(where:{$0.caseInsensitiveCompare(".git") == .orderedSame}) else { throw WorkingFileExportFailure.location }
        try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true)
        if export.snapshot.to == .workingTree { try saveWorkingFile(path:path,to:destination,cancellation:cancellation);return }
        guard case .revision(let revision) = export.snapshot.to else { throw RevisionComparisonFailure.selection }
        // FileDiffDlg exports Version 2 only; a missing Base blob cannot block it.
        let content=try materializedHistoricalFile(revision:revision,path:path,cancellation:cancellation,backend:export.backend)
        let temporary=parent.appendingPathComponent(".TurtleGitExport-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:temporary)}
        try content.bytes.write(to:temporary,options:.withoutOverwriting);try cancellation?.check()
        guard RepositoryAccessLease.pathIsContained(parent,by:export.folder),!parent.resolvingSymlinksInPath().pathComponents.contains(where:{$0.caseInsensitiveCompare(".git") == .orderedSame}) else { throw WorkingFileExportFailure.location }
        guard Darwin.rename(temporary.path,destination.path)==0 else { throw GitFailure(arguments:["export",path],code:1,message:String(cString:strerror(errno))) }
    }
}
