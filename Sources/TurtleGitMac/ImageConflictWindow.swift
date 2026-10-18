import AppKit
import SwiftUI
import Combine
import TurtleGitCore

@MainActor private final class ImageConflictNSWindow: NSWindow {
    weak var imageModel: ImageConflictWindowModel?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard attachedSheet == nil, (firstResponder as? NSTextView)?.isFieldEditor != true,
              let imageModel, !imageModel.retired else { return super.performKeyEquivalent(with: event) }
        // Preview decoding is cancellable by the ordinary window close route.
        // Mutation/Select work still keeps its existing busy close protection.
        if event.modifierFlags.intersection([.command,.shift,.control,.option]).isEmpty, event.keyCode == 53,
           !imageModel.busy || imageModel.decoding { performClose(nil); return true }
        guard !imageModel.busy else {return super.performKeyEquivalent(with:event)}
        if let command = ImageEditorCommand.key(event), imageModel.commandState(command) != nil {
            imageModel.perform(command); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
@MainActor final class ImageConflictWindowController: NSWindowController, NSWindowDelegate {
    let model: ImageConflictWindowModel
    private(set) var imageToolbar: ImageEditorToolbar?
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, document: ImageConflictDocument, preferences: UserDefaults = .standard, decodeImages:ImageConflictWindowModel.Decoder?=nil) {
        model = ImageConflictWindowModel(repository: repository, access: access, document: document, preferences: preferences,decodeImages:decodeImages)
        let window = ImageConflictNSWindow(contentRect: NSRect(x: 0,y: 0,width: 1200,height: 720), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = document.entry.path + " — TurtleGitIDiff"
        window.contentView = NSHostingView(rootView: ImageConflictDialog(model: model))
        window.minSize = NSSize(width: 800,height: 400)
        super.init(window: window); model.presentation.attach(window); model.windowForCommands = window; window.delegate = self; window.imageModel = model; window.center()
        model.close = { [weak window] in window?.close() }
        model.askMarkResolved = { [weak model = model] path in await model?.confirmResolution(path: path) ?? false }
        imageToolbar = ImageEditorToolbar.conflict(self)
        DialogGeometry.attach(window, identifier: "TurtleGit.ImageConflict", legacyName: "TurtleGit.ImageConflict")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { (!model.busy || model.decoding) && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) {
        imageToolbar?.retire(); model.retire(); (window as? ImageConflictNSWindow)?.imageModel = nil; onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class ImageConflictWindowModel: ObservableObject {
    private(set) static var activeOperations = 0
    typealias Decoder=(ImageConflictDocument,OperationCancellation) async throws -> [ImageConflictSide:ComparisonImage]
    var decodeImages:Decoder = { document,token in
        try await Task.detached {
            var images:[ImageConflictSide:ComparisonImage]=[:]
            for side in ImageConflictSide.allCases {try token.check();images[side]=document.image(side,cancellation:token)}
            try token.check();return images
        }.value
    }
    @Published private(set) var decoding=false
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    private let preferences: UserDefaults
    @Published private(set) var document: ImageConflictDocument
    @Published var nativeToolbarInstalled = false
    @Published var vertical = false
    @Published var showInfo = false
    @Published private(set) var busy = false
    @Published var error: String?
    private(set) var retired = false
    private var task: Task<Void,Never>?
    private var cancellation: OperationCancellation?
    private var resolutionSession: ExternalMergeSession?
    private var paneObservers: [AnyCancellable] = []
    var onChanged: (String) -> Void = { _ in }
    var close: () -> Void = {}
    var askMarkResolved: (String) async -> Bool = { _ in false }
    let presentation = ImageWindowPresentation()
    let panes: [ImageConflictSide: ImageComparisonViewModel]
    private(set) var images: [ImageConflictSide: ComparisonImage]
    init(repository: GitRepository, access: RepositoryAccessLease?, document: ImageConflictDocument, preferences: UserDefaults = .standard,decodeImages:Decoder?=nil) {
        self.repository = repository; self.access = access; self.document = document; self.preferences = preferences
        if let decodeImages {self.decodeImages=decodeImages}
        images = [:]
        let presentation = self.presentation
        panes = Dictionary(uniqueKeysWithValues: ImageConflictSide.allCases.map { side in
            let pane = ImageComparisonViewModel(presentation: presentation); pane.configureImages(base: nil, destination: nil)
            return (side,pane)
        })
        for (side,pane) in panes { pane.commandsAllowed = { [weak self] in
            guard let self else {return false};return !self.busy && !self.retired && !self.panes.contains(where:{$0.key != side && $0.value.receivingDrop}) && self.windowForCommands?.attachedSheet == nil
        } }
        paneObservers = panes.values.map {pane in pane.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() } }
        loadInitialImages()
    }
    private func publishImages(_ decoded:[ImageConflictSide:ComparisonImage]) {
        images=decoded
        for side in ImageConflictSide.allCases {panes[side]?.configureImages(base:decoded[side],destination:nil,force:true)}
        fitImages()
    }
    private func loadInitialImages() {
        busy=true;decoding=true
        let token=OperationCancellation(),snapshot=document,decode=decodeImages
        cancellation=token;Self.activeOperations += 1
        task=Task { [self,access] in
            defer {
                Self.activeOperations -= 1;withExtendedLifetime(access) {}
                if cancellation === token {busy=false;decoding=false;task=nil;cancellation=nil}
            }
            do {
                let decoded=try await decode(snapshot,token);try token.check()
                guard !retired,cancellation === token else{return}
                publishImages(decoded)
            } catch {if !retired,!token.isCancelled {self.error=error.localizedDescription}}
        }
    }
    func commandState(_ command: ImageEditorCommand) -> ImageEditorCommandState? {
        let ready = !busy && !retired && !panes.values.contains(where:{$0.receivingDrop}) && windowForCommands?.attachedSheet == nil
        switch command {
        case .info: return .init(enabled: ready, checked: showInfo)
        case .vertical: return .init(enabled: ready, checked: vertical)
        case .dark: return .init(enabled: ready, checked: presentation.darkMode)
        case .fit, .original, .zoomIn, .zoomOut, .reload, .transparentColor, .fileMenu, .viewMenu: return .init(enabled: ready)
        default: return nil
        }
    }
    weak var windowForCommands: NSWindow?
    func perform(_ command: ImageEditorCommand) {
        guard commandState(command)?.enabled == true else { return }
        switch command {
        case .fit: fitImages(); case .original: originalSize(); case .zoomIn: zoom(true); case .zoomOut: zoom(false)
        case .info: showInfo.toggle(); case .vertical: vertical.toggle(); case .reload: reload()
        case .dark: presentation.toggleDarkMode(); case .transparentColor: presentation.chooseTransparentColor()
        default: break
        }
    }
    func fitImages() { for pane in panes.values { pane.fit = true } }
    func originalSize() { for pane in panes.values { pane.originalSize() } }
    func zoom(_ zoomIn: Bool) { for pane in panes.values { pane.changeZoom(zoomIn: zoomIn) } }
    func retire() {
        guard !retired else { return }
        presentation.retire(); for pane in panes.values { pane.retire() }
        retired = true; cancellation?.cancel(); resolutionSession?.retire(); task?.cancel()
        // Keep the actual operation and its retained repository grant alive
        // until the Git worker or owned question really settles.
    }
    func confirmResolution(path: String) async -> Bool {
        guard !retired, let cancellation else { return false }
        let question = ExternalMergeSession(owner: windowForCommands, cancellation: cancellation)
        resolutionSession = question
        defer { question.retire(cancelWork: false); if resolutionSession === question { resolutionSession = nil } }
        return await question.confirmImageResolution(path: path)
    }
    func canSelect(_ side: ImageConflictSide) -> Bool {
        !busy && !retired && !panes.values.contains(where:{$0.receivingDrop}) && windowForCommands?.attachedSheet == nil && document.selectionBytes(side) != nil
    }
    func reload() {
        guard !busy, !retired, !panes.values.contains(where:{$0.receivingDrop}), windowForCommands?.attachedSheet == nil else { return }; busy = true; decoding=true;error = nil
        let token = OperationCancellation(),decode=decodeImages; cancellation = token; Self.activeOperations += 1
        task = Task { [self,access] in
            defer { busy = false; decoding=false;task = nil; cancellation = nil; Self.activeOperations -= 1;withExtendedLifetime(access) {} }
            guard !retired else { return }
            do {
                guard let next = try await repository.imageConflictDocument(path: document.entry.path, identityOptions: ConflictIdentityOptions(defaults: preferences), cancellation: token) else { throw ImageConflictFailure.unavailable }
                try token.check()
                let decoded=try await decode(next,token);try token.check()
                guard !retired,cancellation === token else { return }
                document = next;publishImages(decoded)
            } catch { if !retired { self.error = error.localizedDescription } }
        }
    }
    func title(for side: ImageConflictSide) -> String {
        if let titles = document.conflictTitles {
            switch side {
            case .base: return titles.base
            case .mine: return "Mine — " + titles.mine.title
            case .theirs: return "Theirs — " + titles.theirs.title
            }
        }
        return side == .mine && document.mineStage == 3 ? "Mine — Branch being rebased" : side == .theirs && document.theirsStage == 2 ? "Theirs — Branch being rebased onto" : side.rawValue
    }
    func select(_ side: ImageConflictSide) {
        guard canSelect(side) else { return }; busy = true; error = nil
        let token = OperationCancellation(); cancellation = token; Self.activeOperations += 1
        task = Task { [self] in
            defer { busy = false; task = nil; cancellation = nil; Self.activeOperations -= 1 }
            guard !retired else { return }
            do {
                let saved = try await repository.selectImageConflict(document, side: side, cancellation: token)
                guard !retired else { return }; document = saved
                onChanged("Selected " + side.rawValue + ": " + saved.entry.path)
                guard await askMarkResolved(saved.entry.path), !retired else { return }
                let output = try await repository.markImageConflictResolved(saved, cancellation: token)
                guard !retired else { return }
                onChanged(output.isEmpty ? "Resolved: " + saved.entry.path : output); close()
            } catch { if !retired { self.error = error.localizedDescription } }
        }
    }
}
struct ImageConflictDialog: View {
    @ObservedObject var model: ImageConflictWindowModel
    private func tool(_ title: String, _ icon: MenuIcon, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(nsImage: icon.image() ?? NSImage()).resizable().frame(width: 20,height: 20) }
            .background(active ? Color.accentColor.opacity(0.22) : Color.clear).help(title).accessibilityLabel(title)
    }
    var body: some View {
        VStack(spacing: 0) {
            if !model.nativeToolbarInstalled {
            HStack(spacing: 5) {
                tool("Fit images in window", .imageFit) { model.fitImages() }
                tool("Original size", .imageOriginal) { model.originalSize() }
                tool("Zoom in", .imageZoomIn) { model.zoom(true) }
                tool("Zoom out", .imageZoomOut) { model.zoom(false) }
                Divider().frame(height: 25)
                tool("Image info", .imageInfo, active: model.showInfo) { model.showInfo.toggle() }
                tool("Arrange vertical", .imageVertical, active: model.vertical) { model.vertical.toggle() }
                Spacer()
                Menu("View") {
                    Button { model.fitImages() } label: { CommandLabel(title: "Fit images in window", icon: .imageFit) }
                    Button { model.originalSize() } label: { CommandLabel(title: "Original size", icon: .imageOriginal) }
                    Button("Transparent color…") { model.presentation.chooseTransparentColor() }
                    Divider()
                    Button { model.zoom(false) } label: { CommandLabel(title: "Zoom out", icon: .imageZoomOut) }
                    Button { model.zoom(true) } label: { CommandLabel(title: "Zoom in", icon: .imageZoomIn) }
                    Divider()
                    Toggle(isOn: $model.showInfo) { CommandLabel(title: "Image info", icon: .imageInfo) }
                    Toggle(isOn: $model.vertical) { CommandLabel(title: "Arrange vertical", icon: .imageVertical) }
                    Divider()
                    ImageAppearanceMenu(presentation: model.presentation)
                }.fixedSize()
                Button("Reload") { model.reload() }
            }.padding(8)
            Divider()
            }
            if model.vertical {
                VSplitView { pane(.mine); pane(.base); pane(.theirs) }
            } else {
                HSplitView { pane(.mine); pane(.base); pane(.theirs) }
            }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled).padding(8) }
            HStack { if model.busy { ProgressView().controlSize(.small); Text(model.decoding ? "Loading images…":"Selecting image…") }; Spacer(); Text(model.document.entry.path).lineLimit(1) }.font(.caption).padding(8)
        }.background(Color(nsColor: .windowBackgroundColor)).disabled(model.busy)
    }
    private func pane(_ side: ImageConflictSide) -> some View {
        ImageConflictPane(side: side, image: model.images[side], bytes: model.document.contents[side]?.count ?? 0,
                          title: model.title(for: side), selectable: model.canSelect(side),
                          emptyBase: side == .base && model.document.contents[side] == nil,
                          model: model.panes[side]!, info: model.showInfo) { model.select(side) }
    }
}
private struct ImageConflictPane: View {
    let side: ImageConflictSide
    let image: ComparisonImage?
    let bytes: Int
    let title: String
    let selectable: Bool
    let emptyBase: Bool
    @ObservedObject var model: ImageComparisonViewModel
    let info: Bool
    let select: () -> Void
    var body: some View {
        let current = model.currentImage(base: true)
        VStack(spacing: 0) {
            Text(model.droppedFiles[true]?.path ?? title).font(.caption).lineLimit(1).truncationMode(.middle).help((model.droppedFiles[true]?.path ?? title) + "\n" + model.information(base:true,bytes:bytes).joined(separator:"\n")).padding(7).frame(maxWidth: .infinity).background(Color(nsColor: .controlBackgroundColor))
            ImageFrameControls(model: model, base: true, label: side.rawValue)
            if model.receivingDrop {ProgressView("Loading dropped image…").controlSize(.small).padding(4)}
            if model.droppedFiles[true] != nil {Text("Preview only — Select uses the original conflict revision.").font(.caption).foregroundStyle(.secondary).padding(4)}
            if let error = model.dropError {Text(error).font(.caption).foregroundStyle(.red).padding(4)}
            ZStack(alignment: .bottomLeading) {
                ImageComparisonScroll(model: model, image: current, second: nil, base: true)
                if current == nil {
                    Text(emptyBase && model.droppedFiles[true] == nil ? "No base revision — Select copies an empty file" : "Unable to decode image — Select copies the original bytes")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).allowsHitTesting(false)
                }
                if info {
                    ImageComparisonInformation(model:model,base:true,bytes:bytes)
                        .padding(8).background(.regularMaterial).padding(10).allowsHitTesting(false)
                }
            }
            HStack { Text(model.fit ? "Fit in window" : "Zoom: \(Int(model.zoom * 100))%").font(.caption); Spacer(); ImageConflictSelectButton(side: side, enabled: selectable, action: select).frame(width: 90,height: 24) }.padding(7)
        }.frame(minWidth: 200,minHeight: 100)
    }
}

private struct ImageConflictSelectButton: NSViewRepresentable {
    let side: ImageConflictSide
    let enabled: Bool
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "Select", target: context.coordinator, action: #selector(Coordinator.select(_:)))
        button.bezelStyle = .rounded; button.setAccessibilityLabel("Select " + side.rawValue)
        button.isEnabled = enabled && context.environment.isEnabled
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action; button.isEnabled = enabled && context.environment.isEnabled
    }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func select(_ sender: NSButton) { action() }
    }
}
