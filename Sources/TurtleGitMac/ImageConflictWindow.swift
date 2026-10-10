import AppKit
import SwiftUI
import TurtleGitCore

@MainActor private final class ImageConflictNSWindow: NSWindow {
    weak var imageModel: ImageConflictWindowModel?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard attachedSheet == nil, (firstResponder as? NSTextView)?.isFieldEditor != true,
              let imageModel, !imageModel.busy, !imageModel.retired else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command,.shift,.control,.option])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command, key == "v" { imageModel.vertical.toggle(); return true }
        guard flags.isEmpty || flags == .shift else { return super.performKeyEquivalent(with: event) }
        if event.keyCode == 53 { performClose(nil); return true }
        switch key {
        case "f": imageModel.fitImages()
        case "s": imageModel.originalSize()
        case "+", "=": imageModel.zoom(true)
        case "-": imageModel.zoom(false)
        case "i": imageModel.showInfo.toggle()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
@MainActor final class ImageConflictWindowController: NSWindowController, NSWindowDelegate {
    let model: ImageConflictWindowModel
    var onClosed: () -> Void = {}
    init(repository: GitRepository, access: RepositoryAccessLease?, document: ImageConflictDocument) {
        model = ImageConflictWindowModel(repository: repository, access: access, document: document)
        let window = ImageConflictNSWindow(contentRect: NSRect(x: 0,y: 0,width: 1200,height: 720), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = document.entry.path + " — TurtleGitIDiff"
        window.contentView = NSHostingView(rootView: ImageConflictDialog(model: model))
        window.minSize = NSSize(width: 800,height: 400)
        super.init(window: window); window.delegate = self; window.imageModel = model; window.center()
        model.close = { [weak window] in window?.close() }
        model.askMarkResolved = { [weak window] path in
            guard let window else { return false }
            let alert = NSAlert(); alert.alertStyle = .informational
            alert.messageText = "Mark “\((path as NSString).lastPathComponent)” as resolved?"
            alert.informativeText = "The selected image has been copied to the working file."
            alert.addButton(withTitle: "Yes"); alert.addButton(withTitle: "No")
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
            }
        }
        DialogGeometry.attach(window, identifier: "TurtleGit.ImageConflict", legacyName: "TurtleGit.ImageConflict")
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy && sender.attachedSheet == nil }
    func windowWillClose(_ notification: Notification) {
        model.retire(); (window as? ImageConflictNSWindow)?.imageModel = nil; onClosed()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
@MainActor final class ImageConflictWindowModel: ObservableObject {
    let repository: GitRepository
    private let access: RepositoryAccessLease?
    @Published private(set) var document: ImageConflictDocument
    @Published var vertical = false
    @Published var showInfo = false
    @Published private(set) var busy = false
    @Published var error: String?
    private(set) var retired = false
    private var task: Task<Void,Never>?
    private var cancellation: OperationCancellation?
    var onChanged: (String) -> Void = { _ in }
    var close: () -> Void = {}
    var askMarkResolved: (String) async -> Bool = { _ in false }
    let panes: [ImageConflictSide: ImageComparisonViewModel]
    private(set) var images: [ImageConflictSide: ComparisonImage]
    init(repository: GitRepository, access: RepositoryAccessLease?, document: ImageConflictDocument) {
        self.repository = repository; self.access = access; self.document = document
        let decoded = Dictionary(uniqueKeysWithValues: ImageConflictSide.allCases.compactMap { side in document.image(side).map { (side,$0) } })
        images = decoded
        panes = Dictionary(uniqueKeysWithValues: ImageConflictSide.allCases.map { side in
            let pane = ImageComparisonViewModel(); pane.configureImages(base: decoded[side], destination: nil)
            return (side,pane)
        })
    }
    func fitImages() { for pane in panes.values { pane.fit = true } }
    func originalSize() { for pane in panes.values { pane.originalSize() } }
    func zoom(_ zoomIn: Bool) { for pane in panes.values { pane.changeZoom(zoomIn: zoomIn) } }
    func retire() { for pane in panes.values { pane.stopAllPlayback() }; retired = true; cancellation?.cancel(); task?.cancel(); task = nil }
    func reload() {
        guard !busy, !retired else { return }; busy = true; error = nil
        let token = OperationCancellation(); cancellation = token
        task = Task { [weak self] in
            guard let self, !self.retired else { return }; defer { busy = false; task = nil; cancellation = nil }
            do {
                guard let next = try await repository.imageConflictDocument(path: document.entry.path, cancellation: token) else { throw ImageConflictFailure.unavailable }
                guard !retired else { return }
                document = next
                images = Dictionary(uniqueKeysWithValues: ImageConflictSide.allCases.compactMap { side in next.image(side).map { (side,$0) } })
                for side in ImageConflictSide.allCases { panes[side]?.configureImages(base: images[side], destination: nil) }
                fitImages()
            } catch { if !retired { self.error = error.localizedDescription } }
        }
    }
    func select(_ side: ImageConflictSide) {
        guard !busy, !retired, images[side] != nil else { return }; busy = true; error = nil
        let token = OperationCancellation(); cancellation = token
        task = Task { [weak self] in
            guard let self, !self.retired else { return }; defer { busy = false; task = nil; cancellation = nil }
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
                    Button { model.zoom(true) } label: { CommandLabel(title: "Zoom in", icon: .imageZoomIn) }
                    Button { model.zoom(false) } label: { CommandLabel(title: "Zoom out", icon: .imageZoomOut) }
                    Divider()
                    Toggle(isOn: $model.showInfo) { CommandLabel(title: "Image info", icon: .imageInfo) }
                    Toggle(isOn: $model.vertical) { CommandLabel(title: "Arrange vertical", icon: .imageVertical) }
                }.fixedSize()
                Button("Reload") { model.reload() }
            }.padding(8)
            Divider()
            if model.vertical {
                VSplitView { pane(.mine); pane(.base); pane(.theirs) }
            } else {
                HSplitView { pane(.mine); pane(.base); pane(.theirs) }
            }
            if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled).padding(8) }
            HStack { if model.busy { ProgressView().controlSize(.small); Text("Selecting image…") }; Spacer(); Text(model.document.entry.path).lineLimit(1) }.font(.caption).padding(8)
        }.background(Color(nsColor: .windowBackgroundColor)).disabled(model.busy)
    }
    private func pane(_ side: ImageConflictSide) -> some View {
        ImageConflictPane(side: side, image: model.images[side], bytes: model.document.contents[side]?.count ?? 0,
                          title: side == .mine && model.document.mineStage == 3 ? "Mine — Branch being rebased" : side == .theirs && model.document.theirsStage == 2 ? "Theirs — Branch being rebased onto" : side.rawValue,
                          model: model.panes[side]!, info: model.showInfo) { model.select(side) }
    }
}
private struct ImageConflictPane: View {
    let side: ImageConflictSide
    let image: ComparisonImage?
    let bytes: Int
    let title: String
    @ObservedObject var model: ImageComparisonViewModel
    let info: Bool
    let select: () -> Void
    var body: some View {
        let current = model.currentImage(base: true)
        VStack(spacing: 0) {
            Text(title).font(.caption).padding(7).frame(maxWidth: .infinity).background(Color(nsColor: .controlBackgroundColor))
            ImageFrameControls(model: model, base: true, label: side.rawValue)
            ZStack(alignment: .bottomLeading) {
                ImageComparisonScroll(model: model, image: current, second: nil, base: true)
                if image == nil { Text("No image on this side").foregroundStyle(.secondary) }
                if info, let image = current {
                    VStack(alignment: .leading) {
                        Text("File size: \(bytes) bytes")
                        Text("Width: \(image.pixels.width) pixels")
                        Text("Height: \(image.pixels.height) pixels")
                        Text("Depth: \(image.pixels.bitsPerPixel) bits")
                    }.font(.caption).padding(8).background(.regularMaterial).padding(10).allowsHitTesting(false)
                }
            }
            HStack { Text(model.fit ? "Fit in window" : "Zoom: \(Int(model.zoom * 100))%").font(.caption); Spacer(); ImageConflictSelectButton(side: side, enabled: image != nil, action: select).frame(width: 90,height: 24) }.padding(7)
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
