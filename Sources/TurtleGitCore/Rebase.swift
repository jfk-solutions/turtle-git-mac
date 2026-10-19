import Foundation
import Darwin

public enum RebaseAction: String, CaseIterable, Codable, Sendable { case pick, skip = "drop", edit, squash }
public enum RebaseEntryProgress: Sendable { case pending, current, completed }
public enum RebaseEmptyChoice: Sendable { case commit, skip, cancel }
public enum RebaseSquashDate: Int, Codable, Sendable { case first = 0, latest = 1, current = 2 }
public struct RebaseSquashMessage: Codable, Sendable {
    public var message: String
    public let datePolicy: RebaseSquashDate
    public let latestDate: String
    public let step: Int
    public var skipOriginalHead: String? = nil
    public var skipBaseHead: String? = nil
}
public struct RebaseSplitReturn: Codable, Sendable {
    public let parts: Int
    public let firstAuthor: String
    public let firstDate: String
    public let squashDate: RebaseSquashDate?
    public var firstParents: [String]? = nil
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
    /// Capture topology for the first replacement part; later parts are children.
    public var firstParents: [String]? = nil
}
public struct RebaseEntry: Identifiable, Sendable {
    public var id: String { occurrence == 0 ? commit.hash : commit.hash + ":" + String(occurrence) }
    public var occurrence = 0
    public let commit: LogEntry
    public var action: RebaseAction = .pick
    public var progress: RebaseEntryProgress = .pending
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
public struct RebaseSessionContext: Codable, Sendable {
    public let version: Int
    public let branch: String
    public let upstream: String
    public let onto: String
    public let force: Bool
    public let preserveMerges: Bool
    public let afterFetch: Bool
    public let autoStart: Bool
    public let fromLog: Bool?
    public let addCherryPickedFrom: Bool?
    init(options: RebaseOptions, afterFetch: Bool, autoStart: Bool, fromLog: Bool) {
        version = 1; branch = options.branch; upstream = options.upstream; onto = options.onto
        force = options.force; preserveMerges = options.preserveMerges
        self.afterFetch = afterFetch && !options.isCherryPick; self.autoStart = autoStart && self.afterFetch; self.fromLog = fromLog && !options.isCherryPick; addCherryPickedFrom = options.addCherryPickedFrom
    }
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
public struct RebaseState: Codable, Sendable {
    public let active: Bool
    public let isCherryPick: Bool
    public let branch: String
    public let originalHead: String
    public let onto: String
    public let stoppedEntryID: String
    public let stoppedCommit: String
    public let mergeParents: [String]
    public let message: String
    public let currentStep: Int
    public let total: Int
    public let conflicts: [String]
    public let remainingCommands: [String]
    public let squashMessage: RebaseSquashMessage?
    public let stoppedAction: RebaseAction?
    public let split: RebaseSplitState?
    public let isEditPause: Bool
    public let isStructuralMergeEdit: Bool
    public let hasStructuralMergeResult: Bool
    public let needsFileRecovery: Bool
    public let session: RebaseSessionContext?
    public var hasFailedPickCleanup = false
    public var canSplit: Bool { !hasFailedPickCleanup && active && conflicts.isEmpty && (isEditPause || squashMessage != nil && squashMessage?.skipBaseHead == nil || split != nil && split?.conflictRecovery != true) }
}
/// Identifies the stopped occurrence and original session, not just its step number.
public struct RebaseConflictIdentity:Equatable,Sendable {
    public let originalHead:String,branch:String,onto:String,entry:String
    public let step:Int,splitParts:Int
    public let cherryPick:Bool
    public static func == (a: Self, b: Self) -> Bool {
        GitReferenceName.equal(a.originalHead,b.originalHead) && GitReferenceName.equal(a.branch,b.branch) && GitReferenceName.equal(a.onto,b.onto) && GitReferenceName.equal(a.entry,b.entry) && a.step == b.step && a.splitParts == b.splitParts && a.cherryPick == b.cherryPick
    }
    public init?(_ state:RebaseState) {
        guard state.active,!state.hasFailedPickCleanup,state.squashMessage?.skipBaseHead == nil else {return nil}
        originalHead=state.originalHead;branch=state.branch;onto=state.onto;entry=state.stoppedEntryID
        step=state.currentStep;splitParts=state.split?.parts ?? 0;cherryPick=state.isCherryPick
    }
}
public struct RebaseSessionSnapshot:Sendable {
    public let state:RebaseState
    public let identity:RebaseConflictIdentity?
    public let fileRecovery:Bool
    public let conflicts:[ConflictEntry]
    public let rows:[StatusEntry]
    public let statistics:GitPathMap<CommitFile>
    public var indexFlags:GitPathMap<FinderIndexFlags>=[:]
    public let head:String
    public let remaining:[RebaseEntry],replay:[RebaseEntry]
    public var messageCommit: LogEntry? = nil
}

/// A draft belongs to one stopped occurrence and applied HEAD, never just a
/// repository path or step number. Changing the applied object retires it.
public struct RebaseMessageIdentity: Codable, Equatable, Sendable {
    public let originalHead: String, branch: String, onto: String, entry: String, head: String, phase: String
    public let step: Int
    public init?(state: RebaseState, head: String) {
        guard state.active, !state.hasFailedPickCleanup, !head.isEmpty, state.needsFileRecovery || state.isEditPause || state.squashMessage != nil || state.split != nil else { return nil }
        originalHead = state.originalHead; branch = state.branch; onto = state.onto; entry = state.stoppedEntryID; self.head = head; step = state.currentStep
        phase = state.squashMessage != nil ? "squash" : state.split?.conflictRecovery == true ? "amend-selection" : state.split != nil ? "split" : state.isEditPause ? "edit" : "conflict"
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.step == rhs.step && lhs.phase == rhs.phase &&
            zip([lhs.originalHead, lhs.branch, lhs.onto, lhs.entry, lhs.head], [rhs.originalHead, rhs.branch, rhs.onto, rhs.entry, rhs.head]).allSatisfy { GitReferenceName.equal($0.0, $0.1) }
    }
}
public struct RebaseMessageDraft: Codable, Sendable {
    public let identity: RebaseMessageIdentity
    public let message: String
    public init(identity: RebaseMessageIdentity, message: String) { self.identity = identity; self.message = message }
}

public struct RebaseExecution: Sendable {
    public let output: String
    public let exitCode: Int32
    public let state: RebaseState
    public let witnessedHead: String?
    public let witnessedSession: String?
    public init(output: String, exitCode: Int32, state: RebaseState, witnessedHead: String? = nil, witnessedSession: String? = nil) {
        self.output=output;self.exitCode=exitCode;self.state=state;self.witnessedHead=witnessedHead;self.witnessedSession=witnessedSession
    }
}
public enum RebaseFailure: LocalizedError {
    case revision, active, inactive, changed, plan, squash, preservePlan, message, mainline, emptyResult, actionEditLocked
    public var errorDescription: String? {
        switch self {
        case .actionEditLocked: return "The replay plan is being changed by another operation. Try again when it finishes."
        case .revision: return "Choose valid branch, upstream and onto revisions."
        case .active: return "A rebase is already active. Continue, skip or abort that operation first."
        case .inactive: return "No rebase is active in this repository."
        case .changed: return "A selected reference changed after the commit plan was loaded. Reload the plan before starting."
        case .plan: return "The commit plan contains missing, duplicate or unexpected commits."
        case .squash: return "The first retained commit cannot be squashed."
        case .preservePlan: return "This structural plan requires unsupported actions or a merge whose first parent has not been replayed yet."
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
    static func canonicalCommand(_ command: String) -> String {
        ["p":"pick", "e":"edit", "s":"squash", "d":"drop", "m":"merge",
         "l":"label", "t":"reset", "u":"update-ref", "b":"break", "f":"fixup"][command] ?? command
    }
    static func canonicalLine(_ line: String) -> String {
        let fields = line.split(separator:" ",maxSplits:1).map(String.init)
        guard let command = fields.first else { return line }
        return ([canonicalCommand(command)] + fields.dropFirst()).joined(separator:" ")
    }
    public static func handle(arguments: [String], environment: [String: String]) -> Int32? {
        if arguments.dropFirst().first == messageArgument { return handleMessage(arguments: arguments) }
        guard arguments.dropFirst().first == argument else { return nil }
        guard arguments.count == 3, let source = environment["TURTLEGIT_REBASE_PLAN"] else { return 1 }
        do {
            let target = URL(fileURLWithPath: arguments[2])
            let custom = try String(contentsOf: URL(fileURLWithPath: source), encoding: .utf8)
            let generated = FileManager.default.fileExists(atPath: target.path) ? try String(contentsOf: target, encoding: .utf8) : ""
            let identityData = try environment["TURTLEGIT_REPLAY_IDENTITIES"].map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
            let identities = try identityData.map { try JSONDecoder().decode([RebaseReplayIdentity].self, from: $0) } ?? []
            var originals: [String: Int] = [:]
            for (index, identity) in identities.enumerated() where identity.occurrence == 0 {
                guard originals.updateValue(index, forKey: identity.hash) == nil else { throw RebaseFailure.plan }
            }
            let merged = try environment["TURTLEGIT_STRUCTURAL_PLAN"] == "1" ? mergeStructuralReferenceUpdates(generated:generated,custom:custom) : mergeReferenceUpdates(generated: generated, custom: custom, originalPositions: originals)
            try Data(merged.todo.utf8).write(to: target, options: .atomic)
            if merged.hasUpdates { try Data().write(to: target.deletingLastPathComponent().appendingPathComponent("turtlegit-update-refs"), options: .atomic) }
            if environment["TURTLEGIT_STRUCTURAL_PLAN"] == "1" { try Data().write(to:target.deletingLastPathComponent().appendingPathComponent("turtlegit-structural-plan")) }
            if let metadata = environment["TURTLEGIT_CHERRY_PICK_METADATA"] {
                try Data(contentsOf: URL(fileURLWithPath: metadata)).write(to: target.deletingLastPathComponent().appendingPathComponent("turtlegit-cherry-pick.json"), options: .atomic)
            }
            if let identityData {
                try identityData.write(to: target.deletingLastPathComponent().appendingPathComponent("turtlegit-replay-identities.json"), options: .atomic)
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
    static func mergeReferenceUpdates(generated: String, custom: String, originalPositions: [String: Int] = [:]) throws -> (todo: String, hasUpdates: Bool) {
        let rows = custom.split(separator: "\n").map(String.init)
        let fields = rows.map { $0.split(separator: " ", maxSplits: 2).map(String.init) }
        var updates: [Int: [String]] = [:], preceding = ""
        for line in generated.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard let command = parts.first else { continue }
            if ["pick", "p", "drop", "d", "edit", "e", "squash", "s", "reword", "r", "fixup", "f"].contains(command), parts.count >= 2 { preceding = parts[1] }
            if command == "update-ref" || command == "u" {
                guard parts.count == 2, parts[1].hasPrefix("refs/heads/"), !preceding.isEmpty else { throw RebaseFailure.plan }
                let matches = fields.indices.filter { fields[$0].count >= 2 && fields[$0][1].hasPrefix(preceding) }
                guard let match = matches.first else { throw RebaseFailure.plan }
                var index: Int
                if let original = originalPositions[fields[match][1]], matches.contains(original) { index = original }
                else { guard matches.count == 1 else { throw RebaseFailure.plan }; index = match }
                // References inside a Squash group must name its final result,
                // including the destination parent when the whole group is skipped.
                var next = index + 1
                while next < fields.count {
                    if fields[next].first == RebaseAction.skip.rawValue { next += 1; continue }
                    guard fields[next].first == RebaseAction.squash.rawValue else { break }
                    index = next; next += 1
                }
                updates[index, default: []].append(line.description)
            }
        }
        guard !updates.isEmpty else { return (custom, false) }
        return (rows.indices.flatMap { [rows[$0]] + (updates[$0] ?? []) }.joined(separator: "\n") + "\n", true)
    }
    static func mergeStructuralReferenceUpdates(generated:String,custom:String) throws -> (todo:String,hasUpdates:Bool) {
        var preceding = "", updates: [String:[String]] = [:]
        for line in generated.split(separator:"\n") {
            let fields = canonicalLine(String(line)).split(separator:" ").map(String.init)
            if fields.first.map({ ["pick","edit","squash","drop"].contains($0) }) == true, fields.count >= 2 { preceding = fields[1] }
            else if fields.first == "merge", fields.count >= 3, ["-C","-c"].contains(fields[1]) { preceding = fields[2] }
            else if fields.first == "label", fields.count == 2, fields[1].hasPrefix("turtlegit-"), fields[1] != "turtlegit-onto" { preceding = String(fields[1].dropFirst("turtlegit-".count)) }
            else if fields.first == "update-ref" {
                guard fields.count == 2, fields[1].hasPrefix("refs/heads/"), !preceding.isEmpty else { throw RebaseFailure.plan }
                let labels = custom.split(separator:"\n").map(String.init).filter { $0.hasPrefix("label turtlegit-") && $0.dropFirst("label turtlegit-".count).hasPrefix(preceding) }
                guard labels.count == 1 else { throw RebaseFailure.plan }
                updates[labels[0],default:[]].append(String(line))
            }
        }
        return (custom.split(separator:"\n").flatMap { [String($0)] + (updates[String($0)] ?? []) }.joined(separator:"\n") + "\n", !updates.isEmpty)
    }
    /// Ordinary replay recovery must not silently discard custom instructions.
    /// Only generated update-ref records may accompany the owned action rows.
    static func ordinaryReplayCommands(in directory:URL)->Bool {
        guard !FileManager.default.fileExists(atPath:directory.appendingPathComponent("turtlegit-structural-plan").path),
              let identities=try? JSONDecoder().decode([RebaseReplayIdentity].self,from:Data(contentsOf:directory.appendingPathComponent("turtlegit-replay-identities.json"))),!identities.isEmpty else {return false}
        let mapping=(try? JSONDecoder().decode([String:String].self,from:Data(contentsOf:directory.appendingPathComponent("turtlegit-cherry-pick.json")))) ?? [:]
        func oid(_ hash:String)->Bool {[40,64].contains(hash.utf8.count) && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }}
        func branch(_ ref:String)->Bool {
            ref.hasPrefix("refs/heads/") && !ref.hasSuffix(".") && !ref.contains("..") && !ref.contains("@{") &&
            !ref.utf8.contains(where:{$0<=32 || $0==127 || "~^:?*[\\".utf8.contains($0)}) &&
            !ref.split(separator:"/",omittingEmptySubsequences:false).contains {$0.isEmpty || $0.hasPrefix(".") || $0.hasSuffix(".lock")}
        }
        var updates=Set<GitReferenceName>()
        if FileManager.default.fileExists(atPath:directory.appendingPathComponent("turtlegit-update-refs").path),
           let state=try? String(contentsOf:directory.appendingPathComponent("update-refs"),encoding:.utf8) {
            let rows=state.split(separator:"\n",omittingEmptySubsequences:false).map(String.init)
            let fields=rows.last=="" ? Array(rows.dropLast()) : rows
            guard fields.count%3==0 else {return false}
            for index in stride(from:0,to:fields.count,by:3) {
                guard branch(fields[index]),oid(fields[index+1]),oid(fields[index+2]) else {return false}
                updates.insert(GitReferenceName(fields[index]))
            }
        }
        for name in ["git-rebase-todo","done"] {
            guard let text=try? String(contentsOf:directory.appendingPathComponent(name),encoding:.utf8) else {return false}
            for raw in text.components(separatedBy:"\n") {
                let line=raw.trimmingCharacters(in:.whitespaces)
                if line.isEmpty || line.hasPrefix("#") {continue}
                let fields=canonicalLine(line).split(separator:" ",maxSplits:2).map(String.init)
                guard let command=fields.first else {return false}
                if RebaseAction(rawValue:command) != nil {
                    guard fields.count>=2,fields[1].utf8.count>=4,fields[1].utf8.allSatisfy({(48...57).contains($0) || (97...102).contains($0)}) else {return false}
                    let originals=mapping.filter {$0.key.hasPrefix(fields[1])}.map(\.value)
                    guard identities.contains(where:{identity in originals.isEmpty ? identity.hash.hasPrefix(fields[1]) : originals.contains(identity.hash)}) else {return false}
                } else {
                    guard command=="update-ref",fields.count==2,updates.contains(GitReferenceName(fields[1])) else {return false}
                }
            }
        }
        return true
    }
    /// Git 2.39 reschedules negative Pick failures while retaining stopped-sha,
    /// and save_todo may append the preceding command to done a second time.
    /// Identify the occurrence by the complete owned remaining plan, never by
    /// a hash alone (the same commit may deliberately occur more than once).
    static func rescheduledPick(in directory:URL)->(step:Int,doneLine:Int,duplicateLine:Int?)? {
        guard ordinaryReplayCommands(in:directory),
              let identities = try? JSONDecoder().decode([RebaseReplayIdentity].self,from:Data(contentsOf:directory.appendingPathComponent("turtlegit-replay-identities.json"))),
              let todo = try? String(contentsOf:directory.appendingPathComponent("git-rebase-todo"),encoding:.utf8),
              let done = try? String(contentsOf:directory.appendingPathComponent("done"),encoding:.utf8) else {return nil}
        let mapping = (try? JSONDecoder().decode([String:String].self,from:Data(contentsOf:directory.appendingPathComponent("turtlegit-cherry-pick.json")))) ?? [:]
        func fields(_ line:String)->[String] {canonicalLine(line).split(separator:" ",maxSplits:2).map(String.init)}
        func matches(_ fields:[String],_ identity:RebaseReplayIdentity)->Bool {
            guard fields.count>=2,fields[0]==identity.action else {return false}
            let hash = mapping.first(where:{$0.key.hasPrefix(fields[1])})?.value ?? fields[1]
            return identity.hash.hasPrefix(hash)
        }
        let scheduled = todo.components(separatedBy:"\n").map(fields).filter { $0.first.flatMap(RebaseAction.init(rawValue:)) != nil }
        let index = identities.count - scheduled.count
        guard index>=0,index<identities.count,scheduled.first?.first=="pick",
              zip(scheduled,identities.dropFirst(index)).allSatisfy({matches($0.0,$0.1)}) else {return nil}
        let skipped = (try? JSONDecoder().decode(Set<Int>.self,from:Data(contentsOf:directory.appendingPathComponent("turtlegit-skipped-steps.json")))) ?? []
        let lines = done.components(separatedBy:"\n")
        let commands = lines.indices.filter { !lines[$0].trimmingCharacters(in:.whitespaces).isEmpty && !lines[$0].hasPrefix("#") }
        let actionable = commands.filter { fields(lines[$0]).first.flatMap(RebaseAction.init(rawValue:)) != nil }
        guard actionable.count>=index+1,
              zip(actionable.prefix(index+1),identities.prefix(index+1)).enumerated().allSatisfy({ item in
                  var command = fields(lines[item.element.0])
                  if command.first=="drop",skipped.contains(item.offset+1) {command[0]=item.element.1.action ?? "pick"}
                  return matches(command,item.element.1)
              }) else {return nil}
        let current = actionable[index]
        let trailing = commands.filter {$0>current}
        if trailing.isEmpty {return (index+1,current,nil)}
        guard trailing.count==1,let previous=commands.last(where:{$0<current}),
              canonicalLine(lines[trailing[0]])==canonicalLine(lines[previous]) else {return nil}
        return (index+1,current,trailing[0])
    }
    static func currentStep(in directory: URL) -> Int {
        if let resumed = rescheduledPick(in:directory) {return resumed.step}
        if FileManager.default.fileExists(atPath:directory.appendingPathComponent("turtlegit-structural-plan").path) {
            let done = (try? String(contentsOf:directory.appendingPathComponent("done"),encoding:.utf8)) ?? ""
            let identities = (try? JSONDecoder().decode([RebaseReplayIdentity].self,from:Data(contentsOf:directory.appendingPathComponent("turtlegit-replay-identities.json")))) ?? []
            var step = 1
            for line in done.split(separator:"\n") {
                let fields = line.split(separator:" ").map(String.init)
                guard let rawCommand = fields.first else { continue }
                let command = canonicalCommand(rawCommand)
                let hash: String?
                if ["pick","edit","squash","drop"].contains(command), fields.count >= 2 { hash = fields[1] }
                else if command == "merge", fields.count >= 3 { hash = fields[2] }
                else if command == "label", fields.count == 2, fields[1].hasPrefix("turtlegit-"), fields[1] != "turtlegit-onto" { hash = String(fields[1].dropFirst("turtlegit-".count)) }
                else { hash = nil }
                if let hash, let index = identities.firstIndex(where: { $0.hash.hasPrefix(hash) }) { step = max(step,index + (command == "label" ? 2 : 1)) }
            }
            return step
        }
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("turtlegit-update-refs").path) {
            let done = (try? String(contentsOf: directory.appendingPathComponent("done"), encoding: .utf8)) ?? ""
            return done.split(separator: "\n").filter { $0.split(separator: " ").first.flatMap { RebaseAction(rawValue: String($0)) } != nil }.count
        }
        for file in ["msgnum", "next"] {
            if let text = try? String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8), let step = Int(text.trimmingCharacters(in: .newlines)) { return step }
        }
        return 0
    }
    private static func handleMessage(arguments: [String]) -> Int32 {
        guard arguments.count == 3 else { return 1 }
        let directory = URL(fileURLWithPath: arguments[2]).deletingLastPathComponent().appendingPathComponent("rebase-merge")
        let configuration = directory.appendingPathComponent("turtlegit-message-editor.json")
        let squash = directory.appendingPathComponent("message-squash")
        guard FileManager.default.fileExists(atPath: configuration.path), FileManager.default.fileExists(atPath: squash.path) else { return 0 }
        do {
            let config = try JSONDecoder().decode(RebaseMessageConfiguration.self, from: Data(contentsOf: configuration))
            let step = currentStep(in: directory)
            guard config.dates.indices.contains(step - 1) else { return 1 }
            let text = try CommitMessageEncoding.decode(Data(contentsOf: squash), name: config.commitEncoding ?? "")
            // Remove only Git's combination headings. Literal comment-prefixed
            // message lines remain editable and are committed verbatim.
            let lines = text.components(separatedBy: "\n")
            let header = try NSRegularExpression(pattern: "^(.*) This is a combination of [0-9]+ commits\\.$")
            let first = lines.first ?? ""
            guard let match = header.firstMatch(in: first, range: NSRange(first.startIndex..., in: first)), let range = Range(match.range(at: 1), in: first) else { return 1 }
            let prefix = NSRegularExpression.escapedPattern(for: String(first[range]))
            let headings = try NSRegularExpression(pattern: "^" + prefix + " This is (a combination of [0-9]+ commits\\.|the ([0-9]+(st|nd|rd|th) commit message|commit message #[0-9]+):)$")
            var message = lines.filter { headings.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) == nil }.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if let actions = config.actions, let messages = config.messages, actions.indices.contains(step - 1), messages.count == actions.count {
                // Git omits messages for Squash steps whose conflict resolution
                // adds no changes. TortoiseGit accumulates every group message.
                // Keep Git's first section, which may contain an approved Edit,
                // and obtain later sections from the captured replay objects.
                var start = step - 1
                while start > 0 && (actions[start] == RebaseAction.squash.rawValue || actions[start] == RebaseAction.skip.rawValue) { start -= 1 }
                let boundaries = lines.indices.filter { headings.firstMatch(in: lines[$0], range: NSRange(lines[$0].startIndex..., in: lines[$0])) != nil }
                if boundaries.count >= 3 {
                    let firstMessage = lines[(boundaries[1] + 1)..<boundaries[2]].joined(separator: "\n").trimmingCharacters(in: .newlines)
                    let skippedURL = directory.appendingPathComponent("turtlegit-skipped-steps.json")
                    let skipped = FileManager.default.fileExists(atPath: skippedURL.path) ? try JSONDecoder().decode(Set<Int>.self, from: Data(contentsOf: skippedURL)) : []
                    let rest = ((start + 1)..<step).filter { actions[$0] == RebaseAction.squash.rawValue && !skipped.contains($0 + 1) }.map { messages[$0].trimmingCharacters(in: .newlines) }
                    message = ([firstMessage] + rest).joined(separator: "\n\n")
                }
            }
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
    var actions: [String]? = nil
    var messages: [String]? = nil
    var commitEncoding: String? = nil
}
private struct RebaseReplayIdentity: Codable {
    let hash: String
    let occurrence: Int
    var action: String? = nil
    var mainline: Int? = nil
    var id: String { occurrence == 0 ? hash : hash + ":" + String(occurrence) }
}
extension GitRepository {
    private func rebaseRevision(_ name: String, cancellation: OperationCancellation? = nil) throws -> String {
        try cancellation?.check()
        guard !name.isEmpty, !name.contains("\0") else { throw RebaseFailure.revision }
        guard let result = try? run(["rev-parse", "--verify", "--end-of-options", name + "^{commit}"], cancellation: cancellation) else { try cancellation?.check(); throw RebaseFailure.revision }
        try cancellation?.check()
        // Successful rev-parse can still warn (for example, ambiguous short
        // names). Diagnostics are not part of the object identity.
        let hash = String(decoding:result.stdout,as:UTF8.self).trimmingCharacters(in:.newlines)
        guard [40,64].contains(hash.utf8.count), hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw RebaseFailure.revision }
        return hash
    }
    private func rebasePath(_ name: String, cancellation: OperationCancellation? = nil) throws -> URL {
        var bytes = try run(["rev-parse", "--git-path", name], cancellation: cancellation).stdout
        if bytes.last == 10 { bytes.removeLast() }
        let path = String(decoding: bytes, as: UTF8.self)
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    }
    public func rebaseState(cancellation: OperationCancellation? = nil) throws -> RebaseState {
        try cancellation?.check()
        try recoverRebaseActionEdit(cancellation: cancellation)
        let merge = try rebasePath("rebase-merge", cancellation: cancellation), apply = try rebasePath("rebase-apply", cancellation: cancellation)
        let manager = FileManager.default
        let directory = manager.fileExists(atPath: merge.path) ? merge : apply
        let active = manager.fileExists(atPath: directory.path)
        func read(_ file: String) -> String { (try? String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)) ?? "" }
        func line(_ file: String) -> String { read(file).trimmingCharacters(in: .newlines) }
        func readMessage() throws -> String {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("message")) else { return "" }
            return try decodedCommitMessage(data, cancellation: cancellation)
        }
        let hasConflicts = active ? try hasWorkingTreeConflicts(cancellation:cancellation) : false
        let conflicts = hasConflicts ? try run(["diff", "--name-only", "--diff-filter=U", "-z"], cancellation: cancellation).stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) } : []
        let metadataURL = directory.appendingPathComponent("turtlegit-cherry-pick.json")
        let mapping = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: metadataURL))) ?? [:]
        let stopped = line("stopped-sha")
        let commands = read("git-rebase-todo").split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }.map { command -> String in
            var fields = RebaseEditor.canonicalLine(command).split(separator: " ", maxSplits: 2).map(String.init)
            if fields.count >= 2, let original = mapping[fields[1]] { fields[1] = original }
            return fields.joined(separator: " ")
        }
        let step = RebaseEditor.currentStep(in: directory)
        let identities = replayIdentities(directory)
        let structural = manager.fileExists(atPath:directory.appendingPathComponent("turtlegit-structural-plan").path)
        let done = read("done").split(separator: "\n").map { RebaseEditor.canonicalLine(String($0)) }
        let mergeEdit = active && structural && done.last?.split(separator:" ").first == "break" && identities.indices.contains(step - 1) && identities[step - 1].action == RebaseAction.edit.rawValue && commands.first == "label turtlegit-" + identities[step - 1].hash
        let mergeReplay = active && structural && done.last?.split(separator:" ").first == "merge" && identities.indices.contains(step - 1)
        let originalStopped = mergeEdit || mergeReplay ? identities[step - 1].hash : mapping[stopped] ?? stopped
        let stoppedIdentity = identities.indices.contains(step - 1) && identities[step - 1].hash == originalStopped ? identities[step - 1].id : originalStopped
        let requestURL = directory.appendingPathComponent("turtlegit-squash-message.json")
        let request = active && manager.fileExists(atPath: requestURL.path) ? try JSONDecoder().decode(RebaseSquashMessage.self, from: Data(contentsOf: requestURL)) : nil
        let splitURL = directory.appendingPathComponent("turtlegit-split.json")
        let split = active && manager.fileExists(atPath: splitURL.path) ? try JSONDecoder().decode(RebaseSplitState.self, from: Data(contentsOf: splitURL)) : nil
        let storedSession = active ? try? JSONDecoder().decode(RebaseSessionContext.self, from: Data(contentsOf: directory.appendingPathComponent("turtlegit-session.json"))) : nil
        let session = storedSession?.version == 1 ? storedSession : nil
        let referenceUpdates = manager.fileExists(atPath: directory.appendingPathComponent("turtlegit-update-refs").path)
        let lastCommand = (referenceUpdates ? done.filter { $0.split(separator: " ").first.flatMap { RebaseAction(rawValue: String($0)) } != nil } : done).last?.split(separator: " ").first.map(String.init)
        let action: RebaseAction? = mergeEdit ? .edit : mergeReplay ? identities[step - 1].action.flatMap(RebaseAction.init(rawValue:)) : lastCommand.flatMap(RebaseAction.init(rawValue:))
        let editPause = active && conflicts.isEmpty && action == .edit && (mergeEdit || manager.fileExists(atPath: directory.appendingPathComponent("amend").path) || split?.step == step && (split?.conflictRecovery == true && (split?.parts ?? 0) > 0 || split?.conflictRecoveryReturn != nil))
        let pending = request?.step == step && conflicts.isEmpty ? request : nil
        let activeSplit = split?.step == step && split?.entryID == stoppedIdentity ? split : nil
        let mergeResult = active && structural && (editPause || pending != nil) ? try rebaseCommit("HEAD", cancellation: cancellation).parents.count > 1 : false
        try cancellation?.check()
        var result = RebaseState(active: active, isCherryPick: active && manager.fileExists(atPath: metadataURL.path), branch: line("head-name"), originalHead: line("orig-head"), onto: line("onto"),
                           stoppedEntryID: stoppedIdentity, stoppedCommit: originalStopped, mergeParents: active ? ((try? String(contentsOf:rebasePath("MERGE_HEAD", cancellation: cancellation),encoding:.utf8)) ?? "").split(whereSeparator: \.isWhitespace).map(String.init) : [], message: mergeEdit || activeSplit?.conflictRecovery == true || activeSplit?.conflictRecoveryReturn != nil ? try rebaseCommit("HEAD", cancellation: cancellation).message : try readMessage(), currentStep: step,
                           total: referenceUpdates || structural ? identities.count : Int(line("end")) ?? Int(line("last")) ?? 0, conflicts: conflicts,
                           remainingCommands: structural ? commands.compactMap { command in
                               let fields = command.split(separator:" ").map(String.init)
                               if fields.first == "pick" || fields.first == "edit" || fields.first == "squash" || fields.first == "drop" { return command }
                               if fields.first == "merge", fields.count >= 3 { return "pick " + fields[2] }
                               return nil
                           } : commands, squashMessage: pending, stoppedAction: action, split: activeSplit,
                           isEditPause: editPause, isStructuralMergeEdit: mergeEdit, hasStructuralMergeResult: mergeResult, needsFileRecovery: active && !manager.fileExists(atPath:directory.appendingPathComponent(Self.failedPickIntentName).path) && (!conflicts.isEmpty || !originalStopped.isEmpty && !editPause && pending == nil && activeSplit == nil), session: session)
        result.hasFailedPickCleanup = active && manager.fileExists(atPath:directory.appendingPathComponent(Self.failedPickIntentName).path)
        return result
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
    public func addingRebaseCommits(_ plan: RebasePlan, revisions: [String], cancellation: OperationCancellation? = nil) throws -> RebasePlan {
        try cancellation?.check()
        guard !(try rebaseState(cancellation: cancellation).active) else { throw RebaseFailure.active }
        guard !plan.options.preserveMerges else { throw RebaseFailure.preservePlan }
        try validateRebaseIdentities(plan)
        if revisions.isEmpty { return plan }
        let entries = try addingRebaseEntries(plan.entries, revisions: revisions, cancellation: cancellation)
        var value = RebasePlan(disposition: .ready, options: plan.options, branchHash: plan.branchHash, upstreamHash: plan.upstreamHash,
                               ontoHash: plan.ontoHash, branchReference: plan.branchReference, originalCommits: entries.map(\.id), entries: entries)
        value.hasAddedCommits = true
        try cancellation?.check()
        return value
    }
    /// Resolve Add selections without requiring branch/upstream fields to be complete.
    public func addingRebaseEntries(_ existing: [RebaseEntry], revisions: [String], cancellation: OperationCancellation? = nil) throws -> [RebaseEntry] {
        try cancellation?.check()
        guard !(try rebaseState(cancellation: cancellation).active) else { throw RebaseFailure.active }
        guard Set(existing.map(\.id)).count == existing.count, existing.allSatisfy({ $0.occurrence >= 0 }) else { throw RebaseFailure.plan }
        let commits = try revisions.reversed().map { try rebaseCommit($0, cancellation: cancellation) }
        var entries = existing
        for commit in commits {
            var entry = RebaseEntry(commit: commit)
            entry.occurrence = entries.filter { $0.commit.hash == commit.hash }.map(\.occurrence).max().map { $0 + 1 } ?? 0
            entries.append(entry)
        }
        try cancellation?.check()
        return entries
    }
    private func currentRebaseBranch(cancellation: OperationCancellation? = nil) throws -> String {
        try cancellation?.check()
        let value = ((try? run(["symbolic-ref", "--quiet", "HEAD"], cancellation: cancellation).text) ?? "").trimmingCharacters(in: .newlines)
        try cancellation?.check(); return value
    }
    /// Input follows the Log's newest-first visible selection; execution is oldest-first.
    public func cherryPickPlan(revisions: [String], cancellation: OperationCancellation? = nil) throws -> RebasePlan {
        guard !(try rebaseState(cancellation: cancellation).active) else { throw RebaseFailure.active }
        guard !revisions.isEmpty else { throw RebaseFailure.plan }
        let commits = try revisions.reversed().map { try rebaseCommit($0, cancellation: cancellation) }
        guard Set(commits.map(\.hash)).count == commits.count else { throw RebaseFailure.plan }
        let head = try rebaseRevision("HEAD", cancellation: cancellation), branch = try currentRebaseBranch(cancellation: cancellation)
        var options = RebaseOptions(); options.branch = "HEAD"; options.upstream = head; options.force = true; options.isCherryPick = true
        try cancellation?.check()
        return RebasePlan(disposition: .ready, options: options, branchHash: head, upstreamHash: head, ontoHash: head,
                          branchReference: branch, originalCommits: commits.map(\.hash), entries: commits.map { RebaseEntry(commit: $0) })
    }
    public func rebasePlan(_ options: RebaseOptions, cancellation: OperationCancellation? = nil) throws -> RebasePlan {
        try cancellation?.check()
        guard !options.isCherryPick else { throw RebaseFailure.plan }
        guard !(try rebaseState(cancellation: cancellation).active) else { throw RebaseFailure.active }
        let branchHash = try rebaseRevision(options.branch, cancellation: cancellation), upstreamHash = try rebaseRevision(options.upstream, cancellation: cancellation)
        let ontoHash = options.onto.isEmpty ? upstreamHash : try rebaseRevision(options.onto, cancellation: cancellation)
        let symbolicBytes = (try? run(["rev-parse", "--symbolic-full-name", "--verify", "--end-of-options", options.branch], cancellation:cancellation).stdout) ?? Data()
        let symbolic = String(decoding:symbolicBytes,as:UTF8.self).trimmingCharacters(in:.newlines)
        try cancellation?.check()
        let branchReference = symbolic.hasPrefix("refs/heads/") ? symbolic : ""
        var args = ["log", "--encoding=UTF-8", "--reverse", "--topo-order", "--format=%H%x00%P%x00%an%x00%ae%x00%aI%x00%s%x00%B%x00%cn%x00%ce%x00%cI%x00"]
        if !options.preserveMerges { args.append("--no-merges") }
        args += [upstreamHash + ".." + branchHash, "--"]
        let commits = LogEntry.parseReplayHistory(try run(args, cancellation: cancellation).stdout)
        let cherry = try run(["cherry", upstreamHash, branchHash], cancellation: cancellation).text
        let redundant = Set(cherry.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: " "); return parts.count == 2 && parts[0] == "-" ? String(parts[1]) : nil
        })
        let disposition: RebaseDisposition
        if branchHash == ontoHash && branchHash == upstreamHash { disposition = .equal }
        else if options.onto.isEmpty && !options.force {
            let forward = try replayMergeBase(from:branchHash,to:upstreamHash,cancellation:cancellation)
            if forward.fastForward { disposition = .fastForward }
            else {
                let current = try replayMergeBase(from:upstreamHash,to:branchHash,cancellation:cancellation)
                disposition = current.fastForward ? .upToDate : .ready
            }
        }
        else { disposition = .ready }
        try cancellation?.check()
        return RebasePlan(disposition: disposition, options: options, branchHash: branchHash, upstreamHash: upstreamHash, ontoHash: ontoHash,
                          branchReference: branchReference, originalCommits: commits.map(\.hash),
                          entries: commits.map { RebaseEntry(commit: $0, action: redundant.contains($0.hash) && !options.force && !options.preserveMerges ? .skip : .pick) })
    }
    public func rebaseCommit(_ revision: String, cancellation: OperationCancellation? = nil) throws -> LogEntry {
        let hash = try rebaseRevision(revision, cancellation: cancellation)
        let result = try run(["show", "--encoding=UTF-8", "-s", "--format=%H%x00%P%x00%an%x00%ae%x00%aI%x00%s%x00%B%x00%cn%x00%ce%x00%cI%x00", hash, "--"], cancellation: cancellation)
        guard let entry = LogEntry.parseReplayHistory(result.stdout).first else { throw RebaseFailure.revision }
        return entry
    }
    public func remainingRebaseEntries(cancellation: OperationCancellation? = nil) throws -> [RebaseEntry] {
        let state = try rebaseState(cancellation: cancellation)
        guard state.active else { return [] }
        let identities = replayIdentities(try rebasePath("rebase-merge", cancellation: cancellation))
        var result: [RebaseEntry] = []
        func recovered(_ hash: String, action: RebaseAction, position: Int) throws -> RebaseEntry {
            var entry = RebaseEntry(commit: try rebaseCommit(hash, cancellation: cancellation), action: action)
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
    /// Full original replay list for native progress display, including completed occurrences.
    public func rebaseReplayEntries(cancellation: OperationCancellation? = nil) throws -> [RebaseEntry] {
        let state = try rebaseState(cancellation: cancellation)
        guard state.active else { return [] }
        let directory = try rebasePath("rebase-merge", cancellation: cancellation)
        let identities = replayIdentities(directory)
        // Older sessions retain hashes/occurrences; recover their actions from Git's commands.
        let done = (try? String(contentsOf: directory.appendingPathComponent("done"), encoding: .utf8)) ?? ""
        let commands = (done.components(separatedBy: .newlines) + state.remainingCommands).compactMap { line -> RebaseAction? in
            guard let word = line.split(separator: " ").first else { return nil }
            return RebaseAction(rawValue: String(word))
        }
        guard !identities.isEmpty else { return try remainingRebaseEntries(cancellation: cancellation) }
        let skipped = (try? JSONDecoder().decode(Set<Int>.self, from: Data(contentsOf: directory.appendingPathComponent("turtlegit-skipped-steps.json")))) ?? []
        return try identities.enumerated().map { index, identity in
            var entry = RebaseEntry(commit: try rebaseCommit(identity.hash, cancellation: cancellation))
            entry.occurrence = identity.occurrence
            entry.action = identity.action.flatMap(RebaseAction.init(rawValue:)) ?? (commands.indices.contains(index) ? commands[index] : .pick)
            if skipped.contains(index + 1) { entry.action = .skip }
            entry.mainline = identity.mainline
            if index + 1 < state.currentStep { entry.progress = .completed }
            else if index + 1 == state.currentStep { entry.progress = .current }
            return entry
        }
    }
    /// Publish one complete read result, refusing a session/HEAD transition
    /// during the reads. Mutation and recovery still use their existing engine.
    public func rebaseSessionSnapshot(retaining previous:RebaseConflictIdentity?=nil,includeReplay:Bool=true,cancellation:OperationCancellation?=nil) throws -> RebaseSessionSnapshot {
        try cancellation?.check()
        let state=try rebaseState(cancellation:cancellation),identity=RebaseConflictIdentity(state)
        let recovery=state.active && identity != nil && (state.needsFileRecovery || identity == previous)
        let head=try run(["rev-parse","--verify","--quiet","HEAD"],successfulExitCodes:0...1,cancellation:cancellation).text.trimmingCharacters(in:.newlines)
        var conflicts:[ConflictEntry]=[],rows:[StatusEntry]=[],statistics:GitPathMap<CommitFile>=[:]
        if recovery {
            conflicts=try self.conflicts(cancellation:cancellation)
            let group=state.stoppedAction == .squash
            rows=try commitDialogStatus(amendToParent:group,cancellation:cancellation).filter {$0.state != .untracked && $0.state != .ignored}
            statistics=GitPathMap(try workingTreeFiles(amendToParent:group,cancellation:cancellation).map {($0.path,$0)},uniquingKeysWith:{_,last in last})
        }
        let absoluteFlags=recovery ? try finderIndexFlags(cancellation:cancellation):[:]
        let indexFlags=GitPathMap(uniqueKeysWithValues:rows.compactMap { row in
            absoluteFlags[root.path + "/" + row.path].map {(row.path,$0)}
        })
        let remaining=state.active && includeReplay ? try remainingRebaseEntries(cancellation:cancellation):[]
        let replay=state.active && includeReplay ? try rebaseReplayEntries(cancellation:cancellation):[]
        let messageCommit = state.active && !head.isEmpty && (state.isEditPause || state.squashMessage != nil || state.split != nil) ? try rebaseCommit(head, cancellation: cancellation) : nil
        let final=try rebaseState(cancellation:cancellation),finalHead=try run(["rev-parse","--verify","--quiet","HEAD"],successfulExitCodes:0...1,cancellation:cancellation).text.trimmingCharacters(in:.newlines)
        try cancellation?.check()
        guard state.active == final.active,identity == RebaseConflictIdentity(final),state.stoppedAction == final.stoppedAction,
              state.remainingCommands == final.remainingCommands,state.conflicts.map({GitReferenceName($0)}) == final.conflicts.map({GitReferenceName($0)}),state.message == final.message,
              state.squashMessage?.message == final.squashMessage?.message,state.isEditPause == final.isEditPause,head == finalHead else {throw RebaseFailure.changed}
        return RebaseSessionSnapshot(state:state,identity:recovery ? identity:nil,fileRecovery:recovery,conflicts:conflicts,rows:rows,statistics:statistics,indexFlags:indexFlags,head:head,remaining:remaining,replay:replay,messageCommit:messageCommit)
    }
    public func rebaseTodo(_ plan: RebasePlan) throws -> String {
        try validateRebaseIdentities(plan)
        guard plan.entries.first(where: { $0.action != .skip })?.action != .squash else { throw RebaseFailure.squash }
        if plan.options.preserveMerges { return try structuralRebaseTodo(plan) }
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
    /// Source parent rewrite semantics for structural Pick, Skip and Edit plans.
    /// Labels identify already replayed parents; an unreplayed linear parent
    /// falls back to the current head. A missing first merge parent is rejected.
    public func structuralRebaseTodo(_ plan: RebasePlan) throws -> String {
        try validateRebaseIdentities(plan)
        guard plan.entries.first(where: { $0.action != .skip })?.action != .squash else { throw RebaseFailure.squash }
        guard plan.options.preserveMerges, plan.entries.allSatisfy({ $0.occurrence == 0 && !($0.action == .squash && $0.commit.parents.count != 1) }) else { throw RebaseFailure.preservePlan }
        let bases = try run(["merge-base","--all",plan.branchHash,plan.ontoHash],successfulExitCodes:0...1).text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !bases.isEmpty else { throw RebaseFailure.preservePlan }
        let selected = Set(plan.entries.map { $0.commit.hash })
        var rewritten = Dictionary(uniqueKeysWithValues:bases.map { ($0,"turtlegit-onto") })
        var current = "turtlegit-onto", rows = ["label turtlegit-onto"], group: [String] = []
        func nextIsSquash(after index: Int) -> Bool {
            plan.entries.dropFirst(index + 1).first { $0.action != .skip }?.action == .squash
        }
        for (position,entry) in plan.entries.enumerated() {
            let original = try rebaseCommit(entry.commit.hash)
            guard original.parents == entry.commit.parents else { throw RebaseFailure.changed }
            if entry.action == .skip {
                // Source skips a selected row without rewriting its parent map.
                // Its descendants use the current HEAD fallback; a merge's
                // unreplayed first parent still fails the source guard.
                if group.isEmpty { rows.append("label turtlegit-" + original.hash) }
                else { rows.append("drop " + original.hash); group.append(original.hash) }
                continue
            }
            var parents: [String] = []
            for (index,parent) in original.parents.enumerated() {
                let target: String
                if let mapped = rewritten[parent] { target = mapped }
                else if selected.contains(parent) {
                    guard original.parents.count <= 1 || index != 0 else { throw RebaseFailure.preservePlan }
                    target = current
                } else { target = parent }
                if !parents.contains(target) { parents.append(target) }
            }
            let first = parents.first ?? "turtlegit-onto"
            if entry.action != .squash { rows.append("reset " + first) }
            if original.parents.count > 1 {
                if parents == original.parents { rows.append("reset " + original.hash) }
                else if parents.count > 1 { rows.append("merge -C " + original.hash + " " + parents.dropFirst().joined(separator:" ")) }
            } else { rows.append((entry.action == .edit && nextIsSquash(after:position) ? RebaseAction.pick.rawValue : entry.action.rawValue) + " " + original.hash + " " + original.subject.replacingOccurrences(of:"\n",with:" ").replacingOccurrences(of:"\r",with:" ")) }
            if original.parents.count > 1 && entry.action == .edit && !nextIsSquash(after:position) { rows.append("break") }
            group.append(original.hash)
            if !nextIsSquash(after:position) {
                for hash in group { rows.append("label turtlegit-" + hash) }
                // Every applied member must map to the final Squash result.
                // Skipped members retain source's unreplayed-parent fallback.
                for hash in group where plan.entries.first(where: { $0.commit.hash == hash })?.action != .skip { rewritten[hash] = "turtlegit-" + original.hash }
                current = "turtlegit-" + original.hash; group.removeAll()
            }
        }
        return rows.joined(separator:"\n") + "\n"
    }
    private func startRebaseOwned(_ plan: RebasePlan, editorExecutable: URL, afterFetch: Bool = false, autoStart: Bool = false, fromLog: Bool = false) throws -> RebaseExecution {
        guard !(try rebaseState().active) else { throw RebaseFailure.active }
        guard try rebaseRevision(plan.options.branch) == plan.branchHash,
              try rebaseRevision(plan.options.upstream) == plan.upstreamHash,
              (plan.options.onto.isEmpty ? plan.upstreamHash : try rebaseRevision(plan.options.onto)) == plan.ontoHash else { throw RebaseFailure.changed }
        if plan.options.isCherryPick {
            guard try currentRebaseBranch() == plan.branchReference, !plan.options.preserveMerges,
                  plan.options.branch == "HEAD", plan.upstreamHash == plan.branchHash, plan.ontoHash == plan.branchHash else { throw RebaseFailure.changed }
        }
        _ = try rebaseTodo(plan)
        let temporary = try TurtleGitTemporaryStorage.root.appendingPathComponent(UUID().uuidString)
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
        let structural = plan.options.preserveMerges
        let todo = replay.entries.map { $0.action.rawValue + " " + $0.commit.hash + " " + $0.commit.subject.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") }.joined(separator: "\n") + "\n"
        try Data((structural ? try structuralRebaseTodo(plan) : replay.entries.isEmpty ? "noop\n" : todo).utf8).write(to: path)
        var environment = ["GIT_SEQUENCE_EDITOR": RebaseEditor.command(executable: editorExecutable), "TURTLEGIT_REBASE_PLAN": path.path, "GIT_EDITOR": "/usr/bin/true"]
        if structural { environment["TURTLEGIT_STRUCTURAL_PLAN"] = "1" }
        let identityFile = temporary.appendingPathComponent("identities.json")
        try JSONEncoder().encode(plan.entries.map { RebaseReplayIdentity(hash: $0.commit.hash, occurrence: $0.occurrence, action: $0.action.rawValue, mainline: $0.mainline) }).write(to: identityFile)
        environment["TURTLEGIT_REPLAY_IDENTITIES"] = identityFile.path
        if plan.entries.contains(where: { $0.action == .squash }) {
            let messageFile = temporary.appendingPathComponent("replay-messages.json")
            let command = RebaseEditor.messageCommand(executable: editorExecutable)
            try JSONEncoder().encode(RebaseMessageConfiguration(editorCommand: command, datePolicy: plan.options.squashDate, dates: plan.entries.map { $0.commit.date }, actions: replay.entries.map { $0.action.rawValue }, messages: replay.entries.map { $0.commit.message }, commitEncoding: commitMessageEncodingName())).write(to: messageFile)
            environment["TURTLEGIT_REPLAY_MESSAGES"] = messageFile.path
            environment["GIT_EDITOR"] = command
        }
        if plan.options.isCherryPick {
            let metadata = temporary.appendingPathComponent("cherry-pick.json")
            try JSONEncoder().encode(mapping).write(to: metadata)
            environment["TURTLEGIT_CHERRY_PICK_METADATA"] = metadata.path
        }
        var args = ["-c", "i18n.logOutputEncoding=UTF-8", "rebase", "--no-autostash"]
        if plan.options.force || plan.options.isCherryPick || plan.hasAddedCommits { args += ["--force-rebase", "--reapply-cherry-picks"] }
        // Interactive replay stops for patches that become empty, including on Git versions predating --empty=stop.
        if plan.options.isCherryPick { args.append("--keep-empty") }
        if plan.options.isCherryPick { args = ["-c", "rebase.updateRefs=false"] + args }
        if plan.options.preserveMerges { args.append("--rebase-merges"); if structural { args.append("--interactive") } }
        else { args.append("--interactive") }
        args += ["--onto", plan.ontoHash, "--", plan.upstreamHash, plan.branchReference.isEmpty ? plan.branchHash : String(plan.branchReference.dropFirst(11))]
        let result = try executeRebase(args, environment: environment)
        if result.state.active {
            let merge = try rebasePath("rebase-merge")
            let directory = FileManager.default.fileExists(atPath: merge.path) ? merge : try rebasePath("rebase-apply")
            let context = RebaseSessionContext(options: plan.options, afterFetch: afterFetch, autoStart: autoStart, fromLog: fromLog)
            try JSONEncoder().encode(context).write(to: directory.appendingPathComponent("turtlegit-session.json"), options: .atomic)
            return RebaseExecution(output: result.output, exitCode: result.exitCode, state: try rebaseState(), witnessedHead:result.witnessedHead,witnessedSession:result.witnessedSession)
        }
        return result
    }
    private func rebaseSquashIsEmptyOwned() throws -> Bool {
        let state = try rebaseState()
        guard state.active, state.squashMessage != nil, state.squashMessage?.skipBaseHead == nil, state.conflicts.isEmpty, state.split == nil else { throw RebaseFailure.plan }
        let base = try commitComparisonBase(amendToParent: true)
        return try run(["diff", "--cached", "--quiet", base, "--"], successfulExitCodes: 0...1).exitCode == 0
    }
    private func resumeEmptySquashSkip(_ pending: RebaseSquashMessage) throws -> RebaseExecution {
        guard let original = pending.skipOriginalHead, let base = pending.skipBaseHead else { throw RebaseFailure.plan }
        let head = try rebaseRevision("HEAD")
        guard head == original || head == base, try run(["diff", "--cached", "--quiet", base, "--"], successfulExitCodes: 0...1).exitCode == 0,
              try run(["diff", "--quiet", "--"], successfulExitCodes: 0...1).exitCode == 0 else { throw RebaseFailure.changed }
        if head == original { _ = try run(["reset", "--soft", base, "--"]) }
        return try recoverRebase("--skip")
    }
    private func requireRebaseContinuation(_ actual: RebaseState, expected: RebaseState, expectedHead: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let sameSquash = try encoder.encode(actual.squashMessage) == encoder.encode(expected.squashMessage)
        let sameSplit = try encoder.encode(actual.split) == encoder.encode(expected.split)
        guard actual.active, expected.active, actual.isCherryPick == expected.isCherryPick,
              actual.originalHead == expected.originalHead, actual.branch == expected.branch, actual.onto == expected.onto,
              actual.stoppedEntryID == expected.stoppedEntryID, actual.stoppedCommit == expected.stoppedCommit,
              actual.currentStep == expected.currentStep, actual.stoppedAction == expected.stoppedAction,
              actual.hasFailedPickCleanup == expected.hasFailedPickCleanup, actual.isEditPause == expected.isEditPause, actual.remainingCommands == expected.remainingCommands,
              actual.mergeParents == expected.mergeParents, actual.total == expected.total,
              actual.isStructuralMergeEdit == expected.isStructuralMergeEdit, actual.hasStructuralMergeResult == expected.hasStructuralMergeResult,
              actual.conflicts.map({GitReferenceName($0)}) == expected.conflicts.map({GitReferenceName($0)}), actual.message == expected.message, sameSquash, sameSplit,
              try rebaseRevision("HEAD") == expectedHead else { throw RebaseFailure.changed }
    }
    public func validateRebaseContinuation(expected: RebaseState, expectedHead: String, cancellation: OperationCancellation? = nil) throws {
        try withReplayIO(cancellation: cancellation, onOutput: nil) {
            try requireRebaseContinuation(rebaseState(), expected: expected, expectedHead: expectedHead)
        }
    }
    private func continueRebaseOwned(squashMessage: String? = nil, editMessage: String? = nil, emptySquashChoice: RebaseEmptyChoice? = nil, expectedSquashHead: String? = nil, expectedSquashState: RebaseState? = nil, expectedReplayState: RebaseState? = nil, expectedReplayHead: String? = nil) throws -> RebaseExecution {
        let state = try rebaseState()
        if let expectedReplayState {
            guard let expectedReplayHead else { throw RebaseFailure.changed }
            try requireRebaseContinuation(state, expected: expectedReplayState, expectedHead: expectedReplayHead)
        }
        guard state.active else { throw RebaseFailure.inactive }
        if state.hasFailedPickCleanup {
            guard let recovery=try failedPickRecovery(after:.init(output:"",exitCode:1,state:state,witnessedHead:try rebaseRevision("HEAD"),witnessedSession:try failedPickSessionIdentity(rebasePath("rebase-merge")))) else {throw RebaseFailure.changed}
            return try recoverFailedPick(recovery,action:.retry)
        }
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
            if let expectedSquashState {
                guard state.currentStep == expectedSquashState.currentStep, state.stoppedEntryID == expectedSquashState.stoppedEntryID, state.originalHead == expectedSquashState.originalHead else { throw RebaseFailure.changed }
            }
            if let expectedSquashHead, try rebaseRevision("HEAD") != expectedSquashHead { throw RebaseFailure.changed }
            if pending.skipBaseHead != nil { return try resumeEmptySquashSkip(pending) }
            let empty = try rebaseSquashIsEmpty()
            if empty {
                guard let emptySquashChoice else { throw RebaseFailure.emptyResult }
                if emptySquashChoice == .cancel { return RebaseExecution(output: "", exitCode: 0, state: state) }
                if emptySquashChoice == .skip {
                    guard try run(["diff", "--quiet", "--"], successfulExitCodes: 0...1).exitCode == 0 else { throw RebaseFailure.plan }
                    let base = try commitComparisonBase(amendToParent: true)
                    pending.skipOriginalHead = try rebaseRevision("HEAD"); pending.skipBaseHead = base
                    try JSONEncoder().encode(pending).write(to: rebasePath("rebase-merge/turtlegit-squash-message.json"), options: .atomic)
                    return try resumeEmptySquashSkip(pending)
                }
            } else if emptySquashChoice != nil { throw RebaseFailure.changed }
            guard let squashMessage, !squashMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RebaseFailure.message }
            let messageFile = try makeCommitMessageFile(squashMessage, appendFinalNewline: false); defer { messageFile.remove() }
            pending.message = squashMessage
            let request = try rebasePath("rebase-merge/turtlegit-squash-message.json")
            try JSONEncoder().encode(pending).write(to: request, options: .atomic)
            let date: String
            switch pending.datePolicy {
            case .first: date = try rebaseCommit("HEAD").date
            case .latest: date = pending.latestDate
            case .current: date = ISO8601DateFormatter().string(from: Date())
            }
            output = try run(["commit", "--amend", "--cleanup=verbatim", "-F", messageFile.url.path, "--date", date] + (empty ? ["--allow-empty"] : [])).text
            try FileManager.default.removeItem(at: request)
        }
        let result = try recoverRebase("--continue")
        return RebaseExecution(output: output + result.output, exitCode: result.exitCode, state: result.state,witnessedHead:result.witnessedHead,witnessedSession:result.witnessedSession)
    }
    private func skipRebaseOwned(bookkeepingStep: Int? = nil) throws -> RebaseExecution {
        let before = try rebaseState()
        guard before.active else { throw RebaseFailure.inactive }
        let hasMessageConfiguration=FileManager.default.fileExists(atPath:try rebasePath("rebase-merge/turtlegit-message-editor.json").path)
        guard bookkeepingStep != nil || hasMessageConfiguration else { return try recoverRebase("--skip") }
        let path = try rebasePath("rebase-merge/turtlegit-skipped-steps.json")
        var skipped = FileManager.default.fileExists(atPath: path.path) ? try JSONDecoder().decode(Set<Int>.self, from: Data(contentsOf: path)) : []
        let old = skipped, beforeHead = try rebaseRevision("HEAD")
        skipped.insert(bookkeepingStep ?? before.currentStep)
        try JSONEncoder().encode(skipped).write(to: path, options: .atomic)
        let result: RebaseExecution
        do { result = try recoverRebase("--skip") }
        catch {
            // If the command never advanced this step, do not leave a provisional
            // Skip in the Squash editor's durable bookkeeping after cancellation.
            try? replayUncancelled {
                let actual = try rebaseState(), actualHead = try rebaseRevision("HEAD")
                if actual.active && actual.currentStep == before.currentStep && actual.stoppedEntryID == before.stoppedEntryID && actualHead == beforeHead { try JSONEncoder().encode(old).write(to: path, options: .atomic) }
            }
            throw error
        }
        if result.state.active && result.state.currentStep == before.currentStep && result.state.squashMessage == nil {
            try JSONEncoder().encode(old).write(to: path, options: .atomic)
        }
        return result
    }
    private func abortRebaseOwned() throws -> RebaseExecution { try recoverRebase("--abort") }
    private func recoverRebase(_ action: String) throws -> RebaseExecution {
        guard try rebaseState().active else { throw RebaseFailure.inactive }
        let configuration = try rebasePath("rebase-merge/turtlegit-message-editor.json")
        let config = FileManager.default.fileExists(atPath: configuration.path) ? try JSONDecoder().decode(RebaseMessageConfiguration.self, from: Data(contentsOf: configuration)) : nil
        return try executeRebase(["-c", "i18n.logOutputEncoding=UTF-8", "rebase", action], environment: ["GIT_EDITOR": config?.editorCommand ?? "/usr/bin/true"])
    }
    private func executeRebase(_ arguments: [String], environment: [String: String]) throws -> RebaseExecution {
        func execution(_ output:String,_ exitCode:Int32) throws -> RebaseExecution {
            let head=try? rebaseRevision("HEAD"),state=try rebaseState()
            let session=state.active ? (try? failedPickSessionIdentity(rebasePath("rebase-merge"))) : nil
            return RebaseExecution(output:output,exitCode:exitCode,state:state,witnessedHead:head,witnessedSession:session)
        }
        do {return try execution(run(arguments,environmentOverrides:environment).text,0)}
        catch let failure as GitFailure {return try execution(failure.message,failure.code)}
    }
    private func amendRebaseCommitOwned(message: String) throws -> String {
        guard try rebaseState().active else { throw RebaseFailure.inactive }
        let state = try rebaseState()
        guard state.isEditPause, state.squashMessage == nil && (state.split == nil || state.split?.conflictRecovery == true) else { throw RebaseFailure.plan }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RebaseFailure.message }
        let base = try commitComparisonBase(amendToParent: true)
        let originallyEmpty = try run(["diff", "--quiet", base, "HEAD", "--"], successfulExitCodes: 0...1).exitCode == 0
        let messageFile = try makeCommitMessageFile(message); defer { messageFile.remove() }
        return try run(["commit", "--amend", "-F", messageFile.url.path] + (originallyEmpty ? ["--allow-empty"] : [])).text
    }
    private func beginRebaseSplitOwned() throws -> RebaseSplitState {
        let state = try rebaseState()
        guard state.canSplit else { throw RebaseFailure.plan }
        if let split = state.split, split.conflictRecovery != true { return split }
        let head = try rebaseCommit("HEAD")
        if let recovery = state.split, recovery.conflictRecovery == true, recovery.expectedHead != head.hash { throw RebaseFailure.changed }
        var split = RebaseSplitState(entryID: state.stoppedEntryID, step: state.currentStep, expectedHead: head.hash, parts: 0,
                                     firstAuthor: head.author + " <" + head.email + ">", firstDate: state.squashMessage?.datePolicy == .latest ? state.squashMessage!.latestDate : head.date,
                                     squashDate: state.squashMessage?.datePolicy)
        split.firstParents = head.parents
        if let recovery = state.split, recovery.conflictRecovery == true {
            split.conflictRecoveryReturn = RebaseSplitReturn(parts: recovery.parts, firstAuthor: recovery.firstAuthor, firstDate: recovery.firstDate, squashDate: recovery.squashDate, firstParents: recovery.firstParents)
        }
        try JSONEncoder().encode(split).write(to: rebasePath("rebase-merge/turtlegit-split.json"), options: .atomic)
        return split
    }
    /// Edit's dirty-worktree handoff amends the applied commit, without turning
    /// the first accepted selection into a new split part or resetting HEAD.
    public func beginRebaseEditSelection(expected: RebaseState, expectedHead: String, cancellation: OperationCancellation? = nil) throws -> RebaseSplitState? {
        try withReplayIO(cancellation: cancellation, onOutput: nil) {
            let state = try rebaseState(); try requireRebaseContinuation(state, expected: expected, expectedHead: expectedHead)
            guard state.isEditPause, state.squashMessage == nil, state.split == nil else { throw RebaseFailure.plan }
            // Source1568 checks workdir-only readiness before opening Commit
            // for an ordinary Edit continuation; staged edits are incorporated
            // by the following amend. CheckNextCommitIsSquash returns zero for
            // Squash, so that accumulated/structural path retains its full check.
            let next = state.remainingCommands.compactMap { command in
                command.split(separator:" ").first.flatMap {RebaseAction(rawValue:String($0))}
            }.first { $0 != .skip }
            let structural = FileManager.default.fileExists(atPath:try rebasePath("rebase-merge/turtlegit-structural-plan").path)
            let needsSelection:Bool
            if !structural && next != .squash {needsSelection = try !replayWorktreeIsClean(stagedOK:true)}
            else {needsSelection = try rebaseSplitHasRemainingChangesOwned()}
            guard needsSelection else {return nil}
            let head = try rebaseCommit("HEAD")
            guard head.hash == expectedHead else { throw RebaseFailure.changed }
            try requireRebaseContinuation(rebaseState(), expected: expected, expectedHead: expectedHead)
            var selection = RebaseSplitState(entryID: state.stoppedEntryID, step: state.currentStep, expectedHead: head.hash, parts: 0,
                                             firstAuthor: head.author + " <" + head.email + ">", firstDate: head.date, squashDate: nil)
            selection.conflictRecovery = true; selection.firstParents = head.parents
            try replayCancellation?.check()
            try JSONEncoder().encode(selection).write(to: rebasePath("rebase-merge/turtlegit-split.json"), options: .atomic)
            return selection
        }
    }
    /// Commit checked conflict-resolution files against destination HEAD. The
    /// durable continuation record keeps excluded index/worktree changes available
    /// for the native amend loop; Git's original replay metadata remains in place.
    private func checkedRebaseRecovery(paths: GitPathSet, expected: RebaseState, expectedHead: String) throws -> (RebaseState, [StatusEntry]) {
        let state = try rebaseState()
        guard state.active, state.needsFileRecovery, state.split == nil, state.conflicts.isEmpty, state.stoppedAction == .pick || state.stoppedAction == .edit,
              state.currentStep == expected.currentStep, state.stoppedEntryID == expected.stoppedEntryID,
              state.originalHead == expected.originalHead, state.mergeParents == expected.mergeParents, try rebaseRevision("HEAD") == expectedHead else { throw RebaseFailure.changed }
        let changes = try status()
        let checked = changes.filter { paths.contains($0.path) }
        guard checked.count == paths.count, checked.allSatisfy({ $0.state != .ignored && $0.state != .untracked }), !changes.contains(where: { $0.state == .conflicted }) else { throw RebaseFailure.plan }
        return (state, checked)
    }
    private func rebaseConflictSelectionIsEmptyOwned(paths: GitPathSet, expected: RebaseState, expectedHead: String) throws -> Bool {
        let (_, checked) = try checkedRebaseRecovery(paths: paths, expected: expected, expectedHead: expectedHead)
        return try commitSelectionIsEmpty(checked: checked, base: "HEAD", fileModes: selectedStagedFileModes(checked))
    }
    private func commitRebaseConflictSelectionOwned(message: String, paths: GitPathSet, expected: RebaseState, expectedHead: String, allowEmpty: Bool = false) throws -> RebaseExecution {
        let (state, checked) = try checkedRebaseRecovery(paths: paths, expected: expected, expectedHead: expectedHead)
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RebaseFailure.message }
        let modes = try selectedStagedFileModes(checked)
        if !allowEmpty, try commitSelectionIsEmpty(checked: checked, base: "HEAD", fileModes: modes) { throw RebaseFailure.emptyResult }
        let source = try rebaseCommit(state.stoppedCommit)
        var options = CommitOptions(); options.messageOnly = allowEmpty; options.author = source.author + " <" + source.email + ">"
        let output = try commitSeparateSelection(message: message, checked: checked, options: options, base: "HEAD", fileModes: modes, preservedAuthorDate: source.date)
        var continuation = RebaseSplitState(entryID: state.stoppedEntryID, step: state.currentStep, expectedHead: try rebaseRevision("HEAD"), parts: 1, firstAuthor: options.author!, firstDate: source.date, squashDate: nil)
        continuation.conflictRecovery = true
        continuation.firstParents = try rebaseCommit("HEAD").parents
        try JSONEncoder().encode(continuation).write(to: rebasePath("rebase-merge/turtlegit-split.json"), options: .atomic)
        return RebaseExecution(output: output, exitCode: 0, state: try rebaseState())
    }
    private func rebaseSplitHasRemainingChangesOwned() throws -> Bool {
        try !replayWorktreeIsClean()
    }
    private func cancelUnstartedRebaseSplitOwned() throws {
        guard let split = try rebaseState().split, split.parts == 0, try rebaseRevision("HEAD") == split.expectedHead else { throw RebaseFailure.changed }
        let path = try rebasePath("rebase-merge/turtlegit-split.json")
        if let origin = split.conflictRecoveryReturn {
            guard origin.parts > 0 else { throw RebaseFailure.changed }
            var restored = RebaseSplitState(entryID: split.entryID, step: split.step, expectedHead: split.expectedHead, parts: origin.parts, firstAuthor: origin.firstAuthor, firstDate: origin.firstDate, squashDate: origin.squashDate)
            restored.conflictRecovery = true
            restored.firstParents = origin.firstParents
            try JSONEncoder().encode(restored).write(to: path, options: .atomic)
        } else { try FileManager.default.removeItem(at: path) }
    }
    /// Commit each split part through the same complete selection/index backend.
    /// The first part replaces the stopped commit; later parts create children.
    private func commitRebaseSplitOwned(message: String, paths: GitPathSet, staging: Bool, options: CommitOptions, expected: RebaseSplitState) throws -> String {
        let state = try rebaseState()
        guard let saved = state.split, state.canSplit || saved.conflictRecovery == true, saved.parts == expected.parts, saved.entryID == expected.entryID,
              saved.expectedHead == expected.expectedHead, saved.firstParents == expected.firstParents, try rebaseRevision("HEAD") == saved.expectedHead,
              options.newBranch == nil, options.amend == (saved.conflictRecovery == true || saved.parts == 0), saved.conflictRecovery == true ? options.amendDiffToLastCommit : saved.parts != 0 || !options.amendDiffToLastCommit else { throw RebaseFailure.changed }
        if saved.parts == 0, let parents = saved.firstParents {
            guard try rebaseCommit("HEAD").parents == parents else { throw RebaseFailure.changed }
        }
        let output = try (staging ? commitIndex(message: message, options: options) : commitSelected(message: message, paths: paths, options: options))
        var updated = saved; updated.conflictRecoveryReturn = nil; updated.parts += 1; updated.expectedHead = try rebaseRevision("HEAD")
        try JSONEncoder().encode(updated).write(to: rebasePath("rebase-merge/turtlegit-split.json"), options: .atomic)
        if saved.parts == 0, state.squashMessage != nil { try FileManager.default.removeItem(at: rebasePath("rebase-merge/turtlegit-squash-message.json")) }
        return output
    }
}

