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
    public func remove(_ messages: Set<String>) {
        defaults.set(entries.filter { value in !messages.contains(where: { Array($0.utf16).elementsEqual(value.utf16) }) }, forKey: Self.key)
    }
}
