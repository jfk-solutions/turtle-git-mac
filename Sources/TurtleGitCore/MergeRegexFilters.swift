// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public struct MergeRegexFilter: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var expression: String
    public var replacement: String
    public var id: String { name }
    public init(name: String, expression: String, replacement: String) {
        self.name = name; self.expression = expression; self.replacement = replacement
    }
}

/// Named sections correspond to upstream regexfilters.ini. Selection is local
/// to a comparison window; only the definitions are persisted.
public enum MergeRegexFilters {
    private static let key = "TurtleGitMerge.RegexFilters"
    public static func load(defaults: UserDefaults = .standard) -> [MergeRegexFilter] {
        guard let data = defaults.data(forKey: key), let values = try? JSONDecoder().decode([MergeRegexFilter].self, from: data) else { return [] }
        return values
    }
    public static func save(_ values: [MergeRegexFilter], defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(values), forKey: key)
    }
    /// SimpleIni section names are case-insensitive. Renaming onto an existing
    /// name replaces that section rather than creating a duplicate menu entry.
    public static func updating(_ values: [MergeRegexFilter], oldName: String?, filter: MergeRegexFilter) -> [MergeRegexFilter] {
        var result = values.filter { value in
            !(oldName.map { value.name.caseInsensitiveCompare($0) == .orderedSame } ?? false)
        }
        if let index = result.firstIndex(where: { $0.name.caseInsensitiveCompare(filter.name) == .orderedSame }) { result[index] = filter }
        else { result.append(filter) }
        return result
    }
    public static func validate(_ filter: MergeRegexFilter, executable: URL? = nil, cancellation: OperationCancellation? = nil) throws {
        _ = try transformed([], filter: filter, executable: executable, cancellation: cancellation)
    }
    /// Runs off the UI thread. Framing preserves empty lines, embedded NUL,
    /// surrogate units and replacements that contain newlines without treating
    /// the output as a rewritten file. It is only an alignment key.
    public static func transformed(_ lines: [String], filter: MergeRegexFilter, executable: URL? = nil, cancellation: OperationCancellation? = nil) throws -> [String] {
        try cancellation?.check()
        var units: [UInt16] = []
        for line in lines {
            let value = Array(line.utf16)
            guard value.count <= Int(UInt32.max) else { throw MergeRegexFailure.invalidOutput }
            units += [UInt16(truncatingIfNeeded: value.count), UInt16(truncatingIfNeeded: value.count >> 16)] + value
        }
        let bytes: Data
        do { bytes = try IssueRegexRuntime.capture(message: "", check: filter.expression, extract: filter.replacement, executable: executable,
            mode: ["--merge-replace"], messageUnits: units, cancellation: cancellation) }
        catch IssueRegexFailure.runtimeMissing { throw MergeRegexFailure.runtimeMissing }
        catch IssueRegexFailure.timedOut { throw MergeRegexFailure.timedOut }
        catch IssueRegexFailure.failed(let detail) { throw MergeRegexFailure.expression(detail) }
        try cancellation?.check()
        guard bytes.count % 2 == 0 else { throw MergeRegexFailure.invalidOutput }
        let raw = [UInt8](bytes)
        let output = stride(from: 0, to: raw.count, by: 2).map { UInt16(raw[$0]) | UInt16(raw[$0 + 1]) << 8 }
        var offset = 0, result: [String] = []
        while offset < output.count {
            guard output.count - offset >= 2 else { throw MergeRegexFailure.invalidOutput }
            let count = Int(output[offset]) | Int(output[offset + 1]) << 16; offset += 2
            guard count <= output.count - offset else { throw MergeRegexFailure.invalidOutput }
            let value = String(decoding: output[offset..<offset + count], as: UTF16.self)
            guard Array(value.utf16).elementsEqual(output[offset..<offset + count]) else { throw MergeRegexFailure.invalidOutput }
            result.append(value); offset += count
        }
        guard result.count == lines.count else { throw MergeRegexFailure.invalidOutput }
        return result
    }
    public static func lines(_ text: String) -> [String] {
        let source = text as NSString
        return MergeLineEndings.lineRanges(in: text).map { source.substring(with: $0) }
    }
    public static func alignment(base: String, destination: String, filter: MergeRegexFilter, executable: URL? = nil, cancellation: OperationCancellation? = nil) throws -> FileComparisonAlignment {
        let a = lines(base), b = lines(destination)
        // LineRegex receives content without the original EOL. Retain endings
        // in comparison keys so this option doesn't also ignore EOL changes.
        let all = a + b
        let values = try transformed(all.map(MergeLineEndings.droppingFinalEnding), filter: filter, executable: executable, cancellation: cancellation)
        let keys = zip(all, values).map { original, filtered -> String in
            let content = MergeLineEndings.droppingFinalEnding(original)
            let suffix = (original as NSString).substring(from: (content as NSString).length)
            return filtered + suffix
        }
        return FileComparisonAlignment(base: base, destination: destination, baseKeys: Array(keys.prefix(a.count)), destinationKeys: Array(keys.dropFirst(a.count)))
    }
}
public enum MergeRegexFailure: LocalizedError {
    case runtimeMissing, timedOut, expression(String), invalidOutput
    public var errorDescription: String? {
        switch self {
        case .runtimeMissing: return "The comparison regex helper is missing. Rebuild TurtleGit with its matching runtime."
        case .timedOut: return "Filtering took too long. Check the regular expression."
        case .expression(let detail): return "Could not apply the regex filter. " + detail
        case .invalidOutput: return "The regex helper returned invalid comparison data."
        }
    }
}
