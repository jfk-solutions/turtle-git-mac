import AppKit

/// Original upstream artwork. ICO retains its multiple sizes and alpha masks; AppKit
/// chooses a representation for the display scale. Only the monochrome cherry-pick
/// glyph uses template tinting so its shape stays visible in both macOS appearances.
public enum MenuIcon: String, CaseIterable {
    case turtle = "TortoiseSmall", status = "menushowchanged", commit = "menucommit", log = "menulog"
    case compare = "menucompare", unifiedDiff = "menudiff", pull = "pull1", push = "Push", fetch = "menuupdate"
    case branch = "menucopy", tag = "tag", checkout = "menuswitch", merge = "menumerge", rebase = "menurebase"
    case rebasePick = "menupick", rebaseSkip = "menuskip", rebaseEdit = "menuedit", rebaseSquash = "menusquash", reverse = "switch"
    case stash = "menushelve", stashPop = "menuunshelve", clone = "menucheckout", initialize = "menucreaterepos"
    case add = "menuadd", revert = "menurevert", reset = "reset", cherryPick = "cherry-pick", copy = "copy"
    case help = "menuhelp", settings = "menusettings"
    case open = "open", explore = "explorer"
    case normal = "status-normal", modified = "status-modified", added = "status-added", deleted = "status-deleted"
    case conflicted = "status-conflict", ignored = "status-ignored", untracked = "status-unversioned"
    public func image(size: CGFloat = 16) -> NSImage? {
        #if SWIFT_PACKAGE
        let bundle = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("TurtleGitMac_TurtleGitCore.bundle")) } ?? Bundle.module
        #else
        let bundle = Bundle(for: IconResourceBundle.self)
        #endif
        guard let url = bundle.url(forResource: rawValue, withExtension: "ico", subdirectory: "Icons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: size, height: size); image.isTemplate = self == .cherryPick
        return image
    }
}
private final class IconResourceBundle: NSObject {}

extension RepositoryAction {
    public var icon: MenuIcon {
        switch self {
        case .status: return .status
        case .commit: return .commit
        case .log: return .log
        case .diff: return .compare
        case .pull: return .pull
        case .push: return .push
        case .fetch: return .fetch
        case .branch: return .branch
        case .tag: return .tag
        case .switchBranch: return .checkout
        case .merge: return .merge
        case .rebase: return .rebase
        case .stash: return .stash
        case .stashPop: return .stashPop
        case .clone: return .clone
        case .initialize: return .initialize
        }
    }
}

extension FileState {
    public var icon: MenuIcon {
        switch self {
        case .normal: return .normal
        case .modified: return .modified
        case .added: return .added
        case .deleted: return .deleted
        case .untracked: return .untracked
        case .ignored: return .ignored
        case .conflicted: return .conflicted
        }
    }
}
