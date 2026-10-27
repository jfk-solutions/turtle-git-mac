// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Transient Scintilla zoom, independent of the configured Blame font size.
/// Editor.cxx bounds its offset to -10...60; ViewStyle clamps realized size to 1.
public struct GitBlameZoom: Equatable, Sendable {
    public static let offsetRange = -10...60
    public let offset: Int

    public init(offset: Int = 0) {
        self.offset = min(Self.offsetRange.upperBound, max(Self.offsetRange.lowerBound, offset))
    }
    public var canIncrease: Bool { offset < Self.offsetRange.upperBound }
    public var canDecrease: Bool { offset > Self.offsetRange.lowerBound }
    public func effectiveFontSize(base: Int) -> Int {
        max(1, min(1000, max(1, base)) + offset)
    }
    public func stepping(_ delta: Int) -> Self {
        // Bound the delta before addition, including Int.min/Int.max input.
        let step = min(Self.offsetRange.upperBound - offset, max(Self.offsetRange.lowerBound - offset, delta))
        return Self(offset: offset + step)
    }
    public func changesFont(by delta: Int, base: Int) -> Bool {
        stepping(delta).effectiveFontSize(base: base) != effectiveFontSize(base: base)
    }
}

/// Plain-text hover information from TortoiseGitBlameView::OnMouseHover.
/// Metadata must describe the captured line's revision; a late unrelated entry
/// cannot replace that line's author/message. Formatting performs no Git I/O.
public enum GitBlameTooltip {
    public static let maximumUTF16Length = 8000

    public static func text(line: GitBlameLine, entry: LogEntry? = nil, showFilename: Bool,
                            dateSettings: HistoryDateSettings, now: Date = Date(),
                            locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let working = line.hash.isEmpty || line.hash.allSatisfy { $0 == "0" }
        let revision = working ? String(localized: "Working tree") : line.hash
        let matching = !working && entry?.hash == line.hash ? entry : nil
        let author = matching.flatMap { $0.author.isEmpty ? nil : $0.author }
            ?? (line.author.isEmpty && working ? String(localized: "Not committed yet") : line.author)
        let email = matching.flatMap { $0.email.isEmpty ? nil : $0.email } ?? line.email
        let subject = matching?.historySubject ?? line.summary
        let body = matching.map { bodyExcerpt($0.historyBody) } ?? ""
        var rows = [String(localized: "Revision") + ": " + field(revision)]
        if showFilename { rows.append(String(localized: "Filename") + ": " + field(line.displayFilename)) }
        rows.append(String(localized: "Author") + ": " + field(author) + (email.isEmpty ? "" : " <" + field(email) + ">"))

        let parser = ISO8601DateFormatter()
        let date = matching.flatMap { parser.date(from: $0.date) } ?? line.date
        if date.timeIntervalSince1970.isFinite, !working || date.timeIntervalSince1970 != 0 {
            let formatted = dateSettings.format(parser.string(from: date), now: now, locale: locale, timeZone: timeZone)
            rows.append(String(localized: "Date") + ": " + field(formatted))
        }
        rows.append(String(localized: "Message") + ":\n" + field(subject) + "\n" + body)
        let result = rows.joined(separator: "\n")
        let bounded = prefix(result, utf16Limit: maximumUTF16Length)
        guard bounded.truncated else { return result }
        // Include the marker in the hard bound. Unlike CString::Truncate, never
        // split a surrogate pair, combining character or emoji grapheme.
        return prefix(result, utf16Limit: maximumUTF16Length - 3).text + "..."
    }

    private static func field(_ text: String) -> String {
        let bounded = prefix(text, utf16Limit: maximumUTF16Length + 1)
        return bounded.text + (bounded.truncated ? "..." : "")
    }

    private static func bodyExcerpt(_ text: String) -> String {
        // Keep allocation bounded even for a commit containing an enormous body.
        let candidate = field(text), units = Array(candidate.utf16)
        var nominalLines = 0, position = 0
        while nominalLines < 15 {
            nominalLines += 1
            guard let newline = units[position...].firstIndex(of: 10) else { return candidate }
            // Preserve the pinned source's LF/UTF-16 counting and 70-column
            // heuristic, including its terminal line without LF behavior.
            nominalLines += (newline - position - 1) / 70
            position = newline + 1
        }
        return String(decoding: units.prefix(position), as: UTF16.self) + "\n..."
    }

    private static func prefix(_ text: String, utf16Limit: Int) -> (text: String, truncated: Bool) {
        var result = "", count = 0
        for character in text {
            let size = character.utf16.count
            guard size <= utf16Limit - count else { return (result, true) }
            result.append(character); count += size
        }
        return (result, false)
    }
}
