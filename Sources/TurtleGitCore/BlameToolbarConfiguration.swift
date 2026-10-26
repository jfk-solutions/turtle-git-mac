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

public enum BlameToolbarPlacement: String, Codable, CaseIterable, Identifiable, Sendable {
    case top, bottom, left, right, floating
    public var id: String { rawValue }
    public var title: String {
        switch self { case .top: return "Top"; case .bottom: return "Bottom"; case .left: return "Left"; case .right: return "Right"; case .floating: return "Floating" }
    }
}

/// Display-independent saved geometry. The window owner additionally fits this
/// rectangle to the currently connected screens before presenting a panel.
public struct BlameToolbarFloatingRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public func sanitized() -> Self? {
        guard [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        return .init(x: max(-100_000, min(100_000, x)), y: max(-100_000, min(100_000, y)), width: max(32, min(4096, width)), height: max(32, min(4096, height)))
    }
}

/// A drag receipt describes an occurrence, not merely its command. This matters
/// for repeated spacers, and prevents a changed list redirecting an old drag.
public struct BlameToolbarItemReceipt: Codable, Equatable, Sendable {
    public let generation: UUID
    public let barID: UUID
    public let index: Int
    public let itemID: String
    public let sourceItems: [String]
}

public struct BlameToolbarBar: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var isVisible: Bool
    public var items: [String]
    public var displayMode: BlameToolbarDisplayMode
    public var placement: BlameToolbarPlacement
    public var dockOrder: Int
    public var lastDockPlacement: BlameToolbarPlacement
    public var lastDockOrder: Int
    public var floatingRect: BlameToolbarFloatingRect?
    public init(id: UUID = UUID(), name: String, isVisible: Bool = true, items: [String] = [], displayMode: BlameToolbarDisplayMode = .iconsAndLabels, placement: BlameToolbarPlacement = .top, dockOrder: Int = 0, lastDockPlacement: BlameToolbarPlacement = .top, lastDockOrder: Int = 0, floatingRect: BlameToolbarFloatingRect? = nil) {
        self.id = id; self.name = name; self.isVisible = isVisible; self.items = items; self.displayMode = displayMode; self.placement = placement; self.dockOrder = dockOrder; self.lastDockPlacement = lastDockPlacement; self.lastDockOrder = lastDockOrder; self.floatingRect = floatingRect
    }
    private enum CodingKeys: String, CodingKey { case id, name, isVisible, items, displayMode, placement, dockOrder, lastDockPlacement, lastDockOrder, floatingRect }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id); name = try values.decode(String.self, forKey: .name)
        isVisible = try values.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        items = try values.decodeIfPresent([String].self, forKey: .items) ?? []
        displayMode = try values.decodeIfPresent(BlameToolbarDisplayMode.self, forKey: .displayMode) ?? .iconsAndLabels
        let rawPlacement = try values.decodeIfPresent(String.self, forKey: .placement)
        placement = rawPlacement.flatMap(BlameToolbarPlacement.init(rawValue:)) ?? .top
        dockOrder = max(0, min(1000, try values.decodeIfPresent(Int.self, forKey: .dockOrder) ?? 0))
        let rawLastDock = try values.decodeIfPresent(String.self, forKey: .lastDockPlacement)
        let lastDock = rawLastDock.flatMap(BlameToolbarPlacement.init(rawValue:)) ?? .top
        lastDockPlacement = lastDock == .floating ? .top : lastDock
        lastDockOrder = max(0, min(1000, try values.decodeIfPresent(Int.self, forKey: .lastDockOrder) ?? 0))
        floatingRect = try values.decodeIfPresent(BlameToolbarFloatingRect.self, forKey: .floatingRect)?.sanitized()
    }
}

