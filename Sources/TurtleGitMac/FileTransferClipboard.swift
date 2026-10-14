// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
@MainActor enum FileTransferClipboard {
    static func urls(_ pasteboard: NSPasteboard = .general) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    static func copy(_ urls: [URL], pasteboard: NSPasteboard = .general) {
        guard !urls.isEmpty else { return }; pasteboard.clearContents(); pasteboard.writeObjects(urls.map { $0 as NSURL })
    }
}
