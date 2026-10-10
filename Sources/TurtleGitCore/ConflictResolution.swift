import Foundation

public struct ConflictStage: Hashable, Sendable {
    public let number: Int
    public let mode: String
    public let object: String
}
public struct ConflictEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let stages: [ConflictStage]
    public var isSubmodule: Bool { stages.contains { $0.mode == "160000" } }
    public var isDeleteModify: Bool { !isSubmodule && stages.contains(where: { $0.number == 2 }) != stages.contains(where: { $0.number == 3 }) }
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
    public func discoverSelectionRoot(for action: RepositoryAction, selected: URL) async throws -> URL {
        let resolved = try discoverRoot()
        guard action.isResolve || action == .revert || action == .submoduleUpdate || action == .submoduleSync || action == .diff || action == .rename || action == .remove, selected.standardizedFileURL == resolved else { return resolved }
        let parent = GitRepository(root: resolved.deletingLastPathComponent(), executable: executable)
        guard let containing = try? await parent.discoverRoot(), containing != resolved,
              RepositoryAccessLease.pathIsContained(resolved, by: containing) else { return resolved }
        let path = String(resolved.path.dropFirst(containing.path.count + 1))
        let owner = GitRepository(root: containing, executable: executable)
        if action == .rename || action == .remove {
            guard try await GitRepository(root: resolved, executable: executable).registeredSubmoduleParent() == containing else { return resolved }
        }
        if action == .revert || action == .submoduleUpdate || action == .submoduleSync || action == .diff || action == .rename || action == .remove {
            let indexed = try? await owner.run(["ls-files", "--stage", "-z", "--", path]).stdout
            if indexed?.split(separator: 0).contains(where: { record in
                let fields = record.split(separator: 9, maxSplits: 1)
                return fields.count == 2 && fields[0].starts(with: "160000 ".utf8) && String(decoding: fields[1], as: UTF8.self) == path
            }) == true { return containing }
            return resolved
        }
        if let entries = try? await owner.conflicts(paths: [path]), entries.contains(where: { $0.path == path && $0.isSubmodule }) { return containing }
        return resolved
    }
    public func conflicts(paths: [String] = []) throws -> [ConflictEntry] {
        guard try !isBare() else { throw ResolveFailure.selection }
        let scope = paths.filter { $0 != "." }
        if !scope.isEmpty { do { _ = try RemovalRequest(paths: scope, keepLocal: true) } catch { throw ResolveFailure.outsideWorkingTree } }
        var entries: [String: [ConflictStage]] = [:]
        for record in try run(["ls-files", "--unmerged", "-z"]).stdout.split(separator: 0) {
            let fields = record.split(separator: 9, maxSplits: 1)
            guard fields.count == 2 else { throw ResolveFailure.indexFormat }
            let header = String(decoding: fields[0], as: UTF8.self).split(separator: " ")
            guard header.count == 3, let number = Int(header[2]), (1...3).contains(number),
                  ["100644", "100755", "120000", "160000"].contains(String(header[0])) else { throw ResolveFailure.indexFormat }
            let path = String(decoding: fields[1], as: UTF8.self)
            if paths.contains(".") || scope.isEmpty || scope.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                entries[path, default: []].append(ConflictStage(number: number, mode: String(header[0]), object: String(header[1])))
            }
        }
        return entries.map { ConflictEntry(path: $0.key, stages: $0.value.sorted { $0.number < $1.number }) }.sorted { $0.path < $1.path }
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
    public func resolveConflicts(_ checked: [ConflictEntry], using choice: ResolveChoice, confirmSubmoduleDeletion: (@Sendable (SubmoduleDeletionRequest) async -> Bool)? = nil) async throws -> String {
        try validateConflicts(checked, using: choice)
        var output: [String] = []
        for entry in checked {
            // Confirmation suspends this actor. Recheck every remaining item after
            // resumption, including the original index stages and path containment.
            try validateConflicts([entry], using: choice)
            if choice == .current {
                output.append(try run(["add", "-f", "--", entry.path]).text)
            } else if let destination = entry.stages.first(where: { $0.number == choice.rawValue }) {
                if destination.mode == "160000" {
                    let location = root.appendingPathComponent(entry.path)
                    var directory: ObjCBool = false
                    if !FileManager.default.fileExists(atPath: location.path, isDirectory: &directory) || !directory.boolValue {
                        // Upstream checks out an uninitialized gitlink first. This
                        // replaces a conflicting file with the submodule directory.
                        output.append(try run(["checkout-index", "-f", "--stage=" + String(choice.rawValue), "--", entry.path]).text)
                    }
                    output.append(try run(["update-index", "--replace", "--cacheinfo", "160000," + destination.object + "," + entry.path]).text)
                } else {
                    output.append(try run(["checkout-index", "-f", "--stage=" + String(choice.rawValue), "--", entry.path]).text)
                    output.append(try run(["add", "-f", "--", entry.path]).text)
                }
            } else {
                // A missing selected stage means that side deleted the path.
                do { output.append(try run(["rm", "-f", "--", entry.path]).text) }
                catch let failure as GitFailure {
                    let location = root.appendingPathComponent(entry.path)
                    var directory: ObjCBool = false
                    guard entry.isSubmodule,
                          FileManager.default.fileExists(atPath: location.path, isDirectory: &directory), directory.boolValue,
                          !(try FileManager.default.contentsOfDirectory(atPath: location.path)).isEmpty,
                          let confirmSubmoduleDeletion else { throw failure }
                    let request = SubmoduleDeletionRequest(path: entry.path, location: location, gitError: failure.localizedDescription)
                    guard await confirmSubmoduleDeletion(request) else { throw ResolveFailure.cancelled }
                    try validateConflicts([entry], using: choice)
                    // Move the complete checkout (including its .git directory) to
                    // macOS Trash, matching upstream's recycle-bin deletion.
                    guard (try FileManager.default.attributesOfItem(atPath: location.path)[.type]) as? FileAttributeType == .typeDirectory else { throw ResolveFailure.stale }
                    #if os(macOS)
                    var trashed: NSURL?
                    try FileManager.default.trashItem(at: location, resultingItemURL: &trashed)
                    if let path = trashed?.path { output.append("Moved to Trash: " + path) }
                    do { output.append(try run(["rm", "-f", "--", entry.path]).text) }
                    catch { throw SubmoduleDeletionFailure(path: entry.path, trashedLocation: trashed as URL?, gitError: error.localizedDescription) }
                    #else
                    throw failure
                    #endif
                }
            }
            output.append("Resolved: " + entry.path)
        }
        return output.filter { !$0.isEmpty }.joined(separator: "\n")
    }
    func validateConflicts(_ checked: [ConflictEntry], using choice: ResolveChoice) throws {
        guard !checked.isEmpty, Set(checked.map(\.path)).count == checked.count else { throw ResolveFailure.selection }
        let current = Dictionary(try conflicts().map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
        for entry in checked {
            do { _ = try RemovalRequest(paths: [entry.path], keepLocal: true) } catch { throw ResolveFailure.outsideWorkingTree }
            guard current[entry.path] == entry else { throw ResolveFailure.stale }
            let parent = root.appendingPathComponent(entry.path).deletingLastPathComponent()
            guard RepositoryAccessLease.pathIsContained(parent, by: root) else { throw ResolveFailure.outsideWorkingTree }
            let existing = try CloneOptions.workingDirectory(for: parent)
            var bytes = try run(["-C", existing.path, "rev-parse", "--show-toplevel"]).stdout
            if bytes.last == 10 { bytes.removeLast() }
            guard URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true).standardizedFileURL == root else { throw ResolveFailure.outsideWorkingTree }
            if entry.isSubmodule && !RepositoryAccessLease.pathIsContained(root.appendingPathComponent(entry.path), by: root) { throw ResolveFailure.outsideWorkingTree }
            if let destination = entry.stages.first(where: { $0.number == choice.rawValue }), destination.mode == "160000" {
                let url = root.appendingPathComponent(entry.path)
                if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                    let head = try run(["-C", url.path, "rev-parse", "--verify", "HEAD"]).text.trimmingCharacters(in: .newlines)
                    guard head == destination.object else { throw ResolveFailure.submoduleCheckout(entry.path) }
                }
            }
        }
    }
}