public struct BlameToolbarConfiguration: Codable, Equatable, Sendable {
    public static let standardID = UUID(uuidString: "8E70CE84-30D5-494F-A9EA-EF8117847A9E")!
    private static let initialGeneration = UUID(uuidString: "60AB791C-5539-48A4-8E81-62BE141A1A6F")!
    public static let maximumCustomBars = 20
    public static let maximumItemsPerBar = 100
    public var standard: BlameToolbarBar
    public var customBars: [BlameToolbarBar]
    public private(set) var generation: UUID
    public init(standard: BlameToolbarBar, customBars: [BlameToolbarBar] = []) { self.standard = standard; self.customBars = customBars; generation = UUID() }
    private enum CodingKeys: String, CodingKey { case standard, customBars, generation }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        standard = try values.decode(BlameToolbarBar.self, forKey: .standard)
        customBars = try values.decodeIfPresent([BlameToolbarBar].self, forKey: .customBars) ?? []
        generation = try values.decodeIfPresent(UUID.self, forKey: .generation) ?? Self.initialGeneration
    }
    /// Compare visible/persistent layout, independently of its receipt epoch.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.standard == rhs.standard && lhs.customBars == rhs.customBars }
    public static var defaults: Self {
        var value = Self(standard: .init(id: standardID, name: "Standard", items: ["open", "space", "previousChange", "nextChange", "space", "copy", "space", "about"]))
        value.generation = initialGeneration; return value
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
            value.floatingRect = bar.floatingRect?.sanitized()
            value.dockOrder = max(0, min(1000, bar.dockOrder))
            value.lastDockPlacement = bar.lastDockPlacement == .floating ? .top : bar.lastDockPlacement
            value.lastDockOrder = max(0, min(1000, bar.lastDockOrder))
            return value
        }
        var value = Self(standard: clean(standard)); value.generation = generation; value.standard.id = Self.standardID; value.standard.name = "Standard"
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
        var candidate = Self(standard: standard, customBars: customBars + [bar]).sanitized()
        guard candidate.customBars.contains(where: { $0.id == bar.id }) else { return nil }
        candidate.generation = UUID(); self = candidate; return bar.id
    }
    @discardableResult public mutating func renameBar(id: UUID, name: String) -> Bool {
        guard let index = customBars.firstIndex(where: { $0.id == id }) else { return false }
        var candidate = self; candidate.customBars[index].name = name
        candidate = candidate.sanitized()
        guard candidate.customBars.count == customBars.count, candidate.customBars.contains(where: { $0.id == id }) else { return false }
        candidate.generation = UUID(); self = candidate; return true
    }
    @discardableResult public mutating func removeBar(id: UUID) -> Bool {
        guard let index = customBars.firstIndex(where: { $0.id == id }) else { return false }
        customBars.remove(at: index); generation = UUID(); return true
    }
    /// Management-list ordering is distinct from the saved order on a dock.
    @discardableResult public mutating func moveBar(id: UUID, offset: Int) -> Bool {
        guard offset != 0, let index = customBars.firstIndex(where: { $0.id == id }),
              offset >= -index, offset < customBars.count - index else { return false }
        customBars.swapAt(index, index + offset); generation = UUID(); return true
    }
    /// Reindex the complete visible edge atomically after an accepted drag.
    /// The caller supplies actual hit-tested order, including Standard when it
    /// belongs on this edge. Hidden bars keep their saved position.
    @discardableResult public mutating func reorderDockBars(_ orderedIDs: [UUID], at placement: BlameToolbarPlacement) -> Bool {
        guard placement != .floating, Set(orderedIDs).count == orderedIDs.count else { return false }
        let visible = allBars.filter { $0.isVisible && $0.placement == placement }
        guard Set(visible.map(\.id)) == Set(orderedIDs) else { return false }
        var candidate = self
        for (order, id) in orderedIDs.enumerated() {
            guard var bar = candidate.allBars.first(where: { $0.id == id }) else { return false }
            bar.dockOrder = order; bar.lastDockPlacement = placement; bar.lastDockOrder = order
            if id == Self.standardID { candidate.standard = bar }
            else if let index = candidate.customBars.firstIndex(where: { $0.id == id }) { candidate.customBars[index] = bar }
        }
        guard candidate != self else { return false }
        candidate.generation = UUID(); self = candidate; return true
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
        if candidate != self { candidate.generation = UUID() }
        self = candidate
    }
    /// Capture only known, live occurrences; no executable or pathname payload.
    public func captureItem(barID: UUID, index: Int) -> BlameToolbarItemReceipt? {
        guard let bar = allBars.first(where: { $0.id == barID }), bar.items.indices.contains(index), BlameToolbarCommand.isKnownItem(bar.items[index]) else { return nil }
        return .init(generation: generation, barID: barID, index: index, itemID: bar.items[index], sourceItems: bar.items)
    }
    /// Insertion indexes refer to the destination before removing the source.
    /// Call only for an accepted drop. Cancellation never mutates the model.
    @discardableResult public mutating func transfer(_ receipt: BlameToolbarItemReceipt, to destinationID: UUID, at insertionIndex: Int, copy: Bool = false) -> Bool {
        guard receipt.generation == generation,
              let source = allBars.first(where: { $0.id == receipt.barID }),
              let destination = allBars.first(where: { $0.id == destinationID }),
              source.items == receipt.sourceItems,
              source.items.indices.contains(receipt.index), source.items[receipt.index] == receipt.itemID,
              BlameToolbarCommand.isKnownItem(receipt.itemID),
              insertionIndex >= 0, insertionIndex <= destination.items.count else { return false }
        let sameBar = source.id == destination.id
        let spacer = receipt.itemID == "space" || receipt.itemID == "flexibleSpace"
        if (!sameBar || copy), !spacer, destination.items.contains(receipt.itemID) { return false }
        if (copy || !sameBar), destination.items.count >= Self.maximumItemsPerBar { return false }
        var sourceBar = source, destinationBar = destination
        if sameBar {
            var index = insertionIndex
            if !copy { sourceBar.items.remove(at: receipt.index); if receipt.index < index { index -= 1 } }
            sourceBar.items.insert(receipt.itemID, at: index)
            guard sourceBar.items != source.items else { return false }
            if source.id == Self.standardID { standard = sourceBar }
            else if let index = customBars.firstIndex(where: { $0.id == source.id }) { customBars[index] = sourceBar }
        } else {
            if !copy { sourceBar.items.remove(at: receipt.index) }
            destinationBar.items.insert(receipt.itemID, at: insertionIndex)
            if source.id == Self.standardID { standard = sourceBar }
            else if let index = customBars.firstIndex(where: { $0.id == source.id }) { customBars[index] = sourceBar }
            if destination.id == Self.standardID { standard = destinationBar }
            else if let index = customBars.firstIndex(where: { $0.id == destination.id }) { customBars[index] = destinationBar }
        }
        generation = UUID(); return true
    }
    public mutating func reset() { self = .defaults; generation = UUID() }
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
    @discardableResult public func reset() -> BlameToolbarConfiguration { var value = BlameToolbarConfiguration.defaults; value.reset(); save(value); return value }
}
