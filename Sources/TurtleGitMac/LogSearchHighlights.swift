// Adapted from TortoiseGit FilterHelper/GitLogListBase.
// Copyright (C) 2018-2023 TortoiseGit; 2010-2017 TortoiseSVN.
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import TurtleGitCore

/// Display-column gates from GitLogListBase's match drawing, with ranges relative to cell text.
enum LogSearchHighlights {
    static func prepare(_ entries: [LogEntry], query: String, regex: Bool, caseSensitive: Bool, fields: HistorySearchFields, fullMessage: Bool, labeled: Set<String>, executable: URL?, cancellation: OperationCancellation? = nil) throws -> [String: [String: [NSRange]]] {
        var keys: [(String, String)] = [], texts: [String] = []
        for entry in entries {
            func add(_ column: String, _ value: String, _ enabled: Bool) {
                if enabled { keys.append((entry.hash, column)); texts.append(value) }
            }
            let messageFields: HistorySearchFields = labeled.contains(entry.hash) && !fullMessage ? .subject : [.subject, .messages]
            add("message", entry.logLine(fullMessage: fullMessage), !fields.intersection(messageFields).isEmpty && (entry.references.isEmpty || labeled.contains(entry.hash)))
            add("hash", entry.hash, fields.contains(.revisions))
            add("author", entry.author, fields.contains(.authors)); add("committer", entry.committer, fields.contains(.authors))
            add("email", entry.email, fields.contains(.emails)); add("committerEmail", entry.committerEmail, fields.contains(.emails))
            add("bugs", entry.issueIDs, fields.contains(.bugIDs))
        }
        guard !texts.isEmpty else { return [:] }
        let ranges = try HistoryHighlighting.ranges(texts, query: query, regex: regex, caseSensitive: caseSensitive, executable: executable, cancellation: cancellation)
        var result: [String: [String: [NSRange]]] = [:]
        for (key, ranges) in zip(keys, ranges) where !ranges.isEmpty { result[key.0, default: [:]][key.1] = ranges }
        return result
    }
}
