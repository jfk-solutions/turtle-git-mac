import Foundation

public struct LFSLock: Identifiable, Equatable, Sendable {
    public let id: String
    public let path: String
    public let owner: String
    public init(id: String, path: String, owner: String) { self.id = id; self.path = path; self.owner = owner }
    /// git-lfs locks --json emits an array, not the locking HTTP API envelope.
    public static func parse(_ data: Data) throws -> [Self] {
        guard !data.isEmpty else { return [] }
        struct Record: Decodable {
            struct Owner: Decodable { let name: String }
            let id: String; let path: String; let owner: Owner
            enum CodingKeys: String, CodingKey { case id, path, owner }
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .id)
                if id.isEmpty { path = ""; owner = Owner(name: "") }
                else { path = try container.decode(String.self, forKey: .path); owner = try container.decode(Owner.self, forKey: .owner) }
            }
        }
        return try JSONDecoder().decode([Record].self, from: data).filter { !$0.id.isEmpty }.map { Self(id: $0.id, path: $0.path, owner: $0.owner.name) }
    }
}
public struct LFSFileResult: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let success: Bool
    public let output: String
    public init(path: String, success: Bool, output: String) { self.path = path; self.success = success; self.output = output }
}
public struct LFSBatchResult: Equatable, Sendable {
    public let files: [LFSFileResult]
    public let cancelled: Bool
    public init(files: [LFSFileResult], cancelled: Bool = false) { self.files = files; self.cancelled = cancelled }
}
public enum LFSLocksFailure: LocalizedError {
    case selection, directory
    public var errorDescription: String? {
        switch self {
        case .selection: return "Select files from this repository for Git LFS locking."
        case .directory: return "Git LFS locks apply to files, not folders."
        }
    }
}
extension GitRepository {
    public func hasLFS() throws -> Bool {
        var bytes = try run(["rev-parse", "--git-common-dir"]).stdout
        if bytes.last == 10 { bytes.removeLast() }
        let value = String(decoding: bytes, as: UTF8.self)
        let directory = value.hasPrefix("/") ? URL(fileURLWithPath: value) : root.appendingPathComponent(value)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("lfs").path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    public func lfsLocks(cancellation: OperationCancellation? = nil) throws -> [LFSLock] {
        try LFSLock.parse(run(["lfs", "locks", "--json"], cancellation: cancellation).stdout)
    }
    /// Validate every literal target before contacting the server. Like upstream,
    /// individual command failures are reported and do not stop subsequent files.
    /// Cancellation cannot roll back server-side locks already changed.
    public func setLFSLocked(paths: [String], locked: Bool, force: Bool = false, cancellation: OperationCancellation? = nil, onResult: (@Sendable (LFSFileResult) -> Void)? = nil) throws -> LFSBatchResult {
        if cancellation?.isCancelled == true { return LFSBatchResult(files: [], cancelled: true) }
        guard !paths.isEmpty, try !isBare() else { throw LFSLocksFailure.selection }
        var seen = Set<String>(), targets: [String] = []
        for path in paths where seen.insert(path).inserted {
            let location = try restoreLocation(path)
            if let type = try? FileManager.default.attributesOfItem(atPath: location.path)[.type] as? FileAttributeType, type == .typeDirectory { throw LFSLocksFailure.directory }
            targets.append(path)
        }
        var files: [LFSFileResult] = []
        for path in targets {
            if cancellation?.isCancelled == true { return LFSBatchResult(files: files, cancelled: true) }
            var arguments = ["lfs", locked ? "lock" : "unlock"]
            if force && !locked { arguments.append("--force") }
            arguments += ["--", path]
            do {
                let result = try run(arguments, cancellation: cancellation)
                let file = LFSFileResult(path: path, success: true, output: result.text)
                files.append(file); onResult?(file)
            } catch {
                let file = LFSFileResult(path: path, success: false, output: error.localizedDescription)
                files.append(file); onResult?(file)
                if cancellation?.isCancelled == true { return LFSBatchResult(files: files, cancelled: true) }
            }
        }
        return LFSBatchResult(files: files, cancelled: cancellation?.isCancelled == true)
    }
}

public enum LFSLockMenuAction: String, CaseIterable, Sendable {
    case lock = "LFS Lock", unlock = "LFS Unlock"
}

/// Upstream AppendLocksMenuItems: hidden ownership offers both operations;
/// visible ownership offers one operation only for a uniformly locked selection.
public enum LFSLockMenu {
    public static func actions(paths: [String], ownersVisible: Bool, lockedPaths: Set<String>, ownershipKnown: Bool) -> [LFSLockMenuAction] {
        guard !paths.isEmpty else { return [] }
        if !ownersVisible { return [.lock, .unlock] }
        guard ownershipKnown else { return [] }
        let locked = paths.filter { lockedPaths.contains($0) }.count
        if locked == 0 { return [.lock] }
        if locked == paths.count { return [.unlock] }
        return []
    }
}
