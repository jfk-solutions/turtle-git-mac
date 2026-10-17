// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Darwin
import AppKit

public enum FinderVolumeKind: String, Codable, CaseIterable, Sendable { case fixed, removable, network, optical, ram, unknown }
public enum FinderOverlayCacheMode: Int, Codable, Sendable { case none = 0, standard = 1 }
public enum FinderOverlayIconSet: String, Codable, CaseIterable, Sendable {
    case blip = "Blip", blipClean = "Blip Clean", cvsClassic = "CVSClassic", dechenesVista = "DechenesVista", dechenesXp = "DechenesXp"
    case flat = "Flat", function = "Function", illustration = "Illustration", modern = "Modern", mufWin7 = "MufWin7", professional = "Professional"
    case ribbon = "Ribbon", straight = "Straight", subclipse = "Subclipse", win10 = "Win10", xpStyle = "XPStyle"
}
public enum FinderOverlayBadge: String, CaseIterable, Sendable {
    case normal, modified, added, deleted, untracked, ignored, conflicted, skipWorktree, assumeUnchanged
    public var icon: MenuIcon {
        switch self {
        case .skipWorktree: return .skipWorktreeOverlay
        case .assumeUnchanged: return .assumeUnchangedOverlay
        default: return FileState(rawValue: rawValue)!.icon
        }
    }
    public var title: String { self == .skipWorktree ? "Skip worktree" : self == .assumeUnchanged ? "Assume unchanged" : rawValue.capitalized }
    public func image(set: FinderOverlayIconSet, size: CGFloat = 16) -> NSImage? {
        let filenames: [Self: String] = [.normal: "NormalIcon", .modified: "ModifiedIcon", .added: "AddedIcon", .deleted: "DeletedIcon", .untracked: "UnversionedIcon", .ignored: "IgnoredIcon", .conflicted: "ConflictIcon", .skipWorktree: "LockedIcon", .assumeUnchanged: "ReadOnlyIcon"]
        return MenuIcon.overlayImage(filename: filenames[self]!, set: set.rawValue, size: size)
    }
}
public struct FinderIndexFlags: Codable, Equatable, Sendable {
    public let skipWorktree: Bool, assumeUnchanged: Bool
    public init(skipWorktree: Bool = false, assumeUnchanged: Bool = false) { self.skipWorktree = skipWorktree; self.assumeUnchanged = assumeUnchanged }
}
extension GitRepository {
    public func finderIndexFlags(cancellation: OperationCancellation? = nil) throws -> GitPathMap<FinderIndexFlags> {
        var flags: GitPathMap<FinderIndexFlags> = [:]
        for record in try run(["ls-files", "-v", "-z"], cancellation: cancellation).stdout.split(separator: 0) {
            guard record.count >= 3 else { throw GitConfigurationFailure.output }
            let bytes = Array(record), code = bytes[0]
            guard bytes[1] == 32 else { throw GitConfigurationFailure.output }
            let assume = (97...122).contains(code), skip = code == 83 || code == 115
            if assume || skip {
                let path = String(decoding: bytes.dropFirst(2), as: UTF8.self)
                flags[root.path + "/" + path] = .init(skipWorktree: skip, assumeUnchanged: assume)
            }
        }
        return flags
    }
}
public struct FinderOverlaySettings: Codable, Equatable, Sendable {
    public var cacheMode: FinderOverlayCacheMode = .standard
    public var unversionedAsModified = false
    public var recurseSubmodules = false
    public var showExcludedAsNormal = true
    public var volumes: Set<FinderVolumeKind> = [.fixed]
    public var excludePaths = ""
    public var includePaths = ""
    public var hiddenStates: Set<FileState> = []
    public var showSkipWorktree = true
    public var showAssumeUnchanged = true
    public var iconSet: FinderOverlayIconSet = .xpStyle
    public init() {}
    // Include/exclude rules can distinguish canonically equivalent spellings on
    // case-sensitive volumes; draft equality must retain those exact bytes too.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.cacheMode == rhs.cacheMode && lhs.unversionedAsModified == rhs.unversionedAsModified &&
        lhs.recurseSubmodules == rhs.recurseSubmodules && lhs.showExcludedAsNormal == rhs.showExcludedAsNormal &&
        lhs.volumes == rhs.volumes && lhs.excludePaths.utf8.elementsEqual(rhs.excludePaths.utf8) &&
        lhs.includePaths.utf8.elementsEqual(rhs.includePaths.utf8) && lhs.hiddenStates == rhs.hiddenStates &&
        lhs.showSkipWorktree == rhs.showSkipWorktree && lhs.showAssumeUnchanged == rhs.showAssumeUnchanged && lhs.iconSet == rhs.iconSet
    }
    private enum CodingKeys: String, CodingKey { case cacheMode, unversionedAsModified, recurseSubmodules, showExcludedAsNormal, volumes, excludePaths, includePaths, hiddenStates, showSkipWorktree, showAssumeUnchanged, iconSet }
    public init(from decoder: Decoder) throws {
        self.init(); let values = try decoder.container(keyedBy: CodingKeys.self)
        cacheMode = try values.decodeIfPresent(FinderOverlayCacheMode.self, forKey: .cacheMode) ?? .standard
        unversionedAsModified = try values.decodeIfPresent(Bool.self, forKey: .unversionedAsModified) ?? false
        recurseSubmodules = try values.decodeIfPresent(Bool.self, forKey: .recurseSubmodules) ?? false
        showExcludedAsNormal = try values.decodeIfPresent(Bool.self, forKey: .showExcludedAsNormal) ?? true
        volumes = try values.decodeIfPresent(Set<FinderVolumeKind>.self, forKey: .volumes) ?? [.fixed]
        excludePaths = try values.decodeIfPresent(String.self, forKey: .excludePaths) ?? ""
        includePaths = try values.decodeIfPresent(String.self, forKey: .includePaths) ?? ""
        hiddenStates = try values.decodeIfPresent(Set<FileState>.self, forKey: .hiddenStates) ?? []
        showSkipWorktree = try values.decodeIfPresent(Bool.self, forKey: .showSkipWorktree) ?? true
        showAssumeUnchanged = try values.decodeIfPresent(Bool.self, forKey: .showAssumeUnchanged) ?? true
        iconSet = try values.decodeIfPresent(FinderOverlayIconSet.self, forKey: .iconSet) ?? .xpStyle
    }
    public static var sharedURL: URL? { FinderIntegration.container?.appendingPathComponent("overlay-settings.json") }
    public static func from(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "TurtleGit.FinderOverlaySettings"), let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }; return settings
    }
    public static func read(from url: URL? = sharedURL) -> Self {
        guard let url, let data = try? Data(contentsOf: url), let settings = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }; return settings
    }
    /// The helper's cache menu can update shared presentation while the app is
    /// closed. Production reads honor that accepted state before local defaults.
    public static func effective(defaults: UserDefaults = .standard, shared: URL? = nil) -> Self {
        let url = shared ?? (defaults === UserDefaults.standard ? sharedURL : nil)
        if let url, let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Self.self, from: data), value.valid { return value }
        return from(defaults: defaults)
    }
    /// Read the latest complete record before changing this one field. A corrupt
    /// record fails without replacing unrelated overlay preferences.
    public static func updateCacheMode(_ mode: FinderOverlayCacheMode, at url: URL) throws {
        var value = Self()
        if FileManager.default.fileExists(atPath: url.path) { value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
        guard value.valid else { throw GitConfigurationFailure.invalidValue }
        value.cacheMode = mode; _ = try value.write(to: url)
    }
    public var pathPolicy: FinderOverlayPathPolicy { FinderOverlayPathPolicy(exclude: excludePaths, include: includePaths) }
    public var valid: Bool { pathPolicy.issue == nil }
    @discardableResult public func write(to url: URL? = sharedURL) throws -> Bool {
        guard valid else { throw GitConfigurationFailure.invalidValue }
        guard let url else { return false }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic); return true
    }
    public func save(to defaults: UserDefaults = .standard) throws {
        guard valid else { throw GitConfigurationFailure.invalidValue }
        defaults.set(try JSONEncoder().encode(self), forKey: "TurtleGit.FinderOverlaySettings")
    }
    /// Source terminal '*' means recursive and '?' means this path only.
    /// More specific paths win; equal include/exclude specifications prefer include.
    public func allows(_ path: String, volume: FinderVolumeKind, caseSensitive: Bool = true) -> Bool {
        pathPolicy.allows(path, fallback: volumes.contains(volume), caseSensitive: caseSensitive)
    }
    public static func volumeKind(for url: URL) -> FinderVolumeKind {
        var info = statfs()
        if statfs(url.path, &info) == 0 {
            let name = withUnsafePointer(to: &info.f_fstypename) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
            if ["cd9660", "udf"].contains(name) { return .optical }
            if ["ramfs", "tmpfs"].contains(name) { return .ram }
        }
        guard let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsRemovableKey, .volumeIsInternalKey]) else { return .unknown }
        if values.volumeIsLocal == false { return .network }
        if values.volumeIsRemovable == true { return .removable }
        if values.volumeIsLocal == true { return .fixed }
        return .unknown
    }
    /// Badge projection stays independent of the snapshot used for context-menu
    /// eligibility. No Git command runs in the extension.
    public func badges(snapshot: FinderSnapshot, volume: (String) -> FinderVolumeKind, isDirectory: (String) -> Bool, caseSensitive: (String) -> Bool = { _ in true }) -> [String: FileState] {
        projectedBadges(snapshot: snapshot, volume: volume, isDirectory: isDirectory, caseSensitive: caseSensitive, policy: pathPolicy)
    }
    private func projectedBadges(snapshot: FinderSnapshot, volume: (String) -> FinderVolumeKind, isDirectory: (String) -> Bool, caseSensitive: (String) -> Bool, policy: FinderOverlayPathPolicy) -> [String: FileState] {
        let roots = snapshot.roots.sorted { $0.count > $1.count }
        let priority: [FileState: Int] = [.normal: 0, .ignored: 1, .untracked: 2, .added: 3, .deleted: 4, .modified: 5, .conflicted: 6]
        var badges: [String: FileState] = [:], folders = Set(roots)
        if cacheMode == .none {
            for path in (snapshot.overlayEntries ?? snapshot.states).keys {
                guard let root = roots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
                if isDirectory(path) { folders.insert(path) }
                var parent = URL(fileURLWithPath: path).deletingLastPathComponent()
                while parent.path == root || parent.path.hasPrefix(root + "/") {
                    folders.insert(parent.path); if parent.path == root { break }; parent.deleteLastPathComponent()
                }
            }
            badges = Dictionary(uniqueKeysWithValues: folders.map { ($0, .normal) })
        }
        else {
            for (path, state) in snapshot.overlayEntries ?? snapshot.states {
                guard let root = roots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
                if priority[state, default: 0] >= priority[badges[path] ?? .normal, default: 0] { badges[path] = state }
                var parent = URL(fileURLWithPath: path).deletingLastPathComponent()
                let contribution: FileState = state == .untracked ? (unversionedAsModified ? .modified : .normal) : state == .ignored ? .normal : state
                while parent.path == root || parent.path.hasPrefix(root + "/") {
                    folders.insert(parent.path)
                    if priority[contribution, default: 0] >= priority[badges[parent.path] ?? .normal, default: 0] { badges[parent.path] = contribution }
                    if parent.path == root { break }; parent.deleteLastPathComponent()
                }
            }
            for root in roots { badges[root] = badges[root] ?? .normal }
            if recurseSubmodules {
                for root in roots {
                    guard let parentRoot = snapshot.repositories[root]?.submoduleParentRoot, let state = badges[root] else { continue }
                    var parent = URL(fileURLWithPath: root).deletingLastPathComponent()
                    while parent.path == parentRoot || parent.path.hasPrefix(parentRoot + "/") {
                        folders.insert(parent.path)
                        if priority[state, default: 0] > priority[badges[parent.path] ?? .normal, default: 0] { badges[parent.path] = state }
                        if parent.path == parentRoot { break }; parent.deleteLastPathComponent()
                    }
                }
            }
        }
        return badges.reduce(into: [:]) { result, entry in
            guard !entry.key.split(separator: "/").contains(".git") else { return }
            if policy.allows(entry.key, fallback: volumes.contains(volume(entry.key)), caseSensitive: caseSensitive(entry.key)) {
                if !hiddenStates.contains(entry.value) { result[entry.key] = entry.value }
            } else if showExcludedAsNormal && (folders.contains(entry.key) || isDirectory(entry.key)) { result[entry.key] = .normal }
        }
    }
    public func overlayBadges(snapshot: FinderSnapshot, volume: (String) -> FinderVolumeKind, isDirectory: (String) -> Bool, caseSensitive: (String) -> Bool = { _ in true }) -> [String: FinderOverlayBadge] {
        let policy = pathPolicy
        let states = projectedBadges(snapshot: snapshot, volume: volume, isDirectory: isDirectory, caseSensitive: caseSensitive, policy: policy)
        return states.mapValues { FinderOverlayBadge(rawValue: $0.rawValue)! }.reduce(into: [:]) { result, entry in
            var badge = entry.value
            if cacheMode == .standard, badge == .normal, let flags = snapshot.indexFlags?[entry.key] {
                guard policy.allows(entry.key, fallback: volumes.contains(volume(entry.key)), caseSensitive: caseSensitive(entry.key)) else { result[entry.key] = badge; return }
                if flags.skipWorktree && showSkipWorktree { badge = .skipWorktree }
                else if flags.assumeUnchanged && showAssumeUnchanged { badge = .assumeUnchanged }
            }
            result[entry.key] = badge
        }
    }
}

