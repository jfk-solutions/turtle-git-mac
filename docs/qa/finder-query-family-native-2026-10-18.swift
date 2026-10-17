import AppKit
import FinderSync
import TurtleGitCore

@main struct FinderQueryFamilyVerification {
    @MainActor static func main() async throws {
        if CommandLine.arguments.last == "finder-publication-worker" {await FinderPublicationWorker.main();return}
        if CommandLine.arguments.last == "root-worker" {try await FinderRootIdentityVerification.worker();return}
        try verifyMenus()
        try await FinderRootIdentityVerification.verify()
        try await FinderPublicationVerification.verify()
        print("PASS: Finder indexed query family; native menus, root/worker/publication regressions and cleanup completed")
    }
    @MainActor static func verifyMenus() throws {
        let directory=URL(fileURLWithPath:CommandLine.arguments[1]),root=directory.appendingPathComponent("large-query",isDirectory:true)
        let group=root.appendingPathComponent("selected",isDirectory:true)
        try FileManager.default.createDirectory(at:group,withIntermediateDirectories:true)
        let tracked=(0..<5000).map {"selected/sub-\($0)/file"}
        var snapshot=FinderSnapshot.build(root:root,tracked:tracked,changes:StatusEntry.parse(Data("UU selected/sub-4999/file\0".utf8)))
        snapshot.repositories[root.path] = .init(mergeActive:true)
        snapshot.roots += (0..<200).map {directory.path+"/other-\($0)"}
        let target=RootIdentityTarget(),selector=#selector(RootIdentityTarget.invoke(_:))
        var settings=FinderMenuSettings();settings.extendedOnlyMask=0;settings.topLevelMask=0
        func items(_ menu:NSMenu)->[NSMenuItem] {menu.items + menu.items.flatMap {$0.submenu.map(items) ?? []}}
        func menu(_ snapshot:FinderSnapshot)->NSMenu {
            FinderMenuBuilder.make(paths:[group],snapshot:snapshot,settings:settings,comparisonMark:nil,target:target,actionSelector:selector)
        }
        func item(_ action:RepositoryAction,_ menu:NSMenu)->NSMenuItem? {items(menu).first {($0.representedObject as? FinderMenuCommand)?.request.action==action}}
        let cold=DispatchTime.now().uptimeNanoseconds
        let first=menu(snapshot)
        try FinderRootIdentityVerification.require(item(.resolve,first)?.isEnabled == true && item(.revert,first)?.isEnabled == true,"Large-folder source actions missing")
        let ready=DispatchTime.now().uptimeNanoseconds
        for _ in 0..<20 {
            let popup=menu(snapshot)
            try FinderRootIdentityVerification.require(item(.resolve,popup)?.image != nil && item(.resolve,popup)?.isEnabled == true,"Warm popup changed source icon/state")
        }
        let end=DispatchTime.now().uptimeNanoseconds
        let retained=snapshot
        snapshot.overlayEntries?[root.path+"/selected/sub-4999/file"] = .normal
        let fresh=menu(snapshot)
        // The old aggregate directory color remains in states, deliberately.
        // Availability must use the changed direct entry namespace, not that
        // stale aggregate or the retained copy's already-warmed query data.
        try FinderRootIdentityVerification.require(item(.resolve,fresh)?.isEnabled != true && item(.revert,fresh)?.isEnabled != true && item(.remove,fresh)?.isEnabled == true,"Changed snapshot reused old descendant eligibility")
        try FinderRootIdentityVerification.require(item(.resolve,menu(retained))?.isEnabled == true,"A changed copy invalidated its retained snapshot")
        let badges=FinderOverlaySettings().overlayBadges(snapshot:snapshot,volume:{_ in .fixed},isDirectory:{_ in false})
        try FinderRootIdentityVerification.require(badges[root.path] == .normal && badges[group.path] == .normal,"Badge projection reused old path generation")
        let rawEntries=snapshot.overlayEntries
        snapshot.roots.append(group.path+"/sub-4999")
        snapshot.overlayEntries?[group.path+"/sub-4999/file"] = .conflicted
        try FinderRootIdentityVerification.require(item(.resolve,menu(snapshot))?.isEnabled != true,"Nested checkout made its parent directory actionable")
        snapshot.roots.removeLast();snapshot.overlayEntries=rawEntries
        try FinderRootIdentityVerification.require(item(.resolve,menu(snapshot))?.isEnabled != true,"Restored snapshot retained nested query data")
        print("Finder native query sample: 5000 entries/201 roots; cold menu \(Double(ready-cold)/1_000_000) ms, 20 warm menus \(Double(end-ready)/1_000_000) ms. No timing threshold asserted. Actual source icon/eligibility, copy/mutation, fresh badges and nested ownership passed.")
    }
}
