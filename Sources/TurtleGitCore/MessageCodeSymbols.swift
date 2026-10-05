// Adapted from TortoiseGit CommitDlg.cpp::ParseRegexFile/ScanFile.
// Copyright (C) 2003-2021, 2023-2025 - TortoiseGit. GPL-2.0-or-later.
import Foundation

public struct MessageCodeDefinitions: Sendable {
    private var patterns: [[UInt16]: String] = [:]
    public init() {}
    public func pattern(for fileExtension: String) -> String? { patterns[Array(fileExtension.lowercased().utf16)] }
    public mutating func overlay(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        for (index, raw) in lines.enumerated() {
            var line = raw
            if index < lines.count - 1 && line.hasSuffix("\r") { line.removeLast() }
            guard !line.isEmpty, line.utf16.first != 35 else { continue }
            let originalEquals = (line as NSString).range(of: "=").location
            let equals = originalEquals == NSNotFound ? -1 : originalEquals
            let pattern = ((line as NSString).substring(from: equals + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            // The original eqpos is retained while the line is shortened. Keep
            // that behavior, including untrimmed early extension keys.
            while let comma = line.firstIndex(of: ","), line[..<comma].utf16.count < equals {
                patterns[Array(line[..<comma].utf16)] = pattern
                line = String(line[line.index(after: comma)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let finalEquals = line.firstIndex(of: "=")
            let key = finalEquals.map { String(line[..<$0]) } ?? ""
            patterns[Array(key.trimmingCharacters(in: .whitespacesAndNewlines).utf16)] = pattern
        }
    }
}

public enum MessageCodeSymbols {
    /// All nonempty capture groups, using the upstream icase ECMAScript engine.
    /// Run off the main actor. The bounded helper contains pathological regexes.
    public static func captures(in text: String, pattern: String, executable: URL? = nil) throws -> [String] {
        try captureUnits(in: Array(text.utf16), pattern: pattern, executable: executable).map { String(decoding: $0, as: UTF16.self) }
    }
    public static func captureUnits(in units: [UInt16], pattern: String, executable: URL? = nil) throws -> [[UInt16]] {
        guard !pattern.isEmpty else { return [] }
        let data = try IssueRegexRuntime.capture(message: "", check: pattern, extract: "", executable: executable, mode: ["--code-captures"], messageUnits: units)
        guard let output = String(data: data, encoding: .utf8) else { throw IssueRegexFailure.failed("Invalid code capture output.") }
        let lines = output.split(separator: "\n")
        guard lines.first == "captures\tutf16" else { throw IssueRegexFailure.failed("Invalid code capture header.") }
        var values = Set<[UInt16]>()
        for line in lines.dropFirst() {
            let columns = line.split(separator: "\t")
            guard columns.count == 2, let start = Int(columns[0]), let length = Int(columns[1]), start >= 0, length >= 0,
                  start <= units.count, length <= units.count - start else { throw IssueRegexFailure.failed("Invalid code capture range.") }
            values.insert(Array(units[start..<(start + length)]))
        }
        return values.sorted { $0.lexicographicallyPrecedes($1) }
    }
}
