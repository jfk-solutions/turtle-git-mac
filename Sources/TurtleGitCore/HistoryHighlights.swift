// Adapted from TortoiseGit FilterHelper/GitLogListBase.
// Copyright (C) 2018-2023 TortoiseGit; 2010-2017 TortoiseSVN.
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// FilterHelper::GetMatchRanges: positive terms, overlapping occurrences and merged ranges.
public enum HistoryHighlighting {
    public static func merge(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = result.last, NSMaxRange(last) >= range.location {
                result[result.count - 1] = NSRange(location: last.location, length: max(NSMaxRange(last), NSMaxRange(range)) - last.location)
            } else { result.append(range) }
        }
        return result
    }
    /// Prepare once off the UI thread. Regex uses the bundled ECMAScript UTF-16 engine.
    public static func ranges(_ texts: [String], query: String, regex: Bool, caseSensitive: Bool, executable: URL? = nil, cancellation: OperationCancellation? = nil) throws -> [[NSRange]] {
        try cancellation?.check()
        if regex { return try IssueRegexRuntime.logRanges(texts, pattern: query, caseSensitive: caseSensitive, executable: executable, cancellation: cancellation) }
        let filter = HistoryTextQuery(query, caseSensitive: caseSensitive)
        return try texts.map { text in
            try cancellation?.check()
            return filter.matchRanges(in: text)
        }
    }
}
