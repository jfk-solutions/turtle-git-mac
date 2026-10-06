import Foundation

public enum RebaseAction: String, CaseIterable, Sendable { case pick, skip = "drop", edit, squash }
public enum RebaseEmptyChoice: Sendable { case commit, skip, cancel }
public enum RebaseSquashDate: Int, Codable, Sendable { case first = 0, latest = 1, current = 2 }
public struct RebaseSquashMessage: Codable, Sendable {
    public var message: String
    public let datePolicy: RebaseSquashDate
    public let latestDate: String
    public let step: Int
}
public struct RebaseSplitReturn: Codable, Sendable {
    public let parts: Int
    public let firstAuthor: String
    public let firstDate: String
    public let squashDate: RebaseSquashDate?
}
public struct RebaseSplitState: Codable, Sendable {
    public let entryID: String
    public let step: Int
    public var expectedHead: String
    public var parts: Int
    public let firstAuthor: String
    public let firstDate: String
    public let squashDate: RebaseSquashDate?
    /// Conflict recovery keeps amending the applied commit, rather than creating split parts.
    public var conflictRecovery: Bool? = nil
    /// Return to the applied conflict Edit if the first Split dialog is cancelled.
    public var conflictRecoveryReturn: RebaseSplitReturn? = nil
}
public struct RebaseEntry: Identifiable, Sendable {
    public var id: String { occurrence == 0 ? commit.hash : commit.hash + ":" + String(occurrence) }
    public var occurrence = 0
    public let commit: LogEntry
    public var action: RebaseAction = .pick
    /// Required for retained merge commits in a Cherry Pick plan.
    public var mainline: Int? = nil
}
public struct RebaseOptions: Sendable {
    public var branch = "HEAD"
    public var upstream = ""
    public var onto = ""
    public var force = false
    public var preserveMerges = false
    public var isCherryPick = false
    public var addCherryPickedFrom = false
    public var squashDate: RebaseSquashDate = .first
    public init() {}
}
public enum RebaseDisposition: Sendable { case ready, fastForward, upToDate, equal }
public struct RebasePlan: Sendable {
    public let disposition: RebaseDisposition
    public var options: RebaseOptions
    public let branchHash: String
    public let upstreamHash: String
    public let ontoHash: String
    public let branchReference: String
    public let originalCommits: [String]
    public var entries: [RebaseEntry]
    public var hasAddedCommits = false
}
public struct RebaseState: Sendable {
    public let active: Bool
    public let isCherryPick: Bool
    public let branch: String
    public let originalHead: String
    public let onto: String
    public let stoppedEntryID: String
    public let stoppedCommit: String
    public let message: String
    public let currentStep: Int
    public let total: Int
    public let conflicts: [String]
    public let remainingCommands: [String]
    public let squashMessage: RebaseSquashMessage?
    public let stoppedAction: RebaseAction?
    public let split: RebaseSplitState?
    public let isEditPause: Bool
    public let needsFileRecovery: Bool
    public var canSplit: Bool { active && conflicts.isEmpty && (isEditPause || squashMessage != nil || split != nil && split?.conflictRecovery != true) }
}
public struct RebaseExecution: Sendable {
    public let output: String
    public let exitCode: Int32
    public let state: RebaseState
}
public enum RebaseFailure: LocalizedError {
    case revision, active, inactive, changed, plan, squash, preservePlan, message, mainline, emptyResult
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
        case .emptyResult: return "The current commit will be empty. Choose Commit, Skip or Cancel."
        case .mainline: return "Choose a valid mainline parent for each retained merge commit."
        }
    }
}
/// Invoked by Git as an editor through the same signed application executable.
/// This entry point writes the generated plan and exits before creating windows.
public enum RebaseEditor {
    public static let argument = "--turtlegit-sequence-editor"
    public static let messageArgument = "--turtlegit-rebase-message-editor"
    public static func handle(arguments: [String], environment: [String: String]) -> Int32? {
        if arguments.dropFirst().first == messageArgument { return handleMessage(arguments: arguments) }
        guard arguments.dropFirst().first == argument else { return nil }
        guard arguments.count == 3, let source = environment["TURTLEGIT_REBASE_PLAN"] else { return 1 }
        do {
            let target = URL(fileURLWithPath: arguments[2])
            try Data(contentsOf: URL(fileURLWithPath: source)).write(to: target, options: .atomic)
            if let metadata = environment["TURTLEGIT_CHERRY_PICK_METADATA"] {
                try Data(contentsOf: URL(fileURLWithPath: metadata)).write(to: target.deletingLastPathComponent().appendingPathComponent("turtlegit-cherry-pick.json"), options: .atomic)
            }
            if let metadata = environment["TURTLEGIT_REPLAY_IDENTITIES"] {
                try Data(contentsOf: URL(fileURLWithPath: metadata)).write(to: target.deletingLastPathComponent().appendingPathComponent("turtlegit-replay-identities.json"), options: .atomic)
            }
            if let metadata = environment["TURTLEGIT_REPLAY_MESSAGES"] {
                try Data(contentsOf: URL(fileURLWithPath: metadata)).write(to: target.deletingLastPathComponent().appendingPathComponent("turtlegit-message-editor.json"), options: .atomic)
            }
            return 0
        }
        catch { return 1 }
    }
    public static func command(executable: URL) -> String {
        "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "' " + argument
    }
    public static func messageCommand(executable: URL) -> String {
        "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "' " + messageArgument
    }
    private static func handleMessage(arguments: [String]) -> Int32 {
        guard arguments.count == 3 else { return 1 }
        let directory = URL(fileURLWithPath: arguments[2]).deletingLastPathComponent().appendingPathComponent("rebase-merge")
        let configuration = directory.appendingPathComponent("turtlegit-message-editor.json")
        let squash = directory.appendingPathComponent("message-squash")
        guard FileManager.default.fileExists(atPath: configuration.path), FileManager.default.fileExists(atPath: squash.path) else { return 0 }
        do {
            let config = try JSONDecoder().decode(RebaseMessageConfiguration.self, from: Data(contentsOf: configuration))
            let step = Int(try String(contentsOf: directory.appendingPathComponent("msgnum"), encoding: .utf8).trimmingCharacters(in: .newlines)) ?? 0
            guard config.dates.indices.contains(step - 1) else { return 1 }
            let text = try String(contentsOf: squash, encoding: .utf8)
            // Remove only Git's combination headings. Literal comment-prefixed
            // message lines remain editable and are committed verbatim.
            let lines = text.components(separatedBy: "\n")
            let header = try NSRegularExpression(pattern: "^(.*) This is a combination of [0-9]+ commits\\.$")
            let first = lines.first ?? ""
            guard let match = header.firstMatch(in: first, range: NSRange(first.startIndex..., in: first)), let range = Range(match.range(at: 1), in: first) else { return 1 }
            let prefix = NSRegularExpression.escapedPattern(for: String(first[range]))
            let headings = try NSRegularExpression(pattern: "^" + prefix + " This is (a combination of [0-9]+ commits\\.|the ([0-9]+(st|nd|rd|th) commit message|commit message #[0-9]+):)$")
            let message = lines.filter { headings.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) == nil }.joined(separator: "\n").trimmingCharacters(in: .newlines)
            let request = RebaseSquashMessage(message: message, datePolicy: config.datePolicy, latestDate: config.dates[step - 1], step: step)
            try JSONEncoder().encode(request).write(to: directory.appendingPathComponent("turtlegit-squash-message.json"), options: .atomic)
            return 1 // Leave Git's durable replay state for the native editor.
        } catch { return 1 }
    }
}
private struct RebaseMessageConfiguration: Codable {
    let editorCommand: String
    let datePolicy: RebaseSquashDate
    let dates: [String]
}
private struct RebaseReplayIdentity: Codable {
    let hash: String
    let occurrence: Int
    var id: String { occurrence == 0 ? hash : hash + ":" + String(occurrence) }
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
        let metadataURL = directory.appendingPathComponent("turtlegit-cherry-pick.json")
        let mapping = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: metadataURL))) ?? [:]
        let stopped = line("stopped-sha")
        let commands = read("git-rebase-todo").split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }.map { command -> String in
            var fields = command.split(separator: " ", maxSplits: 2).map(String.init)
            if fields.count >= 2, let original = mapping[fields[1]] { fields[1] = original }
            return fields.joined(separator: " ")
        }
        let step = Int(line("msgnum")) ?? Int(line("next")) ?? 0
        let identities = replayIdentities(directory)
        let originalStopped = mapping[stopped] ?? stopped
        let stoppedIdentity = identities.indices.contains(step - 1) && identities[step - 1].hash == originalStopped ? identities[step - 1].id : originalStopped
        let requestURL = directory.appendingPathComponent("turtlegit-squash-message.json")
        let request = active && manager.fileExists(atPath: requestURL.path) ? try JSONDecoder().decode(RebaseSquashMessage.self, from: Data(contentsOf: requestURL)) : nil
        let splitURL = directory.appendingPathComponent("turtlegit-split.json")
        let split = active && manager.fileExists(atPath: splitURL.path) ? try JSONDecoder().decode(RebaseSplitState.self, from: Data(contentsOf: splitURL)) : nil
        let lastCommand = read("done").split(separator: "\n").last?.split(separator: " ").first.map(String.init)
        let action = lastCommand.flatMap(RebaseAction.init(rawValue:))
        let editPause = active && conflicts.isEmpty && action == .edit && (manager.fileExists(atPath: directory.appendingPathComponent("amend").path) || split?.step == step && (split?.conflictRecovery == true && (split?.parts ?? 0) > 0 || split?.conflictRecoveryReturn != nil))
        let pending = request?.step == step && conflicts.isEmpty ? request : nil
        let activeSplit = split?.step == step && split?.entryID == stoppedIdentity ? split : nil
        return RebaseState(active: active, isCherryPick: active && manager.fileExists(atPath: metadataURL.path), branch: line("head-name"), originalHead: line("orig-head"), onto: line("onto"),
                           stoppedEntryID: stoppedIdentity, stoppedCommit: originalStopped, message: activeSplit?.conflictRecovery == true || activeSplit?.conflictRecoveryReturn != nil ? try rebaseCommit("HEAD").message : read("message"), currentStep: step,
                           total: Int(line("end")) ?? Int(line("last")) ?? 0, conflicts: conflicts,
                           remainingCommands: commands, squashMessage: pending, stoppedAction: action, split: activeSplit,
                           isEditPause: editPause, needsFileRecovery: active && (!conflicts.isEmpty || !originalStopped.isEmpty && !editPause && pending == nil && activeSplit == nil))
    }
    private func replayIdentities(_ directory: URL) -> [RebaseReplayIdentity] {
        (try? JSONDecoder().decode([RebaseReplayIdentity].self, from: Data(contentsOf: directory.appendingPathComponent("turtlegit-replay-identities.json")))) ?? []
    }
    private func validateRebaseIdentities(_ plan: RebasePlan) throws {
        let ids = plan.entries.map(\.id)
        guard ids.count == plan.originalCommits.count, Set(ids).count == ids.count, Set(ids) == Set(plan.originalCommits),
              plan.entries.allSatisfy({ $0.occurrence >= 0 }) else { throw RebaseFailure.plan }
    }
    /// Insert picker selections above the visible newest-first list, replaying them after existing entries.
    public func addingRebaseCommits(_ plan: RebasePlan, revisions: [String]) throws -> RebasePlan {
        guard !(try rebaseState().active) else { throw RebaseFailure.active }
        guard !plan.options.preserveMerges else { throw RebaseFailure.preservePlan }
        try validateRebaseIdentities(plan)
        if revisions.isEmpty { return plan }
        let entries = try addingRebaseEntries(plan.entries, revisions: revisions)
        var value = RebasePlan(disposition: .ready, options: plan.options, branchHash: plan.branchHash, upstreamHash: plan.upstreamHash,
                               ontoHash: plan.ontoHash, branchReference: plan.branchReference, originalCommits: entries.map(\.id), entries: entries)
        value.hasAddedCommits = true
        return value
    }
    /// Resolve Add selections without requiring branch/upstream fields to be complete.
    public func addingRebaseEntries(_ existing: [RebaseEntry], revisions: [String]) throws -> [RebaseEntry] {
        guard !(try rebaseState().active) else { throw RebaseFailure.active }
        guard Set(existing.map(\.id)).count == existing.count, existing.allSatisfy({ $0.occurrence >= 0 }) else { throw RebaseFailure.plan }
        let commits = try revisions.reversed().map { try rebaseCommit($0) }
        var entries = existing
        for commit in commits {
            var entry = RebaseEntry(commit: commit)
            entry.occurrence = entries.filter { $0.commit.hash == commit.hash }.map(\.occurrence).max().map { $0 + 1 } ?? 0
            entries.append(entry)
        }
        return entries
    }
    private func currentRebaseBranch() throws -> String {
        ((try? run(["symbolic-ref", "--quiet", "HEAD"]).text) ?? "").trimmingCharacters(in: .newlines)
    }
    /// Input follows the Log's newest-first visible selection; execution is oldest-first.
    public func cherryPickPlan(revisions: [String]) throws -> RebasePlan {
        guard !(try rebaseState().active) else { throw RebaseFailure.active }
        guard !revisions.isEmpty else { throw RebaseFailure.plan }
        let commits = try revisions.reversed().map { try rebaseCommit($0) }
        guard Set(commits.map(\.hash)).count == commits.count else { throw RebaseFailure.plan }
        let head = try rebaseRevision("HEAD"), branch = try currentRebaseBranch()
        var options = RebaseOptions(); options.branch = "HEAD"; options.upstream = head; options.force = true; options.isCherryPick = true
        return RebasePlan(disposition: .ready, options: options, branchHash: head, upstreamHash: head, ontoHash: head,
                          branchReference: branch, originalCommits: commits.map(\.hash), entries: commits.map { RebaseEntry(commit: $0) })
    }
    public func rebasePlan(_ options: RebaseOptions) throws -> RebasePlan {
        guard !options.isCherryPick else { throw RebaseFailure.plan }
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
        let disposition: RebaseDisposition
        if branchHash == ontoHash && branchHash == upstreamHash { disposition = .equal }
        else if options.onto.isEmpty && !options.force && (try? run(["merge-base", "--is-ancestor", branchHash, upstreamHash])) != nil { disposition = .fastForward }
        else if options.onto.isEmpty && !options.force && (try? run(["merge-base", "--is-ancestor", upstreamHash, branchHash])) != nil { disposition = .upToDate }
        else { disposition = .ready }
        return RebasePlan(disposition: disposition, options: options, branchHash: branchHash, upstreamHash: upstreamHash, ontoHash: ontoHash,
                          branchReference: branchReference, originalCommits: commits.map(\.hash),
                          entries: commits.map { RebaseEntry(commit: $0, action: redundant.contains($0.hash) && !options.force && !options.preserveMerges ? .skip : .pick) })
    }
    public func rebaseCommit(_ revision: String) throws -> LogEntry {
        let hash = try rebaseRevision(revision)
        let result = try run(["show", "-s", "--format=%H%x00%P%x00%an%x00%ae%x00%aI%x00%s%x00%B%x00", hash, "--"])
        guard let entry = LogEntry.parseHistory(result.stdout).first else { throw RebaseFailure.revision }
        return entry
    }
    public func remainingRebaseEntries() throws -> [RebaseEntry] {
        let state = try rebaseState()
        guard state.active else { return [] }
        let identities = replayIdentities(try rebasePath("rebase-merge"))
        var result: [RebaseEntry] = []
        func recovered(_ hash: String, action: RebaseAction, position: Int) throws -> RebaseEntry {
            var entry = RebaseEntry(commit: try rebaseCommit(hash), action: action)
            if identities.indices.contains(position), identities[position].hash == entry.commit.hash { entry.occurrence = identities[position].occurrence }
            return entry
        }
        if !state.stoppedCommit.isEmpty { result.append(try recovered(state.stoppedCommit, action: .edit, position: state.currentStep - 1)) }
        var position = state.currentStep
        for line in state.remainingCommands {
            let fields = line.split(separator: " ", maxSplits: 2)
            guard fields.count >= 2, let action = RebaseAction(rawValue: String(fields[0])) else { continue }
            result.append(try recovered(String(fields[1]), action: action, position: position)); position += 1
        }
        return result
    }
    public func rebaseTodo(_ plan: RebasePlan) throws -> String {
        let ids = plan.entries.map(\.id)
        try validateRebaseIdentities(plan)
        guard plan.entries.first(where: { $0.action != .skip })?.action != .squash else { throw RebaseFailure.squash }
        if plan.options.preserveMerges, ids != plan.originalCommits || plan.entries.contains(where: { $0.action != .pick }) { throw RebaseFailure.preservePlan }
        if plan.options.isCherryPick {
            for entry in plan.entries where entry.action != .skip {
                if entry.commit.parents.count > 1 {
                    guard let parent = entry.mainline, (1...entry.commit.parents.count).contains(parent) else { throw RebaseFailure.mainline }
                } else if entry.mainline != nil { throw RebaseFailure.mainline }
            }
        }
        if plan.entries.isEmpty { return "noop\n" }
        return plan.entries.map { $0.action.rawValue + " " + $0.commit.hash + " " + $0.commit.subject.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") }.joined(separator: "\n") + "\n"
    }
    public func startRebase(_ plan: RebasePlan, editorExecutable: URL) throws -> RebaseExecution {
        guard !(try rebaseState().active) else { throw RebaseFailure.active }
        guard try rebaseRevision(plan.options.branch) == plan.branchHash,
              try rebaseRevision(plan.options.upstream) == plan.upstreamHash,
              (plan.options.onto.isEmpty ? plan.upstreamHash : try rebaseRevision(plan.options.onto)) == plan.ontoHash else { throw RebaseFailure.changed }
        if plan.options.isCherryPick {
            guard try currentRebaseBranch() == plan.branchReference, !plan.options.preserveMerges,
                  plan.options.branch == "HEAD", plan.upstreamHash == plan.branchHash, plan.ontoHash == plan.branchHash else { throw RebaseFailure.changed }
        }
        _ = try rebaseTodo(plan)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var replay = plan
        var mapping: [String: String] = [:]
        if plan.options.isCherryPick {
            for index in replay.entries.indices {
                let entry = replay.entries[index]
                // Read immutable objects again rather than trusting caller-supplied parent metadata.
                let original = try rebaseCommit(entry.commit.hash)
                guard original.parents == entry.commit.parents else { throw RebaseFailure.plan }
                guard entry.action != .skip, original.parents.count > 1 || plan.options.addCherryPickedFrom else { continue }
                let parent: String?
                if original.parents.count > 1 {
                    guard let mainline = entry.mainline, original.parents.indices.contains(mainline - 1) else { throw RebaseFailure.mainline }
                    parent = original.parents[mainline - 1]
                } else { parent = original.parents.first }
                let object = try run(["cat-file", "commit", original.hash]).stdout
                guard let separator = object.range(of: Data([10, 10])) else { throw RebaseFailure.plan }
                let messageFile = temporary.appendingPathComponent("message")
                var message = object.subdata(in: separator.upperBound..<object.count)
                if plan.options.addCherryPickedFrom {
                    while message.last == 10 { message.removeLast() }
                    message.append(Data(("\n\n(cherry picked from commit " + original.hash + ")\n").utf8))
                }
                try message.write(to: messageFile)
                let tree = try run(["rev-parse", original.hash + "^{tree}"]).text.trimmingCharacters(in: .newlines)
                // A one-parent object applies precisely the merge-to-mainline patch. It changes no ref or index.
                let hash = try run(["commit-tree", tree] + (parent.map { ["-p", $0] } ?? []) + ["-F", messageFile.path],
                                   environmentOverrides: ["GIT_AUTHOR_NAME": original.author, "GIT_AUTHOR_EMAIL": original.email, "GIT_AUTHOR_DATE": original.date]).text.trimmingCharacters(in: .newlines)
                mapping[hash] = original.hash
                var replacement = RebaseEntry(commit: try rebaseCommit(hash), action: entry.action)
                replacement.mainline = nil; replacement.occurrence = entry.occurrence
                replay.entries[index] = replacement
            }
        }
        let path = temporary.appendingPathComponent("todo")
        // Validate the original plan first; synthetic merge IDs intentionally differ from its selections.
        let todo = replay.entries.map { $0.action.rawValue + " " + $0.commit.hash + " " + $0.commit.subject.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") }.joined(separator: "\n") + "\n"
        try Data((replay.entries.isEmpty ? "noop\n" : todo).utf8).write(to: path)
        var environment = ["GIT_SEQUENCE_EDITOR": RebaseEditor.command(executable: editorExecutable), "TURTLEGIT_REBASE_PLAN": path.path, "GIT_EDITOR": "/usr/bin/true"]
        let identityFile = temporary.appendingPathComponent("identities.json")
        try JSONEncoder().encode(plan.entries.map { RebaseReplayIdentity(hash: $0.commit.hash, occurrence: $0.occurrence) }).write(to: identityFile)
        environment["TURTLEGIT_REPLAY_IDENTITIES"] = identityFile.path
        if plan.entries.contains(where: { $0.action == .squash }) {
            let messageFile = temporary.appendingPathComponent("replay-messages.json")
            let command = RebaseEditor.messageCommand(executable: editorExecutable)
            try JSONEncoder().encode(RebaseMessageConfiguration(editorCommand: command, datePolicy: plan.options.squashDate, dates: plan.entries.map { $0.commit.date })).write(to: messageFile)
            environment["TURTLEGIT_REPLAY_MESSAGES"] = messageFile.path
            environment["GIT_EDITOR"] = command
        }
        if plan.options.isCherryPick {
            let metadata = temporary.appendingPathComponent("cherry-pick.json")
            try JSONEncoder().encode(mapping).write(to: metadata)
            environment["TURTLEGIT_CHERRY_PICK_METADATA"] = metadata.path
        }
        var args = ["rebase", "--no-autostash"]
        if plan.options.force || plan.options.isCherryPick || plan.hasAddedCommits { args += ["--force-rebase", "--reapply-cherry-picks"] }
        // Interactive replay stops for patches that become empty, including on Git versions predating --empty=stop.
        if plan.options.isCherryPick { args.append("--keep-empty") }
        if plan.options.preserveMerges { args.append("--rebase-merges") }
        else { args.append("--interactive") }
        args += ["--onto", plan.ontoHash, "--", plan.upstreamHash, plan.branchReference.isEmpty ? plan.branchHash : String(plan.branchReference.dropFirst(11))]
        return try executeRebase(args, environment: environment)
    }
    public func continueRebase(squashMessage: String? = nil, editMessage: String? = nil) throws -> RebaseExecution {
        let state = try rebaseState()
        guard state.active else { throw RebaseFailure.inactive }
        if let split = state.split {
            guard split.parts > 0, try rebaseRevision("HEAD") == split.expectedHead, !(try rebaseSplitHasRemainingChanges()) else { throw RebaseFailure.plan }
            if split.conflictRecovery != true { try FileManager.default.removeItem(at: rebasePath("rebase-merge/turtlegit-split.json")) }
        }
        var output = ""
        if state.isEditPause, state.split == nil || state.split?.conflictRecovery == true, state.squashMessage == nil, let editMessage {
            output = try amendRebaseCommit(message: editMessage)
            if var continuation = state.split, continuation.conflictRecovery == true {
                continuation.expectedHead = try rebaseRevision("HEAD")
                try JSONEncoder().encode(continuation).write(to: rebasePath("rebase-merge/turtlegit-split.json"), options: .atomic)
            }
        }
        if var pending = state.squashMessage {
            guard let squashMessage, !squashMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RebaseFailure.message }
            pending.message = squashMessage
            let request = try rebasePath("rebase-merge/turtlegit-squash-message.json")
            try JSONEncoder().encode(pending).write(to: request, options: .atomic)
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data(squashMessage.utf8).write(to: temporary)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let date: String
            switch pending.datePolicy {
            case .first: date = try rebaseCommit("HEAD").date
            case .latest: date = pending.latestDate
            case .current: date = ISO8601DateFormatter().string(from: Date())
            }
            output = try run(["commit", "--amend", "--cleanup=verbatim", "-F", temporary.path, "--date", date]).text
            try FileManager.default.removeItem(at: request)
        }
        let result = try recoverRebase("--continue")
        return RebaseExecution(output: output + result.output, exitCode: result.exitCode, state: result.state)
    }
    public func skipRebase() throws -> RebaseExecution { try recoverRebase("--skip") }
    public func abortRebase() throws -> RebaseExecution { try recoverRebase("--abort") }
    private func recoverRebase(_ action: String) throws -> RebaseExecution {
        guard try rebaseState().active else { throw RebaseFailure.inactive }
        let configuration = try rebasePath("rebase-merge/turtlegit-message-editor.json")
        let config = FileManager.default.fileExists(atPath: configuration.path) ? try JSONDecoder().decode(RebaseMessageConfiguration.self, from: Data(contentsOf: configuration)) : nil
        return try executeRebase(["rebase", action], environment: ["GIT_EDITOR": config?.editorCommand ?? "/usr/bin/true"])
    }
    private func executeRebase(_ arguments: [String], environment: [String: String]) throws -> RebaseExecution {
        do { let output = try run(arguments, environmentOverrides: environment).text; return RebaseExecution(output: output, exitCode: 0, state: try rebaseState()) }
        catch let failure as GitFailure { return RebaseExecution(output: failure.message, exitCode: failure.code, state: try rebaseState()) }
    }
    public func amendRebaseCommit(message: String) throws -> String {
        guard try rebaseState().active else { throw RebaseFailure.inactive }
        let state = try rebaseState()
        guard state.squashMessage == nil && (state.split == nil || state.split?.conflictRecovery == true) else { throw RebaseFailure.plan }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RebaseFailure.message }
        let base = try commitComparisonBase(amendToParent: true)
        let originallyEmpty = try run(["diff", "--quiet", base, "HEAD", "--"], successfulExitCodes: 0...1).exitCode == 0
        return try run(["commit", "--amend", "-m", message] + (originallyEmpty ? ["--allow-empty"] : [])).text
    }
    public func beginRebaseSplit() throws -> RebaseSplitState {
        let state = try rebaseState()
        guard state.canSplit else { throw RebaseFailure.plan }
        if let split = state.split, split.conflictRecovery != true { return split }
        let head = try rebaseCommit("HEAD")
        if let recovery = state.split, recovery.conflictRecovery == true, recovery.expectedHead != head.hash { throw RebaseFailure.changed }
        var split = RebaseSplitState(entryID: state.stoppedEntryID, step: state.currentStep, expectedHead: head.hash, parts: 0,
                                     firstAuthor: head.author + " <" + head.email + ">", firstDate: state.squashMessage?.datePolicy == .latest ? state.squashMessage!.latestDate : head.date,
                                     squashDate: state.squashMessage?.datePolicy)
        if let recovery = state.split, recovery.conflictRecovery == true {
            split.conflictRecoveryReturn = RebaseSplitReturn(parts: recovery.parts, firstAuthor: recovery.firstAuthor, firstDate: recovery.firstDate, squashDate: recovery.squashDate)
        }
        try JSONEncoder().encode(split).write(to: rebasePath("rebase-merge/turtlegit-split.json"), options: .atomic)
        return split
    }
    /// Commit checked conflict-resolution files against destination HEAD. The
    /// durable continuation record keeps excluded index/worktree changes available
    /// for the native amend loop; Git's original replay metadata remains in place.
    private func checkedRebaseRecovery(paths: Set<String>, expected: RebaseState, expectedHead: String) throws -> (RebaseState, [StatusEntry]) {
        let state = try rebaseState()
        guard state.active, state.needsFileRecovery, state.split == nil, state.conflicts.isEmpty, state.stoppedAction == .pick || state.stoppedAction == .edit,
              state.currentStep == expected.currentStep, state.stoppedEntryID == expected.stoppedEntryID,
              state.originalHead == expected.originalHead, try rebaseRevision("HEAD") == expectedHead else { throw RebaseFailure.changed }
        let changes = try status()
        let checked = changes.filter { paths.contains($0.path) }
        guard checked.count == paths.count, checked.allSatisfy({ $0.state != .ignored && $0.state != .untracked }), !changes.contains(where: { $0.state == .conflicted }) else { throw RebaseFailure.plan }
        return (state, checked)
    }
    public func rebaseConflictSelectionIsEmpty(paths: Set<String>, expected: RebaseState, expectedHead: String) throws -> Bool {
        let (_, checked) = try checkedRebaseRecovery(paths: paths, expected: expected, expectedHead: expectedHead)
        return try commitSelectionIsEmpty(checked: checked, base: "HEAD", fileModes: selectedStagedFileModes(checked))
    }
    public func commitRebaseConflictSelection(message: String, paths: Set<String>, expected: RebaseState, expectedHead: String, allowEmpty: Bool = false) throws -> RebaseExecution {
        let (state, checked) = try checkedRebaseRecovery(paths: paths, expected: expected, expectedHead: expectedHead)
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RebaseFailure.message }
        let modes = try selectedStagedFileModes(checked)
        if !allowEmpty, try commitSelectionIsEmpty(checked: checked, base: "HEAD", fileModes: modes) { throw RebaseFailure.emptyResult }
        let source = try rebaseCommit(state.stoppedCommit)
        var options = CommitOptions(); options.messageOnly = allowEmpty; options.author = source.author + " <" + source.email + ">"
        let output = try commitSeparateSelection(message: message, checked: checked, options: options, base: "HEAD", fileModes: modes, preservedAuthorDate: source.date)
        var continuation = RebaseSplitState(entryID: state.stoppedEntryID, step: state.currentStep, expectedHead: try rebaseRevision("HEAD"), parts: 1, firstAuthor: options.author!, firstDate: source.date, squashDate: nil)
        continuation.conflictRecovery = true
        try JSONEncoder().encode(continuation).write(to: rebasePath("rebase-merge/turtlegit-split.json"), options: .atomic)
        return RebaseExecution(output: output, exitCode: 0, state: try rebaseState())
    }
    public func rebaseSplitHasRemainingChanges() throws -> Bool {
        try status().contains { $0.state != .untracked && $0.state != .ignored }
    }
    public func cancelUnstartedRebaseSplit() throws {
        guard let split = try rebaseState().split, split.parts == 0, try rebaseRevision("HEAD") == split.expectedHead else { throw RebaseFailure.changed }
        let path = try rebasePath("rebase-merge/turtlegit-split.json")
        if let origin = split.conflictRecoveryReturn {
            guard origin.parts > 0 else { throw RebaseFailure.changed }
            var restored = RebaseSplitState(entryID: split.entryID, step: split.step, expectedHead: split.expectedHead, parts: origin.parts, firstAuthor: origin.firstAuthor, firstDate: origin.firstDate, squashDate: origin.squashDate)
            restored.conflictRecovery = true
            try JSONEncoder().encode(restored).write(to: path, options: .atomic)
        } else { try FileManager.default.removeItem(at: path) }
    }
    /// Commit each split part through the same complete selection/index backend.
    /// The first part replaces the stopped commit; later parts create children.
    public func commitRebaseSplit(message: String, paths: Set<String>, staging: Bool, options: CommitOptions, expected: RebaseSplitState) throws -> String {
        let state = try rebaseState()
        guard let saved = state.split, state.canSplit || saved.conflictRecovery == true, saved.parts == expected.parts, saved.entryID == expected.entryID,
              saved.expectedHead == expected.expectedHead, try rebaseRevision("HEAD") == saved.expectedHead,
              options.newBranch == nil, options.amend == (saved.conflictRecovery == true || saved.parts == 0), saved.conflictRecovery == true ? options.amendDiffToLastCommit : saved.parts != 0 || !options.amendDiffToLastCommit else { throw RebaseFailure.changed }
        let output = try (staging ? commitIndex(message: message, options: options) : commitSelected(message: message, paths: paths, options: options))
        var updated = saved; updated.conflictRecoveryReturn = nil; updated.parts += 1; updated.expectedHead = try rebaseRevision("HEAD")
        try JSONEncoder().encode(updated).write(to: rebasePath("rebase-merge/turtlegit-split.json"), options: .atomic)
        if saved.parts == 0, state.squashMessage != nil { try FileManager.default.removeItem(at: rebasePath("rebase-merge/turtlegit-squash-message.json")) }
        return output
    }
}
