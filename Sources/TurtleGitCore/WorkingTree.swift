import Foundation

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
    public func workingTreeStatus() throws -> [WorkingTreeFile] {
        let changes = try status()
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
