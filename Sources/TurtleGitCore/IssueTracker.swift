// Commit issue behavior adapted from TortoiseGit ProjectProperties.cpp.
// Copyright (C) 2003-2021, 2023-2025 - TortoiseGit
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum IssueTrackerFailure: LocalizedError {
    case invalidIssueID, malformedConfiguration
    public var errorDescription: String? {
        switch self {
        case .invalidIssueID: return "The issue ID must contain only numbers, commas and spaces."
        case .malformedConfiguration: return "Invalid issue-tracker configuration output."
        }
    }
}

public struct IssueCommitPreparation: Sendable {
    public let message: String
    public let requiresIssueWarning: Bool
}

/// Commit-facing subset of TortoiseGit ProjectProperties. Regex matching uses
/// the bundled C++ engine; these operations never modify Git state.
public struct IssueTrackerProperties: Sendable, Equatable {
    public var label = "Bug-ID/Issue-Nr:"
    public var messageTemplate = ""
    public var urlTemplate = ""
    public var numbersOnly = true
    public var append = true
    public var warnIfNoIssue = false
    public var warnNoSignedOffBy = false
    public var checkExpression = ""
    public var extractionExpression = ""
    public var showsIssueField: Bool { !messageTemplate.isEmpty }
    public init(values: [String: String] = [:]) {
        if let value = values["bugtraq.label"], !value.isEmpty { label = value }
        messageTemplate = values["bugtraq.message"] ?? ""
        urlTemplate = values["bugtraq.url"] ?? ""
        numbersOnly = Self.boolean(values["bugtraq.number"], default: true)
        append = Self.boolean(values["bugtraq.append"], default: true)
        warnIfNoIssue = Self.boolean(values["bugtraq.warnifnoissue"], default: false)
        warnNoSignedOffBy = Self.boolean(values["tgit.warnnosignedoffby"], default: false)
        let expression = (values["bugtraq.logregex"] ?? "") as NSString
        let split = expression.range(of: "\n").location
        if split != NSNotFound {
            checkExpression = expression.substring(to: split).trimmingCharacters(in: .whitespacesAndNewlines)
            extractionExpression = expression.substring(from: split).trimmingCharacters(in: .whitespacesAndNewlines)
        } else { checkExpression = (expression as String).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    private static func boolean(_ value: String?, default fallback: Bool) -> Bool {
        guard let value else { return fallback }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "on": return true
        case "false", "no", "off", "": return false
        default: return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)).map { $0 != 0 } ?? fallback
        }
    }
    public func validatesIssueID(_ id: String) -> Bool {
        !numbersOnly || id.utf16.allSatisfy { (48...57).contains($0) || $0 == 44 || $0 == 32 }
    }
    private static func trimmingTrailingLF(_ message: String) -> String {
        let text = message as NSString
        var length = text.length
        while length > 0, text.character(at: length - 1) == 10 { length -= 1 }
        return text.substring(to: length)
    }
    private func templateLine(in message: String) -> (text: NSString, line: NSRange, id: NSRange, top: Bool)? {
        guard let placeholder = messageTemplate.range(of: "%BUGID%") else { return nil }
        let prefix = String(messageTemplate[..<placeholder.lowerBound]), suffix = String(messageTemplate[placeholder.upperBound...])
        let trimmed = Self.trimmingTrailingLF(message)
        let text = trimmed as NSString
        let firstBreak = text.range(of: "\n"), lastBreak = text.range(of: "\n", options: .backwards)
        let first = NSRange(location: 0, length: firstBreak.location == NSNotFound ? text.length : firstBreak.location)
        let last = NSRange(location: lastBreak.location == NSNotFound ? 0 : lastBreak.location + 1, length: lastBreak.location == NSNotFound ? text.length : text.length - lastBreak.location - 1)
        for (line, top) in [(append ? last : first, !append), (first, true)] {
            let value = text.substring(with: line)
            let prefixLength = prefix.utf16.count, suffixLength = suffix.utf16.count
            if !value.isEmpty && value.utf16.starts(with: prefix.utf16) && value.utf16.suffix(suffixLength).elementsEqual(suffix.utf16) && line.length >= prefixLength + suffixLength {
                return (text, line, NSRange(location: line.location + prefixLength, length: line.length - prefixLength - suffixLength), top)
            }
        }
        return nil
    }
    /// Seed the separate field and remove its template line, trimming only LF.
    public func separateIssueLine(from message: String) -> (message: String, issueID: String) {
        guard messageTemplate.contains("%BUGID%") else { return (message, "") }
        let trimmed = Self.trimmingTrailingLF(message)
        guard let found = templateLine(in: trimmed) else { return (trimmed, "") }
        let id = found.text.substring(with: found.id)
        let rest: String
        if found.top {
            rest = found.text.substring(from: NSMaxRange(found.line)).drop(while: { $0 == "\n" }).description
        } else {
            rest = Self.trimmingTrailingLF(found.text.substring(to: found.line.location))
        }
        return (rest, id)
    }
    public func identifiers(in message: String, executable: URL? = nil) throws -> [String] {
        if !checkExpression.isEmpty {
            return try IssueRegexRuntime.match(message: message, check: checkExpression, extract: extractionExpression, executable: executable).identifiers(in: message)
        }
        guard let found = templateLine(in: message), found.id.length > 0 else { return [] }
        // Upstream trims edge commas before splitting, while retaining the
        // original offset. Preserve that behavior rather than normalizing IDs.
        var section = found.text.substring(with: found.id)
        while section.first == "," { section.removeFirst() }
        while section.last == "," { section.removeLast() }
        var offset = found.id.location
        return section.components(separatedBy: ",").map { part in
            defer { offset += part.utf16.count + 1 }
            return found.text.substring(with: NSRange(location: offset, length: part.utf16.count))
        }
    }
    public func prepareCommit(message: String, issueID: String, executable: URL? = nil) throws -> IssueCommitPreparation {
        guard validatesIssueID(issueID) else {
            throw IssueTrackerFailure.invalidIssueID
        }
        let match = checkExpression.isEmpty ? nil : try IssueRegexRuntime.match(message: message, check: checkExpression, extract: extractionExpression, executable: executable)
        let warning = warnIfNoIssue && issueID.isEmpty && match?.hasMatch != true
        let id = issueID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, showsIssueField else { return IssueCommitPreparation(message: message, requiresIssueWarning: warning) }
        let ids = try match?.identifiers(in: message) ?? identifiers(in: message, executable: executable)
        // Foundation's numeric comparison supplies natural numeric ordering.
        // Full StrCmpLogicalW punctuation/locale parity is still under audit.
        let existing = Self.naturalIssueIDs(ids)
        guard id != existing else { return IssueCommitPreparation(message: message, requiresIssueWarning: warning) }
        let normalized = id.replacingOccurrences(of: ", ", with: ",").replacingOccurrences(of: " ,", with: ",")
        let line = messageTemplate.replacingOccurrences(of: "%BUGID%", with: normalized)
        return IssueCommitPreparation(message: append ? message + "\n" + line + "\n" : line + "\n" + message, requiresIssueWarning: warning)
    }
    public func issueURL(for id: String) -> String {
        guard showsIssueField || !checkExpression.isEmpty else { return urlTemplate }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return urlTemplate.replacingOccurrences(of: "%BUGID%", with: id.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
    }
    public static func addingSignOff(_ line: String, to message: String) -> String {
        guard !message.contains(line) else { return message }
        var text = message
        while let character = text.last, character.isWhitespace { text.removeLast() }
        let lastLine = text.components(separatedBy: "\n").last ?? ""
        let lastBreak = (text as NSString).range(of: "\n", options: .backwards).location
        let hasTrailer = lastBreak != NSNotFound && lastBreak > 0 && lastLine.contains("-by: ")
        return text + (hasTrailer ? "\n" : "\n\n") + line + "\n"
    }
}

