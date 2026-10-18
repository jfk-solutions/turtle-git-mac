// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Source command identities, not translated captions or native selectors.
public enum HistoryContextCommand: String, CaseIterable, Sendable {
    case compareWorkingTree = "ID_COMPARE", commit = "ID_COMMIT", mergeAbort = "ID_MERGE_ABORT"
    case blamePrevious = "ID_BLAMEPREVIOUS", unifiedDiff = "ID_GNUDIFF1", comparePrevious = "ID_COMPAREWITHPREVIOUS", blame = "ID_BLAME"
    case stashSave = "ID_STASH_SAVE", stashPop = "ID_STASH_POP", stashList = "ID_STASH_LIST"
    case bisectGood = "ID_BISECTGOOD", bisectBad = "ID_BISECTBAD", bisectSkip = "ID_BISECTSKIP", bisectReset = "ID_BISECTRESET"
    case pull = "ID_PULL", fetch = "ID_FETCH", submoduleUpdate = "ID_SUBMODULE_UPDATE", cleanup = "ID_CLEANUP"
    case showLog = "ID_LOG", repositoryBrowser = "ID_REPOBROWSE", merge = "ID_MERGEREV", reset = "ID_RESET"
    case switchBranch = "ID_SWITCHBRANCH", checkout = "ID_SWITCHTOREV", createBranch = "ID_CREATE_BRANCH", createTag = "ID_CREATE_TAG"
    case rebase = "ID_REBASE_TO_VERSION", export = "ID_EXPORT", revert = "ID_REVERTREV", editNote = "ID_EDITNOTE"
    case compareTwo = "ID_COMPARETWO", unifiedDiffTwo = "ID_GNUDIFF2", compareChangeSets = "ID_COMPARETWOCOMMITCHANGES"
    case combine = "ID_COMBINE_COMMIT", cherryPick = "ID_CHERRY_PICK", createPatch = "ID_CREATE_PATCH", bisectStart = "ID_BISECTSTART"
    case push = "ID_PUSH", svnDCommit = "ID_SVNDCOMMIT", delete = "ID_DELETE", rollup = "ID_TOGGLE_ROLLUP"
    case copyClipboard = "ID_COPYCLIPBOARD", find = "ID_FINDENTRY", showBranches = "ID_SHOWBRANCHES"
    case rebasePick = "ID_REBASE_PICK", rebaseSquash = "ID_REBASE_SQUASH", rebaseEdit = "ID_REBASE_EDIT", rebaseSkip = "ID_REBASE_SKIP"
    case revertToRevision = "ID_REVERTTOREV"
}

/// Mirrors CGitLogListBase::hideFromContextMenu and the two source consumers.
/// Mask membership never makes an unavailable Git operation available.
public struct HistoryContextMenuPolicy: Equatable, Sendable {
    public var commands: Set<HistoryContextCommand>
    public init(commands: Set<HistoryContextCommand>) { self.commands = commands }
    public static let log = Self(commands: Set(HistoryContextCommand.allCases).subtracting([
        .rebasePick, .rebaseSquash, .rebaseEdit, .rebaseSkip, .showLog, .blame, .blamePrevious
    ]))
    public static let blame = Self(commands: [
        .comparePrevious, .unifiedDiff, .blamePrevious, .copyClipboard, .export,
        .createBranch, .createTag, .checkout, .showLog, .showBranches, .repositoryBrowser
    ])
    public static let rebase = Self(commands: log.commands.subtracting([
        .cherryPick, .checkout, .reset, .revert, .merge, .rebase, .revertToRevision, .combine, .rollup
    ]))
    public mutating func hide(_ commands: Set<HistoryContextCommand>, exclusivelyShow: Bool = false) {
        if exclusivelyShow { self.commands.formIntersection(commands) }
        else { self.commands.subtract(commands) }
    }
    public func contains(_ command: HistoryContextCommand) -> Bool { commands.contains(command) }
    /// ID_LOG is intentionally exceptional: source permits a named revision or
    /// Shift even when its consumer mask does not include the ordinary command.
    public func showsLog(hasReferences: Bool, isStash: Bool, extended: Bool) -> Bool {
        contains(.showLog) || (!isStash && hasReferences) || extended
    }
    /// Filtering retains source insertion order, including repeated parent actions.
    public func filtering(_ ordered: [HistoryContextCommand]) -> [HistoryContextCommand] {
        ordered.filter(contains)
    }
}
