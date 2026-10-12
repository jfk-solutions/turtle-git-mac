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
        guard let value = properties["tab_width"] else { return nil }
        // TortoiseMerge's wrapper uses atoi, then BaseView clamps to 1...1000.
        // Retain that behavior for unset, nonnumeric and numeric-prefix values.
        let width = value.withCString { Int(atoi($0)) }
        return min(1000, max(1, width))
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
        let data: Data
        do { data = try BundledTextHelper.capture(executable: parser, arguments: [file.path]) }
        catch BundledTextHelperFailure.timedOut { throw EditorConfigFailure.timedOut }
        catch BundledTextHelperFailure.failed(let message) { throw EditorConfigFailure.failed(message) }
        guard let text = String(data: data, encoding: .utf8) else { throw EditorConfigFailure.failed("Invalid parser output.") }
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
    public var autoAdd: Bool
    public var enableEditorConfig: Bool
    public init(tabWidth: Int = 4, useSpaces: Bool = false, smartTab: Bool = false, showLineNumbers: Bool = true, enableEditorConfig: Bool = false, autoAdd: Bool = true) {
        self.tabWidth = min(1000, max(1, tabWidth)); self.useSpaces = useSpaces; self.smartTab = smartTab
        self.showLineNumbers = showLineNumbers; self.enableEditorConfig = enableEditorConfig; self.autoAdd = autoAdd
    }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(tabWidth: defaults.object(forKey: "TurtleGitMerge.TabSize") == nil ? 4 : defaults.integer(forKey: "TurtleGitMerge.TabSize"),
             useSpaces: defaults.bool(forKey: "TurtleGitMerge.UseSpaces"), smartTab: defaults.bool(forKey: "TurtleGitMerge.SmartTab"),
             showLineNumbers: defaults.object(forKey: "TurtleGitMerge.ShowLineNumbers") == nil ? true : defaults.bool(forKey: "TurtleGitMerge.ShowLineNumbers"),
             enableEditorConfig: defaults.bool(forKey: "TurtleGitMerge.EnableEditorConfig"),
             autoAdd: defaults.object(forKey: "TurtleGitMerge.AutoAdd") == nil ? true : defaults.bool(forKey: "TurtleGitMerge.AutoAdd"))
    }
    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(min(1000, max(1, tabWidth)), forKey: "TurtleGitMerge.TabSize")
        defaults.set(useSpaces, forKey: "TurtleGitMerge.UseSpaces")
        defaults.set(smartTab, forKey: "TurtleGitMerge.SmartTab")
        defaults.set(showLineNumbers, forKey: "TurtleGitMerge.ShowLineNumbers")
        defaults.set(autoAdd, forKey: "TurtleGitMerge.AutoAdd")
        defaults.set(enableEditorConfig, forKey: "TurtleGitMerge.EnableEditorConfig")
    }
}

/// SetMainPage's source font, inline bound and load-navigation preferences.
public struct MergeGeneralPreferences: Equatable, Sendable {
    public var fontName: String
    public var fontSize: Int
    public var maximumInlineLength: Int
    public var firstDifference: Bool
    public var firstConflict: Bool
    public init(fontName: String = "Consolas", fontSize: Int = 10, maximumInlineLength: Int = 3000, firstDifference: Bool = true, firstConflict: Bool = true) {
        self.fontName = fontName.isEmpty ? "Consolas" : String(fontName.prefix(256))
        self.fontSize = min(72, max(6, fontSize)); self.maximumInlineLength = min(100_000, max(0, maximumInlineLength))
        self.firstDifference = firstDifference; self.firstConflict = firstConflict
    }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(fontName: defaults.string(forKey: "TurtleGitMerge.LogFontName") ?? "Consolas",
             fontSize: defaults.object(forKey: "TurtleGitMerge.LogFontSize") == nil ? 10 : defaults.integer(forKey: "TurtleGitMerge.LogFontSize"),
             maximumInlineLength: defaults.object(forKey: "TurtleGitMerge.InlineDiffMaxLineLength") == nil ? 3000 : defaults.integer(forKey: "TurtleGitMerge.InlineDiffMaxLineLength"),
             firstDifference: defaults.object(forKey: "TurtleGitMerge.FirstDiffOnLoad") == nil ? true : defaults.bool(forKey: "TurtleGitMerge.FirstDiffOnLoad"),
             firstConflict: defaults.object(forKey: "TurtleGitMerge.FirstConflictOnLoad") == nil ? true : defaults.bool(forKey: "TurtleGitMerge.FirstConflictOnLoad"))
    }
    public func save(to defaults: UserDefaults = .standard) {
        let value = Self(fontName: fontName, fontSize: fontSize, maximumInlineLength: maximumInlineLength, firstDifference: firstDifference, firstConflict: firstConflict)
        defaults.set(value.fontName, forKey: "TurtleGitMerge.LogFontName"); defaults.set(value.fontSize, forKey: "TurtleGitMerge.LogFontSize")
        defaults.set(value.maximumInlineLength, forKey: "TurtleGitMerge.InlineDiffMaxLineLength")
        defaults.set(value.firstDifference, forKey: "TurtleGitMerge.FirstDiffOnLoad"); defaults.set(value.firstConflict, forKey: "TurtleGitMerge.FirstConflictOnLoad")
    }
    public func inlineAllowed(baseLength: Int, mineLength: Int) -> Bool { baseLength <= maximumInlineLength && mineLength <= maximumInlineLength }
    /// MainFrm checks FirstConflict independently of FirstDiff, even though the
    /// settings checkbox is disabled when FirstDiff is off. Retain that ordering.
    public func initialTarget(difference: NSRange?, conflict: NSRange?) -> NSRange? {
        if firstConflict, let conflict { return conflict }
        return firstDifference ? difference : nil
    }
}
