import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class ImageComparisonViewModel: ObservableObject {
    @Published var overlay = false { didSet { if overlay { linked = true } } }
    @Published var blendAlpha = true
    @Published var vertical = false
    @Published var linked = true
    @Published var showInfo = false
    @Published var fit = true
    @Published var zoom: CGFloat = 1
    @Published var alpha: Double = 0.5
    var fittedZoom: CGFloat = 1
    private var scrolls: [Bool: NSScrollView] = [:]
    private var synchronizing = false
    func originalSize() { fit = false; zoom = 1 }
    func changeZoom(_ factor: CGFloat) { let wasFit = fit; fit = false; zoom = min(16, max(0.01, (wasFit ? fittedZoom : zoom) * factor)) }
    func register(_ scroll: NSScrollView, base: Bool) { scrolls[base] = scroll }
    func unregister(_ scroll: NSScrollView, base: Bool) { if scrolls[base] === scroll { scrolls.removeValue(forKey: base) } }
    func didScroll(_ source: NSScrollView, base: Bool) {
        guard linked, !synchronizing, let target = scrolls[!base], let content = target.documentView else { return }
        synchronizing = true; defer { synchronizing = false }
        target.contentView.scroll(to: ImageComparisonGeometry.linkedOrigin(source.contentView.bounds.origin, content: content.frame.size, viewport: target.contentView.bounds.size))
        target.reflectScrolledClipView(target.contentView)
    }
}

@MainActor struct ImageComparisonDialog: View {
    let images: ImageComparisonDocument
    let document: FileComparisonDocument
    @StateObject private var model: ImageComparisonViewModel
    init(images: ImageComparisonDocument, document: FileComparisonDocument, model: ImageComparisonViewModel? = nil) {
        self.images = images; self.document = document; _model = StateObject(wrappedValue: model ?? ImageComparisonViewModel())
    }
    private func tool(_ title: String, _ icon: MenuIcon, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(nsImage: icon.image() ?? NSImage()).resizable().frame(width: 20, height: 20) }
            .background(active ? Color.accentColor.opacity(0.22) : Color.clear)
            .help(title).accessibilityLabel(title).accessibilityValue(active ? "On" : "Off")
    }
    private func pane(base: Bool) -> some View {
        let image = base ? images.base : images.destination
        let content = base ? document.base : document.destination
        return VStack(alignment: .leading, spacing: 0) {
            Text(content.path + " — " + content.revision.label).font(.caption).lineLimit(1).truncationMode(.middle)
                .padding(7).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor))
            ZStack(alignment: .topLeading) {
                ImageComparisonScroll(model: model, image: image, second: model.overlay ? images.destination : nil, base: base)
                if image == nil && !model.overlay { Text("No image on this side").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                if model.showInfo, let image {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("File size: \(content.bytes.count) bytes")
                        Text("Width: \(image.pixels.width) pixels")
                        Text("Height: \(image.pixels.height) pixels")
                        if let x = image.dpiX, let y = image.dpiY { Text(String(format: "Resolution: %.1f × %.1f dpi", x, y)) }
                        Text("Depth: \(image.pixels.bitsPerPixel) bits")
                        if image.frameCount > 1 { Text("Frame 1 of \(image.frameCount)") }
                    }.font(.caption).padding(8).background(.regularMaterial).padding(12).allowsHitTesting(false)
                }
            }
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                tool("Overlay images", .imageOverlay, active: model.overlay) { model.overlay.toggle() }
                tool("Blend alpha", .imageBlend, active: model.overlay && model.blendAlpha) { model.blendAlpha.toggle() }.disabled(!model.overlay)
                tool("Link image positions", .imageLink, active: model.linked) { model.linked.toggle() }.disabled(model.overlay)
                Divider().frame(height: 22)
                tool("Fit images in window", .imageFit, active: model.fit) { model.fit = true }
                tool("Original size", .imageOriginal) { model.originalSize() }
                tool("Zoom in", .imageZoomIn) { model.changeZoom(1.25) }
                tool("Zoom out", .imageZoomOut) { model.changeZoom(0.8) }
                Divider().frame(height: 22)
                tool("Image info", .imageInfo, active: model.showInfo) { model.showInfo.toggle() }
                tool("Arrange vertical", .imageVertical, active: model.vertical && !model.overlay) { model.vertical.toggle() }.disabled(model.overlay)
                Spacer()
                Menu("View") {
                    Toggle(isOn: $model.overlay) { CommandLabel(title: "Overlay images", icon: .imageOverlay) }
                    Toggle(isOn: $model.blendAlpha) { CommandLabel(title: "Blend alpha", icon: .imageBlend) }.disabled(!model.overlay)
                    Toggle(isOn: $model.linked) { CommandLabel(title: "Link image positions", icon: .imageLink) }.disabled(model.overlay)
                    Button { model.fit = true } label: { CommandLabel(title: "Fit images in window", icon: .imageFit) }
                    Button { model.originalSize() } label: { CommandLabel(title: "Original size", icon: .imageOriginal) }
                    Button { model.changeZoom(1.25) } label: { CommandLabel(title: "Zoom in", icon: .imageZoomIn) }
                    Button { model.changeZoom(0.8) } label: { CommandLabel(title: "Zoom out", icon: .imageZoomOut) }
                    Toggle(isOn: $model.showInfo) { CommandLabel(title: "Image info", icon: .imageInfo) }
                    Toggle(isOn: $model.vertical) { CommandLabel(title: "Arrange vertical", icon: .imageVertical) }.disabled(model.overlay)
                }
            }.padding(8)
            Divider()
            if model.overlay {
                HStack(spacing: 0) {
                    if model.blendAlpha { VStack {
                        tool("Toggle blend", .imageAlphaToggle) { model.alpha = model.alpha > 0.5 ? 0 : 1 }
                        ImageAlphaSlider(value: $model.alpha).frame(width: 28, height: 180)
                        Text("\(Int(model.alpha * 100))%").font(.caption)
                        Spacer()
                    }.padding(.vertical, 12).frame(width: 52) }
                    pane(base: true)
                }
            } else if model.vertical { VSplitView { pane(base: true); pane(base: false) } }
            else { HSplitView { pane(base: true); pane(base: false) } }
            Divider()
            HStack { Text(model.fit ? "Fit in window" : "Zoom: \(Int(model.zoom * 100))%"); Spacer(); Text("Read-only image comparison") }.font(.caption).padding(8)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ImageAlphaSlider: NSViewRepresentable {
    @Binding var value: Double
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: 0, maxValue: 1, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.setAccessibilityLabel("Image blend alpha"); slider.isContinuous = true
        return slider
    }
    func updateNSView(_ slider: NSSlider, context: Context) { context.coordinator.parent = self; slider.doubleValue = value }
    final class Coordinator: NSObject {
        var parent: ImageAlphaSlider
        init(_ parent: ImageAlphaSlider) { self.parent = parent }
        @objc func changed(_ slider: NSSlider) { parent.value = slider.doubleValue }
    }
}

