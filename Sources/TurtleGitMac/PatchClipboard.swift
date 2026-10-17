// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// The registered Windows TGIT_UNIFIEDDIFF format becomes a native macOS UTI.
/// Clipboard reads occur only on an explicit action, never during menu polling.
@MainActor enum PatchClipboard {
    static let unifiedDiff = NSPasteboard.PasteboardType(FinderPatchHandoff.clipboardType)
    static let legacyUnifiedDiff = NSPasteboard.PasteboardType(FinderPatchHandoff.legacyClipboardType)
    static func snapshot(from pasteboard: NSPasteboard = .general) -> Data? {
        for type in [unifiedDiff, legacyUnifiedDiff] {
            if let bytes = pasteboard.data(forType: type), !bytes.isEmpty { return bytes }
        }
        // Native interoperability: ordinary copied diff text is accepted on the
        // explicit Review Clipboard action; private-format bytes take priority.
        guard let text = pasteboard.string(forType: .string),
              text.contains("\n@@ ") || text.hasPrefix("diff --git ") || text.hasPrefix("--- ") else { return nil }
        return Data(text.utf8)
    }
    @discardableResult static func write(_ document: UnifiedDiffDocument, to pasteboard: NSPasteboard = .general) -> Bool {
        guard !document.bytes.isEmpty else { return false }
        let item = NSPasteboardItem()
        guard item.setData(document.bytes, forType: unifiedDiff), item.setData(document.bytes, forType: legacyUnifiedDiff),
              item.setString(document.displayText, forType: .string) else { return false }
        pasteboard.clearContents(); return pasteboard.writeObjects([item])
    }
}
