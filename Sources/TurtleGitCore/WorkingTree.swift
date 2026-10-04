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
    public func workingTreeStatus(refreshIndex: Bool = true) throws -> [WorkingTreeFile] {
        let changes = try status(refreshIndex: refreshIndex)
        var entries = Dictionary(changes.map { ($0.path, $0) }, uniquingKeysWith: { _, new in new })
        var flags: [String: (Bool, Bool)] = [:]
        for record in try run(["ls-files", "-v", "-z"]).stdout.split(separator: 0) {
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
        let head = try? run(["rev-parse", "--verify", "HEAD"])
        return try run(["diff", "--no-ext-diff", "--no-color"] + (head == nil ? ["--cached"] : ["HEAD"]) + ["--"] + paths).text
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
        guard !files.isEmpty, files.allSatisfy({ ![FileState.untracked, .ignored, .conflicted].contains($0.state) }) else { return false }
        switch self {
        case .skipWorktree: return files.allSatisfy { $0.state != .added && !$0.skipWorktree }
        case .assumeUnchanged: return files.allSatisfy { ![FileState.added, .deleted].contains($0.state) && !$0.assumeUnchanged }
        case .clear: return files.contains { $0.assumeUnchanged || $0.skipWorktree }
        }
    }
}

extension GitRepository {
    /// Change only index flags. Re-read eligibility before modifying the index.
    public func setIndexFlags(_ action: IndexFlagAction, paths: [String]) throws {
        let paths = Set(paths)
        let selected = try workingTreeStatus(refreshIndex: false).filter { paths.contains($0.id) }
        guard selected.count == paths.count, action.isAvailable(for: selected) else {
            throw GitFailure(arguments: ["update-index"], code: 1, message: "The selected files changed or cannot use this index flag action. Refresh and select versioned files.")
        }
        let arguments: [String]
        switch action {
        case .skipWorktree: arguments = ["--skip-worktree"]
        case .assumeUnchanged: arguments = ["--assume-unchanged"]
        case .clear:
            try clearIndexFlags(paths.sorted())
            return
        }
        _ = try run(["update-index"] + arguments + ["--"] + paths.sorted())
    }
    private func clearIndexFlags(_ paths: [String]) throws {
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
        // Git accepts only one flag mode per invocation. Both writes target our
        // private locked index; the real index remains intact if either fails.
        let environment = ["GIT_INDEX_FILE": lock.path]
        _ = try run(["update-index", "--no-assume-unchanged", "--"] + paths, environmentOverrides: environment)
        _ = try run(["update-index", "--no-skip-worktree", "--"] + paths, environmentOverrides: environment)
        let attributes = try FileManager.default.attributesOfItem(atPath: index.path)
        if let permissions = attributes[.posixPermissions] { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: lock.path) }
        guard Darwin.rename(lock.path, index.path) == 0 else {
            throw GitFailure(arguments: ["update-index"], code: 1, message: "Could not replace the Git index: " + String(cString: strerror(errno)))
        }
    }

}
