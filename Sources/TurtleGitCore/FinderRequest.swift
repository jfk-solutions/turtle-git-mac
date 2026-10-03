import Foundation

/// A Finder request carries selection, never permission. Repeated path fields keep
/// spaces, Unicode, newlines and URL punctuation intact without delimiter guessing.
public struct FinderRequest: Sendable {
    public let action: RepositoryAction
    public let paths: [URL]
    public init(action: RepositoryAction, paths: [URL]) {
        self.action = action
        var seen = Set<String>()
        self.paths = paths.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
    }
    public init?(url: URL) {
        guard url.scheme == "turtlegit", url.host == "action",
              let fields = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              fields.filter({ $0.name == "command" }).count == 1,
              let command = fields.first(where: { $0.name == "command" })?.value,
              let action = RepositoryAction(rawValue: command) else { return nil }
        let paths = fields.filter { $0.name == "path" }.compactMap(\.value)
        guard !paths.isEmpty, paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }),
              paths.count == fields.filter({ $0.name == "path" }).count else { return nil }
        self.init(action: action, paths: paths.map { URL(fileURLWithPath: $0) })
    }
    public var url: URL? {
        guard !paths.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "turtlegit"; components.host = "action"
        components.queryItems = [URLQueryItem(name: "command", value: action.rawValue)] + paths.map { URLQueryItem(name: "path", value: $0.path) }
        return components.url
    }
    public func relativePaths(root: URL) -> [String] {
        let prefix = root.standardizedFileURL.path
        return paths.compactMap { item in
            if item.path == prefix { return "." }
            guard item.path.hasPrefix(prefix + "/") else { return nil }
            return String(item.path.dropFirst(prefix.count + 1))
        }
    }
    /// Expand selected directories to changed rows, with component boundaries.
    /// Selecting the repository itself includes its complete status list.
    public func selectedStatusPaths(root: URL, entries: [StatusEntry]) -> Set<String> {
        let prefix = root.standardizedFileURL.path
        return Set(entries.filter { entry in
            let full = root.appendingPathComponent(entry.path).standardizedFileURL.path
            return paths.contains { selected in
                selected.path == prefix || full == selected.path || full.hasPrefix(selected.path + "/")
            }
        }.map(\.path))
    }
}
