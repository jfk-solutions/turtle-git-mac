import Foundation

/// Customization scans the Blame menus upstream, rather than only its five
/// initial toolbar buttons. IDs are persisted independently of translated text.
public enum BlameToolbarCommand: String, Codable, CaseIterable, Identifiable, Sendable {
    case open, reload, previousChange, nextChange, copy, about
    case find, findNext, findPrevious, goTo, settings, close
    case zoomIn, zoomOut, actualSize, nextPane, previousPane
    case toolbar, log, properties, statusBar, logID, author, date, filename, original
    case ignoreWhitespace, completeLog, followRenames, firstParent, colorAge, syntax, dark, wrap
    case followSystemAppearance, detectDisabled, detectWithinFile, detectModifiedFiles, detectFileCreation, detectExistingFiles, encoding
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .open: return "Open…"
        case .reload: return "Reload"
        case .previousChange: return "Previous Change"
        case .nextChange: return "Next Change"
        case .copy: return "Copy"
        case .about: return "About TurtleGitBlame…"
        case .find: return "Find…"
        case .findNext: return "Find Next"
        case .findPrevious: return "Find Previous"
        case .goTo: return "Go To Line…"
        case .settings: return "Settings…"
        case .close: return "Close"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .actualSize: return "Actual Size"
        case .nextPane: return "Next Pane"
        case .previousPane: return "Previous Pane"
        case .toolbar: return "Toolbar"
        case .log: return "Log"
        case .properties: return "Properties"
        case .statusBar: return "Status Bar"
        case .logID: return "Show log ID instead of SHA-1"
        case .author: return "Show author"
        case .date: return "Show date"
        case .filename: return "Show file name"
        case .original: return "Show original line number"
        case .ignoreWhitespace: return "Ignore whitespace"
        case .completeLog: return "Show complete log"
        case .followRenames: return "Follow renames"
        case .firstParent: return "Only consider first parents on blame"
        case .colorAge: return "Color by age, continuous"
        case .syntax: return "Enable syntax highlighting"
        case .dark: return "Dark Mode"
        case .wrap: return "Wrap long lines"
        case .followSystemAppearance: return "Follow System Appearance"
        case .detectDisabled: return "Detect moved or copied lines: Disabled"
        case .detectWithinFile: return "Detect moved or copied lines: Within file"
        case .detectModifiedFiles: return "Detect moved or copied lines: From modified files"
        case .detectFileCreation: return "Detect moved or copied lines: At file creation"
        case .detectExistingFiles: return "Detect moved or copied lines: From existing files"
        case .encoding: return "Encoding"
        }
    }
    /// Source asset names, resolved to MenuIcon by the native presentation layer.
    public var iconName: String {
        switch self {
        case .open: return "open"
        case .reload: return "refresh"
        case .previousChange, .findPrevious, .previousPane: return "jumpup"
        case .nextChange, .findNext, .nextPane: return "jumpdown"
        case .copy: return "copy"
        case .about: return "TurtleGitApplication"
        case .find: return "Search"
        case .goTo, .log, .logID: return "menulog"
        case .zoomIn: return "zoomin"
        case .zoomOut: return "zoomout"
        case .actualSize: return "origsize"
        case .properties: return "imginfo"
        default: return "menusettings"
        }
    }
    public var accessibilityIdentifier: String { "Blame.Toolbar.Command." + rawValue }
    private static var encodingChoices: [GitBlameEncodingChoice] {
        GitBlameEncodingMenu.unicode + GitBlameEncodingMenu.groups.flatMap(\.choices)
    }
    public static var availableItemIDs: [String] {
        allCases.map(\.rawValue) + ["encoding.automatic"] + encodingChoices.filter { $0.encoding != nil }.map { "encoding.\($0.codePage)" }
    }
    public static func isKnownItem(_ id: String) -> Bool {
        id == "space" || id == "flexibleSpace" || availableItemIDs.contains(id)
    }
    public static func encoding(for id: String) -> GitBlameEncoding? {
        guard id.hasPrefix("encoding."), let codePage = UInt32(id.dropFirst(9)) else { return nil }
        return encodingChoices.first { $0.codePage == codePage }?.encoding
    }
    public static func title(for id: String) -> String {
        if let command = Self(rawValue: id) { return command.title }
        if id == "space" { return "Space" }
        if id == "flexibleSpace" { return "Flexible Space" }
        if id == "encoding.automatic" { return "Encoding: Automatic" }
        if id.hasPrefix("encoding."), let codePage = UInt32(id.dropFirst(9)), let choice = encodingChoices.first(where: { $0.codePage == codePage }) { return "Encoding: " + choice.title }
        return id
    }
    public static func iconName(for id: String) -> String { Self(rawValue: id)?.iconName ?? "menusettings" }
}

public enum BlameToolbarDisplayMode: String, Codable, CaseIterable, Sendable {
    case icons, iconsAndLabels, labels
    public var title: String {
        switch self { case .icons: return "Icons Only"; case .iconsAndLabels: return "Icons and Text"; case .labels: return "Text Only" }
    }
}

