import AppKit
import SwiftUI
import TurtleGitCore

struct IssueTrackerCapture {
    @MainActor static func main() async {do{try await capture()}catch{fputs("Issue capture failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func capture() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _=try await repo.run(["init","-b","main"])
        let suite="TurtleGit.IssueCapture."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,clipboard=NSPasteboard(name:NSPasteboard.Name("TurtleGit.IssueCapture."+UUID().uuidString))
        defer{prefs.removePersistentDomain(forName:suite);clipboard.clearContents()}
        let output=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/qa/issue-tracker-captures-2026-10-12")
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        func wait(_ ready:()->Bool)async throws{for _ in 0..<1000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw NSError(domain:"Capture did not settle",code:1)}
        func png(_ window:NSWindow,_ name:String)async throws {
            window.contentView?.layoutSubtreeIfNeeded();NSApplication.shared.activate(ignoringOtherApps:true);window.makeKeyAndOrderFront(nil);window.makeFirstResponder(nil)
            try await Task.sleep(nanoseconds:300_000_000)
            let file=output.appendingPathComponent(name+".png")
            let capture=Process();capture.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture")
            capture.arguments=["-x","-o","-l",String(window.windowNumber),file.path]
            let errors=Pipe();capture.standardError=errors
            try capture.run();capture.waitUntilExit()
            guard capture.terminationStatus==0,FileManager.default.fileExists(atPath:file.path) else{throw NSError(domain:"Window compositor capture unavailable: \(String(decoding:errors.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self))",code:1)}
            window.orderOut(nil)
        }
        let model=IssueTrackerSettingsModel(),workspace=RepositoryModel(startMonitoring:false),transaction=SettingsTransaction()
        model.authorizeFile={_ in true}
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:820,height:780),styleMask:[.titled,.closable],backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.title="Issue Tracker Config – TurtleGit for Mac"
        let page=IssueTrackerSettingsPage(workspace:workspace,model:model,contextProvider:{(repo,nil,true)}).environment(\.settingsTransaction,transaction)
        let host=NSHostingView(rootView:VStack(spacing:0){page;Divider();HStack{Spacer();Button("OK"){transaction.apply(closeAfter:true)};Button("Cancel"){transaction.cancel();window.close()};Button("Apply"){transaction.apply(closeAfter:false)}}.padding(12)})
        window.contentView=host;host.frame=window.contentLayoutRect;host.layoutSubtreeIfNeeded()
        defer{model.invalidate();transaction.invalidate();window.contentView=nil;window.close()}
        try await wait{model.loaded && !model.busy};model.load(.local);try await wait{model.loaded && !model.busy}
        model.draft.fields[.url]=GitConfigurationIdentity(value:"https://issues.example/%BUGID%",inherit:false)
        model.draft.fields[.message]=GitConfigurationIdentity(value:"References issue %BUGID%",inherit:false)
        model.draft.fields[.label]=GitConfigurationIdentity(value:"Ticket:",inherit:false)
        model.draft.fields[.regex]=GitConfigurationIdentity(value:"#[0-9]+\n[0-9]+",inherit:false)
        model.draft.number = .enabled;model.draft.append = .enabled;model.draft.warnIfNoIssue = .enabled
        for (appearance,name) in [(NSAppearance.Name.aqua,"issue-tracker-config-light"),(.darkAqua,"issue-tracker-config-dark")] {
            window.appearance=NSAppearance(named:appearance);host.appearance=window.appearance;try await png(window,name)
        }
        let helper=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/IssueRegex/issue-regex")
        let matcher=IssueRegexTesterModel(check:"#[0-9]+",extract:"[0-9]+",executable:helper,preferences:prefs,clipboard:clipboard),tester=IssueRegexTesterController(model:matcher)
        defer{tester.close()}
        try await wait{!matcher.busy && !matcher.ranges.isEmpty}
        for (appearance,name) in [(NSAppearance.Name.aqua,"issue-regex-tester-light"),(.darkAqua,"issue-regex-tester-dark")] {
            tester.window!.appearance=NSAppearance(named:appearance);tester.window!.contentView?.appearance=tester.window!.appearance;try await png(tester.window!,name)
        }
        tester.close();try await wait{IssueRegexTesterModel.activeRequests==0}
        print("Captured actual native Issue Tracker page and Regex Tester content in light/dark. Private config/drafts only; windows and helper work retired.")
    }
}
