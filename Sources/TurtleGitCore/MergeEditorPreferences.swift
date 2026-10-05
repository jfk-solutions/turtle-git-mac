import Foundation
import Darwin

public enum EditorConfigFailure: LocalizedError {
    case runtimeMissing, invalidPath, failed(String), timedOut
    public var errorDescription: String? {
        switch self {
        case .runtimeMissing: return "The bundled EditorConfig parser is missing. Rebuild the app with its pinned parser runtime."
        case .invalidPath: return "EditorConfig requires an absolute file path."
        case .failed(let message): return "Could not read EditorConfig settings. " + message
        case .timedOut: return "Reading EditorConfig settings took too long. Check the configuration files and try again."
        }
    }
}

public struct MergeEditorConfigProperties: Equatable, Sendable {
    public let properties: [String: String]
    public init(properties: [String: String]) { self.properties = properties }
    public var loaded: Bool { !properties.isEmpty }
    public var tabWidth: Int? {
        guard let value = properties["tab_width"], let width = Int(value), width > 0 else { return nil }
        return min(1000, width)
    }
    public var useSpaces: Bool? {
        switch properties["indent_style"] {
        case "space": return true
        case "tab": return false
        default: return nil
        }
    }
    public func applying(to defaults: MergeEditorPreferences) -> MergeEditorPreferences {
        var result = defaults
        if let tabWidth { result.tabWidth = tabWidth }
        if let useSpaces { result.useSpaces = useSpaces }
        return result
    }
}

public enum EditorConfigRuntime {
    public static func executable(bundle: Bundle = .main) throws -> URL {
        let url = bundle.bundleURL.appendingPathComponent("Contents/Helpers/EditorConfig/editorconfig")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw EditorConfigFailure.runtimeMissing }
        return url
    }
    /// Call off the main thread. The parser reads configurations only; a bounded
    /// child process and disk-backed output avoid UI and pipe stalls.
    public static func resolve(file: URL, executable: URL? = nil, bundle: Bundle = .main) throws -> MergeEditorConfigProperties {
        guard file.isFileURL, file.path.hasPrefix("/"), !file.path.contains("\0") else { throw EditorConfigFailure.invalidPath }
        try Task.checkCancellation()
        let parser = try executable ?? Self.executable(bundle: bundle)
        guard FileManager.default.isExecutableFile(atPath: parser.path) else { throw EditorConfigFailure.runtimeMissing }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitEditorConfig-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let outputURL = temporary.appendingPathComponent("stdout"), errorURL = temporary.appendingPathComponent("stderr")
        try Data().write(to: outputURL); try Data().write(to: errorURL)
        let output = try FileHandle(forWritingTo: outputURL), error = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? error.close() }
        let process = Process(), finished = DispatchSemaphore(value: 0)
        process.executableURL = parser; process.arguments = [file.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = error
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 5) == .timedOut {
            if process.isRunning { process.terminate() }
            if finished.wait(timeout: .now() + 1) == .timedOut, process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw EditorConfigFailure.timedOut
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            throw EditorConfigFailure.failed(String(decoding: try Data(contentsOf: errorURL).prefix(1024), as: UTF8.self))
        }
        guard let text = String(data: try Data(contentsOf: outputURL), encoding: .utf8) else { throw EditorConfigFailure.failed("Invalid parser output.") }
        var properties: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { throw EditorConfigFailure.failed("Invalid parser output.") }
            properties[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        return MergeEditorConfigProperties(properties: properties)
    }
}

public struct MergeEditorPreferences: Equatable, Sendable {
    public var tabWidth: Int
    public var useSpaces: Bool
    public var smartTab: Bool
    public var showLineNumbers: Bool
    public init(tabWidth: Int = 4, useSpaces: Bool = false, smartTab: Bool = false, showLineNumbers: Bool = true) {
        self.tabWidth = min(1000, max(1, tabWidth)); self.useSpaces = useSpaces; self.smartTab = smartTab
        self.showLineNumbers = showLineNumbers
    }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(tabWidth: defaults.object(forKey: "TurtleGitMerge.TabSize") == nil ? 4 : defaults.integer(forKey: "TurtleGitMerge.TabSize"),
             useSpaces: defaults.bool(forKey: "TurtleGitMerge.UseSpaces"), smartTab: defaults.bool(forKey: "TurtleGitMerge.SmartTab"),
             showLineNumbers: defaults.object(forKey: "TurtleGitMerge.ShowLineNumbers") == nil ? true : defaults.bool(forKey: "TurtleGitMerge.ShowLineNumbers"))
    }
    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(min(1000, max(1, tabWidth)), forKey: "TurtleGitMerge.TabSize")
        defaults.set(useSpaces, forKey: "TurtleGitMerge.UseSpaces")
        defaults.set(smartTab, forKey: "TurtleGitMerge.SmartTab")
        defaults.set(showLineNumbers, forKey: "TurtleGitMerge.ShowLineNumbers")
    }
}
