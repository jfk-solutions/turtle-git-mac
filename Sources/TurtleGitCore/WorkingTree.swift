import Foundation
import Darwin

public struct WorkingTreeFile: Identifiable, Sendable {
    public var id: String { entry.path }
    public let entry: StatusEntry
    public let assumeUnchanged: Bool
    public let skipWorktree: Bool
    public let modificationDate: Date?
    public var state: FileState { entry.index == " " && entry.worktree == " " ? .normal : entry.state }
    public var status: String {
        if skipWorktree { return "Skip-worktree" }
        if assumeUnchanged { return "Assume unchanged" }
        if entry.index == "R" || entry.worktree == "R" { return "Renamed" }
        return state.rawValue.capitalized
    }
}

public struct WorkingTreeFilter: Equatable, Sendable {
    public var paths: [String] = []
    public var wholeProject = true
    public var showUnversioned = true
    public var showIgnored = false
    public var showUnmodified = false
    public var showLocalChangesIgnored = false
    public var showAllStaged = true
    public init() {}
    public func includes(_ file: WorkingTreeFile) -> Bool {
        let scoped = wholeProject || paths.isEmpty || paths.contains { $0 == "." || file.id == $0 || file.id.hasPrefix($0 + "/") }
        guard scoped || showAllStaged && file.entry.staged else { return false }
        if file.assumeUnchanged || file.skipWorktree { return showLocalChangesIgnored }
        switch file.state {
        case .normal: return showUnmodified
        case .untracked: return showUnversioned
        case .ignored: return showIgnored
        default: return true
        }
    }
}

