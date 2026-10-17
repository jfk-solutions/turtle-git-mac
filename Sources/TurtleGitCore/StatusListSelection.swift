import Foundation

public enum StatusListSelection {
    /// Checking a highlighted row applies its new state to the highlighted
    /// files. An unhighlighted row changes alone, preserving the highlight.
    public static func checkboxEntries(entry: StatusEntry, entries: [StatusEntry], highlighted: some Sequence<String>) -> [StatusEntry] {
        let highlighted = GitPathSet(highlighted)
        guard entries.contains(where: { GitReferenceName.equal($0.id,entry.id) }) else { return [] }
        return highlighted.contains(entry.id) ? entries.filter { highlighted.contains($0.id) } : [entry]
    }
    /// SwiftUI requests an unselected clicked row before its native mouse event
    /// updates the focus binding. Use that row immediately; preserve the mark
    /// (including a mark outside the highlight) for an existing selection.
    public static func mark(entries: [StatusEntry], requested: some Sequence<String>, highlighted: some Sequence<String>, focusedPath: String?) -> StatusEntry? {
        let requested = GitPathSet(requested), highlighted = GitPathSet(highlighted)
        let selected = entries.filter { requested.contains($0.id) }
        if selected.count == 1, requested != highlighted { return selected.first }
        return entries.first { entry in focusedPath.map { GitReferenceName.equal(entry.path,$0) } == true } ?? (selected.count == 1 ? selected.first : nil)
    }
}
