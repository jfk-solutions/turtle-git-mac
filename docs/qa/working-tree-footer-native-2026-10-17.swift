// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import SwiftUI
import ScreenCaptureKit
import TurtleGitCore

@main struct WorkingTreeFooterVerification {
    enum Failure:Error {case assertion(String),timeout(UInt)}
    @MainActor static func require(_ yes:Bool,_ message:String)throws {if !yes {throw Failure.assertion(message)}}
    @MainActor static func wait(line:UInt = #line,_ yes:()->Bool)async throws {for _ in 0..<2500 {if yes(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure.timeout(line)}
    @MainActor static func views(_ root:NSView?)->[NSView] {guard let root else {return []};return [root]+root.subviews.flatMap {views($0)}}
    @MainActor static func capture(_ window:NSWindow,to folder:URL)async throws {
        guard #available(macOS 14.4,*) else {throw Failure.assertion("Capture requires macOS 14.4")}
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        for (appearance,suffix) in [(NSAppearance.Name.aqua,"light"),(.darkAqua,"dark")] {
            window.appearance=NSAppearance(named:appearance);window.alphaValue=1;window.orderFront(nil);window.contentView?.layoutSubtreeIfNeeded();try await Task.sleep(nanoseconds:250_000_000)
            let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
            guard let own=content.windows.first(where:{$0.windowID==CGWindowID(window.windowNumber)}) else {throw Failure.assertion("Capture owner missing")}
            let options=SCStreamConfiguration();options.width=Int(window.frame.width*2);options.height=Int(window.frame.height*2);options.showsCursor=false
            let pixels=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:own),configuration:options)
            guard let png=NSBitmapImageRep(cgImage:pixels).representation(using:.png,properties:[:]) else {throw Failure.assertion("PNG missing")}
            try png.write(to:folder.appendingPathComponent("working-tree-footer-"+suffix+".png"))
        };window.orderOut(nil);window.alphaValue=0
    }
    @MainActor static func main()async {NSApplication.shared.setActivationPolicy(.prohibited);do {try await verify();print("PASS Working Tree footer: real Git action/line totals, filter/scope acquisition, readonly native information, original Stash menu icons/order, captured one-use/refresh/foreign/retired dispatch and unchanged repository")}catch {fputs("Working Tree footer failed: \(error)\n",stderr);exit(1)}}
    @MainActor static func verify()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),repo=GitRepository(root:root,executable:git,askpass:nil),fm=FileManager.default
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Working Tree Footer"),("user.email","footer@example.invalid"),("commit.gpgsign","false")] {_=try await repo.run(["config",key,value])}
        try fm.createDirectory(at:root.appendingPathComponent("scope"),withIntermediateDirectories:true)
        for name in ["modified.txt","deleted.txt","rename.txt","normal.txt","conflict.txt"] {try Data("base\n".utf8).write(to:root.appendingPathComponent("scope/"+name))}
        try Data("*.ignored\n".utf8).write(to:root.appendingPathComponent(".gitignore"));try await repo.stage(["."]);_=try await repo.commit(message:"base")
        try Data("stash candidate\n".utf8).write(to:root.appendingPathComponent("scope/normal.txt"));_=try await repo.run(["stash","push","-m","footer sample"])
        _=try await repo.run(["switch","-c","other"]);try Data("theirs\n".utf8).write(to:root.appendingPathComponent("scope/conflict.txt"));try await repo.stage(["scope/conflict.txt"]);_=try await repo.commit(message:"theirs")
        _=try await repo.run(["switch","main"]);try Data("ours\n".utf8).write(to:root.appendingPathComponent("scope/conflict.txt"));try await repo.stage(["scope/conflict.txt"]);_=try await repo.commit(message:"ours")
        _=try await repo.run(["merge","--no-edit","other"],successfulExitCodes:0...1)
        try Data("changed\nextra\n".utf8).write(to:root.appendingPathComponent("scope/modified.txt"));try fm.removeItem(at:root.appendingPathComponent("scope/deleted.txt"))
        _=try await repo.run(["mv","scope/rename.txt","scope/moved.txt"])
        try Data("added\n".utf8).write(to:root.appendingPathComponent("scope/added.txt"));try await repo.stage(["scope/added.txt"])
        try Data("untracked\n".utf8).write(to:root.appendingPathComponent("scope/notes.txt"));try Data("ignored\n".utf8).write(to:root.appendingPathComponent("scope/data.ignored"))
        _=try await repo.run(["update-index","--skip-worktree","scope/normal.txt"])
        let suite="TurtleGit.WorkingFooter."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,clipboard=NSPasteboard.withUniqueName()
        defer {prefs.removePersistentDomain(forName:suite);clipboard.releaseGlobally()}
        let owner=StatusWindowController(repository:repo,access:nil,defaults:prefs),model=owner.model,window=owner.window!
        window.alphaValue=0;model.clipboard=clipboard;defer {owner.close()};model.reload();try await wait {!model.busy && model.files.contains {$0.state == .conflicted}}
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let totals=StatusFooterStatistics(files:model.files,statistics:model.statistics,filter:model.filter)
        try require(totals.unversioned==1 && totals.modified>=2 && totals.added==1 && totals.deleted>=1 && totals.conflicted==1,"Detailed action totals missing real Git states: \(model.summary)")
        try require(totals.addedLines>0 && totals.removedLines>0 && model.summary.hasPrefix("line: ") && model.summary.contains("normal=0"),"Source line/normal information missing")
        var filter=model.filter;filter.showIgnored=true;model.setFilter(filter)
        try require(StatusFooterStatistics(files:model.files,statistics:model.statistics,filter:model.filter).unversioned==2,"Ignored acquisition did not join source unversioned count")
        filter.showUnversioned=false;model.setFilter(filter)
        try require(StatusFooterStatistics(files:model.files,statistics:model.statistics,filter:model.filter).unversioned==1,"Unversioned acquisition ignored filter")
        filter.showIgnored=false;filter.showUnversioned=true;model.setFilter(filter)
        window.contentView?.layoutSubtreeIfNeeded()
        try await wait {views(window.contentView).contains {($0 as? NSTextField)?.accessibilityLabel()=="Working Tree statistics"}}
        let info=views(window.contentView).compactMap {$0 as? NSTextField}.first {$0.accessibilityLabel()=="Working Tree statistics"}!
        try await wait {info.stringValue==model.summary && info.toolTip==model.nativeSummary}
        try require(!info.isEditable && info.isSelectable && info.intrinsicContentSize.height>0 && info.frame.height>=info.intrinsicContentSize.height,"Native information state: editable=\(info.isEditable), selectable=\(info.isSelectable), frame=\(info.frame)")
        let popup=views(window.contentView).compactMap {$0 as? NSPopUpButton}.first {$0.accessibilityLabel()=="Stash"}!,menu=popup.menu!,coordinator=menu.delegate as! StatusStashMenu.Coordinator
        coordinator.menuNeedsUpdate(menu)
        let choices=menu.items.filter {!$0.isHidden}
        try require(choices.map(\.title)==["Stash save…","Stash pop","Stash apply","Stash list"] && choices.allSatisfy {$0.image != nil},"Source Stash choice order/icons differ")
        var actions:[RepositoryAction]=[];model.onAction={action,_ in actions.append(action)}
        let stale=choices[1];model.reload();try await wait {!model.busy};coordinator.invoke(stale)
        try require(actions.isEmpty,"Old Stash popup survived refresh")
        coordinator.menuNeedsUpdate(menu);let item=menu.items.first {$0.title=="Stash list"}!;coordinator.invoke(item);coordinator.invoke(item)
        try await wait {!model.busy && actions.count==1};coordinator.invoke(item);try require(actions==[.stashList],"Captured Stash command repeated or changed")
        let snapshot=model.stashMenuSnapshot()!,foreign=StatusWindowModel(repository:repo,access:nil,defaults:prefs);var foreignActions=0;foreign.onAction={_,_ in foreignActions += 1}
        foreign.performStashAction(.stash,snapshot:snapshot);try require(foreignActions==0 && !foreign.busy,"Foreign popup snapshot accepted")
        model.setScope(["scope"]);try await wait {!model.busy};try require(model.summary.contains("conflicted=1"),"Scoped statistics lost conflict")
        if let output=ProcessInfo.processInfo.environment["TURTLEGIT_STATUS_FOOTER_CAPTURE"] {try await capture(window,to:URL(fileURLWithPath:output))}
        coordinator.menuNeedsUpdate(menu);let retiredItem=menu.items.first {$0.title=="Stash save…"}!
        owner.close();coordinator.invoke(retiredItem);try require(actions.count==1,"Retired Stash item dispatched")
        let after=try await repo.run(["rev-parse","HEAD"]).stdout
        try require(after==head && (try Data(contentsOf:root.appendingPathComponent(".git/index")))==index && StatusWindowModel.activeOperations==0,"Footer changed repository or leaked operations")
    }
}
