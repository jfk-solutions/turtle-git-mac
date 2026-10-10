import AppKit

public enum MenuPresentationSettings {
    public static func applicationContextIcons(defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: "ShowAppContextMenuIcons") as? NSNumber)?.boolValue ?? true
    }
}

/// Original upstream artwork. Ribbon BMP alpha is decoded explicitly; ICO retains
/// its multiple sizes and alpha masks. AppKit
/// chooses a representation for the display scale. Monochrome Log, Help and
/// cherry-pick glyphs use template tinting to remain visible in both appearances.
public enum MenuIcon: String, CaseIterable {
    case imageFitWidths = "fitwidths", imageFitHeights = "fitheights"
    case imagePrevious = "player_rew", imageNext = "player_fwd", imagePlay = "player_start", imageStop = "player_stop"
    case imageBlend = "blend"
    case imageOverlay = "overlap", imageLink = "link", imageFit = "fitinwindow", imageOriginal = "origsize"
    case imageZoomIn = "zoomin", imageZoomOut = "zoomout", imageInfo = "imginfo", imageVertical = "vertical", imageAlphaToggle = "alphatoggle"
    case completionFile = "file", completionSnippet = "snippet", completionCode = "code"
    case turtle = "TortoiseSmall", status = "menushowchanged", commit = "menucommit", log = "menulog"
    case blame = "TortoiseGitBlame"
    case revisionGraph = "menurevisiongraph"
    case bisect = "menubisect", bisectReset = "menubisectreset", bisectGood = "thumb_up", bisectBad = "thumb_down"
    case patch = "menupatch", sendMail = "menusendmail"
    case repositoryBrowser = "menurepobrowse", executableOverlay = "executableovl", symlinkOverlay = "symlinkovl", externalOverlay = "externalovl"
    case repositoryBackdrop = "RepoBrowserBackground", addBackdrop = "AddBackground"
    case compare = "menucompare", unifiedDiff = "menudiff", pull = "pull1", push = "Push", fetch = "menuupdate"
    case branch = "menucopy", tag = "tag", checkout = "menuswitch", merge = "menumerge", mergeAbort = "menumergeabort", rebase = "menurebase"
    case rebasePick = "menupick", rebaseSkip = "menuskip", rebaseEdit = "menuedit", rebaseSquash = "menusquash", reverse = "switch"
    case stash = "menushelve", stashPop = "menuunshelve", clone = "menucheckout", initialize = "menucreaterepos"
    case graphBar = "graph-bar", graphStackedBar = "graph-bar-stacked", graphLine = "graph-line", graphStackedLine = "graph-line-stacked", graphPie = "graph-pie"
    case clean = "menucleanup", sync = "menusync"
    case add = "menuadd", revert = "menurevert", reset = "reset", cherryPick = "cherry-pick", copy = "copy"
    case help = "menuhelp", settings = "menusettings", saveAs = "saveas"
    case open = "open", explore = "explorer", export = "menuexport", editor = "notepad"
    case rename = "menurename"
    case remove = "menudelete"
    case lock = "menulock", unlock = "menuunlock"
    case ignore = "menuignore"
    case restore = "restore", restoreOverlay = "restoreovl"
    case resolve = "menuresolve", editConflict = "menuconflict"
    case mergeSave = "Save", mergeSaveAs = "SaveAs", mergeResolved = "Check"
    case refresh = "refresh"
    case mergeReload = "Refresh"
    case mergeMarked = "linemarked"
    case mergePaste = "Paste"
    case mergeUndo = "Undo", mergeRedo = "Redo", mergeFind = "Search"
    case mergePreviousConflict = "UpRed", mergeNextConflict = "DownRed"
    case mergeUseMine = "UseMine", mergeUseTheirs = "UseTheirs"
    case mergeMineThenTheirs = "UseMineTheirs", mergeTheirsThenMine = "UseTheirsMine"
    case jumpUp = "jumpup", jumpDown = "jumpdown"
    case actionModified = "actionmodified", actionAdded = "actionadded", actionDeleted = "actiondeleted"
    case actionReplaced = "actionreplaced", actionConflicted = "actionconflicted", actionFetching = "actionfetching", actionError = "actionerror"
    case normal = "status-normal", modified = "status-modified", added = "status-added", deleted = "status-deleted"
    case conflicted = "status-conflict", ignored = "status-ignored", untracked = "status-unversioned"
    public func image(size: CGFloat = 16) -> NSImage? {
        #if SWIFT_PACKAGE
        let bundle = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("TurtleGitMac_TurtleGitCore.bundle")) } ?? Bundle.module
        #else
        let bundle = Bundle(for: IconResourceBundle.self)
        #endif
        let ribbon: Set<MenuIcon> = [.mergePaste,.mergeReload, .mergeSave, .mergeSaveAs, .mergeResolved, .mergeUndo, .mergeRedo, .mergeFind, .mergePreviousConflict, .mergeNextConflict, .mergeUseMine, .mergeUseTheirs, .mergeMineThenTheirs, .mergeTheirsThenMine]
        let isRibbon = ribbon.contains(self)
        guard let url = bundle.url(forResource: rawValue, withExtension: isRibbon ? "bmp" : "ico", subdirectory: "Icons"),
              let image = isRibbon ? Self.ribbonImage(at: url) : NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: size, height: size); image.isTemplate = [.cherryPick, .log, .help].contains(self)
        return image
    }
    public func contextImage(size: CGFloat = 16, defaults: UserDefaults = .standard) -> NSImage? {
        MenuPresentationSettings.applicationContextIcons(defaults: defaults) ? image(size: size) : nil
    }
    /// The upstream ribbon uses BI_RGB 32-bit BMPs with straight BGRA alpha.
    /// AppKit treats their fourth byte as padding, rendering transparent areas black.
    /// Decode that original alpha explicitly without modifying the bundled artwork.
    private static func ribbonImage(at url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url), data.count >= 54, data[0] == 0x42, data[1] == 0x4d else { return nil }
        func u32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | (UInt32(data[offset + $1]) << ($1 * 8)) }
        }
        let width = Int(Int32(bitPattern: u32(18))), signedHeight = Int(Int32(bitPattern: u32(22)))
        guard u32(14) >= 40, width > 0, width <= 4096, signedHeight != 0, abs(signedHeight) <= 4096,
              data[26] == 1, data[27] == 0, data[28] == 32, data[29] == 0, u32(30) == 0 else { return nil }
        let height = abs(signedHeight), offset = Int(u32(10)), stride = width * 4
        guard offset >= 54, offset <= data.count, stride * height <= data.count - offset,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied, bytesPerRow: stride, bitsPerPixel: 32),
              let destination = bitmap.bitmapData else { return nil }
        for y in 0..<height {
            let sourceRow = offset + (signedHeight > 0 ? height - y - 1 : y) * stride
            for x in 0..<width {
                let source = sourceRow + x * 4, target = y * stride + x * 4
                destination[target] = data[source + 2]; destination[target + 1] = data[source + 1]
                destination[target + 2] = data[source]; destination[target + 3] = data[source + 3]
            }
        }
        let image = NSImage(size: NSSize(width: width, height: height)); image.addRepresentation(bitmap)
        return image
    }
}
/// Tiles in the original IDR_REVGRAPHBAR resource, in toolbar command order.
/// The unused zoom-combo placeholder occupies tile 6 in the upstream strip.
public enum RevisionGraphToolbarIcon: Int, CaseIterable {
    case zoomIn = 0, zoomOut, zoom100, fitHeight, fitWidth, fitGraph
    case filter = 7, overview, find

