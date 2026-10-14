// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Darwin

@main struct TurtleGitGitAskpass {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 2, isatty(STDOUT_FILENO) == 0 else { exit(1) }
        signal(SIGPIPE, SIG_IGN)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        switch ProcessInfo.processInfo.environment["TURTLEGIT_ASKPASS_APPEARANCE"] {
        case "light": application.appearance = NSAppearance(named: .aqua)
        case "dark": application.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        var parent = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        while parent.path != "/" && parent.pathExtension != "app" { parent.deleteLastPathComponent() }
        let icon = NSImage(contentsOf: parent.appendingPathComponent("Contents/Frameworks/TurtleGitCore.framework/Resources/Icons/TortoiseSmall.ico"))
        if let icon { application.applicationIconImage = icon }
        let ssh = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent == "TurtleGitOpenSSHAskpass"
        do {
            if let request = try GitSVNAuthenticationPrompt.decode(CommandLine.arguments[1], enabled: !ssh && ProcessInfo.processInfo.environment["TURTLEGIT_SVN_NATIVE_PROMPTS"] == "1") {
                let controller = GitSVNPromptWindowController(prompt: request, icon: icon) { answer in
                    guard let answer else { exit(1) }
                    do { let encoded = try answer.encoded(for: request); try FileHandle.standardOutput.write(contentsOf: Data((encoded + "\n").utf8)); exit(0) } catch { exit(1) }
                }
                if let directory = ProcessInfo.processInfo.environment["TURTLEGIT_SVN_CERT_DIRECTORY"] { controller.certificateDirectory = URL(fileURLWithPath: directory) }
                controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); application.activate(ignoringOtherApps: true)
                withExtendedLifetime(controller) { application.run() }; exit(1)
            }
        } catch { exit(1) }
        let prompt = GitAskpassPrompt(CommandLine.arguments[1], ssh: ssh, hint: ProcessInfo.processInfo.environment["SSH_ASKPASS_PROMPT"], svn: !ssh && ProcessInfo.processInfo.environment["TURTLEGIT_SVN_NATIVE_PROMPTS"] == "1")
        let controller = GitAskpassWindowController(prompt: prompt, icon: icon) { answer in
            guard let answer else { exit(1) }
            do { try FileHandle.standardOutput.write(contentsOf: Data((answer + "\n").utf8)); exit(0) }
            catch { exit(1) }
        }
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        withExtendedLifetime(controller) { application.run() }
        exit(1)
    }
}
