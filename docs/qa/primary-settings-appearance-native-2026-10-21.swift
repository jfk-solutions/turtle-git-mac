// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import TurtleGitCore

private actor PrimarySettingsSMTPStore:SMTPCredentialStore {
    func login()async throws->String {""}
    func store(login:String,password:String)async throws {}
    func clear()async throws {}
}
@MainActor enum PrimarySettingsAppearanceVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:UInt = #line)throws {if !value {throw Failure(description:"\(line): \(message)")}}
    static func views(_ view:NSView?)->[NSView] {guard let view else{return []};return [view]+view.subviews.flatMap{views($0)}}
    static func wait(_ message:String,line:UInt = #line,_ ready:()->Bool)async throws {
        for _ in 0..<2400 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"\(line): \(message)")
    }
    static func button(_ window:NSWindow,_ title:String)throws->NSButton {
        guard let button=views(window.contentView).compactMap({$0 as? NSButton}).first(where:{$0.title==title}) else {throw Failure(description:"Missing native Settings button: "+title)}
        return button
    }
    static func theme(_ window:NSWindow)throws->NSButton {
        guard let button=views(window.contentView).compactMap({$0 as? NSButton}).first(where:{$0.identifier?.rawValue=="Settings.Colors1.DarkTheme"}) else {throw Failure(description:"Missing native theme checkbox")};return button
    }
    static func dark(_ appearance:NSAppearance)->Bool {appearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua}
    static func idle()->Bool {
        SettingsTransaction.activeApplications==0 && SettingsTransaction.activeRetirements==0 && GitConfigurationSettingsModel.activeReads==0 && GitConfigurationSettingsModel.activeSaves==0 && GitConfigurationSettingsModel.activeSheetReleases==0 && ProjectDialogSettingsModel.activeReads==0 && ProjectDialogSettingsModel.activeSaves==0
    }
    @MainActor final class Context {
        let suite="TurtleGit.PrimarySettings."+UUID().uuidString,preferences:UserDefaults
        let originalAppearance=NSApp.appearance
        var windows:[NSWindow]=[],navigations:[SettingsNavigationController]=[],cleanupModels:[()->Void]=[]
        init(){preferences=UserDefaults(suiteName:suite)!;preferences.set("light",forKey:"appearance");preferences.set(false,forKey:"VersionCheck");preferences.set(true,forKey:"HintHierarchicalConfig")}
        func track(_ window:NSWindow)->NSWindow {windows.append(window);window.isReleasedWhenClosed=false;window.alphaValue=0;window.setFrameOrigin(.init(x:-12000,y:-12000));window.orderFront(nil);return window}
        func navigation(_ workspace:RepositoryModel,_ appearance:AppAppearance,page:SettingsPageID)->(SettingsNavigationController,NSWindow) {
            let navigation=SettingsNavigationController(workspace:workspace,appearance:appearance,preferences:preferences,initialPage:page,smtpCredentials:PrimarySettingsSMTPStore())
            let window=NSWindow(contentRect:.init(x:0,y:0,width:1040,height:740),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            window.contentViewController=navigation;navigations.append(navigation);_=track(window);navigation.viewDidAppear();navigation.view.layoutSubtreeIfNeeded();return(navigation,window)
        }
        func cleanup()async {
            navigations.forEach{$0.invalidate()};cleanupModels.forEach{$0()}
            windows.forEach{$0.close();$0.contentViewController=nil;$0.orderOut(nil)}
            for _ in 0..<2400 {if idle(){break};try? await Task.sleep(nanoseconds:10_000_000)}
            preferences.removePersistentDomain(forName:suite);NSApp.appearance=originalAppearance
        }
    }
    static func run(root:URL,git:URL)async throws {
        let context=Context(),prefs=context.preferences
        do {
            let directory=root.appendingPathComponent("primary-settings",isDirectory:true);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let repo=GitRepository(root:directory,executable:git)
            _=try await repo.run(["init","-b","main"])
            for(key,value)in[("user.name","Settings fixture"),("user.email","settings@example.invalid"),("core.hooksPath","/dev/null"),("commit.gpgsign","false")] {_=try await repo.run(["config",key,value])}
            let source=directory.appendingPathComponent("source.txt"),bytes=Data("unchanged\n".utf8);try bytes.write(to:source);try await repo.stage(["source.txt"]);_=try await repo.commit(message:"Settings baseline")
            let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:directory.appendingPathComponent(".git/index"))
            let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)})
            workspace.settingsContextOverride=(repo,nil,true)
            let appearance=AppAppearance(preferences:prefs);appearance.apply()

            // First page is Colors1: General has never registered a participant.
            let(cancelNavigation,cancelWindow)=context.navigation(workspace,appearance,page:.colors1)
            try await wait("Direct Colors1 did not render"){views(cancelWindow.contentView).contains{($0 as? NSButton)?.identifier?.rawValue=="Settings.Colors1.DarkTheme"}}
            let canceledTheme=try theme(cancelWindow),retainedTarget=canceledTheme.target,retainedAction=canceledTheme.action
            canceledTheme.performClick(nil)
            try await wait("Unsaved theme failed to preview/mark Settings modified"){cancelNavigation.transaction.modified && dark(cancelWindow.effectiveAppearance)}
            try require(prefs.string(forKey:"appearance")=="light" && appearance.choice == .light,"Preview persisted before Apply")
            try await PrimaryParityCapture.save(cancelWindow,"settings-colors1-dark-draft")
            try button(cancelWindow,"Cancel").performClick(nil)
            try await wait("Cancel did not close/restore live appearance"){!cancelNavigation.canDismiss && !dark(NSApp.effectiveAppearance) && !cancelWindow.isVisible}
            try require(prefs.string(forKey:"appearance")=="light","Cancel saved the theme")
            try await wait("Canceled settings retirement did not drain"){idle()}
            if let retainedAction {canceledTheme.state = .on;_=NSApp.sendAction(retainedAction,to:retainedTarget,from:canceledTheme)}
            try require(!dark(NSApp.effectiveAppearance) && prefs.string(forKey:"appearance")=="light","Retired theme control revived global preview")

            let(navigation,window)=context.navigation(workspace,appearance,page:.colors1)
            try await wait("Second Colors1 did not render"){views(window.contentView).contains{($0 as? NSButton)?.identifier?.rawValue=="Settings.Colors1.DarkTheme"}}
            try theme(window).performClick(nil)
            try await wait("Theme draft did not register"){navigation.transaction.modified}
            try button(window,"Apply").performClick(nil)
            try await wait("Direct Colors Apply did not save"){!navigation.transaction.busy && prefs.string(forKey:"appearance")=="dark" && !navigation.transaction.modified}
            try require(appearance.choice == .dark,"Direct Colors Apply did not update application appearance")
            try theme(window).performClick(nil)
            try await wait("Second appearance draft was not owned"){navigation.transaction.modified && !dark(window.effectiveAppearance)}
            navigation.requestCommandPage(.general)
            try await wait("General did not display"){navigation.selected == .general}
            try button(window,"Apply").performClick(nil)
            try await wait("General visit replaced appearance participant identity"){!navigation.transaction.busy && !navigation.transaction.modified && prefs.string(forKey:"appearance")=="light"}
            try require(navigation.transaction.error==nil,"Cached General/Colors appearance registration failed")

            navigation.requestCommandPage(.colors3)
            try await wait("Graph palette controls did not render"){views(window.contentView).contains{$0 is SettingsGraphPreviewView}}
            guard let preview=views(window.contentView).compactMap({$0 as? SettingsGraphPreviewView}).first,
                  let well=views(window.contentView).compactMap({$0 as? MergeColorChoiceView}).first(where:{$0.identifier?.rawValue=="LogColors.BranchLine1"}) else {throw Failure(description:"Missing actual graph draft preview/swatch")}
            let stored=LogColorPreferences.load(prefs)
            well.well.color=NSColor(srgbRed:0x12/255.0,green:0x34/255.0,blue:0x56/255.0,alpha:1)
            try require(NSApp.sendAction(well.well.action!,to:well.well.target,from:well.well),"Graph RGB action did not route")
            try await wait("Unsaved RGB did not reach graph preview"){preview.palette.rgb(.branchLine1)==[18,52,86] && navigation.transaction.modified}
            try require(LogColorPreferences.load(prefs)==stored,"Color preview wrote preference storage")
            for(count,value)in[(10,6),(30,20)] {
                guard let popup=views(window.contentView).compactMap({$0 as? NSPopUpButton}).first(where:{$0.itemTitles==(1...count).map{String($0)}}),let action=popup.action else {throw Failure(description:"Missing source graph dimension popup; actual menus: \(views(window.contentView).compactMap{($0 as? NSPopUpButton)?.itemTitles})")}
                popup.selectItem(at:value-1);try require(NSApp.sendAction(action,to:popup.target,from:popup),"Graph dimension action did not route")
            }
            try await wait("Unsaved dimensions did not reach graph drawing"){preview.palette.lineWidth==6 && preview.palette.nodeSize==20}
            try await PrimaryParityCapture.save(window,"settings-colors3-draft")
            navigation.transaction.cancel()
            try await wait("Cancel did not restore graph preview"){preview.palette==stored && !navigation.transaction.modified}
            try button(window,"Restore Default").performClick(nil)
            try await wait("Restore did not restore source graph dimensions"){preview.palette.lineWidth==2 && preview.palette.nodeSize==10}
            try button(window,"Cancel").performClick(nil)
            try await wait("Settings Cancel did not close"){!window.isVisible && !navigation.canDismiss}
            try await wait("Settings retirement did not drain"){idle()}

            // Actual source-level and inherit models remain functional after
            // changing only their native layout/grouping.
            let gitModel=GitConfigurationSettingsModel(preferences:prefs)
            context.cleanupModels.append{gitModel.deactivate()}
            let gitWindow=NSWindow(contentRect:.init(x:0,y:0,width:760,height:650),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            let gitHost=NSHostingController(rootView:GitConfigurationSettingsPage(workspace:workspace,preferences:prefs,model:gitModel));gitHost.sizingOptions=[]
            gitWindow.contentViewController=gitHost;gitWindow.setContentSize(.init(width:760,height:650));_=context.track(gitWindow)
            try await wait("Git source form did not load"){gitWindow.contentView?.layoutSubtreeIfNeeded();return gitModel.loaded && !gitModel.busy}
            let gitSources=views(gitWindow.contentView).compactMap{$0 as? NSButton}.filter{$0.identifier?.rawValue.hasPrefix("ReferenceForm.")==true}
            try require(gitSources.count==4,"Git source hierarchy lost native radio controls")
            gitModel.load(.local);try await wait("Local Git source did not load"){gitModel.source == .local && !gitModel.busy}
            gitModel.draft.name = .init(value:"Changed settings identity",inherit:false)
            try require(await gitModel.applyForSettings(owner:gitWindow),"Local identity save failed")
            try require(try await repo.run(["config","--local","user.name"]).text.trimmingCharacters(in:.whitespacesAndNewlines)=="Changed settings identity","Local scoped value was not saved")
            gitModel.draft.name.inherit=true
            try require(await gitModel.applyForSettings(owner:gitWindow),"Local inherited identity save failed")
            try require(try await repo.run(["config","--local","--get","user.name"],successfulExitCodes:0...1).exitCode==1,"inherit failed to unset the local identity")
            try await PrimaryParityCapture.save(gitWindow,"settings-git-source-inherit")
            gitModel.deactivate();gitWindow.close();gitWindow.contentViewController=nil

            let project=ProjectDialogSettingsModel(preferences:prefs);context.cleanupModels.append{project.invalidate()}
            let projectWindow=NSWindow(contentRect:.init(x:0,y:0,width:760,height:650),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            let projectHost=NSHostingController(rootView:ProjectDialogSettingsPage(workspace:workspace,preferences:prefs,model:project));projectHost.sizingOptions=[]
            projectWindow.contentViewController=projectHost;projectWindow.setContentSize(.init(width:760,height:650));_=context.track(projectWindow)
            try await wait("Dialogs3 source form did not load"){projectWindow.contentView?.layoutSubtreeIfNeeded();return project.loaded && !project.busy}
            let projectSources=views(projectWindow.contentView).compactMap{$0 as? NSButton}.filter{$0.identifier?.rawValue.hasPrefix("ReferenceForm.")==true}
            try require(projectSources.count==5,"Dialogs3 source hierarchy lost Project or inherit controls")
            project.load(.project);try await wait("Project source did not load"){project.source == .project && !project.busy}
            project.draft.minimumMessageLength = .init(value:"7",inherit:false)
            try require(await project.apply(owner:projectWindow),"Project scoped settings save failed")
            let projectFile=directory.appendingPathComponent(".tgitconfig")
            try require(try String(contentsOf:projectFile).contains("minsize"),"Dialogs3 did not save project config")
            project.draft.minimumMessageLength = .init(value:"12",inherit:false);project.cancel()
            try require(project.draft.minimumMessageLength.value=="7","Dialogs3 Cancel lost saved value")
            try await PrimaryParityCapture.save(projectWindow,"settings-dialogs3-scoped")
            project.invalidate();projectWindow.close();projectWindow.contentViewController=nil
            try require(try await repo.run(["rev-parse","HEAD"]).stdout==head && Data(contentsOf:directory.appendingPathComponent(".git/index"))==index && Data(contentsOf:source)==bytes,"Settings changed HEAD/index/worktree source bytes")
            await context.cleanup();try require(idle(),"Settings workers/retirements did not drain")
        }catch{await context.cleanup();throw error}
    }
}