    public func image() -> NSImage? { ColorKeyIconStrip.image(resource: "revgraphbar", tile: rawValue, size: 20) }
}

/// Original IDB_BITMAP_REFTYPE tiles used by CFindDlg, including its white mask.
public enum ReferenceTypeIcon: Int, CaseIterable {
    case tag = 0, localBranch, remoteBranch
    public init?(referenceName: String) {
        if referenceName.hasPrefix("refs/tags/") { self = .tag }
        else if referenceName.hasPrefix("refs/heads/") { self = .localBranch }
        else if referenceName.hasPrefix("refs/remotes/") { self = .remoteBranch }
        else { return nil }
    }
    public func image() -> NSImage? { ColorKeyIconStrip.image(resource: "reftype", tile: rawValue, size: 16, colorKey: [255, 255, 255]) }
}

private enum ColorKeyIconStrip {
    static func image(resource: String, tile: Int, size: Int, colorKey: [UInt8]? = nil) -> NSImage? {
        #if SWIFT_PACKAGE
        let bundle = Bundle.main.resourceURL.flatMap { Bundle(url: $0.appendingPathComponent("TurtleGitMac_TurtleGitCore.bundle")) } ?? Bundle.module
        #else
        let bundle = Bundle(for: IconResourceBundle.self)
        #endif
        guard let url = bundle.url(forResource: resource, withExtension: "bmp", subdirectory: "Icons"),
              let data = try? Data(contentsOf: url), data.count >= 54, data[0] == 0x42, data[1] == 0x4d else { return nil }
        func u32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | (UInt32(data[offset + $1]) << ($1 * 8)) }
        }
        let width = Int(Int32(bitPattern: u32(18))), signedHeight = Int(Int32(bitPattern: u32(22)))
        guard u32(14) >= 40, width > 0, width <= 4096, signedHeight == size,
              data[26] == 1, data[27] == 0, data[28] == 24, data[29] == 0, u32(30) == 0,
              tile >= 0, (tile + 1) * size <= width else { return nil }
        let offset = Int(u32(10)), stride = (width * 3 + 3) & ~3
        guard offset >= 54, offset <= data.count, stride * size <= data.count - offset,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: .alphaNonpremultiplied, bytesPerRow: size * 4, bitsPerPixel: 32),
              let pixels = bitmap.bitmapData else { return nil }
        // CImageList::Add uses the first BMP pixel as its exact RGB color key.
        let mask = colorKey ?? Array(data[offset..<offset + 3])
        guard mask.count == 3 else { return nil }
        for y in 0..<size {
            for x in 0..<size {
                let source = offset + (size - y - 1) * stride + (tile * size + x) * 3
                let target = y * size * 4 + x * 4
                pixels[target] = data[source + 2]; pixels[target + 1] = data[source + 1]; pixels[target + 2] = data[source]
                pixels[target + 3] = data[source] == mask[0] && data[source + 1] == mask[1] && data[source + 2] == mask[2] ? 0 : 255
            }
        }
        let image = NSImage(size: NSSize(width: size, height: size)); image.addRepresentation(bitmap)
        image.isTemplate = false
        return image
    }
}

