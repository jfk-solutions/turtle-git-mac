import AppKit
import SwiftUI
import TurtleGitCore

struct UtilityDialogCapture {
    @MainActor static func main() async { do { try await capture() } catch { fputs("Utility capture failed: \(error)\n",stderr); exit(1) } }
    @MainActor static func capture() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), repo = GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        let suite = "TurtleGit.UtilityCapture." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        let clipboard = NSPasteboard(name:NSPasteboard.Name(suite))
        defer { prefs.removePersistentDomain(forName:suite); clipboard.clearContents() }
        let output = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/qa/utility-captures-2026-10-12")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        func wait(_ ready:()->Bool) async throws { for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }; throw NSError(domain:"Utility capture did not settle",code:1) }
        func png(_ window:NSWindow,_ name:String) async throws {
            window.contentView?.layoutSubtreeIfNeeded(); NSApplication.shared.activate(ignoringOtherApps:true)
            window.makeKeyAndOrderFront(nil); window.makeFirstResponder(nil)
            try await Task.sleep(nanoseconds:300_000_000)
            let file = output.appendingPathComponent(name + ".png"), process = Process()
            process.executableURL = URL(fileURLWithPath:"/usr/sbin/screencapture")
            process.arguments = ["-x","-o","-l",String(window.windowNumber),file.path]
            let errors = Pipe(); process.standardError = errors
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0, FileManager.default.fileExists(atPath:file.path) else { throw NSError(domain:"Owned window capture unavailable: " + String(decoding:errors.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self),code:1) }
            let data = try Data(contentsOf:file)
            func dimension(_ offset:Int) -> UInt32 { data[offset..<offset+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
            guard data.count > 24, dimension(16) >= 600, dimension(20) >= 300 else { throw NSError(domain:"Captured utility window collapsed: " + name,code:1) }
            window.orderOut(nil)
        }
        func themes(_ window:NSWindow,_ name:String) async throws {
            for (appearance,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
                window.appearance = NSAppearance(named:appearance); window.contentView?.appearance = window.appearance
                try await png(window,name + "-" + suffix)
            }
        }
        let local = ClientHook(type:.preCommit,path:repo.root.path,command:"/usr/bin/python3 '%root%/scripts/check-commit.py'",show:false,local:true)
        try await repo.saveProjectClientHooks([local])
        let global = ClientHook(type:.postPush,path:"/Users/demo/Projects",command:"/bin/sh '%root%/scripts/after-push.sh'",wait:false,show:false)
        prefs.set(try ClientHookConfiguration.serialize([global]),forKey:"hooks")
        let model = HookSettingsModel(preferences:prefs), transaction = SettingsTransaction()
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:600),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = "Hook Scripts – TurtleGit for Mac"; window.isReleasedWhenClosed = false
        let page = HookSettingsPage(model:model,repository:repo,access:nil).environment(\.settingsTransaction,transaction)
        let host = NSHostingView(rootView:VStack(spacing:0) {
            HStack { if let icon = MenuIcon.settingsHooks.image() { Image(nsImage:icon).frame(width:16,height:16) }; Text("Hook Scripts"); Spacer() }.padding(12)
            page; Divider()
            HStack { Spacer(); Button("OK") { transaction.apply(closeAfter:true) }; Button("Cancel") { transaction.cancel() }; Button("Apply") { transaction.apply(closeAfter:false) }.disabled(!model.modified) }.padding(12)
        })
        window.contentView = host; host.frame = window.contentLayoutRect; host.layoutSubtreeIfNeeded()
        defer { model.invalidate(); transaction.invalidate(); window.contentView = nil; window.close() }
        model.activate(repository:repo,access:nil); try await wait { model.loaded && !model.busy }
        model.selection = [local.id]
        try await themes(window,"hook-settings")
        let configuration = HookConfigurationController(hook:local,repositoryRoot:repo.root,preferences:prefs)
        defer { configuration.finish(nil) }
        try await themes(configuration.window!,"hook-config")
        configuration.finish(nil)
        let helper = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/IssueRegex/issue-regex")
        let autotext = AutotextTesterModel(executable:helper,preferences:prefs,clipboard:clipboard), tester = AutotextTesterController(model:autotext)
        defer { tester.close() }
        autotext.content = "class Example {\n    func commitMessage() { }\n    func refreshStatus() { }\n}\n"
        autotext.pattern = "(?:class|func)\\s+([A-Za-z_][A-Za-z0-9_]*)"
        autotext.scan(); try await wait { !autotext.busy && !autotext.result.isEmpty }
        try await themes(tester.window!,"autotext-tester")
        tester.close(); try await wait { AutotextTesterModel.activeRequests == 0 }
        print("Captured six actual native Hook Scripts/configuration/Autotext light-dark windows. Private sample config and matching only; no hook script executed. Owned windows/helpers retired.")
    }
}
