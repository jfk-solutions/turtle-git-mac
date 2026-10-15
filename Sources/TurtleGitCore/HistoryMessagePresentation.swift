// Adapts LogDlg::FillLogMessageCtrl/FindGitHashPositions and AppUtils rich-edit formatting.
// Copyright (C) TortoiseGit contributors. SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public struct HistoryMessageDocument: Equatable, Sendable {
    public struct Section: Equatable, Sendable {
        public let range: NSRange
        public let fields: HistorySearchFields
    }
    public let text: String
    public let hashStart: Int
    public let bold: [NSRange]
    public let sections: [Section]
    public init(plain text: String) { self.text = text; hashStart = text.utf16.count; bold = []; sections = [] }
    public init(hash: String, branchNumber: String? = nil, describe: String? = nil, subject: String, body: String, notes: String = "", tagInfo: String = "", asterisk: Bool = true) {
        var text = "SHA-1: ", bold: [NSRange] = [], sections: [Section] = []
        func append(_ value: String, fields: HistorySearchFields = [], strong: Bool = false) {
            let clean = value.replacingOccurrences(of: "\r", with: ""), range = NSRange(location: text.utf16.count, length: clean.utf16.count)
            text += clean
            if strong { bold.append(range) }; if !fields.isEmpty { sections.append(Section(range: range, fields: fields)) }
        }
        append(hash, fields: .revisions)
        if let branchNumber { append(", Branch RevNo: " + branchNumber) }
        let hashStart = text.utf16.count
        append("\n"); if let describe { append("Describe: " + describe + "\n") }; append("\n")
        if asterisk { append("* ") }
        append(subject, fields: [.subject,.messages], strong: true); append("\n"); append(body, fields: .messages)
        if !notes.isEmpty { append("\n" + (asterisk ? "* " : "")); append("Notes:\n", strong: true); append(notes, fields: .notes) }
        if !tagInfo.isEmpty { append("\n" + (asterisk ? "* " : "")); append("Tag Info:\n", strong: true); append(tagInfo, fields: .tagInfo) }
        self.text = text
        // Exclude both hash header and optional describe line from hash matching.
        self.hashStart = describe == nil ? hashStart : (text as NSString).range(of: "\n", range: NSRange(location: hashStart + 1, length: text.utf16.count - hashStart - 1)).location
        self.bold = bold; self.sections = sections
    }
}
public struct HistoryMessageOptions: Equatable, Sendable {
    public var formatting = true
    public var minimumHashLength = 8
    public var query = ""
    public var fields: HistorySearchFields = []
    public var regex = false
    public var caseSensitive = false
    public init(defaults: UserDefaults = .standard) {
        formatting = defaults.object(forKey: "StyleCommitMessages") as? Bool ?? true
        let number = (defaults.object(forKey: "ShortHashLengthForHyperLinkInLogMessage") as? NSNumber)?.uint32Value ?? 8
        minimumHashLength = min(40, max(3, Int(Int32(bitPattern: number))))
    }
}
public struct HistoryMessageLink: Equatable, Sendable {
    public enum Kind: Sendable { case hash, url }
    public let range: NSRange
    public let kind: Kind
    public let target: String
}
public struct HistoryMessageStyles: Equatable, Sendable {
    public var links: [HistoryMessageLink] = []
    public var bold: [NSRange] = []
    public var italic: [NSRange] = []
    public var underlined: [NSRange] = []
    public var highlights: [NSRange] = []
    public init() {}
}
public enum HistoryMessageHash {
    public static func ranges(in text: String, offset: Int = 0, minimum: Int = 8, cancellation: OperationCancellation? = nil) throws -> [NSRange] {
        let units = Array(text.utf16), count = units.count, minimum = min(40,max(3,minimum))
        var position = max(0,offset), result: [NSRange] = []
        func alphaNumeric(_ c: UInt16) -> Bool { (65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c) }
        func hex(_ c: UInt16) -> Bool { (48...57).contains(c) || (97...102).contains(c) }
        let trailers = ["git-svn-id:","Signed-off-by:","Change-Id:"].map { Array($0.utf16) }
        while position < count {
            if position % 1024 == 0 { try cancellation?.check() }
            var start = position
            let c = units[position]
            if c == 10 {
                position += 1
                if trailers.contains(where: { units[position...].starts(with: $0) }) {
                    while position < count && units[position] != 10 { position += 1 }
                }
            } else if (65...90).contains(c) || (104...122).contains(c) {
                repeat { position += 1 } while position < count && alphaNumeric(units[position])
            } else if (97...103).contains(c) || (48...57).contains(c) {
                if c == 103 { start += 1; position += 1 }
                while position < count && hex(units[position]) { position += 1 }
                let length = position - start
                if length >= minimum && length <= 40 && (position == count || units[position] != 64 && !alphaNumeric(units[position])) {
                    result.append(NSRange(location: start,length: length))
                }
                position += 1
            } else { position += 1 }
        }
        try cancellation?.check(); return result
    }
    /// Search below the marked row first, wrap, and exclude that row (JumpToGitHash).
    public static func target(prefix: String, hashes: [String], current: String) -> String? {
        guard !prefix.isEmpty, prefix.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }), let start = hashes.firstIndex(of: current), hashes.count > 1 else { return nil }
        for step in 1..<hashes.count { let hash = hashes[(start + step) % hashes.count]; if hash.hasPrefix(prefix) { return hash } }
        return nil
    }
}
public actor HistoryMessageStyler {
    public init() {}
    public func prepare(_ document: HistoryMessageDocument, properties: IssueTrackerProperties, options: HistoryMessageOptions, executable: URL? = nil, cancellation: OperationCancellation? = nil) throws -> HistoryMessageStyles {
        try cancellation?.check(); let text = document.text as NSString
        var result = HistoryMessageStyles(); result.bold = document.bold
        func add(_ range: NSRange, kind: HistoryMessageLink.Kind, target: String) {
            guard range.length > 0, !target.isEmpty else { return }
            result.links.removeAll { NSIntersectionRange($0.range,range).length > 0 }
            result.links.append(HistoryMessageLink(range:range,kind:kind,target:target))
        }
        for range in try HistoryMessageHash.ranges(in: document.text, offset: document.hashStart, minimum: options.minimumHashLength, cancellation: cancellation) { add(range,kind:.hash,target:text.substring(with:range)) }
        do {
            for range in try properties.logIssuePositions(in: document.text, executable: executable, cancellation: cancellation) { add(range,kind:.url,target:properties.issueURL(for:text.substring(with:range))) }
        } catch is IssueRegexFailure { /* Invalid source issue expressions do not suppress hashes/URLs. */ }
        for range in MessageURLFinder.ranges(in:document.text) { add(range,kind:.url,target:MessageURLFinder.target(for:text.substring(with:range))) }
        if options.formatting {
            result.bold += Self.formatting(document.text, marker:42)
            result.italic = Self.formatting(document.text, marker:94)
            result.underlined = Self.formatting(document.text, marker:95)
        }
        if !options.query.isEmpty {
            let sections = document.sections.filter { !$0.fields.intersection(options.fields).isEmpty }
            do {
                let ranges = try HistoryHighlighting.ranges(sections.map { text.substring(with:$0.range) }, query:options.query, regex:options.regex, caseSensitive:options.caseSensitive, executable:executable, cancellation:cancellation)
                result.highlights = HistoryHighlighting.merge(zip(sections,ranges).flatMap { section, ranges in ranges.map { NSRange(location:section.range.location + $0.location,length:$0.length) } })
            } catch is HistoryRegexFailure { /* Invalid filters retain the unhighlighted document. */ }
        }
        try cancellation?.check(); result.links.sort { $0.range.location < $1.range.location }; return result
    }
    /// RichEdit accumulates traits; its UTF-16 FindStyleChars differs from SciEdit.
    static func formatting(_ text: String, marker: UInt16) -> [NSRange] {
        let units = Array(text.utf16); var result: [NSRange] = [], lineStart = 0
        func alnum(_ c: UInt16) -> Bool { UnicodeScalar(c).map { CharacterSet.alphanumerics.contains($0) } ?? false }
        while lineStart < units.count {
            var end = lineStart; while end < units.count && units[end] != 10 { end += 1 }
            let line = Array(units[lineStart..<end]), last = line.count - 1
            var start = 0
            while start < last {
                var i = start, c: UInt16 = i == 0 ? 0 : line[i-1], next: UInt16 = i >= last ? 0 : line[i+1], found = false
                while i < last {
                    let previous = c; c = next; next = line[i+1]
                    if c == marker && c != next && alnum(next) && !alnum(previous) { i += 1; found = true; break }; i += 1
                }
                guard found else { break }; let first = i; found = false
                while i <= last {
                    let previous = c; c = line[i]
                    if c == marker && (i == last || !alnum(line[i+1]) && alnum(previous)) { found = true; break }; i += 1
                }
                guard found else { break }; result.append(NSRange(location:lineStart+first,length:i-first)); start = i
            }
            lineStart = end + 1
        }
        return result
    }
}
