// Adapts TortoiseGit MergeDlg.cpp and RegHistory.cpp (GPL-2.0-or-later; see NOTICE).
import Foundation

/// Merge messages share a global history, as in TortoiseGit.
public final class MergeMessageHistory: MessageHistory {
    private let defaults: UserDefaults
    public static let key = "Merge.MessageHistory"
    public let limit: Int
    public init(defaults: UserDefaults = .standard, limit: Int? = nil) {
        self.defaults = defaults
        self.limit = max(0, limit ?? (defaults.object(forKey: "MaxHistoryItems") as? Int ?? 25))
    }
    // RegHistory's do/while reads one entry even when the configured limit is zero.
    public var entries: [String] {
        Array((defaults.stringArray(forKey: Self.key) ?? []).prefix(max(1, limit)).prefix { !$0.isEmpty })
    }
    public func add(_ message: String) {
        guard !message.isEmpty else { return }
        // wcscmp distinguishes canonically equivalent Unicode spellings.
        var values = entries.filter { !Array($0.utf16).elementsEqual(message.utf16) }
        values.insert(message, at: 0)
        // Source Load reads at most limit, while Save permits one additional new entry.
        let saveLimit = limit == Int.max ? limit : limit + 1
        defaults.set(Array(values.prefix(saveLimit)), forKey: Self.key)
    }
    public func remove(_ messages: Set<String>) { removeExact(Array(messages)) }
    public func removeExact(_ messages:[String]) {
        let removed = Set(messages.map { GitReferenceName($0) })
        defaults.set(entries.filter { !removed.contains(GitReferenceName($0)) },forKey:Self.key)
    }
}


/// LogDlg's CRegHistory uses a separate exact-name history for each repository.
public struct HistoryReferenceRecents {
    private let defaults: UserDefaults
    public let key: String
    public let limit: Int
    public init(root: URL, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "History.LogRefs." + root.standardizedFileURL.path
        let raw = (defaults.object(forKey: "MaxRefHistoryItems") as? NSNumber)?.int64Value ?? 5
        limit = raw >= 0 && raw <= Int64(UInt32.max) ? Int(raw) : 5
    }
    public var entries: [String] { Array((defaults.stringArray(forKey: key) ?? []).prefix(max(1, limit)).prefix { !$0.isEmpty }) }
    /// Reload before merging so another Log window's recent selection survives.
    @discardableResult public func add(_ expression: String) -> [String] {
        guard HistoryReferenceSelection(expression: expression) != nil else { return entries }
        var values = entries.filter { !Array($0.utf16).elementsEqual(expression.utf16) }
        values.insert(expression, at: 0)
        values = Array(values.prefix(limit + 1))
        defaults.set(values, forKey: key)
        return values
    }
}
