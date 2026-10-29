import Foundation

public enum SettingsPublicationChannel: String, CaseIterable, Sendable {
    case cachePersistence, cacheTray, finderMenu
}

/// Durable intent to publish already accepted settings. Payloads are deliberately
/// not stored: a retry reconstructs the current accepted settings. A publisher
/// must also verify that its captured payload is still current before completing.
/// The lock serializes helper instances in this process; UserDefaults is not a
/// cross-process compare-and-swap store.
public struct SettingsPublicationIntents {
    private let defaults: UserDefaults
    private static let lock = NSLock()
    private static let legacyCachePendingKey = "TurtleGit.CacheSavePublicationPending"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ channel: SettingsPublicationChannel) -> String {
        "TurtleGit.SettingsPublicationIntent." + channel.rawValue
    }
    private func pendingLocked(_ channel: SettingsPublicationChannel) -> String? {
        if let token = defaults.string(forKey: key(channel)), UUID(uuidString: token) != nil { return token }
        guard channel == .cachePersistence, defaults.bool(forKey: Self.legacyCachePendingKey) else { return nil }
        let token = UUID().uuidString
        defaults.set(token, forKey: key(channel))
        // Retain the legacy true witness until successful completion. An
        // interrupted migration must conservatively retain the retry intent.
        return token
    }
    /// Every accepted publication request gets a fresh identity, even if an
    /// older publication of the same channel has not completed yet.
    @discardableResult public func request(_ channel: SettingsPublicationChannel) -> String {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let token = UUID().uuidString
        defaults.set(token, forKey: key(channel))
        return token
    }
    public func pending(_ channel: SettingsPublicationChannel) -> String? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return pendingLocked(channel)
    }
    /// A stale/duplicate completion cannot clear a newer accepted request.
    @discardableResult public func complete(_ channel: SettingsPublicationChannel, request: String) -> Bool {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard pendingLocked(channel) == request else { return false }
        defaults.removeObject(forKey: key(channel))
        if channel == .cachePersistence { defaults.removeObject(forKey: Self.legacyCachePendingKey) }
        return true
    }
}

public struct AdvancedSettingDefinition: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case boolean(Bool), dword(UInt32) }
    public let name: String
    public let kind: Kind
    public func accepts(_ text: String) -> Bool {
        if text.isEmpty { return true }
        switch kind {
        case .boolean: return text == "true" || text == "false"
        case .dword: return text.utf8.allSatisfy { (48...57).contains($0) }
        }
    }
    public static let all: [AdvancedSettingDefinition] = [
        .init(name: "AutoCompleteMinChars", kind: .dword(3)),
        .init(name: "AutocompleteParseMaxSize", kind: .dword(300000)),
        .init(name: "AutocompleteParseUnversioned", kind: .boolean(false)),
        .init(name: "AutocompleteRemovesExtensions", kind: .boolean(false)),
        .init(name: "BlockStatus", kind: .boolean(false)),
        .init(name: "CacheTrayIcon", kind: .boolean(false)),
        .init(name: "CacheSave", kind: .boolean(true)),
        .init(name: "ConflictDontGuessBranchNames", kind: .boolean(false)),
        .init(name: "CygwinHack", kind: .boolean(false)),
        .init(name: "Debug", kind: .boolean(false)),
        .init(name: "DebugOutputString", kind: .boolean(false)),
        .init(name: "DialogTitles", kind: .dword(0)),
        .init(name: "DiffSimilarityIndexThreshold", kind: .dword(50)),
        .init(name: "DownloadAnimation", kind: .boolean(true)),
        .init(name: "FetchVerbose", kind: .boolean(true)),
        .init(name: "FullRowSelect", kind: .boolean(true)),
        .init(name: "GroupTaskbarIconsPerRepo", kind: .dword(3)),
        .init(name: "GroupTaskbarIconsPerRepoOverlay", kind: .boolean(true)),
        .init(name: "LogFontForFileListCtrl", kind: .boolean(false)),
        .init(name: "LogFontForLogCtrl", kind: .boolean(false)),
        .init(name: "LogTooManyItemsThreshold", kind: .dword(1000)),
        .init(name: "LogIncludeBoundaryCommits", kind: .boolean(false)),
        .init(name: "LogIncludeWorkingTreeChanges", kind: .boolean(true)),
        .init(name: "LogShowSuperProjectSubmodulePointer", kind: .boolean(true)),
        .init(name: "MaxRefHistoryItems", kind: .dword(5)),
        .init(name: "ModifyExplorerTitle", kind: .boolean(true)),
        .init(name: "Msys2Hack", kind: .boolean(false)),
        .init(name: "NamedRemoteFetchAll", kind: .boolean(true)),
        .init(name: "NoSortLocalBranchesFirst", kind: .boolean(false)),
        .init(name: "NumDiffWarning", kind: .dword(10)),
        .init(name: "OverlaysCaseSensitive", kind: .boolean(true)),
        .init(name: "ProgressDlgLinesLimit", kind: .dword(50000)),
        .init(name: "ReaddUnselectedAddedFilesAfterCommit", kind: .boolean(true)),
        .init(name: "RefreshFileListAfterResolvingConflict", kind: .boolean(true)),
        .init(name: "RememberFileListPosition", kind: .boolean(true)),
        .init(name: "SanitizeCommitMsg", kind: .boolean(true)),
        .init(name: "ScintillaDirect2D", kind: .boolean(false)),
        .init(name: "ShellMenuAccelerators", kind: .boolean(true)),
        .init(name: "ShortHashLengthForHyperLinkInLogMessage", kind: .dword(8)),
        .init(name: "ShowContextMenuIcons", kind: .boolean(true)),
        .init(name: "ShowAppContextMenuIcons", kind: .boolean(true)),
        .init(name: "ShowListBackgroundImage", kind: .boolean(true)),
        .init(name: "ShowListFullPathTooltip", kind: .boolean(true)),
        .init(name: "SquashDate", kind: .dword(0)),
        .init(name: "StyleCommitMessages", kind: .boolean(true)),
        .init(name: "StyleGitOutput", kind: .boolean(true)),
        .init(name: "TGitCacheCheckContentMaxSize", kind: .dword(10240)),
        .init(name: "UseCustomWordBreak", kind: .dword(2)),
        .init(name: "UseLibgit2", kind: .boolean(true)),
        .init(name: "VersionCheck", kind: .boolean(true)),
        .init(name: "VersionCheckPreview", kind: .boolean(false)),
        .init(name: "Win8SpellChecker", kind: .boolean(false)),
    ]
}

