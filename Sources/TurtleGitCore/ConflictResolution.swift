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
}
public enum ResolveChoice: Int, Sendable { case current = 0, mine = 2, theirs = 3 }
public enum ResolveFailure: LocalizedError {
    case selection, outsideWorkingTree, stale, indexFormat, submoduleCheckout(String)
    public var errorDescription: String? {
        switch self {
        case .selection: return "Check at least one conflicted file to resolve."
        case .outsideWorkingTree: return "Resolve selections must stay inside this working tree, outside Git’s administrative directories."
        case .stale: return "The conflict stages have changed. Refresh the conflict list before resolving."
        case .indexFormat: return "Git returned an invalid conflict-stage record."
        case .submoduleCheckout(let path): return "The selected submodule commit differs from its current checkout: \(path). Check out that commit in the submodule before resolving this conflict."
        }
    }
}
extension GitRepository {
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
    public func conflictIsRebase() throws -> Bool {
        for name in ["rebase-merge", "rebase-apply"] {
            var bytes = try run(["rev-parse", "--git-path", name]).stdout
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
    public func resolveConflicts(_ checked: [ConflictEntry], using choice: ResolveChoice) throws -> String {
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
        var output: [String] = []
        for entry in checked {
            if choice == .current {
                output.append(try run(["add", "-f", "--", entry.path]).text)
            } else if let destination = entry.stages.first(where: { $0.number == choice.rawValue }) {
                if destination.mode == "160000" {
                    output.append(try run(["update-index", "--replace", "--cacheinfo", "160000," + destination.object + "," + entry.path]).text)
                } else {
                    output.append(try run(["checkout-index", "-f", "--stage=" + String(choice.rawValue), "--", entry.path]).text)
                    output.append(try run(["add", "-f", "--", entry.path]).text)
                }
            } else {
                // A missing selected stage means that side deleted the path.
                output.append(try run(["rm", "-f", "--", entry.path]).text)
            }
            output.append("Resolved: " + entry.path)
        }
        return output.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
