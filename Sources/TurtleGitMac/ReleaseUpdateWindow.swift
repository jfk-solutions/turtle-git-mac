// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class ReleaseUpdateModel: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var release: PublishedRelease?
    @Published private(set) var available = false
    @Published private(set) var message = ""
    @Published private(set) var error: String?
    let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var retired = false
    var onResult: () -> Void = {}
    func check() {
        guard !busy, !retired else { return }
        if GitRuntime.isAppStoreBuild { message = "Application updates are managed by the App Store."; return }
        let request = UUID(); generation = request; busy = true; release = nil; available = false; error = nil; message = "Checking for updates…"
        task = Task {
            defer { if generation == request { busy = false; task = nil } }
            do {
                let preview = UserDefaults.standard.bool(forKey: "VersionCheckPreview")
                let list = try await ReleaseUpdateFeed.fetch(repository: ReleaseUpdateFeed.repository(), includePreview: preview)
                guard !retired, generation == request, !Task.isCancelled else { return }
                UserDefaults.standard.set(Date(), forKey: "TurtleGit.LastVersionCheck")
                guard let newest = list.first else { message = "No published releases are available yet."; onResult(); return }
                release = newest
                guard let current = ReleaseVersion(installed), let latest = ReleaseVersion(newest.tag) else { throw ReleaseUpdateFailure.invalidVersion }
                available = latest > current
                message = available ? "A new version of TurtleGit for Mac is available." : "You have the latest published version of TurtleGit for Mac."
                onResult()
            } catch {
                guard !retired, generation == request, !Task.isCancelled else { return }
                message = "Could not check for updates."; self.error = error.localizedDescription; onResult()
            }
        }
    }
    func cancel() { retired = true; generation = UUID(); task?.cancel(); task = nil; busy = false; onResult = {} }
    func openRelease() {
        let url = release?.url ?? URL(string: "https://github.com/" + ReleaseUpdateFeed.repository() + "/releases")!
        NSWorkspace.shared.open(url)
    }
    func openAppStore() {
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.AppStore") else { return }
        NSWorkspace.shared.openApplication(at: application, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}
@MainActor final class ReleaseUpdateWindowController: NSWindowController, NSWindowDelegate {
    let model: ReleaseUpdateModel
    var onClosed: () -> Void = {}
    init(model: ReleaseUpdateModel = ReleaseUpdateModel(), automatic: Bool = false) {
        self.model = model
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 470), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Check for updates – TurtleGit for Mac"; window.isReleasedWhenClosed = false
        window.contentMinSize = .init(width: 520, height: 330)
        window.contentViewController = NSHostingController(rootView: ReleaseUpdateDialog(model: model, automatic: automatic, close: { [weak window] in window?.close() }))
        super.init(window: window); window.delegate = self; window.center()
        DialogGeometry.attach(window, identifier: "CheckForUpdatesDlg")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowWillClose(_ notification: Notification) { model.cancel(); onClosed() }
}
private struct ReleaseUpdateDialog: View {
    @ObservedObject var model: ReleaseUpdateModel
    let automatic: Bool
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.message).font(.headline)
            Text("Installed version: " + model.installed)
            if let release = model.release { Text("Available version: " + release.tag) }
            if model.busy { ProgressView().controlSize(.small) }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let notes = model.release?.notes, !notes.isEmpty {
                GroupBox("Changelog") { ScrollView { Text(notes).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) } }
            } else { Spacer() }
            HStack {
                if automatic { Button("Do not ask again") { UserDefaults.standard.set(false, forKey: "VersionCheck"); close() } }
                Spacer()
                if GitRuntime.isAppStoreBuild { Button("Open App Store", action: model.openAppStore) }
                else { Button("Open release page", action: model.openRelease).disabled(model.busy) }
                Button(automatic ? "Remind me later" : "Close", action: close).keyboardShortcut(.cancelAction)
            }
        }.padding(20)
    }
}
@MainActor final class ReleaseUpdateService {
    static let shared = ReleaseUpdateService()
    private var timer: Timer?
    private var background: ReleaseUpdateModel?
    private var controller: ReleaseUpdateWindowController?
    private var attempted = false
    static var enabled: Bool { (UserDefaults.standard.object(forKey: "VersionCheck") as? NSNumber)?.boolValue ?? true }
    func install() {
        guard timer == nil, !GitRuntime.isAppStoreBuild, Bundle.main.bundleIdentifier?.hasPrefix("org.turtlegit.macos.documentation-preview") != true else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.attempted = false; self?.checkIfDue() }
        }
        checkIfDue()
    }
    func show() {
        if let controller { controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); return }
        if let model = background { background = nil; model.onResult = {}; present(model, automatic: false); return }
        let model = ReleaseUpdateModel(); present(model, automatic: false); model.check()
    }
    private func present(_ model: ReleaseUpdateModel, automatic: Bool) {
        let controller = ReleaseUpdateWindowController(model: model, automatic: automatic); self.controller = controller
        controller.onClosed = { [weak self, weak controller] in if self?.controller === controller { self?.controller = nil } }
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
    }
    private func checkIfDue() {
        guard !attempted, Self.enabled, controller == nil, background == nil, !GitRuntime.isAppStoreBuild else { return }
        attempted = true
        let last = UserDefaults.standard.object(forKey: "TurtleGit.LastVersionCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= 7 * 24 * 60 * 60 else { return }
        // Throttle failures too; explicit Check now always remains available.
        UserDefaults.standard.set(Date(), forKey: "TurtleGit.LastVersionCheck")
        let model = ReleaseUpdateModel(); background = model
        model.onResult = { [weak self, weak model] in
            guard let self, let model else { return }; self.background = nil
            guard Self.enabled, model.available, self.controller == nil else { model.cancel(); return }
            self.present(model, automatic: true)
        }
        model.check()
    }
}
