import AppKit
import SwiftUI
import TurtleGitCore

struct HookSettingsFamilyVerification {
    @MainActor static func verify() async throws {
        func require(_ value:Bool,_ text:String)throws {if !value{throw NSError(domain:text,code:1)}}
        func wait(_ text:String,_ value:()->Bool)async throws {for _ in 0..<2000{if value(){return};try await Task.sleep(nanoseconds:10_000_000)};throw NSError(domain:text,code:2)}
        let root=URL(fileURLWithPath:CommandLine.arguments[1]), git=URL(fileURLWithPath:CommandLine.arguments[2])
        let folder=root.appendingPathComponent("settings-family");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let repo=GitRepository(root:folder,executable:git);_ = try await repo.run(["init","-b","main"])
        let suite="TurtleGit.HookSettings.Family."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer{prefs.removePersistentDomain(forName:suite)}
        let model=HookSettingsModel(preferences:prefs), owner=NSWindow(contentRect:NSRect(x:-12000,y:-12000,width:1050,height:650),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        owner.isReleasedWhenClosed=false;owner.alphaValue=0;owner.appearance=NSAppearance(named:.darkAqua)
        owner.contentViewController=NSHostingController(rootView:HookSettingsPage(model:model,repository:repo,access:nil))
        defer{model.invalidate();owner.orderOut(nil);owner.close()}
        model.window=owner;model.activate(repository:repo,access:nil);try await wait("Settings read did not finish"){model.loaded && !model.busy}
        var editor:HookConfigurationController?
        model.configureEditor={editor=$0};model.configure(add:true)
        try await wait("Add sheet did not attach"){editor?.window?.sheetParent===owner}
        let add=editor!
        try require(add.draft.selectedType==nil && add.draft.hook.path.isEmpty && !add.draft.hook.enabled,"Add lost source unselected/blank/disabled defaults")
        try require(add.draft.hook.wait && add.draft.hook.show,"Add lost source Wait/Show defaults")
        add.accept();try require(!add.answered && add.draft.error != nil,"Unselected Add was accepted")
        add.draft.selectType(.preCommit);add.draft.hook.command="/bin/true";add.draft.hook.path=folder.appendingPathComponent("missing").path
        add.accept();try require(!add.answered,"Missing folder was accepted")
        let file=folder.appendingPathComponent("ordinary-file");try Data().write(to:file)
        add.draft.hook.path=file.path;add.accept();try require(!add.answered,"Regular file was accepted as working tree folder")
        add.draft.hook.path="*";add.draft.setLocal(true)
        try require(add.draft.hook.path=="*" && (try add.draft.acceptedValue()).path==folder.path,"Local scope lost retained global draft or exact repository path")
        add.draft.setLocal(false);try require(add.draft.hook.path=="*","Returning to global discarded draft")
        add.accept();try await wait("Add sheet did not release"){!model.hasEditor && owner.attachedSheet==nil && HookConfigurationController.activeReleases==0}
        try require(model.hooks.count==1 && model.modified && prefs.string(forKey:"hooks")==nil,"Add wrote settings before Apply")
        let original=model.hooks[0];model.selection=[original.id];editor=nil;model.configure(copy:true)
        try await wait("Copy did not attach"){editor?.window?.sheetParent===owner};let copy=editor!
        try require(copy.draft.hook.path.isEmpty && copy.draft.selectedType==original.type && copy.draft.hook.command==original.command && copy.draft.hook.enabled==original.enabled,"Copy did not preserve flags/type/command while clearing path")
        copy.draft.hook.path=folder.path;copy.accept();try await wait("Copy did not detach"){!model.hasEditor && owner.attachedSheet==nil}
        try require(model.hooks.count==2 && model.hooks.contains{$0.id==original.id},"Copy replaced original")
        try require(await model.apply(),"Shared hook Apply failed")
        try require(ClientHookPreferences.globals(prefs).count==2 && !model.modified,"Apply did not persist both hooks")
        model.selection=[original.id];model.remove();model.cancel();try require(model.hooks.count==2 && !model.modified,"Cancel did not restore saved list")
        // Invoke the actual table's double action with a selected row, independent
        // of which of its five cells receives the double click.
        func tables(_ view:NSView)->[NSTableView]{(view as? NSTableView).map{[$0]} ?? view.subviews.flatMap(tables)}
        owner.contentView?.layoutSubtreeIfNeeded()
        try await wait("Native hook table missing"){owner.contentView.map{tables($0).first?.numberOfRows==2} ?? false}
        let table=tables(owner.contentView!)[0]
        try require(table.tableColumns.count==5 && table.numberOfRows==2,"Hook table did not expose five source columns and both rows")
        try require(table.doubleAction != nil && table.target != nil,"Whole-row Edit action missing")
        table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try require(NSApp.sendAction(table.doubleAction!,to:table.target,from:table),"Native whole-row double action was not dispatched")
        try await wait("Selected-row Edit missing"){model.hasEditor};editor?.finish(nil)
        try await wait("Edit remained attached"){!model.hasEditor && owner.attachedSheet==nil}
        model.configure(add:true);try await wait("Picker owner missing"){editor?.window?.sheetParent===owner};let browse=editor!
        var callback:((NSApplication.ModalResponse)->Void)?, chooser:NSOpenPanel?
        browse.presentBrowse={panel,parent,reply in chooser=panel;callback=reply;parent.beginSheet(panel,completionHandler:nil)}
        browse.selectedBrowseURL={_ in folder};browse.browse(command:false)
        try await wait("Folder chooser did not attach"){chooser?.sheetParent===browse.window}
        try require(browse.draft.choosing && HookConfigurationController.activeChoosers==1 && chooser?.alphaValue==0 && chooser?.appearance?.name==owner.appearance?.name,"Chooser lost ownership, invisibility or appearance")
        let beforeFolderRevision=browse.draft.revision
        callback?(.OK);callback?(.OK)
        try await wait("Chooser did not physically detach"){!browse.draft.choosing && chooser?.sheetParent==nil && HookConfigurationController.activeChoosers==0}
        try require(browse.draft.hook.path==folder.path,"Folder response was not applied after detach: actual=\(browse.draft.hook.path.debugDescription), expected=\(folder.path.debugDescription), revision=\(beforeFolderRevision) -> \(browse.draft.revision), error=\(String(describing:browse.draft.error)), answered=\(browse.answered), active=\(browse.draft.active), available=\(browse.externalAvailability())")
        browse.selectedBrowseURL={_ in file};browse.browse(command:true)
        try await wait("Command chooser did not attach"){chooser?.sheetParent===browse.window}
        try require(chooser?.canChooseFiles==true && chooser?.canChooseDirectories==false,"Command chooser accepted folders")
        callback?(.OK);try await wait("Command chooser did not detach"){!browse.draft.choosing && chooser?.sheetParent==nil}
        try require(browse.draft.hook.command=="'"+file.path+"'","Command chooser did not quote selected script")
        browse.selectedBrowseURL={_ in folder}
        browse.browse(command:false);try await wait("Second chooser missing"){browse.draft.choosing}
        browse.finish(nil);callback?(.OK)
        try await wait("Retired chooser/editor not drained"){!model.hasEditor && owner.attachedSheet==nil && HookConfigurationController.activeChoosers==0 && HookConfigurationController.activeReleases==0}
        try require(model.hooks.count==2 && !model.modified,"Late retired picker mutated saved hooks")
        model.invalidate();try await wait("Hook settings workers retained"){HookSettingsModel.activeReads==0 && HookSettingsModel.activeSaves==0}
        print("Hook settings source defaults, Copy, validation, scopes, list, Apply/Cancel and picker retirement passed.")
    }
}
