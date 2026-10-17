// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore
@MainActor enum FileTransferClipboard {
    static func urls(_ pasteboard: NSPasteboard = .general) -> [URL] {
        FileTransferPaths.uniqueURLs((pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? [])
    }
    static func copy(_ urls: [URL], pasteboard: NSPasteboard = .general) {
        let urls = FileTransferPaths.uniqueURLs(urls)
        guard !urls.isEmpty else { return }; pasteboard.clearContents(); pasteboard.writeObjects(urls.map { $0 as NSURL })
    }
}
