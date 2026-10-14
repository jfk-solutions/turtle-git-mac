import AppKit
import TurtleGitCore

@main struct PrimaryDialogCapture {
    struct Failure:Error,CustomStringConvertible {let description:String}
    @MainActor static func wait(line:UInt = #line,_ ready:()->Bool) async throws {for _ in 0..<2000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Primary dialog capture timeout at line \(line)")}
    @MainActor static func png(_ window:NSWindow,_ file:URL) async throws {
        window.contentView?.layoutSubtreeIfNeeded();NSApp.activate(ignoringOtherApps:true);window.makeKeyAndOrderFront(nil);window.makeFirstResponder(nil)
        try await Task.sleep(nanoseconds:350_000_000)
        let capture=Process();capture.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");capture.arguments=["-x","-o","-l",String(window.windowNumber),file.path]
        let errors=Pipe();capture.standardError=errors;try capture.run();capture.waitUntilExit()
        guard capture.terminationStatus == 0,FileManager.default.fileExists(atPath:file.path) else {throw Failure(description:"Native compositor capture failed: "+String(decoding:errors.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self))}
        window.orderOut(nil)
    }
    @MainActor static func main() async {do {try await run()}catch {fputs("Primary capture failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func run() async throws {
        NSApp.setActivationPolicy(.accessory)
        let fixture=URL(fileURLWithPath:"/tmp/TurtleGit-Primary-"+UUID().uuidString.prefix(8)),root=fixture.appendingPathComponent("Harbor"),git=URL(fileURLWithPath:CommandLine.arguments[2])
        defer {try? FileManager.default.removeItem(at:fixture)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:git),output=URL(fileURLWithPath:ProcessInfo.processInfo.environment["TURTLEGIT_PREVIEW_CAPTURE_DIR"] ?? "build/qa/primary-dialog-captures-2026-10-14")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","TurtleGit Team"),("user.email","demo@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("tgit.commitstagingsupport","false"),("tgit.showpatch","false")] {_ = try await repo.run(["config",key,value])}
        for folder in ["Sources","Tests"] {try FileManager.default.createDirectory(at:root.appendingPathComponent(folder),withIntermediateDirectories:true)}
        let initial:[String:String]=["README.md":"# Harbor\n\nA native Git client example.\n","Sources/Repository.swift":"struct Repository {\n    var name = \"Harbor\"\n}\n","Sources/Colors.swift":"enum Colors {\n    static let status = \"blue\"\n}\n","Tests/RepositoryTests.swift":"func testRepository() {\n    // Sample test\n}\n",".gitignore":"*.ignored\n"]
        for (path,text) in initial {try Data(text.utf8).write(to:root.appendingPathComponent(path))};try await repo.stage(["."]);_ = try await repo.commit(message:"Create the Harbor project")
        let base=try await repo.rebaseCommit("HEAD");_ = try await repo.run(["switch","-c","feature/status-badges"])
        try Data("struct BadgePalette {\n    let modified = \"blue\"\n    let added = \"purple\"\n}\n".utf8).write(to:root.appendingPathComponent("Sources/BadgePalette.swift"));try await repo.stage(["."]);_ = try await repo.commit(message:"Add colorful status badges")
        _ = try await repo.run(["switch","main"]);try Data("# Harbor\n\nA native Git client example.\n\nInspect history with its compact commit graph.\n".utf8).write(to:root.appendingPathComponent("README.md"));try await repo.stage(["README.md"]);_ = try await repo.commit(message:"Describe the history view")
        _ = try await repo.run(["merge","--no-ff","feature/status-badges","-m","Merge native status badges\n\nKeep familiar colors and original icons in native macOS dialogs."])
        _ = try await repo.run(["tag","v0.1-preview"])
        try Data("# Harbor\n\nA native Git client example.\n\nInspect history with its compact commit graph.\n\nKeep the familiar Commit workflow on macOS.\n".utf8).write(to:root.appendingPathComponent("README.md"));try await repo.stage(["README.md"])
        try Data("# Harbor\n\nA native Git client example.\n\nInspect history with its compact commit graph.\n\nKeep the familiar Commit workflow on macOS.\nShow original status icons in Finder.\n".utf8).write(to:root.appendingPathComponent("README.md"))
        try Data("struct Repository {\n    var name = \"Harbor\"\n    var showsStatus = true\n}\n".utf8).write(to:root.appendingPathComponent("Sources/Repository.swift"))
        try FileManager.default.removeItem(at:root.appendingPathComponent("Tests/RepositoryTests.swift"))
        try Data("struct StatusBadge {\n    let title: String\n}\n".utf8).write(to:root.appendingPathComponent("Sources/StatusBadge.swift"))
        try Data("Private ignored example\n".utf8).write(to:root.appendingPathComponent("sample.ignored"))
        _ = try await repo.assignChangelist(paths:["Sources/Repository.swift"],name:"Native dialogs")
        _ = try await repo.assignChangelist(paths:["Tests/RepositoryTests.swift"],name:"ignore-on-commit")
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try await repo.run(["write-tree"]).stdout,status=try await repo.run(["status","--porcelain=v1","-z"]).stdout
        let suite="TurtleGit.PrimaryCaptures."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer {prefs.removePersistentDomain(forName:suite)}
        prefs.set(false,forKey:"EnableLogCache");prefs.set(false,forKey:"EnableGravatar");prefs.set(true,forKey:"ShowAppContextMenuIcons");prefs.set(12,forKey:"LogFontSize");prefs.set("Menlo",forKey:"LogFontName")
        prefs.set(true,forKey:"LogIncludeWorkingTreeChanges");prefs.set(false,forKey:"RelativeTimes");prefs.set(true,forKey:"UseSystemLocaleForDates")
        let commit=CommitWindowController(repository:repo,access:nil,defaults:prefs);defer {commit.close()};commit.model.confirmCancel={ $0(true) };commit.model.reload();try await wait {!commit.model.busy && commit.model.hasHead}
        commit.model.message="Improve repository status display\n\nKeep familiar colors and original icons in native Mac dialogs."
        commit.model.checked=["README.md","Sources/Repository.swift"]
        for (appearance,name) in [(NSAppearance.Name.aqua,"commit-current-light"),(.darkAqua,"commit-current-dark")] {commit.window!.appearance=NSAppearance(named:appearance);try await png(commit.window!,output.appendingPathComponent(name+".png"))}
        commit.model.stagingEnabled=true;commit.model.selection=["README.md"];commit.model.stagingChanged();commit.model.reload();try await wait {!commit.model.busy}
        for (appearance,name) in [(NSAppearance.Name.aqua,"staging-current-light"),(.darkAqua,"staging-current-dark")] {commit.window!.appearance=NSAppearance(named:appearance);try await png(commit.window!,output.appendingPathComponent(name+".png"))}
        commit.window!.appearance=NSAppearance(named:.aqua)
        commit.model.showPartial(false)
        try await wait {commit.partial?.model.busy == false}
        let patch=commit.partial!
        for (appearance,name) in [(NSAppearance.Name.aqua,"partial-staging-current-light"),(.darkAqua,"partial-staging-current-dark")] {commit.window!.appearance=NSAppearance(named:appearance);patch.window!.appearance=NSAppearance(named:appearance);commit.window!.orderOut(nil);try await png(patch.window!,output.appendingPathComponent(name+".png"))}
        patch.close();commit.close()
        let log=LogWindowController(repository:repo,access:nil,labelDefaults:prefs,savesColumnLayout:false,savesGeometry:false);defer {log.close()};log.model.reload();try await wait {!log.model.busy && !log.model.entries.isEmpty}
        let merge=log.model.entries.first {$0.parents.count == 2}!;log.model.select([merge.hash]);try await wait {!log.model.busy && log.model.fileGroups.count == 2}
        log.model.setChangedFileColumn(.removed,visible:true)
        for (appearance,name) in [(NSAppearance.Name.aqua,"log-current-light"),(.darkAqua,"log-current-dark")] {log.window!.appearance=NSAppearance(named:appearance);try await png(log.window!,output.appendingPathComponent(name+".png"))};log.close()
        let working=StatusWindowController(repository:repo,access:nil,defaults:prefs);defer {working.close()};working.model.reload();try await wait {!working.model.busy && !working.model.files.isEmpty}
        var filter=working.model.filter;filter.showIgnored=true;filter.showUnversioned=true;working.model.setFilter(filter);try await wait {!working.model.busy}
        for (appearance,name) in [(NSAppearance.Name.aqua,"working-tree-current-light"),(.darkAqua,"working-tree-current-dark")] {working.window!.appearance=NSAppearance(named:appearance);try await png(working.window!,output.appendingPathComponent(name+".png"))};working.close()
        let afterHead=try await repo.run(["rev-parse","HEAD"]).stdout,afterIndex=try await repo.run(["write-tree"]).stdout,afterStatus=try await repo.run(["status","--porcelain=v1","-z"]).stdout
        guard head == afterHead,index == afterIndex,status == afterStatus else {throw Failure(description:"Capture changed HEAD/index tree/working status")}
        _ = base
        print("Captured ten real current Commit/staging/partial staging/Log/Working Tree windows in light/dark. Private fixture/preferences; no Commit/apply actions; HEAD/index tree/status preserved; owned windows closed.")
    }
}