extension GitRepository {
    public func workingTreeStatus(refreshIndex: Bool = true, cancellation: OperationCancellation? = nil) throws -> [WorkingTreeFile] {
        try cancellation?.check()
        let changes = try status(refreshIndex: refreshIndex, cancellation: cancellation)
        var entries = Dictionary(changes.map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
        var flags: [String: (Bool, Bool)] = [:]
        for record in try run(["ls-files", "-v", "-z"], cancellation: cancellation).stdout.split(separator: 0) {
            guard record.count >= 3 else { continue }
            let bytes = Array(record), path = String(decoding: bytes.dropFirst(2), as: UTF8.self)
            let code = bytes[0]
            flags[path] = (code >= 97 && code <= 122, code == 83 || code == 115)
            if entries[path] == nil { entries[path] = StatusEntry(path: path, originalPath: nil, index: " ", worktree: " ") }
        }
        return entries.values.map { entry in
            let date = (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(entry.path).path)[.modificationDate]) as? Date
            return WorkingTreeFile(entry: entry, assumeUnchanged: flags[entry.path]?.0 ?? false, skipWorktree: flags[entry.path]?.1 ?? false, modificationDate: date)
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
    public func workingTreeDiff(paths: [String]) throws -> String {
        String(decoding: try workingTreeDiffData(paths: paths), as: UTF8.self)
    }
    public func workingTreeDiffData(paths: [String]) throws -> Data {
        let head = try? run(["rev-parse", "--verify", "HEAD"])
        return try run(["diff", "--no-ext-diff", "--no-color"] + (head == nil ? ["--cached"] : ["HEAD"]) + ["--"] + paths).stdout
    }
}

public enum IndexFlagAction: String, CaseIterable, Sendable {
    case skipWorktree = "Skip worktree"
    case assumeUnchanged = "Assume Unchanged"
    case clear = "Unflag as skip-worktree and assume-unchanged"
    public var confirmation: String {
        switch self {
        case .skipWorktree: return "Do you really want to mark the selected file(s) as skip-worktree?"
        case .assumeUnchanged: return "Do you really want to mark the selected file(s) as assume-valid?"
        case .clear: return "Do you really want to unflag the selected file(s) as skip-worktree or assume-unchanged?"
        }
    }
    public func isAvailable(for files: [WorkingTreeFile]) -> Bool {
        guard !files.isEmpty, files.allSatisfy({ ![FileState.untracked, .ignored, .conflicted].contains($0.state) && !$0.entry.hasUnversionedCopy }) else { return false }
        switch self {
        case .skipWorktree: return files.allSatisfy { $0.entry.index != "A" && $0.entry.worktree != "A" && !$0.skipWorktree }
        case .assumeUnchanged: return files.allSatisfy { ![$0.entry.index, $0.entry.worktree].contains(where: { $0 == "A" || $0 == "D" }) && !$0.assumeUnchanged }
        case .clear: return files.contains { $0.assumeUnchanged || $0.skipWorktree }
        }
    }
}

public struct IndexFlagPartialFailure: LocalizedError, Sendable {
    public let updatedPaths: [String]
    public let unavailablePaths: [String]
    public var errorDescription: String? {
        "Index flags updated for \(updatedPaths.count) selected file(s). The following selected paths have no stage-zero index entry and could not be updated:\n" + unavailablePaths.joined(separator: "\n")
    }
}

extension GitRepository {
    /// Change only flags in a private locked index. A status-list mark enables
    /// upstream mixed-selection behavior; missing stage-zero entries are reported
    /// after the remaining selected entries have been updated.
    public func setIndexFlags(_ action: IndexFlagAction, paths: [String], markedPath: String? = nil) throws {
        let paths = Set(paths)
        guard !paths.isEmpty else { throw RevisionComparisonFailure.selection }
        for path in paths { _ = try restoreLocation(path) }
        if let markedPath { _ = try restoreLocation(markedPath) }
        var indexBytes = try run(["rev-parse", "--git-path", "index"]).stdout
        if indexBytes.last == 10 { indexBytes.removeLast() }
        let indexPath = String(decoding: indexBytes, as: UTF8.self)
        let index = indexPath.hasPrefix("/") ? URL(fileURLWithPath: indexPath) : root.appendingPathComponent(indexPath)
        let lock = URL(fileURLWithPath: index.path + ".lock")
        let descriptor = open(lock.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            throw GitFailure(arguments: ["update-index"], code: 1, message: "Could not lock the Git index: " + String(cString: strerror(errno)))
        }
        defer { try? FileManager.default.removeItem(at: lock) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do { try handle.write(contentsOf: Data(contentsOf: index)); try handle.close() }
        catch { try? handle.close(); throw error }
        let current = try workingTreeStatus(refreshIndex: false)
        let selected = current.filter { paths.contains($0.id) }
        let gate = markedPath.map { mark in current.filter { $0.id == mark } } ?? selected
        guard (markedPath != nil || selected.count == paths.count), action.isAvailable(for: gate) else {
            throw GitFailure(arguments: ["update-index"], code: 1, message: "The selected files changed or cannot use this index flag action. Refresh and select versioned files.")
        }
        // libgit2's upstream action looks up every selected path independently.
        // Preserve that behavior for an eligible mark, including idempotent flags
        // and added files, while reporting paths lacking a stage-zero entry.
        var indexed = Set<String>()
        for record in try run(["ls-files", "--stage", "-z"]).stdout.split(separator: 0) {
            guard let tab = record.firstIndex(of: 9) else { continue }
            let header = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
            if header.last == "0" { indexed.insert(String(decoding: record[record.index(after: tab)...], as: UTF8.self)) }
        }
        let targets = paths.intersection(indexed).sorted()
        let missing = paths.subtracting(indexed).sorted()
        guard !targets.isEmpty else { throw IndexFlagPartialFailure(updatedPaths: [], unavailablePaths: missing) }
        let environment = ["GIT_INDEX_FILE": lock.path]
        let arguments: [[String]]
        switch action {
        case .skipWorktree: arguments = [["--skip-worktree"]]
        case .assumeUnchanged: arguments = [["--assume-unchanged"]]
        case .clear: arguments = [["--no-assume-unchanged"], ["--no-skip-worktree"]]
        }
        for flags in arguments {
            _ = try run(["update-index"] + flags + ["--"] + targets, environmentOverrides: environment)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: index.path)
        if let permissions = attributes[.posixPermissions] { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: lock.path) }
        guard Darwin.rename(lock.path, index.path) == 0 else {
            throw GitFailure(arguments: ["update-index"], code: 1, message: "Could not replace the Git index: " + String(cString: strerror(errno)))
        }
        if !missing.isEmpty {
            throw IndexFlagPartialFailure(updatedPaths: targets, unavailablePaths: missing)
        }
    }

}
