import Foundation

/// A Finder request carries selection, never permission. Repeated path fields keep
/// spaces, Unicode, newlines and URL punctuation intact without delimiter guessing.
public struct FinderRequest: Sendable {
    public let action: RepositoryAction
    public let paths: [URL]
    public let sources: [URL]
    /// nil preserves legacy URL behavior; explicit false captures the default tool.
    public let alternateTool: Bool?
    /// Request Pull command presets remain editable input, never authorization.
    public let requestPullEnd: String?
    public let requestPullURL: String?
    public init(action: RepositoryAction, paths: [URL], sources: [URL] = [], alternateTool: Bool? = nil, requestPullEnd: String? = nil, requestPullURL: String? = nil) {
        self.action = action; self.alternateTool = alternateTool
        self.requestPullEnd = requestPullEnd; self.requestPullURL = requestPullURL
        self.paths = Self.normalizedSelection(paths)
        self.sources = Self.normalizedSelection(sources)
    }
    /// Menu eligibility and the captured request must use the same cardinality,
    /// order and literal-leaf normalization.
    public static func normalizedSelection(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.map(normalizedSelectionURL).filter { seen.insert($0.path).inserted }
    }
    private static func normalizedSelectionURL(_ url: URL) -> URL {
        guard url.isFileURL, url.path != "/" else { return url.standardizedFileURL }
        // Foundation may keep /private/tmp for a missing leaf while normalizing
        // its existing repository root to /tmp. Normalize the existing ancestor
        // and append missing components. Keep the selected leaf itself literal:
        // a tracked symlink is a Git path, not a request for its external target.
        var parent = url.deletingLastPathComponent(), components = [url.lastPathComponent]
        while parent.path != "/", (try? FileManager.default.attributesOfItem(atPath: parent.path)) == nil {
            components.append(parent.lastPathComponent); parent.deleteLastPathComponent()
        }
        return components.reversed().reduce(parent.standardizedFileURL) { $0.appendingPathComponent($1) }
    }
    public init?(url: URL) {
        guard url.scheme == "turtlegit", url.host == "action",
              let fields = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              fields.filter({ $0.name == "command" }).count == 1,
              let command = fields.first(where: { $0.name == "command" })?.value,
              let action = RepositoryAction(rawValue: command), !action.isMenuHeader else { return nil }
        let toolFields=fields.filter {$0.name=="alternate"}
        guard toolFields.count <= 1,toolFields.allSatisfy({$0.value=="0" || $0.value=="1"}) else {return nil}
        let alternateTool=toolFields.first.map {$0.value=="1"}
        let endFields = fields.filter { $0.name == "endrev" }, urlFields = fields.filter { $0.name == "url" }
        guard endFields.count <= 1, urlFields.count <= 1,
              (endFields + urlFields).allSatisfy({ $0.value != nil && $0.value?.contains("\0") == false }),
              action == .requestPull || (endFields.isEmpty && urlFields.isEmpty) else { return nil }
        let paths = fields.filter { $0.name == "path" }.compactMap(\.value)
        guard (!paths.isEmpty || action.allowsEmptySelection), paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }),
              paths.count == fields.filter({ $0.name == "path" }).count else { return nil }
        let sourceFields = fields.filter { $0.name == "source" }, sources = sourceFields.compactMap(\.value)
        guard sources.count == sourceFields.count, sources.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }),
              action.isFileTransfer ? paths.count == 1 && !sources.isEmpty && sources.count <= 256 && url.absoluteString.utf8.count <= 131072 : sources.isEmpty else { return nil }
        self.init(action: action, paths: paths.map { URL(fileURLWithPath: $0) }, sources: sources.map { URL(fileURLWithPath: $0) }, alternateTool:alternateTool, requestPullEnd: endFields.first?.value, requestPullURL: urlFields.first?.value)
    }
    public var url: URL? {
        guard !action.isMenuHeader, !paths.isEmpty || action.allowsEmptySelection,
              action == .requestPull || (requestPullEnd == nil && requestPullURL == nil),
              [requestPullEnd, requestPullURL].compactMap({ $0 }).allSatisfy({ !$0.contains("\0") }) else { return nil }
        guard paths.allSatisfy({ $0.isFileURL && !$0.path.contains("\0") }), sources.allSatisfy({ $0.isFileURL && !$0.path.contains("\0") }),
              action.isFileTransfer ? paths.count == 1 && !sources.isEmpty && sources.count <= 256 : sources.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "turtlegit"; components.host = "action"
        components.queryItems = [URLQueryItem(name: "command", value: action.rawValue)] + paths.map { URLQueryItem(name: "path", value: $0.path) } + sources.map { URLQueryItem(name: "source", value: $0.path) }
        if let requestPullEnd { components.queryItems?.append(URLQueryItem(name: "endrev", value: requestPullEnd)) }
        if let requestPullURL { components.queryItems?.append(URLQueryItem(name: "url", value: requestPullURL)) }
        if let alternateTool {components.queryItems?.append(URLQueryItem(name:"alternate",value:alternateTool ? "1":"0"))}
        guard let result = components.url, !action.isFileTransfer || result.absoluteString.utf8.count <= 131072 else { return nil }; return result
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
