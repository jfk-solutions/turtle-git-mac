import Foundation

/// Source-row visibility is shared by every pane. Folding never changes source
/// text, line numbers or alignment indices, including when wrapping is enabled.
public struct MergeFolding: Sendable, Equatable {
    public enum Visibility: Sendable, Equatable { case shown, hidden, marker }
    public private(set) var visibility: [Visibility]

    public init(visibility: [Visibility]) { self.visibility = visibility }

    /// Ports CDiffData::HideUnchangedSections, including its asymmetric forward
    /// context and marker placement. Callers supply the engine's unchanged rows;
    /// equal-looking text in a changed/conflict row must remain visible.
    public init(unchanged: [Bool], contextLines: Int = 1) {
        visibility = unchanged.map { $0 ? .hidden : .shown }
        guard visibility.count > 1 else { return }
        let context = max(0, min(contextLines, visibility.count))
        var last = visibility[0]
        if last == .hidden { visibility[0] = .marker }
        for index in 1..<visibility.count {
            let current = visibility[index]
            if current != last {
                if current == .shown {
                    var previous = index - 1
                    let stop = previous - context
                    while previous >= 0 && previous > stop {
                        visibility[previous] = .shown
                        previous -= 1
                    }
                } else if current == .hidden && last != .marker {
                    var next = index + 1
                    let stop = next + context
                    while next < visibility.count && next < stop {
                        visibility[next] = .shown
                        next += 1
                    }
                    if next < visibility.count && visibility[next] == .hidden {
                        visibility[next] = .marker
                    }
                }
            }
            last = current
        }
    }

    /// A single shared projection keeps source panes aligned. A marker occupies
    /// one screen row; its underlying source row remains in the document.
    public func visibleRows(collapsed: Bool) -> [Int] {
        visibility.indices.filter { !collapsed || visibility[$0] != .hidden }
    }

    public func hiddenRange(at marker: Int) -> Range<Int>? {
        guard visibility.indices.contains(marker), visibility[marker] == .marker else { return nil }
        var end = marker + 1
        while end < visibility.count && visibility[end] != .shown { end += 1 }
        return marker..<end
    }

    /// CBaseView's marker double-click expands this range in all panes together.
    @discardableResult public mutating func expand(marker: Int) -> Range<Int>? {
        guard let range = hiddenRange(at: marker) else { return nil }
        for row in range { visibility[row] = .shown }
        return range
    }

    /// Find, Go To Line and caret restoration must expose a hidden destination
    /// before translating source coordinates to screen coordinates.
    @discardableResult public mutating func reveal(row: Int) -> Range<Int>? {
        guard visibility.indices.contains(row), visibility[row] != .shown else { return nil }
        if visibility[row] == .marker { return expand(marker: row) }
        var marker = row
        while marker > 0 && visibility[marker] == .hidden { marker -= 1 }
        if visibility[marker] == .marker { return expand(marker: marker) }
        // The source's forward-context rule can leave hidden rows before a
        // shown row rather than a marker. Expose that contiguous run as well.
        var start = row, end = row + 1
        while start > 0 && visibility[start - 1] == .hidden { start -= 1 }
        while end < visibility.count && visibility[end] == .hidden { end += 1 }
        for index in start..<end { visibility[index] = .shown }
        return start..<end
    }

    /// Reveal each folded run once and return all actual changed source ranges.
    /// The owner can publish one projection after a multi-line selection.
    @discardableResult public mutating func reveal(rows: [Int]) -> [Range<Int>] {
        let requested = Set(rows.filter { visibility.indices.contains($0) }).sorted()
        var changed: [Range<Int>] = []
        for row in requested {
            if let last = changed.last, last.contains(row) { continue }
            if let range = reveal(row: row) { changed.append(range) }
        }
        return changed
    }

    public func screenRow(forSourceRow row: Int, collapsed: Bool) -> Int? {
        guard visibility.indices.contains(row) else { return nil }
        if !collapsed { return row }
        let rows = visibleRows(collapsed: true)
        if let exact = rows.firstIndex(of: row) { return exact }
        return rows.lastIndex(where: { $0 < row }) ?? rows.indices.first
    }
}

public struct MergeFoldingPreferences: Sendable, Equatable {
    public var collapsed: Bool
    public var contextLines: Int
    public init(collapsed: Bool = false, contextLines: Int = 1) {
        self.collapsed = collapsed; self.contextLines = max(0, contextLines)
    }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        let key = "TurtleGitMerge.ContextLines"
        // Upstream uses the same context DWORD for folding and unified patches.
        // The saved -1 sentinel means all context and therefore no folded rows.
        let context = defaults.object(forKey: key) == nil ? 1 : defaults.integer(forKey: key)
        return .init(collapsed: defaults.bool(forKey: "TurtleGitMerge.Collapsed"),
                     contextLines: context < 0 ? Int.max : context)
    }
    public func saveCollapsed(to defaults: UserDefaults = .standard) {
        defaults.set(collapsed, forKey: "TurtleGitMerge.Collapsed")
    }
}

/// Pane-neutral screen rows. The marker's source range is explicit so display
/// placeholders cannot accidentally enter Copy, editing or saved file contents.
public struct MergeFoldProjection: Sendable, Equatable {
    public enum Row: Sendable, Equatable {
        case source(Int)
        case marker(Range<Int>)
        public var sourceRow: Int {
            switch self { case .source(let row): return row; case .marker(let range): return range.lowerBound }
        }
    }
    public let rows: [Row]
    public init(folding: MergeFolding, collapsed: Bool) {
        rows = folding.visibleRows(collapsed: collapsed).map { index in
            if collapsed, let range = folding.hiddenRange(at: index) { return .marker(range) }
            return .source(index)
        }
    }
    public func sourceRow(at screenRow: Int) -> Int? {
        guard rows.indices.contains(screenRow) else { return nil }
        return rows[screenRow].sourceRow
    }
    public func screenRow(containing sourceRow: Int) -> Int? {
        guard sourceRow >= 0 else { return nil }
        return rows.firstIndex { row in
            switch row {
            case .source(let index): return index == sourceRow
            case .marker(let range): return range.contains(sourceRow)
            }
        }
    }
}

/// Result edits shift or invalidate exact engine anchors. Unrelated repeated
/// lines are never matched by their text when synchronizing fold expansion.
public struct MergeFoldAnchors: Sendable, Equatable {
    public private(set) var offsets: [Int: Int]
    public init(offsets: [Int: Int] = [:]) { self.offsets = offsets }
    public mutating func reconcile(old: String, new: String) {
        guard !old.utf8.elementsEqual(new.utf8) else { return }
        let a = Array(old.utf16), b = Array(new.utf16)
        var prefix = 0, suffix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        while suffix < min(a.count, b.count) - prefix, a[a.count - suffix - 1] == b[b.count - suffix - 1] { suffix += 1 }
        let end = a.count - suffix, delta = b.count - a.count
        offsets = offsets.compactMapValues { offset in
            if offset < prefix { return offset }
            if offset >= end { return offset + delta }
            return nil
        }
    }
    public func resultRows(in text: String) -> [Int: Int] {
        let ranges = MergeLineEndings.lineRanges(in: text)
        let rowAtOffset = Dictionary(ranges.enumerated().map { ($0.element.location, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var result: [Int: Int] = [:]
        for (source, offset) in offsets {
            // An anchor must still start a result row, not an edited line suffix.
            if let row = rowAtOffset[offset] { result[source] = row }
        }
        return result
    }
}
