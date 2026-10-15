import AppKit
import ScreenCaptureKit
import SwiftUI
import TurtleGitCore

@main struct StatusTextVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(line: UInt = #line, _ ready: () -> Bool) async throws {
        for _ in 0..<2000 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Status text timeout at \(line)")
    }
    static func channels(_ color: NSColor) -> [Int] {
        let value = color.usingColorSpace(.sRGB)!
        return [value.redComponent, value.greenComponent, value.blueComponent].map { Int(($0 * 255).rounded()) }
    }
    @MainActor static func resolved(_ color: NSColor, _ appearance: NSAppearance) -> [Int] {
        var result: [Int] = []; appearance.performAsCurrentDrawingAppearance { result = channels(color) }; return result
    }
    // Independently check the renderer's result, rather than reuse its ratio helper.
    static func contrast(_ rgb: [Int], _ background: [Double]) -> Double {
        func luminance(_ values: [Double]) -> Double {
            let value = values.map { $0 > 0.04045 ? pow(($0 + 0.055) / 1.055, 2.4) : $0 / 12.92 }
            return zip(value, [0.2126, 0.7152, 0.0722]).reduce(0) { $0 + $1.0 * $1.1 }
        }
        let a = luminance(rgb.map { Double($0) / 255 }), b = luminance(background)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
    @MainActor static func palette(_ preferences: UserDefaults) throws {
        let light = NSAppearance(named: .aqua)!, dark = NSAppearance(named: .darkAqua)!
        let backdrop = StatusTextContrast.backgrounds(dark), minimum = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 7.0 : 4.5
        for role in StatusTextRole.allCases {
            let color = StatusTextPalette.text(role, preferences: preferences)
            try require(resolved(color, light) == StatusColorPreferences.load(preferences).rgb(role), "Light RGB changed: " + role.rawValue)
            let output = resolved(color, dark)
            try require(backdrop.allSatisfy { contrast(output, $0) >= minimum }, "Dark native text contrast failed: " + role.rawValue + " rgb=" + String(describing: output) + " backgrounds=" + String(describing: backdrop) + " ratios=" + String(describing: backdrop.map { contrast(output, $0) }))
            let source = StatusTextPalette.transform(StatusColorPreferences.load(preferences).rgb(role), dark: true, highContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
            try require(zip(output, source).allSatisfy { $0 >= $1 }, "Contrast adaptation darkened a channel")
        }
        try require(resolved(StatusTextPalette.text(.renamed, preferences: preferences), dark)[2] > resolved(StatusTextPalette.text(.renamed, preferences: preferences), dark)[0], "Rename lost its blue hue")
        for value in [[0,0,0], [255,255,255], [0,0,255], [10,20,30], [255,0,0], [25,255,25]] {
            let adjusted = StatusTextContrast.adapt(value, backgrounds: backdrop, minimum: 7)
            try require(backdrop.allSatisfy { contrast(adjusted, $0) >= 7 }, "Increased contrast target failed")
            if backdrop.allSatisfy({ contrast(value, $0) >= 7 }) { try require(adjusted == value, "Readable RGB was changed") }
        }
    }
    static func matchingPixels(_ image: CGImage, rgb: [Int]) -> Int {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        return bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return 0 }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let pixels = buffer.bindMemory(to: UInt8.self); var matches = 0
            for offset in stride(from: 0, to: pixels.count, by: 4) where pixels[offset + 3] == 255 {
                if (0..<3).allSatisfy({ abs(Int(pixels[offset + $0]) - rgb[$0]) <= 3 }) { matches += 1 }
            }
            return matches
        }
    }
    @MainActor static func capture(_ owner: NSWindowController, name: String, appearance: NSAppearance.Name, preferences: UserDefaults, directory: URL?) async throws {
        guard let directory, let window = owner.window else { return }
        guard #available(macOS 14.4, *) else { throw Failure(description: "Owned capture needs macOS 14.4") }
        NSApp.setActivationPolicy(.regular); owner.showWindow(nil); window.appearance = NSAppearance(named: appearance)
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(nil)
        window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 350_000_000)
        let content = try await SCShareableContent.currentProcess
        guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure(description: "Owned status window missing") }
        let configuration = SCStreamConfiguration(); configuration.width = Int(window.frame.width * window.backingScaleFactor); configuration.height = Int(window.frame.height * window.backingScaleFactor)
        configuration.showsCursor = false; configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: configuration)
        let expected = resolved(StatusTextPalette.text(.renamed, preferences: preferences), window.effectiveAppearance)
        let count = matchingPixels(image, rgb: expected)
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
        try require(count >= 20, "Rendered rename pixels missing in " + name + ": " + String(describing: expected) + " count=" + String(count))
        print("Rendered " + name + " rename RGB=" + String(describing: expected) + " matching pixels=" + String(count))
        window.orderOut(nil)
    }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Status text failed: \(error)\n", stderr); exit(1) } }
    @MainActor static func verify() async throws {
        NSApp.setActivationPolicy(.accessory); NSApp.finishLaunching()
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), repo = GitRepository(root: root, executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        let output = CommandLine.arguments.count > 3 ? URL(fileURLWithPath: CommandLine.arguments[3]) : nil
        let suite = "TurtleGit.StatusText." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        // Explicit fixture defaults avoid inheriting the user's saved custom colors.
        for role in StatusTextRole.allCases { prefs.set(role.rgb[0] << 16 | role.rgb[1] << 8 | role.rgb[2], forKey: role.preferenceKey) }
        prefs.set(false, forKey: "EnableGravatar"); prefs.set(false, forKey: "EnableLogCache"); prefs.set(false, forKey: "LogIncludeWorkingTreeChanges")
        let global = UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("Colors.") }
        try palette(prefs)
        _ = try await repo.run(["init", "-b", "main"])
        for (key, value) in [("user.name", "TurtleGit Team"), ("user.email", "demo@example.invalid"), ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")] { _ = try await repo.run(["config", key, value]) }
        for path in ["original.txt", "modified.txt", "deleted.txt"] { try Data((path + "\n").utf8).write(to: root.appendingPathComponent(path)) }
        try await repo.stage(["."]); _ = try await repo.commit(message: "Create status color examples")
        _ = try await repo.run(["mv", "original.txt", "renamed.txt"]); _ = try await repo.commit(message: "Rename the example document")
        _ = try await repo.run(["mv", "renamed.txt", "latest.txt"])
        _ = try await repo.run(["rm", "deleted.txt"])
        try Data("Updated status example\n".utf8).write(to: root.appendingPathComponent("modified.txt"))
        try Data("New document\n".utf8).write(to: root.appendingPathComponent("added.txt")); try await repo.stage(["added.txt"])
        let head = try await repo.run(["rev-parse", "HEAD"]).stdout, index = try Data(contentsOf: root.appendingPathComponent(".git/index")), status = try await repo.run(["status", "--porcelain=v1", "-z"]).stdout
        let commit = CommitWindowController(repository: repo, access: nil, defaults: prefs); defer { commit.close() }
        commit.model.confirmCancel = { $0(true) }; commit.model.reload()
        let working = StatusWindowController(repository: repo, access: nil, defaults: prefs); defer { working.close() }; working.model.reload()
        let log = LogWindowController(repository: repo, access: nil, labelDefaults: prefs, savesColumnLayout: false, savesGeometry: false); defer { log.close() }; log.model.reload()
        try await wait { !commit.model.busy && !working.model.busy && !log.model.busy && commit.model.entries.contains { $0.statusTextRole == .renamed } && working.model.files.contains { $0.entry.statusTextRole == .renamed } && log.model.files.contains { $0.statusTextRole == .renamed } }
        try require(working.model.colorPreferences === prefs && commit.model.colorPreferences === prefs && log.model.colorPreferences === prefs, "One owner lost its private color store")
        let windows: [(String, NSWindowController)] = [("commit", commit), ("working-tree", working), ("log", log)]
        for (name, owner) in windows {
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                try await capture(owner, name: "status-text-" + name + "-" + suffix, appearance: appearance, preferences: prefs, directory: output)
            }
        }
        let settings = StatusColorSettingsModel(preferences: prefs), saved = StatusColorPreferences.load(prefs)
        settings.set(.renamed, rgb: [0,100,200]); try require(StatusColorPreferences.load(prefs) == saved, "Draft changed saved status RGB")
        settings.cancel(); try require(!settings.changed && settings.draft == saved, "Cancel lost saved RGB")
        let revision = StatusColorUpdates.shared.revision
        settings.set(.renamed, rgb: [0,100,200]); settings.apply()
        try require(StatusColorUpdates.shared.revision == revision + 1 && StatusColorPreferences.load(prefs).rgb(.renamed) == [0,100,200], "Apply changed RGB encoding or notification count")
        try palette(prefs)
        for (name, owner) in windows {
            try await capture(owner, name: "status-text-custom-" + name + "-dark", appearance: .darkAqua, preferences: prefs, directory: output)
        }
        settings.automatic(.renamed); settings.apply(); try require(StatusColorPreferences.load(prefs).rgb(.renamed) == StatusTextRole.renamed.rgb, "Default did not restore raw source RGB")
        commit.close(); working.close(); log.close()
        let afterHead = try await repo.run(["rev-parse", "HEAD"]).stdout, afterStatus = try await repo.run(["status", "--porcelain=v1", "-z"]).stdout
        try require(head == afterHead && status == afterStatus && (try Data(contentsOf: root.appendingPathComponent(".git/index"))) == index, "Appearance check mutated repository")
        try require(NSDictionary(dictionary: global).isEqual(to: UserDefaults.standard.dictionaryRepresentation().filter { $0.key.hasPrefix("Colors.") }), "Private colors changed global preferences")
        print("PASS: Status text completed: source RGB persistence/light values, native dark/background contrast and increased-contrast target, live private Apply/Cancel/Default across Commit/Working Tree/Log, optional actual rendered pixels, unchanged HEAD/index/status and global colors. Owned windows closed.")
    }
}
