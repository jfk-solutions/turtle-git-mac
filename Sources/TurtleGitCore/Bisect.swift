// Native adaptation of TortoiseGit AppUtils.cpp BisectStart/BisectOperation.
// See NOTICE and LICENSE for upstream attribution and GPL licensing.
import Foundation

public enum BisectOperation: String, CaseIterable, Sendable { case good, bad, skip, reset }
/// Pinned BisectCommand.cpp decides between Start and an operation only after
/// reading the real session state. Presence of good/bad differs from its value.
public struct BisectCommandRequest: Equatable, Sendable {
    public let start: Bool
    public let good: String?
    public let bad: String?
    public let skip: Bool
    public let reset: Bool
    public let reference: String?
    public init(start: Bool = false, good: String? = nil, bad: String? = nil, skip: Bool = false, reset: Bool = false, reference: String? = nil) {
        self.start=start;self.good=good;self.bad=bad;self.skip=skip;self.reset=reset;self.reference=reference
    }
    public enum Action: Equatable, Sendable {
        case start(good: String?, bad: String?)
        case operation(BisectOperation, revisions: [String])
    }
    public func action(active: Bool) throws -> Action {
        if start && !active {
            return .start(good:good.flatMap {$0.isEmpty ? nil:$0},bad:bad.flatMap {$0.isEmpty ? nil:$0})
        }
        guard active else { throw Failure.notAllowed }
        let operation: BisectOperation
        if good != nil { operation = .good }
        else if bad != nil { operation = .bad }
        else if skip { operation = .skip }
        else if reset { operation = .reset }
        else { throw Failure.notAllowed }
        return .operation(operation, revisions: operation == .reset ? [] : reference.flatMap {$0.isEmpty ? nil:[$0]} ?? [])
    }
    public enum Failure: LocalizedError {
        case notAllowed
        public var errorDescription: String? { "Operation unknown or not allowed." }
    }
}
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
    private func bisectReplayActive(cancellation: OperationCancellation?) throws -> Bool {
        for name in ["rebase-merge", "rebase-apply"] {
            if FileManager.default.fileExists(atPath: try bisectPath(name, cancellation: cancellation).path) { return true }
        }
        return false
    }
    private func bisectPath(_ name: String, cancellation: OperationCancellation? = nil) throws -> URL {
        var bytes = try run(["rev-parse", "--git-path", name], cancellation: cancellation).stdout
        if bytes.last == 10 { bytes.removeLast() }
        let path = String(decoding: bytes, as: UTF8.self)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    }
    public func bisectState(cancellation: OperationCancellation? = nil) throws -> BisectState {
        func read(_ name: String) throws -> String {
            let path = try bisectPath(name, cancellation: cancellation)
            let text = (try? String(contentsOf: path, encoding: .utf8)) ?? ""
            try cancellation?.check(); return text
        }
        let active = FileManager.default.fileExists(atPath: try bisectPath("BISECT_START", cancellation: cancellation).path)
        let revision = try run(["rev-parse", "--verify", "--quiet", "HEAD"], successfulExitCodes: 0...1, cancellation: cancellation)
        guard !active || revision.exitCode == 0 else { throw BisectFailure.revision }
        let head = revision.text.trimmingCharacters(in: .newlines)
        let terms = try read("BISECT_TERMS").split(separator: "\n").map(String.init)
        // Git writes the bad term first, then the good term.
        return BisectState(active: active, originalRevision: try read("BISECT_START").trimmingCharacters(in: .newlines), head: head,
                           goodTerm: terms.count == 2 ? terms[1] : "good", badTerm: terms.count == 2 ? terms[0] : "bad", log: active ? try read("BISECT_LOG") : "")
    }
    private func bisectCommit(_ revision: String, cancellation: OperationCancellation? = nil) throws -> String {
        guard !revision.isEmpty, !revision.contains("\0") else { throw BisectFailure.revision }
        do { return try run(["rev-parse", "--verify", "--end-of-options", revision + "^{commit}"], cancellation: cancellation).text.trimmingCharacters(in: .newlines) }
        catch { try cancellation?.check(); throw BisectFailure.revision }
    }
    /// The native Stash/Abort prompt calls this only after explicit Stash.
    public func stashBeforeBisect(cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> StashSaveResult {
        guard try !isBare(cancellation: cancellation) else { throw BisectFailure.workingTree }
        guard try !bisectState(cancellation: cancellation).active, try !logMergeActive(cancellation: cancellation), try !bisectReplayActive(cancellation: cancellation),
              try !FileManager.default.fileExists(atPath: bisectPath("CHERRY_PICK_HEAD", cancellation: cancellation).path),
              try !FileManager.default.fileExists(atPath: bisectPath("REVERT_HEAD", cancellation: cancellation).path) else { throw BisectFailure.active }
        return try saveStash(StashSaveOptions(), cancellation: cancellation, onOutput: onOutput)
    }
    /// Like upstream, run Start, Good, Bad in order. A checkout failure leaves
    /// Git's active session recoverable through Reset instead of hiding it.
    public func startBisect(good: String, bad: String, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> BisectExecution {
        guard try !isBare(cancellation: cancellation) else { throw BisectFailure.workingTree }
        guard try !bisectState(cancellation: cancellation).active, try !logMergeActive(cancellation: cancellation), try !bisectReplayActive(cancellation: cancellation),
              try !FileManager.default.fileExists(atPath: bisectPath("CHERRY_PICK_HEAD", cancellation: cancellation).path),
              try !FileManager.default.fileExists(atPath: bisectPath("REVERT_HEAD", cancellation: cancellation).path) else { throw BisectFailure.active }
        let goodHash = try bisectCommit(good, cancellation: cancellation), badHash = try bisectCommit(bad, cancellation: cancellation)
        guard try run(["diff", "--quiet", "--"], successfulExitCodes: 0...1, cancellation: cancellation).exitCode == 0,
              try run(["diff", "--cached", "--quiet", "--"], successfulExitCodes: 0...1, cancellation: cancellation).exitCode == 0 else { throw BisectFailure.dirty }
        var output = "", code: Int32 = 0
        for arguments in [["bisect", "start"], ["bisect", "good", goodHash], ["bisect", "bad", badHash]] {
            let result = try run(arguments, successfulExitCodes: 0...128, cancellation: cancellation, onOutput: onOutput)
            output += result.text; code = result.exitCode
            if code != 0 { break }
        }
        return BisectExecution(output: output, exitCode: code, state: try bisectState(cancellation: cancellation))
    }
    /// Empty revisions means classify the checked-out commit. Good/Bad follow
    /// custom terms from an externally started Git session. Skip uses literal
    /// resolved hashes for every selected revision, without range expansion.
    public func bisect(_ operation: BisectOperation, revisions: [String] = [], cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> BisectExecution {
        guard try !isBare(cancellation: cancellation) else { throw BisectFailure.workingTree }
        let state = try bisectState(cancellation: cancellation); guard state.active else { throw BisectFailure.inactive }
        guard operation != .reset || revisions.isEmpty,
              operation == .skip || revisions.count <= 1 else { throw BisectFailure.operation }
        let hashes = try revisions.map { try bisectCommit($0, cancellation: cancellation) }
        let command = operation == .good ? state.goodTerm : operation == .bad ? state.badTerm : operation.rawValue
        let result = try run(["bisect", command] + hashes, successfulExitCodes: 0...128, cancellation: cancellation, onOutput: onOutput)
        return BisectExecution(output: result.text, exitCode: result.exitCode, state: try bisectState(cancellation: cancellation))
    }
}
