// SPDX-License-Identifier: GPL-2.0-or-later
// Native adaptation of RTFMCommand.h's explanation, Help and Documents actions.
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class ApplicationIntroductionModel: ObservableObject {
    @Published private(set) var error: String?
    private(set) var retired = false
    var close: () -> Void = {}
    var help: () -> Void = { TurtleGitHelp.show(.overview) }
    var explore: () -> Bool = {
        guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
        return NSWorkspace.shared.open(folder)
    }
    func showHelp() { guard !retired else { return }; help(); close() }
    func openDocuments() {
        guard !retired else { return }
        if explore() { close() } else { error = "The Documents folder could not be opened in Finder." }
    }
    func retire() { retired = true; close = {} }
}
@MainActor final class ApplicationIntroductionController: NSWindowController, NSWindowDelegate {
    let model = ApplicationIntroductionModel()
    var onClosed: () -> Void = {}
    init(preferences: UserDefaults = .standard) {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 560, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "TurtleGit for Mac"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let host = NSHostingController(rootView: ApplicationIntroductionDialog(model: model).defaultAppStorage(preferences)); host.sizingOptions = []
        window.contentViewController = host; window.setContentSize(.init(width: 560, height: 260)); window.center()
        model.close = { [weak self] in self?.close() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowWillClose(_ notification: Notification) {
        guard !model.retired else { return }; model.retire(); let callback = onClosed; onClosed = {}; callback()
    }
}
private struct ApplicationIntroductionDialog: View {
    @ObservedObject var model: ApplicationIntroductionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                if let icon = MenuIcon.turtle.image(size: 48) { Image(nsImage: icon).frame(width: 48, height: 48) }
                VStack(alignment: .leading, spacing: 8) {
                    Text("TurtleGit for Mac").font(.headline)
                    Text("A macOS fork of TortoiseGit").foregroundStyle(.secondary)
                    Text("Open a repository from the File menu, or use TurtleGit’s Finder context menus. Help explains the available commands.").fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 0)
            HStack {
                Button(action: model.showHelp) { CommandLabel(title: "Help", icon: .help) }
                Spacer()
                Button("OK", action: model.openDocuments).keyboardShortcut(.defaultAction)
            }
        }.padding(20).onExitCommand { model.close() }
    }
}
@MainActor final class ApplicationIntroductionService {
    static let shared = ApplicationIntroductionService()
    private(set) var controller: ApplicationIntroductionController?
    private var creations=0
    var hasOwnedUtilityWindow:Bool {controller != nil || creations>0}
    func presentExistingUtility()->Bool {
        guard hasOwnedUtilityWindow else{return false}
        if let controller {
            if controller.window?.isMiniaturized==true {controller.window?.deminiaturize(nil)}
            display(controller)
        }
        return true
    }
    var create: (UserDefaults) -> ApplicationIntroductionController = { ApplicationIntroductionController(preferences: $0) }
    var display: (ApplicationIntroductionController) -> Void = { $0.showWindow(nil); $0.window?.makeKeyAndOrderFront(nil) }
    func show(preferences: UserDefaults = .standard) {
        if let controller { display(controller); return }
        creations += 1;defer{creations -= 1}
        let controller = create(preferences); self.controller = controller
        controller.onClosed = { [weak self, weak controller] in if self?.controller === controller { self?.controller = nil } }
        display(controller)
    }
}
