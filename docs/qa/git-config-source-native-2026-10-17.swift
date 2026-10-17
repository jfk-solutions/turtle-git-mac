// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import ScreenCaptureKit
import TurtleGitCore

@main struct GitConfigSourceVerification {
    enum Failure:Error {case assertion(String),timeout(UInt)}
    @MainActor static func require(_ yes:Bool,_ message:String)throws {if !yes {throw Failure.assertion(message)}}
    @MainActor static func wait(line:UInt = #line,_ yes:()->Bool)async throws {for _ in 0..<2500 {if yes(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure.timeout(line)}
    @MainActor static func views(_ view:NSView?)->[NSView] {guard let view else {return []};return [view]+view.subviews.flatMap {views($0)}}
    @MainActor static func capture(_ window:NSWindow,to directory:URL)async throws {
        guard #available(macOS 14.4,*) else {throw Failure.assertion("Capture requires macOS 14.4")}
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        for (name,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:name);window.alphaValue=1;window.orderFront(nil);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
            try require(window.frame.height<=850,"Git config capture escaped production viewport")
            let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
            guard let own=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else {throw Failure.assertion("Capture owner missing")}
            let config=SCStreamConfiguration();config.width=Int(window.frame.width*2);config.height=Int(window.frame.height*2);config.showsCursor=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:own),configuration:config)
            guard let png=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else {throw Failure.assertion("PNG missing")}
            try png.write(to:directory.appendingPathComponent("git-config-source-"+suffix+".png"))
        };window.orderOut(nil);window.alphaValue=0
    }
    @MainActor static func main()async {NSApplication.shared.setActivationPolicy(.prohibited);do {try await verify();print("PASS Git config source: coherent source/origin/destination publication, failed-read retention, captured pre-write draft, owner editor preferences/late receipts, native hierarchy/mixed-state controls and retired callbacks")}catch {fputs("Git config source failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git,askpass:nil),fm=FileManager.default
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Config Source"),("user.email","config@example.invalid"),("commit.gpgsign","false")] {_=try await repo.run(["config",key,value])}
        try Data("sample\n".utf8).write(to:root.appendingPathComponent("sample.txt"));try await repo.stage(["sample.txt"]);_=try await repo.commit(message:"Config source sample")
        _=try await repo.run(["config","--global","user.name","Global Source"]);_=try await repo.run(["config","--global","user.email","global@example.invalid"])
        let index=try Data(contentsOf:root.appendingPathComponent(".git/index")),head=try await repo.run(["rev-parse","HEAD"]).stdout
        let suite="TurtleGit.ConfigSource."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(true,forKey:"HintHierarchicalConfig");prefs.set("/Applications/PrivateEditor.app",forKey:"TurtleGit.AlternativeEditor.Application")
        defer {prefs.removePersistentDomain(forName:suite);GitConfigurationPreviewFiles.discardAll()}
        let initial=GitConfigurationSettingsModel(preferences:prefs);initial.authorizeFile={_ in true};var initialReads:[GitConfigurationSource]=[]
        initial.readSettings={_,source,_ in initialReads.append(source);if initialReads.count==1 {throw Failure.assertion("first read failed")};return GitConfigurationSettings()}
        initial.activate(repository:repo,access:nil,localAvailable:true);try await wait {!initial.busy && initial.error != nil}
        initial.load(.effective);try await wait {initial.loaded && !initial.busy}
        try require(initial.source == .global && initial.destination == .global && !initial.draft.name.inherit && !initial.draft.email.inherit && initialReads==[.effective,.effective,.global],"Failed first load consumed source initial defaults")
        initial.deactivate()
        let model=GitConfigurationSettingsModel(preferences:prefs);model.authorizeFile={_ in true};defer {model.deactivate()}
        let owner=NSWindow(contentRect:NSRect(x:0,y:0,width:820,height:700),styleMask:[.titled,.closable],backing:.buffered,defer:false);owner.isReleasedWhenClosed=false;owner.alphaValue=0;owner.title="Git – Settings – TurtleGit";model.window=owner
        defer {model.deactivate();owner.contentView=nil;owner.close()}
        model.activate(repository:repo,access:nil,localAvailable:true);try await wait {model.loaded && !model.busy};model.load(.local);try await wait {model.loaded && !model.busy}
        let accepted=model.draft,oldGlobal=model.files?.global,reader=model.readSettings,source=model.source,destination=model.destination
        let originalGlobal=ProcessInfo.processInfo.environment["GIT_CONFIG_GLOBAL"]!,changedGlobal=root.appendingPathComponent("changed-global.config")
        try Data().write(to:changedGlobal);defer {setenv("GIT_CONFIG_GLOBAL",originalGlobal,1)}
        setenv("GIT_CONFIG_GLOBAL",changedGlobal.path,1)
        var read:CheckedContinuation<GitConfigurationSettings,Error>?
        model.readSettings={_,_,_ in try await withCheckedThrowingContinuation {read=$0}}
        model.load(.global);try await wait {read != nil}
        try require(model.busy && !model.loaded && model.loadingSource == .global && model.source==source && model.destination==destination && model.files?.global==oldGlobal && model.draft==accepted,"Pending read mixed accepted origins/source/draft")
        read?.resume(throwing:Failure.assertion("private failed read"));read=nil;try await wait {!model.busy}
        try require(!model.loaded && !model.editable && model.loadingSource==nil && model.source==source && model.destination==destination && model.files?.global==oldGlobal && model.draft==accepted && model.error != nil,"Failed read replaced accepted display or enabled Apply")
        var editorFiles:[URL]=[],editorPreferences:[Bool]=[],editorReplies:[GitConfigurationSettingsModel.EditorReply]=[]
        model.openEditor={url,defaults,_,reply in editorFiles.append(url);editorPreferences.append(defaults === prefs);editorReplies.append(reply)}
        model.editConfiguration(.local);try require(editorFiles.isEmpty,"Failed context edited an old config path")
        setenv("GIT_CONFIG_GLOBAL",originalGlobal,1);model.readSettings=reader;model.load(.global);try await wait {model.loaded && !model.busy}
        try require(model.source == .global && model.destination == .global && model.files?.global?.path==originalGlobal && model.draft.name.value=="Global Source","Successful read did not publish one coherent source")
        model.editConfiguration(.global);try await wait {editorFiles.count==1 && !model.busy}
        try require(editorPreferences==[true] && editorFiles[0].path==originalGlobal,"Config editor ignored owner preferences/path")
        model.load(.local);try await wait {model.loaded && !model.busy};editorReplies[0]("stale editor failure");try require(model.error==nil,"Old config editor reported on a new level")
        model.viewConfiguration(.local);try await wait {model.configurationText != nil && !model.busy};model.openDisplayedConfiguration()
        try require(editorFiles.count==2 && editorPreferences.allSatisfy {$0},"Displayed config editor used global preferences")
        model.configurationText="replacement displayed config";editorReplies[1]("old displayed editor failure");try require(model.error==nil,"Old displayed-text receipt reported on replacement")
        model.configurationText=nil
        // Native confirmation occurs before the authorized write starts.
        var writes=0;let writer=model.writeSettings
        model.writeSettings={repo,value,destination in writes += 1;try await writer(repo,value,destination)}
        model.draft.name = .init(value:"Before confirmation",inherit:false);model.destination = .global
        let applying=Task {await model.applyForSettings(owner:owner)};try await wait {owner.attachedSheet != nil}
        try require(GitConfigurationSettingsModel.activeSaves==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Confirmation lost write/Quit lifetime")
        model.draft.name.value="Changed during confirmation"
        owner.endSheet(owner.attachedSheet!,returnCode:.alertSecondButtonReturn)
        let result=await applying.value
        try require(!result && writes==0 && model.draft.name.value=="Changed during confirmation" && model.error?.contains("draft changed")==true,"Changed confirmation draft was written")
        model.cancelDraft();model.load(.local);try await wait {model.loaded && !model.busy}
        model.draft.name = .init(value:"Saved config source",inherit:false);model.draft.autoCRLF="input";model.draft.safeCRLF="warn";model.draft.quotePath = .inherit;model.draft.prune = .enabled
        let saved=await model.applyForSettings(owner:owner);try require(saved && writes==1 && !model.changed,"Valid captured source draft did not save")
        let stored=try await repo.gitConfiguration(source:.local);try require(stored.name.value=="Saved config source" && stored.autoCRLF=="input" && stored.safeCRLF=="warn" && stored.quotePath == .inherit && stored.prune == .enabled,"Source fields changed in private Git save")
        let acceptedWriter=model.writeSettings
        var returnWrite:CheckedContinuation<Void,Never>?
        model.draft.name.value="Returned page";model.deactivate()
        model.writeSettings={repo,value,destination in await withCheckedContinuation {returnWrite=$0};try await acceptedWriter(repo,value,destination)}
        let returning=Task {await model.applyForSettings(owner:owner)};try await wait {returnWrite != nil}
        model.activate(repository:repo,access:nil,localAvailable:true);returnWrite?.resume();returnWrite=nil
        let returned=await returning.value
        try require(returned && model.isActive && model.loaded && !model.busy && model.draft.name.value=="Returned page","Hidden Apply completion deactivated the returned page")
        model.writeSettings=acceptedWriter
        model.authorizeConfigurationFolder();try await wait {owner.attachedSheet != nil}
        try require(model.authorizingFolder && GitConfigurationSettingsModel.activeFolderChoosers==1 && TurtleGitApplicationDelegate().applicationShouldTerminate(NSApp) == .terminateCancel,"Recovery folder chooser lost independent Quit ownership")
        model.deactivate();try await wait {owner.attachedSheet==nil && GitConfigurationSettingsModel.activeFolderChoosers==0};model.activate(repository:repo,access:nil,localAvailable:true)
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false);workspace.settingsContextOverride=(repo,nil,true)
        let transaction=SettingsTransaction(),host=NSHostingView(rootView:GitConfigurationSettingsPage(workspace:workspace,preferences:prefs,model:model).environment(\.settingsTransaction,transaction).defaultAppStorage(prefs))
        let viewport=SettingsPageViewport(frame:owner.contentLayoutRect);viewport.autoresizingMask=[.width,.height];owner.contentView=viewport;viewport.pageDocument.addSubview(host);host.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo:viewport.pageDocument.leadingAnchor),host.trailingAnchor.constraint(equalTo:viewport.pageDocument.trailingAnchor),host.topAnchor.constraint(equalTo:viewport.pageDocument.topAnchor),host.bottomAnchor.constraint(equalTo:viewport.pageDocument.bottomAnchor)])
        defer {transaction.invalidate();owner.contentView=nil}
        viewport.layoutSubtreeIfNeeded();host.layoutSubtreeIfNeeded();try await wait {views(host).compactMap {$0 as? NSButton}.contains {$0.title=="QuotePath"}}
        let quote=views(host).compactMap {$0 as? NSButton}.first {$0.title=="QuotePath"}!,prune=views(host).compactMap {$0 as? NSButton}.first {$0.title=="Prune"}!
        try require(quote.state == .mixed && prune.state == .on && quote.allowsMixedState && prune.allowsMixedState && quote.frame.height<=30 && prune.frame.height<=30,"Source mixed-state controls missing or stretched")
        // SwiftUI editor buttons are not NSButton descendants in this passive
        // host. Verify column/background geometry in the raw captures instead.
        let radios=views(host).compactMap {$0 as? NSButton}.filter {GitConfigurationSource.allCases.map(\.rawValue).contains($0.title)}
        try require(radios.count==4 && radios.first {$0.title=="Local"}?.state == .on,"Source hierarchy radio row missing")
        model.deactivate();try await wait {!quote.isEnabled};model.activate(repository:repo,access:nil,localAvailable:true);try await wait {quote.isEnabled}
        if let output=ProcessInfo.processInfo.environment["TURTLEGIT_GIT_CONFIG_CAPTURE"] {try await capture(owner,to:URL(fileURLWithPath:output))}
        let oldTarget=quote.target as? NSObject,oldAction=quote.action,oldDraft=model.draft
        owner.contentView=nil;try await wait {!model.isActive};model.activate(repository:repo,access:nil,localAvailable:true)
        quote.state = .off;if let oldTarget,let oldAction {_=oldTarget.perform(oldAction,with:quote)}
        try require(model.draft==oldDraft,"Retired checkbox changed reopened configuration")
        let finalHead=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(finalHead==head && (try Data(contentsOf:root.appendingPathComponent(".git/index")))==index && GitConfigurationSettingsModel.activeReads==0 && GitConfigurationSettingsModel.activeSaves==0 && GitConfigurationSettingsModel.activeFolderChoosers==0,"Config source changed Git history/index or leaked operations")
    }
}