public struct BlameToolbarBar: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var isVisible: Bool
    public var items: [String]
    public var displayMode: BlameToolbarDisplayMode
    public init(id: UUID = UUID(), name: String, isVisible: Bool = true, items: [String] = [], displayMode: BlameToolbarDisplayMode = .iconsAndLabels) {
        self.id = id; self.name = name; self.isVisible = isVisible; self.items = items; self.displayMode = displayMode
    }
}

public struct BlameToolbarConfiguration: Codable, Equatable, Sendable {
    public static let standardID = UUID(uuidString: "8E70CE84-30D5-494F-A9EA-EF8117847A9E")!
    public static let maximumCustomBars = 20
    public static let maximumItemsPerBar = 100
    public var standard: BlameToolbarBar
    public var customBars: [BlameToolbarBar]
    public init(standard: BlameToolbarBar, customBars: [BlameToolbarBar] = []) { self.standard = standard; self.customBars = customBars }
    public static var defaults: Self {
        .init(standard: .init(id: standardID, name: "Standard", items: ["open", "space", "previousChange", "nextChange", "space", "copy", "space", "about"]))
    }
    public var allBars: [BlameToolbarBar] { [standard] + customBars }
    private static func cleanName(_ name: String) -> String {
        String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    }
    /// Preserve intentional empty compositions and repeated spacers, while
    /// discarding stale command IDs and duplicate executable buttons per bar.
    public func sanitized() -> Self {
        func clean(_ bar: BlameToolbarBar) -> BlameToolbarBar {
            var value = bar, seen = Set<String>()
            value.items = Array(bar.items.filter { id in
                guard BlameToolbarCommand.isKnownItem(id) else { return false }
                return id == "space" || id == "flexibleSpace" || seen.insert(id).inserted
            }.prefix(Self.maximumItemsPerBar))
            value.name = Self.cleanName(bar.name)
            return value
        }
        var value = Self(standard: clean(standard)); value.standard.id = Self.standardID; value.standard.name = "Standard"
        var ids: Set<UUID> = [Self.standardID], names: Set<String> = ["standard"]
        for original in customBars {
            guard value.customBars.count < Self.maximumCustomBars else { break }
            let bar = clean(original), key = bar.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard !bar.name.isEmpty, ids.insert(bar.id).inserted, names.insert(key).inserted else { continue }
            value.customBars.append(bar)
        }
        return value
    }
    @discardableResult public mutating func createBar(name: String) -> UUID? {
        let bar = BlameToolbarBar(name: name)
        let candidate = Self(standard: standard, customBars: customBars + [bar]).sanitized()
        guard candidate.customBars.contains(where: { $0.id == bar.id }) else { return nil }
        self = candidate; return bar.id
    }
    @discardableResult public mutating func renameBar(id: UUID, name: String) -> Bool {
        guard let index = customBars.firstIndex(where: { $0.id == id }) else { return false }
        var candidate = self; candidate.customBars[index].name = name
        candidate = candidate.sanitized()
        guard candidate.customBars.count == customBars.count, candidate.customBars.contains(where: { $0.id == id }) else { return false }
        self = candidate; return true
    }
    @discardableResult public mutating func removeBar(id: UUID) -> Bool {
        guard let index = customBars.firstIndex(where: { $0.id == id }) else { return false }
        customBars.remove(at: index); return true
    }
    public mutating func updateBar(_ bar: BlameToolbarBar) {
        var candidate = self
        if bar.id == Self.standardID { candidate.standard = bar }
        else if let index = customBars.firstIndex(where: { $0.id == bar.id }) { candidate.customBars[index] = bar }
        else { return }
        candidate = candidate.sanitized()
        // A live name editor can temporarily be empty or duplicate another
        // name. Reject that edit instead of deleting an existing toolbar.
        guard candidate.customBars.count == customBars.count,
              candidate.allBars.contains(where: { $0.id == bar.id }) else { return }
        self = candidate
    }
    public mutating func reset() { self = .defaults }
}

/// Inject a private defaults suite and key in native checks. No global singleton
/// or observed window is retained; controllers own their live configuration.
public final class BlameToolbarConfigurationStore {
    public static let defaultKey = "Blame.ToolbarConfiguration.v1"
    private let defaults: UserDefaults
    private let key: String
    public init(defaults: UserDefaults = .standard, key: String = BlameToolbarConfigurationStore.defaultKey) { self.defaults = defaults; self.key = key }
    public func load() -> BlameToolbarConfiguration {
        if let data = defaults.data(forKey: key), data.count <= 262_144,
           let value = try? JSONDecoder().decode(BlameToolbarConfiguration.self, from: data) { return value.sanitized() }
        var value = BlameToolbarConfiguration.defaults
        if let visible = defaults.object(forKey: "Blame.ShowToolbar") as? Bool { value.standard.isVisible = visible }
        return value
    }
    public func save(_ configuration: BlameToolbarConfiguration) {
        let value = configuration.sanitized()
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
        defaults.set(value.standard.isVisible, forKey: "Blame.ShowToolbar")
    }
    @discardableResult public func reset() -> BlameToolbarConfiguration { let value = BlameToolbarConfiguration.defaults; save(value); return value }
}
