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
        try await verifyCutoffFamily(repository:owner.model.repository,root:root)
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
    @MainActor static func sourceAX(_ object:Any,_ name:String)->Any? {
        guard let value=object as? NSObject else{return nil}
        let selector=NSSelectorFromString(name)
        return value.responds(to:selector) ? value.perform(selector)?.takeUnretainedValue():nil
    }
    @MainActor static func sourceAXTree(_ root:Any)->[NSObject] {
        var seen=Set<ObjectIdentifier>(),result:[NSObject]=[]
        func visit(_ object:Any,_ depth:Int) {
            guard depth<24,result.count<2000,let value=object as? NSObject,seen.insert(ObjectIdentifier(value)).inserted else{return}
            result.append(value)
            for child in NSAccessibility.unignoredChildren(from:sourceAX(value,"accessibilityChildren") as? [Any] ?? []) {visit(child,depth+1)}
        }
        for child in NSAccessibility.unignoredChildrenForOnlyChild(from:root) {visit(child,0)}
        return result
    }
    @MainActor static func sourceAXEnabled(_ element:NSObject)->(value:Bool?,route:String) {
        let selector=NSSelectorFromString("isAccessibilityEnabled")
        if element.responds(to:selector) {
            typealias Callback = @convention(c)(AnyObject,Selector)->Bool
            let enabled=unsafeBitCast(element.method(for:selector),to:Callback.self)(element,selector)
            return (enabled,"protocol isAccessibilityEnabled")
        }
        let attribute=NSAccessibility.Attribute(rawValue:"AXEnabled")
        guard element.accessibilityAttributeNames().contains(attribute) else{return (nil,"no enabled interface")}
        return ((element.accessibilityAttributeValue(attribute) as? NSNumber)?.boolValue,"advertised AXEnabled")
    }
    @MainActor static func sourceAXIncrement(_ element:NSObject)->(delivered:Bool,diagnostic:String) {
        let selector=NSSelectorFromString("accessibilityPerformIncrement")
        let action=NSAccessibility.Action(rawValue:"AXIncrement")
        let names=element.accessibilityActionNames()
        let enabled=sourceAXEnabled(element)
        let diagnostic="node=\(type(of:element)), modern=\(element.responds(to:selector)), actions=\(names.map(\.rawValue)), enabled=\(String(describing:enabled))"
        // SwiftUI lightweight AX nodes can expose the named NSObject action
        // interface rather than the newer optional protocol selector. Dispatch
        // one actual advertised action; a rejected modern action stays rejected.
        guard element.responds(to:selector) else {
            guard names.contains(action) else{return (false,diagnostic+", route=none")}
            element.accessibilityPerformAction(action)
            return (true,diagnostic+", route=named AXIncrement")
        }
        typealias Callback = @convention(c)(AnyObject,Selector)->Bool
        return (unsafeBitCast(element.method(for:selector),to:Callback.self)(element,selector),diagnostic+", route=protocol increment")
    }
    @MainActor static func verifyCutoffFamily(repository:GitRepository,root:URL)async throws {
        func require(_ value:Bool,_ message:String)throws {if !value {throw NSError(domain:"Statistics cutoff: "+message,code:1)}}
        // SwiftUI materializes lightweight AX nodes only when a client requests
        // its enhanced tree. This changes this private process, not system prefs.
        let enhancedUI=NSAccessibility.Attribute(rawValue:"AXEnhancedUserInterface")
        try require(NSApp.accessibilityIsAttributeSettable(enhancedUI),"Private AX client mode unavailable")
        let originalAX=NSApp.accessibilityAttributeValue(enhancedUI)
        NSApp.accessibilitySetValue(NSNumber(value:true),forAttribute:enhancedUI)
        defer{NSApp.accessibilitySetValue(originalAX,forAttribute:enhancedUI)}
        let suite="TurtleGit.Statistics.Cutoff."+UUID().uuidString,preferences=UserDefaults(suiteName:suite)!
        defer{preferences.removePersistentDomain(forName:suite)}
        preferences.set(false,forKey:"UseSystemLocaleForDates");try AppLanguageChoice.save("ja",to:preferences)
        var entries:[LogEntry]=[]
        for author in 0..<4 {for copy in 0...author {
            entries.append(LogEntry(hash:"cutoff-\(author)-\(copy)",author:"Author\(author)",date:"2024-01-02T12:00:00Z",subject:"",committerDate:"2024-01-02T12:00:00Z"))
        }}
        let owner=StatisticsWindowController(repository:repository,access:nil,entries:entries,defaults:preferences),model=owner.model
        let gate=StatisticsWriteGate()
        do {
            owner.window?.alphaValue=0;owner.window?.setFrameOrigin(.init(x:-24000,y:-24000));owner.showWindow(nil)
            model.selectMetric(.commitsByAuthor)
            func slider()->NSObject? {
                sourceAXTree(owner.window!).first{sourceAX($0,"accessibilityRole") as? String == "AXSlider" && sourceAX($0,"accessibilityLabel") as? String == "Authors shown individually"}
            }
            do {try await sourceWait {slider() != nil}} catch {
                let state="metric=\(model.metric) authors=\(model.authorsShown) available=\(model.availableAuthorCount) interact=\(model.canInteract) busy=\(model.busy) visible=\(owner.window?.isVisible == true)"
                let native=sourceViews(owner.window?.contentView).map{String(describing:type(of:$0))}
                let roles=sourceAXTree(owner.window!).map{String(describing:type(of:$0))+":"+String(reflecting:sourceAX($0,"accessibilityRole"))+":"+String(reflecting:sourceAX($0,"accessibilityLabel"))}
                throw NSError(domain:"Statistics actual AX slider missing: "+state+" native=\(native) AX=\(roles)",code:1)
            }
            try require(model.availableAuthorCount==4 && model.authorsShown==4,"Source author maximum not restored")
            let original=model.graph!.includedAuthors
            let token=model.beginAuthorLimitGesture(context:model.formRevision)!
            model.updateAuthorLimitGesture(1,gesture:token)
            try require(model.displayedAuthorLimit==1 && model.authorsShown==4 && model.graph!.includedAuthors==original,"Thumb tracking redrew committed graph")
            model.finishAuthorLimitGesture(token)
            try require(model.authorLimitDraft==nil && model.authorsShown==1 && model.graph!.includedAuthors.count==1 && model.graph!.skippedAuthors.count==3,"Release did not publish cutoff once")
            let released=model.formRevision;model.finishAuthorLimitGesture(token)
            try require(model.formRevision==released,"Duplicate slider release redrew graph")
            // Invoke the actual rendered SwiftUI AX slider, rather than assuming
            // that this SDK implements it as an NSSlider subclass. Thumb tracking
            // uses the captured production begin/update/end contract above.
            do {try await sourceWait {
                    owner.window?.contentView?.layoutSubtreeIfNeeded()
                    guard model.canInteract,model.authorLimitDraft==nil,let current=slider(),
                          (sourceAX(current,"accessibilityValue") as? NSNumber)?.intValue==1 else{return false}
                    return sourceAXEnabled(current).value==true
                }
            } catch {
                let current=slider()
                let enabled=current.map{sourceAXEnabled($0)}
                let value=current.flatMap{sourceAX($0,"accessibilityValue")}
                throw NSError(domain:"Statistics cutoff AX admission: authors=\(model.authorsShown), draft=\(String(describing:model.authorLimitDraft)), interact=\(model.canInteract), enabled=\(String(describing:enabled)), value=\(String(describing:value))",code:1)
            }
            guard let actual=slider() else{throw NSError(domain:"Statistics AX slider retired before action",code:1)}
            let action=sourceAXIncrement(actual)
            try require(action.delivered,"Actual AX slider increment was not delivered: "+action.diagnostic+", authors=\(model.authorsShown), canInteract=\(model.canInteract)")
            try await sourceWait {model.authorsShown==2 && model.authorLimitDraft==nil && (slider().flatMap{sourceAX($0,"accessibilityValue") as? NSNumber})?.intValue==2}
            print("Statistics actual AX slider action: "+action.diagnostic+"; committed authors=2, no draft")
            model.selectStyle(.pie)
            try require(model.authorsShown==4 && model.graph!.includedAuthors.count==4,"Style redraw retained reduced author cutoff")
            model.setAuthorLimit(1);model.selectStyle(.pie)
            try require(model.authorsShown==4,"Selecting current style failed source reset")
            for transition in 0..<5 {
                let stale=model.beginAuthorLimitGesture(context:model.formRevision)!
                model.updateAuthorLimitGesture(1,gesture:stale)
                if transition==0 {model.selectMetric(.commitsByDate)}
                else if transition==1 {model.selectStyle(.stackedLine)}
                else if transition==2 {var options=model.options;options.sortByCommitCount.toggle();model.setOptions(options)}
                else if transition==3 {model.rebuild(resetAuthors:true)}
                else {model.hasSheet=true;model.hasSheet=false}
                let revision=model.formRevision,authors=model.authorsShown
                model.updateAuthorLimitGesture(2,gesture:stale);model.finishAuthorLimitGesture(stale)
                try require(model.authorLimitDraft==nil && model.formRevision==revision && model.authorsShown==authors,"Old gesture affected replacement chart/owner: \(transition)")
            }
            try require(model.style == .stackedLine && model.authorsShown==4,"Date line style did not restore maximum")
            try require(model.dateSettings.order == .yearMonthDay && model.graph!.categoryLabels.allSatisfy{$0.hasPrefix("24/")},"Owning app-language date preference did not reach graph")
            let labels=model.graph!.categoryLabels,dateSettings=model.dateSettings
            try AppLanguageChoice.save("de",to:preferences);model.rebuild()
            try require(model.dateSettings==dateSettings && model.graph!.categoryLabels==labels,"External preference change replaced captured graph date context")
            model.setAuthorLimit(1);model.graphSize=CGSize(width:480,height:280)
            let captured=model.graph!,destination=root.appendingPathComponent("captured-cutoff-preferences.pdf")
            var answer:((NSApplication.ModalResponse)->Void)?
            owner.presentSavePanel={_,_,reply in answer=reply};owner.selectedSaveURL={_ in destination}
            owner.writeGraph={data,url,token in try await gate.write(data,to:url,cancellation:token)}
            let stale=model.beginAuthorLimitGesture(context:model.formRevision)!
            model.updateAuthorLimitGesture(2,gesture:stale);owner.saveGraphAs()
            model.finishAuthorLimitGesture(stale);model.selectStyle(.bar)
            try require(model.authorLimitDraft==nil && model.authorsShown==1 && model.style == .stackedLine,"Save ownership committed a pending thumb or changed style")
            answer?(.OK)
            for _ in 0..<2500 {if await gate.started {break};try await Task.sleep(nanoseconds:10_000_000)}
            guard let data=await gate.bytes,let pdf=PDFDocument(data:data) else{throw NSError(domain:"Statistics captured cutoff export not received",code:1)}
            let text=pdf.string ?? ""
            try require(captured.skippedAuthors.count==3 && captured.categoryLabels.allSatisfy{text.contains($0)} && text.contains("Others (3)"),"Export lost committed author cutoff/date captions")
            await gate.finish();try await sourceWait{!owner.hasPendingWork && !model.exporting}
            try require(try Data(contentsOf:destination)==data,"Captured export bytes changed during publication")
            model.savePreferences()
            let reopened=StatisticsWindowModel(repository:repository,access:nil,entries:entries,defaults:preferences)
            try require(reopened.style == .stackedLine && reopened.metric == .commitsByDate && reopened.options==model.options && reopened.dateSettings.order == .dayMonthYear,"Persisted style/options or newly opened language preference lost")
            reopened.retire()
            let retired=model.beginAuthorLimitGesture(context:model.formRevision)!
            model.updateAuthorLimitGesture(2,gesture:retired);owner.close();model.finishAuthorLimitGesture(retired)
            try await sourceWait{!owner.hasPendingWork}
            try require(model.retired && model.authorLimitDraft==nil && model.authorsShown==1,"Retired slider callback changed chart")
            print("PASS: Statistics cutoff draft/release/duplicate, actual SwiftUI AX immediate action, same/new style maximum, stale metric/style/options/snapshot/sheet/retired gesture refusal, captured date preference and PDF receipt, fresh preference reopening")
        } catch {
            await gate.finish();owner.close();try? await sourceWait{!owner.hasPendingWork};throw error
        }
    }
    static func XCTlessPDF(_ url: URL) throws -> PDFDocument {
        guard let pdf = PDFDocument(url: url), pdf.pageCount == 1 else { throw NSError(domain: "Statistics PDF", code: 1) }
        return pdf
    }
}
