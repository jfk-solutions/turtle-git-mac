// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

@main struct SupportReportVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    @MainActor static var owners = [SupportReportWindowController]()
    @MainActor static var releaseHeld: (() -> Void)?
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(line: UInt = #line, _ predicate: () -> Bool) async throws {
        for _ in 0..<1800 { if predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Support report wait at line \(line)")
    }
    @MainActor static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    @MainActor static func cleanup() async {
        owners.forEach { $0.close() }; releaseHeld?(); releaseHeld = nil
        for _ in 0..<1800 { if SupportReportWindowModel.activeReads == 0 && SupportReportWindowModel.activeWrites == 0 && SupportReportService.activeScans == 0 { break }; try? await Task.sleep(nanoseconds: 10_000_000) }
    }
    @MainActor static func main() async {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        do { try await verify(); await cleanup(); print("PASS: Native support report, owned pickers, explicit inclusion, exact copy/export, held read/write ownership and retired callbacks") }
        catch { await cleanup(); fputs("Support report failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func capture(_ window: NSWindow, prefix: String = "support-report") async throws {
        guard let directory = ProcessInfo.processInfo.environment["TURTLEGIT_SUPPORT_CAPTURE"] else { return }
        guard #available(macOS 14.4, *) else { throw Failure(description: "Owned capture API unavailable") }
        window.alphaValue = 1; window.orderFront(nil); defer { window.alphaValue = 0 }
        for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: name); window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 250_000_000)
            let content = try await SCShareableContent.currentProcess
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure(description: "Owned support window missing") }
            let config = SCStreamConfiguration(); config.width = Int(window.frame.width * 2); config.height = Int(window.frame.height * 2)
            config.showsCursor = false; config.ignoreShadowsSingleWindow = true; config.includeChildWindows = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: config)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: directory).appendingPathComponent(prefix + "-" + suffix + ".png"))
            print("Captured \(prefix)-\(suffix): \(config.width)x\(config.height)")
        }
    }
    @MainActor final class HeldCrashScan {
        let incident:SupportCrashIncident
        var continuation:CheckedContinuation<SupportCrashIncident?,Error>?
        var token:OperationCancellation?
        init(incident:SupportCrashIncident) { self.incident = incident }
        func read(_ token:OperationCancellation) async throws -> SupportCrashIncident? {
            self.token = token
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func finish() { continuation?.resume(returning:incident); continuation = nil }
    }
    @MainActor static func verifyRecovery(root:URL) async throws {
        let directory = root.appendingPathComponent("DiagnosticReports",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let suite = "TurtleGit.Recovery.Native."+UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        let text = #"{"procName":"TurtleGitMac","bundleInfo":{"CFBundleIdentifier":"org.test.turtle"},"exception":{"type":"EXC_CRASH"},"fixture":"RECOVERY_BODY"}"#
        let file = directory.appendingPathComponent("TurtleGitMac-fixture.ips"); try Data(text.utf8).write(to:file)
        var services:[SupportReportService] = []
        defer { services.forEach { $0.retire() } }
        func service() -> SupportReportService {
            let value = SupportReportService(preferences:prefs,reportsDirectory:directory,processName:"TurtleGitMac",bundleIdentifier:"org.test.turtle")
            value.presentNotice = { $0.window!.alphaValue = 0; $0.window!.orderFront(nil) }
            value.presentReport = { $0.window!.alphaValue = 0; $0.window!.orderFront(nil) }
            services.append(value); return value
        }
        let first = service(); first.checkForPreviousCrash(); first.checkForPreviousCrash()
        try await wait { SupportReportService.activeScans == 0 && first.recoveryNotice != nil }
        try require(first.controller == nil && SupportCrashRecoveryPreferences.handled(in:prefs).isEmpty,"Discovery opened/included/acknowledged a report before a choice")
        var notice = first.recoveryNotice
        weak var releasedNotice = notice
        try await capture(notice!.window!,prefix:"crash-recovery")
        notice!.dismiss(); notice!.review(); notice = nil
        try await wait { first.recoveryNotice == nil && releasedNotice == nil }
        try require(SupportCrashRecoveryPreferences.handled(in:prefs).count == 1 && first.controller == nil,"Dismiss lost receipt or opened report")
        let second = service(); second.checkForPreviousCrash(); try await wait { SupportReportService.activeScans == 0 }
        try require(second.recoveryNotice == nil,"Handled crash prompted again")
        try Data(text.replacingOccurrences(of:"EXC_CRASH",with:"EXC_BAD_ACCESS").utf8).write(to:file)
        let review = service(); review.checkForPreviousCrash(); try await wait { review.recoveryNotice != nil && SupportReportService.activeScans == 0 }
        review.show(); let report = review.controller!
        report.model.picking = true; review.recoveryNotice!.review()
        try require(review.recoveryNotice?.model.notice != nil && SupportCrashRecoveryPreferences.handled(in:prefs).count == 1,"Busy report accepted or acknowledged recovery")
        report.model.picking = false; review.recoveryNotice!.review()
        try require(review.recoveryNotice == nil && report.model.report?.text.contains("RECOVERY_BODY") == true && !report.model.draft.includeCrashReport && !report.model.preview.contains("RECOVERY_BODY"),"Review lost original report or silently included it")
        report.model.field(\.includeCrashReport,context:report.model.context).wrappedValue = true
        try require(report.model.preview.contains("RECOVERY_BODY"),"Explicit recovered inclusion missing")
        report.model.setCrashChecking(false,context:report.model.context)
        let disabled = service(); disabled.checkForPreviousCrash()
        try require(SupportReportService.activeScans == 0 && disabled.recoveryNotice == nil && !SupportCrashRecoveryPreferences.enabled(in:prefs),"Disabled discovery started work")
        report.model.setCrashChecking(true,context:report.model.context)
        let late = service()
        let incident = SupportCrashIncident(report:try SupportCrashReport.read(file),date:Date())
        let held = HeldCrashScan(incident:incident)
        releaseHeld = { held.finish() }
        late.discover = { _,_,_,_,token in try await held.read(token) }
        late.checkForPreviousCrash(); try await wait { held.continuation != nil }
        let count = SupportCrashRecoveryPreferences.handled(in:prefs).count
        late.retire()
        try require(held.token?.isCancelled == true && SupportReportService.activeScans == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Retired discovery lost cancellation/drain ownership")
        held.finish(); releaseHeld = nil
        try await wait { SupportReportService.activeScans == 0 }
        try require(late.recoveryNotice == nil && SupportCrashRecoveryPreferences.handled(in:prefs).count == count,"Retired discovery published/acknowledged")
        print("PASS: local crash discovery, exact identity, handled suppression, Review/Dismiss, busy review retry, explicit inclusion, private preference, cancellation/drain, retired callbacks and released notice")
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), file = root.appendingPathComponent("TurtleGit-fixture.ips"), destination = root.appendingPathComponent("saved-report.txt")
        let body = #"{"bug_type":"309","incident_id":"fixture-only"}"# + "\n" + #"{"procName":"TurtleGitMac","exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},"procPath":"/Users/example/project/TurtleGitMac","fixture":"CRASH_MARKER","threads":[]}"#
        try Data(body.utf8).write(to: file)
        try await verifyRecovery(root:root)
        let bundle = Bundle(url: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app"))!
        let info = ApplicationAboutInformation(application: bundle.bundleURL, version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
        func owner() -> SupportReportWindowController {
            let value = SupportReportWindowController(systemInformation: info.versionText + "\nmacOS: " + ProcessInfo.processInfo.operatingSystemVersionString, home: "/Users/example")
            owners.append(value); value.window!.alphaValue = 0; value.window!.orderFront(nil); return value
        }
        func quitBlocked() -> Bool { TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel }
        var releaseCheck: SupportReportWindowController? = SupportReportWindowController(systemInformation: "Lifecycle fixture")
        weak var released = releaseCheck
        releaseCheck?.close(); releaseCheck = nil
        try await wait { released == nil }
        let controller = owner(), model = controller.model
        let board = NSPasteboard(name: .init("TurtleGit.Support.QA." + UUID().uuidString)); controller.clipboard = board; defer { board.clearContents() }
        var openReply: ((NSApplication.ModalResponse) -> Void)?, saveReply: ((NSApplication.ModalResponse) -> Void)?, openCount = 0, links = [URL]()
        controller.openURL = { links.append($0) }
        controller.presentOpen = { _, own, reply in precondition(own === controller.window); openReply = reply; openCount += 1 }
        controller.presentSave = { _, own, reply in precondition(own === controller.window); saveReply = reply }
        controller.panelURL = { _ in file }
        let initial = model.context, oldField = model.field(\.details, context: initial)
        oldField.wrappedValue = "Commit window closed while reviewing /Users/example/project."
        controller.importReport(context: initial)
        try require(model.picking && SupportReportWindowController.activePickers == 1 && quitBlocked(), "Picker did not own Quit")
        oldField.wrappedValue = "during picker"; controller.importReport(context: initial)
        try require(openCount == 1 && model.draft.details != "during picker", "Picker allowed retained field/action")
        openReply?(.OK); openReply?(.OK)
        try await wait { !model.reading && model.report != nil }
        try require(!model.draft.includeCrashReport && !model.preview.contains("CRASH_MARKER") && model.preview.contains("<HOME>/project"), "Import silently included report or missed home replacement")
        model.field(\.includeCrashReport, context: model.context).wrappedValue = true
        try require(model.preview.contains("CRASH_MARKER") && !model.preview.contains("/Users/example"), "Explicit inclusion did not reach preview")
        controller.copyReport(context: model.context); try require(board.string(forType: .string) == model.preview, "Copy differs from preview")
        controller.issueForm(context: model.context)
        try require(links.count == 1 && links[0].absoluteString == "https://github.com/jfk-solutions/turtle-git-mac/issues/new" && links[0].query == nil, "Issue action disclosed report in URL")
        let descendants = views(controller.window!.contentView!)
        guard let preview = descendants.compactMap({ $0 as? NSTextView }).first(where: { $0.accessibilityLabel() == "Exact problem report" }) else { throw Failure(description: "Native report preview missing") }
        try require(!preview.isEditable && preview.isSelectable, "Report preview not selectable/read-only")
        // Export freezes bytes before the Save sheet even if the model is changed directly.
        let snapshot = Data(model.preview.utf8); controller.panelURL = { _ in destination }; controller.exportReport(context: model.context)
        model.draft.details = "newer draft"; saveReply?(.OK); saveReply?(.OK)
        try await wait { !model.writing && model.notice != nil }
        try require(try Data(contentsOf: destination) == snapshot, "Save lost reviewed snapshot")
        model.field(\.details, context: model.context).wrappedValue = "Commit window closed while reviewing /Users/example/project."
        try await capture(controller.window!)
        model.writeFile = { _, _ in throw Failure(description: "Fixture write failure") }
        controller.exportReport(context: model.context); saveReply?(.OK); try await wait { !model.writing && model.error != nil }
        try require(model.notice == nil && (try Data(contentsOf: destination)) == snapshot, "Write failure lost existing report")
        model.removeReport(context: model.context); try require(model.report == nil && !model.preview.contains("CRASH_MARKER"), "Remove retained report payload")
        // Actual native sheet cancellation uses the private fixture directory.
        controller.presentOpen = { panel, own, reply in panel.directoryURL = root; panel.beginSheetModal(for: own, completionHandler: reply) }
        controller.importReport(context: model.context); try await wait { controller.window!.attachedSheet is NSOpenPanel }
        let panel = controller.window!.attachedSheet!
        try require(panel.sheetParent === controller.window, "Import attached to another window")
        controller.window!.endSheet(panel, returnCode: .cancel); panel.orderOut(nil)
        try await wait { !model.picking && SupportReportWindowController.activePickers == 0 }
        let beforeClose = board.string(forType: .string), stale = model.context; controller.close()
        controller.copyReport(context: stale); controller.issueForm(context: stale); model.field(\.details, context: stale).wrappedValue = "retired"
        try require(board.string(forType: .string) == beforeClose && links.count == 1 && model.draft.details != "retired", "Closed controller dispatched retained actions")
        let late = owner(); var lateReply: ((NSApplication.ModalResponse) -> Void)?
        late.presentOpen = { _, _, answer in lateReply = answer }; late.panelURL = { _ in file }
        late.importReport(context: late.model.context); late.close(); lateReply?(.OK)
        try require(late.model.report == nil && SupportReportWindowController.activePickers == 0, "Closed picker started read")
        let held = owner(), originalPreview = held.model.preview
        var finishRead: CheckedContinuation<SupportCrashReport, Error>?, token: OperationCancellation?
        held.model.readFile = { _, value in token = value; return try await withCheckedThrowingContinuation { finishRead = $0; releaseHeld = { finishRead?.resume(returning: try! SupportCrashReport.read(file)); finishRead = nil } } }
        held.model.load(file, lease: nil); try await wait { finishRead != nil }
        held.close(); try require(token?.isCancelled == true && SupportReportWindowModel.activeReads == 1 && quitBlocked(), "Read closure lost cancellation/count")
        releaseHeld?(); releaseHeld = nil; try await wait { SupportReportWindowModel.activeReads == 0 }
        try require(held.model.preview == originalPreview && held.model.report == nil && held.model.error == nil, "Retired read published")
        let writing = owner(), output = root.appendingPathComponent("accepted-after-close.txt"), acceptedBytes = Data("accepted immutable report".utf8)
        var finishWrite: CheckedContinuation<Void, Never>?
        writing.model.writeFile = { data, url in
            await withCheckedContinuation { finishWrite = $0; releaseHeld = { finishWrite?.resume(); finishWrite = nil } }
            try data.write(to: url, options: .atomic)
        }
        writing.model.save(acceptedBytes, to: output, lease: nil); try await wait { finishWrite != nil }
        writing.close(); try require(SupportReportWindowModel.activeWrites == 1 && quitBlocked(), "Accepted write lost Quit ownership")
        releaseHeld?(); releaseHeld = nil; try await wait { SupportReportWindowModel.activeWrites == 0 }
        try require((try Data(contentsOf: output)) == acceptedBytes && writing.model.notice == nil && writing.model.error == nil, "Accepted write or retired publication differs")

    }
}
