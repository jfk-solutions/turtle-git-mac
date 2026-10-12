// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum MergeWhitespaceComparison: Int, CaseIterable, Sendable {
    case compare = 0, ignoreChanges = 1, ignoreAll = 2
    public var title: String {
        switch self {
        case .compare: return "Compare whitespaces"
        case .ignoreChanges: return "Ignore whitespace changes"
        case .ignoreAll: return "Ignore all whitespace changes"
        }
    }
}
public struct MergeComparisonOptions: Equatable, Sendable {
    public var whitespace: MergeWhitespaceComparison
    public var ignoreCase: Bool
    public var ignoreEndings: Bool
    public init(whitespace: MergeWhitespaceComparison = .compare, ignoreCase: Bool = false, ignoreEndings: Bool = true) {
        self.whitespace = whitespace; self.ignoreCase = ignoreCase; self.ignoreEndings = ignoreEndings
    }
    /// Low-level engine callers keep explicit exact-byte comparison. App
    /// preferences default to the source's recommended IgnoreEOL=true.
    public static let exact = Self(ignoreEndings: false)
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        .init(whitespace: MergeWhitespaceComparison(rawValue: defaults.integer(forKey: "TurtleGitMerge.IgnoreWS")) ?? .compare,
              ignoreCase: defaults.bool(forKey: "TurtleGitMerge.CaseInsensitive"),
              ignoreEndings: defaults.object(forKey: "TurtleGitMerge.IgnoreEOL") == nil ? true : defaults.bool(forKey: "TurtleGitMerge.IgnoreEOL"))
    }
    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(whitespace.rawValue, forKey: "TurtleGitMerge.IgnoreWS")
        defaults.set(ignoreCase, forKey: "TurtleGitMerge.CaseInsensitive")
        defaults.set(ignoreEndings, forKey: "TurtleGitMerge.IgnoreEOL")
    }
    /// Keys only; display/edit/save always use captured originals. ASCII
    /// whitespace follows svn_diff__normalize_buffer's non-EOL character set.
    /// Case uses macOS Unicode lowercase; Windows locale edge cases remain a
    /// separate acceptance gate rather than using Unicode full case folding.
    public func key(content: String, ending: String) -> String {
        var bytes: [UInt8] = [], inWhitespace = false
        for byte in content.utf8 {
            let whitespaceByte = byte == 32 || byte == 9 || byte == 11 || byte == 12
            if whitespace != .compare && whitespaceByte {
                if whitespace == .ignoreChanges && !inWhitespace { bytes.append(32) }
                inWhitespace = true
            } else { bytes.append(byte); inWhitespace = false }
        }
        var text = String(decoding: bytes, as: UTF8.self)
        if ignoreCase { text = text.lowercased(with: Locale(identifier: "en_US_POSIX")) }
        return text + (ignoreEndings && !ending.isEmpty ? "\n" : ending)
    }
}
