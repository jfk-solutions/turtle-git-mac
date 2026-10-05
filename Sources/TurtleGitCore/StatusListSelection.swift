import Foundation

public enum StatusListSelection {
    /// SwiftUI requests an unselected clicked row before its native mouse event
    /// updates the focus binding. Use that row immediately; preserve the mark
    /// (including a mark outside the highlight) for an existing selection.
    public static func mark(entries: [StatusEntry], requested: Set<String>, highlighted: Set<String>, focusedPath: String?) -> StatusEntry? {
        let selected = entries.filter { requested.contains($0.id) }
        if selected.count == 1, requested != highlighted { return selected.first }
        return entries.first { $0.path == focusedPath } ?? (selected.count == 1 ? selected.first : nil)
    }
}
