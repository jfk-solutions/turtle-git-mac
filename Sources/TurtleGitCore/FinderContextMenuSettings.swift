// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Foundation

public enum FinderCommandFailure: LocalizedError {
    case previousRevisionUnavailable, submodule, selection
    public var errorDescription: String? {
        switch self {
        case .previousRevisionUnavailable: return "No previous revision is available for this path."
        case .submodule: return "This folder is no longer a registered submodule."
        case .selection: return "Select one versioned file or folder."
        }
    }
}

/// Source menu IDs preserve grouped commands and unknown mask bits across edits.
public enum FinderMenuEntry: String, CaseIterable, Sendable {
    case clone = "Clone"
    case pull = "Pull"
    case fetch = "Fetch"
    case push = "Push"
    case sync = "Sync"
    case commit = "Commit"
    case svndCommit = "SVNDCommit"
    case svnRebase = "SVNRebase"
    case svnFetch = "SVNFetch"
    case svnIgnore = "SVNIgnore"
    case diff = "Diff"
    case diffLater = "DiffLater"
    case prevDiff = "PrevDiff"
    case log = "Log"
    case logSubmodule = "LogSubmodule"
    case refLog = "RefLog"
    case refBrowser = "RefBrowser"
    case daemon = "Daemon"
    case revisionGraph = "RevisionGraph"
    case repoBrowser = "RepoBrowser"
    case showChanged = "ShowChanged"
    case rebase = "Rebase"
    case stashSave = "StashSave"
    case stashApply = "StashApply"
    case stashPop = "StashPop"
    case stashList = "StashList"
    case bisect = "Bisect"
    case conflictEditor = "Conflicteditor"
    case resolve = "Resolve"
    case rename = "Rename"
    case remove = "Remove"
    case removeKeep = "RemoveKeep"
    case revert = "Revert"
    case cleanup = "Cleanup"
    case lfs = "LFS"
    case switchBranch = "Switch"
    case merge = "Merge"
    case branch = "Branch"
    case tag = "Tag"
    case export = "Export"
    case createRepo = "CreateRepo"
    case add = "Add"
    case blame = "Blame"
    case ignore = "Ignore"
    case worktree = "Worktree"
    case submoduleAdd = "SubmoduleAdd"
    case submoduleUpdate = "SubmoduleUpdate"
    case submoduleSync = "SubmoduleSync"
    case formatPatch = "FormatPatch"
    case importPatch = "ImportPatch"
    case applyPatch = "ApplyPatch"
    case sendMail = "Sendmail"
    case settings = "Settings"
    case help = "Help"
    case about = "About"
    public var mask: UInt64 {
        switch self {
        case .clone: return 0x0000002000000000
        case .pull: return 0x0000000800000000
        case .fetch: return 0x0000040000000000
        case .push: return 0x0000001000000000
        case .sync: return 0x0000000000000002
        case .commit: return 0x0000000000000004
        case .svndCommit: return 0x0000000010000000
        case .svnRebase: return 0x0000000008000000
        case .svnFetch: return 0x0080000000000000
        case .svnIgnore: return 0x0000000040000000
        case .diff: return 0x0000000000010000
        case .diffLater: return 0x0000020000000000
        case .prevDiff: return 0x0000000200000000
        case .log: return 0x0000000000020000
        case .logSubmodule: return 0x0000000100000000
        case .refLog: return 0x0000000000400000
        case .refBrowser: return 0x0000000000080000
        case .daemon: return 0x0200000000000000
        case .revisionGraph: return 0x0100000000000000
        case .repoBrowser: return 0x0000000001000000
        case .showChanged: return 0x0000000000100000
        case .rebase: return 0x0000080000000000
        case .stashSave: return 0x0000100000000000
        case .stashApply: return 0x0000200000000000
        case .stashPop: return 0x0002000000000000
        case .stashList: return 0x0000400000000000
        case .bisect: return 0x0008000000000000
        case .conflictEditor: return 0x0000000000040000
        case .resolve: return 0x0000000000000040
        case .rename: return 0x0000000000004000
        case .remove: return 0x0000000000002000
        case .removeKeep: return 0x0000000004000000
        case .revert: return 0x0000000000000010
        case .cleanup: return 0x0000000000000020
        case .lfs: return 0x1000000000000000
        case .switchBranch: return 0x0000000000000080
        case .merge: return 0x0000000000001000
        case .branch: return 0x0000000000000800
        case .tag: return 0x0000004000000000
        case .export: return 0x0000000000000200
        case .createRepo: return 0x0000000000000400
        case .add: return 0x0000000000000008
        case .blame: return 0x0000000000800000
        case .ignore: return 0x0000000000200000
        case .worktree: return 0x0400000000000000
        case .submoduleAdd: return 0x0000800000000000
        case .submoduleUpdate: return 0x0000000000008000
        case .submoduleSync: return 0x0001000000000000
        case .formatPatch: return 0x0000008000000000
        case .importPatch: return 0x0000010000000000
        case .applyPatch: return 0x0000000002000000
        case .sendMail: return 0x0000000000000100
        case .settings: return 0x2000000000000000
        case .help: return 0x4000000000000000
        case .about: return 0x8000000000000000
        }
    }
    public var title: String {
        switch self {
        case .clone: return "Clone..."
        case .pull: return "Pull..."
        case .fetch: return "Fetch..."
        case .push: return "Push..."
        case .sync: return "Sync..."
        case .commit: return "Commit..."
        case .svndCommit: return "SVN DCommit..."
        case .svnRebase: return "SVN Rebase"
        case .svnFetch: return "SVN Fetch"
        case .svnIgnore: return "Import SVN Ignore ..."
        case .diff: return "Diff"
        case .diffLater: return "Diff later"
        case .prevDiff: return "Diff with previous version"
        case .log: return "Show log"
        case .logSubmodule: return "Show log of this folder"
        case .refLog: return "Show RefLog"
        case .refBrowser: return "Browse References"
        case .daemon: return "Daemon"
        case .revisionGraph: return "Revision graph"
        case .repoBrowser: return "Repo-browser"
        case .showChanged: return "Check for modifications"
        case .rebase: return "Rebase..."
        case .stashSave: return "Stash changes"
        case .stashApply: return "Stash Apply"
        case .stashPop: return "Stash Pop"
        case .stashList: return "Stash List"
        case .bisect: return "Bisect start"
        case .conflictEditor: return "Edit conflicts"
        case .resolve: return "Resolve..."
        case .rename: return "Rename..."
        case .remove: return "Delete"
        case .removeKeep: return "Delete (keep local)"
        case .revert: return "Revert..."
        case .cleanup: return "Clean up..."
        case .lfs: return "LFS"
        case .switchBranch: return "Switch/Checkout..."
        case .merge: return "Merge..."
        case .branch: return "Create Branch..."
        case .tag: return "Create Tag..."
        case .export: return "Export..."
        case .createRepo: return "Create repository here..."
        case .add: return "Add..."
        case .blame: return "Blame"
        case .ignore: return "Add to ignore list"
        case .worktree: return "Worktrees"
        case .submoduleAdd: return "Submodule Add..."
        case .submoduleUpdate: return "Submodule Update..."
        case .submoduleSync: return "Submodule Sync"
        case .formatPatch: return "Create Patch Serial..."
        case .importPatch: return "Apply Patch Serial..."
        case .applyPatch: return "Review/apply single patch..."
        case .sendMail: return "Send Mail..."
        case .settings: return "Settings"
        case .help: return "Help"
        case .about: return "About"
        }
    }
    public var iconResource: String {
        switch self {
        case .clone: return "menucheckout"
        case .pull: return "pull1"
        case .fetch: return "menuupdate"
        case .push: return "Push"
        case .sync: return "menurelocate"
        case .commit: return "menucommit"
        case .svndCommit: return "menucommit"
        case .svnRebase: return "menurebase"
        case .svnFetch: return "menuupdate"
        case .svnIgnore: return "menuignore"
        case .diff: return "menucompare"
        case .diffLater: return "menucompare"
        case .prevDiff: return "menucompare"
        case .log: return "menulog"
        case .logSubmodule: return "menulog"
        case .refLog: return "menulog"
        case .refBrowser: return "menurepobrowse"
        case .daemon: return "menudaemon"
        case .revisionGraph: return "menurevisiongraph"
        case .repoBrowser: return "menurepobrowse"
        case .showChanged: return "menushowchanged"
        case .rebase: return "menurebase"
        case .stashSave: return "menushelve"
        case .stashApply: return "menuunshelve"
        case .stashPop: return "menuunshelve"
        case .stashList: return "menulog"
        case .bisect: return "menubisect"
        case .conflictEditor: return "menuconflict"
        case .resolve: return "menuresolve"
        case .rename: return "menurename"
        case .remove: return "menudelete"
        case .removeKeep: return "menudelete"
        case .revert: return "menurevert"
        case .cleanup: return "menucleanup"
        case .lfs: return "menulfs"
        case .switchBranch: return "menuswitch"
        case .merge: return "menumerge"
        case .branch: return "menucopy"
        case .tag: return "Tag"
        case .export: return "menuexport"
        case .createRepo: return "menucreaterepos"
        case .add: return "menuadd"
        case .blame: return "TortoiseGitBlame"
        case .ignore: return "menuignore"
        case .worktree: return "menucopy"
        case .submoduleAdd: return "menuadd"
        case .submoduleUpdate: return "menuupdate"
        case .submoduleSync: return "menusync"
        case .formatPatch: return "menudiff"
        case .importPatch: return "menupatch"
        case .applyPatch: return "menupatch"
        case .sendMail: return "menusendmail"
        case .settings: return "menusettings"
        case .help: return "menuhelp"
        case .about: return "menuabout"
        }
    }
    public func image(size: CGFloat = 16) -> NSImage? { MenuIcon.originalImage(resource: iconResource, size: size) }
    public static let defaultTopMask = sync.mask | createRepo.mask | clone.mask | commit.mask
    public static let defaultExtendedMask = svnIgnore.mask | stashApply.mask | submoduleSync.mask
    public static let allMask = allCases.reduce(UInt64(0)) { $0 | $1.mask }
    /// One preference controls every command sharing the source menu ID.
    public static func entry(for action: RepositoryAction) -> Self? {
        switch action {
        case .properties: return nil // macOS entry replaces Explorer's property-sheet tab, not a MenuInfo bit.
        case .lfs, .lfsLocks, .lfsLock, .lfsUnlock: return .lfs
        case .svnDCommit: return .svndCommit
        case .svnRebase: return .svnRebase
        case .svnFetch: return .svnFetch
        case .svnIgnore: return .svnIgnore
        case .reviewPatch: return .applyPatch
        case .sendMail: return .sendMail
        case .daemon: return .daemon
        case .synchronize: return .sync
        case .blame: return .blame
        case .previousDiff: return .prevDiff
        case .logSubmodule: return .logSubmodule
        case .settings: return .settings
        case .help: return .help
        case .about: return .about
        case .clone: return .clone
        case .pull: return .pull
        case .fetch: return .fetch
        case .push: return .push
        case .commit: return .commit
        case .diff: return .diff
        case .diffLater, .clearComparisonMark: return .diffLater
        case .log: return .log
        case .reflog: return .refLog
        case .referenceBrowser: return .refBrowser
        case .revisionGraph: return .revisionGraph
        case .repositoryBrowser: return .repoBrowser
        case .status: return .showChanged
        case .rebase: return .rebase
        case .stash: return .stashSave
        case .stashApply: return .stashApply
        case .stashPop: return .stashPop
        case .stashList: return .stashList
        case .bisect, .bisectStart, .bisectGood, .bisectBad, .bisectSkip, .bisectReset: return .bisect
        case .editConflict: return .conflictEditor
        case .resolve, .resolveCurrent, .resolveMine, .resolveTheirs: return .resolve
        case .rename: return .rename
        case .remove: return .remove
        case .removeKeep: return .removeKeep
        case .revert: return .revert
        case .clean: return .cleanup
        case .switchBranch: return .switchBranch
        case .merge, .mergeAbort: return .merge
        case .branch: return .branch
        case .tag: return .tag
        case .export: return .export
        case .initialize: return .createRepo
        case .add: return .add
        case .ignore, .ignoreMask, .ignoreDelete, .ignoreDeleteMask: return .ignore
        case .worktreeList, .worktreeCreate: return .worktree
        case .submoduleAdd: return .submoduleAdd
        case .submoduleUpdate: return .submoduleUpdate
        case .submoduleSync: return .submoduleSync
        case .formatPatch: return .formatPatch
        case .importPatch: return .importPatch
        case .requestPull, .reset, .move: return nil
        }
    }
    public var availableInFinder: Bool { true }
}
