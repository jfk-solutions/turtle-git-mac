// Adapted from TortoiseGitMerge MainFrm.cpp and FileTextLines.cpp.
// Copyright (C) 2016, 2019, 2021, 2023, 2025 - TortoiseGit
// Copyright (C) 2007-2016, 2019 - TortoiseSVN
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public struct MergeCommentTokens: Sendable, Equatable {
    public let line: String
    public let blockStart: String
    public let blockEnd: String
    public init(line: String, blockStart: String, blockEnd: String) { self.line = line; self.blockStart = blockStart; self.blockEnd = blockEnd }
}
public struct MergeCommentProfiles: Sendable {
    private var profiles: [String: MergeCommentTokens] = [:]
    public init(text: String) {
        for raw in text.components(separatedBy: .newlines) {
            guard let equals = raw.firstIndex(of: "=") else { continue }
            let fields = raw[raw.index(after: equals)...].split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            let tokens = MergeCommentTokens(line: String(fields[0]), blockStart: String(fields[1]), blockEnd: String(fields[2]))
            for name in raw[..<equals].split(separator: ",") { profiles[String(name).lowercased()] = tokens }
        }
    }
    private final class Anchor: NSObject {}
    public static func bundled() -> Self {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: Anchor.self)
        #endif
        let file = bundle.resourceURL?.appendingPathComponent("Completion/ignorecomments.txt")
        return Self(text: file.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "")
    }
    /// Source chooses Base, then Mine, then Theirs extension. Keep tokens
    /// literal, including SQL's required space after its -- line marker.
    public func tokens(paths: [String]) -> MergeCommentTokens? {
        paths.lazy.compactMap { profiles[($0 as NSString).pathExtension.lowercased()] }.first
    }
    public func tokens(fileExtension: String) -> MergeCommentTokens? { profiles[fileExtension.lowercased()] }
}
public enum MergeCommentStripping {
    /// Literal UTF-16 port of the source's fast quote-count heuristic. It is
    /// deliberately not a language parser: escaped/multiline strings and the
    /// source's single-quote progression are preserved, not silently improved.
    public static func strip(_ lines: [String], tokens: MergeCommentTokens, cancellation: OperationCancellation? = nil) throws -> [String] {
        let lineToken = Array(tokens.line.utf16), blockStart = Array(tokens.blockStart.utf16), blockEnd = Array(tokens.blockEnd.utf16)
        var inBlock = false
        let deadline = Date().addingTimeInterval(5)
        func find(_ text: [UInt16], _ needle: [UInt16], from start: Int = 0) -> Int {
            guard !needle.isEmpty, start >= 0, start <= text.count, needle.count <= text.count - start else { return -1 }
            for index in start...(text.count - needle.count) where text[index..<index + needle.count].elementsEqual(needle) { return index }
            return -1
        }
        func inString(_ text: [UInt16], at position: Int) -> Bool {
            var doubles = 0, singles = 0, cursor = find(text, [34])
            while cursor >= 0 && cursor < position { doubles += 1; cursor = find(text, [34], from: cursor + 1) }
            cursor = find(text, [39])
            while cursor >= 0 && cursor < position { singles += 1; cursor = find(text, [34], from: cursor + 1) }
            return doubles % 2 != 0 || singles % 2 != 0
        }
        return try lines.map { original in
            try cancellation?.check()
            var text = Array(original.utf16), start = 0, oldStart = -1
            guard text.count <= 8 * 1024 * 1024 else { throw MergeCommentFailure.limit }
            let maximumIterations = min(1_000_000, max(1024, text.count * 2))
            var iterations = 0
            repeat {
                iterations += 1; try cancellation?.check()
                guard iterations <= maximumIterations, text.count <= 8 * 1024 * 1024, Date() < deadline else { throw MergeCommentFailure.limit }
                if inBlock {
                    var end = find(text, blockEnd)
                    if inString(text, at: end) { end = -1 }
                    if end >= 0 && (end > start || end == 0) {
                        text = Array(text.prefix(start)) + Array(text.dropFirst(end + blockEnd.count))
                        inBlock = false; start = end
                    } else { text = Array(text.prefix(max(0, start))); start = -1 }
                }
                if !inBlock {
                    start = find(text, blockStart, from: max(0, start))
                    let line = find(text, lineToken)
                    if line >= 0 && (line < start || start < 0) {
                        if !inString(text, at: line) { text = Array(text.prefix(line)); start = -1 }
                        if start == oldStart { inBlock = false; break }
                        oldStart = start
                    } else if start >= 0 {
                        if !inString(text, at: start) { inBlock = true } else { start += 1 }
                    }
                }
            } while start >= 0
            return String(decoding: text, as: UTF16.self)
        }
    }
}
public enum MergeCommentFailure: LocalizedError {
    case limit
    public var errorDescription: String? { "Comment comparison exceeded its input or processing limit. Compare without ignoring comments or use a smaller file." }
}
