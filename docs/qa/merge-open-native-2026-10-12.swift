import AppKit
import ObjectiveC
import TurtleGitCore

private struct MergeOpenCheckFailure: Error { let line: Int }
private final class MergeOpenPrivateBookmarks: RepositoryBookmarkProvider {
    var starts: [URL] = []
    var stops: [URL] = []
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark { .init(url: FileTransferPaths.fileURL(String(decoding:data,as:UTF8.self)), stale:false) }
    func startAccessing(_ url: URL) -> Bool { starts.append(url); return true }
    func stopAccessing(_ url: URL) { stops.append(url) }
}
struct MergeOpenNativeVerification {
    // Swift 6.4 crashes while generating the optional throwing ObjC-protocol
    // bridge. Invoke the same public AppKit validation selector directly.
    @MainActor private static func validation(_ panel: NSOpenPanel, _ url: URL) throws -> (Bool, NSError?) {
        guard let delegate = panel.delegate, let type = object_getClass(delegate as AnyObject),
              let method = class_getInstanceMethod(type, NSSelectorFromString("panel:validateURL:error:")) else { throw MergeOpenCheckFailure(line:#line) }
        typealias Validate = @convention(c) (AnyObject, Selector, AnyObject, NSURL, UnsafeMutablePointer<Unmanaged<AnyObject>?>) -> ObjCBool
        let call = unsafeBitCast(method_getImplementation(method), to:Validate.self)
        var error: Unmanaged<AnyObject>?
        let accepted = call(delegate as AnyObject, NSSelectorFromString("panel:validateURL:error:"), panel, url as NSURL, &error)
        return (accepted.boolValue, error?.takeUnretainedValue() as? NSError)
    }
    @MainActor static func require(_ value: @autoclosure () -> Bool, line: Int = #line) throws { if !value() { throw MergeOpenCheckFailure(line: line) } }
    @MainActor static func wait(line:Int = #line,_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw MergeOpenCheckFailure(line: line)
    }
    @MainActor static func verifyAuthorization(root: URL, prefs: UserDefaults, pasteboard: NSPasteboard) async throws {
        let provider = MergeOpenPrivateBookmarks()
        let typed = MergeOpenWindowController(preferences:prefs,pasteboard:pasteboard)
        defer { typed.close() }
        typed.requiresScopes = true
        typed.makeLease = { RepositoryAccessLease(url:$0,provider:provider) }
        let first = FileTransferPaths.fileURL(root.path + "/Café\ntyped"), second = FileTransferPaths.fileURL(root.path + "/Cafe\u{301}\ntyped")
        typed.base.stringValue = first.path; typed.mine.stringValue = second.path
        var slots: [MergeOpenWindowController.Slot] = [], accepted = 0
        var received: MergeOpenRequest?, retained: [RepositoryAccessLease] = []
        typed.choosePath = { slot, requested in
            slots.append(slot)
            guard let requested else { return nil }
            // The target deliberately does not exist until access is requested.
            // An existence check before authorization would never reach here.
            try? Data("authorized input\n".utf8).write(to:requested)
            return requested
        }
        typed.onAccepted = { request, grants in accepted += 1; received = request; retained = grants }
        typed.accept(); try await wait { !typed.busy }
        try require(slots == [.base] && accepted == 0 && typed.status.stringValue.isEmpty)
        typed.accept(); try await wait { !typed.busy }
        // Canonical-equivalent paths may share the first grant, but their role
        // spellings must still survive the submitted request unchanged.
        if accepted == 0 { typed.accept() }
        try require(accepted == 1 && !retained.isEmpty)
        guard case .compare(let base,let mine,let single) = received else { throw MergeOpenCheckFailure(line:#line) }
        try require(Data(base.path.utf8) == Data(first.path.utf8) && Data(mine.path.utf8) == Data(second.path.utf8) && !single)
        try require(prefs.integer(forKey:"TurtleGitMerge.OpenRadio") == MergeOpenMode.merging.rawValue)
        let cancelled = MergeOpenWindowController(preferences:prefs,pasteboard:pasteboard)
        defer { cancelled.close() }; cancelled.requiresScopes = true
        cancelled.base.stringValue = root.appendingPathComponent("not-yet-authorized").path
        var choices = 0
        cancelled.choosePath = { _,_ in choices += 1; return nil }
        cancelled.onAccepted = { _,_ in throw MergeOpenCheckFailure(line:#line) }
        cancelled.accept(); try await wait { !cancelled.busy }
        try require(choices == 1 && cancelled.status.stringValue.isEmpty && cancelled.base.stringValue.hasSuffix("not-yet-authorized"))
        // Native validation keeps a wrong selection in the same authorization
        // panel. Injected presenters must also pass the post-answer check.
        let corrected = MergeOpenWindowController(preferences:prefs,pasteboard:pasteboard)
        defer { corrected.close() }; corrected.requiresScopes = true
        corrected.makeLease = { RepositoryAccessLease(url:$0,provider:provider) }
        corrected.base.stringValue = first.path
        var validations = 0, pickerCount = 0
        corrected.selectedPath = { _ in first }
        corrected.presentPicker = { panel,_,reply in
            pickerCount += 1
            do {
                let rejected = try validation(panel,root.appendingPathComponent("mine.txt"))
                if !rejected.0 && rejected.1 != nil { validations += 1 } else { validations = -100 }
                let accepted = try validation(panel,first)
                if accepted.0 && accepted.1 == nil { validations += 1 } else { validations = -100 }
            }
            catch { validations = -100 }
            reply(.OK); reply(.cancel)
        }
        var correctedAccepted = 0
        corrected.onAccepted = { _,grants in correctedAccepted += 1; try require(grants.count == 1) }
        corrected.accept(); try await wait { !corrected.busy }
        try require(validations == 2 && pickerCount == 1 && correctedAccepted == 0)
        corrected.accept(); try require(correctedAccepted == 1 && pickerCount == 1)
        let wrong = MergeOpenWindowController(preferences:prefs,pasteboard:pasteboard)
        defer { wrong.close() }; wrong.requiresScopes = true
        wrong.base.stringValue = first.path
        wrong.makeLease = { RepositoryAccessLease(url:$0,provider:provider) }
        var wrongReplies = 0, wrongAccepted = 0
        wrong.choosePath = { _,_ in wrongReplies += 1; return wrongReplies == 1 ? root.appendingPathComponent("mine.txt") : first }
        wrong.onAccepted = { _,grants in wrongAccepted += 1; try require(grants.count == 1) }
        wrong.accept(); try await wait { !wrong.busy }
        try require(wrongReplies == 1 && wrongAccepted == 0 && !wrong.status.stringValue.isEmpty && Data(wrong.base.stringValue.utf8) == Data(first.path.utf8))
        wrong.accept(); try await wait { !wrong.busy }; wrong.accept()
        try require(wrongAccepted == 1 && wrongReplies == 2)
        let draining = MergeOpenWindowController(preferences:prefs,pasteboard:pasteboard)
        defer { draining.close() }; draining.requiresScopes = true
        draining.base.stringValue = first.path
        draining.window?.alphaValue = 0; draining.window?.setFrameOrigin(NSPoint(x:-10000,y:-10000))
        draining.makeLease = { RepositoryAccessLease(url:$0,provider:provider) }
        draining.selectedPath = { _ in first }
        var heldPanel: NSOpenPanel?, reply: ((NSApplication.ModalResponse)->Void)?
        draining.presentPicker = { panel,owner,answer in
            panel.alphaValue = 0; heldPanel = panel; reply = answer; owner.beginSheet(panel)
        }
        draining.accept(); try await wait { heldPanel?.sheetParent != nil && reply != nil }
        reply?(.OK)
        await Task.yield(); await Task.yield()
        try require(draining.busy && draining.pendingChoices == 1 && !draining.ok.isEnabled)
        if let panel = heldPanel { draining.window?.endSheet(panel,returnCode:.OK); panel.orderOut(nil) }
        try await wait { !draining.busy && draining.pendingChoices == 0 }
        try require(draining.status.stringValue.isEmpty)
        retained = []
    }
    @MainActor static func verify() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TurtleGitMergeOpenNative-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories:true)
        let suite = "TurtleGit.MergeOpen.Native." + UUID().uuidString, prefs = UserDefaults(suiteName:suite)!
        let pasteboard = NSPasteboard(name:NSPasteboard.Name("TurtleGitMergeOpen-" + UUID().uuidString))
        defer { prefs.removePersistentDomain(forName:suite); pasteboard.releaseGlobally(); try? FileManager.default.removeItem(at:root) }
        let base = root.appendingPathComponent("base.txt"), theirs = root.appendingPathComponent("theirs.txt"), mine = root.appendingPathComponent("mine.txt")
        for (url,text) in [(base,"a\nb\nc\n"),(theirs,"a\nb\nC\n"),(mine,"a\nB\nc\n")] { try Data(text.utf8).write(to:url) }
        try await verifyAuthorization(root:root,prefs:prefs,pasteboard:pasteboard)
        let dropBoard = NSPasteboard(name:NSPasteboard.Name("TurtleGitMergeOpenDrop-" + UUID().uuidString))
        defer { dropBoard.releaseGlobally() }
        let paths = MergeOpenWindowController(preferences:prefs,pasteboard:pasteboard)
        defer { paths.close() }
        paths.setMode(.merging)
        dropBoard.writeObjects([mine as NSURL]); try require(paths.mine.acceptDrop(from:dropBoard) && paths.mine.stringValue == mine.path)
        try require(!paths.directory.acceptDrop(from:dropBoard))
        paths.setMode(.applyUnifiedDiff)
        dropBoard.clearContents(); dropBoard.writeObjects([root as NSURL])
        try require(paths.directory.acceptDrop(from:dropBoard) && paths.directory.stringValue == root.path)
        try require(!paths.diff.acceptDrop(from:dropBoard))
        let candidates = paths.completionCandidates(for:root.path + "/mi")
        try require(candidates == [mine.path])
        try require(paths.completionCandidates(for:root.path + "/mi",directoryOnly:true).isEmpty)
        let ungranted = MergeOpenWindowController(preferences:prefs,pasteboard:pasteboard)
        defer { ungranted.close() }; ungranted.requiresScopes = true
        try require(ungranted.completionCandidates(for:root.path + "/mi").isEmpty)
        paths.pollClipboard(); try require(!paths.clipboard.isEnabled)
        pasteboard.setData(Data("diff --git a/a b/a\n".utf8),forType:PatchClipboard.unifiedDiff)
        paths.pollClipboard(); try require(paths.clipboard.isEnabled)
        paths.clipboard.state = .on
        pasteboard.clearContents(); paths.pollClipboard(); try require(paths.clipboard.isEnabled && !paths.diff.isEnabled)
        paths.clipboard.state = .off; paths.updateGates(); try require(!paths.clipboard.isEnabled && paths.diff.isEnabled)
        paths.close(); try require(paths.completionCandidates(for:root.path + "/mi").isEmpty)
        let parent = NSWindow(contentRect:NSRect(x:0,y:0,width:700,height:600),styleMask:[.titled],backing:.buffered,defer:false)
        parent.isReleasedWhenClosed = false; defer { parent.close() }
        let watched = MergeOpenWindowController(preferences:prefs,pasteboard:pasteboard)
        defer { watched.close() }; watched.setMode(.applyUnifiedDiff); watched.present(parent:parent)
        parent.orderOut(nil); watched.window?.orderOut(nil)
        try require(watched.monitoringClipboard && watched.window?.sheetParent === parent)
        pasteboard.setData(Data("diff --git a/a b/a\n".utf8),forType:PatchClipboard.unifiedDiff)
        try await wait { watched.clipboard.isEnabled }
        parent.close(); try require(!watched.monitoringClipboard && watched.window?.sheetParent == nil)
        pasteboard.clearContents()
        let opener = MergeOpenWindowController(preferences:prefs,pasteboard:pasteboard)
        defer { opener.close() }
        try require(opener.mode == .merging && opener.base.isEnabled && !opener.diff.isEnabled && !opener.clipboard.isEnabled)
        opener.setMode(.applyUnifiedDiff)
        try require(!opener.base.isEnabled && opener.diff.isEnabled && opener.directory.isEnabled)
        let patch = Data("--- a/mine.txt\n+++ b/mine.txt\n@@ -1,3 +1,3 @@\n a\n-B\n+PATCH\n c\n".utf8)
        pasteboard.setData(patch,forType:PatchClipboard.unifiedDiff); opener.updateGates()
        try require(opener.clipboard.isEnabled)
        opener.clipboard.state = .on; opener.updateGates(); try require(!opener.diff.isEnabled && opener.directory.isEnabled)
        opener.directory.stringValue = root.path; opener.base.stringValue = "/not-used"
        var captured: MergeOpenRequest?
        opener.onAccepted = { request,_ in captured = request }; opener.accept()
        guard case .patch(nil,let target,let bytes) = captured else { throw MergeOpenCheckFailure(line:#line) }
        try require(target?.path == root.path && bytes == patch && prefs.integer(forKey:"TurtleGitMerge.OpenRadio") == 1)
        // Radio Cancel retains preference; missing paths retain the window and error.
        let invalid = MergeOpenWindowController(preferences:prefs,pasteboard:pasteboard); defer { invalid.close() }
        invalid.setMode(.merging); invalid.base.stringValue = root.appendingPathComponent("missing").path
        var acceptedInvalid = false; invalid.onAccepted = { _,_ in acceptedInvalid = true }; invalid.accept()
        try require(!acceptedInvalid && !invalid.status.stringValue.isEmpty); invalid.close()
        try require(prefs.integer(forKey:"TurtleGitMerge.OpenRadio") == 1)
        // Captured picker result expires after its owning Open window closes.
        let late = MergeOpenWindowController(preferences:prefs,pasteboard:pasteboard); defer { late.close() }
        var continuation: CheckedContinuation<URL?,Never>?
        var lateLeases = 0
        late.makeLease = { url in lateLeases += 1; return RepositoryAccessLease(url:url) }
        late.choosePath = { _,_ in await withCheckedContinuation { continuation = $0 } }
        late.browse(.diff); try await wait { continuation != nil }; try require(late.busy && !late.ok.isEnabled)
        late.close(); continuation?.resume(returning:base); try await Task.sleep(nanoseconds:20_000_000)
        try require(late.diff.stringValue.isEmpty && lateLeases == 0)
        // Open-created standalone three-pane model owns exact result and guarded Save.
        let working = try WorkingTextMerge(base:base,theirs:theirs,mine:mine)
        let context = GitRepository(root:root,executable:URL(fileURLWithPath:"/usr/bin/git"))
        let merge = TextConflictWindowController(repository:context,access:nil,path:mine.lastPathComponent,workingMerge:working)
        defer { merge.window?.close() }
        merge.model.comparisonDefaults = prefs; merge.model.commentProfileURL = root.appendingPathComponent("ignorecomments.txt"); merge.model.load()
        try await wait { !merge.model.busy && merge.model.document != nil }
        try require(merge.model.result == "a\nB\nC\n" && merge.model.dirty)
        // Standalone Mark as resolved now saves first, then obtains authority
        // for that actual output. Cancelling its output choice must do neither.
        var outputChoices=0,resolutionRequests=0,resolvedCallbacks=0
        var outputReply:CheckedContinuation<URL?,Never>?
        defer {outputReply?.resume(returning:nil)}
        merge.model.newOutputAdd.resolveRepository={_,_ in resolutionRequests += 1;throw MergeOpenCheckFailure(line:#line)}
        merge.model.onResolvedOutput={_,_ in resolvedCallbacks += 1}
        merge.model.chooseStandaloneOutput={_,_ in outputChoices += 1;return await withCheckedContinuation {outputReply=$0}}
        merge.model.save(markResolved:true)
        try await wait {outputReply != nil}
        try require(merge.model.busy && merge.model.workingMergeOutput==nil && merge.model.pendingResolve==nil && resolutionRequests==0)
        merge.model.save(markResolved:true);try require(outputChoices==1)
        merge.model.cancelSaveOperation()
        try require(merge.model.busy) // The accepted chooser remains owned until its real reply drains.
        let cancelledOutput=root.appendingPathComponent("cancelled-resolve-output.txt")
        outputReply?.resume(returning:cancelledOutput);outputReply=nil
        try await wait {!merge.model.mergeToolHasPendingWork}
        try require(!FileManager.default.fileExists(atPath:cancelledOutput.path) && merge.model.workingMergeOutput==nil && merge.model.pendingResolve==nil && merge.model.dirty && merge.model.error==nil && resolutionRequests==0 && resolvedCallbacks==0)
        try require((try? Data(contentsOf:mine))==Data("a\nB\nc\n".utf8) && !FileManager.default.fileExists(atPath:root.appendingPathComponent(".git").path))
        merge.model.chooseStandaloneOutput = { _,_ in nil }
        merge.model.save(markResolved:false); try await wait { !merge.model.busy }
        try require(merge.model.workingMergeOutput == nil && merge.model.dirty)
        let resultFile = root.appendingPathComponent("result.txt")
        merge.model.chooseStandaloneOutput = { _,_ in resultFile }
        merge.model.save(markResolved:false); try await wait { !merge.model.busy }
        let saved = try Data(contentsOf:resultFile)
        try require(saved == Data("a\nB\nC\n".utf8) && !merge.model.dirty && merge.model.error == nil)
        let unchangedMine = try Data(contentsOf: mine)
        try require(unchangedMine == Data("a\nB\nc\n".utf8) && merge.model.workingMergeOutput == resultFile)
        try require(!FileManager.default.fileExists(atPath:root.appendingPathComponent(".git").path))
        merge.model.chooseStandaloneOutput = { _,_ in nil }; merge.model.export()
        try await wait { !merge.model.busy }
        try require(merge.model.workingMergeOutput == resultFile)
        merge.model.chooseStandaloneOutput = { _,_ in mine }; merge.model.export()
        try await wait { !merge.model.busy }
        try require(merge.model.workingMergeOutput == mine && merge.model.error == nil)
        merge.model.result = "another result\n"; merge.model.save(markResolved:false)
        try await wait { !merge.model.busy }
        let aliasSaved = try Data(contentsOf:mine)
        try require(aliasSaved == Data("another result\n".utf8) && !merge.model.dirty && merge.model.error == nil)
        let originalResult = merge.model.result
        merge.model.chooseFormat = { _,_,_ in .init(encoding:.utf16BEBOM) }; merge.model.showFormatDialog()
        try await wait { merge.model.encoding == .utf16BEBOM }
        try require(merge.model.result == originalResult)
        merge.model.chooseFormat = { _,_,_ in .init(encoding:.utf8,ending:.crlf) }; merge.model.showFormatDialog()
        try await wait { merge.model.encoding == .utf8 && merge.model.result == "another result\r\n" }
        let beforeRetirement=try Data(contentsOf:mine),retiredOutput=root.appendingPathComponent("retired-resolve-output.txt")
        merge.model.chooseStandaloneOutput={_,_ in outputChoices += 1;return await withCheckedContinuation {outputReply=$0}}
        merge.model.save(markResolved:true,chooseNewOutput:true)
        try await wait {outputReply != nil}
        merge.window?.close()
        outputReply?.resume(returning:retiredOutput);outputReply=nil
        try await wait { MergeRegexOperations.activeRequests == 0 }
        try require(merge.model.retired && !merge.model.mergeToolHasPendingWork && !FileManager.default.fileExists(atPath:retiredOutput.path) && resolutionRequests==0 && resolvedCallbacks==0)
        try require((try? Data(contentsOf:mine))==beforeRetirement && !FileManager.default.fileExists(atPath:root.appendingPathComponent(".git").path))
        print("Merge Open: native source radio/field/clipboard gates, captured private patch, mode Apply/Cancel, invalid path, expired picker, standalone three-pane load/save/dirty and no Git initialization passed. All owned windows closed.")
    }
}
