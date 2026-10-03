#if DEBUG
import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

@MainActor enum DocumentationCapture {
    static func saveWindow() {
        guard let selected = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let window = selected.sheetParent ?? selected.parent ?? selected
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
                // Sheets can be wider than their parent and are not necessarily
                // listed in childWindows. Include both when sizing the capture.
                let attached = (window.childWindows ?? []) + (window.attachedSheet.map { [$0] } ?? [])
                let bounds = attached.reduce(window.frame) { $0.union($1.frame) }
                config.width = Int(bounds.width * window.backingScaleFactor)
                config.height = Int(bounds.height * window.backingScaleFactor)
                config.showsCursor = false
                config.ignoreShadowsSingleWindow = true
                let rendered = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                guard let png = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]) else { return }
                if let path = Bundle.main.object(forInfoDictionaryKey: "TurtleGitDocumentationCapturePath") as? String {
                    try png.write(to: URL(fileURLWithPath: path), options: .atomic)
                    return
                }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.nameFieldStringValue = "turtlegit-window.png"
                panel.prompt = "Save screenshot"
                panel.begin { response in
                    guard response == .OK, let url = panel.url else { return }
                    do { try png.write(to: url, options: .atomic) }
                    catch { NSAlert(error: error).runModal() }
                }
            } catch { NSAlert(error: error).runModal() }
        }
    }
}
#endif
