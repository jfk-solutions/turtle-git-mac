// Native adaptation of TortoiseGit AppUtils.cpp BisectStart/BisectOperation.
// See NOTICE and LICENSE for upstream attribution and GPL licensing.
import Foundation

public enum BisectOperation: String, CaseIterable, Sendable { case good, bad, skip, reset }
public struct BisectState: Sendable {
    public let active: Bool
    public let originalRevision: String
    public let head: String
    public let goodTerm: String
    public let badTerm: String
    public let log: String
    /// Git 2.55 quotes the bad term in completion records; older versions do not.
    public var firstBadCommit: String? {
        let prefixes = ["# first " + badTerm + " commit: [", "# first '" + badTerm + "' commit: ["]
        for line in log.split(separator: "\n").reversed() {
            for prefix in prefixes where line.hasPrefix(prefix) {
                let suffix = line.dropFirst(prefix.count)
                guard let end = suffix.firstIndex(of: "]") else { continue }
                let hash = String(suffix[..<end])
                if [40, 64].contains(hash.count), hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) { return hash }
            }
        }
        return nil
    }
}
public struct BisectExecution: Sendable {
    public let output: String
    public let exitCode: Int32
    public let state: BisectState
}
public enum BisectFailure: LocalizedError {
    case workingTree, active, inactive, revision, dirty, operation
    public var errorDescription: String? {
        switch self {
        case .workingTree: return "Bisect requires a working tree."
        case .active: return "A bisect, merge or replay operation is already active."
        case .inactive: return "No bisect session is active."
        case .revision: return "Choose an existing commit for each bisect revision."
        case .dirty: return "Stash or commit tracked changes before starting bisect."
        case .operation: return "Choose one revision for Good or Bad. Skip accepts multiple revisions; Reset accepts none."
        }
    }
}
extension GitRepository {
    private func bisectPath(_ name: String) throws -> URL {
        var bytes = try run(["rev-parse", "--git-path", name]).stdout
        if bytes.last == 10 { bytes.removeLast() }
        let path = String(decoding: bytes, as: UTF8.self)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    }
    public func bisectState() throws -> BisectState {
        func read(_ name: String) throws -> String { (try? String(contentsOf: bisectPath(name), encoding: .utf8)) ?? "" }
        let active = FileManager.default.fileExists(atPath: try bisectPath("BISECT_START").path)
        let head = try run(["rev-parse", "--verify", "HEAD"]).text.trimmingCharacters(in: .newlines)
        let terms = try read("BISECT_TERMS").split(separator: "\n").map(String.init)
        // Git writes the bad term first, then the good term.
        return BisectState(active: active, originalRevision: try read("BISECT_START").trimmingCharacters(in: .newlines), head: head,
                           goodTerm: terms.count == 2 ? terms[1] : "good", badTerm: terms.count == 2 ? terms[0] : "bad", log: active ? try read("BISECT_LOG") : "")
    }
    private func bisectCommit(_ revision: String) throws -> String {
        guard !revision.isEmpty, !revision.contains("\0") else { throw BisectFailure.revision }
        do { return try run(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"]).text.trimmingCharacters(in: .newlines) }
        catch { throw BisectFailure.revision }
    }
    /// The native Stash/Abort prompt calls this only after explicit Stash.
    public func stashBeforeBisect() throws -> StashSaveResult {
        guard try !isBare() else { throw BisectFailure.workingTree }
        guard try !bisectState().active, try !logMergeActive(), try !rebaseState().active,
              try !FileManager.default.fileExists(atPath: bisectPath("CHERRY_PICK_HEAD").path),
              try !FileManager.default.fileExists(atPath: bisectPath("REVERT_HEAD").path) else { throw BisectFailure.active }
        return try saveStash(StashSaveOptions())
    }
    /// Like upstream, run Start, Good, Bad in order. A checkout failure leaves
    /// Git's active session recoverable through Reset instead of hiding it.
    public func startBisect(good: String, bad: String) throws -> BisectExecution {
        guard try !isBare() else { throw BisectFailure.workingTree }
        guard try !bisectState().active, try !logMergeActive(), try !rebaseState().active,
              try !FileManager.default.fileExists(atPath: bisectPath("CHERRY_PICK_HEAD").path),
              try !FileManager.default.fileExists(atPath: bisectPath("REVERT_HEAD").path) else { throw BisectFailure.active }
        let goodHash = try bisectCommit(good), badHash = try bisectCommit(bad)
        guard try run(["diff", "--quiet", "--"], successfulExitCodes: 0...1).exitCode == 0,
              try run(["diff", "--cached", "--quiet", "--"], successfulExitCodes: 0...1).exitCode == 0 else { throw BisectFailure.dirty }
        var output = "", code: Int32 = 0
        for arguments in [["bisect", "start"], ["bisect", "good", goodHash], ["bisect", "bad", badHash]] {
            let result = try run(arguments, successfulExitCodes: 0...128)
            output += result.text; code = result.exitCode
            if code != 0 { break }
        }
        return BisectExecution(output: output, exitCode: code, state: try bisectState())
    }
    /// Empty revisions means classify the checked-out commit. Good/Bad follow
    /// custom terms from an externally started Git session. Skip uses literal
    /// resolved hashes for every selected revision, without range expansion.
    public func bisect(_ operation: BisectOperation, revisions: [String] = []) throws -> BisectExecution {
        guard try !isBare() else { throw BisectFailure.workingTree }
        let state = try bisectState(); guard state.active else { throw BisectFailure.inactive }
        guard operation != .reset || revisions.isEmpty,
              operation == .skip || revisions.count <= 1 else { throw BisectFailure.operation }
        let hashes = try revisions.map { try bisectCommit($0) }
        let command = operation == .good ? state.goodTerm : operation == .bad ? state.badTerm : operation.rawValue
        let result = try run(["bisect", command] + hashes, successfulExitCodes: 0...128)
        return BisectExecution(output: result.text, exitCode: result.exitCode, state: try bisectState())
    }
}
