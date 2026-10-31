// SPDX-License-Identifier: GPL-2.0-or-later
// Native source adaptation: CheckForUpdatesDlg, TortoiseGit / TortoiseSVN.
import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class ReleaseUpdateModel: ObservableObject {
    static private(set) var activeOperations = 0
    @Published private(set) var busy = false
    @Published private(set) var release: PublishedRelease?
    @Published private(set) var available = false
    @Published private(set) var message = ""
    @Published private(set) var error: String?
    @Published private(set) var selected: Set<Int64> = []
    @Published private(set) var statuses: [Int64:String] = [:]
    @Published private(set) var downloaded: [URL] = []
    @Published private(set) var downloadPending = false
    @Published private(set) var cancelling = false
    @Published private(set) var progress: Double = 0
    private var downloadedIDs: Set<Int64> = []
    let installed: String, repository: String, appStore: Bool
    let distribution:ApplicationDistribution
    private let preferences: UserDefaults
    private var task: Task<Void,Never>?, downloadTask: Task<Void,Never>?
    @Published private(set) var manualPresentation = false
    private var forceRequested = false
    private var generation = UUID(), downloadRequest: UUID?
    private(set) var retired = false
    weak var window: NSWindow?
    private var panel: NSOpenPanel?
    private var folderReply: ((URL?) -> Void)?
    var fetch: (String,Bool) async throws -> [PublishedRelease] = { try await ReleaseUpdateFeed.fetch(repository: $0, includePreview: $1) }
    var transfer: (ReleaseAsset,URL,@escaping @Sendable (Int64) -> Void) async throws -> Void = { try await ReleaseAssetDownload.fetch($0, to: $1, progress: $2) }
    var chooseFolder: ((NSWindow) async -> URL?)?
    var openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    var reveal: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    var openStore:(URL)->Bool = {NSWorkspace.shared.open($0)}
    var onResult: () -> Void = {}
    init(preferences: UserDefaults = .standard,
         installed: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
         repository: String = ReleaseUpdateFeed.repository(), appStore: Bool = GitRuntime.isAppStoreBuild,appStoreListing:URL? = GitRuntime.appStoreListingURL(bundle:SubversionMergeDiff.applicationBundle())) {
        self.preferences = preferences; self.installed = installed; self.repository = repository; self.appStore = appStore
        distribution=ApplicationDistribution(appStoreBuild:appStore,appStoreListing:appStoreListing)
        if appStore {message=storeStatus}
    }
    var canOpenAppStore:Bool {!retired && distribution.canOpenStoreListing}
    var storeStatus:String {distribution.canOpenStoreListing ? "Open the App Store page to check availability and updates.":"An App Store listing is not available for this build."}
    var updateSourceDescription:String {appStore ? (distribution.canOpenStoreListing ? "App Store":"Local test build"):"Using GitHub Releases: "+repository}
    var releaseNotesPlaceholder:String {appStore ? (distribution.canOpenStoreListing ? "Release notes are available on the App Store page.":"App Store release notes are not available for this build."):"Release notes appear after the check completes."}
    var context: UUID { generation }
    var assets: [ReleaseAsset] { release?.assets ?? [] }
    var canDownload: Bool { !retired && !busy && !appStore && available && assets.contains { selected.contains($0.id) && $0.downloadable && !downloadedIDs.contains($0.id) } }
    func canSelect(_ asset: ReleaseAsset) -> Bool { !retired && !busy && !appStore && available && asset.downloadable && !downloadedIDs.contains(asset.id) }
    func select(_ asset: ReleaseAsset, checked: Bool, context: UUID) {
        guard context == generation, canSelect(asset), assets.contains(asset) else { return }
        if checked { selected.insert(asset.id) } else { selected.remove(asset.id) }
    }
    func promote(force: Bool, visible: Bool = false) {
        guard !retired else { return }
        if visible || force { manualPresentation = true }
        guard force, !downloadPending, !appStore else { return }
        forceRequested = true
        if !busy, release != nil, error == nil {
            if !available { message = "The published release is available for download." }
            available = true
        }
    }
    func check(force: Bool = false) {
        guard !busy, !retired else { return }
        if appStore {message=storeStatus;onResult();return}
        let request = UUID(); generation = request; forceRequested = force
        if force { manualPresentation = true }
        let preview = preferences.bool(forKey: "VersionCheckPreview"), fetch = fetch
        busy = true; release = nil; selected = []; statuses = [:]; downloaded = []; downloadedIDs = []
        available = false; error = nil; message = "Checking for updates…"; Self.activeOperations += 1
        task = Task {
            defer { Self.activeOperations -= 1; if generation == request { busy = false; task = nil } }
            do {
                let list = try await fetch(repository,preview)
                guard !retired, generation == request, !Task.isCancelled else { return }
                preferences.set(Date(), forKey: "TurtleGit.LastVersionCheck")
                guard let newest = list.first else { message = "No published releases are available yet."; onResult(); return }
                release = newest
                guard let current = ReleaseVersion(installed), let latest = ReleaseVersion(newest.tag) else { throw ReleaseUpdateFailure.invalidVersion }
                let newer = latest > current
                available = newer || forceRequested
                message = newer ? "A new version of TurtleGit for Mac is available." : forceRequested ? "The published release is available for download." : "You have the latest published version of TurtleGit for Mac."
                // Prefer the published Mac application archive; auxiliary files
                // remain available as separate source-style checked downloads.
                let main = newest.assets.first { $0.downloadable && ["zip","dmg","pkg"].contains($0.url.pathExtension.lowercased()) && $0.name.lowercased().contains("turtlegit") }
                if let main { selected = [main.id] }
                onResult()
            } catch {
                guard !retired, generation == request, !Task.isCancelled else { return }
                message = "Could not check for updates."; self.error = error.localizedDescription; onResult()
            }
        }
    }
    private func destination(in owner: NSWindow) async -> URL? {
        if let chooseFolder { return await chooseFolder(owner) }
        let chooser = NSOpenPanel(); chooser.canChooseFiles = false; chooser.canChooseDirectories = true; chooser.canCreateDirectories = true
        chooser.prompt = "Download"; chooser.message = "Choose a folder for the checked release files. Existing files will be preserved."
        panel = chooser
        return await withCheckedContinuation { reply in
            var answered = false
            let finish: (URL?) -> Void = { value in guard !answered else { return }; answered = true; reply.resume(returning: value) }
            folderReply = finish
            chooser.beginSheetModal(for: owner) { [weak self] response in
                guard let self, self.panel === chooser else { finish(nil); return }
                self.panel = nil; self.folderReply = nil
                finish(response == .OK && !self.retired ? chooser.url : nil)
            }
        }
    }
    func download() {
        guard canDownload, let owner = window, owner.attachedSheet == nil, let release else { return }
        let files = assets.filter { selected.contains($0.id) && $0.downloadable && !downloadedIDs.contains($0.id) }
        let request = UUID(), identity = generation, transfer = transfer
        downloadRequest = request; downloadPending = true; busy = true; cancelling = false; progress = 0; error = nil
        Self.activeOperations += 1
        downloadTask = Task {
            defer {
                Self.activeOperations -= 1
                if downloadRequest == request { downloadRequest = nil; downloadPending = false; busy = false; cancelling = false; downloadTask = nil }
            }
            var current: Int64?
            do {
                guard !retired, !Task.isCancelled, window === owner else { return }
                guard let folder = await destination(in: owner) else { return }
                guard !retired, !Task.isCancelled, downloadRequest == request, generation == identity, window === owner else { return }
                let scoped = folder.startAccessingSecurityScopedResource(); defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw ReleaseDownloadFailure.destination }
                for asset in files {
                    try asset.validate(repository: repository, tag: release.tag)
                    guard !FileManager.default.fileExists(atPath: folder.appendingPathComponent(asset.name).path) else { throw ReleaseDownloadFailure.destination }
                }
                let staging = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitRelease-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: staging) }
                for (index,asset) in files.enumerated() {
                    try Task.checkCancellation(); guard !retired, downloadRequest == request else { return }
                    current = asset.id; statuses[asset.id] = "Downloading…"
                    let stage = staging.appendingPathComponent(UUID().uuidString)
                    try await transfer(asset,stage) { [weak self] bytes in
                        Task { @MainActor in
                            guard let self, !self.retired, self.downloadRequest == request, !self.cancelling, self.statuses[asset.id] == "Downloading…" else { return }
                            self.progress = (Double(index) + min(1,Double(bytes)/Double(asset.size))) / Double(files.count)
                        }
                    }
                    try Task.checkCancellation(); guard !retired, downloadRequest == request, window === owner else { return }
                    // The actual default transfer already checks integrity. This
                    // final gate also covers an injected transport and changed stage.
                    try await Task.detached { try ReleaseAssetDownload.verify(stage, asset: asset) }.value
                    try Task.checkCancellation(); guard !retired else { return }
                    let destination = folder.appendingPathComponent(asset.name)
                    // Once accepted, this bounded file publication owns its scope
                    // and Quit lifetime even if the window is forcibly closed.
                    try await Task.detached { try ReleaseAssetDownload.install(stage, to: destination) }.value
                    guard !retired else { return }
                    statuses[asset.id] = "Downloaded · SHA-256 verified"; downloaded.append(destination); downloadedIDs.insert(asset.id); selected.remove(asset.id)
                    progress = Double(index + 1) / Double(files.count)
                }
                message = "Downloads complete. Show the files in Finder to inspect and install them."
            } catch {
                guard !retired, downloadRequest == request else { return }
                if Task.isCancelled || error is CancellationError {
                    if let current { statuses[current] = "Aborted" }; message = "Download aborted. Completed files are retained."
                } else {
                    if let current { statuses[current] = "Failed" }; self.error = error.localizedDescription
                }
            }
        }
    }
    private func cancelPanel() {
        if let panel { panel.sheetParent?.endSheet(panel, returnCode: .cancel); panel.orderOut(nil) }
        panel = nil; let reply = folderReply; folderReply = nil; reply?(nil)
    }
    func abort() { guard downloadPending, !cancelling else { return }; cancelling = true; downloadTask?.cancel(); cancelPanel() }
    func cancel() {
        guard !retired else { return }; retired = true; generation = UUID(); task?.cancel(); downloadTask?.cancel(); cancelPanel()
        onResult = {}; busy = false
        // Tasks retain independent accounting until real fetch/chooser/file work drains.
    }
    func openRelease() {
        guard !retired, !busy, !appStore else { return }
        let url = release?.url ?? URL(string: "https://github.com/" + repository + "/releases")!
        if !openURL(url) { error = "The release page could not be opened." }
    }
    func showDownloads() { guard !retired, !busy, !downloaded.isEmpty else { return }; reveal(downloaded) }
    func openAppStore() {guard canOpenAppStore,let listing=distribution.appStoreListing else{return};if !openStore(listing) {error="The App Store page could not be opened."}}
    func disableAutomatic() { guard !retired, !busy else { return }; preferences.set(false, forKey: "VersionCheck"); window?.performClose(nil) }
}
@MainActor final class ReleaseUpdateWindowController: NSWindowController, NSWindowDelegate {
    let model: ReleaseUpdateModel
    private let initiallyAutomatic: Bool
    var automatic: Bool { initiallyAutomatic && !model.manualPresentation }
    var onClosed: () -> Void = {}
    init(model suppliedModel: ReleaseUpdateModel? = nil, automatic: Bool = false) {
        self.initiallyAutomatic = automatic
        let model = suppliedModel ?? ReleaseUpdateModel(); self.model = model
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 720, height: 650), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
        window.title = "Check For Updates – TurtleGit for Mac"; window.isReleasedWhenClosed = false; window.contentMinSize = .init(width: 600, height: 520)
        super.init(window: window); window.delegate = self; model.window = window
        let host = NSHostingController(rootView: ReleaseUpdateDialog(model: model, automatic: automatic)); host.sizingOptions = []; window.contentViewController = host
        window.setContentSize(.init(width: 720, height: 650)); window.center(); DialogGeometry.attach(window, identifier: "CheckForUpdatesDlg")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.downloadPending }
    func windowWillClose(_ notification: Notification) { model.cancel(); let callback = onClosed; onClosed = {}; callback() }
}
private struct ReleaseUpdateDialog: View {
    @ObservedObject var model: ReleaseUpdateModel
    let automatic: Bool
    var body: some View {
        let context = model.context, automatic = self.automatic && !model.manualPresentation
        VStack(alignment: .leading, spacing: 10) {
            Text(model.updateSourceDescription).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Your version is: " + model.installed).textSelection(.enabled)
            Text("Current version is: " + (model.release?.tag ?? "—")).textSelection(.enabled)
            Text(model.message).foregroundStyle(model.available ? Color.green : Color.primary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if model.busy && !model.downloadPending { ProgressView().controlSize(.small) }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if !model.appStore { HStack { Spacer(); Button("Click here to go to the website", action: model.openRelease).buttonStyle(.link).disabled(model.busy); Spacer() } }
            GroupBox("Change log") {
                ScrollView { Text(model.release?.notes ?? model.releaseNotesPlaceholder).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }.frame(minHeight: 100)
            }
            if !model.appStore && model.available {
                GroupBox("Download") {
                    VStack(alignment: .leading, spacing: 8) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(model.assets) { asset in
                                    HStack(alignment: .top) {
                                        Toggle(isOn: Binding(get: { model.selected.contains(asset.id) }, set: { model.select(asset, checked: $0, context: context) })) { CommandLabel(title: asset.name, icon: .export, localized: false) }.disabled(!model.canSelect(asset))
                                        Spacer()
                                        Text(model.statuses[asset.id] ?? (asset.downloadable ? ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file) : "SHA-256 download unavailable"))
                                            .font(.caption).foregroundStyle(model.statuses[asset.id]?.hasPrefix("Downloaded") == true ? Color.green : Color.secondary)
                                    }
                                }
                                if model.assets.isEmpty { Text("No downloadable release files are published for this version.").foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(height: 110)
                        HStack {
                            if model.downloadPending { ProgressView(value: model.progress).frame(maxWidth: .infinity) }
                            else { Text("Downloads are checked against GitHub’s SHA-256 digest. macOS signing and installation remain separate.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                            Spacer(minLength: 8)
                            if model.downloadPending { Button(model.cancelling ? "Aborting…" : "Abort", action: model.abort).disabled(model.cancelling) }
                            else if !model.downloaded.isEmpty && !model.canDownload { Button("Show in Finder", action: model.showDownloads) }
                            else { Button("Download", action: model.download).disabled(!model.canDownload) }
                        }
                    }.padding(8)
                }
            }
            HStack {
                Spacer()
                if automatic { Button("Don’t ask me again") { if !model.manualPresentation { model.disableAutomatic() } }.disabled(model.busy) }
                if model.appStore {Button("View in App Store…",action:model.openAppStore).disabled(!model.canOpenAppStore)}
                if !model.downloaded.isEmpty && model.canDownload { Button("Show downloaded files", action: model.showDownloads).disabled(model.busy) }
                Button(automatic ? "Remind me later" : "Close") { model.window?.performClose(nil) }.keyboardShortcut(.defaultAction).disabled(model.downloadPending)
            }
        }.padding(16).onExitCommand { if !model.downloadPending { model.window?.performClose(nil) } }
    }
}
@MainActor final class ReleaseUpdateService {
    static let shared = ReleaseUpdateService()
    private var timer: Timer?
    private(set) var background: ReleaseUpdateModel?
    private(set) var controller: ReleaseUpdateWindowController?
    private var presentations=0,backgroundPresentationIntent=false
    var hasOwnedUtilityWindow:Bool {presentations>0 || controller?.model.retired == false || backgroundPresentationIntent && background?.retired == false}
    func presentExistingUtility()->Bool {
        guard hasOwnedUtilityWindow else{return false}
        if let controller,!controller.model.retired {if controller.window?.isMiniaturized == true {controller.window?.deminiaturize(nil)};display(controller)}
        return true
    }
    private var backgroundAutomatic = false, backgroundRequiresEnabled = false
    private var attempted = false
    var createModel: (UserDefaults) -> ReleaseUpdateModel = { ReleaseUpdateModel(preferences: $0) }
    var display: (ReleaseUpdateWindowController) -> Void = { $0.showWindow(nil); $0.window?.makeKeyAndOrderFront(nil) }
    static var enabled: Bool { enabled(in: .standard) }
    private static func enabled(in preferences: UserDefaults) -> Bool { (preferences.object(forKey: "VersionCheck") as? NSNumber)?.boolValue ?? true }
    func install() {
        guard timer == nil, !GitRuntime.isAppStoreBuild, Bundle.main.bundleIdentifier?.hasPrefix("org.turtlegit.macos.documentation-preview") != true else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.attempted = false; self?.checkIfDue() }
        }
        checkIfDue()
    }
    func show(preferences: UserDefaults = .standard) { showCommand(visible: true, force: false, preferences: preferences) }
    func showCommand(visible: Bool, force: Bool, preferences: UserDefaults = .standard) {
        let ownsPresentation=visible || force
        if ownsPresentation {presentations += 1};defer{if ownsPresentation {presentations -= 1}}
        if let controller {
            controller.model.promote(force: force, visible: visible)
            if visible || force { display(controller) }; return
        }
        if let model = background {
            model.promote(force: force, visible: visible); backgroundRequiresEnabled = false
            if force {backgroundAutomatic=false;backgroundPresentationIntent=true}
            if visible {background=nil;backgroundPresentationIntent=false;model.onResult={};present(model,automatic:false)}
            return
        }
        let model = createModel(preferences)
        if model.appStore {
            model.check()
            if visible || force { present(model, automatic: false) } else { model.cancel() }
        } else if visible { present(model, automatic: false); model.check(force: force) }
        else { startBackground(model, force: force, automatic: !force, respectEnabled: false, preferences: preferences) }
    }
    func cancelBackground() {
        let model = background; background = nil;backgroundPresentationIntent=false
        model?.cancel() // Backend accounting remains until its actual return.
    }
    private func present(_ model: ReleaseUpdateModel, automatic: Bool) {
        presentations += 1;defer{presentations -= 1}
        let controller = ReleaseUpdateWindowController(model: model, automatic: automatic); self.controller = controller
        controller.onClosed = { [weak self, weak controller] in if self?.controller === controller { self?.controller = nil } }
        display(controller)
    }
    private func startBackground(_ model: ReleaseUpdateModel, force: Bool, automatic: Bool, respectEnabled: Bool, preferences: UserDefaults) {
        background = model;backgroundPresentationIntent=force; backgroundAutomatic = automatic; backgroundRequiresEnabled = respectEnabled
        model.onResult = { [weak self, weak model] in
            guard let self, let model, self.background === model else { return }
            let show = model.available && (!self.backgroundRequiresEnabled || Self.enabled(in: preferences)) && self.controller == nil
            let automatic = self.backgroundAutomatic && Self.enabled(in: preferences); self.background = nil;self.backgroundPresentationIntent=false
            if show { self.present(model, automatic: automatic) } else { model.cancel() }
        }
        model.check(force: force)
    }
    private func checkIfDue() {
        guard !attempted, Self.enabled, controller == nil, background == nil, !GitRuntime.isAppStoreBuild else { return }
        attempted = true
        let last = UserDefaults.standard.object(forKey: "TurtleGit.LastVersionCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= 7 * 24 * 60 * 60 else { return }
        UserDefaults.standard.set(Date(), forKey: "TurtleGit.LastVersionCheck")
        startBackground(createModel(.standard), force: false, automatic: true, respectEnabled: true, preferences: .standard)
    }
}
