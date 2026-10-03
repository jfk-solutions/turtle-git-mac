import Foundation

public enum RebaseAction: String, CaseIterable, Sendable { case pick, skip = "drop", edit, squash }
public struct RebaseEntry: Identifiable, Sendable {
    public var id: String { commit.hash }
    public let commit: LogEntry
    public var action: RebaseAction = .pick
}
public struct RebaseOptions: Sendable {
    public var branch = "HEAD"
    public var upstream = ""
    public var onto = ""
    public var force = false
    public var preserveMerges = false
    public init() {}
}
public struct RebasePlan: Sendable {
    public let options: RebaseOptions
    public let branchHash: String
    public let upstreamHash: String
    public let ontoHash: String
    public let branchReference: String
    public let originalCommits: [String]
    public var entries: [RebaseEntry]
}
public struct RebaseState: Sendable {
    public let active: Bool
    public let branch: String
    public let originalHead: String
    public let onto: String
    public let stoppedCommit: String
    public let message: String
    public let currentStep: Int
    public let total: Int
    public let conflicts: [String]
    public let remainingCommands: [String]
}
public struct RebaseExecution: Sendable {
    public let output: String
    public let exitCode: Int32
    public let state: RebaseState
}
public enum RebaseFailure: LocalizedError {
    case revision, active, inactive, changed, plan, squash, preservePlan, message
    public var errorDescription: String? {
        switch self {
        case .revision: return "Choose valid branch, upstream and onto revisions."
        case .active: return "A rebase is already active. Continue, skip or abort that operation first."
        case .inactive: return "No rebase is active in this repository."
        case .changed: return "A selected reference changed after the commit plan was loaded. Reload the plan before starting."
        case .plan: return "The commit plan contains missing, duplicate or unexpected commits."
        case .squash: return "The first retained commit cannot be squashed."
        case .preservePlan: return "Preserve Merges uses Git's structural plan; custom actions and ordering require further porting."
        case .message: return "Enter a commit message."
        }
    }
}
/// Invoked by Git as an editor through the same signed application executable.
/// This entry point writes the generated plan and exits before creating windows.
public enum RebaseEditor {
    public static let argument = "--turtlegit-sequence-editor"
    public static func handle(arguments: [String], environment: [String: String]) -> Int32? {
        guard arguments.dropFirst().first == argument else { return nil }
        guard arguments.count == 3, let source = environment["TURTLEGIT_REBASE_PLAN"] else { return 1 }
        do { try Data(contentsOf: URL(fileURLWithPath: source)).write(to: URL(fileURLWithPath: arguments[2]), options: .atomic); return 0 }
        catch { return 1 }
    }
    public static func command(executable: URL) -> String {
        "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "' " + argument
    }
}
extension GitRepository {
    private func rebaseRevision(_ name: String) throws -> String {
        guard !name.isEmpty, !name.contains("\0") else { throw RebaseFailure.revision }
        guard let result = try? run(["rev-parse", "--verify", "--end-of-options", name + "^{commit}"]) else { throw RebaseFailure.revision }
        return result.text.trimmingCharacters(in: .newlines)
    }
    private func rebasePath(_ name: String) throws -> URL {
        var bytes = try run(["rev-parse", "--git-path", name]).stdout
        if bytes.last == 10 { bytes.removeLast() }
        let path = String(decoding: bytes, as: UTF8.self)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    }
    public func rebaseState() throws -> RebaseState {
        let merge = try rebasePath("rebase-merge"), apply = try rebasePath("rebase-apply")
        let manager = FileManager.default
        let directory = manager.fileExists(atPath: merge.path) ? merge : apply
        let active = manager.fileExists(atPath: directory.path)
        func read(_ file: String) -> String { (try? String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)) ?? "" }
        func line(_ file: String) -> String { read(file).trimmingCharacters(in: .newlines) }
        let conflicts = active ? try run(["diff", "--name-only", "--diff-filter=U", "-z"]).stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) } : []
        return RebaseState(active: active, branch: line("head-name"), originalHead: line("orig-head"), onto: line("onto"),
                           stoppedCommit: line("stopped-sha"), message: read("message"), currentStep: Int(line("msgnum")) ?? Int(line("next")) ?? 0,
                           total: Int(line("end")) ?? Int(line("last")) ?? 0, conflicts: conflicts,
                           remainingCommands: read("git-rebase-todo").split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") })
    }
    public func rebasePlan(_ options: RebaseOptions) throws -> RebasePlan {
        guard !(try rebaseState().active) else { throw RebaseFailure.active }
        let branchHash = try rebaseRevision(options.branch), upstreamHash = try rebaseRevision(options.upstream)
        let ontoHash = options.onto.isEmpty ? upstreamHash : try rebaseRevision(options.onto)
        let symbolic = ((try? run(["rev-parse", "--symbolic-full-name", "--verify", "--end-of-options", options.branch]).text) ?? "").trimmingCharacters(in: .newlines)
        let branchReference = symbolic.hasPrefix("refs/heads/") ? symbolic : ""
        var args = ["log", "--reverse", "--topo-order", "--format=%H%x00%P%x00%an%x00%ae%x00%aI%x00%s%x00%B%x00"]
        if !options.preserveMerges { args.append("--no-merges") }
        args += [upstreamHash + ".." + branchHash, "--"]
        let commits = LogEntry.parseHistory(try run(args).stdout)
        let cherry = try run(["cherry", upstreamHash, branchHash]).text
        let redundant = Set(cherry.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: " "); return parts.count == 2 && parts[0] == "-" ? String(parts[1]) : nil
        })
        return RebasePlan(options: options, branchHash: branchHash, upstreamHash: upstreamHash, ontoHash: ontoHash,
                          branchReference: branchReference, originalCommits: commits.map(\.hash),
                          entries: commits.map { RebaseEntry(commit: $0, action: redundant.contains($0.hash) && !options.force && !options.preserveMerges ? .skip : .pick) })
    }
    public func rebaseTodo(_ plan: RebasePlan) throws -> String {
        let ids = plan.entries.map(\.id)
        guard ids.count == plan.originalCommits.count, Set(ids).count == ids.count, Set(ids) == Set(plan.originalCommits) else { throw RebaseFailure.plan }
        guard plan.entries.first(where: { $0.action != .skip })?.action != .squash else { throw RebaseFailure.squash }
        if plan.options.preserveMerges, ids != plan.originalCommits || plan.entries.contains(where: { $0.action != .pick }) { throw RebaseFailure.preservePlan }
        if plan.entries.isEmpty { return "noop\n" }
        return plan.entries.map { $0.action.rawValue + " " + $0.commit.hash + " " + $0.commit.subject.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") }.joined(separator: "\n") + "\n"
    }
    public func startRebase(_ plan: RebasePlan, editorExecutable: URL) throws -> RebaseExecution {
        guard !(try rebaseState().active) else { throw RebaseFailure.active }
        guard try rebaseRevision(plan.options.branch) == plan.branchHash,
              try rebaseRevision(plan.options.upstream) == plan.upstreamHash,
              (plan.options.onto.isEmpty ? plan.upstreamHash : try rebaseRevision(plan.options.onto)) == plan.ontoHash else { throw RebaseFailure.changed }
        let todo = try rebaseTodo(plan)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let path = temporary.appendingPathComponent("todo")
        try Data(todo.utf8).write(to: path)
        var args = ["rebase", "--no-autostash"]
        if plan.options.force { args += ["--force-rebase", "--reapply-cherry-picks"] }
        if plan.options.preserveMerges { args.append("--rebase-merges") }
        else { args.append("--interactive") }
        args += ["--onto", plan.ontoHash, "--", plan.upstreamHash, plan.branchReference.isEmpty ? plan.branchHash : String(plan.branchReference.dropFirst(11))]
        return try executeRebase(args, environment: ["GIT_SEQUENCE_EDITOR": RebaseEditor.command(executable: editorExecutable), "TURTLEGIT_REBASE_PLAN": path.path, "GIT_EDITOR": "/usr/bin/true"])
    }
    public func continueRebase() throws -> RebaseExecution { try recoverRebase("--continue") }
    public func skipRebase() throws -> RebaseExecution { try recoverRebase("--skip") }
    public func abortRebase() throws -> RebaseExecution { try recoverRebase("--abort") }
    private func recoverRebase(_ action: String) throws -> RebaseExecution {
        guard try rebaseState().active else { throw RebaseFailure.inactive }
        return try executeRebase(["rebase", action], environment: ["GIT_EDITOR": "/usr/bin/true"])
    }
    private func executeRebase(_ arguments: [String], environment: [String: String]) throws -> RebaseExecution {
        do { let output = try run(arguments, environmentOverrides: environment).text; return RebaseExecution(output: output, exitCode: 0, state: try rebaseState()) }
        catch let failure as GitFailure { return RebaseExecution(output: failure.message, exitCode: failure.code, state: try rebaseState()) }
    }
    public func amendRebaseCommit(message: String) throws -> String {
        guard try rebaseState().active else { throw RebaseFailure.inactive }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RebaseFailure.message }
        return try run(["commit", "--amend", "-m", message]).text
    }
}
