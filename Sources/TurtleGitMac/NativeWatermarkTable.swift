import AppKit
import TurtleGitCore

/// Original translucent list artwork, anchored to the current viewport like
/// upstream's LVBKIF_TYPE_WATERMARK rather than scrolling with the rows.
@MainActor class NativeWatermarkTable: NSTableView {
    private let defaults: UserDefaults
    private(set) var watermarkImage: NSImage?
    init(icon: MenuIcon, defaults: UserDefaults = .standard) {
        self.defaults = defaults; watermarkImage = icon.image(size: 128)
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { defaults = .standard; watermarkImage = nil; super.init(coder: coder) }
    func setWatermark(_ icon: MenuIcon) { watermarkImage = icon.image(size: 128); needsDisplay = true }
    func backdropRect(in viewport: NSRect) -> NSRect? {
        guard defaults.object(forKey: "ShowListBackgroundImage") as? Bool ?? true,
              // Never position a full-size watermark above a short viewport:
              // its negative origin otherwise bleeds through a transparent header.
              watermarkImage != nil, viewport.width >= 128, viewport.height >= 128 else { return nil }
        return NSRect(x: viewport.maxX - 128, y: isFlipped ? viewport.maxY - 128 : viewport.minY, width: 128, height: 128)
    }
    override func drawBackground(inClipRect clipRect: NSRect) {
        super.drawBackground(inClipRect: clipRect)
        let viewport=visibleRect.intersection(bounds)
        guard let rect = backdropRect(in: viewport), rect.intersects(clipRect) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: viewport.intersection(clipRect)).addClip()
        watermarkImage?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}
