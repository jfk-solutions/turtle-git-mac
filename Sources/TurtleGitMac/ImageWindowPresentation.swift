import AppKit
import SwiftUI

/// Shared by every pane in one image window, as in MainWindow/PicWindow.
@MainActor final class ImageWindowPresentation: ObservableObject {
    @Published private(set) var transparentColor: NSColor?
    @Published private var appearanceRevision = 0
    var openImages: () -> Void = {}
    private weak var window: NSWindow?
    private var colorPrompt: NSAlert?
    private var promptGeneration: UUID?

    func attach(_ window: NSWindow) { self.window = window }
    var darkMode: Bool { window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    func toggleDarkMode() {
        guard let window, window.attachedSheet == nil else { return }
        window.appearance = NSAppearance(named: darkMode ? .aqua : .darkAqua)
        // Upstream SetTheme resets the transparent color for all panes.
        transparentColor = nil; appearanceRevision += 1
    }
    func chooseTransparentColor() {
        guard let window, window.attachedSheet == nil, colorPrompt == nil else { return }
        let alert = NSAlert(); alert.messageText = "Transparent color"
        alert.informativeText = "Choose the background used behind transparent image pixels."
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        let well = NSColorWell(frame: NSRect(x: 0, y: 0, width: 260, height: 40))
        well.color = transparentColor ?? .white
        well.setAccessibilityLabel("Transparent image color")
        alert.accessoryView = well
        let generation = UUID(); promptGeneration = generation; colorPrompt = alert
        alert.beginSheetModal(for: window) { [weak self, weak window] response in
            well.deactivate()
            guard let self, self.promptGeneration == generation else { return }
            self.promptGeneration = nil; self.colorPrompt = nil
            if response == .alertFirstButtonReturn, let rgb = well.color.usingColorSpace(.deviceRGB) {
                self.transparentColor = NSColor(deviceRed: rgb.redComponent, green: rgb.greenComponent,
                                                blue: rgb.blueComponent, alpha: 1)
            }
            window?.makeFirstResponder(window?.contentView)
        }
    }
    func retire() {
        promptGeneration = nil
        if let prompt = colorPrompt, let window, window.attachedSheet === prompt.window {
            (prompt.accessoryView as? NSColorWell)?.deactivate()
            window.endSheet(prompt.window, returnCode: .abort)
        }
        colorPrompt = nil; window = nil
    }
    static func background(_ color: NSColor?, appearance: NSAppearance) -> NSColor {
        guard let rgb = color?.usingColorSpace(.deviceRGB) else { return .textBackgroundColor }
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let bytes = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
        // PicWindow specially maps white to the dark window background.
        if dark, bytes == [255, 255, 255] { return .textBackgroundColor }
        let themed = StatusTextPalette.transform(bytes, dark: dark)
        return NSColor(deviceRed: CGFloat(themed[0]) / 255, green: CGFloat(themed[1]) / 255,
                       blue: CGFloat(themed[2]) / 255, alpha: 1)
    }
}

struct ImageAppearanceMenu: View {
    @ObservedObject var presentation: ImageWindowPresentation
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Toggle("Dark Mode", isOn: Binding(get: { colorScheme == .dark }, set: { _ in presentation.toggleDarkMode() }))
    }
}
