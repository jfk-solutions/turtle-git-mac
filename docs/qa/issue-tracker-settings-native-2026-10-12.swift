import AppKit
import SwiftUI
import TurtleGitCore

@main struct IssueTrackerSettingsVerification {
    @MainActor static func main() async {do{try await verify()}catch{fputs("Issue Settings failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify() async throws {
        func require(_ value:Bool,_ message:String)throws{if !value{throw NSError(domain:message,code:1)}}
        func wait(_ ready:()->Bool)async throws{for _ in 0..<1000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw NSError(domain:"Issue Settings did not settle",code:1)}
        try require(MenuIcon.settingsIssueTracker.image() != nil,"Original Bugtraq icon did not decode")
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _=try await repo.run(["init","-b","main"]);_=try await repo.run(["config","user.name","retained"])
        let model=IssueTrackerSettingsModel(),workspace=RepositoryModel(startMonitoring:false),transaction=SettingsTransaction()
        model.authorizeFile={_ in true};model.confirmSavingTo={_ in true}
        model.regexExecutable=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/IssueRegex/issue-regex")
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:840,height:760),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
        let host=NSHostingView(rootView:IssueTrackerSettingsPage(workspace:workspace,model:model,contextProvider:{(repo,nil,true)}).environment(\.settingsTransaction,transaction));window.contentView=host;host.layoutSubtreeIfNeeded()
        defer{model.invalidate();transaction.invalidate();window.contentView=nil;window.close()}
        try await wait{model.loaded && !model.busy}
        try require(model.source == .effective && !model.editable && !model.modified,"Effective read-only defaults differ")
        model.load(.local);try await wait{model.loaded && !model.busy}
        try require(model.editable && model.draft.fields.values.allSatisfy(\.inherit) && model.draft.number == .inherit,"Scoped inheritance differs")
        model.draft.fields[.url]=GitConfigurationIdentity(value:"https://issues.invalid/%BUGID%",inherit:false)
        model.draft.fields[.message]=GitConfigurationIdentity(value:"Refs %BUGID%",inherit:false)
        model.draft.fields[.label]=GitConfigurationIdentity(value:"Ticket",inherit:false)
        model.draft.fields[.regex]=GitConfigurationIdentity(value:"#([0-9]+)",inherit:false)
        model.draft.fields[.provider32]=GitConfigurationIdentity(value:"{interop32}",inherit:false)
        model.draft.number = .disabled;model.draft.warnIfNoIssue = .enabled
        try await wait{transaction.modified};transaction.apply(closeAfter:false);try await wait{!transaction.busy && !model.busy}
        let properties=try await repo.issueTrackerProperties()
        try require(transaction.error==nil && !model.modified && properties.label=="Ticket" && properties.warnIfNoIssue && !properties.numbersOnly,"Shared Apply/Commit reader differs")
        for appearance in [NSAppearance.Name.aqua,.darkAqua]{host.appearance=NSAppearance(named:appearance);host.layoutSubtreeIfNeeded()}
        model.destination = .project;try await wait{transaction.modified};transaction.cancel()
        try require(model.destination == .local && !model.modified,"Destination-only Cancel differs")
        var child:IssueRegexTesterController?,presentations=0
        model.presentTester={controller,_ in child=controller;presentations += 1;return true}
        let configBefore=try Data(contentsOf:root.appendingPathComponent(".git/config"))
        model.testRegex();model.testRegex();try require(model.hasTester && !model.editable && presentations==1,"Tester ownership/duplicate gate differs")
        model.load(.global);try require(model.source == .local,"Source change escaped owned Tester")
        child!.model.check=" #[0-9]+ ";child!.model.extract=" [0-9]+ ";child!.finish(accept:true)
        try require(!model.hasTester && model.modified && model.draft.fields[.regex]?.value=="#[0-9]+\n[0-9]+" && (try Data(contentsOf:root.appendingPathComponent(".git/config")))==configBefore,"Tester OK saved early or lost expressions")
        transaction.cancel();try require(model.draft.fields[.regex]?.value=="#([0-9]+)" && !model.modified,"Parent Cancel retained preview draft")
        model.testRegex();child!.model.check="discarded";child!.finish(accept:false)
        try require(!model.hasTester && !model.modified,"Tester Cancel changed parent")
        model.destination = .global;let copied=await model.apply(owner:window)
        let global=try await repo.issueTrackerSettings(source:.global)
        try require(copied && global.fields[.url]?.value=="https://issues.invalid/%BUGID%" && !model.modified,"Destination copy did not save")
        model.draft.fields[.label]=GitConfigurationIdentity(value:"bad\0field",inherit:false)
        transaction.apply(closeAfter:false);try await wait{!transaction.busy};try require(transaction.error != nil && model.modified,"NUL draft accepted")
        transaction.cancel()
        model.draft.fields[.label]=GitConfigurationIdentity(value:"held save",inherit:false);model.destination = .project
        var answer:CheckedContinuation<Bool,Never>?
        model.confirmSavingTo={_ in await withCheckedContinuation{answer=$0}}
        let save=Task{await model.apply(owner:window)};try await wait{answer != nil}
        try require(IssueTrackerSettingsModel.activeSaves==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApplication.shared) == .terminateCancel,"Captured save did not fence Quit")
        model.invalidate();answer?.resume(returning:true);let saved=await save.value
        try require(!saved && !model.active && IssueTrackerSettingsModel.activeSaves==0 && !FileManager.default.fileExists(atPath:root.appendingPathComponent(".tgitconfig").path),"Late Save confirmation wrote/reactivated retired page")
        try await wait{IssueRegexTesterModel.activeRequests==0}
        print("Issue Settings: Effective/scoped inheritance, source fields/provider preservation, private real Git Apply/Commit reader, destination-only Cancel/copy, owned Tester OK/Cancel/draft-only/duplicate/source gates, light-dark hosts, validation and held-save retirement/Quit fences passed. Private config; no tracker plugin or general clipboard.")
    }
}
