// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import ScreenCaptureKit
import TurtleGitCore

struct MergeEditorSourceVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ yes: Bool, _ message: String) throws { if !yes { throw Failure(description: message) } }
    @MainActor static func wait(_ yes: () -> Bool, line: UInt = #line) async throws {
        for _ in 0..<2000 { if yes() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Merge Editor source timeout at \(line)")
    }
    @MainActor static func views(_ root: NSView?) -> [NSView] { guard let root else { return [] }; return [root] + root.subviews.flatMap { views($0) } }
    @MainActor static func capture(_ window: NSWindow, into folder: URL) async throws {
        guard #available(macOS 14.4, *) else { throw Failure(description: "Capture requires macOS 14.4") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance); window.alphaValue = 1; window.orderFront(nil); window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 250_000_000)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure(description: "Capture owner missing") }
            let options = SCStreamConfiguration(); options.includeChildWindows = false; options.width = Int(window.frame.width*2); options.height = Int(window.frame.height*2); options.showsCursor = false
            let pixels = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: options)
            guard let data = NSBitmapImageRep(cgImage: pixels).representation(using: .png, properties: [:]) else { throw Failure(description: "PNG missing") }
            try data.write(to: folder.appendingPathComponent("merge-editor-source-" + suffix + ".png"))
        }; window.orderOut(nil); window.alphaValue = 0
    }
    @MainActor static func verify() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitEditorSource-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "TurtleGit.EditorSource." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!, file = root.appendingPathComponent("ignorecomments.txt")
        let initial = "swift=//,/*,*/\n", edited = "swift=#,/*,*/\n"
        try Data(initial.utf8).write(to: file)
        let model = MergeEditorSettingsModel(defaults: prefs, commentProfileURL: file), transaction = SettingsTransaction()
        defer { model.cancelProfiles(); transaction.invalidate(); prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 820, height: 1040), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Merge Editor – TurtleGit"; window.isReleasedWhenClosed = false; window.alphaValue = 0
        defer { window.close() }
        let viewport = SettingsPageViewport(frame: .zero), host = NSHostingView(rootView: MergeEditorSettings(model: model).environment(\.settingsTransaction, transaction))
        window.contentView = viewport; viewport.pageDocument.addSubview(host); host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: viewport.pageDocument.leadingAnchor), host.trailingAnchor.constraint(equalTo: viewport.pageDocument.trailingAnchor), host.topAnchor.constraint(equalTo: viewport.pageDocument.topAnchor), host.bottomAnchor.constraint(equalTo: viewport.pageDocument.bottomAnchor)])
        window.orderFront(nil); window.contentView?.layoutSubtreeIfNeeded()
        try await wait { model.window === window && views(host).compactMap { $0 as? NSComboBox }.count == 1 }
        let context = model.editContext, oldFont = model.binding(\.fontSize)
        model.setActive(false); oldFont.wrappedValue = "18"; model.editTabSize(8, context: context)
        try require(model.fontSize == "10" && model.tabSize != "8", "Hidden page accepted stale form")
        model.setActive(true); oldFont.wrappedValue = "18"
        try require(model.fontSize == "10", "Reactivation revived old binding")
        model.binding(\.fontSize).wrappedValue = "18"; model.binding(\.general.fontName).wrappedValue = "Menlo"
        model.tabSize = "8"; model.patchContext = "12"; model.preferUTF8 = true
        let before = prefs.dictionaryRepresentation() as NSDictionary
        model.profileText = edited; try Data("swift=;,/*,*/\n".utf8).write(to: file)
        try require(!model.apply() && model.error != nil && prefs.dictionaryRepresentation() as NSDictionary == before, "Profile save race partially wrote preferences")
        model.reloadProfiles(context: model.editContext)
        try require(model.error == nil && model.profileText == "swift=;,/*,*/\n" && model.fontSize == "18" && model.tabSize == "8", "Profile-only recovery lost unrelated draft")
        model.profileText = edited
        let beforeApply = model.binding(\.fontSize)
        model.setActive(false); try require(model.apply(), "Authorized hidden Apply failed")
        model.setActive(true); beforeApply.wrappedValue = "20"
        try require(model.fontSize == "18" && MergeGeneralPreferences.load(from: prefs).fontSize == 18 && MergeEditorPreferences.load(from: prefs).tabWidth == 8 && MergeUnifiedPatch.contextLines(from: prefs) == 12 && ComparisonTextEncoding.preferUTF8(from: prefs), "Captured settings did not save coherently")
        try require(try String(contentsOf: file, encoding: .utf8) == edited && !model.changed, "Profiles were not saved before settings")
        model.openProfiles(context: model.editContext)
        guard let session = model.profileSession else { throw Failure(description: "Profile owner missing") }
        let sheetBinding = model.profileBinding(session)
        try await wait { window.attachedSheet != nil }
        try require(MergeEditorSettingsModel.activeProfileEditors == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel && !model.apply(), "Profile editing did not own Quit/Apply")
        sheetBinding.wrappedValue = "swift=//,/*"; model.acceptProfiles(session)
        try require(model.profileSession != nil && model.sheetValidationError != nil, "Invalid profile accepted")
        sheetBinding.wrappedValue = initial; model.acceptProfiles(session); model.acceptProfiles(session)
        try await wait { window.attachedSheet == nil && MergeEditorSettingsModel.activeProfileEditors == 0 }
        let afterSheet = try String(contentsOf: file, encoding: .utf8)
        try require(model.profileText == initial && model.changed && afterSheet == edited, "Sheet acceptance persisted before Apply")
        model.restore(); sheetBinding.wrappedValue = "stale"; model.acceptProfiles(session)
        try require(model.profileText == edited && model.profileSession == nil && !model.changed, "Old sheet revived after Cancel/restore")
        model.readProfiles = { _ in throw Failure(description: "injected read failure") }; model.restore()
        try require(model.profileError != nil && model.validationError != nil && model.profileText == edited, "Failed profile read replaced accepted text")
        model.readProfiles = { try MergeCommentProfileFile.text(at: $0) }; model.reloadProfiles(context: model.editContext)
        try require(model.profileError == nil && model.validationError == nil && !model.changed, "Profile retry did not recover")
        for invalid in ["", "0", "1001", "abc"] { model.tabSize = invalid; try require(model.validationError != nil && !model.apply(), "Invalid tab size persisted") }
        model.restore()
        // Shared native font controls fence disabled and closed callbacks.
        var fontValue = "Menlo", sizeValue = "10"
        let fontWindow = NSWindow(contentRect: .init(x: 0, y: 0, width: 440, height: 70), styleMask: [.titled], backing: .buffered, defer: false)
        fontWindow.isReleasedWhenClosed = false; fontWindow.alphaValue = 0; defer { fontWindow.close() }
        let fonts = NSHostingView(rootView: HStack { NativeFixedFontChoice(value: Binding(get: { fontValue }, set: { fontValue = $0 })); NativeFontSizeChoice(value: Binding(get: { sizeValue }, set: { sizeValue = $0 })).frame(width: 80) }.disabled(true))
        fontWindow.contentView = fonts; fonts.layoutSubtreeIfNeeded()
        try await wait { views(fonts).compactMap { $0 as? NSComboBox }.count == 1 && views(fonts).compactMap { $0 as? NSPopUpButton }.count == 1 }
        let combo = views(fonts).compactMap { $0 as? NSComboBox }[0], family = views(fonts).compactMap { $0 as? NSPopUpButton }[0]
        let sizeDelegate = combo.delegate as! NativeFontSizeChoice.Coordinator, familyTarget = family.target as! NativeFixedFontChoice.Coordinator
        combo.stringValue = "24"; sizeDelegate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: combo)); familyTarget.changed(family)
        try require(!combo.isEnabled && !family.isEnabled && sizeValue == "10" && fontValue == "Menlo", "Disabled font control changed binding")
        fontWindow.close(); combo.isEnabled = true; family.isEnabled = true
        sizeDelegate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: combo)); familyTarget.changed(family)
        try require(sizeDelegate.retired && familyTarget.retired && sizeValue == "10" && fontValue == "Menlo", "Closed font owner accepted callback")
        if let path = ProcessInfo.processInfo.environment["TURTLEGIT_MERGE_EDITOR_CAPTURE"] { try await capture(window, into: URL(fileURLWithPath: path)) }
        window.alphaValue = 0; window.orderFront(nil); model.setActive(true)
        let closedBinding = model.binding(\.fontSize); model.openProfiles(context: model.editContext)
        try await wait { window.attachedSheet != nil }; window.close()
        closedBinding.wrappedValue = "24"; model.acceptProfiles(session)
        try require(MergeEditorSettingsModel.activeProfileEditors == 0 && model.profileSession == nil && !model.active && !model.apply() && model.fontSize == "18", "Owner closure revived settings/profile lifetime")
        print("PASS Merge Editor source: captured form/hidden Apply, profile save/read recovery without partial preferences, owned validated sheet/Cancel/late replies/Quit, numeric bounds and disabled/retired native fonts; private files/preferences only")
    }
}
