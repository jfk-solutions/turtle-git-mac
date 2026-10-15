import AppKit
import FinderSync
import TurtleGitCore

@MainActor final class FinderContextTarget: NSObject {
    var packet: FinderRequest?
    @objc func invoke(_ sender: NSMenuItem) { packet = (sender.representedObject as? FinderMenuCommand)?.request }
}
@main struct FinderSelectionContextVerification {
    @MainActor static func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items + menu.items.flatMap { $0.submenu.map(items) ?? [] } }
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]), first=root.appendingPathComponent("repo",isDirectory:true), second=root.appendingPathComponent("other",isDirectory:true)
        let nested=first.appendingPathComponent("nested",isDirectory:true), module=first.appendingPathComponent("module",isDirectory:true), ignored=first.appendingPathComponent("ignored",isDirectory:true)
        for folder in [first,second,nested,module,ignored.appendingPathComponent("child",isDirectory:true)] { try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true) }
        let changed=first.appendingPathComponent("changed 雪\n.txt"), normal=first.appendingPathComponent("normal"), added=first.appendingPathComponent("added.patch"), other=second.appendingPathComponent("file"), inner=nested.appendingPathComponent("file"), external=root.appendingPathComponent("outside")
        for file in [changed,normal,added,other,inner,external] { try Data("original\n".utf8).write(to:file) }
        let direct:[String:FileState]=[changed.path:.modified,normal.path:.normal,added.path:.added,other.path:.modified,inner.path:.conflicted,module.path:.normal,ignored.path:.ignored]
        var snapshot=FinderSnapshot(roots:[first.path,second.path,nested.path,module.path],states:direct,repositories:[first.path:.init(hasLFS:true),second.path:.init(),nested.path:.init(),module.path:.init(submoduleParentRoot:first.path)],overlayEntries:direct)
        let target=FinderContextTarget(), selector=#selector(FinderContextTarget.invoke(_:))
        var settings=FinderMenuSettings(); settings.extendedOnlyMask=0
        func menu(_ paths:[URL], top:Bool=false, creation:URL?=nil, icons:Bool=true)->NSMenu {
            var prefs=settings; prefs.topLevelMask=top ? UInt64.max:0; prefs.showIcons=icons
            return FinderMenuBuilder.make(paths:paths,snapshot:snapshot,settings:prefs,comparisonMark:nil,target:target,actionSelector:selector,creationDirectory:creation)
        }
        func item(_ action:RepositoryAction,_ menu:NSMenu)->NSMenuItem? { items(menu).first { ($0.representedObject as? FinderMenuCommand)?.request.action == action } }
        for top in [false,true] {
            let mixed=menu([changed,other],top:top)
            precondition(item(.commit,mixed)?.isEnabled == false && item(.diff,mixed)?.isEnabled == true)
            precondition(item(.commit,mixed)?.toolTip?.contains("one repository") == true)
            mixed.update(); precondition(item(.commit,mixed)?.isEnabled == false)
            let compare=item(.diff,mixed)!, packet=(compare.representedObject as! FinderMenuCommand).request
            precondition(packet.paths.map(\.path) == [changed.path,other.path])
            precondition(NSApp.sendAction(compare.action!,to:compare.target,from:compare)); precondition(target.packet?.paths == packet.paths)
            let childMix=menu([changed,inner],top:top)
            precondition(item(.commit,childMix)?.isEnabled == false && item(.resolve,childMix) == nil)
            let same=menu([changed,normal],top:top)
            precondition(item(.revert,same)?.isEnabled == true && item(.remove,same)?.isEnabled == true)
            let reversed=menu([normal,changed],top:top); precondition(item(.revert,reversed) == nil)
            let registered=menu([changed,module],top:top)
            precondition(item(.remove,registered)?.isEnabled == true)
            let unknown=menu([external,changed],top:top)
            precondition(item(.commit,unknown) == nil && item(.diff,unknown)?.isEnabled == true)
            let directoryPair=menu([changed,nested],top:top); precondition(item(.diff,directoryPair) == nil)
        }
        let duplicate=menu([changed,changed]); precondition(item(.rename,duplicate)?.isEnabled == true)
        let rename=item(.rename,duplicate)!, request=(rename.representedObject as! FinderMenuCommand).request
        precondition(request.paths.count == 1 && FinderRequest(url:request.url!)?.paths == request.paths)
        let child=ignored.appendingPathComponent("child",isDirectory:true), inherited=menu([child],creation:child)
        precondition(item(.clone,inherited) != nil && item(.initialize,inherited) != nil && item(.add,inherited)?.isEnabled == true)
        let tracked=ignored.appendingPathComponent("tracked"); try Data("tracked\n".utf8).write(to:tracked)
        snapshot.states[tracked.path] = .normal; snapshot.overlayEntries?[tracked.path] = .normal
        precondition(item(.ignore,menu([tracked])) == nil && item(.ignoreDelete,menu([tracked])) != nil)
        let nestedIgnored=ignored.appendingPathComponent("checkout",isDirectory:true)
        try FileManager.default.createDirectory(at:nestedIgnored,withIntermediateDirectories:true)
        snapshot.roots.append(nestedIgnored.path); snapshot.repositories[nestedIgnored.path] = .init()
        let nestedMenu=menu([nestedIgnored],creation:nestedIgnored)
        precondition(item(.clone,nestedMenu) == nil && item(.initialize,nestedMenu) == nil)
        let iconMenu=menu([changed],icons:true), plain=menu([changed],icons:false)
        let iconItem=item(.rename,iconMenu)!, plainItem=item(.rename,plain)!
        precondition(iconItem.image != nil && plainItem.image == nil)
        precondition((iconItem.representedObject as! FinderMenuCommand).request.url == (plainItem.representedObject as! FinderMenuCommand).request.url)
        let retained=try Data(contentsOf:changed); precondition(retained == Data("original\n".utf8))
        print("PASS: actual Finder menu builder representative context/cardinality, nested ownership, mixed-root disabled state surviving update, independent two-file Diff, registered gitlink removal, Revert mixed review, ignored ancestry/explicit tracked exception, nested-root boundary, original icon policy and immutable normalized dispatch; no Finder controller/extension activation or Git execution")
    }
}