extension GitRepository {
    public func issueTrackerProperties(environmentOverrides: [String: String] = [:]) throws -> IssueTrackerProperties {
        let pattern = "^(bugtraq\\.|tgit\\.warnnosignedoffby$)"
        let configured = try run(["config", "--null", "--show-scope", "--get-regexp", pattern], environmentOverrides: environmentOverrides, successfulExitCodes: 0...1).stdout
        var records = configured.split(separator: 0, omittingEmptySubsequences: false)
        if records.last?.isEmpty == true { records.removeLast() }
        guard records.count % 2 == 0 else { throw IssueTrackerFailure.malformedConfiguration }
        var low: [String: String] = [:], high: [String: String] = [:]
        for index in stride(from: 0, to: records.count, by: 2) {
            let scope = String(decoding: records[index], as: UTF8.self)
            let pair = Self.issueConfigPair(Data(records[index + 1]))
            if ["local", "worktree", "command"].contains(scope) { high[pair.0] = pair.1 }
            else { low[pair.0] = pair.1 }
        }
        var project: Data?
        if try isBare() { project = try? run(["show", "HEAD:.tgitconfig"]).stdout }
        else {
            let file = root.appendingPathComponent(".tgitconfig")
            if FileManager.default.fileExists(atPath: file.path) { project = try Data(contentsOf: file) }
        }
        if let project {
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitProjectProperties-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let file: URL
            if try isBare() { file = temporary.appendingPathComponent(".tgitconfig"); try project.write(to: file) }
            else { file = root.appendingPathComponent(".tgitconfig") }
            let values = try run(["config", "--includes", "--file", file.path, "--null", "--get-regexp", pattern], environmentOverrides: environmentOverrides, successfulExitCodes: 0...1).stdout
            for record in values.split(separator: 0) {
                let pair = Self.issueConfigPair(Data(record)); low[pair.0] = pair.1
            }
        }
        low.merge(high) { _, higher in higher }
        return IssueTrackerProperties(values: low)
    }
    private static func issueConfigPair(_ record: Data) -> (String, String) {
        guard let split = record.firstIndex(of: 10) else {
            let key = String(decoding: record, as: UTF8.self).lowercased()
            return (key, ["bugtraq.number", "bugtraq.append", "bugtraq.warnifnoissue", "tgit.warnnosignedoffby"].contains(key) ? "true" : "")
        }
        return (String(decoding: record[..<split], as: UTF8.self).lowercased(), String(decoding: record[record.index(after: split)...], as: UTF8.self))
    }
    public func prepareIssueCommit(properties: IssueTrackerProperties, message: String, issueID: String) throws -> IssueCommitPreparation {
        try properties.prepareCommit(message: message, issueID: issueID)
    }
    public func issueFieldValue(properties: IssueTrackerProperties, message: String) throws -> String {
        try properties.issueFieldValue(in: message)
    }
    public func commitSignOffLine() throws -> String {
        let name = try run(["config", "user.name"]).text.replacingOccurrences(of: "\n", with: "")
        let email = try run(["config", "user.email"]).text.replacingOccurrences(of: "\n", with: "")
        return "Signed-off-by: \(name) <\(email)>"
    }
}
