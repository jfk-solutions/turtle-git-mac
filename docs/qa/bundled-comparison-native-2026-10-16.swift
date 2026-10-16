import AppKit
import TurtleGitCore

@main struct BundledComparisonVerification {
    struct Failure: Error, LocalizedError { let message: String; var errorDescription: String? { message } }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(message:message) } }
    @MainActor static var owners: [NSWindowController] = []
    @MainActor static func wait(_ ready: () -> Bool, line: Int = #line) async throws {
        for _ in 0..<1500 { if ready() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(message:"Bundled comparison timeout at \(line)")
    }
    @MainActor static func main() async {
        NSApplication.shared.setActivationPolicy(ProcessInfo.processInfo.environment["TURTLEGIT_BUNDLED_CAPTURE"] == nil ? .prohibited : .accessory)
        do { try await verify(); owners.forEach { $0.close() }; DiffToolApplication.discardAll() }
        catch { owners.forEach { $0.close() }; DiffToolApplication.discardAll(); fputs("Bundled comparisons failed: \(error)\n",stderr); exit(1) }
    }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]), original=root.appendingPathComponent("old.dylib"), changed=root.appendingPathComponent("new.dylib")
        let beforeA=try Data(contentsOf:original), beforeB=try Data(contentsOf:changed)
        let suite="TurtleGit.BundledNative."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer { prefs.removePersistentDomain(forName:suite) }
        let savedBinary=DiffToolApplication.presentBinary, savedNotebook=DiffToolApplication.openNotebook
        defer { DiffToolApplication.presentBinary=savedBinary; DiffToolApplication.openNotebook=savedNotebook }
        var reports: [BinaryComparisonWindowController]=[]
        DiffToolApplication.presentBinary={ reports.append($0); owners.append($0); return true }
        let compare=FileComparisonWindowController(comparison:try WorkingFileComparison(base:original,destination:changed),permissions:[],preferences:prefs)
        owners.append(compare); compare.model.load(); try await wait { !compare.model.busy && reports.count==1 }
        try require(!reports[0].report.identical && reports[0].report.text.contains("File content differs!") && reports[0].report.text.contains("Version:"),"Real native-library report lost bytes/version")
        let equal=FileComparisonWindowController(comparison:try WorkingFileComparison(base:original,destination:original),permissions:[],preferences:prefs)
        owners.append(equal); equal.model.load(); try await wait { !equal.model.busy && reports.count==2 }
        try require(reports[1].report.identical && reports[1].report.text.contains("Files are identical"),"Identical native library reported different")
        if let capture=ProcessInfo.processInfo.environment["TURTLEGIT_BUNDLED_CAPTURE"] {
            let folder=URL(fileURLWithPath:capture); try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            for (theme,name) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
                let window=reports[0].window!; window.appearance=NSAppearance(named:theme); window.contentView?.appearance=window.appearance
                window.alphaValue=1; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
                try await Task.sleep(nanoseconds:350_000_000); window.contentView?.layoutSubtreeIfNeeded()
                let capture=Process(); capture.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
                capture.arguments=["-x","-o","-l",String(window.windowNumber),folder.appendingPathComponent("binary-comparison-"+name+".png").path]
                try capture.run(); capture.waitUntilExit()
                try require(capture.terminationStatus==0,"Owned binary window capture failed"); window.orderOut(nil)
            }
        }
        let base=root.appendingPathComponent("old notebook 雪.nb"), new=root.appendingPathComponent("new notebook.nb")
        let oldBytes=Data("Notebook[{Cell[\"old\"]}]".utf8),newBytes=Data("Notebook[{Cell[\"new\"]}]".utf8)
        try oldBytes.write(to:base); try newBytes.write(to:new)
        var handed: [URL]=[]
        DiffToolApplication.openNotebook={ file in
            handed.append(file)
            let folder=file.deletingLastPathComponent(), inputA=folder.appendingPathComponent("base").appendingPathComponent(base.lastPathComponent),inputB=folder.appendingPathComponent("new").appendingPathComponent(new.lastPathComponent)
            try require(try Data(contentsOf:inputA)==oldBytes && Data(contentsOf:inputB)==newBytes,"Notebook handoff changed captured bytes")
            let source=try String(contentsOf:file)
            try require(source.contains("Compare Notebooks") && source.contains("NotebookDiff") && source.contains("\\:96ea"),"Notebook driver lost source button or escaped filename")
        }
        let notebook=FileComparisonWindowController(comparison:try WorkingFileComparison(base:base,destination:new),permissions:[],preferences:prefs)
        owners.append(notebook); notebook.model.load(); try await wait { !notebook.model.busy && handed.count==1 }
        try require(notebook.model.error==nil && FileManager.default.fileExists(atPath:handed[0].path),"Successful notebook driver lost lifetime")
        // General app cleanup must not invalidate a successful source-style
        // notebook whose Compare button can be pressed in the receiver later.
        DiffToolApplication.discardAll(); try require(FileManager.default.fileExists(atPath:handed[0].path),"App cleanup removed a successful notebook driver")
        var rejected: URL?
        DiffToolApplication.openNotebook={ file in rejected=file; throw Failure(message:"Receiver refused notebook") }
        let failure=FileComparisonWindowController(comparison:try WorkingFileComparison(base:base,destination:new),permissions:[],preferences:prefs)
        owners.append(failure); failure.model.load(); try await wait { !failure.model.busy }
        try require(failure.model.error=="Receiver refused notebook" && rejected != nil && !FileManager.default.fileExists(atPath:rejected!.deletingLastPathComponent().path),"Rejected notebook launch leaked files or lost failure")
        var answer: CheckedContinuation<Void,Error>?, late: URL?
        DiffToolApplication.openNotebook={ file in late=file; try await withCheckedThrowingContinuation { answer=$0 } }
        let closing=FileComparisonWindowController(comparison:try WorkingFileComparison(base:base,destination:new),permissions:[],preferences:prefs)
        owners.append(closing); closing.model.load(); try await wait { answer != nil }; closing.close()
        try require(DiffToolApplication.activeRequests==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Closed pending notebook launch released Quit early")
        answer?.resume(); answer=nil; try await wait { DiffToolApplication.activeRequests==0 }
        try require(late != nil && FileManager.default.fileExists(atPath:late!.path) && closing.model.error==nil,"Late successful SDK handoff lost its inputs or published an obsolete error")
        for file in handed + [late].compactMap({$0}) { try? FileManager.default.removeItem(at:file.deletingLastPathComponent()) }
        try require((try Data(contentsOf:original))==beforeA && (try Data(contentsOf:changed))==beforeB && (try Data(contentsOf:base))==oldBytes && (try Data(contentsOf:new))==newBytes,"Bundled tools modified original input files")
        print("PASS: real Mach-O binary native reports/light-dark capture; notebook literal exact-copy handoff, retained inputs, failure cleanup, forced-close/Quit and late SDK ownership; unchanged original files")
    }
}
