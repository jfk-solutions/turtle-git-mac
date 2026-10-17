// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import Darwin
import TurtleGitCore

@main struct DaemonProgressVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    final class Gate: @unchecked Sendable {
        private let lock = NSLock(); private var value = false
        func open() { lock.lock(); value = true; lock.unlock() }
        var opened: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(description:message) } }
    @MainActor static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<1800 { if condition() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Daemon progress wait at \(line)")
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func capture(_ window:NSWindow) async throws {
        guard let folder = ProcessInfo.processInfo.environment["TURTLEGIT_DAEMON_PROGRESS_CAPTURE"] else { return }
        guard #available(macOS 14.4, *) else { throw Failure(description:"Capture unavailable") }
        window.alphaValue=1; window.orderFront(nil); defer { window.alphaValue=0 }
        for (appearance,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:appearance); window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds:250_000_000)
            let content=try await SCShareableContent.currentProcess
            guard let owned=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else { throw Failure(description:"Owned daemon window unavailable") }
            let config=SCStreamConfiguration(); config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false;config.ignoreShadowsSingleWindow=true;config.includeChildWindows=false
            let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:owned),configuration:config)
            guard let bytes=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else { throw Failure(description:"PNG encoding") }
            try bytes.write(to:URL(fileURLWithPath:folder).appendingPathComponent("daemon-progress-"+name+".png"))
        }
    }
    static func availablePort() throws -> UInt16 {
        let fd=socket(AF_INET,SOCK_STREAM,0); guard fd>=0 else { throw POSIXError(.EIO) }; defer { Darwin.close(fd) }
        var address=sockaddr_in(); address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET);address.sin_addr.s_addr=inet_addr("127.0.0.1")
        let bound=withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound==0 else { throw POSIXError(.EIO) }
        var size=socklen_t(MemoryLayout<sockaddr_in>.size)
        let result=withUnsafeMutablePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { getsockname(fd,$0,&size) } }
        guard result==0 else { throw POSIXError(.EIO) }; return UInt16(bigEndian:address.sin_port)
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]), git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.DaemonProgress."+UUID().uuidString, preferences=UserDefaults(suiteName:suite)!
        var windows=[GitDaemonWindowController]()
        defer { for controller in windows { controller.model.retire(); controller.window?.close() }; preferences.removePersistentDomain(forName:suite) }
        let repoRoot=folder.appendingPathComponent("repository 雪");try FileManager.default.createDirectory(at:repoRoot,withIntermediateDirectories:true)
        let repository=GitRepository(root:repoRoot,executable:git)
        _ = try await repository.run(["init","-b","main"])
        let log=ActionLogStore(storageURL:folder.appendingPathComponent("private-action-log.txt"))
        ProgressActionLog.install(store:log,preferences:preferences)
        let delegate=TurtleGitApplicationDelegate()
        func make(_ configuration:GitDaemonConfiguration = .init()) -> GitDaemonWindowController {
            var local = configuration
            if local.listenAddresses.isEmpty { local.listenAddresses = ["127.0.0.1"] }
            let controller=GitDaemonWindowController(repository:repository,access:nil,configuration:local,preferences:preferences)
            controller.window?.alphaValue=0;windows.append(controller);return controller
        }
        // Match the existing warning/stream/close coverage without running unrelated
        // LFS/mail families again. This creates no public listener.
        try await DaemonNativeVerification.verify()
        preferences.set(true,forKey:"ConfirmKillProcess");preferences.set(2,forKey:"AutoCloseGitProgress");preferences.set(false,forKey:"ShowGitexeTimings")
        let natural=make(), gate=Gate();let registry=DockProgressRegistry(presentation:{_ in})
        natural.model.dockRegistry=registry
        natural.model.run={_,_,token,emit in emit(.init(stream:.stderr,data:Data("Ready to rumble\n".utf8)));while !gate.opened && !token.isCancelled {usleep(5_000)};return 0}
        var replies=[(Bool)->Void](), closes=0
        natural.model.close={closes += 1}
        natural.model.confirmCancellation={replies.append($0)}
        natural.model.proceed();try await wait {natural.model.status=="Git daemon is running."}
        natural.model.cancel(closeWhenStopped:true);natural.model.cancel()
        try require(replies.count==1 && natural.model.confirmingCancellation && registry.current?.kind == .paused,"Duplicate kill question or missing waiting Dock")
        gate.open();try await wait {natural.model.phase == .finished}
        try require(natural.model.success && !natural.model.cancelled && closes==0 && GitDaemonWindowModel.activeOperations==0 && GitDaemonWindowModel.activeQuestions==1,"Natural exit crossed the pending question")
        try require(delegate.applicationShouldTerminate(NSApp) == .terminateCancel,"Quit ignored pending daemon question")
        replies[0](true);replies[0](true)
        try require(closes==1 && natural.model.success && !natural.model.cancelled && GitDaemonWindowModel.activeQuestions==0 && registry.current==nil,"Late/duplicate answer retargeted completion")
        natural.model.saveActionLog();let firstLog=try log.read();natural.model.saveActionLog();try require(try log.read()==firstLog,"Duplicate daemon action log")
        natural.window?.close()

        preferences.set(0,forKey:"AutoCloseGitProgress")
        let cancel=make();var cancellationReplies=[(Bool)->Void]()
        cancel.model.confirmCancellation={cancellationReplies.append($0)}
        cancel.model.run={_,_,token,emit in emit(.init(stream:.stdout,data:Data("Ready to rumble\n".utf8)));while !token.isCancelled {usleep(5_000)};return 130}
        cancel.model.proceed();try await wait {cancel.model.status=="Git daemon is running."}
        cancel.model.cancel();cancellationReplies[0](false)
        try require(cancel.model.busy && !cancel.model.confirmingCancellation && cancel.model.dockState?.kind == .running,"No answer stopped serving")
        cancel.model.cancel();cancellationReplies[0](true)
        try require(cancel.model.confirmingCancellation && cancel.model.busy,"Old question answered replacement")
        cancellationReplies[1](true);cancellationReplies[1](true)
        try await wait {cancel.model.phase == .finished}
        try require(cancel.model.cancelled && !cancel.model.success && cancel.model.output.contains("User cancelled") && cancel.model.completionRange != nil && cancel.model.dockState?.kind == .failed,"Confirmed stop completion/Dock lost")
        cancel.window?.close()

        let failed=make();preferences.set(1,forKey:"GitOutputLimitinKiB")
        failed.model.run={_,_,_,emit in emit(.init(stream:.stderr,data:Data("fatal: occupied QA listener\nSee https://example.invalid/daemon\n".utf8)));throw GitDaemonFailure.failed(7,"fatal: occupied QA listener")}
        failed.model.proceed();try await wait {failed.model.phase == .finished}
        try require(!failed.model.success && failed.model.output.contains("exit code 7") && failed.model.completionRange != nil,"Daemon exit code or completion missing")
        try require(failed.model.output.contains("git://127.0.0.1/") && failed.model.output.contains("git daemon --verbose") && failed.model.output.components(separatedBy:"fatal: occupied QA listener").count == 2,"Daemon pretext/command missing or streamed failure duplicated")
        failed.window?.contentView?.layoutSubtreeIfNeeded()
        try await wait {failed.window?.contentView.map{descendants($0).contains{$0 is SubmoduleProgressTextView}} == true}
        let text=descendants(failed.window!.contentView!).compactMap{$0 as? SubmoduleProgressTextView}.first!
        try await wait {text.string==failed.model.output}
        let board=NSPasteboard(name:.init("TurtleGit.Daemon.Copy."+UUID().uuidString));defer {board.releaseGlobally()};text.clipboard=board
        text.setSelectedRange(NSRange(location:0,length:5));let selection=text.selectedRange();let menu=text.outputMenu()
        try require(menu.items.first?.image != nil && menu.items.last?.image != nil,"Daemon output Copy icons missing")
        menu.performActionForItem(at:menu.items.count-1)
        try require(board.string(forType:.string)==text.string && text.selectedRange()==selection,"Copy All changed selection or output")
        let end=failed.model.completionRange!
        try require(text.textStorage?.attribute(.foregroundColor,at:end.location,effectiveRange:nil) as? NSColor != NSColor.textColor,"Daemon completion footer not styled")
        try await capture(failed.window!)
        failed.window?.close();try require((try log.read()).contains("occupied QA listener"),"Failed result not retained")

        preferences.set(16,forKey:"GitOutputLimitinKiB")
        let clipped=make()
        clipped.model.run={_,_,_,emit in emit(.init(stream:.stderr,data:Data(repeating:120,count:128*1024)));return 23}
        clipped.model.proceed();try await wait {clipped.model.phase == .finished}
        try require(!clipped.model.success && clipped.model.output.contains("exit code 23") && clipped.model.output.contains("truncated") && clipped.model.output.utf8.count < 17*1024,"Nonzero runner success bypassed bounded failure handling")
        clipped.window?.close()

        let forced=make(), forcedGate=Gate();var forcedReply:((Bool)->Void)?
        defer {forcedGate.open()}
        forced.model.confirmCancellation={forcedReply=$0}
        forced.model.run={_,_,token,_ in while !token.isCancelled {usleep(5_000)};while !forcedGate.opened {usleep(5_000)};throw GitDaemonFailure.failed(9,"late failure after force")}
        forced.model.proceed();forced.model.cancel();let before=forced.model.output
        forced.window?.close();forcedReply?(true)
        try require(GitDaemonWindowModel.activeOperations==1 && GitDaemonWindowModel.activeQuestions==0 && delegate.applicationShouldTerminate(NSApp) == .terminateCancel,"Forced close released worker lease early")
        forcedGate.open();try await wait {GitDaemonWindowModel.activeOperations==0}
        try require(forced.model.output==before && forced.model.error==nil,"Retired daemon republished completion")
        try require((try log.read()).contains("User cancelled"),"Forced-close cancellation not retained")

        // Actual Git daemon lifecycle on loopback only, through the shipping native
        // model rather than the injected process callbacks used above.
        preferences.set(false,forKey:"ConfirmKillProcess")
        var configuration=GitDaemonConfiguration();configuration.listenAddresses=["127.0.0.1"];configuration.port=try availablePort()
        let live=make(configuration);defer {live.model.retire()}
        live.model.proceed();try await wait {live.model.status=="Git daemon is running." || live.model.phase == .finished}
        try require(live.model.busy,"Loopback daemon did not start: "+live.model.output)
        _=try await repository.run(["ls-remote",configuration.urls()[0]])
        live.model.cancel();try await wait {GitDaemonWindowModel.activeOperations==0}
        try require(live.model.cancelled && live.model.completionRange != nil,"Real loopback process did not drain")
        live.window?.close()
        try require(GitDaemonWindowModel.activeQuestions==0,"Daemon question count leaked")
        print("PASS: Daemon progress family, native output/copy, completion/logging, kill questions, retired worker ownership and real loopback lifecycle")
    }
}
