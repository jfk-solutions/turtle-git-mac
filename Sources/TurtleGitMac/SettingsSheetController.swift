// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

/// Owns one captured Settings workspace through native sheet release.
@MainActor final class SettingsSheetController: NSWindowController, NSWindowDelegate {
    let navigation: SettingsNavigationController
    private let workspace: RepositoryModel
    var onClosed: (Bool) -> Void = { _ in }
    private var retired = false, finished = false, closing = false
    private weak var sheetOwner: NSWindow?
    private var sheetObserver: NSObjectProtocol?
    private(set) static var activeSheets = 0
    private var counted = false
    private var ownerObserver: NSObjectProtocol?
    init(workspace: RepositoryModel, preferences: UserDefaults, initialPage: SettingsPageID, title: String,
         globalOnly: Bool = false, contentSize: NSSize = NSSize(width: 1040, height: 740), minimumSize: NSSize = NSSize(width: 860, height: 540)) {
        self.workspace = workspace
        navigation = SettingsNavigationController(workspace: workspace, appearance: AppAppearance(preferences: preferences), globalOnly: globalOnly, preferences: preferences, initialPage: initialPage)
        let window = SettingsSheetWindow(contentRect: NSRect(origin: .zero, size: contentSize), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = title; window.contentMinSize = minimumSize
        super.init(window: window); window.delegate = self; window.contentViewController = navigation
        window.canClose = { [weak self] in self.map { !$0.retired && !$0.closing && !$0.finished && $0.navigation.canDismiss } ?? false }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func presentSheet(for owner: NSWindow) {
        guard let window, !closing, !finished, sheetOwner == nil, owner.attachedSheet == nil else { retire(); return }
        sheetOwner = owner; window.alphaValue = owner.alphaValue
        counted = true; Self.activeSheets += 1
        ownerObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: owner, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.retire() }
        }
        sheetObserver = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: owner, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.drain() }
        }
        owner.beginSheet(window)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { navigation.canDismiss }
    func windowWillClose(_ notification: Notification) { finish() }
    func retire() {
        guard !finished else { return }; retired = true
        if !closing { close() }
        finish()
    }
    private func finish() {
        guard !finished else { return }
        if !closing {
            closing = true; navigation.invalidate()
            if let window { window.sheetParent?.endSheet(window, returnCode: retired ? .abort : .OK); window.orderOut(nil) }
        }
        // Keep the transaction/window/continuation through AppKit's actual sheet
        // release. A caller can immediately need another question or document replacement.
        DispatchQueue.main.async { [self] in drain() }
    }
    private func drain() {
        guard closing, !finished, window?.sheetParent == nil, sheetOwner?.attachedSheet !== window else { return }
        finished = true
        if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver); self.sheetObserver = nil }
        if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver); self.ownerObserver = nil }
        if counted { counted = false; Self.activeSheets -= 1 }
        let reply = onClosed; onClosed = { _ in }
        reply(!retired && sheetOwner != nil && sheetOwner?.attachedSheet == nil)
        withExtendedLifetime(workspace) {}
    }
    deinit { if let sheetObserver { NotificationCenter.default.removeObserver(sheetObserver) }; if let ownerObserver { NotificationCenter.default.removeObserver(ownerObserver) } }
}


/// AppKit disables an attached sheet's title-bar close button. Its ordinary
/// performClose therefore refuses even the Settings footer's OK/Cancel action.
/// This owned sheet keeps the same transaction/delegate policy while allowing
/// those explicit close actions to finish their existing handoff.
@MainActor private final class SettingsSheetWindow: NSWindow {
    var canClose: () -> Bool = { false }
    override func performClose(_ sender: Any?) {
        guard canClose(), delegate?.windowShouldClose?(self) != false else { return }
        close()
    }
}