/// CPathFilter's exact/recursive precedence compiled once per Finder refresh.
/// Case-sensitive volumes retain byte distinctions; insensitive volumes fold
/// names and canonical Unicode spellings before matching component boundaries.
public struct FinderOverlayPathPolicy: Sendable {
    public struct Issue: Equatable, Sendable {
        public let include: Bool
        public let line: Int
        public let reason: String
        public var message: String { "\(include ? "Include" : "Exclude") paths, line \(line): " + reason }
    }
    private struct Rule: Sendable {
        var exact: Bool?
        var recursive: Bool?
        mutating func merge(include: Bool, exact: Bool) {
            if exact { self.exact = self.exact == true || include }
            else { recursive = recursive == true || include }
        }
    }
    private var exactNames: [GitReferenceName: Rule] = [:]
    private var foldedNames: [GitReferenceName: Rule] = [:]
    public private(set) var issue: Issue?
    public private(set) var includeCount = 0
    public private(set) var excludeCount = 0
    private static func normalized(_ path: String) -> String {
        // NSURL standardization may normalize Unicode on macOS. Only collapse
        // separators and dot components here; preserve every filename byte.
        var components: [String] = []
        for part in path.utf8.split(separator: 47) {
            if part.elementsEqual([46]) { continue }
            if part.elementsEqual([46, 46]) { if !components.isEmpty { components.removeLast() }; continue }
            components.append(String(decoding: part, as: UTF8.self))
        }
        return "/" + components.joined(separator: "/")
    }
    static func folded(_ path: String) -> String {
        path.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
    }
    public init(exclude: String, include: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        for (text, included) in [(exclude, false), (include, true)] {
            for (index, raw) in text.components(separatedBy: "\n").enumerated() {
                var path = raw; if path.hasSuffix("\r") { path.removeLast() }
                if path.isEmpty { continue }
                if path.utf8.contains(0) {
                    if issue == nil { issue = Issue(include: included, line: index + 1, reason: "A path cannot contain a NUL character.") }; continue
                }
                let only = path.hasSuffix("?")
                if only || path.hasSuffix("*") { path.removeLast() }
                if path == "~" || path.hasPrefix("~/") { path = home.path + path.dropFirst() }
                else if path == "$HOME" || path.hasPrefix("$HOME/") { path = home.path + path.dropFirst(5) }
                guard path.hasPrefix("/") else {
                    if issue == nil { issue = Issue(include: included, line: index + 1, reason: "Enter an absolute path, ~ or $HOME.") }; continue
                }
                path = Self.normalized(path)
                let key = GitReferenceName(path), folded = GitReferenceName(Self.folded(path))
                var rule = exactNames[key] ?? Rule(); rule.merge(include: included, exact: only); exactNames[key] = rule
                var foldedRule = foldedNames[folded] ?? Rule(); foldedRule.merge(include: included, exact: only); foldedNames[folded] = foldedRule
                if included { includeCount += 1 } else { excludeCount += 1 }
            }
        }
    }
    public func allows(_ path: String, fallback: Bool, caseSensitive: Bool) -> Bool {
        // A corrupt policy must not accidentally grant an include exception.
        guard issue == nil, path.utf8.first == 47, !path.utf8.contains(0) else { return false }
        let table = caseSensitive ? exactNames : foldedNames
        let name = caseSensitive ? path : Self.folded(path)
        if let rule = table[GitReferenceName(name)], let result = rule.exact ?? rule.recursive { return result }
        let bytes = Array(name.utf8)
        for index in bytes.indices.reversed() where bytes[index] == 47 && index > 0 {
            if let result = table[GitReferenceName(String(decoding: bytes[..<index], as: UTF8.self))]?.recursive { return result }
        }
        return table["/"]?.recursive ?? fallback
    }
}

