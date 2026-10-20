import AppKit
import SwiftUI
import TurtleGitCore

@main struct ToolSettingsVerification {
    @MainActor static func main() async {do {try await verify()}catch{fputs("FAIL: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify() async throws {
        func require(_ value:Bool,_ message:String)throws{if !value{throw NSError(domain:"ToolSettingsNative",code:1,userInfo:[NSLocalizedDescriptionKey:message])}}
        func wait(_ ready:()->Bool)async throws{for _ in 0..<1000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw NSError(domain:"Tool settings did not settle",code:1)}
        func entry(_ pattern:String)->DiffToolAssociation{var e=DiffToolAssociation();e.pattern=pattern;e.program.applicationPath="/Applications/Fixture.app";return e}
        let suite="TurtleGit.ToolSettingsNative."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer{prefs.removePersistentDomain(forName:suite)}
        let a=entry(".a"),b=entry(".b"),c=entry(".c")
        let associations=ToolAssociationsModel(associations:[c,a,b],tool:"diff",preferences:prefs)
        try require(associations.rows.map(\.pattern)==[".a",".b",".c"],"Association sorting differs")
        associations.selected=b.id;associations.remove()
        try require(associations.selected==c.id && associations.draft.count==2,"Remove failed to select next row")
        associations.remove();try require(associations.selected==a.id,"Last Remove failed to select previous row")
        associations.edit();let original=associations.editing!;associations.accept(nil)
        try require(associations.draft==[a] && associations.editing==nil,"Editor Cancel changed draft")
        associations.add();var added=associations.editing!;added.pattern="*.SWIFT";added.program.applicationPath="/Applications/Fixture.app";associations.accept(added)
        try require(associations.draft.last?.pattern==".swift" && associations.selected==added.id,"Add normalization/selection differs")
        associations.edit();var changed=associations.editing!;changed.pattern=".a";associations.accept(changed)
        try require(associations.draft.count==2 && associations.valid,"Duplicate edit overwrote another association")
        associations.edit();changed=associations.editing!;changed.pattern=".z";associations.accept(changed)
        try require(associations.rows.map(\.pattern)==[".a",".z"] && associations.selected==changed.id,"Renamed association lost sorted selection")
        let mergeAssociations=ToolAssociationsModel(associations:[],tool:"merge",preferences:prefs);mergeAssociations.add()
        try require(mergeAssociations.editing?.program.arguments=="%base %theirs %mine %merged","Merge Add used diff arguments")
        mergeAssociations.accept(nil)
        let tableWindow=NSWindow(contentRect:NSRect(x:0,y:0,width:720,height:400),styleMask:[.titled],backing:.buffered,defer:false);tableWindow.isReleasedWhenClosed=false
        let tableHost=NSHostingView(rootView:ToolAssociationsTable(model:associations));tableWindow.contentView=tableHost;tableHost.layoutSubtreeIfNeeded()
        func table(_ view:NSView)->NSTableView?{if let t=view as? NSTableView{return t};return view.subviews.compactMap{table($0)}.first}
        defer{tableWindow.contentView=nil;tableWindow.close()}
        try await wait{table(tableHost)?.numberOfRows==2}
        let native=table(tableHost)!
        try require(native.tableColumns.map(\.title)==["Extension","Program"] && native.doubleAction != nil && native.target != nil,"Native table columns/Edit routing absent")
        native.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        try require(associations.selected==a.id,"Native row selection did not reach model")
        let cell=native.view(atColumn:1,row:0,makeIfNecessary:true) as? NSTableCellView
        try require(cell?.textField?.stringValue.contains("%base %mine")==true,"Program column hid command arguments")
        for appearance in [NSAppearance.Name.aqua,.darkAqua]{tableHost.appearance=NSAppearance(named:appearance);tableHost.layoutSubtreeIfNeeded()}
        let diff=ToolSettingsDraft(DiffToolPreferences(),valid:{$0.valid},persist:{try $0.save(to:prefs)})
        let merge=ToolSettingsDraft(MergeToolPreferences(),valid:{$0.valid},persist:{try $0.save(to:prefs)})
        let transaction=SettingsTransaction(),window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:900),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
        let host=NSHostingView(rootView:VStack{DiffToolSettings(model:diff,preferences:prefs);MergeToolSettings(model:merge,preferences:prefs)}.environment(\.settingsTransaction,transaction));window.contentView=host;host.layoutSubtreeIfNeeded()
        defer{transaction.invalidate();window.contentView=nil;window.close()}
        diff.value.associations=associations.draft;merge.value.associations=[original];merge.value.blockWhileMerging=true
        try await wait{transaction.modified};transaction.apply(closeAfter:false);try await wait{!transaction.busy}
        try require(transaction.error==nil && !transaction.modified && DiffToolPreferences.load(from:prefs).associations==associations.draft && MergeToolPreferences.load(from:prefs).blockWhileMerging,"Parent Apply/persistence differs")
        merge.value.program.enabled=true;merge.value.program.applicationPath="not-an-app"
        try await wait{transaction.modified};transaction.apply(closeAfter:false);try await wait{!transaction.busy}
        try require(transaction.error != nil && merge.modified,"Invalid application accepted")
        transaction.cancel();try require(!transaction.modified && !merge.value.program.enabled,"Parent Cancel failed")
        let failure=ToolSettingsDraft(DiffToolPreferences(),valid:{$0.valid},persist:{_ in throw NSError(domain:"Private persist failure",code:1)})
        failure.value.associations=[a];try require(!failure.apply() && failure.modified && failure.error != nil,"Failed save discarded pending draft")
        failure.cancel();try require(!failure.modified && failure.error==nil,"Failed save Cancel differs")
        print("Tools: association Add/Edit/Cancel/duplicate normalization, sorted next/previous Remove selection, merge defaults, native columns/selection/double-action wiring/arguments and light-dark host, shared parent Apply/Cancel/validation/private persistence and failed-save draft retention passed. No tool applications launched; physical double-click/sheets and signed launch acceptance remain open.")
    }
}
