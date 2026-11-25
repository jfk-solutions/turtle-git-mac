import AppKit
import SwiftUI
import TurtleGitCore

@MainActor final class OutputFontMode: ObservableObject { @Published var configured = false }
struct OutputFontPreview: View {
    @ObservedObject var mode: OutputFontMode
    var body: some View { OutputView(text: "Legacy output", usesLogFont: mode.configured) }
}

@main struct LogRebaseFontVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:Int = #line)throws {if !value {throw Failure(description:"Log/Rebase font \(line): \(message)")}}
    @MainActor static func wait(_ message:String,_ ready:()->Bool)async throws {
        for _ in 0..<2000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Log/Rebase font timeout: "+message)
    }
    @MainActor static func settle(_ host: NSView) async throws {
        for _ in 0..<20 { host.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 10_000_000) }
    }
    @MainActor static func texts(in view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { texts(in: $0) }
    }
    @MainActor static func host<V: View>(_ view: V) -> NSWindow {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1080, height: 740), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = NSHostingView(rootView: view); return window
    }
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "TurtleGit.LogRebaseFont.QA." + UUID().uuidString, prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite); prefs.synchronize() }
        let repo = GitRepository(root: URL(fileURLWithPath: CommandLine.arguments[1]), executable: URL(fileURLWithPath: CommandLine.arguments[2]))
        _ = try await repo.run(["init", "-b", "main"])
        let log = LogWindowModel(repository: repo, access: nil, labelDefaults: prefs)
        let rebase = RebaseWindowModel(repository: repo, access: nil, messageDefaults: prefs)
        rebase.fileRecovery = true; rebase.amendMessage = "Rebase draft 雪"; rebase.output = "Rebase progress 雪"; rebase.tab = 1
        let logWindow = host(LogDialog(model: log).defaultAppStorage(prefs))
        let rebaseWindow = host(RebaseDialog(model: rebase).defaultAppStorage(prefs))
        let mode = OutputFontMode()
        let legacy = host(OutputFontPreview(mode: mode).defaultAppStorage(prefs))
        defer { logWindow.close(); rebaseWindow.close(); legacy.close(); log.invalidate() }
        try await settle(logWindow.contentView!); try await settle(rebaseWindow.contentView!); try await settle(legacy.contentView!)
        let message = texts(in: logWindow.contentView!).first { $0.string == log.message }!
        let amend = texts(in: rebaseWindow.contentView!).first { $0.string == rebase.amendMessage }!
        let unchanged = texts(in: legacy.contentView!).first { $0.string == "Legacy output" }!
        precondition(message.font?.pointSize == 9 && amend.font?.pointSize == 9 && unchanged.font?.pointSize == 12)
        message.setSelectedRange(.init(location: 0, length: 8)); amend.setSelectedRange(.init(location: 0, length: 6))
        prefs.set("Monaco", forKey: "LogFontName"); prefs.set(18, forKey: "LogFontSize")
        try await settle(logWindow.contentView!); try await settle(rebaseWindow.contentView!); try await settle(legacy.contentView!)
        precondition(message.font?.familyName == "Monaco" && message.font?.pointSize == 18)
        precondition(amend.font?.familyName == "Monaco" && amend.font?.pointSize == 18 && amend.string == "Rebase draft 雪")
        precondition(message.selectedRange() == .init(location: 0, length: 8) && amend.selectedRange() == .init(location: 0, length: 6))
        precondition(unchanged.font?.pointSize == 12 && unchanged.string == "Legacy output")
        mode.configured = true; try await settle(legacy.contentView!); precondition(unchanged.font?.pointSize == 18)
        mode.configured = false; try await settle(legacy.contentView!); precondition(unchanged.font?.pointSize == 12)
        rebase.tab = 2; try await settle(rebaseWindow.contentView!)
        let progress = texts(in: rebaseWindow.contentView!).first { $0.string == rebase.output }!
        precondition(progress.font?.familyName == "Monaco" && progress.font?.pointSize == 18 && !progress.isEditable)
        progress.setSelectedRange(.init(location:0,length:6))
        prefs.set(22, forKey: "LogFontSize")
        try await wait("unchanged Rebase output adopts configured font") {progress.font?.pointSize == 22}
        try require(progress.font?.familyName == "Monaco" && progress.font?.pointSize == 22 && progress.string == "Rebase progress 雪","Live progress font/text did not update")
        try require(progress.selectedRange() == .init(location:0,length:6) && !progress.isEditable,"Live progress restyle lost selection/read-only state")
        precondition(!message.isEditable && rebase.amendMessage == "Rebase draft 雪")
        // Exercise the shared consumer without SwiftUI/AppStorage causing a
        // representable update: its native preference observation owns restyling.
        let nativeScroll=SubmoduleProgressTextView.scrollView(preferences:prefs,clipboard:NSPasteboard.withUniqueName())
        let native=nativeScroll.documentView as! SubmoduleProgressTextView
        let nativeWindow=NSWindow(contentRect:.init(x:-24000,y:-24000,width:700,height:240),styleMask:.titled,backing:.buffered,defer:false)
        nativeWindow.isReleasedWhenClosed=false;nativeWindow.contentView=nativeScroll
        defer {native.clipboard.releaseGlobally();nativeWindow.close()}
        let output="error: retained source 雪\nhttps://example.invalid/path\n"+String(repeating:"unchanged progress line\n",count:100)+"Success\n"
        let completion=(output as NSString).range(of:"Success")
        native.present(output,completed:true,completionRange:completion,success:true)
        native.setSelectedRange(.init(location:7,length:6));nativeWindow.contentView?.layoutSubtreeIfNeeded()
        nativeScroll.contentView.scroll(to:.init(x:0,y:100));nativeScroll.reflectScrolledClipView(nativeScroll.contentView)
        let origin=nativeScroll.contentView.bounds.origin,selection=native.selectedRange()
        func attribute(_ key:NSAttributedString.Key,_ value:String)->Any? {native.textStorage?.attribute(key,at:(output as NSString).range(of:value).location,effectiveRange:nil)}
        func fontDescription(_ font:NSFont?)->String {font.map {"\($0.fontName)@\($0.pointSize) traits=\($0.fontDescriptor.symbolicTraits.rawValue)"} ?? "nil"}
        func color(_ value:String)->NSColor? {(attribute(.foregroundColor,value) as? NSColor)?.usingColorSpace(.deviceRGB)}
        let successColor=color("Success"),warningColor=color("error: "),bodyColor=color("retained")
        let originalBase=MessageEditorFont.resolve(name:"Monaco",size:22)
        let originalPrefix=attribute(.font,"error: ") as? NSFont
        let originalExpected=NSFontManager.shared.convert(originalBase,toHaveTrait:.boldFontMask)
        try require(originalPrefix==originalExpected,"Initial warning font "+fontDescription(originalPrefix)+" != source converter "+fontDescription(originalExpected))
        try require(successColor != nil && warningColor != nil && bodyColor != nil && warningColor != bodyColor,"Initial warning/completion colors missing")
        prefs.set(24,forKey:"LogFontSize")
        try await wait("native progress preference observer") {(attribute(.font,"retained") as? NSFont)?.pointSize == 24}
        let changedBase=MessageEditorFont.resolve(name:"Monaco",size:24),changedPrefix=attribute(.font,"error: ") as? NSFont
        let changedExpected=NSFontManager.shared.convert(changedBase,toHaveTrait:.boldFontMask)
        print("PROGRESS_STYLE: original=\(fontDescription(originalPrefix)), originalExpected=\(fontDescription(originalExpected)), changed=\(fontDescription(changedPrefix)), changedExpected=\(fontDescription(changedExpected)), warning=\(String(describing:color("error: "))), link=\(String(describing:attribute(.link,"https://example.invalid/path"))), completion=\(String(describing:color("Success")))")
        // Monaco has no bold face on macOS: retain the exact native conversion
        // rather than requiring a trait that NSFontManager cannot supply.
        try require(changedPrefix==changedExpected,"Warning restyle font "+fontDescription(changedPrefix)+" != source converter "+fontDescription(changedExpected))
        try require(color("error: ")==warningColor,"Font restyle changed warning prefix color")
        try require(attribute(.link,"https://example.invalid/path") != nil,"Font restyle removed link target")
        try require(color("Success")==successColor,"Font restyle changed completion color")
        try require(native.string == output && native.selectedRange()==selection && nativeScroll.contentView.bounds.origin==origin,"Preference-only restyle changed output/selection/viewport")
        prefs.set(false,forKey:"StyleGitOutput")
        try await wait("native style-only preference observer") {color("error: ")==bodyColor}
        try require((attribute(.font,"error: ") as? NSFont)==changedBase,"Style-disabled prefix retained a warning font")
        try require(attribute(.link,"https://example.invalid/path") != nil && color("Success")==successColor && native.selectedRange()==selection && nativeScroll.contentView.bounds.origin==origin,"Style-only refresh lost links/completion/selection/viewport")
        nativeWindow.close();try require(native.retired,"Closed native progress retained preference ownership")
        prefs.set(28,forKey:"LogFontSize");try await settle(nativeScroll)
        native.present("late output",completed:false)
        try require(native.string==output && (attribute(.font,"retained") as? NSFont)?.pointSize == 24 && native.outputMenu().items.isEmpty,"Retired progress accepted late output/settings/menu")
        print("PASS: actual hidden Log message pane and Rebase amend/progress views use shared source default and live configured fonts; draft/selection retained, read-only output and legacy fonts preserved; shared native preference-only warning/link/footer restyle keeps selection/viewport and retires with owner; no main app or rebase operation")
    }
}