private extension LogEntry {
    static func parseReplayHistory(_ data: Data) -> [LogEntry] {
        let fields = String(decoding: data, as: UTF8.self).components(separatedBy: "\0")
        var entries: [LogEntry] = []
        for start in stride(from: 0, to: max(0, fields.count - 9), by: 10) {
            let hash = fields[start].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !hash.isEmpty else { continue }
            var entry = LogEntry(hash: hash, author: fields[start+2], date: fields[start+4], subject: fields[start+5],
                                 parents: fields[start+1].split(separator: " ").map(String.init), email: fields[start+3], message: fields[start+6])
            entry.committer = fields[start+7]; entry.committerEmail = fields[start+8]; entry.committerDate = fields[start+9]
            entries.append(entry)
        }
        return entries
    }
}

public struct ReplayColumnMetadata: Sendable {
    public let showsIssueIDs: Bool
    public let hasGitSVN: Bool
    public let issueIDs: [String:String]
    public let svnRevisions: [String:String]
}
extension GitRepository {
    public func replayColumnMetadata(_ entries: [LogEntry], executable: URL? = nil, cancellation: OperationCancellation? = nil) throws -> ReplayColumnMetadata {
        try cancellation?.check()
        let properties = try issueTrackerProperties(cancellation:cancellation)
        let svn = try !isBare(cancellation:cancellation) && referenceLogHasGitSVN(cancellation:cancellation)
        var seen = Set<String>(); let commits = entries.filter { seen.insert($0.hash).inserted }
        var issues: [String:String] = [:]
        if properties.showsBugIDColumn {
            if properties.checkExpression.isEmpty {
                for entry in commits { issues[entry.hash] = try properties.logIssueIDs(in:entry.message,executable:executable,cancellation:cancellation) }
            } else {
                let ids = try IssueRegexRuntime.batchIssueIDs(commits.map(\.message),check:properties.checkExpression,extract:properties.extractionExpression,executable:executable,cancellation:cancellation)
                for (entry, values) in zip(commits,ids) { issues[entry.hash] = IssueTrackerProperties.naturalIssueIDs(values) }
            }
        }
        let revisions = svn ? try IssueRegexRuntime.svnRevisions(commits.map { $0.historySubject + "\n" + $0.historyBody },executable:executable,cancellation:cancellation) : []
        try cancellation?.check()
        return ReplayColumnMetadata(showsIssueIDs:properties.showsBugIDColumn,hasGitSVN:svn,issueIDs:issues,svnRevisions:Dictionary(uniqueKeysWithValues:zip(commits.map(\.hash),revisions)))
    }
}


