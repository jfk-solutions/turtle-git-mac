import Foundation
import Darwin

public struct ConflictStage: Hashable, Sendable {
    public let number: Int
    public let mode: String
    public let object: String
}
public struct ConflictEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let stages: [ConflictStage]
    public static func == (lhs: Self, rhs: Self) -> Bool { GitReferenceName.equal(lhs.path, rhs.path) && lhs.stages == rhs.stages }
    public func hash(into hasher: inout Hasher) { hasher.combine(GitReferenceName(path)); hasher.combine(stages) }
    public var isSubmodule: Bool { stages.contains { $0.mode == "160000" } }
    public var isDeleteModify: Bool { !isSubmodule && stages.contains(where: { $0.number == 2 }) != stages.contains(where: { $0.number == 3 }) }
}
public struct ConflictResolutionProgress: Sendable {
    public let path: String
    public let completed: Int
    public let total: Int
    public let finished: Bool
    public let skipped: Bool
    public init(path:String,completed:Int,total:Int,finished:Bool,skipped:Bool=false) {
        self.path=path;self.completed=completed;self.total=total;self.finished=finished;self.skipped=skipped
    }
}
public enum ResolveChoice: Int, Sendable { case current = 0, mine = 2, theirs = 3 }
public enum ResolveFailure: LocalizedError {
    case selection, outsideWorkingTree, stale, indexFormat, cancelled, submoduleCheckout(String)
    public var errorDescription: String? {
        switch self {
        case .cancelled: return "Resolution aborted. Earlier resolved items remain resolved."
        case .selection: return "Check at least one conflicted file to resolve."
        case .outsideWorkingTree: return "Resolve selections must stay inside this working tree, outside Git’s administrative directories."
        case .stale: return "The conflict stages have changed. Refresh the conflict list before resolving."
        case .indexFormat: return "Git returned an invalid conflict-stage record."
        case .submoduleCheckout(let path): return "The selected submodule commit differs from its current checkout: \(path). Check out that commit in the submodule before resolving this conflict."
        }
    }
}
public struct SubmoduleDeletionRequest: Sendable {
    public let path: String
    public let location: URL
    public let gitError: String
}
public struct SubmoduleDeletionFailure: LocalizedError, Sendable {
    public let path: String
    public let trashedLocation: URL?
    public let gitError: String
    public var errorDescription: String? {
        "The folder “\(path)” was moved to Trash, but Git could not resolve its deletion. " +
        (trashedLocation.map { "Recoverable folder: " + $0.path + "\n" } ?? "") + gitError
    }
}
extension GitRepository {
    /// A conflicted gitlink belongs to the containing repository even when its
    /// initialized checkout is itself a repository. Files inside that checkout
    /// continue to use the child repository.
    public func discoverSelectionRoot(for action: RepositoryAction, selected: URL, cancellation: OperationCancellation? = nil) async throws -> URL {
        let resolved = try discoverRoot(cancellation: cancellation)
        // Finder/CLI selections preserve literal paths and may have been made
        // before a directory existed. URL equality also compares its directory
        // bit; repository ownership depends on the normalized exact path.
        func sameLocation(_ lhs: URL, _ rhs: URL) -> Bool {
            GitReferenceName.equal(lhs.standardizedFileURL.path, rhs.standardizedFileURL.path)
        }
        if action == .logSubmodule {
            guard sameLocation(selected, resolved),
                  let parent = try await GitRepository(root: resolved, executable: executable).registeredSubmoduleParent(cancellation: cancellation) else { throw FinderCommandFailure.submodule }
            return parent
        }
        guard action.isResolve || action == .revert || action == .submoduleUpdate || action == .submoduleSync || action == .diff || action == .rename || action == .move || action == .remove, sameLocation(selected, resolved) else { return resolved }
        let parent = GitRepository(root: resolved.deletingLastPathComponent(), executable: executable)
        let parentRoot = try? await parent.discoverRoot(cancellation: cancellation)
        try cancellation?.check()
        guard let containing = parentRoot, !sameLocation(containing, resolved),
              RepositoryAccessLease.pathIsContained(resolved, by: containing) else { return resolved }
        let path = String(resolved.path.dropFirst(containing.path.count + 1))
        let owner = GitRepository(root: containing, executable: executable)
        if action == .rename || action == .move || action == .remove {
            guard let registered = try await GitRepository(root: resolved, executable: executable).registeredSubmoduleParent(cancellation: cancellation), sameLocation(registered, containing) else { return resolved }
        }
        if action == .revert || action == .submoduleUpdate || action == .submoduleSync || action == .diff || action == .rename || action == .move || action == .remove {
            let indexed = try? await owner.run(["ls-files", "--stage", "-z", "--", path], cancellation: cancellation).stdout
            try cancellation?.check()
            if indexed?.split(separator: 0).contains(where: { record in
                let fields = record.split(separator: 9, maxSplits: 1)
                return fields.count == 2 && fields[0].starts(with: "160000 ".utf8) && GitReferenceName.equal(String(decoding: fields[1], as: UTF8.self), path)
            }) == true { return containing }
            return resolved
        }
        if let entries = try? await owner.conflicts(paths: [path], cancellation: cancellation), entries.contains(where: { GitReferenceName.equal($0.path, path) && $0.isSubmodule }) { return containing }
        try cancellation?.check()
        return resolved
    }
    /// Retain the captured conflict order while obtaining real porcelain rows
    /// for shared Revert/Delete. Status reads do not refresh the index here.
    public func conflictWorkingFileSelection(_ selected:[ConflictEntry],cancellation:OperationCancellation? = nil)throws->[StatusEntry] {
        try validateConflicts(selected,using:.current,cancellation:cancellation)
        let current = try status(refreshIndex:false,cancellation:cancellation)
        let rows = try selected.map {entry -> StatusEntry in
            guard let row = current.first(where:{$0.path.utf8.elementsEqual(entry.path.utf8)}),row.state == .conflicted else {throw ResolveFailure.stale}
            return row
        }
        try validateConflicts(selected,using:.current,cancellation:cancellation)
        return rows
    }
    public func conflicts(paths: [String] = [], cancellation: OperationCancellation? = nil) throws -> [ConflictEntry] {
        guard try !isBare(cancellation: cancellation) else { throw ResolveFailure.selection }
        let scope = paths.filter { $0 != "." }
        if !scope.isEmpty { do { _ = try RemovalRequest(paths: scope, keepLocal: true) } catch { throw ResolveFailure.outsideWorkingTree } }
        var entries = GitPathMap<[ConflictStage]>()
        for record in try run(["ls-files", "--unmerged", "-z"], cancellation: cancellation).stdout.split(separator: 0) {
            let fields = record.split(separator: 9, maxSplits: 1)
            guard fields.count == 2 else { throw ResolveFailure.indexFormat }
            let header = String(decoding: fields[0], as: UTF8.self).split(separator: " ")
            guard header.count == 3, let number = Int(header[2]), (1...3).contains(number),
                  ["100644", "100755", "120000", "160000"].contains(String(header[0])) else { throw ResolveFailure.indexFormat }
            let path = String(decoding: fields[1], as: UTF8.self)
            if paths.contains(".") || scope.isEmpty || scope.contains(where: { GitReferenceName.equal(path, $0) || path.utf8.starts(with: ($0 + "/").utf8) }) {
                var stages = entries[path] ?? []
                stages.append(ConflictStage(number: number, mode: String(header[0]), object: String(header[1]))); entries[path] = stages
            }
        }
        return entries.map { ConflictEntry(path: $0.key, stages: $0.value.sorted { $0.number < $1.number }) }.sorted { $0.path < $1.path || $0.path == $1.path && $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    }
    /// Silent ResolveCommand stages the original requested paths, not a newly
    /// enumerated conflict selection. Validate the whole batch before mutation.
    public func resolveCommandPaths(_ paths: [String], cancellation: OperationCancellation? = nil) throws -> [String] {
        try cancellation?.check()
        guard !paths.isEmpty, try !isBare(cancellation: cancellation) else { throw ResolveFailure.selection }
        var seen = GitPathSet(), result: [String] = []
        for path in paths where seen.insert(path).inserted {
            try cancellation?.check()
            if path != "." {
                do { _ = try RemovalRequest(paths: [path], keepLocal: true) } catch { throw ResolveFailure.outsideWorkingTree }
                let location = try restoreLocation(path)
                let parent = try CloneOptions.workingDirectory(for: location.deletingLastPathComponent())
                var bytes = try run(["-C", parent.path, "rev-parse", "--show-toplevel"], cancellation: cancellation).stdout
                if bytes.last == 10 { bytes.removeLast() }
                guard GitReferenceName.equal(URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path) else { throw ResolveFailure.outsideWorkingTree }
            }
            result.append(path)
        }
        return result
    }
    public func resolveCommandSilently(paths: [String], cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil, onProgress: (@Sendable (ConflictResolutionProgress) -> Void)? = nil) throws -> String {
        let selected = try resolveCommandPaths(paths, cancellation: cancellation)
        var output: [String] = []
        for (index, path) in selected.enumerated() {
            try cancellation?.check()
            // Recheck ownership before each mutation after an earlier Git child
            // returned. Cancellation/failure preserves earlier staged paths.
            _ = try resolveCommandPaths([path], cancellation: cancellation)
            onProgress?(.init(path: path, completed: index, total: selected.count, finished: false))
            output.append(try run(["add", "-f", "--pathspec-from-file=-", "--pathspec-file-nul"], cancellation: cancellation, input: literalPathPacket([path]), onOutput: onOutput).text)
            removeSourceMergeFiles(path)
            let message = "Resolved: " + path
            output.append(message); onOutput?(.init(stream: .stdout, data: Data((message + "\n").utf8)))
            onProgress?(.init(path: path, completed: index + 1, total: selected.count, finished: true))
        }
        return output.filter { !$0.isEmpty }.joined(separator: "\n")
    }
    /// Remove only the three source-side sibling files, without following a
    /// symlink or recursively deleting a directory. Other backups remain.
    func removeSourceMergeFiles(_ path: String) {
        guard path != ".", let file = try? restoreLocation(path) else { return }
        var directory: ObjCBool = false
        if FileManager.default.fileExists(atPath: file.path, isDirectory: &directory), directory.boolValue { return }
        let name = file.lastPathComponent
        let suffix = name.lastIndex(of: ".").map { String(name[$0...]) } ?? ""
        for side in ["LOCAL", "REMOTE", "BASE"] {
            let artifact = file.path + "." + side + suffix
            var info = stat()
            if lstat(artifact, &info) == 0, [S_IFREG, S_IFLNK].contains(info.st_mode & S_IFMT) { _ = unlink(artifact) }
        }
    }
    /// Native editor routing needs validated stages and filesystem ownership
    /// before selecting a specialized editor or preparing external tool inputs.
    public func conflictEditorEntry(path: String, cancellation: OperationCancellation? = nil) throws -> ConflictEntry {
        try cancellation?.check()
        guard let entry = try conflicts(paths: [path], cancellation: cancellation).first(where: { GitReferenceName.equal($0.path, path) }) else { throw ResolveFailure.stale }
        try validateConflicts([entry], using: .current, cancellation: cancellation)
        try cancellation?.check(); return entry
    }
    public func conflictIsRebase(cancellation: OperationCancellation? = nil) throws -> Bool {
        try cancellation?.check()
        for name in ["rebase-merge", "rebase-apply"] {
            var bytes = try run(["rev-parse", "--git-path", name], cancellation: cancellation).stdout
            if bytes.last == 10 { bytes.removeLast() }
            let path = String(decoding: bytes, as: UTF8.self)
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue { return true }
        }
        return false
    }
    /// Capture stages when populating the dialog and revalidate all checked rows
    /// before mutation. Resolving records the index result; it does not commit or
    /// continue a merge/rebase/cherry-pick automatically.
    public func resolveConflicts(_ checked: [ConflictEntry], using choice: ResolveChoice, confirmSubmoduleDeletion: (@Sendable (SubmoduleDeletionRequest) async -> Bool)? = nil, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil, onProgress: (@Sendable (ConflictResolutionProgress) -> Void)? = nil, backend:GitLibGit2Configuration?=nil) async throws -> String {
        let selectedBackend=backend ?? libgit2Configuration ?? .load()
        try cancellation?.check()
        try validateConflicts(checked, using: choice, cancellation: cancellation,backend:selectedBackend,allowMissing:choice != .current)
        var output: [String] = []
        func skip(_ entry:ConflictEntry,_ index:Int) {
            let message="Skip: "+entry.path
            output.append(message)
            onOutput?(GitOutputChunk(stream:.stdout,data:Data((message+"\n").utf8)))
            onProgress?(.init(path:entry.path,completed:index+1,total:checked.count,finished:true,skipped:true))
        }
        for (index, entry) in checked.enumerated() {
            try cancellation?.check()
            onProgress?(ConflictResolutionProgress(path: entry.path, completed: index, total: checked.count, finished: false))
            // Confirmation suspends this actor. Recheck every remaining item after
            // resumption, including the original index stages and path containment.
            let missing=try validateConflicts([entry], using: choice, cancellation: cancellation,backend:selectedBackend,allowMissing:choice != .current)
            if missing.contains(entry.path) {skip(entry,index);continue}
            if choice == .current {
                output.append(try run(["add", "-f", "--", entry.path], cancellation: cancellation, onOutput: onOutput).text)
            } else if let destination = entry.stages.first(where: { $0.number == choice.rawValue }) {
                if destination.mode == "160000" {
                    let location = root.appendingPathComponent(entry.path)
                    var directory: ObjCBool = false
                    if !FileManager.default.fileExists(atPath: location.path, isDirectory: &directory) || !directory.boolValue {
                        // Upstream checks out an uninitialized gitlink first. This
                        // replaces a conflicting file with the submodule directory.
                        output.append(try run(["checkout-index", "-f", "--stage=" + String(choice.rawValue), "--", entry.path], cancellation: cancellation, onOutput: onOutput).text)
                    }
                    output.append(try run(["update-index", "--replace", "--cacheinfo", "160000," + destination.object + "," + entry.path], cancellation: cancellation, onOutput: onOutput).text)
                } else {
                    output.append(try run(["checkout-index", "-f", "--stage=" + String(choice.rawValue), "--", entry.path], cancellation: cancellation, onOutput: onOutput).text)
                    output.append(try run(["add", "-f", "--", entry.path], cancellation: cancellation, onOutput: onOutput).text)
                }
            } else {
                // A missing selected stage means that side deleted the path.
                do { output.append(try run(["rm", "-f", "--", entry.path], cancellation: cancellation, onOutput: onOutput).text) }
                catch let failure as GitFailure {
                    try cancellation?.check()
                    let location = root.appendingPathComponent(entry.path)
                    var directory: ObjCBool = false
                    guard entry.isSubmodule,
                          FileManager.default.fileExists(atPath: location.path, isDirectory: &directory), directory.boolValue,
                          !(try FileManager.default.contentsOfDirectory(atPath: location.path)).isEmpty,
                          let confirmSubmoduleDeletion else { throw failure }
                    let request = SubmoduleDeletionRequest(path: entry.path, location: location, gitError: failure.localizedDescription)
                    let accepted = await confirmSubmoduleDeletion(request)
                    try cancellation?.check()
                    guard accepted else { throw ResolveFailure.cancelled }
                    let missing=try validateConflicts([entry], using: choice, cancellation: cancellation,backend:selectedBackend,allowMissing:true)
                    // The accepted destructive prompt belongs to the exact live
                    // conflict observed before suspension, not a later resolution.
                    guard !missing.contains(entry.path) else { throw ResolveFailure.stale }
                    // Move the complete checkout (including its .git directory) to
                    // macOS Trash, matching upstream's recycle-bin deletion.
                    guard (try FileManager.default.attributesOfItem(atPath: location.path)[.type]) as? FileAttributeType == .typeDirectory else { throw ResolveFailure.stale }
                    #if os(macOS)
                    var trashed: NSURL?
                    try cancellation?.check()
                    try FileManager.default.trashItem(at: location, resultingItemURL: &trashed)
                    if let path = trashed?.path { output.append("Moved to Trash: " + path) }
                    do { output.append(try run(["rm", "-f", "--", entry.path], cancellation: cancellation, onOutput: onOutput).text) }
                    catch { throw SubmoduleDeletionFailure(path: entry.path, trashedLocation: trashed as URL?, gitError: error.localizedDescription) }
                    #else
                    throw failure
                    #endif
                }
            }
            removeSourceMergeFiles(entry.path)
            let resolved = "Resolved: " + entry.path
            output.append(resolved)
            onOutput?(GitOutputChunk(stream: .stdout, data: Data((resolved + "\n").utf8)))
            onProgress?(ConflictResolutionProgress(path: entry.path, completed: index + 1, total: checked.count, finished: true))
        }
        return output.filter { !$0.isEmpty }.joined(separator: "\n")
    }
    @discardableResult
    func validateConflicts(_ checked: [ConflictEntry], using choice: ResolveChoice, cancellation: OperationCancellation? = nil,backend:GitLibGit2Configuration?=nil,allowMissing:Bool=false) throws -> GitPathSet {
        guard !checked.isEmpty, GitPathSet(checked.map(\.path)).count == checked.count else { throw ResolveFailure.selection }
        guard try !isBare(cancellation:cancellation) else {throw ResolveFailure.selection}
        let rows:[ConflictEntry]
        if choice != .current && allowMissing {rows=try requestedConflictStages(paths:checked.map(\.path),backend:backend ?? libgit2Configuration ?? .load(),cancellation:cancellation)}
        else {rows=try conflicts(cancellation:cancellation)}
        let current = GitPathMap(rows.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        var missing=GitPathSet()
        for entry in checked {
            try cancellation?.check()
            do { _ = try RemovalRequest(paths: [entry.path], keepLocal: true) } catch { throw ResolveFailure.outsideWorkingTree }
            guard let actual=current[entry.path],!actual.stages.isEmpty else {
                if allowMissing && choice != .current {missing.insert(entry.path);continue}
                throw ResolveFailure.stale
            }
            guard actual == entry else {throw ResolveFailure.stale}
            let parent = root.appendingPathComponent(entry.path).deletingLastPathComponent()
            guard RepositoryAccessLease.pathIsContained(parent, by: root) else { throw ResolveFailure.outsideWorkingTree }
            let existing = try CloneOptions.workingDirectory(for: parent)
            var bytes = try run(["-C", existing.path, "rev-parse", "--show-toplevel"], cancellation: cancellation).stdout
            if bytes.last == 10 { bytes.removeLast() }
            guard URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path else { throw ResolveFailure.outsideWorkingTree }
            if entry.isSubmodule && !RepositoryAccessLease.pathIsContained(root.appendingPathComponent(entry.path), by: root) { throw ResolveFailure.outsideWorkingTree }
            if let destination = entry.stages.first(where: { $0.number == choice.rawValue }), destination.mode == "160000" {
                let url = root.appendingPathComponent(entry.path)
                if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                    let head = try run(["-C", url.path, "rev-parse", "--verify", "HEAD"], cancellation: cancellation).text.trimmingCharacters(in: .newlines)
                    guard head == destination.object else { throw ResolveFailure.submoduleCheckout(entry.path) }
                }
            }
        }
        return missing
    }
}
