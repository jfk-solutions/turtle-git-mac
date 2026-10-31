// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ScreenCaptureKit
import TurtleGitCore

private final class MergeOpenSourceScopes: RepositoryBookmarkProvider {
    var acquired: [Data] = [], released: [Data] = []
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark { .init(url:FileTransferPaths.fileURL(String(decoding:data,as:UTF8.self)),stale:false) }
    func startAccessing(_ url: URL) -> Bool { acquired.append(Data(url.path.utf8)); return true }
    func stopAccessing(_ url: URL) { released.append(Data(url.path.utf8)) }
}

struct MergeOpenSourceVerification {
    struct Failure: Error { let message: String }
    @MainActor static func require(_ yes: Bool, _ message: String) throws { if !yes { throw Failure(message: message) } }
    @MainActor static func wait(_ yes:()->Bool,line:UInt=#line)async throws {
        for _ in 0..<2000 { if yes() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(message:"Open source timeout at caller line \(line); choices=\(MergeOpenWindowController.activeChoices); transactions=\(MergeEditorOpenWorkflow.activeTransactions); saves=\(MergeEditorOpenWorkflow.activeSaves)")
    }
    @MainActor static func views(_ root: NSView?) -> [NSView] { guard let root else { return [] }; return [root] + root.subviews.flatMap { views($0) } }
    @MainActor static func capture(_ window: NSWindow, into folder: URL) async throws {
        guard #available(macOS 14.4, *) else { throw Failure(message: "Capture requires macOS 14.4") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: name); window.alphaValue = 1; window.orderFront(nil); window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 250_000_000)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let own = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { throw Failure(message: "Capture owner missing") }
            let options = SCStreamConfiguration(); options.width = Int(window.frame.width*2); options.height = Int(window.frame.height*2); options.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: own), configuration: options)
            guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw Failure(message: "Capture PNG missing") }
            try data.write(to: folder.appendingPathComponent("merge-open-source-" + suffix + ".png"))
        }
        window.orderOut(nil); window.alphaValue = 0
    }
    @MainActor static func verify() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("TurtleGitOpenSource-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let base = root.appendingPathComponent("base.txt"), mine = root.appendingPathComponent("mine.txt"), patch = root.appendingPathComponent("changes.patch")
        for (file, text) in [(base, "base\n"), (mine, "mine\n"), (patch, "--- a/base.txt\n+++ b/base.txt\n@@ -1 +1 @@\n-base\n+mine\n")] { try Data(text.utf8).write(to: file) }
        let original = try [base, mine, patch].map { try Data(contentsOf: $0) }
        let suite = "TurtleGit.OpenSource." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        let board = NSPasteboard(name: NSPasteboard.Name("TurtleGit.OpenSource." + UUID().uuidString))
        var owners: [MergeOpenWindowController] = []
        defer { owners.forEach { $0.close() }; board.releaseGlobally(); prefs.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
        func opener() -> MergeOpenWindowController {
            let owner = MergeOpenWindowController(preferences: prefs, pasteboard: board); owner.window?.alphaValue = 0; owners.append(owner); return owner
        }
        let owner = opener(); owner.setMode(.merging); owner.base.stringValue = base.path; owner.mine.stringValue = mine.path
        var reply: ((NSApplication.ModalResponse) -> Void)?, panel: NSOpenPanel?, selected = mine, leaseCalls = 0
        let scopes = MergeOpenSourceScopes()
        weak var latestLease: RepositoryAccessLease?
        owner.presentPicker = { chooser, _, completion in panel = chooser; reply = completion }
        owner.selectedPath = { _ in selected }
        owner.makeLease = { url in
            leaseCalls += 1
            let lease = RepositoryAccessLease(url:url,provider:scopes); latestLease = lease; return lease
        }
        owner.browse(.base)
        try await wait { reply != nil }
        try require(owner.busy && MergeOpenWindowController.activeChoices == 1 && !owner.ok.isEnabled && !owner.apply.isEnabled, "Chooser gates missing")
        try require(panel?.canChooseFiles == true && panel?.canChooseDirectories == false && panel?.allowsMultipleSelection == false && panel?.directoryURL?.path == root.path, "Source file chooser settings/seed differ")
        owner.browse(.mine); owner.accept(); owner.setMode(.applyUnifiedDiff)
        try require(owner.mode == .merging && MergeOpenWindowController.activeChoices == 1, "Competing request accepted")
        // An externally edited form invalidates the pending response; duplicate callbacks drain only once.
        owner.mine.stringValue = base.path; reply?(.OK); reply?(.OK)
        try await wait { !owner.busy && MergeOpenWindowController.activeChoices == 0 }
        try require(owner.base.stringValue == base.path && leaseCalls == 0 && scopes.acquired.isEmpty, "Changed form consumed an obsolete choice")
        owner.mine.stringValue = mine.path; reply = nil; owner.browse(.base); try await wait { reply != nil }
        selected = root; reply?(.OK); try await wait { !owner.busy }
        try require(leaseCalls == 1 && scopes.acquired == [Data(root.path.utf8)] && scopes.released == scopes.acquired && latestLease == nil && owner.base.stringValue == base.path && owner.status.stringValue == "Select an existing regular file.", "Wrong-type file selection was accepted, changed its field or retained its temporary grant")
        reply = nil; owner.browse(.base); try await wait { reply != nil }; selected = mine; reply?(.OK)
        try await wait { !owner.busy }; try require(owner.base.stringValue == mine.path && leaseCalls == 2 && scopes.released.count == 1 && latestLease != nil && owner.status.stringValue.isEmpty, "Valid file did not replace captured slot and retain only its own grant")
        weak var acceptedLease = latestLease
        owner.setMode(.applyUnifiedDiff); owner.directory.stringValue = root.path
        reply = nil; owner.browse(.directory); try await wait { reply != nil }
        try require(panel?.canChooseDirectories == true && panel?.canChooseFiles == false && panel?.directoryURL?.path == root.path, "Directory picker settings/seed differ")
        selected = mine; reply?(.OK); try await wait { !owner.busy }
        try require(owner.directory.stringValue == root.path && leaseCalls == 3 && scopes.released.count == 2 && latestLease == nil && acceptedLease != nil && owner.status.stringValue == "Select an existing directory.", "Wrong-type directory selection was accepted or retained, or discarded the earlier valid grant")
        owner.diff.stringValue = patch.path; reply = nil; owner.browse(.diff); try await wait { reply != nil }
        try require(panel?.allowsOtherFileTypes == true && panel?.allowedContentTypes.isEmpty == false, "Source patch/all-files filter absent")
        reply?(.cancel); try await wait { !owner.busy }
        try require(owner.diff.stringValue == patch.path && leaseCalls == 3 && scopes.acquired.count == 3 && scopes.released.count == 2 && acceptedLease != nil, "Cancel changed input or acquired/released an unrelated grant")
        let retired = opener(); retired.setMode(.merging)
        var held: CheckedContinuation<URL?, Never>?
        var retiredLeaseCalls = 0
        retired.makeLease = { url in retiredLeaseCalls += 1; return RepositoryAccessLease(url:url,provider:scopes) }
        retired.choosePath = { _, _ in await withCheckedContinuation { held = $0 } }
        retired.browse(.base); try await wait { held != nil }; retired.close()
        try require(MergeOpenWindowController.activeChoices == 1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Forced-close picker lost independent Quit lifetime")
        held?.resume(returning: base); held = nil; try await wait { MergeOpenWindowController.activeChoices == 0 }
        try require(retired.base.stringValue.isEmpty && !retired.ok.isEnabled && retiredLeaseCalls == 0 && scopes.acquired.count == 3, "Retired picker republished a result or acquired a late grant")
        let submission = opener(); submission.setMode(.merging); submission.base.stringValue = base.path; submission.mine.stringValue = mine.path
        var attempts = 0
        submission.onAccepted = { _, _ in attempts += 1; submission.accept(); throw Failure(message: "expected preparation failure") }
        submission.accept(); try require(attempts == 1 && submission.ok.isEnabled && !submission.status.stringValue.isEmpty, "Failed/reentrant submission did not preserve retry")
        submission.onAccepted = { _, _ in attempts += 1; submission.accept(); submission.setMode(.applyUnifiedDiff) }
        submission.accept(); submission.accept()
        try require(attempts == 2 && prefs.integer(forKey: "TurtleGitMerge.OpenRadio") == 0 && !submission.ok.isEnabled, "Successful submission duplicated or saved a changed mode")
        owner.setMode(.merging); owner.base.stringValue = base.path; owner.mine.stringValue = mine.path; owner.status.stringValue = ""
        let all = views(owner.window?.contentView)
        try require(Set(all.compactMap { ($0 as? NSBox)?.title }) == Set(["Merging", "Apply unified diff"]), "Source groups absent")
        try require(all.compactMap { $0 as? NSButton }.filter { $0.title == "Browse…" }.count == 5, "Source Browse slots missing")
        if let path = ProcessInfo.processInfo.environment["TURTLEGIT_MERGE_OPEN_CAPTURE"], let window = owner.window { try await capture(window, into: URL(fileURLWithPath: path)) }
        try require(try [base, mine, patch].map { try Data(contentsOf: $0) } == original, "Open controls changed input bytes")
        owners.forEach { $0.close() }; try await wait { MergeOpenWindowController.activeChoices == 0 }
        let physicalScopes=try await physicalSheetChoices(root:root,base:base,mine:mine,preferences:prefs,board:board)
        try await wait{physicalScopes.released==physicalScopes.acquired}
        print("PASS Merge Open source: configured native panels, captured form/slot, grant-before-metadata with wrong-type release, Cancel/duplicate/retired replies without extra grants, independent Quit drain, reentrant retry/success and unchanged input bytes")
    }
}

extension MergeOpenSourceVerification {
    @MainActor private static func physicalSheetChoices(root:URL,base:URL,mine:URL,preferences:UserDefaults,board:NSPasteboard)async throws->MergeOpenSourceScopes {
        let parent=NSWindow(contentRect:.init(x:-14000,y:-14000,width:700,height:500),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        parent.isReleasedWhenClosed=false;parent.alphaValue=0;parent.orderFront(nil)
        let scopes=MergeOpenSourceScopes()
        var owned=[MergeOpenWindowController](),held:CheckedContinuation<URL?,Never>?,panel:NSOpenPanel?,reply:((NSApplication.ModalResponse)->Void)?
        func clean()async throws {
            reply?(.cancel);held?.resume(returning:nil);held=nil
            for owner in owned {if let child=owner.window?.attachedSheet {owner.window?.endSheet(child,returnCode:.cancel);child.orderOut(nil)};owner.close()}
            if let child=parent.attachedSheet {parent.endSheet(child,returnCode:.cancel);child.orderOut(nil)}
            parent.close()
            try await wait{owned.allSatisfy{!$0.hasPendingWork} && MergeOpenWindowController.activeChoices==0}
            owned=[];panel=nil;reply=nil
        }
        do {
            print("Merge Open source phase: real nested Browse early response and Open detach");fflush(stdout)
            let owner=MergeOpenWindowController(preferences:preferences,pasteboard:board)
            owned.append(owner);owner.window?.alphaValue=0;owner.requiresScopes=true
            owner.setMode(.merging);owner.base.stringValue=base.path;owner.mine.stringValue=mine.path
            var leaseCalls=0,accepted=0,endRequests=0,closed=0,acceptedLeases=[RepositoryAccessLease]()
            weak var witness:RepositoryAccessLease?
            owner.makeLease={url in leaseCalls+=1;let lease=RepositoryAccessLease(url:url,provider:scopes);witness=lease;return lease}
            owner.selectedPath={_ in mine}
            owner.presentPicker={chooser,window,completion in
                panel=chooser;reply=completion;chooser.alphaValue=0;chooser.setFrameOrigin(.init(x:-14000,y:-14000))
                window.beginSheet(chooser,completionHandler:{_ in})
            }
            owner.onClosed={closed+=1};owner.present(parent:parent)
            owner.browse(.base);try await wait{panel?.sheetParent === owner.window && reply != nil}
            let nativePanel=panel!,openSheet=owner.window!
            try require(nativePanel.alphaValue==0 && openSheet.alphaValue==0,"Hidden sheet ownership exposed native UI")
            reply?(.OK);reply?(.cancel);reply?(.OK)
            try await wait{leaseCalls==1}
            try require(owner.busy && owner.pendingChoices==1 && owner.hasPendingWork && !owner.ok.isEnabled && nativePanel.sheetParent === openSheet && owner.base.stringValue==base.path && witness != nil,"Early picker callback released form/authority before actual detach")
            owner.accept();owner.browse(.mine);owner.setMode(.applyUnifiedDiff)
            try require(leaseCalls==1 && owner.mode == .merging && MergeOpenWindowController.activeChoices==1,"Duplicate or competing nested request escaped native sheet")
            openSheet.endSheet(nativePanel);nativePanel.orderOut(nil)
            try await wait{!owner.busy && owner.pendingChoices==0 && nativePanel.sheetParent==nil && openSheet.attachedSheet==nil}
            try require(owner.base.stringValue==mine.path && leaseCalls==1 && witness != nil,"Detached picker did not publish exactly its captured slot and lease")
            // Authorize the other path through the same selected grant; both
            // selected slots now name mine, and captured mode remains Merging.
            owner.onAccepted={request,permissions in
                accepted+=1;acceptedLeases=permissions
                try require(parent.attachedSheet==nil && openSheet.sheetParent==nil,"onAccepted ran before real Open detachment")
                guard case .compare(let left,let right,let single)=request else {throw Failure(message:"Native detached acceptance changed mode")}
                try require(left==mine && right==mine && !single && permissions.count==1 && permissions[0].permits(mine),"Native acceptance lost captured paths or selected grant")
                owner.setMode(.applyUnifiedDiff);owner.accept()
            }
            owner.presentAcceptedSheetEnd={window,sheet in endRequests+=1;if window !== parent || sheet !== openSheet {accepted = -100}}
            preferences.set(1,forKey:"TurtleGitMerge.OpenRadio")
            owner.accept();owner.accept()
            try require(accepted==0 && endRequests==1 && owner.hasPendingWork && parent.attachedSheet === openSheet,"Open callback ran/reentered before held physical release")
            parent.endSheet(openSheet);openSheet.orderOut(nil)
            try await wait{accepted==1 && closed==1 && !owner.hasPendingWork && parent.attachedSheet==nil && openSheet.sheetParent==nil}
            try require(acceptedLeases.count==1 && leaseCalls==1 && preferences.integer(forKey:"TurtleGitMerge.OpenRadio")==0,"Captured mode/grants weren't retained through detached acceptance")
            acceptedLeases=[]

            print("Merge Open source phase: forced parent close with held nested worker");fflush(stdout)
            let pending=MergeOpenWindowController(preferences:preferences,pasteboard:board)
            owned.append(pending);pending.window?.alphaValue=0;pending.setMode(.merging)
            var pendingClosed=0,lateLeases=0,lateAccepts=0
            pending.onClosed={pendingClosed+=1};pending.onAccepted={_,_ in lateAccepts+=1}
            pending.makeLease={url in lateLeases+=1;return RepositoryAccessLease(url:url,provider:scopes)}
            pending.choosePath={_,_ in await withCheckedContinuation{held=$0}}
            pending.present(parent:parent);pending.browse(.mine);try await wait{held != nil}
            parent.close()
            try require(pendingClosed==0 && pending.hasPendingWork && pending.pendingChoices==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Forced parent close abandoned held nested worker/Quit ownership")
            held?.resume(returning:mine);held=nil
            try await wait{pendingClosed==1 && !pending.hasPendingWork && MergeOpenWindowController.activeChoices==0}
            try require(pending.mine.stringValue.isEmpty && lateLeases==0 && lateAccepts==0,"Retired nested worker acquired authority or republished a late result")
            try await clean();return scopes
        } catch {let original=error;do {try await clean()} catch {throw Failure(message:"Original failure: \(original); cleanup: \(error)")};throw original}
    }
}
