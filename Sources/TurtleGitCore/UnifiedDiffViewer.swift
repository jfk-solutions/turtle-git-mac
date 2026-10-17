import Foundation

/// A read-only patch may contain bytes that cannot be represented in the
/// display encoding. Unedited exports retain original data; edits use the captured codec.
public struct UnifiedDiffDocument: Sendable {
    public let bytes: Data
    public let displayLegacyEncoding:ComparisonTextEncoding
    public let sourceEncoding:ComparisonTextEncoding
    private let retainedEncoding:Bool
    private static let signatures:[([UInt8],ComparisonTextEncoding,String.Encoding)] = [
        ([0xff,0xfe,0,0],.utf32LE,.utf32LittleEndian),([0,0,0xfe,0xff],.utf32BE,.utf32BigEndian),
        ([0xff,0xfe],.utf16LEBOM,.utf16LittleEndian),([0xfe,0xff],.utf16BEBOM,.utf16BigEndian),([0xef,0xbb,0xbf],.utf8BOM,.utf8)
    ]
    public init(bytes:Data,displayLegacyEncoding:ComparisonTextEncoding = .windows1252,sourceEncoding:ComparisonTextEncoding? = nil) {
        self.bytes=bytes
        self.displayLegacyEncoding=displayLegacyEncoding.legacyCodePage == nil ? .windows1252:displayLegacyEncoding
        retainedEncoding=sourceEncoding != nil
        self.sourceEncoding=sourceEncoding ?? Self.signatures.first(where:{bytes.starts(with:$0.0)})?.1
            ?? (String(data:bytes,encoding:.utf8) == nil ? self.displayLegacyEncoding:.utf8)
    }
    public var displayText:String {
        if retainedEncoding,let text=sourceEncoding.decode(bytes) {return text}
        // BOMs precede line-local UTF8/legacy display. Prefixing a sentinel keeps
        // a real leading FEFF character after the one file BOM is removed.
        for (signature,_,encoding) in Self.signatures where bytes.starts(with:signature) {
            let body=Data(bytes.dropFirst(signature.count)),width=encoding == .utf32LittleEndian || encoding == .utf32BigEndian ? 4:encoding == .utf8 ? 1:2
            if body.count % width == 0,let prefix="x".data(using:encoding),var text=String(data:prefix+body,encoding:encoding),text.first == "x" {text.removeFirst();return text}
            return String(decoding:bytes,as:UTF8.self)
        }
        return GitPatch.displayText(bytes,displayLegacyEncoding:displayLegacyEncoding)
    }
    public func encodedEdits(_ text:String) throws ->Data {
        if text.utf8.elementsEqual(displayText.utf8) {return bytes}
        return try sourceEncoding.encode(text)
    }
    public func recording(_ bytes:Data)->Self {
        if bytes == self.bytes {return self}
        return Self(bytes:bytes,displayLegacyEncoding:displayLegacyEncoding,sourceEncoding:sourceEncoding)
    }
    public func write(to url:URL) throws {try bytes.write(to:url,options:.atomic)}
}

public enum UnifiedDiffViewerChoice: Equatable, Sendable {
    case builtin, external(URL)
}
public enum UnifiedDiffViewerFailure: LocalizedError {
    case application
    public var errorDescription: String? { "Choose an application bundle or executable in Settings → Unified Diff Viewer." }
}

/// AppUtils::StartUnifiedDiffViewer inverts enabled/disabled external selection
/// for Shift. A saved disabled viewer remains available for that alternate use.
public struct UnifiedDiffViewerPreferences: Equatable, Sendable {
    public var enabled: Bool
    public var applicationPath: String
    public var bookmark: Data?
    public var arguments: String
    public init(enabled: Bool = false, applicationPath: String = "", bookmark: Data? = nil, arguments: String = "") {
        self.enabled = enabled; self.applicationPath = applicationPath; self.bookmark = bookmark; self.arguments = arguments
    }
    public var program: DiffToolProgram {
        var value = DiffToolProgram(); value.enabled = true; value.applicationPath = applicationPath; value.bookmark = bookmark; value.arguments = arguments; return value
    }
    public var argumentsValid: Bool { (try? DiffToolProgram.argumentTokens(arguments)) != nil }
    private var applicationValid: Bool { var value = program; value.arguments = ""; return value.valid }
    public var valid: Bool { !enabled || applicationValid && argumentsValid }
    public func expandedArguments(file: URL, title: String) throws -> [String] {
        guard file.isFileURL, !file.path.contains("\0"), !title.contains("\0") else { throw DiffToolFailure.arguments }
        return try program.expandedArguments(values: ["1": file.path, "title": title], files: ["1"])
    }
    public func choice(alternate: Bool = false) throws -> UnifiedDiffViewerChoice {
        guard !applicationPath.isEmpty, enabled != alternate else { return .builtin }
        guard applicationValid else { throw UnifiedDiffViewerFailure.application }
        guard argumentsValid else { throw DiffToolFailure.arguments }
        return .external(URL(fileURLWithPath: applicationPath, isDirectory: program.isApplicationBundle))
    }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(enabled: defaults.bool(forKey: "TurtleGit.UnifiedDiffViewer.Enabled"),
             applicationPath: defaults.string(forKey: "TurtleGit.UnifiedDiffViewer.Application") ?? "",
             bookmark: defaults.data(forKey: "TurtleGit.UnifiedDiffViewer.Bookmark"),
             arguments: defaults.string(forKey: "TurtleGit.UnifiedDiffViewer.Arguments") ?? "")
    }
    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: "TurtleGit.UnifiedDiffViewer.Enabled")
        defaults.set(applicationPath, forKey: "TurtleGit.UnifiedDiffViewer.Application")
        defaults.set(bookmark, forKey: "TurtleGit.UnifiedDiffViewer.Bookmark")
        defaults.set(arguments, forKey: "TurtleGit.UnifiedDiffViewer.Arguments")
    }
}

/// An exact byte copy for external viewers, kept until application termination.
/// It never overwrites a repository file or an earlier preview.
public struct UnifiedDiffPreview: Sendable {
    public let directory: URL
    public let file: URL
    public static func create(_ bytes: Data) throws -> Self {
        let manager = FileManager.default
        let directory = try TurtleGitTemporaryStorage.root.appendingPathComponent("TurtleGitUnifiedDiffPreview-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let file = directory.appendingPathComponent("diff.patch")
            try bytes.write(to: file, options: .withoutOverwriting)
            try manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
            return Self(directory: directory, file: file)
        } catch { try? manager.removeItem(at: directory); throw error }
    }
    public func discard() { try? FileManager.default.removeItem(at: directory) }
}
