// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// LogOrdering's persisted values choose Git's walk, never a sorted projection.
public enum HistoryOrdering: Int, CaseIterable, Sendable {
    case chronological = 0, topological = 1, committerDate = 2, authorDate = 3
    public static let preferenceKey = "LogOrderBy"
    public var arguments: [String] {
        switch self {
        case .chronological: return []
        case .topological: return ["--topo-order"]
        case .committerDate: return ["--date-order"]
        case .authorDate: return ["--author-date-order"]
        }
    }
    public var title: String {
        switch self {
        case .chronological: return "Chronological reversed (git default)"
        case .topological: return "--topo-order (TurtleGit default)"
        case .committerDate: return "--date-order"
        case .authorDate: return "--author-date-order"
        }
    }
    public static func load(defaults: UserDefaults = .standard) -> Self {
        guard let stored = defaults.object(forKey: preferenceKey) as? NSNumber,
              let value = Self(rawValue: stored.intValue) else { return .topological }
        return value
    }
    public func save(defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.preferenceKey) }
}
