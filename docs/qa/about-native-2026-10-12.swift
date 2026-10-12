import AppKit
import TurtleGitCore

struct AboutNativeVerification {
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor static func verify() async throws {
        let app = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app")
        let bundle = Bundle(url: app)!
        let information = ApplicationAboutInformation(application: app, version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
        precondition(information.components.first { $0.name == "Git" }?.version == "2.55.0" && information.license != nil && information.notices != nil)
        precondition(information.components.first { $0.name == "Subversion" }?.version == "1.14.5" && information.components.first { $0.name == "Perl" }?.version == "5.44.0")
        for tool in TurtleGitAboutTool.allCases {
            let controller = TurtleGitAboutController(tool: tool, information: information), window = controller.window!
            window.contentView!.layoutSubtreeIfNeeded()
            var links: [URL] = [], updates = 0, closed = 0
            controller.open = { links.append($0) }; controller.checkUpdates = { updates += 1 }; controller.onClosed = { closed += 1 }
            let views = descendants(window.contentView!)
            let buttons = views.compactMap { $0 as? NSButton }
            precondition(buttons.contains { $0.title == "OK" && $0.keyEquivalent == "\r" })
            let text = views.compactMap { $0 as? NSTextView }.first { $0.string.contains("Git: 2.55.0") }!
            precondition(!text.isEditable && text.isSelectable && text.string == controller.diagnosticText)
            let board = NSPasteboard.withUniqueName(); controller.copyVersionInformation(to: board)
            precondition(board.string(forType: .string) == text.string); board.releaseGlobally()
            controller.openLicense(nil); controller.openNotices(nil); controller.update(nil)
            precondition(links == [information.license!, information.notices!] && updates == 1)
            if tool == .application {
                for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    window.appearance = NSAppearance(named: appearance); window.contentView!.displayIfNeeded()
                    let view = window.contentView!, bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/qa/about-" + mode + ".png"))
                }
            }
            window.performClose(nil); precondition(closed == 1)
        }
        print("About family: all five native windows, captured bundle runtime/credits, selectable/copyable exact report, injected license/notices/update routes, default OK and close cleanup passed. No URLs, updates or installed app launched.")
    }
}
