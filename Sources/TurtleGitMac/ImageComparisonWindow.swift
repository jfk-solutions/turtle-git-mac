import AppKit
import SwiftUI
import Combine
import TurtleGitCore

@MainActor final class ImageComparisonViewModel: ObservableObject {
    let presentation: ImageWindowPresentation
    private var presentationObserver: AnyCancellable?
    init(presentation: ImageWindowPresentation? = nil) {
        self.presentation = presentation ?? ImageWindowPresentation()
        presentationObserver = self.presentation.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    @Published var overlay = false { didSet { if overlay { stopAllPlayback(); linked = true; alpha = 0.5 } } }
    @Published var blendAlpha = true
    @Published var vertical = false
    @Published var linked = true
    @Published var showInfo = false
    @Published private var sizing = ImageComparisonSizing(base: .zero, destination: .zero)
    @Published var fit = true
    @Published var alpha: Double = 0.5
    @Published private var currentImages: [Bool: ComparisonImage] = [:]
    @Published private(set) var playing: Set<Bool> = []
    @Published private(set) var frameErrors: [Bool: String] = [:]
    private var sources: [Bool: ComparisonImage] = [:]
    private var playback: [Bool: Task<Void,Never>] = [:]
    private var playbackGeneration: [Bool: UUID] = [:]
    func currentImage(base: Bool) -> ComparisonImage? { currentImages[base] }
    func configureImages(base: ComparisonImage?, destination: ComparisonImage?) {
        guard sources[true]?.id != base?.id || sources[false]?.id != destination?.id else { return }
        stopAllPlayback(); frameErrors = [:]
        sources = [:]; sources[true] = base; sources[false] = destination; currentImages = sources
        configure(base: base?.size ?? .zero, destination: destination?.size ?? .zero)
    }
    @discardableResult private func setImage(_ index: Int, base: Bool) -> Bool {
        guard let current = currentImages[base] else { return false }
        if index == current.frameIndex { return true }
        guard let next = sources[base]?.frame(at: index) else {
            frameErrors[base] = "Could not decode image \(index + 1) of \(current.frameCount)."
            stopPlayback(base: base); return false
        }
        frameErrors[base] = nil; currentImages[base] = next
        sizing.replacePixels(base: currentImages[true]?.size ?? .zero, destination: currentImages[false]?.size ?? .zero)
        return true
    }
    func stepImage(base: Bool, forward: Bool) {
        for side in linked ? [base,!base] : [base] {
            guard let image = currentImages[side] else { continue }
            setImage(ImageComparisonFrames.next(image.frameIndex, count: image.frameCount, forward: forward), base: side)
        }
    }
    func togglePlayback(base: Bool) {
        let start = !playing.contains(base)
        for side in linked ? [base,!base] : [base] {
            if start { startPlayback(base: side) } else { stopPlayback(base: side) }
        }
    }
    private func startPlayback(base: Bool) {
        guard currentImages[base]?.canAnimate == true else { return }
        stopPlayback(base: base)
        let generation = UUID(); playbackGeneration[base] = generation; playing.insert(base)
        playback[base] = Task { [weak self] in
            // Windows SetTimer(0) uses its minimum timer interval for the first tick.
            var delay: UInt64 = 10_000_000
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                guard let nextDelay = self?.animationTick(base: base, generation: generation) else { return }
                delay = nextDelay
            }
        }
    }
    private func animationTick(base: Bool, generation: UUID) -> UInt64? {
        guard playbackGeneration[base] == generation, playing.contains(base), let image = currentImages[base],
              setImage(ImageComparisonFrames.next(image.frameIndex, count: image.frameCount, forward: true, wrapping: true), base: base),
              let current = currentImages[base] else { return nil }
        return UInt64(current.animationDelay * 1_000_000_000)
    }
    private func stopPlayback(base: Bool) {
        playbackGeneration[base] = nil; playback.removeValue(forKey: base)?.cancel(); playing.remove(base)
    }
    func stopAllPlayback() { for side in [true,false] { stopPlayback(base: side) } }
    deinit { for task in playback.values { task.cancel() } }
    private var viewports: [Bool: CGSize] = [:]
    var fitWidths: Bool { sizing.widths }
    var fitHeights: Bool { sizing.heights }
    var zoom: CGFloat {
        get { CGFloat(displaySizing.base.percent) / 100 }
        set { freezeFit(); sizing.setZoom(Int(newValue * 100), base: true); if !fitWidths && !fitHeights && !overlay { sizing.setZoom(Int(newValue * 100), base: false) } }
    }
    var fittedZoom: CGFloat { CGFloat(displaySizing.base.percent) / 100 }
    private var scrolls: [Bool: NSScrollView] = [:]
    private var synchronizing = false
    func configure(base: CGSize, destination: CGSize) {
        guard sizing.base.pixels != base || sizing.destination.pixels != destination else { return }
        sizing = ImageComparisonSizing(base: base, destination: destination); sizing.overlay = overlay
    }
    var displaySizing: ImageComparisonSizing {
        var result = sizing; result.overlay = overlay
        if fit {
            let fallback = viewports[true] ?? viewports[false] ?? CGSize(width: 1,height: 1)
            result.fit(baseViewport: viewports[true] ?? fallback, destinationViewport: overlay ? viewports[true] ?? fallback : viewports[false] ?? fallback)
        }
        return result
    }
    func recordViewport(_ size: CGSize, base: Bool) { viewports[base] = size }
    private func freezeFit() { if fit { sizing = displaySizing; fit = false }; sizing.overlay = overlay }
    func originalSize() { freezeFit(); sizing.originalSize() }
    func changeZoom(zoomIn: Bool) { freezeFit(); sizing.zoom(zoomIn: zoomIn) }
    func toggleWidths() { freezeFit(); sizing.toggleWidths() }
    func toggleHeights() { freezeFit(); sizing.toggleHeights() }
    func toggleAlpha() { alpha = ImageComparisonBlend.toggled(alpha) }
    func alphaWheel(_ event: NSEvent) -> Bool {
        guard overlay, event.modifierFlags.contains([.control, .shift]) else { return false }
        // AppKit maps a Shift-modified vertical wheel into the horizontal axis.
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        let steps = event.hasPreciseScrollingDeltas ? delta / 120 : delta
        alpha = ImageComparisonBlend.wheel(alpha, steps: Double(steps)); return true
    }
    func performKey(_ event: NSEvent, window: NSWindow) -> Bool {
        let flags = event.modifierFlags.intersection([.command,.control,.option,.shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command, key == "v" { vertical.toggle(); return true }
        guard flags.isEmpty || flags == .shift else { return false }
        switch event.keyCode {
        case 126: alpha = 0; return true
        case 125: alpha = 1; return true
        case 123,124: alpha = 0.5; return true
        case 49: toggleAlpha(); return true
        case 53: window.performClose(nil); return true
        default: break
        }
        switch key {
        case "d": presentation.toggleDarkMode()
        case "o": overlay.toggle()
        case "f": fit = true
        case "s": originalSize()
        case "w": toggleWidths()
        case "h": toggleHeights()
        case "i": showInfo.toggle()
        case "+", "=": changeZoom(zoomIn: true)
        case "-": changeZoom(zoomIn: false)
        default: return false
        }
        return true
    }
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
        self.images = images; self.document = document
        let value = model ?? ImageComparisonViewModel()
        value.configureImages(base: images.base, destination: images.destination)
        _model = StateObject(wrappedValue: value)
    }
    private func tool(_ title: String, _ icon: MenuIcon, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(nsImage: icon.image() ?? NSImage()).resizable().frame(width: 20, height: 20) }
            .background(active ? Color.accentColor.opacity(0.22) : Color.clear)
            .help(title).accessibilityLabel(title).accessibilityValue(active ? "On" : "Off")
    }
    private func pane(base: Bool) -> some View {
        let image = model.currentImage(base: base)
        let content = base ? document.base : document.destination
        return VStack(alignment: .leading, spacing: 0) {
            Text(content.path + " — " + content.revision.label).font(.caption).lineLimit(1).truncationMode(.middle)
                .padding(7).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor))
            ImageFrameControls(model: model, base: base, label: base ? "Base" : "Second image")
            ZStack(alignment: .topLeading) {
                ImageComparisonScroll(model: model, image: image, second: model.overlay ? model.currentImage(base: false) : nil, base: base)
                if image == nil && !model.overlay { Text("No image on this side").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                if model.showInfo, let image {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("File size: \(content.bytes.count) bytes")
                        Text("Width: \(image.pixels.width) pixels")
                        Text("Height: \(image.pixels.height) pixels")
                        if let x = image.dpiX, let y = image.dpiY { Text(String(format: "Resolution: %.1f × %.1f dpi", x, y)) }
                        Text("Depth: \(image.pixels.bitsPerPixel) bits")
                        if image.frameCount > 1 { Text("Image \(image.frameIndex + 1) of \(image.frameCount)") }
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
                tool("Fit image widths", .imageFitWidths, active: model.fitWidths) { model.toggleWidths() }
                tool("Fit image heights", .imageFitHeights, active: model.fitHeights) { model.toggleHeights() }
                Divider().frame(height: 22)
                tool("Fit images in window", .imageFit, active: model.fit) { model.fit = true }
                tool("Original size", .imageOriginal) { model.originalSize() }
                tool("Zoom in", .imageZoomIn) { model.changeZoom(zoomIn: true) }
                tool("Zoom out", .imageZoomOut) { model.changeZoom(zoomIn: false) }
                Divider().frame(height: 22)
                tool("Image info", .imageInfo, active: model.showInfo) { model.showInfo.toggle() }
                tool("Arrange vertical", .imageVertical, active: model.vertical && !model.overlay) { model.vertical.toggle() }.disabled(model.overlay)
                Spacer()
                Menu("View") {
                    Toggle(isOn: $model.overlay) { CommandLabel(title: "Overlay images", icon: .imageOverlay) }
                    Toggle(isOn: Binding(get: { model.overlay && model.blendAlpha }, set: { model.blendAlpha = $0 })) { CommandLabel(title: "Blend alpha", icon: .imageBlend) }.disabled(!model.overlay)
                    Toggle(isOn: $model.linked) { CommandLabel(title: "Link image positions", icon: .imageLink) }.disabled(model.overlay)
                    Toggle(isOn: Binding(get: { model.fitWidths }, set: { _ in model.toggleWidths() })) { CommandLabel(title: "Fit image widths", icon: .imageFitWidths) }
                    Toggle(isOn: Binding(get: { model.fitHeights }, set: { _ in model.toggleHeights() })) { CommandLabel(title: "Fit image heights", icon: .imageFitHeights) }
                    Button { model.fit = true } label: { CommandLabel(title: "Fit images in window", icon: .imageFit) }
                    Button { model.originalSize() } label: { CommandLabel(title: "Original size", icon: .imageOriginal) }
                    Button("Transparent color…") { model.presentation.chooseTransparentColor() }
                    Divider()
                    Button { model.changeZoom(zoomIn: false) } label: { CommandLabel(title: "Zoom out", icon: .imageZoomOut) }
                    Button { model.changeZoom(zoomIn: true) } label: { CommandLabel(title: "Zoom in", icon: .imageZoomIn) }
                    Divider()
                    Toggle(isOn: $model.showInfo) { CommandLabel(title: "Image info", icon: .imageInfo) }
                    Toggle(isOn: $model.vertical) { CommandLabel(title: "Arrange vertical", icon: .imageVertical) }.disabled(model.overlay)
                    Divider()
                    ImageAppearanceMenu(presentation: model.presentation)
                }
            }.padding(8)
            Divider()
            if model.overlay {
                HStack(spacing: 0) {
                    if model.blendAlpha { VStack {
                        tool("Toggle blend", .imageAlphaToggle) { model.toggleAlpha() }
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
        .background(ImageComparisonKeyBridge(model: model).frame(width: 0,height: 0))
        .onDisappear { model.stopAllPlayback() }
    }
}

private struct ImageAlphaSlider: NSViewRepresentable {
    @Binding var value: Double
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSlider {
        let slider = ImageComparisonAlphaSlider(value: 1 - value, minValue: 0, maxValue: 1, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        (slider.cell as? NSSliderCell)?.isVertical = true
        slider.numberOfTickMarks = 17; slider.allowsTickMarkValuesOnly = true
        slider.setAccessibilityLabel("Image blend alpha"); slider.isContinuous = true
        return slider
    }
    func updateNSView(_ slider: NSSlider, context: Context) { context.coordinator.parent = self; slider.doubleValue = 1 - value }
    final class Coordinator: NSObject {
        var parent: ImageAlphaSlider
        init(_ parent: ImageAlphaSlider) { self.parent = parent }
        @objc func changed(_ slider: NSSlider) { parent.value = ImageComparisonBlend.sliderValue(1 - slider.doubleValue) }
    }
}

struct ImageComparisonScroll: NSViewRepresentable {
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
        scroll.transparentColor = model.presentation.transparentColor
        scroll.image = image; scroll.second = second; scroll.alpha = model.alpha; scroll.overlay = model.overlay; scroll.blendAlpha = model.blendAlpha
        let side = base
        scroll.recordViewport = { [weak model] size in model?.recordViewport(size, base: side) }
        scroll.alphaWheel = { [weak model] event in model?.alphaWheel(event) ?? false }
        scroll.displayedSizes = { [weak model] in
            guard let model else { return (.zero, .zero) }
            let state = model.displaySizing
            return (state.displayed(base: side), model.overlay ? state.displayed(base: false) : .zero)
        }
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

final class ImageComparisonScrollView: NSScrollView {
    var transparentColor: NSColor?
    var image: ComparisonImage?
    var second: ComparisonImage?
    var alpha: Double = 0.5
    var overlay = false
    var blendAlpha = true
    var alphaWheel: ((NSEvent) -> Bool)?
    override func scrollWheel(with event: NSEvent) { if alphaWheel?(event) != true { super.scrollWheel(with: event) } }
    var recordViewport: ((CGSize) -> Void)?
    var displayedSizes: (() -> (CGSize, CGSize))?
    override func layout() { super.layout(); updateCanvas() }
    func updateCanvas() {
        guard let canvas = documentView as? ImageComparisonCanvas else { return }
        let viewport = contentView.bounds.size
        recordViewport?(viewport)
        let (firstSize, secondSize) = displayedSizes?() ?? (.zero, .zero)
        let extent = NSSize(width: max(viewport.width, firstSize.width, secondSize.width), height: max(viewport.height, firstSize.height, secondSize.height))
        canvas.transparentColor = transparentColor
        backgroundColor = ImageWindowPresentation.background(transparentColor, appearance: effectiveAppearance)
        canvas.image = image; canvas.second = second; canvas.imageSize = firstSize; canvas.secondSize = secondSize; canvas.alpha = alpha; canvas.overlay = overlay; canvas.blendAlpha = blendAlpha
        if canvas.frame.size != extent { canvas.setFrameSize(extent) }
        canvas.needsDisplay = true
    }
}
private final class ImageComparisonCanvas: NSView {
    var transparentColor: NSColor?
    private var imageBackground: NSColor { ImageWindowPresentation.background(transparentColor, appearance: effectiveAppearance) }
    var image: ComparisonImage?
    var second: ComparisonImage?
    var imageSize = CGSize.zero
    var secondSize = CGSize.zero
    var alpha: Double = 0.5
    var overlay = false
    var blendAlpha = true
    private var dragPoint: NSPoint?
    private var dragOrigin = NSPoint.zero
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        imageBackground.setFill(); dirtyRect.fill()
        let combined = CGSize(width: max(imageSize.width, secondSize.width), height: max(imageSize.height, secondSize.height))
        let origin = CGPoint(x: (bounds.width - combined.width) / 2, y: (bounds.height - combined.height) / 2)
        func paint(_ source: ComparisonImage?, size: CGSize, fraction: Double) {
            guard let source else { return }
            let native = NSImage(cgImage: source.pixels, size: source.size)
            native.draw(in: NSRect(origin: origin, size: size), from: .zero, operation: .sourceOver, fraction: fraction, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
        }
        if overlay && !blendAlpha {
            // Render only the visible tile at backing resolution, after zoom and
            // position have been applied. Memory does not grow with the zoomed canvas.
            let tile = dirtyRect.intersection(visibleRect)
            guard !tile.isEmpty else { return }
            let backing = window?.backingScaleFactor ?? 1
            let width = Int(ceil(tile.width * backing)), height = Int(ceil(tile.height * backing))
            func rect(_ size: CGSize) -> CGRect {
                CGRect(x: (origin.x - tile.minX) * backing, y: (origin.y - tile.minY) * backing,
                       width: size.width * backing,
                       height: size.height * backing)
            }
            if let result = ImageComparisonXOR.render(base: image?.pixels, destination: second?.pixels,
                                                     width: width, height: height, baseRect: rect(imageSize),
                                                     destinationRect: rect(secondSize), background: imageBackground.cgColor) {
                NSImage(cgImage: result, size: tile.size).draw(in: tile, from: .zero, operation: .copy,
                    fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
            } else {
                ("Unable to render image comparison" as NSString).draw(at: tile.origin, withAttributes: [.foregroundColor: NSColor.labelColor])
            }
            return
        }
        paint(image, size: imageSize, fraction: 1)
        if overlay, alpha > 0 {
            let layer = NSImage(size: bounds.size, flipped: true) { [self] rect in
                imageBackground.setFill(); rect.fill()
                paint(second, size: secondSize, fraction: 1)
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

@MainActor protocol ImageComparisonKeyRouting: AnyObject {
    var imageKeyModel: ImageComparisonViewModel? { get set }
    var imageKeyOwner: UUID? { get set }
    var imageKeysRetired: Bool { get }
}
private struct ImageComparisonKeyBridge: NSViewRepresentable {
    let model: ImageComparisonViewModel
    func makeNSView(context: Context) -> ImageComparisonKeyView { let view = ImageComparisonKeyView(); view.model = model; return view }
    func updateNSView(_ view: ImageComparisonKeyView, context: Context) { view.model = model; view.install() }
    static func dismantleNSView(_ view: ImageComparisonKeyView, coordinator: ()) { view.retire() }
}
private final class ImageComparisonKeyView: NSView {
    weak var model: ImageComparisonViewModel?
    private weak var owner: ImageComparisonKeyRouting?
    private let keyOwnerID = UUID()
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); install() }
    func install() {
        guard let target = window as? ImageComparisonKeyRouting, !target.imageKeysRetired else { retire(); return }
        // Updates such as playback ticks must not retire an owned color sheet.
        if target.imageKeyOwner == keyOwnerID, target.imageKeyModel === model { return }
        retire()
        target.imageKeyOwner = keyOwnerID; target.imageKeyModel = model; owner = target
        if let window { model?.presentation.attach(window) }
    }
    func retire() {
        if owner?.imageKeyOwner == keyOwnerID { model?.presentation.retire(); owner?.imageKeyModel = nil; owner?.imageKeyOwner = nil }
        owner = nil
    }
}
/// Native vertical slider with source direction (zero at top), immediate click
/// tracking and 17 positions. Accessibility reports alpha rather than its
/// internally inverted AppKit knob value.
final class ImageComparisonAlphaSlider: NSSlider {
    private func track(_ event: NSEvent) {
        guard isEnabled, let cell = cell as? NSSliderCell else { return }
        let bar = cell.barRect(flipped: isFlipped), point = convert(event.locationInWindow, from: nil)
        guard bar.height > 0 else { return }
        let distanceFromTop = isFlipped ? point.y - bar.minY : bar.maxY - point.y
        let alpha = ImageComparisonBlend.sliderValue(Double(distanceFromTop / bar.height))
        doubleValue = 1 - alpha; sendAction(action, to: target)
    }
    override func mouseDown(with event: NSEvent) { track(event) }
    override func mouseDragged(with event: NSEvent) { track(event) }
    override func mouseUp(with event: NSEvent) { track(event) }
    override func accessibilityValue() -> Any? { NSNumber(value: (1 - doubleValue) * 100) }
    override func accessibilityMinValue() -> Any? { NSNumber(value: 0) }
    override func accessibilityMaxValue() -> Any? { NSNumber(value: 100) }
    override func setAccessibilityValue(_ value: Any?) {
        guard let number = value as? NSNumber else { return }
        doubleValue = 1 - ImageComparisonBlend.sliderValue(number.doubleValue / 100); sendAction(action, to: target)
    }
    override func accessibilityPerformIncrement() -> Bool {
        guard isEnabled else { return false }; doubleValue = max(0, doubleValue - 1.0 / 16); sendAction(action, to: target); return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        guard isEnabled else { return false }; doubleValue = min(1, doubleValue + 1.0 / 16); sendAction(action, to: target); return true
    }
}

/// Pane-local source player controls, shared by comparison and conflict panes.
struct ImageFrameControls: View {
    @ObservedObject var model: ImageComparisonViewModel
    let base: Bool
    let label: String
    var body: some View {
        if let image = model.currentImage(base: base), image.frameCount > 1 {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    ImageFrameButton(title: "Previous image (" + label + ")", icon: .imagePrevious) { model.stepImage(base: base, forward: false) }.frame(width: 22,height: 22)
                    ImageFrameButton(title: "Next image (" + label + ")", icon: .imageNext) { model.stepImage(base: base, forward: true) }.frame(width: 22,height: 22)
                    if image.canAnimate {
                        ImageFrameButton(title: (model.playing.contains(base) ? "Stop" : "Play") + " images (" + label + ")", icon: model.playing.contains(base) ? .imageStop : .imagePlay) { model.togglePlayback(base: base) }.frame(width: 22,height: 22)
                    }
                    Spacer(); Text("\(image.frameIndex + 1) of \(image.frameCount)").font(.caption).accessibilityLabel(label + " image \(image.frameIndex + 1) of \(image.frameCount)"); Spacer()
                }
                if let error = model.frameErrors[base] { Text(error).font(.caption).foregroundStyle(.red) }
            }.padding(.horizontal,7).padding(.vertical,3).background(Color(nsColor: .controlBackgroundColor))
        }
    }
}
private struct ImageFrameButton: NSViewRepresentable {
    let title: String
    let icon: MenuIcon
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.press(_:)))
        button.imagePosition = .imageOnly; button.isBordered = false
        updateNSView(button,context: context); return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.action = action; button.image = icon.image(); button.toolTip = title
        button.setAccessibilityLabel(title); button.isEnabled = context.environment.isEnabled
    }
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func press(_ sender: NSButton) { action() }
    }
}
