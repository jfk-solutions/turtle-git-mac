import Foundation
import Darwin

public enum RebaseAction: String, CaseIterable, Codable, Sendable { case pick, skip = "drop", edit, squash }
public enum RebaseEntryProgress: Sendable { case pending, current, completed }
/// Logical source rows, independent of Git's sequencer command count.
public struct RebaseProgressEntry: Sendable, Equatable {
    public let id:String
    public let action:RebaseAction
}
public struct RebaseProgress: Sendable, Equatable {
    public let sessionID:String
    public let head:String
    public let entries:[RebaseProgressEntry]
    public let currentEntryID:String?
    public let currentStep:Int
    public let completed:Int
    public var total:Int {entries.count}
    public let finished:Bool
}

public enum RebaseEmptyChoice: Sendable { case commit, skip, cancel }
public enum RebaseSquashDate: Int, Codable, Sendable { case first = 0, latest = 1, current = 2 }
public enum RebaseNoCommitSquashPhase:String,Codable,Sendable {case waiting,applying,conflicted,approval,committed,uncertain}
public struct RebaseNoCommitSquash:Codable,Equatable,Sendable {
    public let id:String,entryID:String,baseHead:String
    public let step:Int
    public let phase:RebaseNoCommitSquashPhase
    public let preservesLeaderAuthor:Bool
    public var nextRetainedAction:RebaseAction? = nil
    fileprivate let files:[String:RebaseActionEditFile]
}
private struct RebaseSquashLeader:Codable,Equatable {
    let message:String,name:String,email:String,date:String
}
private struct RebaseNoCommitControl:Codable,Equatable {
    let line:String,target:String
}
private struct RebaseNoCommitTopology:Codable,Equatable {
    var anchor:String
    var controls:[RebaseNoCommitControl]=[]
}
private struct RebaseStructuralControlArchive:Codable,Equatable {
    let groupID:String
    let cursor:RebaseNoCommitTopology
}
private struct RebaseNoCommitGroup:Codable,Equatable {
    let id:String,session:String
    var baseHead:String,step:Int,phase:RebaseNoCommitSquashPhase
    var message:String,leader:RebaseSquashLeader?,latestDate:String
    var beforeTree:String?=nil
    var applied:[String]=[]
    var prepared:[String]=[]
    var committedHead:String?=nil
    var resolvedCurrent=false
    var reviewedEmpty:[String]=[]
    var readd:[String]=[],remove:[String]=[]
    var readdUnchecked=false
    var allowsEmpty=false
    // The new-commit Split checkpoint belongs to this same journaled group.
    var split:RebaseSplitState? = nil
    var topology:RebaseNoCommitTopology? = nil
}
public struct RebaseSquashMessage: Codable, Sendable {
    public var message: String
    public let datePolicy: RebaseSquashDate
    public let latestDate: String
    public let step: Int
    public var isNewCommit:Bool? = nil
    public var skipOriginalHead: String? = nil
    public var skipBaseHead: String? = nil
}
public struct RebaseSplitReturn: Codable, Equatable, Sendable {
    var structuralControlCursor:Data? = nil
    public let parts: Int
    public let firstAuthor: String
    public let firstDate: String
    public let squashDate: RebaseSquashDate?
    public var firstParents: [String]? = nil
}
public struct RebaseSplitState: Codable, Equatable, Sendable {
    public let entryID: String
    public let step: Int
    public var expectedHead: String
    public var parts: Int
    public let firstAuthor: String
    public let firstDate: String
    public let squashDate: RebaseSquashDate?
    /// A staged source Squash_Edit creates normal parts from the captured base.
    public var noCommitGroupID:String? = nil
    public var isNewCommit:Bool {noCommitGroupID != nil}
    // Reconstructed from exact group/plan bytes on reads;
    // never embedded back into its own group (which would be recursive).
    var noCommitWitness:Data? = nil
    // Retain structural control ownership through the checked-restoration loop.
    var structuralControlCursor:Data? = nil
    fileprivate var stored:Self {var value=self;value.noCommitWitness=nil;return value}
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
    var deferredMainline = false
    var originalEmptySubject:Bool? = nil
    fileprivate var requiresEmptyMessageReview:Bool {(originalEmptySubject ?? commit.hasEmptyReplaySubject) && action != .skip}
    fileprivate var executionAction:RebaseAction {requiresEmptyMessageReview && action != .squash ? .edit:action}
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
public struct RebaseEmptyMessageWarning:Codable,Equatable,Sendable {
    public let entryID:String,commit:String
    public let requestedAction:RebaseAction
    public let step:Int
    public let head:String
}
public struct RebaseMainlineDecision:Codable,Equatable,Sendable {
    public let entryID:String,commit:String
    public let requestedAction:RebaseAction
    public let step:Int
    public let head:String
    public let parents:[String]
    fileprivate let sessionIdentity:String
    fileprivate let files:[String:RebaseActionEditFile]
}
private struct RebaseMainlineAnchor:Codable {
    let entryID:String,sessionIdentity:String,head:String
    let parents:[String]
    var squashLeader:RebaseSquashLeader? = nil
    var squashCurrentEmpty:Bool? = nil
}
/// A failed message commit at a still-clean, stopped replay. Retry leaves the
/// editor intact; Ignore consumes this exact receipt without running commit again.
public struct RebaseCleanCommitFailure:Codable,Equatable,Sendable,LocalizedError {
    public let id:String
    public let identity:RebaseMessageIdentity
    public let head:String
    public let message:String
    public let diagnostic:String
    public let command:[String]
    public let exitCode:Int32
    fileprivate let sessionIdentity:String
    fileprivate var files:[String:RebaseActionEditFile]
    fileprivate var ignored:Bool
    public var errorDescription:String? {diagnostic}
}
public enum RebaseConflictMessagePhase:String,Codable,Sendable {case pending,complete,uncertain}
public struct RebaseConflictMessage:Codable,Equatable,Sendable {
    public let entryID:String,beforeHead:String,originalCommit:String,originalMessage:String
    public var head:String
    public var rawMessage:String
    public let requestedAction:RebaseAction
    public var needsAmend:Bool
    public var phase:RebaseConflictMessagePhase
    fileprivate let sessionIdentity:String
    fileprivate let step:Int
    fileprivate let originalHead:String
    fileprivate var index:Data
    fileprivate var files:[String:RebaseActionEditFile]
    fileprivate var prepared:Bool
    fileprivate var readd:[String]
    fileprivate var remove:[String]
    fileprivate let readdUnchecked:Bool
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
    public var emptyMessageWarning:RebaseEmptyMessageWarning? = nil
    public var mainlineDecision:RebaseMainlineDecision? = nil
    public var noCommitSquash:RebaseNoCommitSquash? = nil
    var hasMainlineCheckpoint = false
    var mainlineCheckpointHead:String? = nil
    public var cleanCommitFailure:RebaseCleanCommitFailure? = nil
    public var hasIgnoredCleanCommitFailure = false
    public var conflictMessage:RebaseConflictMessage? = nil
    public var hasFailedPickCleanup = false
    public var hasStructuralResultCheckpoint = false
    var structuralResultHead:String? = nil
    // Recovery receipts are stored separately, not recursively embedded in older
    // session/state journals. Reopening reconstructs them from the owned record.
    private enum CodingKeys:String,CodingKey {
        case active,isCherryPick,branch,originalHead,onto,stoppedEntryID,stoppedCommit,mergeParents,message,currentStep,total,conflicts,remainingCommands,squashMessage,stoppedAction,split,isEditPause,isStructuralMergeEdit,hasStructuralMergeResult,needsFileRecovery,session,emptyMessageWarning,hasFailedPickCleanup
    }
    public var canSplit: Bool {
        guard !hasStructuralResultCheckpoint,!hasMainlineCheckpoint,mainlineDecision == nil,conflictMessage == nil,cleanCommitFailure == nil,!hasIgnoredCleanCommitFailure,!hasFailedPickCleanup,active,conflicts.isEmpty else{return false}
        if let group=noCommitSquash {
            guard group.phase == .approval else{return false}
            // Source1568 enters the checked Split loop only at the end of a
            // requested Squash chain. An already opened loop remains resumable.
            if let split {return split.noCommitGroupID==group.id}
            return group.nextRetainedAction != .squash
        }
        return isEditPause || squashMessage != nil && squashMessage?.skipBaseHead == nil || split != nil && split?.conflictRecovery != true
    }
}
/// Identifies the stopped occurrence and original session, not just its step number.
public struct RebaseConflictIdentity:Equatable,Sendable {
    public let originalHead:String,branch:String,onto:String,entry:String
    public let step:Int,splitParts:Int
    public let cherryPick:Bool
    public let noCommitGroup:String?
    public static func == (a: Self, b: Self) -> Bool {
        GitReferenceName.equal(a.originalHead,b.originalHead) && GitReferenceName.equal(a.branch,b.branch) && GitReferenceName.equal(a.onto,b.onto) && GitReferenceName.equal(a.entry,b.entry) && a.step == b.step && a.splitParts == b.splitParts && a.cherryPick == b.cherryPick && a.noCommitGroup == b.noCommitGroup
    }
    public init?(_ state:RebaseState) {
        guard state.active,!state.hasStructuralResultCheckpoint,state.noCommitSquash?.phase != .uncertain,!state.hasMainlineCheckpoint,state.conflictMessage == nil,!state.hasFailedPickCleanup,state.squashMessage?.skipBaseHead == nil else {return nil}
        originalHead=state.originalHead;branch=state.branch;onto=state.onto;entry=state.stoppedEntryID
        step=state.currentStep;splitParts=state.split?.parts ?? 0;cherryPick=state.isCherryPick;noCommitGroup=state.noCommitSquash.map {$0.id+":"+$0.phase.rawValue}
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
        guard state.active,!state.hasStructuralResultCheckpoint,state.noCommitSquash?.phase != .uncertain,state.conflictMessage?.phase != .complete,state.conflictMessage?.phase != .uncertain, !state.hasFailedPickCleanup,!state.hasIgnoredCleanCommitFailure, !head.isEmpty, state.needsFileRecovery || state.isEditPause || state.squashMessage != nil || state.split != nil else { return nil }
        originalHead = state.originalHead; branch = state.branch; onto = state.onto; entry = state.stoppedEntryID; self.head = head; step = state.currentStep
        phase = state.noCommitSquash.map {"no-commit-squash:"+$0.id+":"+$0.phase.rawValue} ?? (state.conflictMessage != nil ? "conflict-message" : state.squashMessage != nil ? "squash" : state.split?.conflictRecovery == true ? "amend-selection" : state.split != nil ? "split" : state.isEditPause ? "edit" : "conflict")
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
    case revision, active, inactive, changed, plan, squash, preservePlan, message, mainline, emptyResult, actionEditLocked,conflictMessageUncertain,noCommitSquashUncertain
    public var errorDescription: String? {
        switch self {
        case .noCommitSquashUncertain:return "A squash operation was interrupted while applying changes or creating a commit. Inspect the index and working tree, or abort the replay. The operation will not be repeated automatically."
        case .conflictMessageUncertain:return "A conflict-resolution commit may already have been published. Inspect HEAD before continuing, or abort the replay. The initial commit will not be repeated."
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
        case .mainline: return "Choose a valid mainline parent for the reached merge commit."
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
    static let emptyMessagePrefix="exec false # turtlegit-empty-subject:"
    static let emptyAppliedPrefix="exec false # turtlegit-empty-applied:"
    static let sourceSquashPrefix="exec false # turtlegit-source-squash:"
    static func sourceSquashID(_ line:String)->String? {line.hasPrefix(sourceSquashPrefix) ? emptyMessageID(emptyMessagePrefix+line.dropFirst(sourceSquashPrefix.count)):nil}
    static let structuralResultPrefix="exec false # turtlegit-structural-result:"
    static func structuralResultID(_ line:String)->String? {line.hasPrefix(structuralResultPrefix) ? emptyMessageID(emptyMessagePrefix+line.dropFirst(structuralResultPrefix.count)):nil}
    static let structuralResultDonePrefix="# turtlegit-structural-result:"
    static func completedStructuralResult(_ line:String)->(id:String,head:String)? {
        guard line.hasPrefix(structuralResultDonePrefix) else{return nil}
        let fields=line.dropFirst(structuralResultDonePrefix.count).split(separator:" ").map(String.init)
        guard fields.count==2,let id=emptyMessageID(emptyMessagePrefix+fields[0]),GitLocalReferenceProtocol.validOID(fields[1]) else{return nil}
        return (id,fields[1])
    }
    static let mainlinePrefix="exec false # turtlegit-mainline:"
    static func mainlineID(_ line:String)->String? {
        guard line.hasPrefix(mainlinePrefix) else{return nil}
        return emptyMessageID(emptyMessagePrefix+line.dropFirst(mainlinePrefix.count))
    }
    static func emptyMessageID(_ line:String,applied:Bool=false)->String? {
        let prefix=applied ? emptyAppliedPrefix:emptyMessagePrefix
        guard line.hasPrefix(prefix) else {return nil}
        let id=String(line.dropFirst(prefix.count)),parts=id.split(separator:":",omittingEmptySubsequences:false)
        guard (parts.count==1 || parts.count==2),[40,64].contains(parts[0].utf8.count),parts[0].utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}),parts.count==1 || (Int(parts[1]).map{$0>0} == true && parts[1].allSatisfy{$0.isASCII && $0.isNumber}) else {return nil}
        return id
    }
    static func ownedEmptyLine(_ line:String)->Bool {emptyMessageID(line) != nil || emptyMessageID(line,applied:true) != nil}
    static func ownedCheckpointLine(_ line:String)->Bool {ownedEmptyLine(line) || mainlineID(line) != nil || sourceSquashID(line) != nil || structuralResultID(line) != nil}
    static func executionLines(_ entry:RebaseEntry,hash:String?=nil,subject:String?=nil,deferSquash:Bool=false,noCommitSquash:Bool=false)->[String] {
        // Git validates the whole todo before running the reached checkpoint,
        // and rejects merge OIDs for pick/edit/squash. Drop admits the exact
        // original OID without preparing or applying any parent-dependent patch.
        let physicalAction=noCommitSquash || deferSquash || entry.deferredMainline && entry.mainline==nil && entry.action != .skip ? RebaseAction.skip:entry.executionAction
        let command=physicalAction.rawValue+" "+(hash ?? entry.commit.hash)+" "+(subject ?? entry.commit.subject).replacingOccurrences(of:"\n",with:" ").replacingOccurrences(of:"\r",with:" ")
        return (entry.requiresEmptyMessageReview ? [emptyMessagePrefix+entry.id]:[])
            + (entry.deferredMainline && entry.action != .skip ? [mainlinePrefix+entry.id]:[])
            + (noCommitSquash ? [sourceSquashPrefix+entry.id]:[])
            + [command] + (entry.requiresEmptyMessageReview && entry.action == .squash ? [emptyAppliedPrefix+entry.id]:[])
    }
    static func deferredSquashPositions(_ entries:[RebaseEntry])->Set<Int> {
        var waiting=false,result=Set<Int>()
        for index in entries.indices {
            let entry=entries[index]
            if entry.action == .skip {continue}
            if entry.action != .squash {waiting=false}
            if entry.deferredMainline && entry.mainline==nil {waiting=true}
            else if waiting && entry.action == .squash {result.insert(index)}
        }
        return result
    }
    static func orphanSquashPositions(_ entries:[RebaseEntry])->Set<Int> {
        var hasLeader=false,result=Set<Int>()
        for index in entries.indices {
            let action=entries[index].action
            if action == .skip {continue}
            if action == .squash {if !hasLeader {result.insert(index)}}
            else {hasLeader=true}
        }
        return result
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
            if let metadata=environment["TURTLEGIT_REPLAY_SESSION"] {
                try Data(contentsOf:URL(fileURLWithPath:metadata)).write(to:target.deletingLastPathComponent().appendingPathComponent("turtlegit-session.json"),options:.atomic)
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
                    if ownedCheckpointLine(rows[next]) || fields[next].first == RebaseAction.skip.rawValue { next += 1; continue }
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
                    if let id=sourceSquashID(line) {
                        guard identities.contains(where:{$0.id==id && $0.noCommitSquash==true}) else{return false}
                        continue
                    }
                    if let id=mainlineID(line) {
                        guard identities.contains(where:{$0.id==id && $0.deferredMainline==true}) else{return false}
                        continue
                    }
                    if let id = emptyMessageID(line) ?? emptyMessageID(line, applied: true) {
                        guard identities.contains(where: { $0.id == id && $0.emptySubject == true }) else { return false }
                        continue
                    }
                    guard command=="update-ref",fields.count==2,updates.contains(GitReferenceName(fields[1])) else {return false}
                }
            }
        }
        return true
    }
    struct OwnedCheckpointReschedule {
        let id: String, line: String, duplicateLine: Int
        let done: String
    }
    /// Git 2.39's save_todo appends the preceding instruction again when a
    /// failed exec is rescheduled. Recognize only our exact reached occurrence:
    /// the same owned exec must lead todo and immediately precede that one
    /// duplicate in done. This projection never writes recovery files.
    static func ownedCheckpointReschedule(in directory: URL, done suppliedDone: String? = nil, todo suppliedTodo: String? = nil) -> OwnedCheckpointReschedule? {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("reschedule-failed-exec").path),
              let done = suppliedDone ?? (try? String(contentsOf: directory.appendingPathComponent("done"), encoding: .utf8)),
              let todo = suppliedTodo ?? (try? String(contentsOf: directory.appendingPathComponent("git-rebase-todo"), encoding: .utf8)),
              done.utf8.count + todo.utf8.count <= 32 * 1024 * 1024,
              let bytes = try? Data(contentsOf: directory.appendingPathComponent("turtlegit-replay-identities.json")),
              let identities = try? JSONDecoder().decode([RebaseReplayIdentity].self, from: bytes),
              !identities.isEmpty, Set(identities.map(\.id)).count == identities.count else { return nil }
        let lines = done.components(separatedBy: "\n")
        let indices = lines.indices.filter { !lines[$0].isEmpty }
        guard indices.count >= 3 else { return nil }
        let duplicate = indices[indices.count - 1], checkpoint = indices[indices.count - 2], previous = indices[indices.count - 3]
        let line = canonicalLine(lines[checkpoint])
        guard canonicalLine(lines[duplicate]) == canonicalLine(lines[previous]),
              let first = todo.components(separatedBy: "\n").first(where: { !$0.isEmpty && !$0.hasPrefix("#") }), canonicalLine(first) == line else { return nil }
        let id: String?
        if let value = sourceSquashID(line), identities.contains(where: { $0.id == value && $0.noCommitSquash == true }) { id = value }
        else if let value = mainlineID(line), identities.contains(where: { $0.id == value && $0.deferredMainline == true }) { id = value }
        else if let value = emptyMessageID(line) ?? emptyMessageID(line, applied: true), identities.contains(where: { $0.id == value && $0.emptySubject == true }) { id = value }
        else if let value = structuralResultID(line), identities.contains(where: { $0.id == value && $0.structuralMerge == true }) { id = value }
        else { id = nil }
        guard let id else { return nil }
        var normalized = lines; normalized.remove(at: duplicate)
        return .init(id: id, line: line, duplicateLine: duplicate, done: normalized.joined(separator: "\n"))
    }
    static func checkpointDone(in directory: URL, text: String) -> String {
        ownedCheckpointReschedule(in: directory, done: text)?.done ?? text
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
            guard fields.count>=2,fields[0]==identity.todoAction else {return false}
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
        let emptyIdentities=(try? JSONDecoder().decode([RebaseReplayIdentity].self,from:Data(contentsOf:directory.appendingPathComponent("turtlegit-replay-identities.json")))) ?? []
        let emptyDone=checkpointDone(in:directory,text:(try? String(contentsOf:directory.appendingPathComponent("done"),encoding:.utf8)) ?? "").split(separator:"\n").map(String.init)
        if let last=emptyDone.last,let id=emptyMessageID(last) ?? emptyMessageID(last,applied:true) ?? mainlineID(last) ?? sourceSquashID(last) ?? structuralResultID(last),let index=emptyIdentities.firstIndex(where:{$0.id==id}) {return index+1}
        if emptyIdentities.contains(where:{$0.emptySubject==true || $0.deferredMainline==true || $0.noCommitSquash==true}),!FileManager.default.fileExists(atPath:directory.appendingPathComponent("turtlegit-structural-plan").path) {
            if let resumed=rescheduledPick(in:directory) {return resumed.step}
            return emptyDone.filter {canonicalLine($0).split(separator:" ").first.flatMap {RebaseAction(rawValue:String($0))} != nil}.count
        }
        if FileManager.default.fileExists(atPath:directory.appendingPathComponent(GitRepository.adoptedPlanName).path) {
            let done=(try? String(contentsOf:directory.appendingPathComponent("done"),encoding:.utf8)) ?? ""
            return max(1,GitRepository.adoptionCommands(done).count)
        }
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
                    let originalFirst = lines[(boundaries[1] + 1)..<boundaries[2]].joined(separator: "\n").trimmingCharacters(in: .newlines)
                    // Git keeps message-squash's original first section after a
                    // native intermediate approval. That approved text is the
                    // source's next squash accumulator, not the stale section.
                    let firstMessage: String
                    if let through = config.reviewedThrough, through >= start + 1, through < step, let approved = config.reviewedMessage { firstMessage = approved.trimmingCharacters(in: .newlines) }
                    else { firstMessage = originalFirst }
                    let skippedURL = directory.appendingPathComponent("turtlegit-skipped-steps.json")
                    let skipped = FileManager.default.fileExists(atPath: skippedURL.path) ? try JSONDecoder().decode(Set<Int>.self, from: Data(contentsOf: skippedURL)) : []
                    let rest = (max(start + 1, config.reviewedThrough ?? 0)..<step).filter { actions[$0] == RebaseAction.squash.rawValue && !skipped.contains($0 + 1) }.map { messages[$0].trimmingCharacters(in: .newlines) }
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
    var reviewedThrough: Int? = nil
    var reviewedMessage: String? = nil
    var structuralControls:[RebaseStructuralControlArchive]? = nil
}
private struct RebaseReplayIdentity: Codable {
    let hash: String
    let occurrence: Int
    var action: String? = nil
    var mainline: Int? = nil
    var deferredMainline:Bool? = nil
    var deferredSquash:Bool? = nil
    var noCommitSquash:Bool? = nil
    var structuralMerge:Bool? = nil
    var emptySubject:Bool? = nil
    var executionAction:String? {emptySubject == true && action != RebaseAction.skip.rawValue && action != RebaseAction.squash.rawValue ? RebaseAction.edit.rawValue:action}
    var todoAction:String? {noCommitSquash==true || deferredSquash==true || deferredMainline==true && mainline==nil && action != RebaseAction.skip.rawValue ? RebaseAction.skip.rawValue:executionAction}
    var id: String { occurrence == 0 ? hash : hash + ":" + String(occurrence) }
}
/// Runs synchronously on the owning repository's command-drain loop. Sampling
/// never launches Git and never mutates replay metadata. Inconsistent/transient
/// reads are omitted rather than turned into guessed progress.
final class RebaseProgressObservation: @unchecked Sendable {
    private let directory:URL,headFile:URL,cancellation:OperationCancellation?
    private let callback:@Sendable(RebaseProgress)->Void
    private let planned:[RebaseProgressEntry]?,plannedBase:String?,plannedOnto:String?
    private var directoryIdentity:String?,sessionFiles:[Data]?,identityBytes:Data?
    private var last:RebaseProgress?,retired=false,lastSample:TimeInterval=0
    private var lastSignature:[String]?
    private var sessionID=UUID().uuidString
    init(directory:URL,headFile:URL,plan:RebasePlan?,cancellation:OperationCancellation?,callback:@escaping @Sendable(RebaseProgress)->Void) {
        self.directory=directory;self.headFile=headFile;self.cancellation=cancellation;self.callback=callback
        planned=plan?.entries.map{.init(id:$0.id,action:$0.action)};plannedBase=plan?.branchHash;plannedOnto=plan?.ontoHash
        // An existing directory belongs to this operation, not a later replay.
        directoryIdentity=Self.identity(directory)
    }
    private static func identity(_ url:URL)->String? {
        var info=stat();guard lstat(url.path,&info)==0,info.st_mode & S_IFMT==S_IFDIR else{return nil}
        return "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
    }
    private func read(_ url:URL,limit:Int=32*1024*1024)->Data? {
        var info=stat();guard lstat(url.path,&info)==0,info.st_mode & S_IFMT==S_IFREG,info.st_size>=0,info.st_size<=limit else{return nil}
        return try? Data(contentsOf:url)
    }
    private func file(_ name:String)->Data? {read(directory.appendingPathComponent(name))}
    private func signature()->[String] {
        let paths=["orig-head","onto","head-name","turtlegit-replay-identities.json","done","git-rebase-todo","turtlegit-cherry-pick.json","turtlegit-structural-plan","turtlegit-skipped-steps.json","turtlegit-update-refs","update-refs","turtlegit-adopted-plan.json","turtlegit-no-commit-squash.json"].map {directory.appendingPathComponent($0)}+[headFile]
        return paths.map {path in
            var info=stat();guard lstat(path.path,&info)==0 else{return "missing"}
            return "\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        }
    }
    func retire(){retired=true}
    func sample(force:Bool=false) {
        guard !retired,cancellation?.isCancelled != true else{return}
        let now=Date.timeIntervalSinceReferenceDate
        guard force || now-lastSample>=0.05 else{return};lastSample=now
        guard let directoryID=Self.identity(directory) else{return}
        if let directoryIdentity,directoryIdentity != directoryID {retire();return}
        let observedSignature=signature()
        guard observedSignature != lastSignature else{return}
        guard let original=file("orig-head"),let onto=file("onto"),let branch=file("head-name"),
              let encoded=file("turtlegit-replay-identities.json"),let done=file("done"),let todo=file("git-rebase-todo"),let head=read(headFile,limit:4096),
              let identities=try? JSONDecoder().decode([RebaseReplayIdentity].self,from:encoded),!identities.isEmpty,
              let text=String(data:done,encoding:.utf8),let headText=String(data:head,encoding:.utf8)?.trimmingCharacters(in:.newlines),GitLocalReferenceProtocol.validOID(headText) else{return}
        let immutable=[original,onto,branch]
        if let sessionFiles,sessionFiles != immutable {retire();return}
        if let identityBytes,identityBytes != encoded {
            guard let previous=try? JSONDecoder().decode([RebaseReplayIdentity].self,from:identityBytes),previous.count==identities.count,
                  zip(previous,identities).allSatisfy({ old,new in
                      old.hash==new.hash && old.occurrence==new.occurrence && old.action==new.action && old.emptySubject==new.emptySubject && old.deferredMainline==new.deferredMainline && (old.noCommitSquash==new.noCommitSquash || old.noCommitSquash != true && new.noCommitSquash==true) && (old.deferredSquash==new.deferredSquash || old.deferredSquash==true && new.deferredSquash==false) &&
                      (old.mainline==new.mainline || old.mainline==nil && new.deferredMainline==true && (new.mainline ?? 0)>0)
                  }) else{retire();return}
        }
        let entries=identities.compactMap {identity->RebaseProgressEntry? in
            guard let action=identity.action.flatMap(RebaseAction.init(rawValue:)) else{return nil}
            return .init(id:identity.id,action:action)
        }
        guard entries.count==identities.count,Set(entries.map(\.id)).count==entries.count else{return}
        if let planned {
            guard entries==planned,String(decoding:original,as:UTF8.self).trimmingCharacters(in:.newlines)==plannedBase,
                  String(decoding:onto,as:UTF8.self).trimmingCharacters(in:.newlines)==plannedOnto else{retire();return}
        }
        let mappingBytes=file("turtlegit-cherry-pick.json"),adoptedBytes=file("turtlegit-adopted-plan.json"),structuralBytes=file("turtlegit-structural-plan")
        let mapping=mappingBytes.flatMap{try? JSONDecoder().decode([String:String].self,from:$0)} ?? [:]
        var cursor=0,current=0
        let resumed=RebaseEditor.rescheduledPick(in:directory)
        let adopted=adoptedBytes.flatMap {try? JSONDecoder().decode(RebaseAdoptedPlan.self,from:$0)}
        let structural=structuralBytes != nil || adopted?.structural==true
        for raw in RebaseEditor.checkpointDone(in:directory,text:text).split(separator:"\n") {
            let line=RebaseEditor.canonicalLine(String(raw)),fields=line.split(separator:" ").map(String.init)
            if let id=RebaseEditor.emptyMessageID(line) ?? RebaseEditor.emptyMessageID(line,applied:true) ?? RebaseEditor.mainlineID(line) ?? RebaseEditor.sourceSquashID(line) ?? RebaseEditor.structuralResultID(line),let index=entries.firstIndex(where:{$0.id==id}) {current=index+1;continue}
            guard let command=fields.first else{continue}
            if command.hasPrefix("#") {continue}
            guard RebaseAction(rawValue:command) != nil || ["label","reset","merge","break","update-ref","noop"].contains(command) else{return}
            var token:String?
            if RebaseAction(rawValue:command) != nil,fields.count>=2 {token=fields[1]}
            else if structural,command=="merge",fields.count>=3 {token=fields[2]}
            else if structural,command=="label",fields.count==2,fields[1].hasPrefix("turtlegit-") {token=String(fields[1].dropFirst("turtlegit-".count))}
            else if structural,command=="reset",fields.count==2 {token=fields[1]}
            guard let token else{continue}
            let original=mapping[token] ?? token
            let adoptedToken: String? = identities.indices.contains(cursor) ? adopted?.originals[identities[cursor].id].flatMap {saved in
                let fields=RebaseEditor.canonicalLine(saved).split(separator:" ").map(String.init)
                return fields.first=="merge" ? (fields.count>=3 ? fields[2]:nil):(fields.count>=2 ? fields[1]:nil)
            }:nil
            let approvedAbbreviation=adoptedToken==token && original.utf8.count>=4 && original.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            if identities.indices.contains(cursor),(GitReferenceName.equal(identities[cursor].hash,original) || approvedAbbreviation && identities[cursor].hash.hasPrefix(original)) {cursor += 1;current=cursor}
            else if (RebaseAction(rawValue:command) != nil || command=="merge") && resumed == nil {return}
        }
        if let resumed {current=resumed.step}
        guard current<=entries.count,mappingBytes==file("turtlegit-cherry-pick.json"),adoptedBytes==file("turtlegit-adopted-plan.json"),structuralBytes==file("turtlegit-structural-plan"),done==file("done"),todo==file("git-rebase-todo"),encoded==file("turtlegit-replay-identities.json"),
              immutable==[file("orig-head"),file("onto"),file("head-name")].compactMap({$0}),head==read(headFile,limit:4096),Self.identity(directory)==directoryID,signature()==observedSignature else{return}
        directoryIdentity=directoryID;sessionID=directoryID;sessionFiles=immutable;identityBytes=encoded;lastSignature=observedSignature
        let receipt=RebaseProgress(sessionID:sessionID,head:headText,entries:entries,currentEntryID:current>0 ? entries[current-1].id:nil,currentStep:current,completed:max(0,current-1),finished:false)
        publish(receipt)
    }
    func finish(head:String) {
        guard !retired,cancellation?.isCancelled != true,GitLocalReferenceProtocol.validOID(head),let entries=last?.entries ?? planned else{return}
        // A replaced directory invalidates the observer even if Git returned 0.
        if let actual=Self.identity(directory),let directoryIdentity,actual != directoryIdentity {retire();return}
        publish(.init(sessionID:sessionID,head:head,entries:entries,currentEntryID:nil,currentStep:entries.count,completed:entries.count,finished:true));retire()
    }
    private func publish(_ value:RebaseProgress){guard value != last else{return};last=value;callback(value)}
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
    private func reachedMainlineAnchor(_ directory:URL,entryID:String,sessionIdentity:String,parents:[String],cancellation:OperationCancellation?) throws -> RebaseMainlineAnchor {
        let anchor=directory.appendingPathComponent("turtlegit-mainline-"+entryID.replacingOccurrences(of:":",with:"-")+".json")
        // A separate advisory lock cannot recurse into git-rebase-todo.lock.
        // Atomic replacement under this lock publishes complete bytes while a
        // second reader rechecks and preserves the first completed anchor. This
        // also works on repository volumes without hard-link support.
        let descriptor=Darwin.open(anchor.path+".lock",O_RDWR|O_CREAT|O_NOFOLLOW,mode_t(0o600))
        guard descriptor>=0 else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno),userInfo:nil)}
        defer {Darwin.close(descriptor)}
        var info=stat();guard fstat(descriptor,&info)==0,(info.st_mode&S_IFMT)==S_IFREG else{throw RebaseFailure.plan}
        let deadline=Date().addingTimeInterval(5)
        while flock(descriptor,LOCK_EX|LOCK_NB) != 0 {
            guard errno==EWOULDBLOCK || errno==EAGAIN else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno),userInfo:nil)}
            try cancellation?.check();guard Date()<deadline else{throw RebaseFailure.actionEditLocked}
            Thread.sleep(forTimeInterval:0.01)
        }
        defer {flock(descriptor,LOCK_UN)}
        try cancellation?.check()
        var anchorInfo=stat()
        if lstat(anchor.path,&anchorInfo)==0 {
            guard (anchorInfo.st_mode&S_IFMT)==S_IFREG else{throw RebaseFailure.plan}
        } else {
            guard errno==ENOENT else{throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno),userInfo:nil)}
            var value=RebaseMainlineAnchor(entryID:entryID,sessionIdentity:sessionIdentity,head:try rebaseRevision("HEAD",cancellation:cancellation),parents:parents)
            let identities=replayIdentities(directory)
            if let index=identities.firstIndex(where:{$0.id==entryID}),identities.dropFirst(index+1).first(where:{$0.action != RebaseAction.skip.rawValue})?.action==RebaseAction.squash.rawValue,identities[index].action != RebaseAction.squash.rawValue {
                let original=try rebaseCommit(identities[index].hash,cancellation:cancellation)
                let session=try? JSONDecoder().decode(RebaseSessionContext.self,from:Data(contentsOf:directory.appendingPathComponent("turtlegit-session.json")))
                var message=Self.sourceSquashMessage(original)
                if session?.addCherryPickedFrom==true {message += (original.historyBody.isEmpty ? "\n":"\n\n")+"(cherry picked from commit "+original.hash+")"}
                value.squashLeader = .init(message:message,name:original.author,email:original.email,date:original.date)
                if let first=original.parents.first {value.squashCurrentEmpty=try run(["diff","--quiet",first,original.hash,"--"],successfulExitCodes:0...1).exitCode==0}
            }
            try JSONEncoder().encode(value).write(to:anchor,options:.atomic)
        }
        guard let bytes=try actionEditFile(directory,anchor.lastPathComponent).bytes else{throw RebaseFailure.changed}
        return try JSONDecoder().decode(RebaseMainlineAnchor.self,from:bytes)
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
        var commands = read("git-rebase-todo").split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }.map { command -> String in
            var fields = RebaseEditor.canonicalLine(command).split(separator: " ", maxSplits: 2).map(String.init)
            if fields.count >= 2, let original = mapping[fields[1]] { fields[1] = original }
            return fields.joined(separator: " ")
        }
        let identities = replayIdentities(directory)
        let structural = manager.fileExists(atPath:directory.appendingPathComponent("turtlegit-structural-plan").path)
        let noCommit=active ? try noCommitGroup(directory):nil
        let commandSlots=commands.indices.filter {commands[$0].split(separator:" ").first.flatMap {RebaseAction(rawValue:String($0))} != nil}
        let commandOffset=identities.count-commandSlots.count
        if commandOffset>=0 {
            for (position,slot) in commandSlots.enumerated() where identities.indices.contains(commandOffset+position) {
                var fields=commands[slot].split(separator:" ",maxSplits:2).map(String.init)
                let identity:RebaseReplayIdentity
                if structural {
                    guard fields.count>=2,let exact=identities.first(where:{$0.hash.hasPrefix(fields[1])}) else{continue}
                    identity=exact
                } else {identity=identities[commandOffset+position]}
                if fields.count>=2,fields[0]==RebaseAction.skip.rawValue,identity.todoAction==RebaseAction.skip.rawValue,identity.action != RebaseAction.skip.rawValue,identity.hash.hasPrefix(fields[1]),let action=identity.executionAction {
                    fields[0]=action;commands[slot]=fields.joined(separator:" ")
                }
            }
        }
        let adopted = try adoptedPlan(directory)
        let projected = active && (identities.isEmpty || adopted != nil)
        let logicalDone=Self.adoptionCommands(read("done")),logicalTodo=Self.adoptionCommands(read("git-rebase-todo"))
        let done = RebaseEditor.checkpointDone(in:directory,text:read("done")).split(separator:"\n").map {RebaseEditor.canonicalLine(String($0))}
        let warningID=done.last.flatMap {RebaseEditor.emptyMessageID($0)}.flatMap {id in noCommit?.reviewedEmpty.contains(id)==true ? nil:id}
        let mainlineID=done.last.flatMap {RebaseEditor.mainlineID($0)}
        let mainlineIndex=mainlineID.flatMap {id in identities.firstIndex(where:{$0.id==id && $0.deferredMainline==true && $0.action != RebaseAction.skip.rawValue})}
        if mainlineID != nil && mainlineIndex==nil {throw RebaseFailure.plan}
        let checkpointIndex: Int?
        let appliedID=done.last.flatMap {RebaseEditor.emptyMessageID($0,applied:true)}
        let emptyIndex=(warningID ?? appliedID).flatMap {id in identities.firstIndex(where:{$0.id==id && $0.emptySubject==true && $0.action != RebaseAction.skip.rawValue})}
        if (warningID != nil || appliedID != nil) && emptyIndex==nil {throw RebaseFailure.plan}
        let sourceIndex=done.last.flatMap {RebaseEditor.sourceSquashID($0)}.flatMap {id in identities.firstIndex(where:{$0.id==id && $0.noCommitSquash==true})}
        let completedStructural=done.last.flatMap(RebaseEditor.completedStructuralResult)
        let structuralResultIndex=(done.last.flatMap(RebaseEditor.structuralResultID) ?? completedStructural?.id).flatMap {id in identities.firstIndex(where:{$0.id==id && $0.structuralMerge==true})}
        if completedStructural != nil && structuralResultIndex==nil {throw RebaseFailure.plan}
        checkpointIndex = emptyIndex ?? mainlineIndex ?? sourceIndex ?? structuralResultIndex ?? noCommit.map {$0.step-1}
        let step = checkpointIndex.map{$0+1} ?? (projected ? max(1,logicalDone.count):RebaseEditor.currentStep(in: directory))
        let currentMerge=logicalDone.last?.first == "merge" || identities.indices.contains(step-1) && adopted?.merges.contains(identities[step-1].id) == true
        let mergeEdit = active && ((structural && done.last?.split(separator:" ").first == "break" && identities.indices.contains(step - 1) && identities[step - 1].executionAction == RebaseAction.edit.rawValue && commands.first == "label turtlegit-" + identities[step - 1].hash) || projected && currentMerge && done.last?.split(separator:" ").first == "break")
        let mergeReplay = active && ((structural && done.last?.split(separator:" ").first == "merge" && identities.indices.contains(step - 1)) || projected && currentMerge && done.last?.split(separator:" ").first == "merge")
        let mergeHash=logicalDone.last.flatMap{$0.first == "merge" && $0.count>=3 ? $0[2]:nil}
        let projectedStopped = try mergeHash.map{try rebaseRevision($0,cancellation:cancellation)} ?? stopped
        let originalStopped = checkpointIndex.map{identities[$0].hash} ?? (mergeEdit || mergeReplay ? (identities.indices.contains(step-1) ? identities[step-1].hash:projectedStopped) : mapping[stopped] ?? stopped)
        var stoppedIdentity = identities.indices.contains(step - 1) && identities[step - 1].hash == originalStopped ? identities[step - 1].id : originalStopped
        if projected,identities.isEmpty,!originalStopped.isEmpty {
            var occurrence=0
            for fields in logicalDone.dropLast() {
                let token=fields.first == "merge" ? (fields.count>=3 ? fields[2]:""):(fields.count>=2 ? fields[1]:"")
                if !token.isEmpty,let resolved=try? rebaseRevision(token,cancellation:cancellation),GitReferenceName.equal(resolved,originalStopped) {occurrence += 1}
            }
            if occurrence>0 {stoppedIdentity=originalStopped+":"+String(occurrence)}
        }
        let requestURL = directory.appendingPathComponent("turtlegit-squash-message.json")
        let request = active && manager.fileExists(atPath: requestURL.path) ? try JSONDecoder().decode(RebaseSquashMessage.self, from: Data(contentsOf: requestURL)) : nil
        let splitURL = directory.appendingPathComponent("turtlegit-split.json")
        let split = active && manager.fileExists(atPath: splitURL.path) ? try JSONDecoder().decode(RebaseSplitState.self, from: Data(contentsOf: splitURL)) : nil
        let storedSession = active ? try? JSONDecoder().decode(RebaseSessionContext.self, from: Data(contentsOf: directory.appendingPathComponent("turtlegit-session.json"))) : nil
        let session = storedSession?.version == 1 ? storedSession : nil
        let referenceUpdates = manager.fileExists(atPath: directory.appendingPathComponent("turtlegit-update-refs").path)
        let lastCommand = (referenceUpdates || projected ? done.filter { $0.split(separator: " ").first.flatMap { RebaseAction(rawValue: String($0)) } != nil } : done).last?.split(separator: " ").first.map(String.init)
        let action: RebaseAction? = mainlineIndex.flatMap{identities[$0].action.flatMap(RebaseAction.init(rawValue:))} ?? (appliedID != nil ? .edit : mergeEdit ? .edit : mergeReplay ? (identities.indices.contains(step-1) ? identities[step-1].action.flatMap(RebaseAction.init(rawValue:)) ?? .pick:.pick) : lastCommand.flatMap(RebaseAction.init(rawValue:)))
        var conflictMessage:RebaseConflictMessage?
        if active,var record=try conflictMessageRecord(directory),record.entryID==stoppedIdentity,record.step==step,
           record.originalHead==line("orig-head"),try failedPickSessionIdentity(directory)==record.sessionIdentity {
            let actualHead=try rebaseRevision("HEAD",cancellation:cancellation)
            if record.prepared {
                if actualHead != record.beforeHead {record.head=actualHead;record.phase = .uncertain;conflictMessage=record}
            } else {
                if actualHead != record.head {record.phase = .uncertain}
                conflictMessage=record
            }
        }
        let editPause = conflictMessage?.phase == .pending || warningID == nil && mainlineID == nil && active && conflicts.isEmpty && (action == .edit || split?.conflictRecovery==true) && (appliedID != nil || mergeEdit || manager.fileExists(atPath: directory.appendingPathComponent("amend").path) || split?.step == step && (split?.conflictRecovery == true && (split?.parts ?? 0) > 0 || split?.conflictRecoveryReturn != nil))
        var pending = request?.step == step && conflicts.isEmpty ? request : nil
        if let noCommit,noCommit.phase == .approval,conflicts.isEmpty {
            let configuration=try JSONDecoder().decode(RebaseMessageConfiguration.self,from:Data(contentsOf:directory.appendingPathComponent("turtlegit-message-editor.json")))
            pending = .init(message:noCommit.message,datePolicy:configuration.datePolicy,latestDate:noCommit.latestDate,step:step,isNewCommit:true)
        }
        let splitCandidate=noCommit?.split ?? split
        var activeSplit = splitCandidate?.step == step && splitCandidate?.entryID == stoppedIdentity ? splitCandidate : nil
        if noCommit != nil,activeSplit?.isNewCommit==true {
            // The Commit child owns Stage/Unstage and captures the resulting
            // selected index itself. Fence immutable replay/group bytes here,
            // rather than rejecting legitimate edits made inside that child.
            var witnesses=try actionEditFiles(directory)
            if let labels=try structuralNoCommitLabels(directory) {witnesses["structural-labels"] = .init(bytes:labels)}
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            activeSplit?.noCommitWitness=try encoder.encode(witnesses)
        }
        let mergeResult = active && (structural || adopted?.structural == true || projected && currentMerge) && (editPause || pending != nil) ? try rebaseCommit("HEAD", cancellation: cancellation).parents.count > 1 : false
        try cancellation?.check()
        let displayedMessage:String
        if let noCommit {displayedMessage=noCommit.message}
        else if warningID != nil || mainlineID != nil {displayedMessage=try rebaseCommit(originalStopped,cancellation:cancellation).message}
        else if mergeEdit || appliedID != nil || activeSplit?.conflictRecovery == true || activeSplit?.conflictRecoveryReturn != nil {displayedMessage=try rebaseCommit("HEAD",cancellation:cancellation).message}
        else {displayedMessage=try readMessage()}
        var result = RebaseState(active: active, isCherryPick: active && manager.fileExists(atPath: metadataURL.path), branch: line("head-name"), originalHead: line("orig-head"), onto: line("onto"),
                           stoppedEntryID: stoppedIdentity, stoppedCommit: originalStopped, mergeParents: active ? ((try? String(contentsOf:rebasePath("MERGE_HEAD", cancellation: cancellation),encoding:.utf8)) ?? "").split(whereSeparator: \.isWhitespace).map(String.init) : [], message: displayedMessage, currentStep: step,
                           total: projected ? logicalDone.count+logicalTodo.count:referenceUpdates || structural || identities.contains(where:{$0.emptySubject==true || $0.deferredMainline==true || $0.noCommitSquash==true}) ? identities.count : Int(line("end")) ?? Int(line("last")) ?? 0, conflicts: conflicts,
                           remainingCommands: structural || projected ? commands.compactMap { command in
                               let fields = command.split(separator:" ").map(String.init)
                               if fields.first == "pick" || fields.first == "edit" || fields.first == "squash" || fields.first == "drop" { return command }
                               if fields.first == "merge", fields.count >= 3 { return "pick " + fields[2] }
                               return nil
                           } : commands, squashMessage: pending, stoppedAction: action, split: activeSplit,
                           isEditPause: editPause, isStructuralMergeEdit: mergeEdit, hasStructuralMergeResult: mergeResult, needsFileRecovery: noCommit != nil ? noCommit?.phase == .conflicted:structuralResultIndex == nil && conflictMessage == nil && warningID == nil && mainlineID == nil && active && !manager.fileExists(atPath:directory.appendingPathComponent(Self.failedPickIntentName).path) && (!conflicts.isEmpty || !originalStopped.isEmpty && !editPause && pending == nil && activeSplit == nil), session: session)
        if let noCommit {
            guard identities.indices.contains(noCommit.step-1) else{throw RebaseFailure.plan}
            var files=try actionEditFiles(directory)
            files["source-index"] = .init(bytes:try conflictMessageIndex())
            if let labels=try structuralNoCommitLabels(directory) {files["structural-labels"] = .init(bytes:labels)}
            result.noCommitSquash = .init(id:noCommit.id,entryID:identities[noCommit.step-1].id,baseHead:noCommit.baseHead,step:noCommit.step,phase:noCommit.phase == .applying ? .uncertain:noCommit.phase,preservesLeaderAuthor:noCommit.leader != nil,nextRetainedAction:identities.dropFirst(noCommit.step).compactMap {$0.action.flatMap(RebaseAction.init(rawValue:))}.first {$0 != .skip},files:files)
        }
        result.conflictMessage=conflictMessage
        result.hasStructuralResultCheckpoint=structuralResultIndex != nil
        result.structuralResultHead=completedStructural?.head
        if let index=emptyIndex,warningID != nil {
            let identity=identities[index]
            guard let requested=identity.action.flatMap(RebaseAction.init(rawValue:)),requested != .skip,try rebaseCommit(identity.hash,cancellation:cancellation).hasEmptyReplaySubject else {throw RebaseFailure.changed}
            result.emptyMessageWarning=RebaseEmptyMessageWarning(entryID:identity.id,commit:identity.hash,requestedAction:requested,step:index+1,head:try rebaseRevision("HEAD",cancellation:cancellation))
            let original=try rebaseCommit(identity.hash,cancellation:cancellation)
            _ = try reachedMainlineAnchor(directory,entryID:identity.id,sessionIdentity:failedPickSessionIdentity(directory),parents:original.parents,cancellation:cancellation)
        }
        result.hasMainlineCheckpoint=mainlineIndex != nil
        if let index=mainlineIndex {
            let identity=identities[index],original=try rebaseCommit(identity.hash,cancellation:cancellation)
            guard result.isCherryPick,let requested=identity.action.flatMap(RebaseAction.init(rawValue:)),requested != .skip,original.parents.count>1 else {throw RebaseFailure.plan}
            if identity.mainline==nil {
                var pending=read("git-rebase-todo").components(separatedBy:"\n").map {RebaseEditor.canonicalLine($0.trimmingCharacters(in:.whitespaces))}.filter {!$0.isEmpty && !$0.hasPrefix("#")}
                if pending.first.flatMap(RebaseEditor.mainlineID)==identity.id {pending.removeFirst()}
                if pending.first.flatMap(RebaseEditor.sourceSquashID)==identity.id {pending.removeFirst()}
                guard let first=pending.first else{throw RebaseFailure.changed}
                let fields=first.split(separator:" ",maxSplits:2)
                guard fields.count>=2,fields[0]==RebaseAction.skip.rawValue,fields[1].utf8.count>=4,identity.hash.hasPrefix(String(fields[1])) else{throw RebaseFailure.changed}
            }
            let sessionIdentity=try failedPickSessionIdentity(directory)
            let anchor=try reachedMainlineAnchor(directory,entryID:identity.id,sessionIdentity:sessionIdentity,parents:original.parents,cancellation:cancellation)
            guard anchor.entryID==identity.id,anchor.sessionIdentity==sessionIdentity,anchor.parents==original.parents else{throw RebaseFailure.changed}
            result.mainlineCheckpointHead=anchor.head
            if let selected=identity.mainline {
                guard (1...original.parents.count).contains(selected) else{throw RebaseFailure.mainline}
            } else {
                result.mainlineDecision = .init(entryID:identity.id,commit:identity.hash,requestedAction:requested,step:index+1,head:anchor.head,parents:original.parents,sessionIdentity:sessionIdentity,files:try actionEditFiles(directory))
            }
        }
        result.hasFailedPickCleanup = active && manager.fileExists(atPath:directory.appendingPathComponent(Self.failedPickIntentName).path)
        if active,let failure=try cleanCommitFailureRecord(directory),
           try cleanCommitFailureMatches(failure,state:result,directory:directory) {
            if failure.ignored {result.hasIgnoredCleanCommitFailure=true} else {result.cleanCommitFailure=failure}
        }
        return result
    }
    private func replayIdentities(_ directory: URL) -> [RebaseReplayIdentity] {
        var identities=(try? JSONDecoder().decode([RebaseReplayIdentity].self, from: Data(contentsOf: directory.appendingPathComponent("turtlegit-replay-identities.json")))) ?? []
        // Older archives stored hashes/occurrences only. The message editor's
        // complete occurrence-aligned action list includes structural merges
        // that have no pick command, so it precedes the linear command fallback.
        if let config=try? JSONDecoder().decode(RebaseMessageConfiguration.self,from:Data(contentsOf:directory.appendingPathComponent("turtlegit-message-editor.json"))),
           let actions=config.actions,actions.count==identities.count,actions.allSatisfy({RebaseAction(rawValue:$0) != nil}) {
            for index in identities.indices where identities[index].action == nil {identities[index].action=actions[index]}
        }
        return identities
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
        let commits = try revisions.reversed().map { revision in
            let hash=try rebaseRevision(revision,cancellation:cancellation)
            return try singleCommitDetails(revision:hash,cancellation:cancellation).asLogEntry()
        }
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
        let directory=try rebasePath("rebase-merge",cancellation:cancellation)
        let identities = replayIdentities(directory)
        if identities.isEmpty || FileManager.default.fileExists(atPath:directory.appendingPathComponent(Self.adoptedPlanName).path) {
            if let projected=try? adoptionProjection(directory,cancellation:cancellation) {return projected.rows.filter{$0.progress != .completed}}
            try cancellation?.check()
            guard identities.isEmpty else {throw RebaseFailure.plan}
        }
        var result: [RebaseEntry] = []
        func recovered(_ hash: String, action: RebaseAction, position: Int) throws -> RebaseEntry {
            var entry = RebaseEntry(commit: try rebaseCommit(hash, cancellation: cancellation), action: action)
            if identities.indices.contains(position), identities[position].hash == entry.commit.hash {entry.occurrence=identities[position].occurrence;entry.mainline=identities[position].mainline;entry.deferredMainline=identities[position].deferredMainline==true;if identities[position].emptySubject==true || identities[position].deferredMainline==true || identities[position].deferredSquash==true || identities[position].noCommitSquash==true {entry.action=identities[position].action.flatMap(RebaseAction.init(rawValue:)) ?? action}}
            return entry
        }
        if state.emptyMessageWarning==nil,!state.hasMainlineCheckpoint,state.noCommitSquash == nil || state.noCommitSquash?.phase == .approval || state.noCommitSquash?.phase == .committed,!state.stoppedCommit.isEmpty { result.append(try recovered(state.stoppedCommit, action: .edit, position: state.currentStep - 1)) }
        var position = state.currentStep-(state.emptyMessageWarning == nil && !state.hasMainlineCheckpoint && (state.noCommitSquash == nil || state.noCommitSquash?.phase == .approval || state.noCommitSquash?.phase == .committed) ? 0:1)
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
        if identities.isEmpty || FileManager.default.fileExists(atPath:directory.appendingPathComponent(Self.adoptedPlanName).path) {
            if let projected=try? adoptionProjection(directory,cancellation:cancellation) {return projected.rows}
            try cancellation?.check()
            guard identities.isEmpty else {throw RebaseFailure.plan}
            return try remainingRebaseEntries(cancellation:cancellation)
        }
        let skipped = (try? JSONDecoder().decode(Set<Int>.self, from: Data(contentsOf: directory.appendingPathComponent("turtlegit-skipped-steps.json")))) ?? []
        return try identities.enumerated().map { index, identity in
            var entry = RebaseEntry(commit: try rebaseCommit(identity.hash, cancellation: cancellation))
            entry.occurrence = identity.occurrence
            entry.action = identity.action.flatMap(RebaseAction.init(rawValue:)) ?? (commands.indices.contains(index) ? commands[index] : .pick)
            if skipped.contains(index + 1) { entry.action = .skip }
            entry.mainline = identity.mainline;entry.deferredMainline=identity.deferredMainline==true
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
        let recovery=state.active && state.mainlineDecision==nil && identity != nil && (state.needsFileRecovery || state.split?.conflictRecovery == true || identity == previous)
        let head=try run(["rev-parse","--verify","--quiet","HEAD"],successfulExitCodes:0...1,cancellation:cancellation).text.trimmingCharacters(in:.newlines)
        var conflicts:[ConflictEntry]=[],rows:[StatusEntry]=[],statistics:GitPathMap<CommitFile>=[:]
        if recovery {
            conflicts=try self.conflicts(cancellation:cancellation)
            let group=state.stoppedAction == .squash && state.noCommitSquash == nil
            rows=try commitDialogStatus(amendToParent:group,cancellation:cancellation).filter {$0.state != .untracked && $0.state != .ignored}
            statistics=GitPathMap(try workingTreeFiles(amendToParent:group,cancellation:cancellation).map {($0.path,$0)},uniquingKeysWith:{_,last in last})
        }
        let absoluteFlags=recovery ? try finderIndexFlags(cancellation:cancellation):[:]
        let indexFlags=GitPathMap(uniqueKeysWithValues:rows.compactMap { row in
            absoluteFlags[root.path + "/" + row.path].map {(row.path,$0)}
        })
        let remaining=state.active && includeReplay ? try remainingRebaseEntries(cancellation:cancellation):[]
        let replay=state.active && includeReplay ? try rebaseReplayEntries(cancellation:cancellation):[]
        let messageCommit:LogEntry?
        if state.active && !head.isEmpty && (state.isEditPause || state.squashMessage != nil || state.split != nil) {
            if state.isEditPause && state.session?.addCherryPickedFrom == true {messageCommit=try singleCommitDetails(revision:"HEAD",cancellation:cancellation).asLogEntry()}
            else {messageCommit=try rebaseCommit(head,cancellation:cancellation)}
        } else {messageCommit=nil}
        let final=try rebaseState(cancellation:cancellation),finalHead=try run(["rev-parse","--verify","--quiet","HEAD"],successfulExitCodes:0...1,cancellation:cancellation).text.trimmingCharacters(in:.newlines)
        try cancellation?.check()
        guard state.active == final.active,identity == RebaseConflictIdentity(final),state.stoppedAction == final.stoppedAction,
              state.noCommitSquash == final.noCommitSquash,state.hasStructuralResultCheckpoint == final.hasStructuralResultCheckpoint,state.structuralResultHead == final.structuralResultHead,state.mainlineDecision == final.mainlineDecision,state.hasMainlineCheckpoint == final.hasMainlineCheckpoint,state.mainlineCheckpointHead == final.mainlineCheckpointHead,
              state.remainingCommands == final.remainingCommands,state.conflicts.map({GitReferenceName($0)}) == final.conflicts.map({GitReferenceName($0)}),state.message == final.message,
              state.squashMessage?.message == final.squashMessage?.message,state.isEditPause == final.isEditPause,head == finalHead else {throw RebaseFailure.changed}
        return RebaseSessionSnapshot(state:state,identity:recovery ? identity:nil,fileRecovery:recovery,conflicts:conflicts,rows:rows,statistics:statistics,indexFlags:indexFlags,head:head,remaining:remaining,replay:replay,messageCommit:messageCommit)
    }
    public func rebaseTodo(_ plan: RebasePlan) throws -> String {
        try validateRebaseIdentities(plan)
        guard plan.entries.first?.action != .squash else { throw RebaseFailure.squash }
        if plan.options.preserveMerges { return try structuralRebaseTodo(plan) }
        if plan.options.isCherryPick {
            for entry in plan.entries where entry.action != .skip {
                if entry.commit.parents.count > 1 {
                    if let parent=entry.mainline {guard (1...entry.commit.parents.count).contains(parent) else {throw RebaseFailure.mainline}}
                } else if entry.mainline != nil { throw RebaseFailure.mainline }
            }
        }
        if plan.entries.isEmpty { return "noop\n" }
        var entries=plan.entries
        for index in entries.indices {entries[index].deferredMainline=plan.options.isCherryPick && entries[index].commit.parents.count>1 && entries[index].mainline==nil}
        let deferred=RebaseEditor.deferredSquashPositions(entries),orphans=RebaseEditor.orphanSquashPositions(entries)
        return entries.enumerated().flatMap {index,entry in
            RebaseEditor.executionLines(entry,deferSquash:deferred.contains(index),noCommitSquash:orphans.contains(index))
        }.joined(separator:"\n")+"\n"
    }
    /// Source parent rewrite semantics for structural Pick, Skip and Edit plans.
    /// Labels identify already replayed parents; an unreplayed linear parent
    /// falls back to the current head. A missing first merge parent is rejected.
    public func structuralRebaseTodo(_ plan: RebasePlan) throws -> String {
        try validateRebaseIdentities(plan)
        guard plan.entries.first?.action != .squash else { throw RebaseFailure.squash }
        guard plan.options.preserveMerges, plan.entries.allSatisfy({ $0.occurrence == 0 && !($0.action == .squash && $0.commit.parents.count != 1) }) else { throw RebaseFailure.preservePlan }
        let bases = try run(["merge-base","--all",plan.branchHash,plan.ontoHash],successfulExitCodes:0...1).text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !bases.isEmpty else { throw RebaseFailure.preservePlan }
        let selected = Set(plan.entries.map { $0.commit.hash })
        let orphans=RebaseEditor.orphanSquashPositions(plan.entries)
        var rewritten = Dictionary(uniqueKeysWithValues:bases.map { ($0,"turtlegit-onto") })
        var current = "turtlegit-onto", rows = ["label turtlegit-onto"], group: [String] = [], resultGroup:[String]=[]
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
            if entry.requiresEmptyMessageReview {rows.append(RebaseEditor.emptyMessagePrefix+entry.id)}
            if orphans.contains(position) {rows.append(RebaseEditor.sourceSquashPrefix+entry.id)}
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
            } else { rows.append((orphans.contains(position) ? RebaseAction.skip.rawValue:entry.executionAction == .edit && nextIsSquash(after:position) && !entry.requiresEmptyMessageReview ? RebaseAction.pick.rawValue : entry.executionAction.rawValue) + " " + original.hash + " " + original.subject.replacingOccurrences(of:"\n",with:" ").replacingOccurrences(of:"\r",with:" ")) }
            if original.parents.count > 1 && entry.executionAction == .edit && (entry.requiresEmptyMessageReview || !nextIsSquash(after:position)) {rows.append("break")}
            if entry.requiresEmptyMessageReview && entry.action == .squash {rows.append(RebaseEditor.emptyAppliedPrefix+entry.id)}
            group.append(original.hash)
            if original.parents.count>1 && (parents==original.parents || parents.count<=1) {resultGroup.append(entry.id)}
            if !nextIsSquash(after:position) {
                for hash in group { rows.append("label turtlegit-" + hash) }
                // A collapsed/unchanged merge has no sequencer commit command.
                // Record its actual reached result after labels/Edit approval.
                rows += resultGroup.map {RebaseEditor.structuralResultPrefix+$0}
                resultGroup.removeAll()
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
                replay.entries[index].deferredMainline=replay.entries[index].commit.parents.count>1 && replay.entries[index].mainline==nil
                let entry = replay.entries[index]
                // Read immutable objects again rather than trusting caller-supplied parent metadata.
                let original = try rebaseCommit(entry.commit.hash)
                guard original.parents == entry.commit.parents else { throw RebaseFailure.plan }
                if entry.action != .skip,entry.deferredMainline {continue}
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
                replacement.mainline = nil; replacement.occurrence = entry.occurrence;replacement.originalEmptySubject=entry.commit.hasEmptyReplaySubject
                replay.entries[index] = replacement
            }
        }
        let path = temporary.appendingPathComponent("todo")
        // Validate the original plan first; synthetic merge IDs intentionally differ from its selections.
        let structural = plan.options.preserveMerges
        let deferredSquashes=RebaseEditor.deferredSquashPositions(replay.entries),orphans=RebaseEditor.orphanSquashPositions(replay.entries)
        let todo = replay.entries.enumerated().flatMap {index,entry in RebaseEditor.executionLines(entry,deferSquash:deferredSquashes.contains(index),noCommitSquash:orphans.contains(index)).map {line in line.hasPrefix(RebaseEditor.emptyMessagePrefix) ? RebaseEditor.emptyMessagePrefix+plan.entries[index].id:line.hasPrefix(RebaseEditor.emptyAppliedPrefix) ? RebaseEditor.emptyAppliedPrefix+plan.entries[index].id:line.hasPrefix(RebaseEditor.mainlinePrefix) ? RebaseEditor.mainlinePrefix+plan.entries[index].id:line.hasPrefix(RebaseEditor.sourceSquashPrefix) ? RebaseEditor.sourceSquashPrefix+plan.entries[index].id:line}}.joined(separator:"\n")+"\n"
        try Data((structural ? try structuralRebaseTodo(plan) : replay.entries.isEmpty ? "noop\n" : todo).utf8).write(to: path)
        var environment = ["GIT_SEQUENCE_EDITOR": RebaseEditor.command(executable: editorExecutable), "TURTLEGIT_REBASE_PLAN": path.path, "GIT_EDITOR": "/usr/bin/true"]
        if structural { environment["TURTLEGIT_STRUCTURAL_PLAN"] = "1" }
        let earlySession=temporary.appendingPathComponent("session.json")
        try JSONEncoder().encode(RebaseSessionContext(options:plan.options,afterFetch:afterFetch,autoStart:autoStart,fromLog:fromLog)).write(to:earlySession)
        environment["TURTLEGIT_REPLAY_SESSION"]=earlySession.path
        let identityFile = temporary.appendingPathComponent("identities.json")
        try JSONEncoder().encode(plan.entries.enumerated().map { index,entry in RebaseReplayIdentity(hash:entry.commit.hash,occurrence:entry.occurrence,action:entry.action.rawValue,mainline:entry.mainline,deferredMainline:plan.options.isCherryPick && entry.commit.parents.count>1 && entry.mainline==nil,deferredSquash:deferredSquashes.contains(index),noCommitSquash:orphans.contains(index),structuralMerge:structural && entry.commit.parents.count>1,emptySubject:entry.commit.hasEmptyReplaySubject) }).write(to: identityFile)
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
        if let group=try noCommitGroup(rebasePath("rebase-merge")),group.allowsEmpty {return false}
        let base:String
        if let group=state.noCommitSquash {base=group.baseHead}else{base=try commitComparisonBase(amendToParent:true)}
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
        guard actual.noCommitSquash==expected.noCommitSquash,actual.hasStructuralResultCheckpoint==expected.hasStructuralResultCheckpoint,actual.structuralResultHead==expected.structuralResultHead else{throw RebaseFailure.changed}
        let sameSplit = try encoder.encode(actual.split) == encoder.encode(expected.split)
        guard actual.active, expected.active, actual.isCherryPick == expected.isCherryPick,
              actual.mainlineCheckpointHead.map({$0==expectedHead}) ?? true,
              actual.originalHead == expected.originalHead, actual.branch == expected.branch, actual.onto == expected.onto,
              actual.stoppedEntryID == expected.stoppedEntryID, actual.stoppedCommit == expected.stoppedCommit,
              actual.currentStep == expected.currentStep, actual.stoppedAction == expected.stoppedAction,
              actual.emptyMessageWarning == expected.emptyMessageWarning,actual.mainlineDecision == expected.mainlineDecision,actual.hasMainlineCheckpoint == expected.hasMainlineCheckpoint,actual.mainlineCheckpointHead == expected.mainlineCheckpointHead,actual.hasFailedPickCleanup == expected.hasFailedPickCleanup, actual.isEditPause == expected.isEditPause, actual.remainingCommands == expected.remainingCommands,
              actual.cleanCommitFailure == expected.cleanCommitFailure,
              actual.hasIgnoredCleanCommitFailure == expected.hasIgnoredCleanCommitFailure,
              actual.conflictMessage == expected.conflictMessage,
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
    /// Approval is tied to the reached occurrence and unchanged pre-application HEAD.
    public func acknowledgeRebaseEmptyMessage(_ warning: RebaseEmptyMessageWarning, expected: RebaseState, expectedHead: String, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil, onProgress: (@Sendable (RebaseProgress) -> Void)? = nil) throws -> RebaseExecution {
        try withReplayIO(cancellation: cancellation, onOutput:onOutput,onProgress:onProgress) {
            let actual = try rebaseState()
            try requireRebaseContinuation(actual, expected: expected, expectedHead: expectedHead)
            guard actual.emptyMessageWarning == warning, warning.head == expectedHead else { throw RebaseFailure.changed }
            try removePendingEmptyMarker(warning.entryID, applied: false)
            let directory=try rebasePath("rebase-merge")
            if var group=try noCommitGroup(directory) {
                group.reviewedEmpty.append(warning.entryID)
                try withActionEditLock(directory) {try publishNoCommitGroup(group,directory:directory,files:actionEditFiles(directory))}
            }
            return try recoverRebase("--continue")
        }
    }
    /// Accept exactly one reached occurrence. Object preparation changes no
    /// reference/index; the journal makes the selected parent durable before Git
    /// is resumed, including cancellation between acceptance and continuation.
    public func selectRebaseMainline(_ decision:RebaseMainlineDecision,parent:Int,expected:RebaseState,expectedHead:String,cancellation:OperationCancellation?=nil,onOutput:(@Sendable(GitOutputChunk)->Void)?=nil,onProgress:(@Sendable(RebaseProgress)->Void)?=nil) throws -> RebaseExecution {
        try withReplayIO(cancellation:cancellation,onOutput:onOutput,onProgress:onProgress) {
            let actual=try rebaseState(),directory=try rebasePath("rebase-merge")
            try requireRebaseContinuation(actual,expected:expected,expectedHead:expectedHead)
            guard actual.mainlineDecision==decision,decision.head==expectedHead,try failedPickSessionIdentity(directory)==decision.sessionIdentity else{throw RebaseFailure.changed}
            let original=try rebaseCommit(decision.commit)
            guard original.parents==decision.parents,(1...original.parents.count).contains(parent) else{throw RebaseFailure.mainline}
            let temporary=try TurtleGitTemporaryStorage.root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
            defer {try? FileManager.default.removeItem(at:temporary)}
            let object=try run(["cat-file","commit",original.hash]).stdout
            guard let separator=object.range(of:Data([10,10])) else{throw RebaseFailure.plan}
            var message=object.subdata(in:separator.upperBound..<object.count)
            if actual.session?.addCherryPickedFrom==true {
                while message.last==10 {message.removeLast()}
                message.append(Data(("\n\n(cherry picked from commit "+original.hash+")\n").utf8))
            }
            let file=temporary.appendingPathComponent("message");try message.write(to:file)
            let tree=try run(["rev-parse",original.hash+"^{tree}"]).text.trimmingCharacters(in:.newlines)
            let hash=try run(["commit-tree",tree,"-p",original.parents[parent-1],"-F",file.path],environmentOverrides:["GIT_AUTHOR_NAME":original.author,"GIT_AUTHOR_EMAIL":original.email,"GIT_AUTHOR_DATE":original.date]).text.trimmingCharacters(in:.newlines)
            let prepared=try rebaseCommit(hash)
            try cancellation?.check()
            try withActionEditLock(directory) {
                let files=try actionEditFiles(directory)
                guard files==decision.files,try failedPickSessionIdentity(directory)==decision.sessionIdentity,try rebaseRevision("HEAD")==expectedHead else{throw RebaseFailure.changed}
                let normalizedDone = try checkedCheckpointDone(directory, files: files)
                var identities=try JSONDecoder().decode([RebaseReplayIdentity].self,from:files["turtlegit-replay-identities.json"]!.bytes!)
                guard let index=identities.firstIndex(where:{$0.id==decision.entryID}),index+1==decision.step,identities[index].mainline==nil,identities[index].deferredMainline==true else{throw RebaseFailure.changed}
                var todo=String(decoding:files["git-rebase-todo"]!.bytes!,as:UTF8.self).components(separatedBy:"\n")
                if let first=todo.firstIndex(where:{!$0.isEmpty && !$0.hasPrefix("#")}),RebaseEditor.mainlineID(todo[first])==decision.entryID {todo.remove(at:first)}
                let first=todo.firstIndex(where:{!$0.isEmpty && !$0.hasPrefix("#") && RebaseEditor.sourceSquashID($0) != decision.entryID})
                guard let first else{throw RebaseFailure.changed}
                let fields=RebaseEditor.canonicalLine(todo[first]).split(separator:" ",maxSplits:2).map(String.init)
                guard fields.count>=2,fields[0]==RebaseAction.skip.rawValue,original.hash.hasPrefix(fields[1]),fields[1].utf8.count>=4 else{throw RebaseFailure.changed}
                guard let executionAction=identities[index].executionAction,executionAction != RebaseAction.skip.rawValue else{throw RebaseFailure.changed}
                todo[first]=(identities[index].noCommitSquash==true ? RebaseAction.skip.rawValue:executionAction)+" "+hash+" "+fields.dropFirst(2).joined(separator:" ")
                var mapping=try JSONDecoder().decode([String:String].self,from:files["turtlegit-cherry-pick.json"]!.bytes!)
                mapping[hash]=original.hash;identities[index].mainline=parent
                if identities[index].noCommitSquash != true {try restoreDeferredSquashes(after:index,todo:&todo,identities:&identities,mapping:mapping)}
                var after=files
                if let normalizedDone { after["done"] = .init(bytes: Data(normalizedDone.utf8)) }
                after["git-rebase-todo"] = .init(bytes:Data(todo.joined(separator:"\n").utf8))
                after["turtlegit-replay-identities.json"] = .init(bytes:try JSONEncoder().encode(identities))
                after["turtlegit-cherry-pick.json"] = .init(bytes:try JSONEncoder().encode(mapping))
                if let bytes=files["turtlegit-message-editor.json"]?.bytes {
                    var config=try JSONDecoder().decode(RebaseMessageConfiguration.self,from:bytes)
                    if config.messages?.indices.contains(index)==true {config.messages?[index]=prepared.message}
                    after["turtlegit-message-editor.json"] = .init(bytes:try JSONEncoder().encode(config))
                }
                let journal=directory.appendingPathComponent(Self.actionEditJournal)
                try JSONEncoder().encode(RebaseActionEditJournal(version:2,before:files,after:after)).write(to:journal,options:.atomic)
                for name in Self.actionEditNames where name != "git-rebase-todo" {try actionEditWrite(after[name]!,directory:directory,name:name)}
                try actionEditWrite(after["git-rebase-todo"]!,directory:directory,name:"git-rebase-todo")
                try FileManager.default.removeItem(at:journal)
            }
            return try recoverRebase("--continue")
        }
    }
    /// Release only this reached row's dependent ordinary Squash chain. A later
    /// unchosen merge owns its own checkpoint and must keep its placeholders.
    private func restoreDeferredSquashes(after index:Int,todo:inout [String],identities:inout [RebaseReplayIdentity],mapping:[String:String])throws {
        let slots=todo.indices.filter {line in todo[line].split(separator:" ").first.flatMap {RebaseAction(rawValue:String($0))} != nil}
        guard !slots.isEmpty else{throw RebaseFailure.changed}
        for next in identities.indices where next>index {
            let identity=identities[next]
            if identity.action==RebaseAction.skip.rawValue {continue}
            guard identity.action==RebaseAction.squash.rawValue else{break}
            if identity.deferredMainline==true && identity.mainline==nil {break}
            guard identity.deferredSquash==true else{continue}
            let offset=next-index
            guard slots.indices.contains(offset) else{throw RebaseFailure.changed}
            let slot=slots[offset],parts=RebaseEditor.canonicalLine(todo[slot]).split(separator:" ",maxSplits:2).map(String.init)
            guard parts.count>=2,parts[0]==RebaseAction.skip.rawValue,identity.hash.hasPrefix(mapping[parts[1]] ?? parts[1]),let action=identity.executionAction else{throw RebaseFailure.changed}
            todo[slot]=action+" "+parts.dropFirst().joined(separator:" ")
            identities[next].deferredSquash=false
        }
    }
    // Git may reschedule a failed exec according to repository configuration.
    // Remove only our exact leading checkpoint, never arbitrary user commands.
    private func removePendingEmptyMarker(_ id: String, applied: Bool) throws {
        let directory = try rebasePath("rebase-merge")
        try withActionEditLock(directory) {
            let files = try actionEditFiles(directory)
            let normalized = try checkedCheckpointDone(directory, files: files)
            guard let bytes = files["git-rebase-todo"]?.bytes, let text = String(data: bytes, encoding: .utf8) else { throw RebaseFailure.plan }
            var lines = text.components(separatedBy: "\n")
            guard let first = lines.firstIndex(where: { !$0.isEmpty && !$0.hasPrefix("#") }), RebaseEditor.emptyMessageID(RebaseEditor.canonicalLine(lines[first]), applied: applied) == id else { return }
            lines.remove(at: first)
            var after = files
            after["git-rebase-todo"] = .init(bytes: Data(lines.joined(separator: "\n").utf8))
            if let normalized { after["done"] = .init(bytes: Data(normalized.utf8)) }
            let journal = directory.appendingPathComponent(Self.actionEditJournal)
            try JSONEncoder().encode(RebaseActionEditJournal(version: 2, before: files, after: after)).write(to: journal, options: .atomic)
            for name in Self.actionEditNames where name != "git-rebase-todo" { try actionEditWrite(after[name]!, directory: directory, name: name) }
            try actionEditWrite(after["git-rebase-todo"]!, directory: directory, name: "git-rebase-todo")
            try FileManager.default.removeItem(at: journal)
        }
    }
    private static let noCommitSquashName="turtlegit-no-commit-squash.json"
    private func structuralNoCommitLabels(_ directory:URL)throws->Data? {
        guard FileManager.default.fileExists(atPath:directory.appendingPathComponent("turtlegit-structural-plan").path) else{return nil}
        return try run(["for-each-ref","--format=%(refname)%00%(objectname)","refs/rewritten/"]).stdout
    }
    private func validateStructuralNoCommitSkip(_ index:Int,identities:[RebaseReplayIdentity],directory:URL)throws {
        guard FileManager.default.fileExists(atPath:directory.appendingPathComponent("turtlegit-structural-plan").path) else{return}
        let unreplayed=Set(identities.indices.filter {$0==index || identities[$0].action==RebaseAction.skip.rawValue}.map {identities[$0].hash})
        for position in identities.indices where position>index && identities[position].action != RebaseAction.skip.rawValue {
            let commit=try rebaseCommit(identities[position].hash)
            if commit.parents.count>1,let first=commit.parents.first,unreplayed.contains(first) {throw RebaseFailure.preservePlan}
        }
    }
    /// Move only owned skipped-row metadata behind the group's final label.
    /// Its base target is anchored, while the return label is evaluated by Git
    /// after actual approval/restoration, not a stale pre-amend HEAD literal.
    private func structuralNoCommitTodo(_ text:String,cursor:RebaseNoCommitTopology)throws->String {
        guard cursor.controls.count<=200000,(cursor.anchor=="turtlegit-onto" || cursor.anchor.hasPrefix("turtlegit-") && GitLocalReferenceProtocol.validOID(String(cursor.anchor.dropFirst("turtlegit-".count)))),
              cursor.controls.allSatisfy({control in
                  let fields=control.line.split(separator:" ").map(String.init)
                  return GitLocalReferenceProtocol.validOID(control.target) && fields.count==2 &&
                      (fields[0]=="label" && fields[1].hasPrefix("turtlegit-") && GitLocalReferenceProtocol.validOID(String(fields[1].dropFirst("turtlegit-".count))) ||
                       fields[0]=="update-ref" && fields[1].hasPrefix("refs/heads/") && GitLocalReferenceProtocol.validName(fields[1]))
              }) else{throw RebaseFailure.plan}
        var lines=text.components(separatedBy:"\n")
        let block=cursor.controls.flatMap {["reset "+$0.target,$0.line,"reset "+cursor.anchor]}
        if !block.isEmpty,let first=lines.indices.first(where:{index in index+block.count<=lines.count && Array(lines[index..<index+block.count])==block}) {
            lines.removeSubrange(first..<first+block.count)
        } else {
            for control in cursor.controls {
                guard let index=lines.firstIndex(of:control.line) else{throw RebaseFailure.changed}
                lines.remove(at:index)
            }
        }
        guard let anchor=lines.firstIndex(of:"label "+cursor.anchor),lines.filter({$0=="label "+cursor.anchor}).count==1 else{throw RebaseFailure.changed}
        lines.insert(contentsOf:block,at:anchor+1)
        return lines.joined(separator:"\n")
    }
    private func holdStructuralNoCommitControls(_ group:inout RebaseNoCommitGroup,todo:inout [String],identities:[RebaseReplayIdentity],directory:URL)throws {
        guard FileManager.default.fileExists(atPath:directory.appendingPathComponent("turtlegit-structural-plan").path) else{return}
        let prior=group.topology?.controls ?? []
        if let topology=group.topology,!prior.isEmpty {
            let block=prior.flatMap {["reset "+$0.target,$0.line,"reset "+topology.anchor]}
            guard let start=todo.indices.first(where:{$0+block.count<=todo.count && Array(todo[$0..<$0+block.count])==block}) else{throw RebaseFailure.changed}
            todo.removeSubrange(start..<start+block.count)
        }
        var pending:[RebaseNoCommitControl]=[],cursor=0,skipTarget:String?
        while cursor<todo.count {
            let line=RebaseEditor.canonicalLine(todo[cursor]),fields=line.split(separator:" ").map(String.init)
            if line.isEmpty || line.hasPrefix("#") {cursor += 1;continue}
            if fields.count==2,fields[0]=="label",fields[1].hasPrefix("turtlegit-"),
               let identity=identities.first(where:{"turtlegit-"+$0.hash==fields[1]}) {
                if identity.action==RebaseAction.skip.rawValue {
                    skipTarget=group.baseHead;pending.append(.init(line:line,target:group.baseHead));todo.remove(at:cursor)
                } else if group.applied.contains(identity.id) {skipTarget=nil;cursor += 1}
                else {break}
            } else if fields.count==2,fields[0]=="update-ref",fields[1].hasPrefix("refs/heads/"),GitLocalReferenceProtocol.validName(fields[1]) {
                if let target=skipTarget {pending.append(.init(line:line,target:target));todo.remove(at:cursor)}else{cursor += 1}
            } else {break}
        }
        guard !pending.isEmpty || !prior.isEmpty else{return}
        let applied=group.applied.reversed().compactMap {id in identities.first(where:{$0.id==id && $0.action != RebaseAction.skip.rawValue})}.first
        let current=identities[group.step-1].action != RebaseAction.skip.rawValue ? identities[group.step-1]:nil
        let following=identities.dropFirst(group.step).first {$0.action==RebaseAction.squash.rawValue}
        let anchor=(applied ?? current ?? following).map {"turtlegit-"+$0.hash} ?? "turtlegit-onto"
        group.topology = .init(anchor:anchor,controls:prior+pending)
        var text=(prior+pending).map(\.line).joined(separator:"\n")+"\n"+todo.joined(separator:"\n")
        if anchor=="turtlegit-onto",!todo.contains("label "+anchor) {
            // No applied group member survived Skip. All targets are the
            // unchanged destination; the initial onto label already exists.
            let block=(prior+pending).flatMap {["reset "+$0.target,$0.line,"reset "+anchor]}
            todo=block+todo
        } else {
            text=try structuralNoCommitTodo(text,cursor:group.topology!)
            todo=text.components(separatedBy:"\n")
        }
    }
    private func noCommitGroup(_ directory:URL)throws->RebaseNoCommitGroup? {
        guard let bytes=try actionEditFile(directory,Self.noCommitSquashName).bytes else{return nil}
        guard bytes.count<=16_777_216 else{throw RebaseFailure.plan}
        let group=try JSONDecoder().decode(RebaseNoCommitGroup.self,from:bytes)
        let identities=replayIdentities(directory),known=Set(identities.map(\.id))
        guard UUID(uuidString:group.id) != nil,group.session == (try failedPickSessionIdentity(directory)),GitLocalReferenceProtocol.validOID(group.baseHead),group.step>0,identities.indices.contains(group.step-1),
              Set(group.applied).count==group.applied.count,Set(group.prepared).count==group.prepared.count,Set(group.applied).isSubset(of:known),Set(group.prepared).isSubset(of:known),
              (group.readd+group.remove).allSatisfy({RepositoryBrowserListing.validPath($0,allowRoot:false)}) else{throw RebaseFailure.changed}
        if let topology=group.topology {
            guard FileManager.default.fileExists(atPath:directory.appendingPathComponent("turtlegit-structural-plan").path),
                  (topology.anchor=="turtlegit-onto" || identities.contains(where:{"turtlegit-"+$0.hash==topology.anchor})),topology.controls.count<=200000,
                  topology.controls.allSatisfy({control in
                      let fields=control.line.split(separator:" ").map(String.init)
                      return GitLocalReferenceProtocol.validOID(control.target) && fields.count==2 &&
                          (fields[0]=="label" && identities.contains(where:{"turtlegit-"+$0.hash==fields[1] && $0.action==RebaseAction.skip.rawValue}) ||
                           fields[0]=="update-ref" && fields[1].hasPrefix("refs/heads/") && GitLocalReferenceProtocol.validName(fields[1]))
                  }) else{throw RebaseFailure.changed}
        }
        if let split=group.split {
            guard split.noCommitGroupID==group.id,split.entryID==identities[group.step-1].id,split.step==group.step,split.parts>=0,
                  GitLocalReferenceProtocol.validOID(split.expectedHead),split.firstParents==[group.baseHead],split.conflictRecovery != true,split.conflictRecoveryReturn==nil,split.noCommitWitness==nil,
                  split.parts != 0 || split.expectedHead==group.baseHead else{throw RebaseFailure.changed}
        }
        return group
    }
    /// Before changing a legacy reschedule representation, reproduce the whole
    /// owned plan. The local suffix shape alone is never permission to discard
    /// an external edit elsewhere in done/todo.
    private func checkedCheckpointDone(_ directory: URL, files: [String: RebaseActionEditFile]) throws -> String? {
        let done = String(decoding: files["done"]?.bytes ?? Data(), as: UTF8.self)
        let todo = String(decoding: files["git-rebase-todo"]?.bytes ?? Data(), as: UTF8.self)
        guard let receipt = RebaseEditor.ownedCheckpointReschedule(in: directory, done: done, todo: todo) else {
            // A reached owned exec followed by an unverified extra instruction
            // is not a normal newer-Git representation. Do not let an active
            // approval group hide that external edit and commit before refusal.
            let completed = done.components(separatedBy: "\n").filter { !$0.isEmpty }
            if let first = todo.components(separatedBy: "\n").first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
               RebaseEditor.ownedCheckpointLine(RebaseEditor.canonicalLine(first)), completed.count >= 2,
               RebaseEditor.canonicalLine(completed[completed.count - 2]) == RebaseEditor.canonicalLine(first) { throw RebaseFailure.changed }
            return nil
        }
        guard files[Self.adoptedPlanName]?.bytes == nil,
              let encoded = files["turtlegit-replay-identities.json"]?.bytes else { throw RebaseFailure.changed }
        let identities = try JSONDecoder().decode([RebaseReplayIdentity].self, from: encoded)
        let rows = try identities.map { identity -> RebaseEntry in
            guard let action = identity.action.flatMap(RebaseAction.init(rawValue:)) else { throw RebaseFailure.changed }
            var row = RebaseEntry(commit: try rebaseCommit(identity.hash), action: action)
            row.occurrence = identity.occurrence; row.mainline = identity.mainline
            row.deferredMainline = identity.deferredMainline == true; row.originalEmptySubject = identity.emptySubject
            return row
        }
        var pending = todo.components(separatedBy: "\n")
        guard let first = pending.firstIndex(where: { !$0.isEmpty && !$0.hasPrefix("#") }), RebaseEditor.canonicalLine(pending[first]) == receipt.line else { throw RebaseFailure.changed }
        pending.remove(at: first)
        let actual = receipt.done + "\n" + pending.joined(separator: "\n")
        let mapping = try files["turtlegit-cherry-pick.json"]?.bytes.map { try JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        func original(_ hash: String) throws -> String {
            let matches = mapping.keys.filter { $0.hasPrefix(hash) }
            guard matches.count <= 1 else { throw RebaseFailure.changed }
            let value = matches.first.map { mapping[$0]! } ?? hash
            let originals = rows.filter { $0.commit.hash.hasPrefix(value) }.map(\.commit.hash)
            let unique = Set(originals)
            guard unique.count == 1, let resolved = unique.first else { throw RebaseFailure.changed }
            return resolved
        }
        func lines(_ text: String) throws -> [String] {
            try text.components(separatedBy: "\n").compactMap { raw in
                let line = RebaseEditor.canonicalLine(raw)
                if line.isEmpty || line.hasPrefix("#") { return nil }
                var fields = line.split(separator: " ", maxSplits: 2).map(String.init)
                if fields.count >= 2, RebaseAction(rawValue: fields[0]) != nil { fields[1] = try original(fields[1]) }
                else if fields.first == "merge" {
                    fields = line.split(separator: " ").map(String.init)
                    guard fields.count >= 3 else { throw RebaseFailure.changed }
                    fields[2] = try original(fields[2])
                }
                return fields.joined(separator: " ")
            }
        }
        let structural = FileManager.default.fileExists(atPath: directory.appendingPathComponent("turtlegit-structural-plan").path)
        let generated: String
        if structural {
            let state = try rebaseState()
            var options = RebaseOptions(); options.preserveMerges = true
            let plan = RebasePlan(disposition: .ready, options: options, branchHash: state.originalHead, upstreamHash: state.onto, ontoHash: state.onto, branchReference: state.branch, originalCommits: rows.map(\.id), entries: rows)
            var custom = try RebaseEditor.mergeStructuralReferenceUpdates(generated: actual, custom: structuralRebaseTodo(plan)).todo
            let config = try files["turtlegit-message-editor.json"]?.bytes.map { try JSONDecoder().decode(RebaseMessageConfiguration.self, from: $0) }
            let archives = config?.structuralControls ?? []
            for archive in archives { custom = try structuralNoCommitTodo(custom, cursor: archive.cursor) }
            let active = try noCommitGroup(directory)
            if let cursor = active?.topology, !archives.contains(where: { $0.groupID == active?.id }) { custom = try structuralNoCommitTodo(custom, cursor: cursor) }
            if archives.isEmpty, active == nil, let data = state.split?.structuralControlCursor { custom = try structuralNoCommitTodo(custom, cursor: JSONDecoder().decode(RebaseNoCommitTopology.self, from: data)) }
            let completed = Set(receipt.done.components(separatedBy: "\n").compactMap { RebaseEditor.completedStructuralResult($0)?.id })
            generated = custom.components(separatedBy: "\n").filter { line in RebaseEditor.structuralResultID(line).map { !completed.contains($0) } ?? true }.joined(separator: "\n")
        } else {
            let commands = actual.components(separatedBy: "\n").map { RebaseEditor.canonicalLine($0).split(separator: " ", maxSplits: 2).map(String.init) }.filter { $0.count >= 2 && RebaseAction(rawValue: $0[0]) != nil }
            guard commands.count == rows.count else { throw RebaseFailure.changed }
            let deferred = RebaseEditor.deferredSquashPositions(rows), orphans = RebaseEditor.orphanSquashPositions(rows)
            let custom = try rows.indices.flatMap { index -> [String] in
                guard try original(commands[index][1]) == rows[index].commit.hash else { throw RebaseFailure.changed }
                return RebaseEditor.executionLines(rows[index], hash: commands[index][1], subject: commands[index].dropFirst(2).joined(separator: " "), deferSquash: deferred.contains(index), noCommitSquash: orphans.contains(index))
            }.joined(separator: "\n") + "\n"
            let applied = Set((try noCommitGroup(directory))?.applied ?? [])
            let protected = custom.components(separatedBy: "\n").filter { line in RebaseEditor.emptyMessageID(line, applied: true).map { !applied.contains($0) } ?? true }.joined(separator: "\n")
            var positions: [String: Int] = [:]
            for index in commands.indices where positions[commands[index][1]] == nil { positions[commands[index][1]] = index }
            generated = try RebaseEditor.mergeReferenceUpdates(generated: actual, custom: protected, originalPositions: positions).todo
        }
        guard try lines(generated) == lines(actual), files == (try actionEditFiles(directory)) else { throw RebaseFailure.changed }
        return receipt.done
    }
    private func retireOwnedCheckpointReschedule() throws {
        let directory = try rebasePath("rebase-merge")
        guard try actionEditFile(directory, "done").bytes != nil else { return }
        try withActionEditLock(directory) {
            let files = try actionEditFiles(directory)
            guard let normalized = try checkedCheckpointDone(directory, files: files) else { return }
            var todo = String(decoding: files["git-rebase-todo"]?.bytes ?? Data(), as: UTF8.self).components(separatedBy: "\n")
            guard let first = todo.firstIndex(where: { !$0.isEmpty && !$0.hasPrefix("#") }) else { throw RebaseFailure.changed }
            todo.remove(at: first)
            try replayCancellation?.check()
            try publishNoCommitGroup(noCommitGroup(directory), directory: directory, files: files, todo: todo, done: normalized.components(separatedBy: "\n"))
        }
    }
    private func publishNoCommitGroup(_ group:RebaseNoCommitGroup?,directory:URL,files:[String:RebaseActionEditFile],todo:[String]?=nil,done:[String]?=nil,identities:[RebaseReplayIdentity]?=nil,groupBytes:Data?=nil)throws {
        var after=files
        if let normalized = try checkedCheckpointDone(directory, files: files) { after["done"] = .init(bytes: Data(normalized.utf8)) }
        let bytes:Data?
        if let groupBytes {bytes=groupBytes}else{bytes=try group.map {try JSONEncoder().encode($0)}}
        after[Self.noCommitSquashName] = .init(bytes:bytes)
        if let todo {after["git-rebase-todo"] = .init(bytes:Data(todo.joined(separator:"\n").utf8))}
        if let done {
            let text = done.joined(separator:"\n")
            after["done"] = .init(bytes:Data(RebaseEditor.checkpointDone(in:directory,text:text).utf8))
        }
        if let identities {after["turtlegit-replay-identities.json"] = .init(bytes:try JSONEncoder().encode(identities))}
        if let group,let cursor=group.topology,let data=after["turtlegit-message-editor.json"]?.bytes {
            var config=try JSONDecoder().decode(RebaseMessageConfiguration.self,from:data)
            let archive=RebaseStructuralControlArchive(groupID:group.id,cursor:cursor)
            if config.structuralControls?.first(where:{$0.groupID==group.id}) != archive {
                config.structuralControls=(config.structuralControls ?? []).filter {$0.groupID != group.id}+[archive]
                after["turtlegit-message-editor.json"] = .init(bytes:try JSONEncoder().encode(config))
            }
        }
        let journal=directory.appendingPathComponent(Self.actionEditJournal)
        try JSONEncoder().encode(RebaseActionEditJournal(version:2,before:files,after:after)).write(to:journal,options:.atomic)
        for name in Self.actionEditNames where name != "git-rebase-todo" {try actionEditWrite(after[name]!,directory:directory,name:name)}
        try actionEditWrite(after["git-rebase-todo"]!,directory:directory,name:"git-rebase-todo")
        try FileManager.default.removeItem(at:journal)
    }
    private func noCommitGroupExecution(_ output:String="",code:Int32=0)throws->RebaseExecution {
        let state=try rebaseState(),head=try rebaseRevision("HEAD")
        replayProgressObservation?.sample(force:true)
        return .init(output:output,exitCode:code,state:state,witnessedHead:head,witnessedSession:try failedPickSessionIdentity(rebasePath("rebase-merge")))
    }
    private func startNoCommitGroupIfReached()throws->Bool {
        let directory=try rebasePath("rebase-merge")
        if try noCommitGroup(directory) != nil {return true}
        guard let done=try actionEditFile(directory,"done").bytes,let line=RebaseEditor.checkpointDone(in:directory,text:String(decoding:done,as:UTF8.self)).split(separator:"\n").last,
              let id=RebaseEditor.sourceSquashID(String(line)) ?? RebaseEditor.emptyMessageID(String(line)) ?? RebaseEditor.mainlineID(String(line)) else{return false}
        let identities=replayIdentities(directory)
        guard let index=identities.firstIndex(where:{$0.id==id && $0.noCommitSquash==true}) else{return false}
        let original=try rebaseCommit(identities[index].hash)
        let group=RebaseNoCommitGroup(id:UUID().uuidString,session:try failedPickSessionIdentity(directory),baseHead:try rebaseRevision("HEAD"),step:index+1,phase:.waiting,message:"",leader:nil,latestDate:original.date)
        try withActionEditLock(directory) {try publishNoCommitGroup(group,directory:directory,files:actionEditFiles(directory))}
        return true
    }
    /// Runs only owned no-commit rows. Git's sequencer must not see their staged
    /// changes until the user's normal commit succeeds (or the group is skipped).
    private func advanceNoCommitGroup()throws->RebaseExecution {
        let directory=try rebasePath("rebase-merge")
        guard var group=try noCommitGroup(directory) else{throw RebaseFailure.plan}
        if group.phase == .committed {return try finishNoCommitGroup(group)}
        guard try rebaseRevision("HEAD")==group.baseHead else{throw RebaseFailure.changed}
        if group.phase == .applying || group.phase == .uncertain {throw RebaseFailure.noCommitSquashUncertain}
        if group.phase == .conflicted || group.phase == .approval {return try noCommitGroupExecution()}
        var output=""
        while true {
            try replayCancellation?.check()
            var identities=replayIdentities(directory)
            guard identities.indices.contains(group.step-1),identities[group.step-1].action==RebaseAction.squash.rawValue else{throw RebaseFailure.changed}
            let identity=identities[group.step-1]
            if !group.prepared.contains(identity.id) {
                if !group.message.isEmpty {group.message += "\n\n"}
                let original=try rebaseCommit(identity.hash)
                let originalEmpty:Bool
                if let parent=original.parents.first {originalEmpty=try run(["diff","--quiet",parent,original.hash,"--"],successfulExitCodes:0...1).exitCode==0}else{originalEmpty=false}
                if !originalEmpty {group.allowsEmpty=false}else if identity.emptySubject==true {group.allowsEmpty=true}
                group.message += try noCommitSourceMessage(original,directory:directory)
                group.latestDate=original.date;group.prepared.append(identity.id)
                try withActionEditLock(directory) {try publishNoCommitGroup(group,directory:directory,files:actionEditFiles(directory))}
            }
            let currentState=try rebaseState()
            if currentState.emptyMessageWarning != nil || currentState.mainlineDecision != nil {return try noCommitGroupExecution(output)}
            var files=try actionEditFiles(directory)
            var todo=String(decoding:files["git-rebase-todo"]!.bytes ?? Data(),as:UTF8.self).components(separatedBy:"\n")
            var done=String(decoding:files["done"]?.bytes ?? Data(),as:UTF8.self).components(separatedBy:"\n").filter {!$0.isEmpty}
            try holdStructuralNoCommitControls(&group,todo:&todo,identities:identities,directory:directory)
            // Accepted warnings/parent questions have already been validated by
            // their APIs. Move only this row's remaining owned marker to done.
            while let first=todo.firstIndex(where:{!$0.isEmpty && !$0.hasPrefix("#")}) {
                let line=RebaseEditor.canonicalLine(todo[first])
                let pendingEmpty=RebaseEditor.emptyMessageID(line)==identity.id && !group.reviewedEmpty.contains(identity.id)
                let pendingMainline=RebaseEditor.mainlineID(line)==identity.id && identity.mainline==nil
                if pendingEmpty || pendingMainline {
                    // The first owned group row can itself require review. It
                    // has no previously applied row to expose this boundary.
                    // Preparation is durable; the row and index stay unapplied.
                    done.append(todo.remove(at:first))
                    try withActionEditLock(directory) {try publishNoCommitGroup(group,directory:directory,files:files,todo:todo,done:done)}
                    return try noCommitGroupExecution(output)
                }
                if RebaseEditor.sourceSquashID(line)==identity.id || RebaseEditor.emptyMessageID(line)==identity.id && group.reviewedEmpty.contains(identity.id) || RebaseEditor.mainlineID(line)==identity.id && identity.mainline != nil {
                    // rescheduleFailedExec retains the failed owned marker in
                    // done and puts an exact copy back at the start of todo.
                    // Retire that copy without manufacturing a second logical
                    // checkpoint or relaxing the later exact plan comparison.
                    let consumed=todo.remove(at:first)
                    if done.last.map(RebaseEditor.canonicalLine) != line {done.append(consumed)}
                    continue
                }
                break
            }
            if let first=todo.firstIndex(where:{!$0.isEmpty && !$0.hasPrefix("#")}),todo[first].hasPrefix("squash ") {todo[first]="drop "+todo[first].dropFirst(7)}
            if done.last.flatMap(RebaseEditor.sourceSquashID) != identity.id {done.append(RebaseEditor.sourceSquashPrefix+identity.id)}
            guard let slot=todo.firstIndex(where:{!$0.isEmpty && !$0.hasPrefix("#")}) else{throw RebaseFailure.changed}
            let parts=RebaseEditor.canonicalLine(todo[slot]).split(separator:" ",maxSplits:2).map(String.init)
            guard parts.count>=2,parts[0]==RebaseAction.skip.rawValue else{throw RebaseFailure.changed}
            let mapping=try files["turtlegit-cherry-pick.json"]?.bytes.map {try JSONDecoder().decode([String:String].self,from:$0)} ?? [:]
            guard identity.hash.hasPrefix(mapping[parts[1]] ?? parts[1]) else{throw RebaseFailure.changed}
            let original=try rebaseCommit(identity.hash)
            if !group.resolvedCurrent {group.beforeTree=try run(["write-tree"]).text.trimmingCharacters(in:.newlines)}
            group.phase = .applying
            try withActionEditLock(directory) {
                guard files == (try actionEditFiles(directory)),try rebaseRevision("HEAD")==group.baseHead else{throw RebaseFailure.changed}
                try publishNoCommitGroup(group,directory:directory,files:files,todo:todo,done:done)
            }
            do {if !group.resolvedCurrent {output += try run(["cherry-pick","--no-commit",parts[1]]).text}}
            catch let failure as GitFailure {
                group.phase = (try hasWorkingTreeConflicts()) ? .conflicted:.uncertain
                try replayUncancelled {try withActionEditLock(directory) {try publishNoCommitGroup(group,directory:directory,files:actionEditFiles(directory))}}
                return try noCommitGroupExecution(output+failure.message,code:failure.code)
            } catch {
                group.phase = .uncertain
                try? replayUncancelled {try withActionEditLock(directory) {try publishNoCommitGroup(group,directory:directory,files:actionEditFiles(directory))}}
                throw error
            }
            group.phase = .waiting;group.resolvedCurrent=false
            group.applied.append(identity.id)
            files=try actionEditFiles(directory)
            todo=String(decoding:files["git-rebase-todo"]!.bytes ?? Data(),as:UTF8.self).components(separatedBy:"\n")
            done=String(decoding:files["done"]?.bytes ?? Data(),as:UTF8.self).components(separatedBy:"\n").filter {!$0.isEmpty}
            guard let current=todo.firstIndex(where:{!$0.isEmpty && !$0.hasPrefix("#")}),todo[current]==parts.joined(separator:" ") else{throw RebaseFailure.changed}
            done.append(todo.remove(at:current))
            todo.removeAll {RebaseEditor.emptyMessageID($0,applied:true)==identity.id}
            let next=identities.indices.first { $0>=group.step && identities[$0].action != RebaseAction.skip.rawValue }
            let followingSquash=next.map {identities[$0].action==RebaseAction.squash.rawValue} ?? false
            // Empty-subject local Edit pauses even in the middle of a group.
            if !followingSquash || identity.emptySubject==true {
                group.phase = .approval
                try withActionEditLock(directory) {try publishNoCommitGroup(group,directory:directory,files:files,todo:todo,done:done)}
                return try noCommitGroupExecution(output)
            }
            let nextIndex=next!
            // Retire only intervening Skip rows and expose the next warning or
            // parent question without asking Git to process the staged group.
            while let first=todo.firstIndex(where:{!$0.isEmpty && !$0.hasPrefix("#")}) {
                let line=RebaseEditor.canonicalLine(todo[first]),fields=line.split(separator:" ").map(String.init)
                if fields.first==RebaseAction.skip.rawValue,fields.count>=2,
                   let skipped=identities.indices.first(where:{$0>=group.step && $0<nextIndex && identities[$0].action==RebaseAction.skip.rawValue && identities[$0].hash.hasPrefix(fields[1])}) {
                    _ = skipped;done.append(todo.remove(at:first));continue
                }
                if RebaseEditor.emptyMessageID(line)==identities[nextIndex].id || RebaseEditor.mainlineID(line)==identities[nextIndex].id {
                    done.append(todo.remove(at:first));group.step=nextIndex+1
                    if !group.prepared.contains(identities[nextIndex].id) {
                        if !group.message.isEmpty {group.message += "\n\n"}
                        let original=try rebaseCommit(identities[nextIndex].hash)
                        let originalEmpty=try original.parents.first.map {try run(["diff","--quiet",$0,original.hash,"--"],successfulExitCodes:0...1).exitCode==0} ?? false
                        if !originalEmpty {group.allowsEmpty=false}else if identities[nextIndex].emptySubject==true {group.allowsEmpty=true}
                        group.message += try noCommitSourceMessage(original,directory:directory)
                        group.latestDate=original.date;group.prepared.append(identities[nextIndex].id)
                    }
                    identities[nextIndex].noCommitSquash=true
                    try withActionEditLock(directory) {try publishNoCommitGroup(group,directory:directory,files:files,todo:todo,done:done,identities:identities)}
                    return try noCommitGroupExecution(output)
                }
                break
            }
            group.step=nextIndex+1;identities[nextIndex].noCommitSquash=true
            // A formerly normal Squash becomes an owned drop before applying.
            if let first=todo.firstIndex(where:{!$0.isEmpty && !$0.hasPrefix("#")}),todo[first].hasPrefix("squash ") {todo[first]="drop "+todo[first].dropFirst(7)}
            try withActionEditLock(directory) {try publishNoCommitGroup(group,directory:directory,files:files,todo:todo,done:done,identities:identities)}
        }
    }
    private static func sourceSquashMessage(_ original:LogEntry)->String {
        let parts=LogEntry.splitHistoryMessage(original.message)
        var body=parts.body
        while body.last?.isWhitespace==true {body.removeLast()}
        return parts.subject+"\n"+body
    }
    private func noCommitSourceMessage(_ original:LogEntry,directory:URL)throws->String {
        var message=Self.sourceSquashMessage(original)
        let context=try? JSONDecoder().decode(RebaseSessionContext.self,from:Data(contentsOf:directory.appendingPathComponent("turtlegit-session.json")))
        if context?.addCherryPickedFrom==true {message += (original.historyBody.isEmpty ? "\n":"\n\n")+"(cherry picked from commit "+original.hash+")"}
        return message
    }
    private func approveNoCommitGroup(message:String?,emptyChoice:RebaseEmptyChoice?)throws->RebaseExecution {
        let directory=try rebasePath("rebase-merge")
        guard var group=try noCommitGroup(directory),group.phase == .approval,try rebaseRevision("HEAD")==group.baseHead else{throw RebaseFailure.changed}
        let empty=try run(["diff","--cached","--quiet",group.baseHead,"--"],successfulExitCodes:0...1).exitCode==0
        if empty && !group.allowsEmpty {
            guard let emptyChoice else{throw RebaseFailure.emptyResult}
            if emptyChoice == .cancel {return try noCommitGroupExecution()}
            if emptyChoice == .skip {
                group.phase = .committed;group.committedHead=group.baseHead
                try withActionEditLock(directory) {try publishNoCommitGroup(group,directory:directory,files:actionEditFiles(directory))}
                return try finishNoCommitGroup(group)
            }
            group.allowsEmpty=true
        } else if emptyChoice != nil {throw RebaseFailure.changed}
        guard let message,!message.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw RebaseFailure.message}
        group.message=message
        let file=try makeCommitMessageFile(message,appendFinalNewline:false);defer{file.remove()}
        var arguments=["commit","--cleanup=verbatim","-F",file.url.path]+(empty ? ["--allow-empty"]:[])
        var environment:[String:String]=[:]
        if let leader=group.leader {
            environment=["GIT_AUTHOR_NAME":leader.name,"GIT_AUTHOR_EMAIL":leader.email]
            let configuration=try JSONDecoder().decode(RebaseMessageConfiguration.self,from:Data(contentsOf:directory.appendingPathComponent("turtlegit-message-editor.json")))
            let date=configuration.datePolicy == .first ? leader.date:configuration.datePolicy == .latest ? group.latestDate:ISO8601DateFormatter().string(from:Date())
            arguments += ["--date",date]
        }
        group.phase = .applying
        try withActionEditLock(directory) {try publishNoCommitGroup(group,directory:directory,files:actionEditFiles(directory))}
        var output=""
        do {output=try run(arguments,environmentOverrides:environment).text}
        catch {
            let unchanged=(try? rebaseRevision("HEAD"))==group.baseHead
            group.phase=unchanged ? .approval:.uncertain
            try? replayUncancelled {try withActionEditLock(directory) {try publishNoCommitGroup(group,directory:directory,files:actionEditFiles(directory))}}
            if unchanged,let failure=error as? GitFailure {try throwCleanReplayMessageFailure(failure,message:message)}
            throw error
        }
        try clearCleanCommitFailure()
        group.committedHead=try rebaseRevision("HEAD");group.phase = .committed
        try replayUncancelled {try withActionEditLock(directory) {try publishNoCommitGroup(group,directory:directory,files:actionEditFiles(directory))}}
        let result=try finishNoCommitGroup(group)
        return .init(output:output+result.output,exitCode:result.exitCode,state:result.state,witnessedHead:result.witnessedHead,witnessedSession:result.witnessedSession)
    }
    public func continueRebaseNoCommitSquash(paths:some Sequence<String>,expected:RebaseState,expectedHead:String,cancellation:OperationCancellation?=nil,onOutput:(@Sendable(GitOutputChunk)->Void)?=nil,indexPolicy:CommitCheckboxIndexPolicy?=nil,onProgress:(@Sendable(RebaseProgress)->Void)?=nil)throws->RebaseExecution {
        let selected=GitPathSet(paths)
        return try withProtectedReplayIO(cancellation:cancellation,onOutput:onOutput,onProgress:onProgress) {
            let state=try rebaseState();try requireRebaseContinuation(state,expected:expected,expectedHead:expectedHead)
            let directory=try rebasePath("rebase-merge")
            guard var group=try noCommitGroup(directory),group.phase == .conflicted,group.baseHead==expectedHead else{throw RebaseFailure.changed}
            let changes=try status()
            guard selected.allSatisfy({path in changes.contains(where:{GitReferenceName.equal($0.path,path) && $0.state != .ignored && $0.state != .untracked})}) else{throw RebaseFailure.plan}
            // Stage resolution only. An unchecked unresolved path remains a
            // conflict and keeps this exact no-commit row pending.
            if !selected.isEmpty {_ = try run(["add","--all","--pathspec-from-file=-","--pathspec-file-nul"],input:literalPathPacket(selected.sorted()))}
            guard !(try hasWorkingTreeConflicts()) else{throw RebaseFailure.plan}
            if let indexPolicy {
                let restoration=try prepareCLICommitIndex(changes:status(),checked:selected,policy:indexPolicy,base:expectedHead,cancellation:nil,onOutput:replayOutput)
                group.readd=restoration.readd.sorted();group.remove=restoration.remove.sorted();group.readdUnchecked=indexPolicy.readdUnchecked
            }
            if FileManager.default.fileExists(atPath:try rebasePath("CHERRY_PICK_HEAD").path) {_ = try run(["cherry-pick","--quit"])}
            group.phase = .waiting;group.resolvedCurrent=true
            try withActionEditLock(directory) {try publishNoCommitGroup(group,directory:directory,files:actionEditFiles(directory))}
            return try advanceNoCommitGroup()
        }
    }
    private func finishNoCommitGroup(_ saved:RebaseNoCommitGroup)throws->RebaseExecution {
        var group=saved
        guard let head=group.committedHead else{throw RebaseFailure.changed}
        let directory=try rebasePath("rebase-merge"),identities=replayIdentities(directory)
        let currentHead=try rebaseRevision("HEAD")
        if FileManager.default.fileExists(atPath:directory.appendingPathComponent("turtlegit-structural-plan").path) {
            let files=try actionEditFiles(directory)
            var todo=String(decoding:files["git-rebase-todo"]!.bytes ?? Data(),as:UTF8.self).components(separatedBy:"\n")
            let before=todo,oldTopology=group.topology
            try holdStructuralNoCommitControls(&group,todo:&todo,identities:identities,directory:directory)
            if todo != before || group.topology != oldTopology {
                try withActionEditLock(directory) {try publishNoCommitGroup(group,directory:directory,files:files,todo:todo)}
            }
        }
        let next=identities.indices.first {$0>=group.step && identities[$0].action != RebaseAction.skip.rawValue}
        if let next,identities[next].action==RebaseAction.squash.rawValue {
            guard currentHead==head || currentHead==group.baseHead else{throw RebaseFailure.changed}
            let approved=try rebaseCommit(head)
            let nextBase:String
            if let split=group.split,split.isNewCommit,split.parts>0 {
                guard split.expectedHead==head,approved.parents.count==1 else{throw RebaseFailure.changed}
                nextBase=approved.parents[0]
            } else {
                guard approved.parents.first==group.baseHead || head==group.baseHead else{throw RebaseFailure.changed}
                nextBase=group.baseHead
            }
            if currentHead==head,head != nextBase {_ = try run(["reset","--soft",nextBase,"--"])}
            group.baseHead=nextBase;group.split=nil
            group.leader = .init(message:group.message,name:approved.author,email:approved.email,date:approved.date)
            group.latestDate=approved.date;group.step=next+1;group.phase = .waiting;group.committedHead=nil
            var updated=identities;updated[next].noCommitSquash=true
            try withActionEditLock(directory) {
                let files=try actionEditFiles(directory)
                var todo=String(decoding:files["git-rebase-todo"]!.bytes ?? Data(),as:UTF8.self).components(separatedBy:"\n")
                // Approval consumes only the post-entry pause for rows whose
                // no-commit patch was actually applied in this owned group.
                let applied=Set(group.applied)
                todo.removeAll {line in RebaseEditor.emptyMessageID(line,applied:true).map {applied.contains($0)} ?? false}
                if let first=todo.firstIndex(where:{!$0.isEmpty && !$0.hasPrefix("#")}),todo[first].hasPrefix("squash ") {todo[first]="drop "+todo[first].dropFirst(7)}
                try publishNoCommitGroup(group,directory:directory,files:files,todo:todo,identities:updated)
            }
            return try advanceNoCommitGroup()
        }
        guard currentHead==head else{throw RebaseFailure.changed}
        // Git's own rewrite/notes consumers need the final result even though
        // their physical commands were deliberately nonapplying drops.
        let rewrite=directory.appendingPathComponent("rewritten-list")
        var rewritten=try actionEditFile(directory,"rewritten-list").bytes ?? Data()
        guard rewritten.count<=16_777_216 else{throw RebaseFailure.plan}
        for id in group.applied {
            guard let identity=identities.first(where:{$0.id==id}) else{throw RebaseFailure.changed}
            let line=Data((identity.hash+" "+head+"\n").utf8)
            if rewritten.range(of:line)==nil {rewritten.append(line)}
        }
        try rewritten.write(to:rewrite,options:.atomic)
        if group.readdUnchecked {
            if !group.readd.isEmpty {_ = try run(["add","--ignore-errors","-f","--pathspec-from-file=-","--pathspec-file-nul"],input:literalPathPacket(group.readd))}
            if !group.remove.isEmpty {_ = try run(["rm","--cached","--ignore-unmatch","--pathspec-from-file=-","--pathspec-file-nul"],input:literalPathPacket(group.remove))}
        }
        if !(try replayWorktreeIsClean()) {
            let commit=try rebaseCommit(head)
            var selection=RebaseSplitState(entryID:identities[group.step-1].id,step:group.step,expectedHead:head,parts:1,firstAuthor:commit.author+" <"+commit.email+">",firstDate:commit.date,squashDate:nil)
            selection.conflictRecovery=true;selection.firstParents=commit.parents
            selection.structuralControlCursor=try group.topology.map {try JSONEncoder().encode($0)}
            try JSONEncoder().encode(selection).write(to:directory.appendingPathComponent("turtlegit-split.json"),options:.atomic)
            try Data((identities[group.step-1].hash+"\n").utf8).write(to:directory.appendingPathComponent("stopped-sha"),options:.atomic)
            try withActionEditLock(directory) {
                let files=try actionEditFiles(directory)
                var todo=String(decoding:files["git-rebase-todo"]!.bytes ?? Data(),as:UTF8.self).components(separatedBy:"\n")
                let applied=Set(group.applied)
                todo.removeAll {line in RebaseEditor.emptyMessageID(line,applied:true).map {applied.contains($0)} ?? false}
                try publishNoCommitGroup(nil,directory:directory,files:files,todo:todo)
            }
            return try noCommitGroupExecution()
        }
        try withActionEditLock(directory) {
            let files=try actionEditFiles(directory)
            var todo=String(decoding:files["git-rebase-todo"]!.bytes ?? Data(),as:UTF8.self).components(separatedBy:"\n")
            let applied=Set(group.applied)
            todo.removeAll {line in RebaseEditor.emptyMessageID(line,applied:true).map {applied.contains($0)} ?? false}
            try publishNoCommitGroup(nil,directory:directory,files:files,todo:todo)
        }
        return try recoverRebase("--continue")
    }
    private func continueRebaseOwned(editorExecutable: URL? = nil, squashMessage: String? = nil, editMessage: String? = nil, emptySquashChoice: RebaseEmptyChoice? = nil, expectedSquashHead: String? = nil, expectedSquashState: RebaseState? = nil, expectedReplayState: RebaseState? = nil, expectedReplayHead: String? = nil) throws -> RebaseExecution {
        let state = try rebaseState()
        if let expectedReplayState {
            guard let expectedReplayHead else { throw RebaseFailure.changed }
            try requireRebaseContinuation(state, expected: expectedReplayState, expectedHead: expectedReplayHead)
        }
        guard state.active else { throw RebaseFailure.inactive }
        guard state.emptyMessageWarning == nil else { throw RebaseFailure.message }
        guard state.mainlineDecision == nil else {throw RebaseFailure.mainline}
        try retireOwnedCheckpointReschedule()
        if state.hasStructuralResultCheckpoint {
            if let head=state.structuralResultHead {guard try rebaseRevision("HEAD")==head else{throw RebaseFailure.changed}}
            else {guard try recordStructuralResultIfReached() else{throw RebaseFailure.changed}}
            return try recoverRebase("--continue")
        }
        if let phase=state.noCommitSquash {
            if let failure=state.cleanCommitFailure {throw failure}
            if phase.phase == .uncertain {throw RebaseFailure.noCommitSquashUncertain}
            if phase.phase == .approval,let split=state.split,split.isNewCommit {
                guard split.parts>0,try rebaseRevision("HEAD")==split.expectedHead,!(try rebaseSplitHasRemainingChangesOwned()),
                      var group=try noCommitGroup(rebasePath("rebase-merge")),group.split==split.stored else{throw RebaseFailure.plan}
                group.phase = .committed;group.committedHead=split.expectedHead
                let directory=try rebasePath("rebase-merge")
                try withActionEditLock(directory) {try publishNoCommitGroup(group,directory:directory,files:actionEditFiles(directory))}
                return try finishNoCommitGroup(group)
            }
            if phase.phase == .approval {return try approveNoCommitGroup(message:squashMessage,emptyChoice:emptySquashChoice)}
            if phase.phase == .conflicted {throw RebaseFailure.plan}
            if state.mainlineDecision == nil {return try advanceNoCommitGroup()}
        }
        if state.hasMainlineCheckpoint {
            guard state.mainlineCheckpointHead == (try rebaseRevision("HEAD")) else{throw RebaseFailure.changed}
            return try recoverRebase("--continue")
        }
        if let ignored=try cleanCommitFailureRecord(rebasePath("rebase-merge")),ignored.ignored,
           state.stoppedEntryID==ignored.identity.entry,state.currentStep==ignored.identity.step {
            guard try cleanCommitFailureMatches(ignored,state:state,directory:rebasePath("rebase-merge")) else{throw RebaseFailure.changed}
            guard try replayWorktreeIsClean() else{throw RebaseFailure.changed}
            return try recoverRebase("--continue")
        }
        if let failure=state.cleanCommitFailure {throw failure}
        if state.conflictMessage != nil {
            return try completeRebaseConflictMessageOwned(amendMessage:editMessage,expected:state,expectedHead:rebaseRevision("HEAD"),editorExecutable:editorExecutable,rawMessage:nil)
        }
        // Arm future adopted rows before attempting the message commit, so its
        // saved failure receipt includes those commands. Accepted Ignore never
        // needs to mutate the future plan after publishing its completion.
        if let editorExecutable {try protectAdoptedEmptyEntries(editorExecutable:editorExecutable)}
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
            try finishReplayMessage(state:state,message:editMessage)
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
            // Source captures HEAD's first author for every squash date policy.
            // Read at approval, where the metadata is actually consumed, rather
            // than persisting an unused copy when the preceding Edit pauses.
            guard case .commit(let firstMetadata)=try singleCommitDetails(revision:"HEAD") else {throw GitSingleCommitFailure.notCommit}
            guard try rebaseRevision("HEAD")==firstMetadata.objectID else {throw RebaseFailure.changed}
            let messageFile = try makeCommitMessageFile(squashMessage, appendFinalNewline: false); defer { messageFile.remove() }
            pending.message = squashMessage
            let request = try rebasePath("rebase-merge/turtlegit-squash-message.json")
            try JSONEncoder().encode(pending).write(to: request, options: .atomic)
            let date: String
            switch pending.datePolicy {
            case .first: date = firstMetadata.author.date
            case .latest: date = pending.latestDate
            case .current: date = ISO8601DateFormatter().string(from: Date())
            }
            // Git's amend already retains raw author bytes. Replacing a legacy
            // encoded signature with UTF-8 environment text would corrupt its
            // identity under the original commit encoding. The selected receipt
            // decides when the Unicode author can be supplied losslessly.
            let author=firstMetadata.author
            let authorEnvironment=Data(author.name.utf8)==author.nameBytes && Data(author.email.utf8)==author.emailBytes
                ? ["GIT_AUTHOR_NAME":author.name,"GIT_AUTHOR_EMAIL":author.email]:[:]
            output = try commitReplayMessage(["commit", "--amend", "--cleanup=verbatim", "-F", messageFile.url.path, "--date", date] + (empty ? ["--allow-empty"] : []),message:squashMessage,environment:authorEnvironment)
            try finishReplayMessage(state:state,message:squashMessage)
        }
        let result = try recoverRebase("--continue")
        return RebaseExecution(output: output + result.output, exitCode: result.exitCode, state: result.state,witnessedHead:result.witnessedHead,witnessedSession:result.witnessedSession)
    }
    private func skipNoCommitGroup()throws->RebaseExecution {
        let directory=try rebasePath("rebase-merge")
        guard var group=try noCommitGroup(directory),group.phase != .applying,group.phase != .uncertain,group.phase != .committed else{throw RebaseFailure.noCommitSquashUncertain}
        if let split=group.split,split.parts>0 {
            guard group.phase == .approval,try rebaseRevision("HEAD")==split.expectedHead,try replayWorktreeIsClean() else{throw RebaseFailure.plan}
            group.phase = .committed;group.committedHead=split.expectedHead
            try withActionEditLock(directory) {try publishNoCommitGroup(group,directory:directory,files:actionEditFiles(directory))}
            return try finishNoCommitGroup(group)
        }
        guard try rebaseRevision("HEAD")==group.baseHead else{throw RebaseFailure.changed}
        group.split=nil
        var identities=replayIdentities(directory)
        guard identities.indices.contains(group.step-1) else{throw RebaseFailure.changed}
        let index=group.step-1,id=identities[index].id
        try validateStructuralNoCommitSkip(index,identities:identities,directory:directory)
        if (group.phase == .conflicted || group.phase == .approval),let tree=group.beforeTree {
            _ = try run(["read-tree","--reset","-u",tree])
            if FileManager.default.fileExists(atPath:try rebasePath("CHERRY_PICK_HEAD").path) {_ = try run(["cherry-pick","--quit"])}
        }
        identities[index].action=RebaseAction.skip.rawValue
        group.applied.removeAll {$0==id}
        let files=try actionEditFiles(directory)
        var todo=String(decoding:files["git-rebase-todo"]!.bytes ?? Data(),as:UTF8.self).components(separatedBy:"\n")
        var done=String(decoding:files["done"]?.bytes ?? Data(),as:UTF8.self).components(separatedBy:"\n").filter {!$0.isEmpty}
        if group.phase != .approval {
            while let first=todo.firstIndex(where:{!$0.isEmpty && !$0.hasPrefix("#")}) {
                let line=RebaseEditor.canonicalLine(todo[first])
                if RebaseEditor.emptyMessageID(line)==id || RebaseEditor.mainlineID(line)==id || RebaseEditor.sourceSquashID(line)==id {todo.remove(at:first);continue}
                let parts=line.split(separator:" ",maxSplits:2)
                guard parts.count>=2,parts[0]==RebaseAction.skip.rawValue else{throw RebaseFailure.changed}
                done.append(todo.remove(at:first));break
            }
        }
        done.removeAll {RebaseEditor.emptyMessageID($0)==id || RebaseEditor.mainlineID($0)==id || RebaseEditor.sourceSquashID($0)==id}
        todo.removeAll {RebaseEditor.emptyMessageID($0,applied:true)==id}
        try holdStructuralNoCommitControls(&group,todo:&todo,identities:identities,directory:directory)
        let next=identities.indices.first {$0>index && identities[$0].action != RebaseAction.skip.rawValue}
        if let next,identities[next].action==RebaseAction.squash.rawValue {
            for position in (index+1)..<next {
                guard identities[position].action==RebaseAction.skip.rawValue,let first=todo.firstIndex(where:{!$0.isEmpty && !$0.hasPrefix("#")}),todo[first].hasPrefix("drop ") else{throw RebaseFailure.changed}
                done.append(todo.remove(at:first))
            }
            group.step=next+1;group.phase = .waiting;group.resolvedCurrent=false
            identities[next].noCommitSquash=true
            if let first=todo.firstIndex(where:{!$0.isEmpty && !$0.hasPrefix("#")}),todo[first].hasPrefix("squash ") {todo[first]="drop "+todo[first].dropFirst(7)}
            try withActionEditLock(directory) {try publishNoCommitGroup(group,directory:directory,files:files,todo:todo,done:done,identities:identities)}
            return try advanceNoCommitGroup()
        }
        if try run(["diff","--cached","--quiet",group.baseHead,"--"],successfulExitCodes:0...1).exitCode != 0 {
            group.phase = .approval
            if let last=group.applied.last,let previous=identities.firstIndex(where:{$0.id==last}) {group.step=previous+1}
            try withActionEditLock(directory) {try publishNoCommitGroup(group,directory:directory,files:files,todo:todo,done:done,identities:identities)}
            return try noCommitGroupExecution()
        }
        try withActionEditLock(directory) {try publishNoCommitGroup(nil,directory:directory,files:files,todo:todo,done:done,identities:identities)}
        return try recoverRebase("--continue")
    }
    private func skipStructuralLeadingWarning(_ warning:RebaseEmptyMessageWarning,index:Int,identities original:[RebaseReplayIdentity],files:[String:RebaseActionEditFile],state:RebaseState,directory:URL)throws->Bool {
        guard FileManager.default.fileExists(atPath:directory.appendingPathComponent("turtlegit-structural-plan").path),
              original.prefix(index).allSatisfy({$0.action==RebaseAction.skip.rawValue}),
              let next=original.indices.first(where:{$0>index && original[$0].action != RebaseAction.skip.rawValue}),original[next].action==RebaseAction.squash.rawValue else{return false}
        var identities=original;identities[index].action=RebaseAction.skip.rawValue
        let rows=try identities.map {identity -> RebaseEntry in
            var row=RebaseEntry(commit:try rebaseCommit(identity.hash));row.occurrence=identity.occurrence
            guard let action=identity.action.flatMap(RebaseAction.init(rawValue:)) else{throw RebaseFailure.plan}
            row.action=action;return row
        }
        let orphans=RebaseEditor.orphanSquashPositions(rows)
        for position in identities.indices {identities[position].noCommitSquash=orphans.contains(position);identities[position].structuralMerge=rows[position].commit.parents.count>1}
        var options=RebaseOptions();options.preserveMerges=true
        let plan=RebasePlan(disposition:.ready,options:options,branchHash:state.originalHead,upstreamHash:state.onto,ontoHash:state.onto,branchReference:state.branch,originalCommits:rows.map(\.id),entries:rows)
        let oldDone=String(decoding:files["done"]?.bytes ?? Data(),as:UTF8.self),oldTodo=String(decoding:files["git-rebase-todo"]?.bytes ?? Data(),as:UTF8.self)
        let custom=try RebaseEditor.mergeStructuralReferenceUpdates(generated:oldDone+"\n"+oldTodo,custom:structuralRebaseTodo(plan)).todo
        let done=oldDone.components(separatedBy:"\n").filter {line in
            !line.isEmpty && RebaseEditor.emptyMessageID(line) != warning.entryID && RebaseEditor.mainlineID(line) != warning.entryID
        }
        let full=custom.components(separatedBy:"\n").filter {!$0.isEmpty}
        guard full.count>=done.count,zip(done,full).allSatisfy({RebaseEditor.canonicalLine($0.0)==RebaseEditor.canonicalLine($0.1)}) else{throw RebaseFailure.changed}
        var todo=Array(full.dropFirst(done.count));todo.append("")
        let anchor=try reachedMainlineAnchor(directory,entryID:warning.entryID,sessionIdentity:failedPickSessionIdentity(directory),parents:rows[index].commit.parents,cancellation:replayCancellation)
        var group=RebaseNoCommitGroup(id:UUID().uuidString,session:try failedPickSessionIdentity(directory),baseHead:warning.head,step:next+1,phase:.waiting,message:anchor.squashLeader?.message ?? "",leader:anchor.squashLeader,latestDate:rows[next].commit.date)
        group.allowsEmpty=anchor.squashCurrentEmpty ?? false
        try holdStructuralNoCommitControls(&group,todo:&todo,identities:identities,directory:directory)
        var owned=files
        if let bytes=files["turtlegit-message-editor.json"]?.bytes {
            var config=try JSONDecoder().decode(RebaseMessageConfiguration.self,from:bytes);config.actions?[index]=RebaseAction.skip.rawValue
            if let cursor=group.topology {config.structuralControls=(config.structuralControls ?? [])+[.init(groupID:group.id,cursor:cursor)]}
            owned["turtlegit-message-editor.json"] = .init(bytes:try JSONEncoder().encode(config))
        }
        // Preserve the true before image for crash recovery, including config.
        var after=owned
        after[Self.noCommitSquashName] = .init(bytes:try JSONEncoder().encode(group))
        after["done"] = .init(bytes:Data((done.joined(separator:"\n")+"\n").utf8))
        after["git-rebase-todo"] = .init(bytes:Data(todo.joined(separator:"\n").utf8))
        after["turtlegit-replay-identities.json"] = .init(bytes:try JSONEncoder().encode(identities))
        let journal=directory.appendingPathComponent(Self.actionEditJournal)
        try JSONEncoder().encode(RebaseActionEditJournal(version:2,before:files,after:after)).write(to:journal,options:.atomic)
        for name in Self.actionEditNames where name != "git-rebase-todo" {try actionEditWrite(after[name]!,directory:directory,name:name)}
        try actionEditWrite(after["git-rebase-todo"]!,directory:directory,name:"git-rebase-todo")
        try FileManager.default.removeItem(at:journal)
        return true
    }
    private func skipRebaseOwned(bookkeepingStep: Int? = nil) throws -> RebaseExecution {
        let before = try rebaseState()
        guard before.active else { throw RebaseFailure.inactive }
        guard !before.hasStructuralResultCheckpoint else{throw RebaseFailure.changed}
        if before.noCommitSquash != nil {
            guard before.cleanCommitFailure == nil,!before.hasIgnoredCleanCommitFailure else{throw RebaseFailure.changed}
            return try withProtectedReplayIO(cancellation:replayCancellation,onOutput:replayOutput) {try skipNoCommitGroup()}
        }
        guard before.conflictMessage == nil,before.cleanCommitFailure == nil,!before.hasIgnoredCleanCommitFailure else{throw RebaseFailure.changed}
        if before.hasMainlineCheckpoint {guard before.mainlineCheckpointHead == (try rebaseRevision("HEAD")) else{throw RebaseFailure.changed}}
        let checkpoint:RebaseEmptyMessageWarning?
        if let warning=before.emptyMessageWarning {checkpoint=warning}
        else if before.hasMainlineCheckpoint {checkpoint=RebaseEmptyMessageWarning(entryID:before.stoppedEntryID,commit:before.stoppedCommit,requestedAction:before.stoppedAction ?? .pick,step:before.currentStep,head:try rebaseRevision("HEAD"))}
        else {checkpoint=nil}
        if let warning = checkpoint {
            let directory = try rebasePath("rebase-merge")
            try withActionEditLock(directory) {
                let files = try actionEditFiles(directory)
                var identities = try JSONDecoder().decode([RebaseReplayIdentity].self, from: files["turtlegit-replay-identities.json"]!.bytes!)
                guard let index = identities.firstIndex(where: { $0.id == warning.entryID }) else { throw RebaseFailure.changed }
                try validateStructuralNoCommitSkip(index,identities:identities,directory:directory)
                if try skipStructuralLeadingWarning(warning,index:index,identities:identities,files:files,state:before,directory:directory) {return}
                var todo = String(decoding: files["git-rebase-todo"]!.bytes!, as: UTF8.self).components(separatedBy: "\n")
                if let first = todo.firstIndex(where: { !$0.isEmpty && !$0.hasPrefix("#") }), RebaseEditor.emptyMessageID(todo[first]) == warning.entryID || RebaseEditor.mainlineID(todo[first]) == warning.entryID { todo.remove(at: first) }
                todo.removeAll {RebaseEditor.mainlineID($0)==warning.entryID}
                let firstReplay=todo.first {line in
                    let fields=RebaseEditor.canonicalLine(line).split(separator:" ").map(String.init)
                    return fields.first.flatMap(RebaseAction.init(rawValue:)) != nil || fields.first=="merge"
                }.map {RebaseEditor.canonicalLine($0).split(separator:" ").map(String.init)}
                let hasCurrentCommand=firstReplay.map {fields in
                    fields.count>=2 && fields[0] != "merge" && warning.commit.hasPrefix(fields[1]) || fields.count>=3 && fields[0]=="merge" && warning.commit.hasPrefix(fields[2])
                } ?? false
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent("turtlegit-structural-plan").path),!hasCurrentCommand,
                   let boundary = todo.firstIndex(of: "label turtlegit-" + warning.commit) {
                    // The structural row can be reset-only when all parents
                    // retain their original identities. Its owned label is the
                    // boundary; never scan into a later logical replay row.
                    guard todo[..<boundary].allSatisfy({ line in
                        line.isEmpty || line.hasPrefix("#") || line.hasPrefix("reset ") || line == "break" ||
                        RebaseEditor.ownedEmptyLine(line) || line.hasPrefix("merge -C " + warning.commit + " ") ||
                        ["pick ","edit ","squash "].contains(where: { line.hasPrefix($0 + warning.commit + " ") })
                    }) else { throw RebaseFailure.changed }
                    todo.replaceSubrange(0..<boundary, with: ["drop " + warning.commit])
                }
                guard let first = todo.firstIndex(where: { line in
                    let command = line.split(separator: " ").first.map(String.init) ?? ""
                    return RebaseAction(rawValue: command) != nil || command == "merge"
                }) else { throw RebaseFailure.changed }
                let fields = todo[first].split(separator: " ", maxSplits: 3)
                guard fields.count >= 2 else { throw RebaseFailure.changed }
                for position in 0..<first where !todo[position].isEmpty && !todo[position].hasPrefix("#") {
                    guard todo[position].hasPrefix("reset ") else { throw RebaseFailure.changed }
                    todo[position] = ""
                }
                todo[first] = "drop " + warning.commit
                if todo.indices.contains(first+1), todo[first+1] == "break" { todo[first+1] = "" }
                todo.removeAll { RebaseEditor.emptyMessageID($0, applied: true) == warning.entryID }
                var done = String(decoding: files["done"]?.bytes ?? Data(), as: UTF8.self).components(separatedBy: "\n")
                guard let last = done.lastIndex(where: { !$0.isEmpty }), RebaseEditor.emptyMessageID(done[last]) == warning.entryID || RebaseEditor.mainlineID(done[last]) == warning.entryID else { throw RebaseFailure.changed }
                done.remove(at: last)
                // An empty-subject review can have preceded this occurrence's
                // parent checkpoint. Retire both owned pre-entry markers when
                // Skip consumes the row; neither may become a new stopped row.
                done.removeAll {RebaseEditor.emptyMessageID($0)==warning.entryID || RebaseEditor.mainlineID($0)==warning.entryID}
                identities[index].action = RebaseAction.skip.rawValue
                let mapping=try files["turtlegit-cherry-pick.json"]?.bytes.map {try JSONDecoder().decode([String:String].self,from:$0)} ?? [:]
                var orphanIndices=Set<Int>(),hasLeader=false
                for position in identities.indices {
                    let requested=identities[position].action
                    if requested==RebaseAction.skip.rawValue {continue}
                    if requested==RebaseAction.squash.rawValue {if !hasLeader {orphanIndices.insert(position)}}else{hasLeader=true}
                }
                var createdGroup:RebaseNoCommitGroup?
                if let next=orphanIndices.filter({$0>index}).min() {
                    for position in orphanIndices {identities[position].noCommitSquash=true;identities[position].deferredSquash=false}
                    var actionPosition=index,rewritten:[String]=[]
                    for line in todo {
                        let parts=RebaseEditor.canonicalLine(line).split(separator:" ",maxSplits:2).map(String.init)
                        if parts.count>=2,RebaseAction(rawValue:parts[0]) != nil {
                            if orphanIndices.contains(actionPosition) {
                                rewritten.append(RebaseEditor.sourceSquashPrefix+identities[actionPosition].id)
                                rewritten.append("drop "+parts.dropFirst().joined(separator:" "))
                            }else{rewritten.append(line)}
                            actionPosition += 1
                        }else{rewritten.append(line)}
                    }
                    todo=rewritten
                    // The skipped row is consumed without touching HEAD/index.
                    // Only intervening Skip rows may precede the orphan group.
                    for position in index..<next {
                        guard identities[position].action==RebaseAction.skip.rawValue,let first=todo.firstIndex(where:{!$0.isEmpty && !$0.hasPrefix("#")}),todo[first].hasPrefix("drop ") else{throw RebaseFailure.changed}
                        done.append(todo.remove(at:first))
                    }
                    let anchor=try reachedMainlineAnchor(directory,entryID:warning.entryID,sessionIdentity:failedPickSessionIdentity(directory),parents:rebaseCommit(warning.commit).parents,cancellation:replayCancellation)
                    let original=try rebaseCommit(identities[next].hash)
                    createdGroup = .init(id:UUID().uuidString,session:try failedPickSessionIdentity(directory),baseHead:warning.head,step:next+1,phase:.waiting,message:anchor.squashLeader?.message ?? "",leader:anchor.squashLeader,latestDate:original.date)
                    createdGroup?.allowsEmpty=anchor.squashCurrentEmpty ?? false
                }else{try restoreDeferredSquashes(after:index,todo:&todo,identities:&identities,mapping:mapping)}
                var after = files
                if let createdGroup {after[Self.noCommitSquashName] = .init(bytes:try JSONEncoder().encode(createdGroup))}
                after["git-rebase-todo"] = .init(bytes: Data(todo.joined(separator: "\n").utf8))
                after["done"] = .init(bytes: Data(done.joined(separator: "\n").utf8))
                after["turtlegit-replay-identities.json"] = .init(bytes: try JSONEncoder().encode(identities))
                if let bytes = files["turtlegit-message-editor.json"]?.bytes {
                    var configuration = try JSONDecoder().decode(RebaseMessageConfiguration.self, from: bytes)
                    if configuration.actions?.indices.contains(index) == true { configuration.actions?[index] = RebaseAction.skip.rawValue }
                    after["turtlegit-message-editor.json"] = .init(bytes: try JSONEncoder().encode(configuration))
                }
                let journalURL = directory.appendingPathComponent(Self.actionEditJournal)
                try JSONEncoder().encode(RebaseActionEditJournal(version: 2, before: files, after: after)).write(to: journalURL, options: .atomic)
                for name in Self.actionEditNames where name != "git-rebase-todo" { try actionEditWrite(after[name]!, directory: directory, name: name) }
                try actionEditWrite(after["git-rebase-todo"]!, directory: directory, name: "git-rebase-todo")
                try FileManager.default.removeItem(at: journalURL)
            }
            return try recoverRebase("--continue")
        }
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
        if action=="--continue",try noCommitGroup(rebasePath("rebase-merge")) != nil {return try advanceNoCommitGroup()}
        let state=try rebaseState()
        guard state.active else { throw RebaseFailure.inactive }
        let configuration = try rebasePath("rebase-merge/turtlegit-message-editor.json")
        let config = FileManager.default.fileExists(atPath: configuration.path) ? try JSONDecoder().decode(RebaseMessageConfiguration.self, from: Data(contentsOf: configuration)) : nil
        let hooks=action == "--continue" ? try deferredSquashPreparationHooks(state:state,configuration:config):nil
        defer {if let hooks {try? FileManager.default.removeItem(at:hooks.directory)}}
        var arguments=["-c","i18n.logOutputEncoding=UTF-8"]
        var environment=["GIT_EDITOR":config?.editorCommand ?? "/usr/bin/true"]
        if let hooks {arguments += ["-c","core.hooksPath="+hooks.directory.path];environment["TURTLEGIT_SQUASH_PREPARATION"]=hooks.nonce}
        return try executeRebase(arguments+["rebase",action],environment:environment)
    }
    /// Source replay applies Squash with cherry-pick --no-commit and runs user
    /// message hooks only at approval. Git's sequencer instead prepares a commit
    /// before invoking our deferred editor. Suppress only that exact preparation
    /// hook; manual message commits and every other hook keep their real target.
    private func deferredSquashPreparationHooks(state:RebaseState,configuration:RebaseMessageConfiguration?)throws->(directory:URL,nonce:String)? {
        guard let configuration,configuration.editorCommand.contains(RebaseEditor.messageArgument),state.squashMessage == nil else{return nil}
        let directory=try rebasePath("rebase-merge"),identities=replayIdentities(directory)
        guard !identities.isEmpty,state.currentStep>0,state.currentStep<=identities.count else{return nil}
        guard let done=try actionEditFile(directory,"done").bytes,let todo=try actionEditFile(directory,"git-rebase-todo").bytes,
              done.count+todo.count<=32*1024*1024,let doneText=String(data:done,encoding:.utf8),let todoText=String(data:todo,encoding:.utf8) else{throw RebaseFailure.plan}
        let mapping=(try? JSONDecoder().decode([String:String].self,from:Data(contentsOf:directory.appendingPathComponent("turtlegit-cherry-pick.json")))) ?? [:]
        func matches(_ line:String,index:Int,action:RebaseAction)->Bool {
            let fields=RebaseEditor.canonicalLine(line).split(separator:" ",maxSplits:2).map(String.init)
            guard fields.count>=2,fields[0]==action.rawValue,GitLocalReferenceProtocol.validOID(fields[1]),identities.indices.contains(index),identities[index].action==action.rawValue else{return false}
            return GitReferenceName.equal(mapping[fields[1]] ?? fields[1],identities[index].hash)
        }
        var expected=done,lengths=[Int]()
        let last=doneText.components(separatedBy:"\n").last {$0.first != "#" && !$0.isEmpty}
        if state.stoppedAction == .squash,state.stoppedEntryID==identities[state.currentStep-1].id,
           let last,matches(last,index:state.currentStep-1,action:.squash) {lengths.append(done.count)}
        var cursor=state.currentStep,group=false
        let lines=todoText.components(separatedBy:"\n")
        for (position,line) in lines.enumerated() {
            let canonical=RebaseEditor.canonicalLine(line),fields=canonical.split(separator:" ").map(String.init),command=fields.first ?? ""
            if command.isEmpty || line.first == "#" {expected.append(Data((line+(position<lines.count-1 ? "\n":"")).utf8));continue}
            if command==RebaseAction.squash.rawValue || command==RebaseAction.skip.rawValue {
                let action:RebaseAction=command==RebaseAction.squash.rawValue ? .squash:.skip
                guard matches(line,index:cursor,action:action) else{break}
                expected.append(Data((line+(position<lines.count-1 ? "\n":"")).utf8));cursor += 1
                if action == .squash {group=true;lengths.append(expected.count)}
            } else if (command=="update-ref" || command=="label") && group {
                expected.append(Data((line+(position<lines.count-1 ? "\n":"")).utf8))
            } else {break}
        }
        guard !lengths.isEmpty,lengths.count<=100000 else{return nil}
        var hooksPath=try run(["rev-parse","--git-path","hooks"]).stdout
        if hooksPath.last==10 {hooksPath.removeLast()}
        guard let path=String(data:hooksPath,encoding:.utf8),!path.isEmpty,!path.utf8.contains(0) else{throw RebaseFailure.plan}
        let configured=try run(["config","--path","--null","--get","core.hooksPath"],successfulExitCodes:0...1)
        var invocationPath=path
        if configured.exitCode==0 {
            var bytes=configured.stdout
            guard bytes.last==0 else{throw RebaseFailure.plan};bytes.removeLast()
            guard let literal=String(data:bytes,encoding:.utf8),!literal.isEmpty,!literal.utf8.contains(0) else{throw RebaseFailure.plan}
            invocationPath=literal
        }
        // Git's path query can canonicalize an absolute configured alias. Read
        // through a URL, but invoke the exact configured hook spelling so $0
        // retains the same meaning as a normal, non-overlay Git invocation.
        let original=invocationPath.hasPrefix("/") ? URL(fileURLWithPath:invocationPath,isDirectory:true):root.appendingPathComponent(invocationPath,isDirectory:true)
        func invocation(_ name:String)->String {invocationPath+(invocationPath.hasSuffix("/") ? "":"/")+name}
        let prepare=original.appendingPathComponent("prepare-commit-msg")
        guard FileManager.default.isExecutableFile(atPath:prepare.path) else{return nil}
        let overlay=try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGit-replay-hooks-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:overlay,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var accepted=false;defer {if !accepted {try? FileManager.default.removeItem(at:overlay)}}
        var guardDirectory=overlay.appendingPathComponent(".receipt-"+UUID().uuidString,isDirectory:true)
        while FileManager.default.fileExists(atPath:original.appendingPathComponent(guardDirectory.lastPathComponent).path) {guardDirectory=overlay.appendingPathComponent(".receipt-"+UUID().uuidString,isDirectory:true)}
        try FileManager.default.createDirectory(at:guardDirectory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        func quote(_ text:String)->String {"'"+text.replacingOccurrences(of:"'",with:"'\\''")+"'"}
        let inheritedParameters=ProcessInfo.processInfo.environment["GIT_CONFIG_PARAMETERS"] ?? ""
        // Match Git's split-parameter quoting for the original transport's one
        // existing -c argument. Forwarded user hooks must not export our overlay
        // into nested/background Git, including Git in another repository.
        let originalParameters=(inheritedParameters.isEmpty ? "":inheritedParameters+" ")+"'i18n.logOutputEncoding'='UTF-8'"
        let forwardEnvironment="unset TURTLEGIT_SQUASH_PREPARATION\nexport GIT_CONFIG_PARAMETERS="+quote(originalParameters)+"\n"
        var info=stat();guard lstat(directory.path,&info)==0,info.st_mode & S_IFMT==S_IFDIR else{throw RebaseFailure.changed}
        let session=[String(info.st_dev),String(info.st_ino),String(info.st_birthtimespec.tv_sec)].joined(separator:":"),nonce=UUID().uuidString
        try expected.write(to:guardDirectory.appendingPathComponent("expected-done"))
        var guards=""
        for (index,name) in ["orig-head","onto","head-name","turtlegit-message-editor.json","turtlegit-replay-identities.json"].enumerated() {
            guard let bytes=try actionEditFile(directory,name).bytes else{return nil}
            let snapshot=guardDirectory.appendingPathComponent("receipt-"+String(index));try bytes.write(to:snapshot)
            guards += "  /usr/bin/cmp -s "+quote(directory.appendingPathComponent(name).path)+" "+quote(snapshot.path)+" || return 1\n"
        }
        let script="""
        #!/bin/sh
        source_preparation() {
          [ "${TURTLEGIT_SQUASH_PREPARATION-}" = \(quote(nonce)) ] || return 1
          [ "${2-}" = message ] || return 1
          [ ! -e \(quote(directory.appendingPathComponent("turtlegit-squash-message.json").path)) ] || return 1
          identity=$(/usr/bin/stat -f '%d:%i:%B' \(quote(directory.path)) 2>/dev/null) || return 1
          [ "$identity" = \(quote(session)) ] || return 1
        \(guards)  length=$(/usr/bin/stat -f '%z' \(quote(directory.appendingPathComponent("done").path)) 2>/dev/null) || return 1
          case "$length" in \(lengths.map(String.init).joined(separator:"|"))) ;; *) return 1;; esac
          /usr/bin/head -c "$length" \(quote(guardDirectory.appendingPathComponent("expected-done").path)) | /usr/bin/cmp -s \(quote(directory.appendingPathComponent("done").path)) -
        }
        if source_preparation "$@"; then exit 0; fi
        \(forwardEnvironment)exec \(quote(invocation("prepare-commit-msg"))) "$@"
        """
        let entries=try FileManager.default.contentsOfDirectory(at:original,includingPropertiesForKeys:nil)
        guard entries.count<=4096 else{throw RebaseFailure.plan}
        for hook in entries where hook.lastPathComponent != "prepare-commit-msg" && FileManager.default.isExecutableFile(atPath:hook.path) {
            let forward=overlay.appendingPathComponent(hook.lastPathComponent)
            try Data(("#!/bin/sh\n"+forwardEnvironment+"exec "+quote(invocation(hook.lastPathComponent))+" \"$@\"\n").utf8).write(to:forward)
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:forward.path)
        }
        let target=overlay.appendingPathComponent("prepare-commit-msg")
        try Data(script.utf8).write(to:target);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:target.path)
        accepted=true;return (overlay,nonce)
    }
    private func recordStructuralResultIfReached()throws->Bool {
        let directory=try rebasePath("rebase-merge")
        guard FileManager.default.fileExists(atPath:directory.appendingPathComponent("turtlegit-structural-plan").path),
              let done=try actionEditFile(directory,"done").bytes,
              let last=RebaseEditor.checkpointDone(in:directory,text:String(decoding:done,as:UTF8.self)).split(separator:"\n").last,
              let id=RebaseEditor.structuralResultID(String(last)) else{return false}
        let identities=replayIdentities(directory)
        guard let identity=identities.first(where:{$0.id==id && $0.structuralMerge==true}),identity.action != RebaseAction.skip.rawValue,
              try rebaseCommit(identity.hash).parents.count>1 else{throw RebaseFailure.plan}
        let session=try failedPickSessionIdentity(directory),head=try rebaseRevision("HEAD")
        guard try rebaseRevision("refs/rewritten/turtlegit-"+identity.hash)==head else{throw RebaseFailure.changed}
        try withActionEditLock(directory) {
            guard try failedPickSessionIdentity(directory)==session,try rebaseRevision("HEAD")==head,
                  try actionEditFile(directory,"done").bytes==done else{throw RebaseFailure.changed}
            let name="rewritten-list"
            var bytes=try actionEditFile(directory,name).bytes ?? Data()
            guard bytes.count<=16_777_216 else{throw RebaseFailure.plan}
            let matches=String(decoding:bytes,as:UTF8.self).split(separator:"\n").map {$0.split(separator:" ").map(String.init)}.filter {$0.first==identity.hash}
            guard matches.allSatisfy({$0.count==2 && $0[1]==head}) else{throw RebaseFailure.changed}
            if matches.isEmpty,identity.hash != head {
                bytes.append(Data((identity.hash+" "+head+"\n").utf8))
                try bytes.write(to:directory.appendingPathComponent(name),options:.atomic)
            }
            // Consume exactly once, including unchanged/self mappings. A later
            // Git refusal cannot recursively redispatch this same checkpoint.
            var lines=RebaseEditor.checkpointDone(in:directory,text:String(decoding:done,as:UTF8.self)).components(separatedBy:"\n")
            guard let position=lines.lastIndex(where:{!$0.isEmpty}),RebaseEditor.structuralResultID(lines[position])==id else{throw RebaseFailure.changed}
            lines[position]=RebaseEditor.structuralResultDonePrefix+id+" "+head
            guard try noCommitGroup(directory)==nil else{throw RebaseFailure.changed}
            let files=try actionEditFiles(directory)
            var todo=String(decoding:files["git-rebase-todo"]?.bytes ?? Data(),as:UTF8.self).components(separatedBy:"\n")
            if let first=todo.firstIndex(where:{!$0.isEmpty && !$0.hasPrefix("#")}),RebaseEditor.structuralResultID(RebaseEditor.canonicalLine(todo[first]))==id {todo.remove(at:first)}
            try publishNoCommitGroup(nil,directory:directory,files:files,todo:todo,done:lines)
        }
        return true
    }
    private func executeRebase(_ arguments: [String], environment: [String: String]) throws -> RebaseExecution {
        func execution(_ output:String,_ exitCode:Int32) throws -> RebaseExecution {
            if !arguments.contains("--abort"),try recordStructuralResultIfReached() {
                let next=try recoverRebase("--continue")
                return .init(output:output+next.output,exitCode:next.exitCode,state:next.state,witnessedHead:next.witnessedHead,witnessedSession:next.witnessedSession)
            }
            let head=try? rebaseRevision("HEAD"),state=try rebaseState()
            if state.active,!arguments.contains("--abort"),try startNoCommitGroupIfReached() {return try advanceNoCommitGroup()}
            let session=state.active ? (try? failedPickSessionIdentity(rebasePath("rebase-merge"))) : nil
            let done = state.active ? (try? String(contentsOf: rebasePath("rebase-merge/done"), encoding: .utf8)) : nil
            let last = done?.split(separator: "\n").last.map(String.init)
            let intentionalEdit = state.isEditPause && last.flatMap { RebaseEditor.emptyMessageID($0, applied: true) } == state.stoppedEntryID
            replayProgressObservation?.sample(force:true)
            if exitCode==0,!state.active,!arguments.contains("--abort") {replayProgressObservation?.finish(head:head ?? "")}
            return RebaseExecution(output:output,exitCode:intentionalEdit ? 0 : exitCode,state:state,witnessedHead:head,witnessedSession:session)
        }
        do {return try execution(run(arguments,environmentOverrides:environment).text,0)}
        catch let failure as GitFailure {return try execution(failure.message,failure.code)}
    }
    private func amendRebaseCommitOwned(message: String) throws -> String {
        guard try rebaseState().active else { throw RebaseFailure.inactive }
        let state = try rebaseState()
        if let failure=state.cleanCommitFailure {throw failure}
        guard state.conflictMessage == nil,!state.hasIgnoredCleanCommitFailure else{throw RebaseFailure.changed}
        guard state.isEditPause, state.squashMessage == nil && (state.split == nil || state.split?.conflictRecovery == true) else { throw RebaseFailure.plan }
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RebaseFailure.message }
        let base = try commitComparisonBase(amendToParent: true)
        let originallyEmpty = try run(["diff", "--quiet", base, "HEAD", "--"], successfulExitCodes: 0...1).exitCode == 0
        let messageFile = try makeCommitMessageFile(message); defer { messageFile.remove() }
        return try commitReplayMessage(["commit", "--amend", "-F", messageFile.url.path] + (originallyEmpty ? ["--allow-empty"] : []),message:message)
    }
    private func beginRebaseSplitOwned() throws -> RebaseSplitState {
        let state = try rebaseState()
        guard state.canSplit else { throw RebaseFailure.plan }
        if let split = state.split, split.conflictRecovery != true {
            guard split.expectedHead == (try rebaseRevision("HEAD")) else{throw RebaseFailure.changed}
            return split
        }
        if let phase=state.noCommitSquash {
            let directory=try rebasePath("rebase-merge")
            guard var group=try noCommitGroup(directory),phase.id==group.id,group.phase == .approval,try rebaseRevision("HEAD")==group.baseHead else{throw RebaseFailure.changed}
            let configuration=try JSONDecoder().decode(RebaseMessageConfiguration.self,from:Data(contentsOf:directory.appendingPathComponent("turtlegit-message-editor.json")))
            let date=configuration.datePolicy == .latest ? group.latestDate:group.leader?.date ?? ""
            var split=RebaseSplitState(entryID:state.stoppedEntryID,step:state.currentStep,expectedHead:group.baseHead,parts:0,
                                       firstAuthor:group.leader.map {$0.name+" <"+$0.email+">"} ?? "",firstDate:date,squashDate:group.leader == nil ? nil:configuration.datePolicy)
            split.noCommitGroupID=group.id;split.firstParents=[group.baseHead];group.split=split
            try withActionEditLock(directory) {try publishNoCommitGroup(group,directory:directory,files:actionEditFiles(directory))}
            guard let receipt=try rebaseState().split else{throw RebaseFailure.changed}
            return receipt
        }
        let head = try rebaseCommit("HEAD")
        if let recovery = state.split, recovery.conflictRecovery == true, recovery.expectedHead != head.hash { throw RebaseFailure.changed }
        var split = RebaseSplitState(entryID: state.stoppedEntryID, step: state.currentStep, expectedHead: head.hash, parts: 0,
                                     firstAuthor: head.author + " <" + head.email + ">", firstDate: state.squashMessage?.datePolicy == .latest ? state.squashMessage!.latestDate : head.date,
                                     squashDate: state.squashMessage?.datePolicy)
        split.firstParents = head.parents
        if let recovery = state.split, recovery.conflictRecovery == true {
            split.structuralControlCursor=recovery.structuralControlCursor
            split.conflictRecoveryReturn = RebaseSplitReturn(structuralControlCursor:recovery.structuralControlCursor,parts: recovery.parts, firstAuthor: recovery.firstAuthor, firstDate: recovery.firstDate, squashDate: recovery.squashDate, firstParents: recovery.firstParents)
        }
        try JSONEncoder().encode(split).write(to: rebasePath("rebase-merge/turtlegit-split.json"), options: .atomic)
        return split
    }
    /// Edit's dirty-worktree handoff amends the applied commit, without turning
    /// the first accepted selection into a new split part or resetting HEAD.
    public func beginRebaseEditSelection(expected: RebaseState, expectedHead: String, cancellation: OperationCancellation? = nil) throws -> RebaseSplitState? {
        try withReplayIO(cancellation: cancellation, onOutput: nil) {
            let state = try rebaseState(); try requireRebaseContinuation(state, expected: expected, expectedHead: expectedHead)
            guard state.conflictMessage == nil,state.cleanCommitFailure == nil,!state.hasIgnoredCleanCommitFailure else{throw RebaseFailure.changed}
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
        guard state.active,state.conflictMessage == nil,state.cleanCommitFailure == nil,!state.hasIgnoredCleanCommitFailure, state.needsFileRecovery, state.split == nil, state.conflicts.isEmpty, state.stoppedAction == .pick || state.stoppedAction == .edit,
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
        let first=try beginRebaseConflictMessageOwned(rawMessage:message,paths:paths,expected:expected,expectedHead:expectedHead,allowEmpty:allowEmpty)
        guard let phase=first.state.conflictMessage else{throw RebaseFailure.changed}
        let second=try completeRebaseConflictMessageOwned(amendMessage:phase.needsAmend ? message:nil,expected:first.state,expectedHead:phase.head,editorExecutable:nil,rawMessage:message,returnAppliedReview:true,allowEmptyAmend:allowEmpty)
        return .init(output:first.output+second.output,exitCode:second.exitCode,state:second.state,witnessedHead:second.witnessedHead,witnessedSession:second.witnessedSession)
    }
    private func beginRebaseConflictMessageOwned(rawMessage:String,paths:GitPathSet,expected:RebaseState,expectedHead:String,allowEmpty:Bool,indexPolicy:CommitCheckboxIndexPolicy?=nil)throws->RebaseExecution {
        let (state, checked) = try checkedRebaseRecovery(paths: paths, expected: expected, expectedHead: expectedHead)
        let modes = try selectedStagedFileModes(checked)
        if !allowEmpty, try commitSelectionIsEmpty(checked: checked, base: "HEAD", fileModes: modes) { throw RebaseFailure.emptyResult }
        let source = try rebaseCommit(state.stoppedCommit)
        let directory=try rebasePath("rebase-merge")
        let requested=replayIdentities(directory).first {$0.id==state.stoppedEntryID}?.action.flatMap(RebaseAction.init(rawValue:)) ?? state.stoppedAction ?? .pick
        var phase=RebaseConflictMessage(entryID:state.stoppedEntryID,beforeHead:expectedHead,originalCommit:source.hash,originalMessage:source.message,head:expectedHead,rawMessage:rawMessage,
            requestedAction:requested,needsAmend:!GitReferenceName.equal(rawMessage.trimmingCharacters(in:.whitespacesAndNewlines),source.message.trimmingCharacters(in:.whitespacesAndNewlines)),phase:.pending,
            sessionIdentity:try failedPickSessionIdentity(directory),step:state.currentStep,originalHead:state.originalHead,index:try conflictMessageIndex(),files:try conflictMessageFiles(directory),prepared:true,readd:[],remove:[],readdUnchecked:indexPolicy?.readdUnchecked ?? false)
        // Published before index preparation or commit: an interrupted first
        // phase with advanced HEAD is uncertain, never another initial commit.
        try saveConflictMessage(phase,directory:directory)
        var options = CommitOptions(); options.messageOnly = allowEmpty
        var prepared:Data?
        if let indexPolicy {
            let changes=try status()
            let restoration=try prepareCLICommitIndex(changes:changes,checked:paths,policy:indexPolicy,base:expectedHead,cancellation:nil,onOutput:replayOutput,fileModes:modes)
            prepared=restoration.index;phase.readd=restoration.readd.sorted();phase.remove=restoration.remove.sorted();phase.index=try conflictMessageIndex()
            try saveConflictMessage(phase,directory:directory)
        }
        let output=try commitSeparateSelection(message:source.message,checked:checked,options:options,base:"HEAD",fileModes:modes,sourcePrepared:indexPolicy != nil,preparedIndexBytes:prepared,reusingMessageFrom:source.hash,usePreparedRealIndex:indexPolicy != nil)
        phase.head=try rebaseRevision("HEAD");phase.index=try conflictMessageIndex();phase.files=try conflictMessageFiles(directory);phase.prepared=false
        try saveConflictMessage(phase,directory:directory)
        return RebaseExecution(output: output, exitCode: 0, state: try rebaseState(),witnessedHead:phase.head,witnessedSession:phase.sessionIdentity)
    }
    private func rebaseSplitHasRemainingChangesOwned() throws -> Bool {
        try !replayWorktreeIsClean()
    }
    private func cancelUnstartedRebaseSplitOwned() throws {
        guard let split = try rebaseState().split, split.parts == 0, try rebaseRevision("HEAD") == split.expectedHead else { throw RebaseFailure.changed }
        if let id=split.noCommitGroupID {
            let directory=try rebasePath("rebase-merge")
            guard var group=try noCommitGroup(directory),group.id==id,group.phase == .approval,group.split==split.stored else{throw RebaseFailure.changed}
            group.split=nil
            try withActionEditLock(directory) {try publishNoCommitGroup(group,directory:directory,files:actionEditFiles(directory))}
            return
        }
        let path = try rebasePath("rebase-merge/turtlegit-split.json")
        if let origin = split.conflictRecoveryReturn {
            guard origin.parts > 0 else { throw RebaseFailure.changed }
            var restored = RebaseSplitState(entryID: split.entryID, step: split.step, expectedHead: split.expectedHead, parts: origin.parts, firstAuthor: origin.firstAuthor, firstDate: origin.firstDate, squashDate: origin.squashDate)
            restored.conflictRecovery = true
            restored.firstParents = origin.firstParents
            restored.structuralControlCursor=origin.structuralControlCursor
            try JSONEncoder().encode(restored).write(to: path, options: .atomic)
        } else { try FileManager.default.removeItem(at: path) }
    }
    /// No reset or amend is valid here: these changes have never been committed.
    /// The applying journal is published before the child's Git operation, so an
    /// interrupted process can never silently repeat a part that advanced HEAD.
    private func commitNoCommitSplit(message:String,paths:GitPathSet,staging:Bool,options:CommitOptions,expected:RebaseSplitState,state:RebaseState)throws->String {
        let directory=try rebasePath("rebase-merge")
        guard state.canSplit,state.cleanCommitFailure==nil,!state.hasIgnoredCleanCommitFailure,state.split==expected,
              var group=try noCommitGroup(directory),group.phase == .approval,group.split==expected.stored,group.id==expected.noCommitGroupID,
              try rebaseRevision("HEAD")==expected.expectedHead,!options.amend,!options.amendDiffToLastCommit,options.newBranch==nil else{throw RebaseFailure.changed}
        guard !message.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw RebaseFailure.message}
        // The native child installs the captured source presets, then the user
        // may edit/uncheck them. Explicit options remain authoritative here.
        let beforeFiles=try actionEditFiles(directory),beforeLabels=try structuralNoCommitLabels(directory)
        group.phase = .applying
        try withActionEditLock(directory) {try publishNoCommitGroup(group,directory:directory,files:beforeFiles)}
        let output:String
        do {output=try (staging ? commitIndex(message:message,options:options):commitSelected(message:message,paths:paths,options:options))}
        catch {
            // The Commit child owns failure and explicit retry. Only an unchanged HEAD
            // permits returning to that child; an interrupted successful commit
            // is deliberately uncertain rather than a guessed additional part.
            let unchanged=(try? rebaseRevision("HEAD"))==expected.expectedHead
            try? replayUncancelled {
                try withActionEditLock(directory) {
                    let files=try actionEditFiles(directory)
                    guard try noCommitGroup(directory)==group,try structuralNoCommitLabels(directory)==beforeLabels,Self.actionEditNames.filter({$0 != Self.noCommitSquashName}).allSatisfy({files[$0]==beforeFiles[$0]}) else{throw RebaseFailure.changed}
                    group.phase=unchanged ? .approval:.uncertain
                    // Restore the exact pre-operation group bytes on an ordinary
                    // child failure, keeping its still-valid retry receipt valid.
                    try publishNoCommitGroup(group,directory:directory,files:files,groupBytes:unchanged ? beforeFiles[Self.noCommitSquashName]?.bytes:nil)
                }
            }
            throw error
        }
        let head=try rebaseCommit("HEAD")
        guard head.hash != expected.expectedHead,head.parents==[expected.expectedHead] else{throw RebaseFailure.changed}
        // After a successful child commit the durable part receipt must be
        // published even if cancellation arrives before delivery to its owner.
        try replayUncancelled {
            try withActionEditLock(directory) {
                let files=try actionEditFiles(directory)
                guard try noCommitGroup(directory)==group,try rebaseRevision("HEAD")==head.hash,try structuralNoCommitLabels(directory)==beforeLabels,
                      Self.actionEditNames.filter({$0 != Self.noCommitSquashName}).allSatisfy({files[$0]==beforeFiles[$0]}) else{throw RebaseFailure.changed}
                var updated=expected.stored;updated.parts += 1;updated.expectedHead=head.hash
                group.split=updated;group.message=message;group.phase = .approval
                try publishNoCommitGroup(group,directory:directory,files:files)
            }
        }
        return output
    }
    /// Commit each split part through the same complete selection/index backend.
    /// The first part replaces the stopped commit; later parts create children.
    private func commitRebaseSplitOwned(message: String, paths: GitPathSet, staging: Bool, options: CommitOptions, expected: RebaseSplitState) throws -> String {
        let state = try rebaseState()
        if expected.isNewCommit {return try commitNoCommitSplit(message:message,paths:paths,staging:staging,options:options,expected:expected,state:state)}
        guard state.cleanCommitFailure == nil,!state.hasIgnoredCleanCommitFailure,let saved = state.split, state.canSplit || saved.conflictRecovery == true, saved.parts == expected.parts, saved.entryID == expected.entryID,
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
    var hasEmptyReplaySubject:Bool {historySubject.isEmpty}
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
    private func withProtectedReplayIO<T>(cancellation: OperationCancellation?, onOutput: (@Sendable (GitOutputChunk) -> Void)?, onProgress: (@Sendable (RebaseProgress) -> Void)? = nil, operation: () throws -> T) throws -> T {
        let token = cancellation ?? replayCancellation; try token?.check()
        let guardedProgress:(@Sendable(RebaseProgress)->Void)?=onProgress.map { callback in {value in if token?.isCancelled != true {callback(value)}} }
        let result = try replayUncancelled { try withReplayIO(cancellation:nil,onOutput:onOutput,onProgress:guardedProgress,operation:operation) }
        try token?.check(); return result
    }
    private func withReplayIO<T>(cancellation: OperationCancellation?, onOutput: (@Sendable (GitOutputChunk) -> Void)?, onProgress: (@Sendable (RebaseProgress) -> Void)? = nil, progressPlan:RebasePlan? = nil, operation: () throws -> T) throws -> T {
        let previousToken = replayCancellation, previousOutput = replayOutput, previousProgress=replayProgressObservation
        let acceptedProgress=try onProgress.map {callback in
            try (cancellation ?? previousToken)?.check()
            return RebaseProgressObservation(directory:try rebasePath("rebase-merge"),headFile:try rebasePath("HEAD"),plan:progressPlan,cancellation:cancellation ?? previousToken,callback:callback)
        }
        replayCancellation = cancellation ?? previousToken; replayOutput = onOutput ?? previousOutput
        replayProgressObservation=acceptedProgress ?? previousProgress
        defer {
            if replayProgressObservation !== previousProgress {replayProgressObservation?.retire()}
            replayCancellation = previousToken; replayOutput = previousOutput;replayProgressObservation=previousProgress
        }
        try replayCancellation?.check();replayProgressObservation?.sample();return try operation()
    }
    public func startRebase(_ plan: RebasePlan, editorExecutable: URL, afterFetch: Bool = false, autoStart: Bool = false, fromLog: Bool = false, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil, onProgress: (@Sendable (RebaseProgress) -> Void)? = nil) throws -> RebaseExecution {
        try withReplayIO(cancellation: cancellation, onOutput:onOutput,onProgress:onProgress,progressPlan:plan) { try startRebaseOwned(plan, editorExecutable: editorExecutable, afterFetch: afterFetch, autoStart: autoStart, fromLog: fromLog) }
    }
    public func continueRebase(squashMessage: String? = nil, editMessage: String? = nil, emptySquashChoice: RebaseEmptyChoice? = nil, expectedSquashHead: String? = nil, expectedSquashState: RebaseState? = nil, expectedReplayState: RebaseState? = nil, expectedReplayHead: String? = nil, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil, editorExecutable: URL? = nil, onProgress: (@Sendable (RebaseProgress) -> Void)? = nil) throws -> RebaseExecution {
        try withReplayIO(cancellation: cancellation, onOutput:onOutput,onProgress:onProgress) { try continueRebaseOwned(editorExecutable: editorExecutable, squashMessage: squashMessage, editMessage: editMessage, emptySquashChoice: emptySquashChoice, expectedSquashHead: expectedSquashHead, expectedSquashState: expectedSquashState, expectedReplayState: expectedReplayState, expectedReplayHead: expectedReplayHead) }
    }
    public func skipRebase(cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil, onProgress: (@Sendable (RebaseProgress) -> Void)? = nil) throws -> RebaseExecution {
        try withReplayIO(cancellation: cancellation, onOutput:onOutput,onProgress:onProgress) { try skipRebaseOwned() }
    }
    public func abortRebase(cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil, onProgress: (@Sendable (RebaseProgress) -> Void)? = nil) throws -> RebaseExecution {
        try withReplayIO(cancellation: cancellation, onOutput:onOutput,onProgress:onProgress) { try abortRebaseOwned() }
    }
    public func amendRebaseCommit(message: String, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil, onProgress: (@Sendable (RebaseProgress) -> Void)? = nil) throws -> String {
        try withReplayIO(cancellation: cancellation, onOutput:onOutput,onProgress:onProgress) { try amendRebaseCommitOwned(message: message) }
    }
    public func beginRebaseSplit(cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil, onProgress: (@Sendable (RebaseProgress) -> Void)? = nil, expected:RebaseState?=nil, expectedHead:String?=nil) throws -> RebaseSplitState {
        try withReplayIO(cancellation:cancellation,onOutput:onOutput,onProgress:onProgress) {
            if let expected {
                guard let expectedHead else{throw RebaseFailure.changed}
                try requireRebaseContinuation(rebaseState(),expected:expected,expectedHead:expectedHead)
            } else if expectedHead != nil {throw RebaseFailure.changed}
            return try beginRebaseSplitOwned()
        }
    }
    public func rebaseSquashIsEmpty(cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil, onProgress: (@Sendable (RebaseProgress) -> Void)? = nil) throws -> Bool {
        try withReplayIO(cancellation: cancellation, onOutput:onOutput,onProgress:onProgress) { try rebaseSquashIsEmptyOwned() }
    }
    public func rebaseConflictSelectionIsEmpty(paths selection: some Sequence<String>, expected: RebaseState, expectedHead: String, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil, onProgress: (@Sendable (RebaseProgress) -> Void)? = nil) throws -> Bool {
        let paths = GitPathSet(selection)
        return try withReplayIO(cancellation: cancellation, onOutput:onOutput,onProgress:onProgress) { try rebaseConflictSelectionIsEmptyOwned(paths: paths, expected: expected, expectedHead: expectedHead) }
    }
    public func commitRebaseConflictSelection(message: String, paths selection: some Sequence<String>, expected: RebaseState, expectedHead: String, allowEmpty: Bool = false, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil, onProgress: (@Sendable (RebaseProgress) -> Void)? = nil) throws -> RebaseExecution {
        let paths = GitPathSet(selection)
        return try withProtectedReplayIO(cancellation: cancellation, onOutput:onOutput,onProgress:onProgress) { try commitRebaseConflictSelectionOwned(message: message, paths: paths, expected: expected, expectedHead: expectedHead, allowEmpty: allowEmpty) }
    }
    public func rebaseSplitHasRemainingChanges(cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil, onProgress: (@Sendable (RebaseProgress) -> Void)? = nil) throws -> Bool {
        try withReplayIO(cancellation: cancellation, onOutput:onOutput,onProgress:onProgress) { try rebaseSplitHasRemainingChangesOwned() }
    }
    public func cancelUnstartedRebaseSplit(cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil, onProgress: (@Sendable (RebaseProgress) -> Void)? = nil) throws -> Void {
        try withReplayIO(cancellation: cancellation, onOutput:onOutput,onProgress:onProgress) { try cancelUnstartedRebaseSplitOwned() }
    }
    public func commitRebaseSplit(message: String, paths selection: some Sequence<String>, staging: Bool, options: CommitOptions, expected: RebaseSplitState, cancellation: OperationCancellation? = nil, onOutput: (@Sendable (GitOutputChunk) -> Void)? = nil, onProgress: (@Sendable (RebaseProgress) -> Void)? = nil) throws -> String {
        let paths = GitPathSet(selection)
        return try withProtectedReplayIO(cancellation: cancellation, onOutput:onOutput,onProgress:onProgress) { try commitRebaseSplitOwned(message: message, paths: paths, staging: staging, options: options, expected: expected) }
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
    fileprivate let adoption: RebaseAdoptedPlan?
    public var requiresAdoption: Bool { adoption != nil && files["turtlegit-adopted-plan.json"]?.bytes == nil }
}
fileprivate struct RebaseActionEditFile: Codable, Equatable, Sendable { let bytes: Data? }
private struct RebaseActionEditJournal: Codable {
    let version: Int
    let before: [String: RebaseActionEditFile]
    let after: [String: RebaseActionEditFile]
}

extension GitRepository {
    private static let conflictMessageName="turtlegit-conflict-message.json"
    private func conflictMessageRecord(_ directory:URL)throws->RebaseConflictMessage? {
        guard let bytes=try actionEditFile(directory,Self.conflictMessageName).bytes else{return nil}
        let record=try JSONDecoder().decode(RebaseConflictMessage.self,from:bytes)
        guard GitLocalReferenceProtocol.validOID(record.originalCommit),GitLocalReferenceProtocol.validOID(record.head),
              GitLocalReferenceProtocol.validOID(record.beforeHead),record.step>0 else{throw RebaseFailure.plan}
        return record
    }
    private func conflictMessageIndex()throws->Data {try run(["-c","core.precomposeunicode=false","ls-files","--stage","-v","-z"],environmentOverrides:["GIT_OPTIONAL_LOCKS":"0"]).stdout}
    private func conflictMessageFiles(_ directory:URL)throws->[String:RebaseActionEditFile] {
        try Dictionary(uniqueKeysWithValues:Self.cleanCommitFailureNames.filter {$0 != Self.conflictMessageName}.map {($0,try actionEditFile(directory,$0))})
    }
    private func saveConflictMessage(_ phase:RebaseConflictMessage,directory:URL)throws {
        try JSONEncoder().encode(phase).write(to:directory.appendingPathComponent(Self.conflictMessageName),options:.atomic)
    }
    private func requireConflictMessage(_ phase:RebaseConflictMessage,state:RebaseState,directory:URL)throws {
        if phase.phase == .uncertain {throw RebaseFailure.conflictMessageUncertain}
        guard !phase.prepared,phase.phase != .uncertain,state.active,state.stoppedEntryID==phase.entryID,state.currentStep==phase.step,
              state.originalHead==phase.originalHead,try rebaseRevision("HEAD")==phase.head,
              try failedPickSessionIdentity(directory)==phase.sessionIdentity,
              try conflictMessageFiles(directory)==phase.files,try conflictMessageIndex()==phase.index else{throw RebaseFailure.changed}
    }
    private func finishConflictMessage(_ phase:RebaseConflictMessage,state:RebaseState,returnAppliedReview:Bool=false)throws->RebaseExecution {
        let directory=try rebasePath("rebase-merge")
        var completed=phase;completed.phase = .complete;completed.head=try rebaseRevision("HEAD")
        completed.index=try conflictMessageIndex()
        // Save completion before restoration or transport: neither a failed
        // queue nor cancellation can turn this back into another message amend.
        try withActionEditLock(directory) {
            var before=try cleanCommitFailureFiles(directory)
            var after=try completedReplayMessageFiles(state:state,message:phase.rawMessage,head:completed.head,files:before)
            completed.files=after.filter {$0.key != Self.conflictMessageName}
            after[Self.conflictMessageName] = .init(bytes:try JSONEncoder().encode(completed))
            before[Self.cleanCommitFailureName] = try actionEditFile(directory,Self.cleanCommitFailureName)
            after[Self.cleanCommitFailureName] = .init(bytes:nil)
            let journal=directory.appendingPathComponent(Self.actionEditJournal)
            try JSONEncoder().encode(RebaseActionEditJournal(version:3,before:before,after:after)).write(to:journal,options:.atomic)
            for name in before.keys where name != "git-rebase-todo" {try actionEditWrite(after[name]!,directory:directory,name:name)}
            try actionEditWrite(after["git-rebase-todo"]!,directory:directory,name:"git-rebase-todo")
            try FileManager.default.removeItem(at:journal)
        }
        if completed.readdUnchecked {
            if !completed.readd.isEmpty {
                _=try run(["add","--ignore-errors","-f","--pathspec-from-file=-","--pathspec-file-nul"],input:literalPathPacket(completed.readd))
                completed.readd=[];completed.index=try conflictMessageIndex();try saveConflictMessage(completed,directory:directory)
            }
            if !completed.remove.isEmpty {
                _=try run(["rm","--cached","--ignore-unmatch","--pathspec-from-file=-","--pathspec-file-nul"],input:literalPathPacket(completed.remove))
                completed.remove=[];completed.index=try conflictMessageIndex();try saveConflictMessage(completed,directory:directory)
            }
        }
        let emptySubject=completed.originalMessage.isEmpty || completed.originalMessage.utf8.first==10
        var needsAppliedReview=completed.requestedAction == .edit || emptySubject || returnAppliedReview
        if !needsAppliedReview {needsAppliedReview=try !replayWorktreeIsClean()}
        if needsAppliedReview {
            let head=try rebaseCommit("HEAD")
            var split=RebaseSplitState(entryID:state.stoppedEntryID,step:state.currentStep,expectedHead:head.hash,parts:1,firstAuthor:head.author+" <"+head.email+">",firstDate:head.date,squashDate:nil)
            split.conflictRecovery=true;split.firstParents=head.parents
            try withActionEditLock(directory) {
                var before=try cleanCommitFailureFiles(directory)
                before[Self.cleanCommitFailureName] = try actionEditFile(directory,Self.cleanCommitFailureName)
                var after=before
                after["turtlegit-split.json"] = .init(bytes:try JSONEncoder().encode(split))
                after[Self.conflictMessageName] = .init(bytes:nil)
                let journal=directory.appendingPathComponent(Self.actionEditJournal)
                try JSONEncoder().encode(RebaseActionEditJournal(version:3,before:before,after:after)).write(to:journal,options:.atomic)
                for name in before.keys where name != "git-rebase-todo" {try actionEditWrite(after[name]!,directory:directory,name:name)}
                try actionEditWrite(after["git-rebase-todo"]!,directory:directory,name:"git-rebase-todo")
                try FileManager.default.removeItem(at:journal)
            }
            return .init(output:"",exitCode:0,state:try rebaseState(),witnessedHead:head.hash,witnessedSession:phase.sessionIdentity)
        }
        return try recoverRebase("--continue")
    }
    private func completeRebaseConflictMessageOwned(amendMessage:String?,expected:RebaseState,expectedHead:String,editorExecutable:URL?,rawMessage:String?,returnAppliedReview:Bool=false,allowEmptyAmend:Bool=false)throws->RebaseExecution {
        var state=try rebaseState();try requireRebaseContinuation(state,expected:expected,expectedHead:expectedHead)
        guard var phase=state.conflictMessage else{throw RebaseFailure.changed}
        let directory=try rebasePath("rebase-merge")
        try requireConflictMessage(phase,state:state,directory:directory)
        if let failure=state.cleanCommitFailure {throw failure}
        if phase.phase == .complete {return try finishConflictMessage(phase,state:state,returnAppliedReview:returnAppliedReview)}
        if let editorExecutable {
            try protectAdoptedEmptyEntries(editorExecutable:editorExecutable)
            phase.files=try conflictMessageFiles(directory);try saveConflictMessage(phase,directory:directory);state=try rebaseState()
        }
        if let rawMessage {
            phase.rawMessage=rawMessage
            phase.needsAmend = !GitReferenceName.equal(rawMessage.trimmingCharacters(in:.whitespacesAndNewlines),phase.originalMessage.trimmingCharacters(in:.whitespacesAndNewlines))
            try saveConflictMessage(phase,directory:directory)
        }
        var output=""
        if phase.needsAmend {
            guard !phase.rawMessage.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw RebaseFailure.message}
            guard let amendMessage else{throw RebaseFailure.message}
            let file=try makeCommitMessageFile(amendMessage);defer{file.remove()}
            // --only with --amend and no paths is Git's message-only amendment;
            // its private index starts from HEAD, never unchecked staged rows.
            output=try commitReplayMessage(["commit","--amend","--only","-F",file.url.path]+(allowEmptyAmend ? ["--allow-empty"]:[]),message:amendMessage)
        } else if amendMessage != nil {throw RebaseFailure.changed}
        let finished=try finishConflictMessage(phase,state:state,returnAppliedReview:returnAppliedReview)
        return .init(output:output+finished.output,exitCode:finished.exitCode,state:finished.state,witnessedHead:finished.witnessedHead,witnessedSession:finished.witnessedSession)
    }
    public func beginRebaseConflictMessage(rawMessage:String,paths selection:some Sequence<String>,expected:RebaseState,expectedHead:String,allowEmpty:Bool=false,cancellation:OperationCancellation?=nil,onOutput:(@Sendable(GitOutputChunk)->Void)?=nil,indexPolicy:CommitCheckboxIndexPolicy?=nil, onProgress: (@Sendable (RebaseProgress) -> Void)? = nil)throws->RebaseExecution {
        let paths=GitPathSet(selection)
        return try withProtectedReplayIO(cancellation:cancellation,onOutput:onOutput,onProgress:onProgress) {try beginRebaseConflictMessageOwned(rawMessage:rawMessage,paths:paths,expected:expected,expectedHead:expectedHead,allowEmpty:allowEmpty,indexPolicy:indexPolicy)}
    }
    public func completeRebaseConflictMessage(amendMessage:String?,expected:RebaseState,expectedHead:String,cancellation:OperationCancellation?=nil,onOutput:(@Sendable(GitOutputChunk)->Void)?=nil,editorExecutable:URL?=nil,rawMessage:String?=nil, onProgress: (@Sendable (RebaseProgress) -> Void)? = nil)throws->RebaseExecution {
        try withReplayIO(cancellation:cancellation,onOutput:onOutput,onProgress:onProgress) {try completeRebaseConflictMessageOwned(amendMessage:amendMessage,expected:expected,expectedHead:expectedHead,editorExecutable:editorExecutable,rawMessage:rawMessage)}
    }
    private static let cleanCommitFailureName="turtlegit-clean-commit-failure.json"
    private static var cleanCommitFailureNames:[String] {Self.actionEditNames+["message","stopped-sha","amend","current-fixups","message-squash","message-fixup","orig-head","onto","head-name","turtlegit-session.json","turtlegit-split.json","turtlegit-squash-message.json","turtlegit-skipped-steps.json",Self.conflictMessageName]}
    private func cleanCommitFailureFiles(_ directory:URL)throws->[String:RebaseActionEditFile] {
        try Dictionary(uniqueKeysWithValues:Self.cleanCommitFailureNames.map {($0,try actionEditFile(directory,$0))})
    }
    private func cleanCommitFailureRecord(_ directory:URL)throws->RebaseCleanCommitFailure? {
        guard let bytes=try actionEditFile(directory,Self.cleanCommitFailureName).bytes else{return nil}
        let record=try JSONDecoder().decode(RebaseCleanCommitFailure.self,from:bytes)
        guard UUID(uuidString:record.id) != nil,
              record.exitCode != 0,GitCommandIdentity(record.command).command == "commit" else {throw RebaseFailure.plan}
        return record
    }
    private func cleanCommitFailureMatches(_ failure:RebaseCleanCommitFailure,state:RebaseState,directory:URL)throws->Bool {
        let identity=failure.identity
        var expectedFiles=failure.files
        if expectedFiles[Self.conflictMessageName] == nil {expectedFiles[Self.conflictMessageName] = .init(bytes:nil)}
        if expectedFiles[Self.noCommitSquashName] == nil {expectedFiles[Self.noCommitSquashName] = .init(bytes:nil)}
        guard state.active,!state.hasFailedPickCleanup,state.emptyMessageWarning == nil,
              state.originalHead==identity.originalHead,state.branch==identity.branch,state.onto==identity.onto,
              state.stoppedEntryID==identity.entry,state.currentStep==identity.step,
              try rebaseRevision("HEAD")==failure.head,
              try failedPickSessionIdentity(directory)==failure.sessionIdentity,
              try cleanCommitFailureFiles(directory)==expectedFiles else{return false}
        return failure.ignored || RebaseMessageIdentity(state:state,head:failure.head)==identity
    }
    private func clearCleanCommitFailure()throws {
        let url=try rebasePath("rebase-merge/"+Self.cleanCommitFailureName)
        if FileManager.default.fileExists(atPath:url.path) {try FileManager.default.removeItem(at:url)}
    }
    private func throwCleanReplayMessageFailure(_ failure:GitFailure,message:String)throws->Never {
            try replayCancellation?.check()
            // Pinned CheckCleanWorkTree ignores untracked files and submodules;
            // it may refresh index stat metadata, so capture witnesses afterward.
            guard try replayWorktreeIsClean() else{throw failure}
            try replayCancellation?.check()
            let state=try rebaseState(),head=try rebaseRevision("HEAD"),directory=try rebasePath("rebase-merge")
            guard state.emptyMessageWarning == nil,let identity=RebaseMessageIdentity(state:state,head:head),state.isEditPause || state.squashMessage != nil else {throw failure}
            let receipt=RebaseCleanCommitFailure(id:UUID().uuidString,identity:identity,head:head,message:message,
                diagnostic:failure.message,command:failure.arguments,exitCode:failure.code,
                sessionIdentity:try failedPickSessionIdentity(directory),files:try cleanCommitFailureFiles(directory),ignored:false)
            try JSONEncoder().encode(receipt).write(to:directory.appendingPathComponent(Self.cleanCommitFailureName),options:.atomic)
            throw receipt
    }
    private func commitReplayMessage(_ arguments:[String],message:String,environment:[String:String]=[:])throws->String {
        let result:GitResult
        do {
            result=try run(arguments,environmentOverrides:environment)
        } catch let failure as GitFailure {
            try throwCleanReplayMessageFailure(failure,message:message)
        }
        try clearCleanCommitFailure()
        return result.text
    }
    /// Completion shared by a successful Squash message commit and explicit
    /// Ignore. The requested text remains the next Squash accumulator; metadata
    /// is subsequently read from actual HEAD, exactly as the source does.
    private func completedReplayMessageFiles(state:RebaseState,message:String,head:String,files:[String:RebaseActionEditFile])throws->[String:RebaseActionEditFile] {
        var after=files
        if var continuation=state.split,continuation.conflictRecovery == true {
            continuation.expectedHead=head
            after["turtlegit-split.json"] = .init(bytes:try JSONEncoder().encode(continuation))
        }
        if state.squashMessage != nil {
            after["turtlegit-squash-message.json"] = .init(bytes:nil)
            guard let bytes=files["git-rebase-todo"]?.bytes,let text=String(data:bytes,encoding:.utf8) else{throw RebaseFailure.plan}
            var lines=text.components(separatedBy:"\n")
            if let first=lines.firstIndex(where:{!$0.isEmpty && !$0.hasPrefix("#")}),RebaseEditor.emptyMessageID(RebaseEditor.canonicalLine(lines[first]),applied:true)==state.stoppedEntryID {lines.remove(at:first)}
            after["git-rebase-todo"] = .init(bytes:Data(lines.joined(separator:"\n").utf8))
        }
        let next=state.remainingCommands.compactMap {$0.split(separator:" ").first.flatMap {RebaseAction(rawValue:String($0))}}.first {$0 != .skip}
        if (state.squashMessage != nil || next == .squash),let bytes=files["turtlegit-message-editor.json"]?.bytes {
            var configuration=try JSONDecoder().decode(RebaseMessageConfiguration.self,from:bytes)
            configuration.reviewedThrough=state.currentStep;configuration.reviewedMessage=message
            after["turtlegit-message-editor.json"] = .init(bytes:try JSONEncoder().encode(configuration))
        }
        return after
    }
    private func finishReplayMessage(state:RebaseState,message:String)throws {
        let directory=try rebasePath("rebase-merge")
        try withActionEditLock(directory) {
            let before=try cleanCommitFailureFiles(directory)
            let after=try completedReplayMessageFiles(state:state,message:message,head:rebaseRevision("HEAD"),files:before)
            for name in Self.cleanCommitFailureNames where name != "git-rebase-todo" && before[name] != after[name] {try actionEditWrite(after[name]!,directory:directory,name:name)}
            if before["git-rebase-todo"] != after["git-rebase-todo"] {try actionEditWrite(after["git-rebase-todo"]!,directory:directory,name:"git-rebase-todo")}
        }
    }
    public func retryRebaseCleanCommitFailure(_ failure:RebaseCleanCommitFailure,expected:RebaseState,expectedHead:String,cancellation:OperationCancellation?=nil)throws->RebaseState {
        try withReplayIO(cancellation:cancellation,onOutput:nil) {
            let state=try rebaseState(),directory=try rebasePath("rebase-merge")
            try requireRebaseContinuation(state,expected:expected,expectedHead:expectedHead)
            guard state.cleanCommitFailure==failure,expectedHead==failure.head,
                  try cleanCommitFailureMatches(failure,state:state,directory:directory) else {throw RebaseFailure.changed}
            try clearCleanCommitFailure()
            return try rebaseState()
        }
    }
    public func ignoreRebaseCleanCommitFailure(_ failure:RebaseCleanCommitFailure,expected:RebaseState,expectedHead:String,cancellation:OperationCancellation?=nil,onOutput:(@Sendable(GitOutputChunk)->Void)?=nil,editorExecutable:URL?=nil, onProgress: (@Sendable (RebaseProgress) -> Void)? = nil)throws->RebaseExecution {
        try withReplayIO(cancellation:cancellation,onOutput:onOutput,onProgress:onProgress) {
            let state=try rebaseState(),directory=try rebasePath("rebase-merge")
            try requireRebaseContinuation(state,expected:expected,expectedHead:expectedHead)
            guard state.cleanCommitFailure==failure,expectedHead==failure.head,
                  try cleanCommitFailureMatches(failure,state:state,directory:directory),
                  try replayWorktreeIsClean() else {throw RebaseFailure.changed}
            if var group=try noCommitGroup(directory) {
                guard group.phase == .approval else{throw RebaseFailure.changed}
                group.phase = .committed;group.committedHead=expectedHead;group.message=failure.message
                try withActionEditLock(directory) {
                    var before=try cleanCommitFailureFiles(directory)
                    before[Self.cleanCommitFailureName]=try actionEditFile(directory,Self.cleanCommitFailureName)
                    var after=before
                    after[Self.noCommitSquashName] = .init(bytes:try JSONEncoder().encode(group))
                    after[Self.cleanCommitFailureName] = .init(bytes:nil)
                    let journal=directory.appendingPathComponent(Self.actionEditJournal)
                    try JSONEncoder().encode(RebaseActionEditJournal(version:3,before:before,after:after)).write(to:journal,options:.atomic)
                    for name in before.keys where name != "git-rebase-todo" {try actionEditWrite(after[name]!,directory:directory,name:name)}
                    try actionEditWrite(after["git-rebase-todo"]!,directory:directory,name:"git-rebase-todo")
                    try FileManager.default.removeItem(at:journal)
                }
                return try finishNoCommitGroup(group)
            }

            if let phase=state.conflictMessage {
                try requireConflictMessage(phase,state:state,directory:directory)
                return try finishConflictMessage(phase,state:state)
            }
            // A tiny protected publication records completed message bookkeeping
            // before cancellable Git continuation. A cancelled continuation can
            // therefore resume without ever retrying the rejected amend.
            try withProtectedReplayIO(cancellation:nil,onOutput:nil) {
                try withActionEditLock(directory) {
                    try requireRebaseContinuation(rebaseState(),expected:state,expectedHead:failure.head)
                    guard try cleanCommitFailureMatches(failure,state:state,directory:directory) else{throw RebaseFailure.changed}
                    var before=failure.files
                    before[Self.cleanCommitFailureName] = try actionEditFile(directory,Self.cleanCommitFailureName)
                    var after=try completedReplayMessageFiles(state:state,message:failure.message,head:failure.head,files:failure.files)
                    if state.squashMessage != nil {
                        // Git otherwise treats a clean, unchanged HEAD as a
                        // skipped final fixup and can run commit again inside
                        // --continue. Ignore has explicitly accepted actual HEAD;
                        // retire that failed message command, never retry it.
                        for name in ["amend","current-fixups","message-squash","message-fixup"] {after[name] = .init(bytes:nil)}
                    }
                    var ignored=failure;ignored.ignored=true;ignored.files=after
                    after[Self.cleanCommitFailureName] = .init(bytes:try JSONEncoder().encode(ignored))
                    let journal=directory.appendingPathComponent(Self.actionEditJournal)
                    try JSONEncoder().encode(RebaseActionEditJournal(version:3,before:before,after:after)).write(to:journal,options:.atomic)
                    for name in before.keys where name != "git-rebase-todo" {try actionEditWrite(after[name]!,directory:directory,name:name)}
                    try actionEditWrite(after["git-rebase-todo"]!,directory:directory,name:"git-rebase-todo")
                    try FileManager.default.removeItem(at:journal)
                }
            }
            return try recoverRebase("--continue")
        }
    }
    private static let actionEditNames = ["git-rebase-todo", "done", "turtlegit-replay-identities.json", "turtlegit-message-editor.json", "turtlegit-cherry-pick.json", "turtlegit-adopted-plan.json","turtlegit-no-commit-squash.json"]
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
            let legacy=ordinary.subtracting([Self.noCommitSquashName])
            let bases=[ordinary,ordinary.subtracting([Self.adoptedPlanName]),legacy,legacy.subtracting([Self.adoptedPlanName])]
            let cleanNames=Set(Self.cleanCommitFailureNames+[Self.cleanCommitFailureName])
            guard (1...3).contains(journal.version),names == Set(journal.after.keys),
                  (journal.version==3 ? names==cleanNames || names==cleanNames.subtracting([Self.conflictMessageName]) || names==cleanNames.subtracting([Self.noCommitSquashName]) || names==cleanNames.subtracting([Self.conflictMessageName,Self.noCommitSquashName]) : bases.contains(where:{base in names==base || journal.version==2 && (names==base.union(["message","stopped-sha"]) || names==base.union([Self.failedPickIntentName]))})),
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
            guard state.conflictMessage == nil,state.cleanCommitFailure == nil,!state.hasIgnoredCleanCommitFailure else {throw RebaseFailure.changed}
            let head = try rebaseRevision("HEAD"), files = try actionEditFiles(directory)
            let identities=replayIdentities(directory)
            let adoption:RebaseAdoptionProjection? = identities.isEmpty || files[Self.adoptedPlanName]?.bytes != nil ? try adoptionProjection(directory,cancellation:cancellation):nil
            let replay = try adoption?.rows ?? rebaseReplayEntries()
            guard files["git-rebase-todo"]?.bytes != nil,
                  !replay.isEmpty, Set(replay.map(\.id)).count == replay.count else { throw RebaseFailure.plan }
            try requireRebaseContinuation(rebaseState(), expected: state, expectedHead: head)
            guard files == (try actionEditFiles(directory)) else { throw RebaseFailure.changed }
            return RebaseActionEditSnapshot(state: state, head: head, replay: replay, directory: directory, files: files, adoption: adoption?.plan)
        }
    }
    /// Change selected future occurrences without altering the stopped commit,
    /// HEAD, index, worktree, messages being edited, or completed commands.
    public func changePendingRebaseActions(_ action: RebaseAction, ids: Set<String>, expected: RebaseActionEditSnapshot, changes: [String: RebaseAction] = [:], mainlines: [String: Int] = [:],
                                          editorExecutable: URL, retaining previous: RebaseConflictIdentity? = nil, cancellation: OperationCancellation? = nil) throws -> RebaseSessionSnapshot {
        try withReplayIO(cancellation: cancellation, onOutput: nil) {
            let directory = try rebasePath("rebase-merge")
            guard expected.state.conflictMessage == nil,expected.state.cleanCommitFailure == nil,!expected.state.hasIgnoredCleanCommitFailure else {throw RebaseFailure.changed}
            guard directory == expected.directory, Set(changes.keys).isSubset(of: ids), Set(mainlines.keys).isSubset(of: ids), !ids.isEmpty, ids.isSubset(of: Set(expected.replay.map(\.id))) else { throw RebaseFailure.plan }
            try withActionEditLock(directory) {
                try requireRebaseContinuation(rebaseState(), expected: expected.state, expectedHead: expected.head)
                guard expected.files == (try actionEditFiles(directory)) else { throw RebaseFailure.changed }
                if expected.adoption != nil {
                    try changeAdoptedPendingActions(action,ids:ids,expected:expected,changes:changes,editorExecutable:editorExecutable)
                    return
                }
                var identities = try JSONDecoder().decode([RebaseReplayIdentity].self, from: expected.files["turtlegit-replay-identities.json"]!.bytes!)
                guard identities.map(\.id) == expected.replay.map(\.id) else { throw RebaseFailure.plan }
                var rows = expected.replay
                for index in rows.indices {
                    let stored = identities[index].action.flatMap(RebaseAction.init(rawValue:)) ?? rows[index].action
                    identities[index].action=stored.rawValue;identities[index].emptySubject=rows[index].commit.hasEmptyReplaySubject
                    if FileManager.default.fileExists(atPath:directory.appendingPathComponent("turtlegit-structural-plan").path) {identities[index].structuralMerge=rows[index].commit.parents.count>1}
                    rows[index].action = stored;rows[index].deferredMainline=identities[index].deferredMainline==true
                }
                let oldRows = rows
                for index in rows.indices where ids.contains(rows[index].id) && rows[index].progress == .pending {
                    let requested = changes[rows[index].id] ?? action
                    if requested == .squash && (index == 0 || !expected.state.isCherryPick && rows[index].commit.parents.count > 1) { continue }
                    rows[index].action = requested; identities[index].action = requested.rawValue
                }
                if rows.map(\.action) == oldRows.map(\.action) { return }
                guard rows.first?.action != .squash else { throw RebaseFailure.squash }
                var todo = String(decoding: expected.files["git-rebase-todo"]!.bytes!, as: UTF8.self)
                let normalizedDone = try checkedCheckpointDone(directory, files: expected.files)
                let done = normalizedDone ?? String(decoding: expected.files["done"]?.bytes ?? Data(), as: UTF8.self)
                if normalizedDone != nil {
                    var pending = todo.components(separatedBy:"\n")
                    if let first = pending.firstIndex(where: { !$0.isEmpty && !$0.hasPrefix("#") }) { pending.remove(at:first) }
                    todo = pending.joined(separator:"\n")
                }
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
                        guard let mainline = mainlines[rows[index].id] ?? rows[index].mainline else {
                            rows[index].deferredMainline=true;identities[index].deferredMainline=true
                            newCommands[index][1]=commit.hash
                            continue
                        }
                        guard (1...commit.parents.count).contains(mainline) else{throw RebaseFailure.mainline}
                        if mainlines[rows[index].id] != nil {rows[index].deferredMainline=false;identities[index].deferredMainline=false}
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
                        var custom=try RebaseEditor.mergeStructuralReferenceUpdates(generated:done+"\n"+todo,custom:structuralRebaseTodo(plan)).todo
                        let config=try expected.files["turtlegit-message-editor.json"]?.bytes.map {try JSONDecoder().decode(RebaseMessageConfiguration.self,from:$0)}
                        let archives=config?.structuralControls ?? []
                        for archive in archives {custom=try structuralNoCommitTodo(custom,cursor:archive.cursor)}
                        let active=try noCommitGroup(directory)
                        if let cursor=active?.topology,!archives.contains(where:{$0.groupID==active?.id}) {custom=try structuralNoCommitTodo(custom,cursor:cursor)}
                        if archives.isEmpty,active==nil,let data=expected.state.split?.structuralControlCursor {
                            custom=try structuralNoCommitTodo(custom,cursor:JSONDecoder().decode(RebaseNoCommitTopology.self,from:data))
                        }
                        let completed=Set(done.components(separatedBy:"\n").compactMap {RebaseEditor.completedStructuralResult($0)?.id})
                        custom=custom.components(separatedBy:"\n").filter {line in RebaseEditor.structuralResultID(line).map {!completed.contains($0)} ?? true}.joined(separator:"\n")
                        return custom
                    }
                    // Non-native structural/custom todo commands are preserved by
                    // refusing a receipt that cannot be reproduced exactly.
                    guard execution.count == values.count else { throw RebaseFailure.plan }
                    let deferred=RebaseEditor.deferredSquashPositions(values),orphans=RebaseEditor.orphanSquashPositions(values)
                    let custom = try values.indices.map { index -> String in
                        let fields = execution[index], hash = fields[1]
                        let original = originalHash(hash)
                        guard values[index].commit.hash.hasPrefix(original) else { throw RebaseFailure.changed }
                        return RebaseEditor.executionLines(values[index], hash: hash, subject: fields.dropFirst(2).joined(separator: " "),deferSquash:deferred.contains(index),noCommitSquash:orphans.contains(index)).joined(separator: "\n")
                    }.joined(separator: "\n") + "\n"
                    let applied=Set((try noCommitGroup(directory))?.applied ?? [])
                    let protectedCustom=custom.components(separatedBy:"\n").filter {line in RebaseEditor.emptyMessageID(line,applied:true).map { !applied.contains($0) } ?? true}.joined(separator:"\n")
                    var positions: [String: Int] = [:]
                    for index in execution.indices where positions[execution[index][1]] == nil { positions[execution[index][1]] = index }
                    return try RebaseEditor.mergeReferenceUpdates(generated: done + "\n" + todo, custom: protectedCustom, originalPositions: positions).todo
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
                let deferred=RebaseEditor.deferredSquashPositions(rows),orphans=RebaseEditor.orphanSquashPositions(rows)
                for index in identities.indices {identities[index].deferredSquash=deferred.contains(index);identities[index].noCommitSquash=orphans.contains(index)}
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
                if let normalizedDone { after["done"] = .init(bytes:Data(normalizedDone.utf8)) }
                after["git-rebase-todo"] = RebaseActionEditFile(bytes: newTodo)
                after["turtlegit-replay-identities.json"] = RebaseActionEditFile(bytes: try JSONEncoder().encode(identities))
                let oldConfig = try expected.files["turtlegit-message-editor.json"]?.bytes.map { try JSONDecoder().decode(RebaseMessageConfiguration.self, from: $0) }
                if expected.state.isCherryPick { after["turtlegit-cherry-pick.json"] = RebaseActionEditFile(bytes: try JSONEncoder().encode(mapping)) }
                var messages = try oldConfig?.messages ?? (structural ? rows.map { $0.commit.message } : newCommands.map { try rebaseCommit($0[1]).message })
                if !structural {
                    guard messages.count == newCommands.count else { throw RebaseFailure.plan }
                    for index in newCommands.indices where newCommands[index][1] != commands[index][1] { messages[index] = try rebaseCommit(newCommands[index][1]).message }
                }
                var config = try RebaseMessageConfiguration(editorCommand: oldConfig?.editorCommand ?? RebaseEditor.messageCommand(executable: editorExecutable), datePolicy: oldConfig?.datePolicy ?? .first,
                    dates: oldConfig?.dates ?? rows.map { $0.commit.date }, actions: rows.map { $0.action.rawValue }, messages: messages, commitEncoding: oldConfig?.commitEncoding ?? commitMessageEncodingName())
                config.reviewedThrough = oldConfig?.reviewedThrough
                config.reviewedMessage = oldConfig?.reviewedMessage
                config.structuralControls=oldConfig?.structuralControls
                after["turtlegit-message-editor.json"] = RebaseActionEditFile(bytes: try JSONEncoder().encode(config))
                try replayCancellation?.check()
                guard expected.files == (try actionEditFiles(directory)) else { throw RebaseFailure.changed }
                let journal = RebaseActionEditJournal(version: normalizedDone == nil ? 1 : 2, before: expected.files, after: after)
                let journalURL = directory.appendingPathComponent(Self.actionEditJournal)
                try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
                // No cancellation point inside publication. The final todo write
                // chooses one complete side of this recoverable transaction.
                do {
                    for name in Self.actionEditNames where name != "git-rebase-todo" && (name != "done" || normalizedDone != nil) { try actionEditWrite(after[name]!, directory: directory, name: name) }
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
                // Older failed-Pick intents omit metadata introduced after
                // their action-edit schema. Upgrade only absent optional files;
                // present files and explicit captured bytes remain strict witnesses.
                var reviewedFiles=pending.files
                for name in [Self.adoptedPlanName,Self.noCommitSquashName] where reviewedFiles[name]==nil && files[name]?.bytes==nil {
                    reviewedFiles[name] = .init(bytes:nil)
                }
                guard reviewedFiles==files,pending.index==payload.index,pending.worktree==payload.worktree else {throw RebaseFailure.changed}
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
                                  cancellation: OperationCancellation? = nil,onOutput: (@Sendable (GitOutputChunk)->Void)? = nil,onProgress: (@Sendable (RebaseProgress)->Void)? = nil) throws -> RebaseExecution {
        try withReplayIO(cancellation:cancellation,onOutput:onOutput,onProgress:onProgress) {
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

/// An adopted Git plan keeps Git's own labels, reset/merge topology and command
/// spelling. It is not converted to TurtleGit's structural-plan generator.
fileprivate struct RebaseAdoptedPlan: Codable, Sendable {
    let version: Int
    let structural: Bool
    let originals: [String: String]
    let merges: Set<String>
}
fileprivate struct RebaseAdoptionProjection {
    var rows: [RebaseEntry]
    let plan: RebaseAdoptedPlan
    let todo: [String]
    let done: [String]
    let slots: [Int: Int]
}
extension GitRepository {
    fileprivate static let adoptedPlanName = "turtlegit-adopted-plan.json"
    private func adoptedPlan(_ directory: URL) throws -> RebaseAdoptedPlan? {
        guard let bytes = try actionEditFile(directory, Self.adoptedPlanName).bytes else { return nil }
        let value = try JSONDecoder().decode(RebaseAdoptedPlan.self, from: bytes)
        guard bytes.count<=16_777_216,value.version == 1 else { throw RebaseFailure.plan }; return value
    }
    /// Logical command positions exclude structural labels/resets. This same
    /// projection is used before and after adoption, preserving draft identities.
    fileprivate static func adoptionCommands(_ text: String) -> [[String]] {
        text.components(separatedBy: "\n").compactMap { raw in
            let line = RebaseEditor.canonicalLine(raw.trimmingCharacters(in: .whitespaces))
            guard !line.isEmpty,!line.hasPrefix("#") else { return nil }
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let command=fields.first,RebaseAction(rawValue:command) != nil || command == "merge" else {return nil}
            return fields
        }
    }
    private func adoptionProjection(_ directory: URL, cancellation: OperationCancellation? = nil) throws -> RebaseAdoptionProjection {
        try cancellation?.check()
        let doneData=try actionEditFile(directory,"done").bytes ?? Data(),todoData=try actionEditFile(directory,"git-rebase-todo").bytes
        guard let todoData,doneData.count+todoData.count<=8_388_608,
              let doneText=String(data:doneData,encoding:.utf8),let todoText=String(data:todoData,encoding:.utf8) else {throw RebaseFailure.plan}
        let previous=try adoptedPlan(directory),identities=replayIdentities(directory)
        let skipped=(try? JSONDecoder().decode(Set<Int>.self,from:Data(contentsOf:directory.appendingPathComponent("turtlegit-skipped-steps.json")))) ?? []
        // A missing native structural archive may erase label-only merge rows;
        // do not guess those original identities from arbitrary labels.
        guard !identities.isEmpty || !FileManager.default.fileExists(atPath:directory.appendingPathComponent("turtlegit-structural-plan").path) else {throw RebaseFailure.plan}
        guard !identities.isEmpty || !FileManager.default.fileExists(atPath:directory.appendingPathComponent("turtlegit-cherry-pick.json").path) else {throw RebaseFailure.plan}
        let done=doneText.components(separatedBy:"\n"),todo=todoText.components(separatedBy:"\n")
        var labels=Set<String>(),rows:[RebaseEntry]=[],originals:[String:String]=[:],merges=Set<String>(),slots:[Int:Int]=[:],counts:[String:Int]=[:]
        var completedCount=0,structural=false,lastWasMerge=false,deferredGroup=false,precedingCommand=""
        func label(_ value:String)->Bool {!value.isEmpty && value.utf8.count<=1024 && !value.contains(where:{$0.isWhitespace || $0 == "\0"}) && !value.hasPrefix("-")}
        for (isDone,lines) in [(true,done),(false,todo)] {
            for (lineIndex,raw) in lines.enumerated() {
                try cancellation?.check()
                let line=RebaseEditor.canonicalLine(raw.trimmingCharacters(in:.whitespaces))
                if line.isEmpty || line.hasPrefix("#") {continue}
                let fields=line.split(whereSeparator:\.isWhitespace).map(String.init)
                guard let command=fields.first else {continue}
                let control=Array(fields.prefix(while:{$0 != "#"}))
                let previousCommand=precedingCommand
                precedingCommand=line
                if let id=RebaseEditor.structuralResultID(line) {
                    guard identities.contains(where:{$0.id==id && $0.structuralMerge==true}) else{throw RebaseFailure.plan}
                    precedingCommand=line;continue
                }
                if let id=RebaseEditor.sourceSquashID(line) {
                    guard identities.contains(where:{$0.id==id && $0.noCommitSquash==true}) else{throw RebaseFailure.plan}
                    continue
                }
                if let id=RebaseEditor.mainlineID(line) {
                    guard identities.contains(where:{$0.id==id && $0.deferredMainline==true}),FileManager.default.fileExists(atPath:directory.appendingPathComponent("turtlegit-cherry-pick.json").path) else{throw RebaseFailure.plan}
                    continue
                }
                if let id = RebaseEditor.emptyMessageID(line) ?? RebaseEditor.emptyMessageID(line, applied: true) {
                    guard identities.contains(where: { $0.id == id && $0.emptySubject == true }),
                          previous != nil || FileManager.default.fileExists(atPath: directory.appendingPathComponent("turtlegit-message-editor.json").path) else { throw RebaseFailure.plan }
                    continue
                }
                if command == "label" {
                    guard control.count==2,label(control[1]),labels.insert(control[1]).inserted else {throw RebaseFailure.plan}
                    structural=true;lastWasMerge=false;continue
                }
                if command == "reset" {
                    guard control.count==2,label(control[1]) else {throw RebaseFailure.plan}
                    if !labels.contains(control[1]) {_ = try rebaseRevision(control[1],cancellation:cancellation)}
                    structural=true;lastWasMerge=false;continue
                }
                if command == "update-ref" {
                    guard control.count==2,control[1].hasPrefix("refs/heads/") else {throw RebaseFailure.plan}
                    _ = try run(["check-ref-format",control[1]],cancellation:cancellation);lastWasMerge=false;continue
                }
                if command == "break" {
                    guard control.count==1,lastWasMerge else {throw RebaseFailure.plan};lastWasMerge=false;continue
                }
                let isMerge=command == "merge"
                let hash:String,action:RebaseAction
                if isMerge {
                    guard fields.count>=4,fields[1]=="-C",fields.dropFirst(3).first != "#" else {throw RebaseFailure.plan}
                    for target in fields.dropFirst(3).prefix(while:{$0 != "#"}) {guard label(target),labels.contains(target) || (try? rebaseRevision(target,cancellation:cancellation)) != nil else {throw RebaseFailure.plan}}
                    hash=try rebaseRevision(fields[2],cancellation:cancellation);action = .pick;structural=true
                } else {
                    guard let parsed=RebaseAction(rawValue:command),fields.count>=2 else {throw RebaseFailure.plan}
                    hash=try rebaseRevision(fields[1],cancellation:cancellation);action=parsed
                }
                guard rows.count<100_000 else {throw RebaseFailure.plan}
                let occurrence=counts[hash,default:0];counts[hash]=occurrence+1
                var row=RebaseEntry(commit:try rebaseCommit(hash,cancellation:cancellation),action:action)
                row.occurrence=occurrence
                if identities.indices.contains(rows.count) {
                    let identity=identities[rows.count]
                    guard GitReferenceName.equal(identity.hash,hash),identity.occurrence==occurrence else {throw RebaseFailure.changed}
                    row.action=identity.action.flatMap(RebaseAction.init(rawValue:)) ?? action
                    // Git retains the original done command after --skip.
                    // Later action publication may already have persisted its
                    // displayed Skip, while the raw completed bytes stay intact.
                    let deferredDrop = !isDone && action == .skip && identity.deferredMainline==true && identity.mainline==nil && row.action != .skip && RebaseEditor.mainlineID(previousCommand)==identity.id
                    if identity.action != RebaseAction.skip.rawValue {
                        if identity.action != RebaseAction.squash.rawValue {deferredGroup=false}
                        if identity.deferredMainline==true && identity.mainline==nil {deferredGroup=true}
                    }
                    let deferredSquash = !isDone && action == .skip && row.action == .squash && identity.deferredSquash==true && deferredGroup
                    if !isMerge,row.action != action,identity.executionAction != action.rawValue,!deferredDrop,!deferredSquash,!(identity.noCommitSquash==true && action == .skip && RebaseEditor.sourceSquashID(previousCommand)==identity.id),!(isDone && skipped.contains(rows.count+1) && row.action == .skip) {throw RebaseFailure.changed}
                    row.mainline=identity.mainline;row.deferredMainline=identity.deferredMainline==true;row.originalEmptySubject=identity.emptySubject
                }
                if skipped.contains(rows.count+1) {row.action = .skip}
                if let previous {
                    guard previous.originals[row.id] != nil else {throw RebaseFailure.changed}
                    originals[row.id]=previous.originals[row.id]
                    if previous.merges.contains(row.id) {merges.insert(row.id)}
                }else{originals[row.id]=raw;if isMerge {merges.insert(row.id)}}
                if !isDone {slots[lineIndex]=rows.count}
                rows.append(row);if isDone {completedCount += 1};lastWasMerge=isMerge
            }
        }
        let warningID = done.reversed().first(where: { !$0.isEmpty && !$0.hasPrefix("#") }).flatMap { RebaseEditor.emptyMessageID($0) }
        let warningIndex = warningID.flatMap { id in rows.firstIndex(where: { $0.id == id }) }
        guard !rows.isEmpty,completedCount>0 || warningIndex != nil,identities.isEmpty || identities.count==rows.count else {throw RebaseFailure.plan}
        if let previous {guard previous.originals.count==rows.count else {throw RebaseFailure.changed}}
        let current = warningIndex ?? (completedCount-1)
        for index in rows.indices {rows[index].progress=index<current ? .completed:index==current ? .current:.pending}
        return RebaseAdoptionProjection(rows:rows,plan:previous ?? RebaseAdoptedPlan(version:1,structural:structural,originals:originals,merges:merges),todo:todo,done:done,slots:slots)
    }
    private func protectAdoptedEmptyEntries(editorExecutable: URL) throws {
        let directory = try rebasePath("rebase-merge")
        let identities = replayIdentities(directory)
        let adopted = FileManager.default.fileExists(atPath: directory.appendingPathComponent(Self.adoptedPlanName).path)
        guard identities.isEmpty || adopted || identities.contains(where: { $0.emptySubject == nil }) else { return }
        let expected: RebaseActionEditSnapshot
        let hasConflictMessage=try rebaseState().conflictMessage != nil
        if !identities.isEmpty && !adopted || hasConflictMessage {
            let state = try rebaseState(), head = try rebaseRevision("HEAD"), files = try actionEditFiles(directory)
            let projection = try adoptionProjection(directory, cancellation: replayCancellation)
            expected = RebaseActionEditSnapshot(state: state, head: head, replay: projection.rows, directory: directory, files: files, adoption: projection.plan)
        } else { expected = try rebaseActionEditSnapshot(cancellation: replayCancellation) }
        guard expected.replay.contains(where: { $0.progress == .pending && $0.requiresEmptyMessageReview }) else { return }
        try withActionEditLock(directory) {
            try requireRebaseContinuation(rebaseState(), expected: expected.state, expectedHead: expected.head)
            guard expected.files == (try actionEditFiles(directory)) else { throw RebaseFailure.changed }
            try changeAdoptedPendingActions(.pick, ids: [], expected: expected, changes: [:], editorExecutable: editorExecutable)
        }
    }
    private func changeAdoptedPendingActions(_ action:RebaseAction,ids:Set<String>,expected:RebaseActionEditSnapshot,changes:[String:RebaseAction],editorExecutable:URL) throws {
        guard let plan=expected.adoption else {throw RebaseFailure.plan}
        let projection=try adoptionProjection(expected.directory,cancellation:replayCancellation)
        guard projection.rows.map({[$0.id,$0.action.rawValue]})==expected.replay.map({[$0.id,$0.action.rawValue]}) else {throw RebaseFailure.changed}
        var rows=projection.rows
        for index in rows.indices where ids.contains(rows[index].id) && rows[index].progress == .pending {
            let requested=changes[rows[index].id] ?? action
            if requested == .squash && (index==0 || rows[index].commit.parents.count>1) {continue}
            if requested == .squash,plan.structural {
                guard let slot=projection.slots.first(where:{$0.value==index})?.key else {throw RebaseFailure.plan}
                let preceding=projection.done+Array(projection.todo.prefix(slot))
                var found=false
                for raw in preceding.reversed() {
                    let command=RebaseEditor.canonicalLine(raw.trimmingCharacters(in:.whitespaces)).split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                    if command.isEmpty || command.hasPrefix("#") || command=="drop" {continue}
                    guard ["pick","edit","squash"].contains(command) else {throw RebaseFailure.preservePlan}
                    found=true;break
                }
                guard found else {throw RebaseFailure.preservePlan}
            }
            rows[index].action=requested
        }
        guard rows.first?.action != .squash else {throw RebaseFailure.squash}
        let needsProtection = rows.contains { $0.progress == .pending && $0.requiresEmptyMessageReview && !projection.todo.contains(RebaseEditor.emptyMessagePrefix + $0.id) }
        guard rows.map(\.action) != projection.rows.map(\.action) || needsProtection else {return}
        let deferred=RebaseEditor.deferredSquashPositions(rows),orphans=RebaseEditor.orphanSquashPositions(rows)
        var lines=projection.todo,result:[String]=[]
        for lineIndex in lines.indices {
            let line=lines[lineIndex]
            if let id=RebaseEditor.sourceSquashID(line) {
                guard projection.rows.contains(where:{$0.id==id}) else{throw RebaseFailure.plan}
                continue
            }
            if let id=RebaseEditor.mainlineID(line) {
                guard projection.rows.contains(where:{$0.id==id && $0.deferredMainline}) else{throw RebaseFailure.plan}
                continue
            }
            if let id = RebaseEditor.emptyMessageID(line) ?? RebaseEditor.emptyMessageID(line, applied: true) {
                guard projection.rows.contains(where: { $0.id == id && $0.originalEmptySubject == true }) else { throw RebaseFailure.plan }
                continue
            }
            guard let index=projection.slots[lineIndex] else {result.append(line);continue}
            let row=rows[index]
            guard rows[index].progress == .pending else {result.append(line);continue}
            if plan.merges.contains(row.id) {
                guard let original=plan.originals[row.id] else {throw RebaseFailure.plan}
                if row.action == .skip {result.append("drop "+row.commit.hash)}
                else {
                    if row.requiresEmptyMessageReview { result.append(RebaseEditor.emptyMessagePrefix + row.id) }
                    result.append(original);if row.executionAction == .edit {result.append("break")}
                }
                // Remove only the break owned by this merge Edit; ordinary
                // structural commands and all completed bytes stay untouched.
                if projection.rows[index].executionAction == .edit,lines.indices.contains(lineIndex+1),RebaseEditor.canonicalLine(lines[lineIndex+1].trimmingCharacters(in:.whitespaces))=="break" {lines[lineIndex+1]=""}
            }else{
                let fields=RebaseEditor.canonicalLine(line.trimmingCharacters(in:.whitespaces)).split(separator:" ",maxSplits:1)
                guard fields.count==2 else {throw RebaseFailure.plan}
                let body=String(fields[1]).split(separator:" ",maxSplits:1).map(String.init)
                guard let hash=body.first else {throw RebaseFailure.plan}
                result.append(contentsOf:RebaseEditor.executionLines(row,hash:hash,subject:body.dropFirst().joined(separator:" "),deferSquash:deferred.contains(index),noCommitSquash:orphans.contains(index)))
            }
        }
        var after=expected.files
        after["git-rebase-todo"]=RebaseActionEditFile(bytes:Data(result.joined(separator:"\n").utf8))
        after[Self.adoptedPlanName]=RebaseActionEditFile(bytes:try JSONEncoder().encode(plan))
        after["turtlegit-replay-identities.json"]=RebaseActionEditFile(bytes:try JSONEncoder().encode(rows.enumerated().map{index,row in RebaseReplayIdentity(hash:row.commit.hash,occurrence:row.occurrence,action:row.action.rawValue,mainline:row.mainline,deferredMainline:row.deferredMainline,deferredSquash:deferred.contains(index),noCommitSquash:orphans.contains(index),emptySubject:row.commit.hasEmptyReplaySubject)}))
        let old=try expected.files["turtlegit-message-editor.json"]?.bytes.map{try JSONDecoder().decode(RebaseMessageConfiguration.self,from:$0)}
        var config=try RebaseMessageConfiguration(editorCommand:old?.editorCommand ?? RebaseEditor.messageCommand(executable:editorExecutable),datePolicy:old?.datePolicy ?? .first,dates:old?.dates ?? rows.map{$0.commit.date},actions:rows.map{$0.action.rawValue},messages:old?.messages ?? rows.map{$0.commit.message},commitEncoding:old?.commitEncoding ?? commitMessageEncodingName())
        config.reviewedThrough=old?.reviewedThrough
        config.reviewedMessage=old?.reviewedMessage
        config.structuralControls=old?.structuralControls
        after["turtlegit-message-editor.json"]=RebaseActionEditFile(bytes:try JSONEncoder().encode(config))
        try replayCancellation?.check();guard expected.files == (try actionEditFiles(expected.directory)) else {throw RebaseFailure.changed}
        let journal=RebaseActionEditJournal(version:1,before:expected.files,after:after),url=expected.directory.appendingPathComponent(Self.actionEditJournal)
        try JSONEncoder().encode(journal).write(to:url,options:.atomic)
        for name in Self.actionEditNames where name != "git-rebase-todo" && name != "done" {try actionEditWrite(after[name]!,directory:expected.directory,name:name)}
        try actionEditWrite(after["git-rebase-todo"]!,directory:expected.directory,name:"git-rebase-todo")
        try FileManager.default.removeItem(at:url)
    }
}
