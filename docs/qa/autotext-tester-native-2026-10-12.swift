import AppKit
import TurtleGitCore

@main struct AutotextTesterVerification {
    @MainActor static func main() async {
        do { try await verify() } catch { fputs("Autotext tester failed: \(error)\n",stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        func require(_ value:Bool,_ message:String) throws { if !value { throw NSError(domain:message,code:1) } }
        func wait(_ ready:()->Bool) async throws {
            for _ in 0..<1000 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
            throw NSError(domain:"Autotext request did not settle",code:1)
        }
        let helper = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/IssueRegex/issue-regex")
        let suite = "TurtleGit.Autotext.QA." + UUID().uuidString
        let prefs = UserDefaults(suiteName:suite)!, clipboard = NSPasteboard(name:NSPasteboard.Name(suite))
        defer { prefs.removePersistentDomain(forName:suite); clipboard.clearContents() }
        let model = AutotextTesterModel(executable:helper,preferences:prefs,clipboard:clipboard)
        let controller = AutotextTesterController(model:model)
        defer { controller.close() }
        model.content = "Foo bar Foo 雪"; model.pattern = "(foo)|(bar)|(雪)"
        try require(model.result.isEmpty && !model.busy,"Editing triggered an implicit scan")
        model.scan(); try await wait { !model.busy }
        try require(model.result == "Foo\r\nbar\r\n雪\r\n" && model.timing.hasPrefix("Parse time: "),"Source captures/sort/timing differ")
        model.pattern = "foo"; model.scan(); try await wait { !model.busy }
        try require(model.result.isEmpty && !model.timing.isEmpty,"Whole matches incorrectly became auto words")
        model.pattern = "("; model.scan(); try await wait { !model.busy }
        try require(model.result.hasPrefix("Regex is invalid!\r\n") && model.timing.isEmpty,"Invalid regex did not clear previous results/timing")
        model.pattern = ""; model.scan(); try require(model.result.isEmpty && model.timing.isEmpty && !model.busy,"Empty expression spawned a scan")
        model.content = "before\0after"; model.pattern = "(after)"; model.scan(); try await wait { !model.busy }
        try require(model.result.isEmpty,"CString content did not stop at NUL")
        model.content = String(repeating:"a",count:AutotextTesterModel.contentLimit+10)
        try require(model.content.utf16.count == AutotextTesterModel.contentLimit,"Source content limit differs")
        model.content = "😀 雪"; model.pattern = "(雪)"; model.scan(); try await wait { !model.busy }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        func editors(_ view:NSView) -> [IssueRegexSampleTextView] {
            (view as? IssueRegexSampleTextView).map { [$0] } ?? view.subviews.flatMap { editors($0) }
        }
        try await wait { controller.window?.contentView.map { editors($0).count == 2 } ?? false }
        try require(controller.window!.contentView!.bounds.width >= 600 && controller.window!.contentView!.bounds.height >= 600,"Fixed Autotext window collapsed below usable source layout")
        let widgets = editors(controller.window!.contentView!), input = widgets.first { $0.isEditable }!, output = widgets.first { !$0.isEditable }!
        try require(input.string == model.content && output.string == model.result,"Native controls differ from model")
        input.setSelectedRange(NSRange(location:0,length:2)); input.copy(nil)
        try require(clipboard.string(forType:.string) == "😀","Private clipboard lost Unicode")
        output.setSelectedRange(NSRange(location:0,length:1)); output.cut(nil); output.paste(nil)
        try require(output.string == model.result && output.sampleMenu().items.first?.isEnabled == false,"Read-only results accepted edits")
        for appearance in [NSAppearance.Name.aqua,.darkAqua] { controller.window?.appearance = NSAppearance(named:appearance); controller.window?.contentView?.layoutSubtreeIfNeeded() }
        var held: CheckedContinuation<[String],Error>?, token: OperationCancellation?
        model.matcher = { _,_,cancellation in token = cancellation; return try await withCheckedThrowingContinuation { held = $0 } }
        model.scan(); try await wait { held != nil }
        try require(TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel,"Quit ignored owned matcher")
        controller.close(); model.retire()
        try require(token?.isCancelled == true && !model.busy,"Close did not cancel matcher")
        let before = model.result; held?.resume(returning:["late"]); held = nil
        try await wait { AutotextTesterModel.activeRequests == 0 }
        try require(model.result == before,"Retired request published late results")
        print("Autotext source captures, explicit scan, Unicode, limits, native editors and owned retirement passed.")
    }
}
