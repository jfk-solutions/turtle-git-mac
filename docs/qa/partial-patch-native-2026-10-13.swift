import AppKit
import Darwin
import TurtleGitCore

@main struct PartialPatchVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func require(_ value: Bool, _ description: String) throws { if !value { throw Failure(description: description) } }
    @MainActor static func wait(_ value: @escaping () -> Bool) async throws {
        for _ in 0..<1000 { if value() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure(description: "Patch state did not settle")
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func main() async { do { try await verify() } catch { fputs("Partial patch failed: \(error)\n", stderr); exit(1) } }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), engine = URL(fileURLWithPath: CommandLine.arguments[2])
        let repo = GitRepository(root: root, executable: engine)
        _ = try await repo.run(["init", "-b", "main"])
        for (key,value) in [("user.name","Patch QA"),("user.email","patch@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] { _ = try await repo.run(["config",key,value]) }
        let file = root.appendingPathComponent("file.txt"), other = root.appendingPathComponent("other.txt")
        try Data("base\n".utf8).write(to: file); try Data("other\n".utf8).write(to: other)
        try await repo.stage(["file.txt","other.txt"]); _ = try await repo.commit(message: "base")
        try Data("base\nneedle 雪\n".utf8).write(to: file); try Data("other staged\n".utf8).write(to: other); try await repo.stage(["other.txt"])
        let head = try await repo.run(["rev-parse","HEAD"]).stdout
        let suite = "TurtleGit.PartialPatch.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let controller = PatchWindowController(repository: repo, access: nil, preferences: prefs), model = controller.model, window = controller.window!
        defer { controller.close() }
        var focus: NSWindow? = window
        let menu = PatchMenuContext(keyWindow: { focus })
        window.contentView?.layoutSubtreeIfNeeded()
        func source() -> PatchTextView.PatchText? { descendants(window.contentView!).compactMap { $0 as? PatchTextView.PatchText }.first }
        try await wait { source() != nil }
        let text = source()!
        // Source-style Find works on the exact displayed bytes, including no LF.
        model.document = GitPatch(text: "needle 雪\nNEEDLE two\nlast needle")
        try await wait { text.string == model.document.text }
        try require(text.string.hasSuffix("needle") && !text.string.hasSuffix("\n"), "Renderer added a newline")
        text.setSelectedRange(NSRange(location: 0, length: 6)); text.find(.showFindInterface)
        try require(model.findVisible && model.findText == "needle", "Selection did not seed bottom Find")
        model.changeFindText("needle")
        try require(text.selectedRange() == NSRange(location: 0, length: 6), "Incremental Find did not reset to start")
        model.search(previous: false); try require((text.string as NSString).substring(with: text.selectedRange()) == "NEEDLE", "Case-insensitive Next")
        model.search(previous: false); let last = text.selectedRange(), boundary = model.findBoundaryCount
        model.search(previous: false)
        try require(text.selectedRange() == NSRange(location: NSMaxRange(last), length: 0) && model.findBoundaryCount == boundary + 1, "Next wrapped instead of stopping")
        model.search(previous: true); try require(text.selectedRange() == last, "Previous boundary cursor")
        model.findMatchCase = true; model.changeFindText("NEEDLE")
        try require(text.selectedRange().location == 9, "Match case or Unicode offsets differ")
        model.hideFind(); try require(!model.findVisible, "Find did not hide")
        // Exact rendering also applies to shared read-only previews.
        let raw = Data([0x61, 0xff, 0x62]); model.setReadOnlyDiff(raw)
        try await wait { text.string == model.document.text }
        try require(model.exportDocument.bytes == raw, "Read-only export lost original bytes")
        model.readOnly = false
        var applying: [Bool] = [], settlements: [Bool] = []; model.onApplying = { applying.append($0) }; model.onSettled = { settlements.append($0) }
        model.reload(paths: ["file.txt"], staged: false)
        try await wait { !model.busy && text.string == model.document.text }
        guard let line = model.document.lines.firstIndex(where: { $0 == "+needle 雪" }) else { throw Failure(description: "Missing changed line") }
        model.selectedLines = [line]
        try await wait { menu.stageLinesAvailable && menu.stageHunksAvailable }
        try require(!menu.unstageLinesAvailable && menu.partialAvailable, "Inactive Unstaging menu")
        focus = nil; menu.apply(staged:false,entireHunks:false)
        try require(!model.busy, "Background Patch command ran without a focused owner")
        focus = window; menu.apply(staged:true,entireHunks:false)
        try require(!model.busy, "Opposite staging menu acted on the current mode")
        menu.apply(staged:false,entireHunks:false)
        try await wait { !model.busy && PatchWindowModel.activeOperations == 0 }
        let staged = try await repo.run(["show",":file.txt"]).stdout, unrelated = try await repo.run(["show",":other.txt"]).stdout
        try require(staged == Data("base\nneedle 雪\n".utf8) && unrelated == Data("other staged\n".utf8), "Line staging changed unrelated index data")
        model.reload(paths: ["file.txt"], staged: true)
        try await wait { !model.busy }
        let undo = model.document.lines.firstIndex(where: { $0 == "+needle 雪" })!
        model.selectedLines = [undo]
        try await wait { menu.unstageHunksAvailable && !menu.stageHunksAvailable }
        menu.apply(staged:true,entireHunks:true)
        try await wait { !model.busy && PatchWindowModel.activeOperations == 0 }
        let restored = try await repo.run(["show",":file.txt"]).stdout
        try require(restored == Data("base\n".utf8) && applying == [true,false,true,false], "Unstaging or parent gate balancing")
        // A failed stale selection settles the parent without hiding its error.
        model.reload(paths:["file.txt"],staged:false);try await wait { !model.busy && text.string == model.document.text }
        model.selectedLines=[model.document.lines.firstIndex(where:{ $0 == "+needle 雪" })!]
        try Data("base\nneedle 雪\nlater\n".utf8).write(to:file)
        menu.apply(staged:false,entireHunks:false)
        try await wait { !model.busy && model.error != nil }
        try require(settlements == [true,true,false] && applying == [true,false,true,false,true,false],"Failed staging did not balance its parent or preserve the error")
        let failedIndex=try await repo.run(["show",":file.txt"]).stdout
        try require(failedIndex == Data("base\n".utf8),"Stale staging mutated the index")
        model.error=nil;try Data("base\nneedle 雪\n".utf8).write(to:file)
        try await wait { window.attachedSheet == nil }
        // Each held child/descendant belongs to this disposable fixture.
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        for phase in 0..<3 {
            let helper = root.appendingPathComponent("held-\(phase)")
            let script = """
            #!/bin/sh
            for arg in "$@"; do
              if [ "$arg" = held.txt ]; then
                /bin/sleep 30 &
                task_child=$!
                trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
                printf '%s %s\\n' "$$" "$task_child" > "$0.ready.tmp"
                /bin/mv "$0.ready.tmp" "$0.ready"
                wait "$task_child"
              fi
            done
            exec \(quote(engine.path)) "$@"
            """
            try script.write(to: helper, atomically: true, encoding: .utf8); try FileManager.default.setAttributes([.posixPermissions:0o755], ofItemAtPath: helper.path)
            let owner = PatchWindowController(repository: GitRepository(root:root, executable:helper), access:nil, preferences:prefs), value = owner.model
            value.reload(paths:["held.txt"], staged:false)
            let marker = URL(fileURLWithPath:helper.path + ".ready")
            try await wait { FileManager.default.fileExists(atPath:marker.path) }
            let pids = try String(contentsOf:marker).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
            try require(pids.count == 2 && !owner.windowShouldClose(owner.window!), "Owned loading/close guard")
            if phase == 0 { value.reload(paths:["file.txt"], staged:false) }
            else if phase == 1 { value.cancelRead(); try require(value.cancelling && value.busy, "Cancellation pending was not published") }
            else {
                owner.close(); try require(value.retired && PatchWindowModel.activeOperations > 0 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel, "Forced close did not retain operation/Quit ownership")
                let old = value.document.text; value.setReadOnlyDiff(Data("late".utf8)); value.reload(paths:["file.txt"],staged:false)
                try require(value.document.text == old, "Retired preview accepted a late result")
            }
            try await wait { !value.busy && PatchWindowModel.activeOperations == 0 }
            for pid in pids { try require(kill(pid,0) == -1 && errno == ESRCH, "Owned patch helper leaked") }
            try require(value.error == nil, "Cancellation surfaced as a load error")
            if phase == 0 { try require(value.document.text.contains("+needle 雪"), "Replacement preview was overwritten") }
            owner.close()
        }
        // Closing cannot cancel an accepted index mutation. Keep Quit and the
        // captured parent gate owned until its check/application finish.
        let mutationHelper = root.appendingPathComponent("held-apply")
        let mutationScript = """
        #!/bin/sh
        for arg in "$@"; do
          if [ "$arg" = apply ] && [ ! -f "$0.released" ]; then
            (while [ ! -f "$0.release" ]; do /bin/sleep 0.02; done) &
            task_child=$!
            trap 'kill "$task_child" 2>/dev/null; wait "$task_child" 2>/dev/null; exit 143' TERM INT
            printf '%s %s\\n' "$$" "$task_child" > "$0.ready.tmp"
            /bin/mv "$0.ready.tmp" "$0.ready"
            wait "$task_child"
            /usr/bin/touch "$0.released"
          fi
        done
        exec \(quote(engine.path)) "$@"
        """
        try mutationScript.write(to:mutationHelper,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:mutationHelper.path)
        let mutationOwner = PatchWindowController(repository:GitRepository(root:root,executable:mutationHelper),access:nil,preferences:prefs)
        let mutation = mutationOwner.model
        mutation.reload(paths:["file.txt"],staged:false);try await wait { !mutation.busy }
        var gate:[Bool]=[],settled:[Bool]=[],lateApplied=0
        mutation.onApplying={ gate.append($0) };mutation.onApplied={ lateApplied += 1 };mutation.onSettled={ settled.append($0) }
        mutation.selectedLines=[mutation.document.lines.firstIndex(where:{ $0 == "+needle 雪" })!]
        mutation.apply(entireHunks:false)
        let mutationMarker=URL(fileURLWithPath:mutationHelper.path+".ready")
        try await wait { FileManager.default.fileExists(atPath:mutationMarker.path) }
        try require(gate == [true] && !mutationOwner.windowShouldClose(mutationOwner.window!),"Mutation parent/close gate")
        let mutationPIDs=try String(contentsOf:mutationMarker).split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        mutationOwner.close()
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel,"Quit forgot closed mutation owner")
        try Data().write(to:URL(fileURLWithPath:mutationHelper.path+".release"))
        try await wait { !mutation.busy && PatchWindowModel.activeOperations == 0 }
        try require(gate == [true,false] && settled == [true] && lateApplied == 0,"Retired mutation did not release its original parent exactly once")
        let accepted=try await repo.run(["show",":file.txt"]).stdout
        try require(accepted == Data("base\nneedle 雪\n".utf8),"Accepted mutation was lost after forced close")
        try require(mutationPIDs.count == 2 && mutationPIDs.allSatisfy({ kill($0,0) != 0 }),"Mutation helper leaked")
        let after = try await repo.run(["rev-parse","HEAD"]).stdout
        try require(head == after && (try Data(contentsOf:file)) == Data("base\nneedle 雪\n".utf8), "Preview/staging changed HEAD or working bytes")
        print("Partial patch: source Staging/Unstaging menu gates and bottom Find/case/no-wrap boundaries, exact rendering and original-byte export; real line stage/hunk unstage, unrelated index preservation, superseded/cancelled/retired reads closed-mutation Quit/parent gates and owned process reaping passed.")
    }
}
