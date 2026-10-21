// Native presentation of CGitBlameLogList's shared GitLogListBase cells.
// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// Presentation only: callers retain raw values and their own snapshot/action receipts.
@MainActor enum BlameHistoryPresentation {
    static func font(preferences: UserDefaults, head: Bool = false) -> NSFont {
        let base: NSFont
        if preferences.bool(forKey: "LogFontForLogCtrl") {
            base = MessageEditorFont.resolve(name: preferences.string(forKey: "LogFontName") ?? MessageEditorFont.defaultName,
                size: (preferences.object(forKey: "LogFontSize") as? NSNumber)?.intValue ?? MessageEditorFont.defaultSize)
        } else { base = .systemFont(ofSize: 12) }
        return head ? NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) : base
    }

    static func rowHeight(preferences: UserDefaults) -> CGFloat {
        let fonts = [font(preferences: preferences), font(preferences: preferences, head: true)]
        return max(24, ceil(fonts.map { $0.ascender - $0.descender + $0.leading }.max() ?? 0) + 8)
    }

    /// No user text is rewritten: these visible substitutes prevent injected rows/tabs,
    /// while the real field tooltip and copy operations retain the original string.
    static func display(_ raw: String) -> String {
        var value = raw.replacingOccurrences(of: "\r\n", with: "↵")
        for separator in ["\r", "\n", "\u{0085}", "\u{2028}", "\u{2029}", "\u{000B}", "\u{000C}"] {
            value = value.replacingOccurrences(of: separator, with: "↵")
        }
        return value.replacingOccurrences(of: "\t", with: "⇥")
    }

    static func attributedCaption(_ raw: String, preferences: UserDefaults, head: Bool = false) -> NSAttributedString {
        NSAttributedString(string: display(raw), attributes: [.font: font(preferences: preferences, head: head)])
    }

    static func attributedMessage(entry: LogEntry, context: HistoryReferenceContext, preferences: UserDefaults) -> NSAttributedString {
        let textFont = font(preferences: preferences, head: entry.isHead)
        let badgeFont = preferences.bool(forKey: "LogFontForLogCtrl") ? textFont :
            NSFont.systemFont(ofSize: 11, weight: entry.isHead ? .bold : .medium)
        let badges = NSMutableAttributedString(string: "")
        for badge in context.labels(entry.references, symbolize: preferences.bool(forKey: "SymbolizeRefNames")) {
            let color = LogPalette.native(LogColorRole.reference(badge.reference), preferences: preferences)
            let foreground = NSColor(name: nil) { _ in LogPalette.foreground(background: color) }
            let attributes: [NSAttributedString.Key: Any] = [.backgroundColor: color, .foregroundColor: foreground, .font: badgeFont]
            let start = badges.length
            badges.append(NSAttributedString(string: " ", attributes: attributes))
            if badge.singleRemote {
                let marker = NSMutableAttributedString(attachment: LogUpstreamMarker.attachment(foreground: foreground, font: badgeFont, isHead: entry.isHead))
                marker.addAttributes(attributes, range: NSRange(location: 0, length: marker.length)); badges.append(marker)
            }
            badges.append(NSAttributedString(string: display(badge.text) + " ", attributes: attributes))
            badges.addAttribute(.logReference, value: LogReferenceStyle(badge, color: color), range: NSRange(location: start, length: badges.length - start))
            let space = (" " as NSString).size(withAttributes: [.font: badgeFont]).width
            badges.addAttribute(.kern, value: 4 - space, range: NSRange(location: start, length: 1))
            badges.addAttribute(.kern, value: 4 - space + (badge.kind == .annotatedTag ? 8 : 0), range: NSRange(location: badges.length - 1, length: 1))
            badges.append(NSAttributedString(string: " ", attributes: [.font: badgeFont, .kern: 1 - space]))
        }
        let message = attributedCaption(entry.logLine(fullMessage: preferences.bool(forKey: "FullCommitMessageOnLogLine")), preferences: preferences, head: entry.isHead)
        let result = NSMutableAttributedString(string: "")
        if preferences.bool(forKey: "DrawTagsBranchesOnRightSide") {
            result.append(message)
            if badges.length > 0 { result.append(NSAttributedString(string: " ", attributes: [.font: textFont])); result.append(badges) }
        } else { result.append(badges); result.append(message) }
        return result
    }

    static func cell(value: NSAttributedString, tooltip: String, font: NSFont, message: Bool = false,
                     alignment: NSTextAlignment = .left) -> NSTableCellView {
        let text = NSTextField(labelWithString: "")
        if message {
            let painter = LogReferenceTextCell(textCell: "")
            painter.isEditable = false; painter.isSelectable = false; painter.isBordered = false; painter.drawsBackground = false
            text.cell = painter
        }
        text.font = font; text.attributedStringValue = value; text.alignment = alignment
        text.lineBreakMode = .byTruncatingTail; text.maximumNumberOfLines = 1; text.usesSingleLineMode = true
        text.cell?.wraps = false; text.cell?.isScrollable = true; text.toolTip = tooltip
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cell = NSTableCellView(); cell.textField = text; cell.addSubview(text); text.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }

    /// ColumnManager::GetWidth: body +14, optional Shift header +20. Measuring
    /// the actual attributed value includes HEAD, tag tips, upstream attachments
    /// and badge padding instead of fitting only the undecorated subject.
    static func fittingWidth(values: [NSAttributedString], header: String, includeHeader: Bool,
                             graphWidth: CGFloat = 0, headerFont: NSFont? = nil) -> CGFloat {
        let body = values.map { ceil($0.size().width) + 14 }.max() ?? 24
        let heading = includeHeader ? ceil((display(header) as NSString).size(withAttributes: [.font: headerFont ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width) + 20 : 0
        return min(10000, max(24, body, heading, graphWidth))
    }
}