public enum AdvancedSettingsFailure: LocalizedError {
    case invalidValue(String)
    public var errorDescription: String? { switch self { case .invalidValue(let name): return "Invalid value for \(name)." } }
}

/// UserDefaults replaces registry storage; blank values remove the override.
public struct AdvancedSettingsStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func value(for setting: AdvancedSettingDefinition) -> String {
        let saved = (defaults.object(forKey: setting.name) as? NSNumber) ?? (setting.name == "NumDiffWarning" ? defaults.object(forKey: "TurtleGit.NumDiffWarning") as? NSNumber : nil)
        switch setting.kind {
        case .boolean(let fallback): return (saved?.boolValue ?? fallback) ? "true" : "false"
        case .dword(let fallback): return String(Int32(bitPattern: saved?.uint32Value ?? fallback))
        }
    }
    public func values() -> [String: String] { Dictionary(uniqueKeysWithValues: AdvancedSettingDefinition.all.map { ($0.name, value(for: $0)) }) }
    public func apply(_ edited: [String: String]) throws {
        let changed = AdvancedSettingDefinition.all.filter { edited[$0.name] != nil && edited[$0.name] != value(for: $0) }
        for setting in changed where !setting.accepts(edited[setting.name]!) { throw AdvancedSettingsFailure.invalidValue(setting.name) }
        for setting in changed {
            if setting.name == "NumDiffWarning" { defaults.removeObject(forKey: "TurtleGit.NumDiffWarning") }
            let text = edited[setting.name]!
            if text.isEmpty { defaults.removeObject(forKey: setting.name); continue }
            switch setting.kind {
            case .boolean: defaults.set(text == "true", forKey: setting.name)
            case .dword(let fallback):
                // Windows _wtol uses signed 32-bit LONG and saturates on overflow.
                let number = text.utf8.reduce(Int64(0)) { min(Int64(Int32.max), $0 * 10 + Int64($1 - 48)) }
                if (defaults.object(forKey: setting.name) as? NSNumber)?.uint32Value ?? fallback != UInt32(number) {
                    defaults.set(Int(number), forKey: setting.name)
                }
            }
        }
    }
}

/// DWORD interpretation follows the source registry consumers, including the
/// minimum-three multiple-diff safeguard and strict greater-than list threshold.
public struct AdvancedListBehavior: Sendable {
    public let fullRowSelect: Bool
    public let localBranchesFirst: Bool
    public let tooManyFiles: UInt32
    public let diffWarning: UInt32
    public init(defaults: UserDefaults = .standard) {
        fullRowSelect = ((defaults.object(forKey: "FullRowSelect") as? NSNumber)?.uint32Value ?? 1) != 0
        localBranchesFirst = !defaults.bool(forKey: "NoSortLocalBranchesFirst")
        tooManyFiles = (defaults.object(forKey: "LogTooManyItemsThreshold") as? NSNumber)?.uint32Value ?? 1000
        diffWarning = (defaults.object(forKey: "NumDiffWarning") as? NSNumber)?.uint32Value
            ?? (defaults.object(forKey: "TurtleGit.NumDiffWarning") as? NSNumber)?.uint32Value ?? 10
    }
    public func hidesFileList(count: Int) -> Bool { count > Int(tooManyFiles) }
    public func warnsBeforeDiffs(count: Int) -> Bool { count > Int(max(3, diffWarning)) }
}

