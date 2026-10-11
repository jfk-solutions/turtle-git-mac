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
    public func finderIndexFlags(cancellation: OperationCancellation? = nil) throws -> [String: FinderIndexFlags] {
        var flags: [String: FinderIndexFlags] = [:]
        for record in try run(["ls-files", "-v", "-z"], cancellation: cancellation).stdout.split(separator: 0) {
            guard record.count >= 3 else { throw GitConfigurationFailure.output }
            let bytes = Array(record), code = bytes[0]
            guard bytes[1] == 32 else { throw GitConfigurationFailure.output }
            let assume = (97...122).contains(code), skip = code == 83 || code == 115
            if assume || skip {
                let path = String(decoding: bytes.dropFirst(2), as: UTF8.self)
                flags[root.appendingPathComponent(path).path] = .init(skipWorktree: skip, assumeUnchanged: assume)
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
    public var valid: Bool {
        [excludePaths, includePaths].allSatisfy { text in
            !text.contains("\0") && text.replacingOccurrences(of: "\r", with: "").split(separator: "\n").allSatisfy { line in
                var path = String(line); if path.hasSuffix("*") || path.hasSuffix("?") { path.removeLast() }
                return path.hasPrefix("/") || path == "~" || path.hasPrefix("~/") || path == "$HOME" || path.hasPrefix("$HOME/")
            }
        }
    }
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
    public func allows(_ path: String, volume: FinderVolumeKind) -> Bool {
        struct Rule { let path: String; let include: Bool; let exact: Bool }
        func rules(_ text: String, include: Bool) -> [Rule] {
            text.replacingOccurrences(of: "\r", with: "").split(separator: "\n").map { line in
                var path = String(line); let exact = path.hasSuffix("?")
                if exact || path.hasSuffix("*") { path.removeLast() }
                if path == "~" || path.hasPrefix("~/") { path = FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst() }
                if path == "$HOME" || path.hasPrefix("$HOME/") { path = FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst(5) }
                path = URL(fileURLWithPath: path).standardizedFileURL.path
                return Rule(path: path, include: include, exact: exact)
            }
        }
        let matches = (rules(excludePaths, include: false) + rules(includePaths, include: true)).filter {
            path == $0.path || !$0.exact && path.hasPrefix($0.path == "/" ? "/" : $0.path + "/")
        }
        guard let depth = matches.map({ $0.path.count }).max() else { return volumes.contains(volume) }
        let closest = matches.filter { $0.path.count == depth }
        let exact = closest.filter { $0.exact && $0.path == path }
        return (exact.isEmpty ? closest : exact).contains { $0.include }
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
    public func badges(snapshot: FinderSnapshot, volume: (String) -> FinderVolumeKind, isDirectory: (String) -> Bool) -> [String: FileState] {
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
            let root = roots.first { entry.key == $0 || entry.key.hasPrefix($0 + "/") }
            if allows(entry.key, volume: volume(root ?? entry.key)) {
                if !hiddenStates.contains(entry.value) { result[entry.key] = entry.value }
            } else if showExcludedAsNormal && (folders.contains(entry.key) || isDirectory(entry.key)) { result[entry.key] = .normal }
        }
    }
    public func overlayBadges(snapshot: FinderSnapshot, volume: (String) -> FinderVolumeKind, isDirectory: (String) -> Bool) -> [String: FinderOverlayBadge] {
        let states = badges(snapshot: snapshot, volume: volume, isDirectory: isDirectory)
        let roots = snapshot.roots.sorted { $0.count > $1.count }
        return states.mapValues { FinderOverlayBadge(rawValue: $0.rawValue)! }.reduce(into: [:]) { result, entry in
            var badge = entry.value
            if cacheMode == .standard, badge == .normal, let flags = snapshot.indexFlags?[entry.key] {
                let root = roots.first { entry.key == $0 || entry.key.hasPrefix($0 + "/") }
                guard allows(entry.key, volume: volume(root ?? entry.key)) else { result[entry.key] = badge; return }
                if flags.skipWorktree && showSkipWorktree { badge = .skipWorktree }
                else if flags.assumeUnchanged && showAssumeUnchanged { badge = .assumeUnchanged }
            }
            result[entry.key] = badge
        }
    }
}
