import AppKit
import SwiftUI
import TurtleGitCore

@main struct OverlaySettingsVerification {
    @MainActor static func main() async {do {try await verify()}catch{fputs("FAIL: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify() async throws {
        func require(_ value:Bool,_ message:String)throws{if !value{throw NSError(domain:"OverlaySettingsNative",code:1,userInfo:[NSLocalizedDescriptionKey:message])}}
        func wait(_ ready:()->Bool)async throws{for _ in 0..<1000{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw NSError(domain:"Overlay settings did not settle",code:1)}
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),publication=root.appendingPathComponent("private-group/overlay-settings.json")
        let suite="TurtleGit.OverlayNative."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer{prefs.removePersistentDomain(forName:suite)}
        var notifications=0,publishedAfterSave=false,fail=false
        let model=FinderOverlaySettingsModel(preferences:prefs,publish:{value in
            if fail{throw NSError(domain:"Private publication failure",code:1)}
            return try value.write(to:publication)
        },notify:{notifications += 1;publishedAfterSave=FinderOverlaySettings.from(defaults:prefs)==FinderOverlaySettings.read(from:publication)})
        let transaction=SettingsTransaction();var windows:[NSWindow]=[]
        defer{transaction.invalidate();for window in windows{window.contentView=nil;window.close()}}
        for (handlers,icons) in [(false,false),(true,false),(false,true)] {
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:530),styleMask:[.titled],backing:.buffered,defer:false);window.isReleasedWhenClosed=false
            let host=NSHostingView(rootView:FinderOverlaySettingsPage(model:model,handlersOnly:handlers,iconsOnly:icons).environment(\.settingsTransaction,transaction));window.contentView=host;host.frame=window.contentLayoutRect;host.layoutSubtreeIfNeeded();windows.append(window)
            for name in [NSAppearance.Name.aqua,.darkAqua]{host.appearance=NSAppearance(named:name);host.layoutSubtreeIfNeeded()}
            func scrolls(_ view:NSView)->Int{(view is NSScrollView ? 1:0)+view.subviews.reduce(0){$0+scrolls($1)}}
            try await wait{scrolls(host)>0}
        }
        model.draft.unversionedAsModified=true;model.draft.recurseSubmodules=true;model.draft.iconSet = .modern
        model.draft.hiddenStates=[.ignored,.untracked];model.draft.showSkipWorktree=false;model.draft.volumes=[.fixed,.network]
        model.draft.excludePaths=root.path+"/excluded*";model.draft.includePaths=root.path+"/excluded/allowed?"
        try await wait{transaction.modified};transaction.apply(closeAfter:false);try await wait{!transaction.busy}
        try require(transaction.error==nil && !model.modified && model.error==nil && model.notice==nil && notifications==1 && publishedAfterSave,"Shared Apply/publication/notification ordering differs")
        let saved=FinderOverlaySettings.read(from:publication)
        try require(saved==model.draft && !saved.allows(root.path+"/excluded/other",volume:.fixed) && saved.allows(root.path+"/excluded/allowed",volume:.unknown),"Published policy differs from shared draft")
        let bytes=try Data(contentsOf:publication)
        model.draft.cacheMode = .none;model.draft.iconSet = .flat;model.draft.showAssumeUnchanged=false
        try await wait{transaction.modified};transaction.cancel()
        try require(model.draft==saved && !transaction.modified && notifications==1 && (try Data(contentsOf:publication))==bytes,"Cancel published draft edits")
        model.draft.includePaths="relative/path";try await wait{transaction.modified};transaction.apply(closeAfter:false);try await wait{!transaction.busy}
        try require(transaction.error != nil && model.modified && notifications==1 && (try Data(contentsOf:publication))==bytes,"Invalid policy published")
        transaction.cancel();fail=true;model.draft.iconSet = .flat
        try await wait{transaction.modified};transaction.apply(closeAfter:false);try await wait{!transaction.busy}
        try require(transaction.error != nil && model.error != nil && model.notice==nil && model.modified && FinderOverlaySettings.from(defaults:prefs)==saved && notifications==1,"Failed publication saved/notified draft")
        transaction.cancel();fail=false
        let unsigned=FinderOverlaySettingsModel(preferences:prefs,publish:{_ in false},notify:{notifications += 1})
        unsigned.draft.iconSet = .win10;let localSaved=unsigned.apply()
        try require(localSaved && !unsigned.modified && unsigned.notice != nil && unsigned.error==nil && notifications==1 && FinderOverlaySettings.from(defaults:prefs).iconSet == .win10,"Unsigned local-save notice/notification differs")
        unsigned.cancel();try require(unsigned.notice==nil,"Cancel retained stale notice")
        print("Overlays: three shared native pages at minimum-height hosts in light/dark, scrolling, shared Apply/Cancel/validation, private atomic policy publication and notification-after-local-save, rule readback, publication failure retains draft, unsigned local-save notice without notification passed. No Finder extension activation or user App Group/preferences changed. Owned windows closed.")
    }
}