private final class IconResourceBundle: NSObject {}

extension RepositoryAction {
    public var icon: MenuIcon {
        switch self {
        case .status: return .status
        case .commit: return .commit
        case .add, .submoduleAdd: return .add
        case .revert: return .revert
        case .clean: return .clean
        case .log, .stashList, .reflog: return .log
        case .revisionGraph: return .revisionGraph
        case .referenceBrowser, .repositoryBrowser: return .repositoryBrowser
        case .bisect, .bisectStart, .bisectSkip: return .bisect
        case .bisectGood: return .bisectGood
        case .bisectBad: return .bisectBad
        case .bisectReset: return .bisectReset
        case .export: return .export
        case .formatPatch, .requestPull: return .unifiedDiff
        case .importPatch: return .patch
        case .diff, .diffLater, .clearComparisonMark: return .compare
        case .pull: return .pull
        case .push: return .push
        case .submoduleSync: return .sync
        case .fetch, .submoduleUpdate: return .fetch
        case .branch, .worktreeCreate, .worktreeList: return .branch
        case .tag: return .tag
        case .switchBranch: return .checkout
        case .merge: return .merge
        case .mergeAbort: return .mergeAbort
        case .rebase: return .rebase
        case .stash: return .stash
        case .stashApply, .stashPop: return .stashPop
        case .clone: return .clone
        case .initialize: return .initialize
        case .rename: return .rename
        case .remove, .removeKeep: return .remove
        case .ignore, .ignoreMask, .ignoreDelete, .ignoreDeleteMask: return .ignore
        case .resolve, .resolveCurrent, .resolveMine, .resolveTheirs: return .resolve
        case .editConflict: return .editConflict
        case .reset: return .reset
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
