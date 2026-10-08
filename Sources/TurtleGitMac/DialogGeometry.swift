import AppKit
import TurtleGitCore

/// Native window persistence is enabled by the app; headless receivers opt in privately.
@MainActor enum DialogGeometry {
    private final class Record {
        weak var window: NSWindow?
        let identifier: String
        var tokens: [NSObjectProtocol] = []
        init(window: NSWindow, identifier: String) { self.window = window; self.identifier = identifier }
        func stop() { tokens.forEach { NotificationCenter.default.removeObserver($0) }; tokens.removeAll() }
    }
    private static var store: WindowGeometryStore?
    private static var records: [ObjectIdentifier: Record] = [:]
    static func install(preferences: UserDefaults = .standard) {
        records.values.forEach { $0.stop() }; records.removeAll(); store = WindowGeometryStore(preferences: preferences)
    }
    static func attach(_ window: NSWindow, identifier: String, legacyName: String? = nil) {
        guard let store else { return }
        for (key, record) in records where record.window == nil { record.stop(); records.removeValue(forKey: key) }
        let key = ObjectIdentifier(window); guard records[key] == nil else { return }
        if var saved = store.load(identifier, legacyName: legacyName) {
            let screens = NSScreen.screens.map { $0.visibleFrame }
            let original = NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)
            let screen = screens.max { a, b in area(original.intersection(a)) < area(original.intersection(b)) } ?? window.screen?.visibleFrame
            if !window.styleMask.contains(.resizable) { saved.width = window.frame.width; saved.height = window.frame.height }
            if let screen {
                let content = NSRect(origin: .zero, size: window.contentMinSize)
                let minimum = window.frameRect(forContentRect: content).size
                saved = saved.fitted(to: geometry(screen), minimumWidth: max(window.minSize.width, minimum.width), minimumHeight: max(window.minSize.height, minimum.height))
                window.setFrame(NSRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height), display: false)
            }
        }
        let record = Record(window: window, identifier: identifier); records[key] = record
        for notification in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
            let token = NotificationCenter.default.addObserver(forName: notification, object: window, queue: nil) { _ in
                MainActor.assumeIsolated {
                    guard let window = record.window else { return }
                    Self.store?.save(geometry(window.frame), identifier: record.identifier)
                    if notification == NSWindow.willCloseNotification { record.stop(); records.removeValue(forKey: key) }
                }
            }
            record.tokens.append(token)
        }
    }
    private static func area(_ rect: NSRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
    private static func geometry(_ rect: NSRect) -> SavedWindowGeometry { SavedWindowGeometry(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height) }
}