public struct FinderOverlayVolume: Equatable, Sendable {
    public let kind: FinderVolumeKind
    public let caseSensitive: Bool
    public init(kind: FinderVolumeKind, caseSensitive: Bool) { self.kind = kind; self.caseSensitive = caseSensitive }
}
/// A refresh-local metadata cache: all files in one directory share its volume
/// query, while a mounted child directory is resolved independently of its root.
public final class FinderOverlayFileSystem {
    private let readVolume: (URL) -> FinderOverlayVolume?
    private let readDirectory: (URL) -> Bool?
    private var directories: [GitReferenceName: Bool] = [:]
    private var volumes: [GitReferenceName: FinderOverlayVolume] = [:]
    public init(readVolume: @escaping (URL) -> FinderOverlayVolume? = FinderOverlayFileSystem.systemVolume,
                readDirectory: @escaping (URL) -> Bool? = { url in
                    guard let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType else { return nil }
                    return type == .typeDirectory
                }) {
        self.readVolume = readVolume; self.readDirectory = readDirectory
    }
    public func isDirectory(_ path: String) -> Bool {
        let key = GitReferenceName(path)
        if let result = directories[key] { return result }
        let result = readDirectory(URL(fileURLWithPath: path)) ?? false; directories[key] = result; return result
    }
    public func volume(_ path: String) -> FinderOverlayVolume {
        var directory = URL(fileURLWithPath: path)
        if !isDirectory(path) { directory.deleteLastPathComponent() }
        var visited: [GitReferenceName] = []
        while true {
            let key = GitReferenceName(directory.path)
            if let cached = volumes[key] { for key in visited { volumes[key] = cached }; return cached }
            visited.append(key)
            if let info = readVolume(directory) { for key in visited { volumes[key] = info }; return info }
            if directory.path == "/" { break }; directory.deleteLastPathComponent()
        }
        let unknown = FinderOverlayVolume(kind: .unknown, caseSensitive: true)
        for key in visited { volumes[key] = unknown }; return unknown
    }
    public static func systemVolume(_ url: URL) -> FinderOverlayVolume? {
        var info = statfs(); guard statfs(url.path, &info) == 0 else { return nil }
        let values = try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return FinderOverlayVolume(kind: FinderOverlaySettings.volumeKind(for: url), caseSensitive: values?.volumeSupportsCaseSensitiveNames ?? true)
    }
}

