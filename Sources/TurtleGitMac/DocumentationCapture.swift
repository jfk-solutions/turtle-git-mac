#if DEBUG
import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor enum DocumentationCapture {
    static func saveWindow() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        Task {
            do {
                guard #available(macOS 14.4, *) else {
                    throw NSError(domain: "TurtleGitDocumentation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Documentation screenshots require macOS 14.4 or later."])
                }
                // This API enumerates only content the current process can capture
                // without TCC consent. Never request access to other apps or displays.
                let content = try await SCShareableContent.currentProcess
                guard let ownWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                    throw NSError(domain: "TurtleGitDocumentation", code: 2, userInfo: [NSLocalizedDescriptionKey: "The selected application window is unavailable for capture."])
                }
                let filter = SCContentFilter(desktopIndependentWindow: ownWindow)
                let config = SCStreamConfiguration()
                config.width = Int(window.frame.width * window.backingScaleFactor)
                config.height = Int(window.frame.height * window.backingScaleFactor)
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                let rendered = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                guard let png = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]) else { return }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.nameFieldStringValue = "turtlegit-window.png"
                panel.prompt = "Save screenshot"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try png.write(to: url, options: .atomic)
            } catch { NSAlert(error: error).runModal() }
        }
    }
}
#endif
