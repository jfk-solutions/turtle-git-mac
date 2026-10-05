import Foundation

public struct IssueMessageStyle: Sendable, Equatable {
    public enum Kind: String, Sendable { case context, identifier }
    public let kind: Kind
    public let range: NSRange
    public let url: String?
}

/// Serializes styling separately from repository mutations. Superseded queued
/// requests observe cancellation before starting another bounded helper.
public actor IssueMessageStyler {
    public init() {}
    public func styles(properties: IssueTrackerProperties, message: String) throws -> [IssueMessageStyle] {
        try Task.checkCancellation()
        return try properties.messageStyles(in: message)
    }
}

extension IssueTrackerProperties {
    /// SciEdit uses narrow ECMAScript regexes over UTF-8 bytes, unlike
    /// ProjectProperties' UTF-16 matcher. Call off the main thread.
    public func messageStyles(in message: String, executable: URL? = nil) throws -> [IssueMessageStyle] {
        guard !checkExpression.isEmpty, !message.isEmpty else { return [] }
        let output = try IssueRegexRuntime.capture(message: message, check: checkExpression, extract: extractionExpression, executable: executable, mode: ["--styles-utf8"])
        guard let text = String(data: output, encoding: .utf8) else { throw IssueRegexFailure.failed("Invalid styling output.") }
        let rows = text.split(separator: "\n")
        guard rows.first == "styles\tutf8" else { throw IssueRegexFailure.failed("Invalid styling output.") }
        var byteRanges: [(IssueMessageStyle.Kind, Int, Int)] = []
        var needed = Set<Int>()
        let length = message.utf8.count
        for row in rows.dropFirst() {
            let columns = row.split(separator: "\t")
            guard columns.count == 3, let kind = IssueMessageStyle.Kind(rawValue: String(columns[0])),
                  let start = Int(columns[1]), let count = Int(columns[2]), start >= 0, count > 0,
                  start <= length, count <= length - start else { throw IssueRegexFailure.failed("Invalid styling range.") }
            byteRanges.append((kind, start, count)); needed.insert(start); needed.insert(start + count)
        }
        var offsets: [Int: Int] = [:], byteOffset = 0, unitOffset = 0
        if needed.contains(0) { offsets[0] = 0 }
        for scalar in message.unicodeScalars {
            byteOffset += String(scalar).utf8.count; unitOffset += scalar.value > 0xFFFF ? 2 : 1
            if needed.contains(byteOffset) { offsets[byteOffset] = unitOffset }
        }
        var ranges: [(IssueMessageStyle.Kind, NSRange)] = []
        for (kind, start, count) in byteRanges {
            // AppKit cannot apply a style to part of a UTF-8 sequence. Preserve
            // byte regex semantics but omit unrepresentable partial scalars.
            guard let first = offsets[start], let end = offsets[start + count] else { continue }
            let range = NSRange(location: first, length: end - first)
            if let last = ranges.last, last.0 == kind, NSMaxRange(last.1) == first {
                ranges[ranges.count - 1] = (kind, NSRange(location: last.1.location, length: NSMaxRange(range) - last.1.location))
            } else { ranges.append((kind, range)) }
        }
        return ranges.map { kind, range in
            let id = (message as NSString).substring(with: range)
            let link = kind == .identifier ? issueURL(for: id) : ""
            return IssueMessageStyle(kind: kind, range: range, url: link.isEmpty ? nil : link)
        }
    }
    public func issueFieldValue(in message: String, executable: URL? = nil) throws -> String {
        try Self.naturalIssueIDs(identifiers(in: message, executable: executable))
    }
    static func naturalIssueIDs(_ ids: [String]) -> String {
        Set(ids).sorted { $0.compare($1, options: [.numeric, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) == .orderedAscending }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
