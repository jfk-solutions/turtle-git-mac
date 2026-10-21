import AppKit
import PDFKit
import ScreenCaptureKit
import TurtleGitCore

private actor StatisticsWriteGate {
    var bytes: Data?
    var release: CheckedContinuation<Void, Never>?
    func write(_ data: Data, to url: URL,cancellation:OperationCancellation) async throws {
        bytes = data
        await withCheckedContinuation { release = $0 }
        try cancellation.check()
        try await StatisticsGraphExport.write(data:data,to:url,cancellation:cancellation)
    }
    func finish() { release?.resume(); release = nil }
    var started: Bool { bytes != nil }
}

extension StatisticsNativeVerification {
    @MainActor static func sourceWait(_ ready: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<2500 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw NSError(domain: "Statistics source wait", code: line)
    }
    @MainActor static func sourceViews(_ root:NSView?)->[NSView] {
        guard let root else{return []};return [root]+root.subviews.flatMap{sourceViews($0)}
    }
    @MainActor static func sourceCapture(_ owner: StatisticsWindowController, page: String) async throws {
        guard let output = ProcessInfo.processInfo.environment["TURTLEGIT_STATISTICS_SOURCE_CAPTURE"], let window = owner.window else { return }
        if #available(macOS 14.4, *) {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
                window.appearance = NSAppearance(named: appearance); window.alphaValue = 1; window.orderFront(nil)
                window.contentView?.layoutSubtreeIfNeeded()
                if page == "bar" {
                    try await sourceWait {
                        window.contentView?.layoutSubtreeIfNeeded()
                        guard let native=sourceViews(window.contentView).compactMap({$0 as? StatisticsVectorNativeView}).first,
                              let drawing=native.drawing,native.bounds.width>100,native.bounds.height>100,
                              abs(drawing.scene.size.width-native.bounds.width)<1,abs(drawing.scene.size.height-native.bounds.height)<1,
                              drawing.plotBounds.width>0,!drawing.accessibilityLabels.isEmpty,
                              let first=drawing.scene.commands.first else{return false}
                        if case .fill(_,let color,_)=first {return abs(color.red-(suffix == "dark" ? 32.0/255:1))<0.001}
                        return false
                    }
                }
                window.displayIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw NSError(domain: "Statistics owned capture", code: 1) }
                let config = SCStreamConfiguration(); config.width = Int(window.frame.width * 2); config.height = Int(window.frame.height * 2)
                config.includeChildWindows = false; config.showsCursor = false
                let pixels = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: config)
                let png = NSBitmapImageRep(cgImage: pixels).representation(using: .png, properties: [:])!
                try png.write(to: directory.appendingPathComponent("statistics-" + page + "-source-" + suffix + ".png"))
            }
            window.alphaValue = 0
        } else { throw NSError(domain: "Statistics capture requires macOS 14.4", code: 1) }
    }
    @MainActor static func verifySourceFamily(_ owner: StatisticsWindowController, root: URL, defaults: UserDefaults) async throws {
        let model = owner.model
        model.selectMetric(.commitsByDate)
        let old = model.formRevision
        model.selectStyle(.bar, context: old)
        model.selectMetric(.statistics, context: old)
        var changed = model.options; changed.caseSensitive.toggle()
        model.setOptions(changed, context: old); model.setAuthorLimit(1, context: old)
        precondition(model.metric == .commitsByDate && model.style == .bar && model.options != changed, "Old form controls survived a new presentation")
        model.setAuthorLimit(Double.greatestFiniteMagnitude)
        precondition(model.authorsShown == Double(max(1, min(250, model.availableAuthorCount))))
        let authors = model.authorsShown
        model.setAuthorLimit(.infinity); model.setAuthorLimit(.nan)
        precondition(model.authorsShown == authors)
        precondition(model.authorSliderHint.contains("most active author(s)"))
        model.selectMetric(.commitsByAuthor); model.selectStyle(.line)
        precondition(model.style == .bar)
        model.selectMetric(.statistics)
        owner.window?.setContentSize(NSSize(width: 780, height: 550)); owner.window?.alphaValue = 0; owner.window?.orderFront(nil)
        try await sourceWait { (owner.window?.contentView?.bounds.width ?? 0) >= 780 }
        try await sourceCapture(owner, page: "summary")
        model.selectMetric(.commitsByDate); model.selectStyle(.bar)
        try await sourceCapture(owner, page: "bar")

        // Freeze the original viewport/theme while a native file picker is pending.
        let saving = StatisticsWindowController(repository: model.repository, access: nil, entries: model.entries, defaults: defaults)
        defer { saving.close() }
        saving.model.selectMetric(.commitsByDate); saving.model.selectStyle(.pie)
        saving.model.graphSize = CGSize(width: 480, height: 280)
        saving.window?.appearance = NSAppearance(named: .aqua)
        let target = root.appendingPathComponent("captured-statistics.pdf")
        let sentinel=Data("existing statistics output".utf8);try sentinel.write(to:target)
        saving.selectedSaveURL = { _ in target }
        var reply: ((NSApplication.ModalResponse) -> Void)?
        var panels = 0
        saving.presentSavePanel = { _, _, completion in panels += 1; reply = completion }
        saving.saveGraphAs(); saving.saveGraphAs(); precondition(panels == 1)
        let stale = reply
        reply?(.cancel)
        try await sourceWait{!saving.model.hasSheet}
        // Cancellation now drains asynchronously; establish the second viewport
        // after that wait, before capturing its new Save intent.
        saving.model.graphSize=CGSize(width:480,height:280)
        saving.saveGraphAs(); stale?(.OK)
        precondition(saving.savePanel != nil && StatisticsWindowController.activeExports == 0)
        saving.model.graphSize = CGSize(width: 900, height: 500)
        saving.window?.appearance = NSAppearance(named: .darkAqua)
        let gate = StatisticsWriteGate()
        saving.writeGraph = {data,url,token in try await gate.write(data,to:url,cancellation:token)}
        let accepted = reply
        accepted?(.OK); accepted?(.OK)
        for _ in 0..<2500 { if await gate.started { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let beganWriting = await gate.started
        precondition(beganWriting)
        precondition(saving.model.exporting && StatisticsWindowController.activeExports == 1 && !saving.canSaveGraph)
        let style = saving.model.style; saving.model.selectStyle(.bar); precondition(saving.model.style == style)
        precondition(!saving.windowShouldClose(saving.window!) && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel)
        saving.close()
        precondition(saving.model.retired && StatisticsWindowController.activeExports == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel)
        await gate.finish()
        try await sourceWait { StatisticsWindowController.activeExports == 0 }
        let capturedBytes=await gate.bytes
        guard let capturedBytes,let pdf=PDFDocument(data:capturedBytes),pdf.pageCount==1 else {throw NSError(domain:"Captured Statistics PDF",code:1)}
        precondition(pdf.page(at:0)?.bounds(for:.mediaBox).size==CGSize(width:480,height:280),"Save used the changed viewport instead of captured graph")
        let retainedOutput=try Data(contentsOf:target)
        precondition(retainedOutput==sentinel,"Cancelled Statistics writer replaced the existing output")
        precondition(!saving.model.exporting && !saving.model.hasSheet)

        let failing = StatisticsWindowController(repository: model.repository, access: nil, entries: model.entries, defaults: defaults)
        failing.window?.alphaValue = 0; failing.window?.orderFront(nil)
        failing.model.selectMetric(.commitsByDate)
        failing.presentSavePanel = { _, _, completion in reply = completion }
        failing.selectedSaveURL = { _ in root.appendingPathComponent("missing/graph.pdf") }
        failing.saveGraphAs(); reply?(.OK)
        try await sourceWait { !failing.model.exporting && failing.model.hasSheet && failing.window?.attachedSheet != nil }
        precondition(StatisticsWindowController.activeExports == 0 && failing.window?.attachedSheet != nil && !failing.canSaveGraph)
        failing.close()
        try await sourceWait{!failing.hasPendingWork && failing.window?.attachedSheet==nil && !failing.model.hasSheet}

        let staleOwner = StatisticsWindowController(repository: model.repository, access: nil, entries: model.entries, defaults: defaults)
        defer { staleOwner.close() }
        staleOwner.model.selectMetric(.commitsByDate)
        staleOwner.presentSavePanel = { _, _, completion in reply = completion }
        let staleFile = root.appendingPathComponent("stale-statistics.pdf")
        staleOwner.selectedSaveURL = { _ in staleFile }
        staleOwner.saveGraphAs(); staleOwner.model.rebuild(); reply?(.OK)
        try await sourceWait{!staleOwner.model.hasSheet}
        precondition(!FileManager.default.fileExists(atPath: staleFile.path) && StatisticsWindowController.activeExports == 0)
        var keyWindow = owner.window
        let menu = StatisticsMenuContext(keyWindow: { keyWindow })
        var ownerPickers = 0
        owner.presentSavePanel = { _, _, completion in ownerPickers += 1; reply = completion }
        let capturedCommand = menu.capturedSaveAction()
        keyWindow = staleOwner.window; menu.refresh()
        capturedCommand()
        precondition(ownerPickers == 1 && owner.model.hasSheet && !staleOwner.model.hasSheet, "File menu followed a different key window")
        reply?(.cancel)
        try await sourceWait{!owner.model.hasSheet}
        keyWindow = owner.window; menu.refresh()
        let staleCommand = menu.capturedSaveAction()
        owner.model.selectStyle(.pie); staleCommand()
        precondition(ownerPickers == 1 && !owner.model.hasSheet, "File menu reused an obsolete graph presentation")

        // Exercise a real owned native Save panel and cancel it without a user action.
        staleOwner.presentSavePanel = { panel, window, completion in panel.beginSheetModal(for: window, completionHandler: completion) }
        staleOwner.window?.alphaValue = 0; staleOwner.window?.orderFront(nil); staleOwner.saveGraphAs()
        try await sourceWait { staleOwner.window?.attachedSheet != nil }
        if let sheet = staleOwner.window?.attachedSheet { staleOwner.window?.endSheet(sheet, returnCode: .cancel) }
        try await sourceWait { !staleOwner.model.hasSheet }
        precondition(StatisticsWindowController.activeExports == 0)
        var automatic: StatisticsWindowController? = StatisticsWindowController(repository: model.repository, access: nil, entries: model.entries, defaults: defaults)
        weak var released = automatic
        automatic!.model.selectMetric(.commitsByDate)
        automatic!.selectedSaveURL = { _ in root.appendingPathComponent("automatic-close.pdf") }
        automatic!.presentSavePanel = { _, _, completion in reply = completion }
        let normalGate = StatisticsWriteGate()
        automatic!.writeGraph = {data,url,token in try await normalGate.write(data,to:url,cancellation:token)}
        var normalClosed = false; automatic!.onClosed = { normalClosed = true }
        automatic!.saveGraphAs(); reply?(.OK)
        for _ in 0..<2500 { if await normalGate.started { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        automatic!.window?.performClose(nil)
        precondition(!normalClosed && StatisticsWindowController.activeExports == 1)
        await normalGate.finish()
        try await sourceWait { normalClosed && StatisticsWindowController.activeExports == 0 }
        automatic = nil
        try await sourceWait { released == nil }
        precondition(!FileManager.default.fileExists(atPath:root.appendingPathComponent("automatic-close.pdf").path),"Normal close failed to cancel unpublished output")
        print("Statistics source family: stale form and picker callbacks, style dependencies, bounded slider, activity hint, source summary/bar geometry, captured export, actual owned picker Cancel, duplicate reply, cancel-before-publication force-close/Quit ownership passed")
    }
    static func XCTlessPDF(_ url: URL) throws -> PDFDocument {
        guard let pdf = PDFDocument(url: url), pdf.pageCount == 1 else { throw NSError(domain: "Statistics PDF", code: 1) }
        return pdf
    }
}
