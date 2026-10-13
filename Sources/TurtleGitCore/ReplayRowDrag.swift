// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Source OnCommitsReordered moves a contiguous block in newest-first display
/// order; execution order remains the reverse of that display.
public struct ReplayRowDrag: Sendable {
    public let selected: Set<String>
    private let identities: [String]
    private let actions: [RebaseAction]
    private let progress: [String]
    private let mainlines: [Int?]
    private let lower: Int
    private let upper: Int
    public init?(visible: [RebaseEntry], selected: Set<String>) {
        let indexes = visible.indices.filter { selected.contains(visible[$0].id) }
        guard Set(visible.map(\.id)).count == visible.count, indexes.count == selected.count,
              let first = indexes.first, let last = indexes.last, last-first+1 == indexes.count else { return nil }
        self.selected = selected; identities = visible.map(\.id); actions = visible.map(\.action)
        progress = visible.map { String(describing:$0.progress) }; mainlines = visible.map(\.mainline)
        lower = first; upper = last+1
    }
    public func matches(_ visible: [RebaseEntry]) -> Bool {
        visible.map(\.id) == identities && visible.map(\.action) == actions &&
        visible.map { String(describing:$0.progress) } == progress && visible.map(\.mainline) == mainlines
    }
    public func canDrop(visible: [RebaseEntry], before destination: Int) -> Bool {
        matches(visible) && (0...visible.count).contains(destination) && !(lower...upper).contains(destination)
    }
    public func reordered(visible: [RebaseEntry], before destination: Int) -> [RebaseEntry]? {
        guard canDrop(visible:visible,before:destination) else { return nil }
        let block = Array(visible[lower..<upper])
        var result = visible; result.removeSubrange(lower..<upper)
        result.insert(contentsOf:block,at:destination > upper ? destination-block.count : destination)
        return result
    }
}