private struct ImageComparisonScroll: NSViewRepresentable {
    @ObservedObject var model: ImageComparisonViewModel
    let image: ComparisonImage?
    let second: ComparisonImage?
    let base: Bool
    func makeCoordinator() -> Coordinator { Coordinator(model: model, base: base) }
    func makeNSView(context: Context) -> ImageComparisonScrollView {
        let scroll = ImageComparisonScrollView()
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let canvas = ImageComparisonCanvas(); canvas.setAccessibilityRole(.image); canvas.setAccessibilityLabel(base ? "Base image" : "Destination image")
        scroll.documentView = canvas
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak scroll, weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated {
                guard let scroll, let coordinator else { return }; coordinator.model.didScroll(scroll, base: coordinator.base)
            }
        }
        model.register(scroll, base: base)
        return scroll
    }
    func updateNSView(_ scroll: ImageComparisonScrollView, context: Context) {
        scroll.image = image; scroll.second = second; scroll.fit = model.fit; scroll.zoom = model.zoom; scroll.alpha = model.alpha; scroll.overlay = model.overlay; scroll.blendAlpha = model.blendAlpha
        scroll.onFittedScale = { [weak model] scale in if base { model?.fittedZoom = scale } }
        scroll.updateCanvas()
    }
    static func dismantleNSView(_ scroll: ImageComparisonScrollView, coordinator: Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
        coordinator.model.unregister(scroll, base: coordinator.base)
    }
    final class Coordinator {
        let model: ImageComparisonViewModel; let base: Bool
        var observer: NSObjectProtocol?
        init(model: ImageComparisonViewModel, base: Bool) { self.model = model; self.base = base }
    }
}