extension GitRepository {
    /// RebaseDlg clears Onto when it aliases Branch or Upstream, even via another ref/tag.
    public func rebaseOntoSelection(_ candidate: String, branch: String, upstream: String, cancellation: OperationCancellation? = nil) throws -> String? {
        try cancellation?.check()
        guard !candidate.isEmpty else { return nil }
        let onto = try rebaseRevision(candidate, cancellation: cancellation)
        let branchHash = try rebaseRevision(branch, cancellation: cancellation)
        let upstreamHash = try rebaseRevision(upstream, cancellation: cancellation)
        try cancellation?.check()
        return onto == branchHash || onto == upstreamHash ? nil : candidate
    }
}

// Replay entry points retain one synchronous actor scope across nested Git helpers.
// Cancellation resets on every return/throw; later recovery reads use fresh input.
extension GitRepository {
    func replayCommandOutput(_ arguments: [String]) -> (@Sendable (GitOutputChunk) -> Void)? {
        guard let command=GitCommandIdentity(arguments).command,["rebase","commit","reset","cherry-pick"].contains(command) else{return nil}
        return replayOutput
    }
    private func replayUncancelled<T>(_ operation: () throws -> T) throws -> T {
        let previous = replayCancellation; replayCancellation = nil
        defer { replayCancellation = previous }; return try operation()
    }
    private func withProtectedReplayIO<T>(cancellation: OperationCancellation?, onOutput: (@Sendable (GitOutputChunk) -> Void)?, operation: () throws -> T) throws -> T {
        let token = cancellation ?? replayCancellation; try token?.check()
        let result = try replayUncancelled { try withReplayIO(cancellation: nil, onOutput: onOutput, operation: operation) }
        try token?.check(); return result
    }
    private func withReplayIO<T>(cancellation: OperationCancellation?, onOutput: (@Sendable (GitOutputChunk) -> Void)?, operation: () throws -> T) throws -> T {
        let previousToken = replayCancellation, previousOutput = replayOutput
        replayCancellation = cancellation ?? previousToken; replayOutput = onOutput ?? previousOutput
        defer { replayCancellation = previousToken; replayOutput = previousOutput }
        try replayCancellation?.check(); return try operation()
    }
    public func startRebase(_ plan: RebasePlan, editorExecutable: URL, afterFetch: Bool = false, autoStart: Bool = false, fromLog: Bool = false, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> RebaseExecution {
        try withReplayIO(cancellation: cancellation, onOutput: onOutput) { try startRebaseOwned(plan, editorExecutable: editorExecutable, afterFetch: afterFetch, autoStart: autoStart, fromLog: fromLog) }
    }
    public func continueRebase(squashMessage: String? = nil, editMessage: String? = nil, emptySquashChoice: RebaseEmptyChoice? = nil, expectedSquashHead: String? = nil, expectedSquashState: RebaseState? = nil, expectedReplayState: RebaseState? = nil, expectedReplayHead: String? = nil, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> RebaseExecution {
        try withReplayIO(cancellation: cancellation, onOutput: onOutput) { try continueRebaseOwned(squashMessage: squashMessage, editMessage: editMessage, emptySquashChoice: emptySquashChoice, expectedSquashHead: expectedSquashHead, expectedSquashState: expectedSquashState, expectedReplayState: expectedReplayState, expectedReplayHead: expectedReplayHead) }
    }
    public func skipRebase(cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> RebaseExecution {
        try withReplayIO(cancellation: cancellation, onOutput: onOutput) { try skipRebaseOwned() }
    }
    public func abortRebase(cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> RebaseExecution {
        try withReplayIO(cancellation: cancellation, onOutput: onOutput) { try abortRebaseOwned() }
    }
    public func amendRebaseCommit(message: String, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> String {
        try withReplayIO(cancellation: cancellation, onOutput: onOutput) { try amendRebaseCommitOwned(message: message) }
    }
    public func beginRebaseSplit(cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> RebaseSplitState {
        try withReplayIO(cancellation: cancellation, onOutput: onOutput) { try beginRebaseSplitOwned() }
    }
    public func rebaseSquashIsEmpty(cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> Bool {
        try withReplayIO(cancellation: cancellation, onOutput: onOutput) { try rebaseSquashIsEmptyOwned() }
    }
    public func rebaseConflictSelectionIsEmpty(paths selection: some Sequence<String>, expected: RebaseState, expectedHead: String, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> Bool {
        let paths = GitPathSet(selection)
        return try withReplayIO(cancellation: cancellation, onOutput: onOutput) { try rebaseConflictSelectionIsEmptyOwned(paths: paths, expected: expected, expectedHead: expectedHead) }
    }
    public func commitRebaseConflictSelection(message: String, paths selection: some Sequence<String>, expected: RebaseState, expectedHead: String, allowEmpty: Bool = false, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> RebaseExecution {
        let paths = GitPathSet(selection)
        return try withProtectedReplayIO(cancellation: cancellation, onOutput: onOutput) { try commitRebaseConflictSelectionOwned(message: message, paths: paths, expected: expected, expectedHead: expectedHead, allowEmpty: allowEmpty) }
    }
    public func rebaseSplitHasRemainingChanges(cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> Bool {
        try withReplayIO(cancellation: cancellation, onOutput: onOutput) { try rebaseSplitHasRemainingChangesOwned() }
    }
    public func cancelUnstartedRebaseSplit(cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> Void {
        try withReplayIO(cancellation: cancellation, onOutput: onOutput) { try cancelUnstartedRebaseSplitOwned() }
    }
    public func commitRebaseSplit(message: String, paths selection: some Sequence<String>, staging: Bool, options: CommitOptions, expected: RebaseSplitState, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil) throws -> String {
        let paths = GitPathSet(selection)
        return try withProtectedReplayIO(cancellation: cancellation, onOutput: onOutput) { try commitRebaseSplitOwned(message: message, paths: paths, staging: staging, options: options, expected: expected) }
    }
}

/// A captured stopped session, including the exact files whose future commands
/// will be replaced. Public callers cannot construct or retarget this receipt.
public struct RebaseActionEditSnapshot: Sendable {
    public let state: RebaseState
    public let head: String
    public let replay: [RebaseEntry]
    fileprivate let directory: URL
    fileprivate let files: [String: RebaseActionEditFile]
}
fileprivate struct RebaseActionEditFile: Codable, Equatable, Sendable { let bytes: Data? }
private struct RebaseActionEditJournal: Codable {
    let version: Int
    let before: [String: RebaseActionEditFile]
    let after: [String: RebaseActionEditFile]
}

extension GitRepository {
    private static let actionEditNames = ["git-rebase-todo", "done", "turtlegit-replay-identities.json", "turtlegit-message-editor.json", "turtlegit-cherry-pick.json"]
    private static let actionEditJournal = "turtlegit-action-edit.json"
    private func actionEditFile(_ directory: URL, _ name: String) throws -> RebaseActionEditFile {
        let url = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { return RebaseActionEditFile(bytes: nil) }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw RebaseFailure.plan }
        return RebaseActionEditFile(bytes: try Data(contentsOf: url))
    }
    private func actionEditFiles(_ directory: URL) throws -> [String: RebaseActionEditFile] {
        try Dictionary(uniqueKeysWithValues: Self.actionEditNames.map { ($0, try actionEditFile(directory, $0)) })
    }
    private func actionEditWrite(_ file: RebaseActionEditFile, directory: URL, name: String) throws {
        let url = directory.appendingPathComponent(name)
        if let bytes = file.bytes { try bytes.write(to: url, options: .atomic) }
        else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private func withActionEditLock<T>(_ directory: URL, _ action: () throws -> T) throws -> T {
        let lock = directory.appendingPathComponent("git-rebase-todo.lock")
        let descriptor = Darwin.open(lock.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw RebaseFailure.actionEditLocked }
        defer { Darwin.close(descriptor); try? FileManager.default.removeItem(at: lock) }
        return try action()
    }
    /// Metadata is staged first, Git's todo is the commit point. On the next
    /// read an interrupted transaction finishes the committed side or restores
    /// the original side. Unknown external bytes are never overwritten.
    private func recoverRebaseActionEdit(cancellation: OperationCancellation? = nil) throws {
        let directory = try rebasePath("rebase-merge", cancellation: cancellation)
        let url = directory.appendingPathComponent(Self.actionEditJournal)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try cancellation?.check()
        try withActionEditLock(directory) {
            guard let bytes = try actionEditFile(directory, Self.actionEditJournal).bytes else { return }
            let journal = try JSONDecoder().decode(RebaseActionEditJournal.self, from: bytes)
            let names=Set(journal.before.keys),ordinary=Set(Self.actionEditNames)
            guard (1...2).contains(journal.version),names == Set(journal.after.keys),
                  names==ordinary || journal.version==2 && (names==ordinary.union(["message","stopped-sha"]) || names==ordinary.union([Self.failedPickIntentName])),
                  (journal.version==2 || journal.before["done"] == journal.after["done"]) else { throw RebaseFailure.plan }
            let actual=try Dictionary(uniqueKeysWithValues:names.map {($0,try actionEditFile(directory,$0))})
            let useNew = actual["git-rebase-todo"] == journal.after["git-rebase-todo"]
            guard useNew || actual["git-rebase-todo"] == journal.before["git-rebase-todo"],
                  (actual["done"] == journal.before["done"] || journal.version==2 && actual["done"] == journal.after["done"]),
                  names.allSatisfy({ actual[$0] == journal.before[$0] || actual[$0] == journal.after[$0] }) else { throw RebaseFailure.changed }
            let chosen = useNew ? journal.after : journal.before
            for name in names where name != "git-rebase-todo" && (name != "done" || journal.version==2) {
                try actionEditWrite(chosen[name]!, directory: directory, name: name)
            }
            try FileManager.default.removeItem(at: url)
        }
    }
    public func rebaseActionEditSnapshot(cancellation: OperationCancellation? = nil) throws -> RebaseActionEditSnapshot {
        try withReplayIO(cancellation: cancellation, onOutput: nil) {
            let state = try rebaseState(), directory = try rebasePath("rebase-merge")
            guard state.active else { throw RebaseFailure.inactive }
            let head = try rebaseRevision("HEAD"), files = try actionEditFiles(directory)
            let replay = try rebaseReplayEntries()
            guard files["git-rebase-todo"]?.bytes != nil, files["turtlegit-replay-identities.json"]?.bytes != nil,
                  !replay.isEmpty, Set(replay.map(\.id)).count == replay.count else { throw RebaseFailure.plan }
            try requireRebaseContinuation(rebaseState(), expected: state, expectedHead: head)
            guard files == (try actionEditFiles(directory)) else { throw RebaseFailure.changed }
            return RebaseActionEditSnapshot(state: state, head: head, replay: replay, directory: directory, files: files)
        }
    }
    /// Change selected future occurrences without altering the stopped commit,
    /// HEAD, index, worktree, messages being edited, or completed commands.
    public func changePendingRebaseActions(_ action: RebaseAction, ids: Set<String>, expected: RebaseActionEditSnapshot, changes: [String: RebaseAction] = [:], mainlines: [String: Int] = [:],
                                          editorExecutable: URL, retaining previous: RebaseConflictIdentity? = nil, cancellation: OperationCancellation? = nil) throws -> RebaseSessionSnapshot {
        try withReplayIO(cancellation: cancellation, onOutput: nil) {
            let directory = try rebasePath("rebase-merge")
            guard directory == expected.directory, Set(changes.keys).isSubset(of: ids), Set(mainlines.keys).isSubset(of: ids), !ids.isEmpty, ids.isSubset(of: Set(expected.replay.map(\.id))) else { throw RebaseFailure.plan }
            try withActionEditLock(directory) {
                try requireRebaseContinuation(rebaseState(), expected: expected.state, expectedHead: expected.head)
                guard expected.files == (try actionEditFiles(directory)) else { throw RebaseFailure.changed }
                var identities = try JSONDecoder().decode([RebaseReplayIdentity].self, from: expected.files["turtlegit-replay-identities.json"]!.bytes!)
                guard identities.map(\.id) == expected.replay.map(\.id) else { throw RebaseFailure.plan }
                var rows = expected.replay
                for index in rows.indices {
                    guard let stored = identities[index].action.flatMap(RebaseAction.init(rawValue:)) else { throw RebaseFailure.plan }
                    rows[index].action = stored
                }
                let oldRows = rows
                for index in rows.indices where ids.contains(rows[index].id) && rows[index].progress == .pending {
                    let requested = changes[rows[index].id] ?? action
                    if requested == .squash && (index == 0 || !expected.state.isCherryPick && rows[index].commit.parents.count > 1) { continue }
                    rows[index].action = requested; identities[index].action = requested.rawValue
                }
                if rows.map(\.action) == oldRows.map(\.action) { return }
                guard rows.first(where: { $0.action != .skip })?.action != .squash else { throw RebaseFailure.squash }
                let todo = String(decoding: expected.files["git-rebase-todo"]!.bytes!, as: UTF8.self)
                let done = String(decoding: expected.files["done"]?.bytes ?? Data(), as: UTF8.self)
                let structural = FileManager.default.fileExists(atPath: directory.appendingPathComponent("turtlegit-structural-plan").path)
                var options = RebaseOptions(); options.preserveMerges = structural; options.isCherryPick = expected.state.isCherryPick
                var mapping = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: directory.appendingPathComponent("turtlegit-cherry-pick.json")))) ?? [:]
                func originalHash(_ hash: String) -> String {
                    if let original = mapping[hash] { return original }
                    let matches = mapping.keys.filter { $0.hasPrefix(hash) }
                    return matches.count == 1 ? mapping[matches[0]]! : hash
                }
                let all = (done + "\n" + todo).split(separator: "\n").map { RebaseEditor.canonicalLine(String($0)) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
                let commands = all.map { $0.split(separator: " ", maxSplits: 2).map(String.init) }.filter { $0.count >= 2 && RebaseAction(rawValue: $0[0]) != nil }
                var newCommands = commands
                if expected.state.isCherryPick {
                    for index in rows.indices where ids.contains(rows[index].id) && rows[index].progress == .pending && rows[index].commit.parents.count > 1 && rows[index].action != .skip {
                        let commit = rows[index].commit
                        guard let mainline = mainlines[rows[index].id] ?? rows[index].mainline, commit.parents.indices.contains(mainline - 1) else { throw RebaseFailure.mainline }
                        if oldRows[index].action == .skip || mainlines[rows[index].id] != nil {
                            let object = try run(["cat-file", "commit", commit.hash]).stdout
                            guard let separator = object.range(of: Data([10, 10])) else { throw RebaseFailure.plan }
                            var message = object.subdata(in: separator.upperBound..<object.count)
                            if expected.state.session?.addCherryPickedFrom == true {
                                while message.last == 10 { message.removeLast() }
                                message.append(Data(("\n\n(cherry picked from commit " + commit.hash + ")\n").utf8))
                            }
                            let temporary = try TurtleGitTemporaryStorage.root.appendingPathComponent(UUID().uuidString)
                            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
                            defer { try? FileManager.default.removeItem(at: temporary) }
                            let file = temporary.appendingPathComponent("message"); try message.write(to: file)
                            let tree = try run(["rev-parse", commit.hash + "^{tree}"]).text.trimmingCharacters(in: .newlines)
                            let hash = try run(["commit-tree", tree, "-p", commit.parents[mainline - 1], "-F", file.path], environmentOverrides:
                                ["GIT_AUTHOR_NAME": commit.author, "GIT_AUTHOR_EMAIL": commit.email, "GIT_AUTHOR_DATE": commit.date]).text.trimmingCharacters(in: .newlines)
                            mapping[hash] = commit.hash; newCommands[index][1] = hash
                        }
                        rows[index].mainline = mainline; identities[index].mainline = mainline
                    }
                }
                func generated(_ values: [RebaseEntry], execution: [[String]]) throws -> String {
                    if structural {
                        let plan = RebasePlan(disposition: .ready, options: options, branchHash: expected.state.originalHead, upstreamHash: expected.state.onto, ontoHash: expected.state.onto,
                                              branchReference: expected.state.branch, originalCommits: values.map(\.id), entries: values)
                        return try RebaseEditor.mergeStructuralReferenceUpdates(generated: done + "\n" + todo, custom: structuralRebaseTodo(plan)).todo
                    }
                    // Non-native structural/custom todo commands are preserved by
                    // refusing a receipt that cannot be reproduced exactly.
                    guard execution.count == values.count else { throw RebaseFailure.plan }
                    let custom = try values.indices.map { index -> String in
                        let fields = execution[index], hash = fields[1]
                        let original = originalHash(hash)
                        guard values[index].commit.hash.hasPrefix(original) else { throw RebaseFailure.changed }
                        return ([values[index].action.rawValue, hash] + fields.dropFirst(2)).joined(separator: " ")
                    }.joined(separator: "\n") + "\n"
                    var positions: [String: Int] = [:]
                    for index in execution.indices where positions[execution[index][1]] == nil { positions[execution[index][1]] = index }
                    return try RebaseEditor.mergeReferenceUpdates(generated: done + "\n" + todo, custom: custom, originalPositions: positions).todo
                }
                func lines(_ text: String) -> [String] {
                    text.split(separator: "\n").map { RebaseEditor.canonicalLine(String($0)) }.filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { line in
                        var fields = line.split(separator: " ", maxSplits: 2).map(String.init)
                        if fields.count >= 2, RebaseAction(rawValue: fields[0]) != nil {
                            let hash = fields[1], matches = oldRows.filter { $0.commit.hash.hasPrefix(originalHash(hash)) }
                            if let entry = matches.first { fields[1] = entry.commit.hash }
                        } else if fields.first == "merge", fields.count >= 3 {
                            // Keep original -C object spelling stable across Git's
                            // shortened done/todo serialization.
                            fields = line.split(separator: " ").map(String.init)
                            if let entry = oldRows.first(where: { $0.commit.hash.hasPrefix(fields[2]) }) { fields[2] = entry.commit.hash }
                        }
                        return fields.joined(separator: " ")
                    }
                }
                let before = try generated(oldRows, execution: commands)
                guard lines(before) == lines(done + "\n" + todo) else { throw RebaseFailure.changed }
                let updated = try generated(rows, execution: newCommands), completed = lines(done), newLines = lines(updated)
                var prefix = 0
                for (index, actual) in completed.enumerated() {
                    if index == completed.count - 1, actual == "break", expected.state.isStructuralMergeEdit, newLines.indices.contains(prefix), newLines[prefix] != "break" { continue }
                    guard newLines.indices.contains(prefix) else { throw RebaseFailure.changed }
                    let proposed = newLines[prefix]
                    let sameCurrentEdit = actual.hasPrefix("edit " + expected.state.stoppedCommit + " ") && proposed == "pick " + actual.dropFirst(5)
                    guard actual == proposed || sameCurrentEdit else { throw RebaseFailure.changed }
                    prefix += 1
                }
                // Keep Git's actual object IDs (including synthetic Cherry Pick
                // mainline objects), not normalized display identities.
                let rawLines = updated.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                let newTodo = Data((rawLines.dropFirst(prefix).joined(separator: "\n") + "\n").utf8)
                var after = expected.files
                after["git-rebase-todo"] = RebaseActionEditFile(bytes: newTodo)
                after["turtlegit-replay-identities.json"] = RebaseActionEditFile(bytes: try JSONEncoder().encode(identities))
                let oldConfig = try expected.files["turtlegit-message-editor.json"]?.bytes.map { try JSONDecoder().decode(RebaseMessageConfiguration.self, from: $0) }
                if expected.state.isCherryPick { after["turtlegit-cherry-pick.json"] = RebaseActionEditFile(bytes: try JSONEncoder().encode(mapping)) }
                var messages = try oldConfig?.messages ?? (structural ? rows.map { $0.commit.message } : newCommands.map { try rebaseCommit($0[1]).message })
                if !structural {
                    guard messages.count == newCommands.count else { throw RebaseFailure.plan }
                    for index in newCommands.indices where newCommands[index][1] != commands[index][1] { messages[index] = try rebaseCommit(newCommands[index][1]).message }
                }
                let config = try RebaseMessageConfiguration(editorCommand: oldConfig?.editorCommand ?? RebaseEditor.messageCommand(executable: editorExecutable), datePolicy: oldConfig?.datePolicy ?? .first,
                    dates: oldConfig?.dates ?? rows.map { $0.commit.date }, actions: rows.map { $0.action.rawValue }, messages: messages, commitEncoding: oldConfig?.commitEncoding ?? commitMessageEncodingName())
                after["turtlegit-message-editor.json"] = RebaseActionEditFile(bytes: try JSONEncoder().encode(config))
                try replayCancellation?.check()
                guard expected.files == (try actionEditFiles(directory)) else { throw RebaseFailure.changed }
                let journal = RebaseActionEditJournal(version: 1, before: expected.files, after: after)
                let journalURL = directory.appendingPathComponent(Self.actionEditJournal)
                try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
                // No cancellation point inside publication. The final todo write
                // chooses one complete side of this recoverable transaction.
                do {
                    for name in Self.actionEditNames where name != "git-rebase-todo" && name != "done" { try actionEditWrite(after[name]!, directory: directory, name: name) }
                    try actionEditWrite(after["git-rebase-todo"]!, directory: directory, name: "git-rebase-todo")
                    try FileManager.default.removeItem(at: journalURL)
                } catch {
                    // Recovery happens after this owned lock is released, at the
                    // next state/read/Continue. Never guess over external bytes.
                    throw error
                }
            }
            return try replayUncancelled { try rebaseSessionSnapshot(retaining: previous) }
        }
    }
}

public enum RebaseFailedPickAction: String, Codable, Sendable { case retry, skip }
fileprivate enum RebaseFailedPickPhase: String, Codable, Sendable { case applied, rescheduled }
/// A failed Pick receipt belongs to one occurrence and its captured tracked
/// state. Hook/config repairs and removal of untracked obstructions are allowed;
/// changed HEAD, index, tracked payload or replay commands retire the receipt.
public struct RebaseFailedPickRecovery: Sendable {
    public let state: RebaseState
    public let head: String
    public let entry: RebaseEntry
    public let diagnostic: String
    public let pendingAction: RebaseFailedPickAction?
    public let cleanupCommand: String?
    public let sessionIdentity: String
    fileprivate let phase: RebaseFailedPickPhase
    fileprivate let directory: URL
    fileprivate let files: [String: RebaseActionEditFile]
    fileprivate let index: Data, worktree: Data
}
private struct RebaseFailedPickIntent: Codable {
    let version: Int
    let state: RebaseState
    let head: String, hash: String, diagnostic: String
    let occurrence: Int
    let prepared: Bool
    let sessionIdentity: String
    let phase: RebaseFailedPickPhase
    let files: [String: RebaseActionEditFile]
    let index: Data, worktree: Data
}
extension GitRepository {
    private static let failedPickIntentName = "turtlegit-failed-pick.json"
    private func failedPickSessionIdentity(_ directory: URL) throws -> String {
        var info=stat();guard lstat(directory.path,&info)==0,info.st_mode & S_IFMT == S_IFDIR else {throw RebaseFailure.changed}
        return [String(info.st_dev),String(info.st_ino),String(info.st_birthtimespec.tv_sec),String(info.st_birthtimespec.tv_nsec)].joined(separator:":")
    }
    private func failedPickPayload() throws -> (index: Data, worktree: Data) {
        let environment=["GIT_OPTIONAL_LOCKS":"0"]
        return (try run(["ls-files","--stage","-v","-z"],environmentOverrides:environment).stdout,
                try run(["diff","--binary","--no-ext-diff","--no-textconv","--"],environmentOverrides:environment).stdout)
    }
    private func failedPickIntent(_ directory: URL) throws -> RebaseFailedPickIntent? {
        guard let bytes=try actionEditFile(directory,Self.failedPickIntentName).bytes else {return nil}
        let intent=try JSONDecoder().decode(RebaseFailedPickIntent.self,from:bytes)
        guard intent.version==1 else {throw RebaseFailure.plan};return intent
    }
    private func failedPickCleanupCommand() -> String {
        ([executable.path,"--literal-pathspecs","-C",root.path,"-c","i18n.logOutputEncoding=UTF-8","rebase","--skip"])
            .map {"'"+$0.replacingOccurrences(of:"'",with:"'\\''")+"'"}.joined(separator:" ")
    }
    public func failedPickRecovery(after execution: RebaseExecution, cancellation: OperationCancellation? = nil) throws -> RebaseFailedPickRecovery? {
        try withReplayIO(cancellation:cancellation,onOutput:nil) {
            guard execution.exitCode != 0,execution.state.active else {return nil}
            let state=try rebaseState(),head=try rebaseRevision("HEAD"),directory=try rebasePath("rebase-merge")
            guard FileManager.default.fileExists(atPath:directory.path),RebaseEditor.ordinaryReplayCommands(in:directory) else {return nil}
            let sessionIdentity=try failedPickSessionIdentity(directory)
            guard execution.witnessedHead==head,execution.witnessedSession==sessionIdentity else {throw RebaseFailure.changed}
            try requireRebaseContinuation(state,expected:execution.state,expectedHead:head)
            guard state.conflicts.isEmpty,!state.isEditPause,state.squashMessage==nil,state.split==nil,!state.isStructuralMergeEdit,
                  FileManager.default.fileExists(atPath:directory.path) else {return nil}
            let files=try actionEditFiles(directory),payload=try failedPickPayload()
            if let pending=try failedPickIntent(directory) {
                guard pending.sessionIdentity==sessionIdentity else {throw RebaseFailure.changed}
                if pending.prepared {
                    guard state.originalHead==pending.state.originalHead,state.branch==pending.state.branch,state.onto==pending.state.onto,
                          state.isCherryPick==pending.state.isCherryPick,head==pending.head else {throw RebaseFailure.changed}
                } else {try requireRebaseContinuation(state,expected:pending.state,expectedHead:pending.head)}
                guard pending.files==files,pending.index==payload.index,pending.worktree==payload.worktree else {throw RebaseFailure.changed}
                var entry=RebaseEntry(commit:try rebaseCommit(pending.hash));entry.occurrence=pending.occurrence;entry.progress = .current
                return RebaseFailedPickRecovery(state:state,head:head,entry:entry,diagnostic:pending.diagnostic,pendingAction:.skip,cleanupCommand:failedPickCleanupCommand(),sessionIdentity:sessionIdentity,phase:pending.phase,directory:directory,files:files,index:payload.index,worktree:payload.worktree)
            }
            let identities=replayIdentities(directory),rescheduled=RebaseEditor.rescheduledPick(in:directory)
            let step=rescheduled?.step ?? state.currentStep
            guard identities.indices.contains(step-1),identities[step-1].action==RebaseAction.pick.rawValue else {return nil}
            let identity=identities[step-1]
            let mapping=(try? JSONDecoder().decode([String:String].self,from:Data(contentsOf:directory.appendingPathComponent("turtlegit-cherry-pick.json")))) ?? [:]
            func command(_ text: String) -> [String] {RebaseEditor.canonicalLine(text).split(separator:" ",maxSplits:2).map(String.init)}
            func lines(_ file: String) -> [String] {String(decoding:files[file]?.bytes ?? Data(),as:UTF8.self).components(separatedBy:"\n").filter {!$0.trimmingCharacters(in:.whitespaces).isEmpty && !$0.hasPrefix("#")}}
            let doneLine:String?
            if let rescheduled {doneLine=String(decoding:files["done"]?.bytes ?? Data(),as:UTF8.self).components(separatedBy:"\n")[rescheduled.doneLine]}
            else {doneLine=lines("done").last}
            guard let doneLine else {return nil}
            let done=command(doneLine)
            guard done.count>=2,done[0]=="pick" else {return nil}
            let executing=try rebaseRevision(done[1]),original=mapping[executing] ?? executing
            guard original==identity.hash else {return nil}
            let phase:RebaseFailedPickPhase
            let dirty=try run(["diff","--cached","--quiet","HEAD","--"],environmentOverrides:["GIT_OPTIONAL_LOCKS":"0"],successfulExitCodes:0...1).exitCode != 0
            let nextFields=lines("git-rebase-todo").first.map(command) ?? []
            let nextHash=nextFields.count>=2 ? (try? rebaseRevision(nextFields[1])) : nil
            let resumedStaged=FileManager.default.fileExists(atPath:directory.appendingPathComponent("message").path) &&
                (try? rebaseRevision("REBASE_HEAD"))==executing && dirty && nextHash != executing
            if rescheduled != nil {
                guard nextFields.count>=2,nextFields[0]=="pick",nextHash==executing,
                      (try? rebaseRevision("REBASE_HEAD"))==executing else {return nil}
                phase = .rescheduled
            } else if !state.stoppedCommit.isEmpty || resumedStaged {
                guard (state.stoppedCommit.isEmpty || state.stoppedCommit==original),state.stoppedAction == .pick else {return nil}
                if !dirty {
                    let object=try rebaseCommit(executing)
                    let base: String
                    if let parent=object.parents.first {base=parent} else {base=try run(["mktree"]).text.trimmingCharacters(in:.newlines)}
                    let originallyEmpty=try run(["diff","--quiet",base,executing,"--"],successfulExitCodes:0...1).exitCode==0
                    guard originallyEmpty else {return nil} // A real became-empty stop keeps its Commit/Skip/Cancel route.
                }
                phase = .applied
            } else {
                guard let first=lines("git-rebase-todo").first else {return nil}
                let scheduled=command(first)
                guard scheduled.count>=2,scheduled[0]=="pick",try rebaseRevision(scheduled[1])==executing,
                      (try? rebaseRevision("REBASE_HEAD"))==executing else {return nil}
                phase = .rescheduled
            }
            var entry=RebaseEntry(commit:try rebaseCommit(identity.hash));entry.occurrence=identity.occurrence;entry.progress = .current
            try requireRebaseContinuation(rebaseState(),expected:state,expectedHead:head)
            let finalPayload=try failedPickPayload()
            guard files == (try actionEditFiles(directory)),payload.index == finalPayload.index,payload.worktree == finalPayload.worktree else {throw RebaseFailure.changed}
            return RebaseFailedPickRecovery(state:state,head:head,entry:entry,diagnostic:execution.output,pendingAction:nil,cleanupCommand:nil,sessionIdentity:sessionIdentity,phase:phase,directory:directory,files:files,index:payload.index,worktree:payload.worktree)
        }
    }
    private func saveFailedPickIntent(_ result: RebaseExecution, expected: RebaseFailedPickRecovery, directory: URL) throws {
        try replayUncancelled {
            let captured=try failedPickPayload()
            var intentState=result.state;intentState.hasFailedPickCleanup=true
            let intent=RebaseFailedPickIntent(version:1,state:intentState,head:try rebaseRevision("HEAD"),hash:expected.entry.commit.hash,diagnostic:result.output,occurrence:expected.entry.occurrence,prepared:false,sessionIdentity:expected.sessionIdentity,phase:expected.phase,files:try actionEditFiles(directory),index:captured.index,worktree:captured.worktree)
            try JSONEncoder().encode(intent).write(to:directory.appendingPathComponent(Self.failedPickIntentName),options:.atomic)
        }
    }
    /// Tortoise runs a fresh Pick command after Retry/Skip and therefore reads
    /// the repaired signing configuration. Git's rebase sequencer instead saves
    /// -S at startup; refresh that owned option without disabling signatures
    /// which are still requested by the current effective configuration.
    private func refreshFailedPickSigning(_ directory: URL) throws {
        let configured=try run(["config","--type=bool","--get","commit.gpgsign"],successfulExitCodes:0...1)
        let sign=String(decoding:configured.stdout,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)=="true"
        _ = try actionEditFile(directory,"gpg_sign_opt")
        try actionEditWrite(.init(bytes:sign ? Data("-S\n".utf8):nil),directory:directory,name:"gpg_sign_opt")
    }
    public func recoverFailedPick(_ expected: RebaseFailedPickRecovery, action requested: RebaseFailedPickAction,
                                  cancellation: OperationCancellation? = nil,onOutput: (@Sendable (GitOutputChunk)->Void)? = nil) throws -> RebaseExecution {
        try withReplayIO(cancellation:cancellation,onOutput:onOutput) {
            let directory=try rebasePath("rebase-merge")
            guard directory==expected.directory,try failedPickSessionIdentity(directory)==expected.sessionIdentity else {throw RebaseFailure.changed}
            try requireRebaseContinuation(rebaseState(),expected:expected.state,expectedHead:expected.head)
            let payload=try failedPickPayload()
            guard expected.files == (try actionEditFiles(directory)),expected.index==payload.index,expected.worktree==payload.worktree else {throw RebaseFailure.changed}
            let action=expected.pendingAction ?? requested
            try refreshFailedPickSigning(directory)
            if expected.pendingAction==nil,expected.phase == .rescheduled {
                try withActionEditLock(directory) {
                    try requireRebaseContinuation(rebaseState(),expected:expected.state,expectedHead:expected.head)
                    guard expected.files == (try actionEditFiles(directory)) else {throw RebaseFailure.changed}
                    var before=expected.files,after=expected.files
                    guard let rescheduled=RebaseEditor.rescheduledPick(in:directory) else {throw RebaseFailure.changed}
                    var done=String(decoding:after["done"]?.bytes ?? Data(),as:UTF8.self).components(separatedBy:"\n")
                    if let duplicate=rescheduled.duplicateLine {done.remove(at:duplicate)}
                    let staged=try run(["diff","--cached","--quiet","HEAD","--"],successfulExitCodes:0...1).exitCode != 0
                    var todo=String(decoding:after["git-rebase-todo"]?.bytes ?? Data(),as:UTF8.self).components(separatedBy:"\n")
                    guard let first=todo.firstIndex(where:{!$0.trimmingCharacters(in:.whitespaces).isEmpty && !$0.hasPrefix("#")}) else {throw RebaseFailure.changed}
                    if action == .retry && staged {
                        // A negative sequencer failure may have staged the patch
                        // before rescheduling it. Convert to Git's commit-resume
                        // form rather than reapplying that same patch.
                        before["message"]=try actionEditFile(directory,"message")
                        before["stopped-sha"]=try actionEditFile(directory,"stopped-sha")
                        let message=try actionEditFile(try rebasePath("MERGE_MSG").deletingLastPathComponent(),"MERGE_MSG")
                        guard message.bytes != nil else {throw RebaseFailure.plan}
                        after["message"]=message
                        let fields=RebaseEditor.canonicalLine(todo[first]).split(separator:" ",maxSplits:2)
                        guard fields.count>=2 else {throw RebaseFailure.changed}
                        after["stopped-sha"] = .init(bytes:Data((try rebaseRevision(String(fields[1]))+"\n").utf8))
                        todo.remove(at:first)
                    } else {
                        done.remove(at:rescheduled.doneLine)
                        if action == .skip {
                            let fields=RebaseEditor.canonicalLine(todo[first]).split(separator:" ",maxSplits:1)
                            guard fields.count==2,fields[0]=="pick" else {throw RebaseFailure.changed}
                            todo[first]="drop "+fields[1]
                        }
                    }
                    after["done"] = .init(bytes:Data(done.joined(separator:"\n").utf8))
                    after["git-rebase-todo"] = .init(bytes:Data(todo.joined(separator:"\n").utf8))
                    if action == .skip {
                        let marker=try actionEditFile(directory,Self.failedPickIntentName)
                        guard marker.bytes==nil else {throw RebaseFailure.changed}
                        let intent=RebaseFailedPickIntent(version:1,state:expected.state,head:expected.head,hash:expected.entry.commit.hash,
                            diagnostic:expected.diagnostic,occurrence:expected.entry.occurrence,prepared:true,sessionIdentity:expected.sessionIdentity,
                            phase:expected.phase,files:after,index:expected.index,worktree:expected.worktree)
                        before[Self.failedPickIntentName]=marker
                        after[Self.failedPickIntentName] = .init(bytes:try JSONEncoder().encode(intent))
                    }
                    try replayCancellation?.check()
                    let journal=RebaseActionEditJournal(version:2,before:before,after:after)
                    let journalURL=directory.appendingPathComponent(Self.actionEditJournal)
                    try JSONEncoder().encode(journal).write(to:journalURL,options:.atomic)
                    for name in after.keys where name != "git-rebase-todo" {try actionEditWrite(after[name]!,directory:directory,name:name)}
                    try actionEditWrite(after["git-rebase-todo"]!,directory:directory,name:"git-rebase-todo")
                    try FileManager.default.removeItem(at:journalURL)
                }
            }
            let preparedState=try replayUncancelled {try rebaseState()}
            let bookkeepingStep=replayIdentities(directory).firstIndex(where:{$0.id==expected.entry.id}).map {$0+1}
            let intentURL=directory.appendingPathComponent(Self.failedPickIntentName)
            if action == .skip {try saveFailedPickIntent(.init(output:expected.diagnostic,exitCode:1,state:preparedState),expected:expected,directory:directory)}
            let result:RebaseExecution
            do {
                if action == .skip {result=try skipRebaseOwned(bookkeepingStep:bookkeepingStep)} else {result=try continueRebaseOwned()}
            } catch {
                if action == .skip {
                    try? replayUncancelled {
                        let actual=try rebaseState()
                        if actual.active,actual.currentStep==preparedState.currentStep,actual.originalHead==expected.state.originalHead,try rebaseRevision("HEAD")==expected.head {
                            try saveFailedPickIntent(.init(output:error.localizedDescription,exitCode:1,state:actual),expected:expected,directory:directory)
                        }
                    }
                }
                throw error
            }
            if action == .skip,result.exitCode != 0,result.state.active,result.state.currentStep==preparedState.currentStep,
               result.state.originalHead==expected.state.originalHead,result.state.onto==expected.state.onto,
               try rebaseRevision("HEAD")==expected.head {try saveFailedPickIntent(result,expected:expected,directory:directory)}
            else if FileManager.default.fileExists(atPath:intentURL.path) {try FileManager.default.removeItem(at:intentURL)}
            return RebaseExecution(output:result.output,exitCode:result.exitCode,state:try rebaseState(),witnessedHead:result.witnessedHead,witnessedSession:result.witnessedSession)
        }
    }
}