/// Portable presentation policy for CAppUtils::FormatWindowTitle and status-list
/// info tips. macOS uses an ellipsis without splitting extended grapheme clusters
/// in place of Windows' PathCompactPathEx; the source UTF-16 budget is retained.
public struct RepositoryPresentationSettings {
    public let compactRepositoryTitle: Bool
    public let showFullPathTooltip: Bool
    public init(defaults: UserDefaults = .standard) {
        compactRepositoryTitle = (defaults.object(forKey: "DialogTitles") as? NSNumber)?.uint32Value == 1
        showFullPathTooltip = ((defaults.object(forKey: "ShowListFullPathTooltip") as? NSNumber)?.intValue ?? 1) == 1
    }
    public func title(repository: URL, location: URL? = nil, dialog: String) -> String {
        let root = repository.standardizedFileURL
        let path = (location ?? root).standardizedFileURL.path
        // A component boundary avoids treating a neighboring worktree as a child.
        let contained = path == root.path || path.hasPrefix(root.path == "/" ? "/" : root.path + "/")
        let parent = root.deletingLastPathComponent().path
        let prefix = parent == "/" ? "/" : parent + "/"
        let displayed = compactRepositoryTitle && contained && path != "/" && path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        let budget = max(1, 79 - dialog.utf16.count)
        return Self.compact(displayed, budget: budget) + " – " + dialog + " – TurtleGit"
    }
    public func fileTooltip(repository: URL, path: String) -> String? {
        guard showFullPathTooltip else { return nil }
        return repository.appendingPathComponent(path).standardizedFileURL.path
    }
    public static func scopedLocation(repository: URL, paths: [String], wholeProject: Bool) -> URL {
        guard !wholeProject, !paths.isEmpty else { return repository }
        if paths.count == 1 { return repository.appendingPathComponent(paths[0]) }
        let components = paths.map { $0.split(separator: "/").dropLast().map(String.init) }
        var common = components[0]
        for path in components.dropFirst() {
            common = Array(zip(common, path).prefix(while: { $0 == $1 }).map { $0.0 })
        }
        return common.reduce(repository) { $0.appendingPathComponent($1) }
    }
    private static func compact(_ path: String, budget: Int) -> String {
        guard path.utf16.count > budget else { return path }
        guard budget > 1 else { return "…" }
        var suffix = ""
        let suffixBudget = (budget - 1) * 2 / 3
        for character in path.reversed() {
            guard suffix.utf16.count + String(character).utf16.count <= suffixBudget else { break }
            suffix.insert(character, at: suffix.startIndex)
        }
        var prefix = ""
        for character in path {
            guard prefix.utf16.count + String(character).utf16.count + 1 + suffix.utf16.count <= budget else { break }
            prefix.append(character)
        }
        return prefix + "…" + suffix
    }
}

/// URL/path stops from Utils/MiscUI/EditWordBreak.cpp. Cocoa dispatches movement
/// directly, so the Windows USER callback-order workaround is not reproduced.
public struct GitInputWordBreak: Sendable {
    public let mode: UInt32
    public init(mode: UInt32 = 2) { self.mode = mode }
    public init(defaults: UserDefaults) {
        mode = (defaults.object(forKey:"UseCustomWordBreak") as? NSNumber)?.uint32Value ?? 2
    }
    public func enabled(combo: Bool) -> Bool { mode != 0 && (!combo || mode == 2) }
    public static func isDelimiter(_ text:[UInt16],at index:Int) -> Bool {
        guard text.indices.contains(index) else { return false }
        let value=text[index]
        if [UInt16(9),10,11,12,13,32].contains(value) {
            if value == 13 {
                var next=index
                while next+1<text.count && text[next] == 13 { next += 1;if text[next] == 10 { return false } }
            }
            return true
        }
        func scheme(_ offset:Int)->Bool {
            offset>=0 && offset+2<text.count && text[offset]==58 && text[offset+1]==47 && text[offset+2]==47
        }
        let punctuation=(33...47).contains(value) || (58...64).contains(value) || (91...96).contains(value) || (123...126).contains(value)
        return punctuation && !scheme(index) && !scheme(index-1)
    }
    public static func boundary(_ string:String,from position:Int,forward:Bool)->Int {
        let text=Array(string.utf16);var cursor=min(max(0,position),text.count)
        if forward {
            while cursor<text.count && !isDelimiter(text,at:cursor) { cursor += 1 }
            while cursor<text.count && isDelimiter(text,at:cursor) { cursor += 1 }
        } else {
            while cursor>0 && isDelimiter(text,at:cursor-1) { cursor -= 1 }
            while cursor>0 && !isDelimiter(text,at:cursor-1) { cursor -= 1 }
        }
        // Cocoa caret positions must not split an emoji or a combining sequence.
        let native=string as NSString
        if cursor>0 && cursor<native.length {
            let cluster=native.rangeOfComposedCharacterSequence(at:cursor)
            if cluster.location<cursor { return forward ? NSMaxRange(cluster):cluster.location }
        }
        return cursor
    }
}