private final class ImageComparisonScrollView: NSScrollView {
    var image: ComparisonImage?
    var second: ComparisonImage?
    var fit = true
    var zoom: CGFloat = 1
    var alpha: Double = 0.5
    var overlay = false
    var blendAlpha = true
    var onFittedScale: ((CGFloat) -> Void)?
    override func layout() { super.layout(); updateCanvas() }
    func updateCanvas() {
        guard let canvas = documentView as? ImageComparisonCanvas else { return }
        let size = CGSize(width: max(image?.size.width ?? 0, second?.size.width ?? 0), height: max(image?.size.height ?? 0, second?.size.height ?? 0))
        let viewport = contentView.bounds.size
        let scale = fit ? ImageComparisonGeometry.fittedScale(image: size, viewport: viewport) : zoom
        if fit { onFittedScale?(scale) }
        let extent = NSSize(width: max(viewport.width, size.width * scale), height: max(viewport.height, size.height * scale))
        canvas.image = image; canvas.second = second; canvas.scale = scale; canvas.alpha = alpha; canvas.overlay = overlay; canvas.blendAlpha = blendAlpha
        if canvas.frame.size != extent { canvas.setFrameSize(extent) }
        canvas.needsDisplay = true
    }
}
private final class ImageComparisonCanvas: NSView {
    var image: ComparisonImage?
    var second: ComparisonImage?
    var scale: CGFloat = 1
    var alpha: Double = 0.5
    var overlay = false
    var blendAlpha = true
    private var dragPoint: NSPoint?
    private var dragOrigin = NSPoint.zero
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill(); dirtyRect.fill()
        let combined = CGSize(width: max(image?.size.width ?? 0, second?.size.width ?? 0), height: max(image?.size.height ?? 0, second?.size.height ?? 0))
        let origin = CGPoint(x: (bounds.width - combined.width * scale) / 2, y: (bounds.height - combined.height * scale) / 2)
        func paint(_ source: ComparisonImage?, fraction: Double) {
            guard let source else { return }
            let native = NSImage(cgImage: source.pixels, size: source.size)
            native.draw(in: NSRect(origin: origin, size: NSSize(width: source.size.width * scale, height: source.size.height * scale)), from: .zero, operation: .sourceOver, fraction: fraction, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
        }
        if overlay && !blendAlpha {
            // Render only the visible tile at backing resolution, after zoom and
            // position have been applied. Memory does not grow with the zoomed canvas.
            let tile = dirtyRect.intersection(visibleRect)
            guard !tile.isEmpty else { return }
            let backing = window?.backingScaleFactor ?? 1
            let width = Int(ceil(tile.width * backing)), height = Int(ceil(tile.height * backing))
            func rect(_ source: ComparisonImage?) -> CGRect {
                CGRect(x: (origin.x - tile.minX) * backing, y: (origin.y - tile.minY) * backing,
                       width: (source?.size.width ?? 0) * scale * backing,
                       height: (source?.size.height ?? 0) * scale * backing)
            }
            if let result = ImageComparisonXOR.render(base: image?.pixels, destination: second?.pixels,
                                                     width: width, height: height, baseRect: rect(image),
                                                     destinationRect: rect(second), background: NSColor.textBackgroundColor.cgColor) {
                NSImage(cgImage: result, size: tile.size).draw(in: tile, from: .zero, operation: .copy,
                    fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
            } else {
                ("Unable to render image comparison" as NSString).draw(at: tile.origin, withAttributes: [.foregroundColor: NSColor.labelColor])
            }
            return
        }
        paint(image, fraction: 1)
        if overlay, alpha > 0 {
            let layer = NSImage(size: bounds.size, flipped: true) { [self] rect in
                NSColor.textBackgroundColor.setFill(); rect.fill()
                paint(second, fraction: 1)
                return true
            }
            layer.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
        }
    }
    override func mouseDown(with event: NSEvent) {
        dragPoint = event.locationInWindow; dragOrigin = enclosingScrollView?.contentView.bounds.origin ?? .zero
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragPoint, let scroll = enclosingScrollView else { return }
        let point = event.locationInWindow
        let proposed = CGPoint(x: dragOrigin.x - (point.x - start.x), y: dragOrigin.y + (point.y - start.y))
        scroll.contentView.scroll(to: ImageComparisonGeometry.linkedOrigin(proposed, content: frame.size, viewport: scroll.contentView.bounds.size))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
    override func mouseUp(with event: NSEvent) { dragPoint = nil }
}
