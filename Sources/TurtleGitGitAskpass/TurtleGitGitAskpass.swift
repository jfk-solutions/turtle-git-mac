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
        let icon = NSImage(contentsOf: parent.appendingPathComponent("Contents/Frameworks/TurtleGitCore.framework/Resources/Icons/TurtleGitApplication.png"))
        if let icon { application.applicationIconImage = icon }
        let ssh = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent == "TurtleGitOpenSSHAskpass"
        do {
            if CommandLine.arguments[1].hasPrefix(GitRemoteAuthenticationPrompt.prefix){
                guard let request=try GitRemoteAuthenticationPrompt.decode(CommandLine.arguments[1],enabled:!ssh && ProcessInfo.processInfo.environment["TURTLEGIT_REMOTE_NATIVE_PROMPTS"]=="1") else{exit(1)}
                guard let marker=ProcessInfo.processInfo.environment["TURTLEGIT_REMOTE_PROMPT_CANCEL_FILE"],let promptLock=remotePromptLock(marker:marker) else{exit(1)}
                defer{flock(promptLock,LOCK_UN);Darwin.close(promptLock)}
                let certificateIcon=NSImage(contentsOf:parent.appendingPathComponent("Contents/Frameworks/TurtleGitCore.framework/Resources/Icons/certcheck.ico"))
                let controller=GitSVNPromptWindowController(prompt:request,icon:request.kind == .trust ? certificateIcon ?? icon:icon,transportName:"Git"){answer in
                    guard let answer else{exit(1)}
                    do{let encoded=try answer.encoded(for:request);try FileHandle.standardOutput.write(contentsOf:Data((encoded+"\n").utf8));exit(0)}catch{exit(1)}
                }
                var cancellation:DispatchSourceTimer?
                let timer=DispatchSource.makeTimerSource(queue:.main);timer.schedule(deadline:.now(),repeating:.milliseconds(20));timer.setEventHandler{MainActor.assumeIsolated{if FileManager.default.fileExists(atPath:marker){controller.abort()}}};timer.resume();cancellation=timer
                controller.showWindow(nil);controller.window?.makeKeyAndOrderFront(nil);application.activate(ignoringOtherApps:true)
                withExtendedLifetime((controller,cancellation)){application.run()};exit(1)
            }
            if let request = try GitSVNAuthenticationPrompt.decode(CommandLine.arguments[1], enabled: !ssh && ProcessInfo.processInfo.environment["TURTLEGIT_SVN_NATIVE_PROMPTS"] == "1") {
                let certificateIcon = NSImage(contentsOf: parent.appendingPathComponent("Contents/Frameworks/TurtleGitCore.framework/Resources/Icons/certcheck.ico"))
                let controller = GitSVNPromptWindowController(prompt: request, icon: request.kind == .trust ? certificateIcon ?? icon : icon) { answer in
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
    private static func remotePromptLock(marker:String)->Int32?{
        guard marker.hasPrefix("/"),!marker.contains("\0"),!FileManager.default.fileExists(atPath:marker),let path=ProcessInfo.processInfo.environment["TURTLEGIT_REMOTE_PROMPT_LOCK"],path.hasPrefix("/"),!path.contains("\0"),URL(fileURLWithPath:path).deletingLastPathComponent()==URL(fileURLWithPath:marker).deletingLastPathComponent() else{return nil}
        let descriptor=Darwin.open(path,O_RDWR|O_NOFOLLOW|O_CLOEXEC)
        guard descriptor>=0 else{return nil}
        var info=stat()
        guard fstat(descriptor,&info)==0,info.st_uid==getuid(),info.st_mode & S_IFMT == S_IFREG,info.st_mode & 0o777 == 0o600,flock(descriptor,LOCK_EX)==0,!FileManager.default.fileExists(atPath:marker) else{Darwin.close(descriptor);return nil}
        return descriptor
    }
}
