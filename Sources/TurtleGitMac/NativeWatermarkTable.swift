import AppKit
import TurtleGitCore

/// Original translucent list artwork, anchored to the current viewport like
/// upstream's LVBKIF_TYPE_WATERMARK rather than scrolling with the rows.
@MainActor class NativeWatermarkTable: NSTableView {
    private let defaults: UserDefaults
    let watermarkImage: NSImage?
    init(icon: MenuIcon, defaults: UserDefaults = .standard) {
        self.defaults = defaults; watermarkImage = icon.image(size: 128)
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { defaults = .standard; watermarkImage = nil; super.init(coder: coder) }
    func backdropRect(in viewport: NSRect) -> NSRect? {
        guard defaults.object(forKey: "ShowListBackgroundImage") as? Bool ?? true,
              watermarkImage != nil, viewport.width > 0, viewport.height > 0 else { return nil }
        return NSRect(x: viewport.maxX - 128, y: isFlipped ? viewport.maxY - 128 : viewport.minY, width: 128, height: 128)
    }
    override func drawBackground(inClipRect clipRect: NSRect) {
        super.drawBackground(inClipRect: clipRect)
        guard let rect = backdropRect(in: visibleRect), rect.intersects(clipRect) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: visibleRect.intersection(clipRect)).addClip()
        watermarkImage?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}
