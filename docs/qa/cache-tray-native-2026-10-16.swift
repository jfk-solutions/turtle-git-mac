import AppKit
import TurtleGitCore

@main struct CacheTrayVerification {
    struct Failure:Error,CustomStringConvertible{let description:String}
    static func require(_ value:Bool,_ message:String) throws{if !value{throw Failure(description:message)}}
    @MainActor static func wait(_ ready:()->Bool) async throws{for _ in 0..<1500{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Cache tray timeout")}
    @MainActor static func main() async{do{try await verify()}catch{fputs("Cache tray failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let folder=URL(fileURLWithPath:CommandLine.arguments[1]),configuration=folder.appendingPathComponent("tray.json"),overlays=folder.appendingPathComponent("overlays.json")
        let suite="TurtleGit.CacheTray."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        var publications=0
        let advanced=AdvancedSettingsModel(defaults:defaults,publishFinderMenu:{_ in},publishCacheTray:{value in publications += 1;try value.write(to:configuration)})
        try require(advanced.edit("CacheTrayIcon",text:"true"),"Advanced rejected source preference");advanced.cancel()
        try require(publications==0 && !FinderCacheTrayPreferences.from(defaults:defaults).enabled,"Advanced Cancel published tray settings")
        _ = advanced.edit("CacheTrayIcon",text:"true");advanced.apply()
        try require(advanced.error==nil && publications==1 && FinderCacheTrayPreferences.read(from:configuration).enabled,"Advanced Apply did not publish source setting")
        var value=FinderOverlaySettings();value.excludePaths="/private/*";value.iconSet = .modern;try value.write(to:overlays)
        var notifications=0,exits=0,finish:CheckedContinuation<Void,Never>?
        var snapshot=FinderCacheActivitySnapshot(running:true,cachedDirectories:12,watchedPaths:4,lines:["Crawling folder: /private/repository 雪","Updated path: /private/repository 雪"])
        let tray=FinderCacheTrayController(preferencesURL:configuration,overlaysURL:overlays,installStatusItem:false,snapshot:{snapshot},notify:{notifications += 1},exitService:{exits += 1;await withCheckedContinuation{finish=$0}})
        defer{tray.retire()}
        func item(_ title:String) throws -> NSMenuItem{guard let item=tray.menu.items.first(where:{$0.title==title})else{throw Failure(description:"Missing cache menu item: "+title)};return item}
        func send(_ item:NSMenuItem){if let target=item.target as? NSObject,let action=item.action{target.perform(action,with:item)}}
        tray.rebuildMenu();let stale=try item("Disable Status Cache");tray.rebuildMenu();send(stale)
        try require(notifications==0,"Retired menu item changed cache")
        let disable=try item("Disable Status Cache");send(disable);send(disable)
        var expected=value;expected.cacheMode = .none
        try require(notifications==1 && FinderOverlaySettings.read(from:overlays)==expected,"Disable duplicated or replaced other overlay preferences")
        tray.rebuildMenu();let enable=try item("Enable Status Cache")
        var later=expected;later.showExcludedAsNormal=false;try later.write(to:overlays);send(enable)
        later.cacheMode = .standard
        try require(notifications==2 && FinderOverlaySettings.read(from:overlays)==later,"Enable used stale whole-record preferences")
        _ = advanced.edit("ShowAppContextMenuIcons",text:"false");advanced.apply();tray.rebuildMenu()
        try require(tray.menu.items.filter{!$0.isSeparatorItem}.allSatisfy{$0.image==nil},"Cache menu ignored source icon preference")
        tray.toggleActivity();guard let window=tray.activityWindow else{throw Failure(description:"Missing native activity window")};window.alphaValue=0
        try require(window.title=="TurtleGit Overlay Icon Server" && tray.tooltip.contains("Cached directories: 12") && tray.tooltip.contains("Watched paths: 4"),"Source counts/title missing")
        func descendants(_ view:NSView)->[NSView]{[view]+view.subviews.flatMap(descendants)}
        let text=descendants(window.contentView!).compactMap{$0 as? NSTextView}.first
        try require(text?.isEditable==false && text?.isSelectable==true && text?.string.contains("Updated path:")==true,"Native activity is not readable/selectable")
        snapshot.cachedDirectories=13;snapshot.watchedPaths=6;snapshot.lines.append("Crawling folder: /private/second")
        tray.refresh();try require(text?.string.contains("/private/second")==true && tray.tooltip.contains("Watched paths: 6"),"Runtime changes did not update existing native activity")
        if let directory=ProcessInfo.processInfo.environment["TURTLEGIT_CACHE_TRAY_CAPTURE"] {
            NSApp.setActivationPolicy(.accessory);window.alphaValue=1;window.setFrameOrigin(.init(x:80,y:120));window.orderFront(nil)
            for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
                window.appearance=NSAppearance(named:appearance);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:350_000_000)
                let output=URL(fileURLWithPath:directory).appendingPathComponent("cache-activity-"+name+".png"),number=window.windowNumber
                try await Task.detached{let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/sbin/screencapture");process.arguments=["-x","-o","-l",String(number),output.path];try process.run();process.waitUntilExit();guard process.terminationStatus==0 else{throw Failure(description:"Owned activity capture failed")}}.value
            }
            window.alphaValue=0
        }
        window.close();tray.toggleActivity();try require(tray.activityWindow===window && window.isVisible,"Closing activity stopped or replaced cache owner")
        let broken=Data("broken overlays".utf8);try broken.write(to:overlays);tray.rebuildMenu();send(try item("Disable Status Cache"))
        try require(tray.failure != nil && notifications==2 && (try Data(contentsOf:overlays))==broken,"Failed toggle overwrote damaged preferences or notified success")
        try value.write(to:overlays);tray.rebuildMenu();send(try item("Disable Status Cache"))
        try require(tray.failure==nil && notifications==3,"Retry did not clear cache menu failure")
        tray.rebuildMenu();let hidden=try item("Enable Status Cache");_ = advanced.edit("CacheTrayIcon",text:"false");advanced.apply();tray.refresh();send(hidden)
        try require(!window.isVisible && notifications==3,"Disabled tray retained visible activity or actionable menu")
        _ = advanced.edit("CacheTrayIcon",text:"true");advanced.apply();tray.refresh();tray.rebuildMenu();let exitItem=try item("Exit");send(exitItem);send(exitItem)
        try await wait{finish != nil}
        try require(exits==1 && tray.stopping && !tray.retired && tray.menu.items.allSatisfy{!$0.isEnabled},"Exit did not hold stopping lifetime or admitted duplicate commands")
        finish?.resume();finish=nil;try await wait{tray.retired}
        send(exitItem);try require(exits==1 && tray.activityWindow==nil,"Retired tray revived a window or repeated Exit")
        print("PASS: native cache activity/menu, Advanced Apply/Cancel/icons, captured one-use enable/disable preserving latest settings, failed-write recovery, live counts, hide/reopen and awaited Exit retirement; private settings only, no real menu-bar item or service registration")
    }
}