/// Finder may request the same item with a different case/Unicode spelling on an
/// insensitive volume. Keep literal identities on sensitive volumes.
public struct FinderOverlayBadgeLookup {
    private var exact: [GitReferenceName: FinderOverlayBadge] = [:]
    private var folded: [GitReferenceName: FinderOverlayBadge] = [:]
    public init(badges: [String: FinderOverlayBadge], caseSensitive: (String) -> Bool) {
        let rank: [FinderOverlayBadge: Int] = [.normal: 0, .assumeUnchanged: 1, .skipWorktree: 2, .ignored: 3, .untracked: 4, .added: 5, .deleted: 6, .modified: 7, .conflicted: 8]
        for (path, badge) in badges {
            exact[GitReferenceName(path)] = badge
            if !caseSensitive(path) {
                let key = GitReferenceName(FinderOverlayPathPolicy.folded(path))
                if rank[badge, default: 0] >= rank[folded[key] ?? .normal, default: 0] { folded[key] = badge }
            }
        }
    }
    public func badge(for path: String, caseSensitive: @autoclosure () -> Bool) -> FinderOverlayBadge? {
        let literal = exact[GitReferenceName(path)]
        guard let alias = folded[GitReferenceName(FinderOverlayPathPolicy.folded(path))] else { return literal }
        // Unbadged paths and known sensitive names need no filesystem query.
        return caseSensitive() ? literal : alias
    }
}
