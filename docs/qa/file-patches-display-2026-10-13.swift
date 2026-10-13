import AppKit
import TurtleGitCore
@testable import TurtleGitMac

@MainActor private final class CaptureCommands: NSObject {
    let controller: WorkingTreePatchWindowController
    init(_ controller: WorkingTreePatchWindowController) { self.controller = controller }
    @objc func light() { NSApp.appearance = NSAppearance(named: .aqua) }
    @objc func dark() { NSApp.appearance = NSAppearance(named: .darkAqua) }
    @objc func close() { controller.window?.performClose(nil) }
}
@MainActor private var commands: CaptureCommands?

@_cdecl("file_patch_capture_main") func bootstrap() -> Int32 {
    NSApplication.shared.setActivationPolicy(.accessory)
    Task { @MainActor in
        do {
            let root = URL(fileURLWithPath: CommandLine.arguments[1])
            let repository = GitRepository(root: root, askpass: nil)
            _ = try await repository.run(["init", "-b", "main"])
            for (key,value) in [("user.name","Documentation"),("user.email","docs@example.invalid"),("commit.gpgsign","false")] { _ = try await repository.run(["config",key,value]) }
            let paths = ["README.md","Sources/Example.swift","Tests/ExampleTests.swift"]
            for directory in ["Sources","Tests"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true) }
            for path in paths { try Data("Original example\n".utf8).write(to: root.appendingPathComponent(path)) }
            try await repository.stage(paths); _ = try await repository.commit(message: "Example baseline")
            for path in paths { try Data("Updated example\n".utf8).write(to: root.appendingPathComponent(path)) }
            let patch = try await repository.run(["diff","--binary","--"]).stdout
            for path in paths { try Data("Original example\n".utf8).write(to: root.appendingPathComponent(path)) }
            try Data("Independent edit retained\n".utf8).write(to: root.appendingPathComponent(paths[1]))
            let controller = WorkingTreePatchWindowController(repository: repository, access: nil, fileAccess: nil, bytes: patch, title: "TurtleGit Demo")
            controller.onClosed = { NSApp.terminate(nil) }
            for _ in 0..<1000 { if !controller.model.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            controller.model.patchFiles(Set(controller.model.review?.files.map(\.id) ?? []), generation: controller.model.fileListGeneration)
            for _ in 0..<1000 { if !controller.model.busy { break }; try await Task.sleep(nanoseconds: 10_000_000) }
            guard controller.model.appliedPaths.count == 2 else { throw NSError(domain: "Capture fixture did not apply expected files", code: 1) }
            controller.model.previewTab = 1
            let capture = CaptureCommands(controller); commands = capture
            let menu = NSMenu(), file = NSMenuItem(title: "File", action: nil, keyEquivalent: ""), view = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
            file.submenu = NSMenu(); view.submenu = NSMenu()
            let close = NSMenuItem(title: "Close", action: #selector(CaptureCommands.close), keyEquivalent: "w"); close.target = capture; file.submenu?.addItem(close)
            for (title,action) in [("Light appearance",#selector(CaptureCommands.light)),("Dark appearance",#selector(CaptureCommands.dark))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = capture; view.submenu?.addItem(item)
            }
            menu.addItem(file); menu.addItem(view); NSApp.mainMenu = menu
            NSApp.appearance = NSAppearance(named: .aqua)
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            print("Owned file-patches preview PID \(ProcessInfo.processInfo.processIdentifier)", terminator: "\n"); fflush(stdout)
        } catch { fputs("Preview failed: \(error)\n",stderr); exit(1) }
    }
    NSApplication.shared.run(); return 0
}
