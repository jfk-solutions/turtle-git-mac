import AppKit
import TurtleGitCore

struct RepositoryBrowserPathsVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (k,v) in [("user.name","Browser path QA"),("user.email","paths@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeUnicode","true")] {_ = try await repo.run(["config",k,v])}
        let a="caf\u{e9}.txt",b="cafe\u{301}.txt",da="d\u{e9}",db="de\u{301}"
        let working=Data("working\n".utf8);try working.write(to:root.appendingPathComponent(a));try await repo.stage([a]);_ = try await repo.commit(message:"working NFC")
        // Bind the alias scenario to actual cached Git bytes rather than the
        // host Git client's platform/default precomposition setting.
        let cached=try await repo.run(["-c","core.precomposeUnicode=false","ls-files","--cached","-z","--"]).stdout.split(separator:0)
        try require(cached.count==1 && cached[0].elementsEqual(a.utf8),"Fixture seed did not retain exact NFC index spelling; cached="+cached.map{Data($0).base64EncodedString()}.joined(separator:","))
        let first=Data([0,1,0xff,10]),second=Data([9,2,0xfe,13,10])
        let ah=try await repo.run(["hash-object","-w","--stdin"],input:first).text.trimmingCharacters(in:.newlines)
        let bh=try await repo.run(["hash-object","-w","--stdin"],input:second).text.trimmingCharacters(in:.newlines)
        func record(_ mode:String,_ type:String,_ hash:String,_ name:String)->String {"\(mode) \(type) \(hash)\t\(name)\0"}
        let at=try await repo.run(["mktree","-z"],input:Data(record("100644","blob",ah,"first.txt").utf8)).text.trimmingCharacters(in:.newlines)
        let bt=try await repo.run(["mktree","-z"],input:Data(record("100644","blob",bh,"second.txt").utf8)).text.trimmingCharacters(in:.newlines)
        let source=record("100644","blob",ah,a)+record("100644","blob",bh,b)+record("100644","blob",ah,"plain.txt")+record("040000","tree",at,da)+record("040000","tree",bt,db)
        let tree=try await repo.run(["mktree","-z"],input:Data(source.utf8)).text.trimmingCharacters(in:.newlines)
        let head=try await repo.run(["rev-parse","HEAD"]).stdout,index=try Data(contentsOf:root.appendingPathComponent(".git/index"))
        let suite="TurtleGit.BrowserPaths."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        defer{prefs.removePersistentDomain(forName:suite)}
        let owner=RepositoryBrowserWindowController(repository:repo,access:nil,revision:tree,preferences:prefs),model=owner.model
        defer{owner.close()};owner.window!.alphaValue=0;owner.window!.orderFront(nil);model.refresh()
        try await RepositoryBrowserTableVerification.wait{!model.busy && model.entries.count == 5}
        let table=RepositoryBrowserTableVerification.find(owner.window!.contentView!)!,outline=RepositoryBrowserTableVerification.findTree(owner.window!.contentView!)!
        try require(Set(model.entries.map(\.id)).count == 5,"Canonical path IDs collapsed")
        let ae=model.entries.first{RepositoryBrowserPathIdentity.equal($0.path,a)}!,be=model.entries.first{RepositoryBrowserPathIdentity.equal($0.path,b)}!
        model.selection=[ae.id];try await RepositoryBrowserTableVerification.wait{table.selectedRowIndexes.count == 1}
        try require(model.selected.count == 1 && model.selected[0].objectID == ah,"NFC selection redirected")
        let captured=model.menuTarget([ae])!
        model.selection=[be.id];try await RepositoryBrowserTableVerification.wait{model.selected.first?.objectID == bh}
        try require(model.acceptsMenu(captured),"Selection change retired captured historical target")
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()}
        model.copy(pasteboard:board,entries:captured.entries)
        try require(Data(board.string(forType:.string)!.utf8) == Data((a+"\r\n").utf8),"Captured Copy changed Unicode spelling")
        var opened:Data?
        model.presentFile={content,_ in opened=content.bytes};model.open(be,action:.save)
        try await RepositoryBrowserTableVerification.wait{!model.busy && opened != nil};try require(opened == second,"Historical action read other alias bytes")
        model.expanded.formUnion([da,db]);model.loadDirectory(da,select:false);model.loadDirectory(db,select:false)
        try await RepositoryBrowserTableVerification.wait{model.directories[da] != nil && model.directories[db] != nil}
        try require(model.directories[da]!.first?.name == "first.txt" && model.directories[db]!.first?.name == "second.txt","Folder caches coalesced")
        try await RepositoryBrowserTableVerification.wait{outline.numberOfRows == 3}
        guard let firstNode=outline.item(atRow:1) as? NSObject,let secondNode=outline.item(atRow:2) as? NSObject else {throw Failure(description:"Missing native folder nodes")}
        try require(firstNode !== secondNode,"Folder nodes share identity")
        model.loadDirectory(db,select:true);let oldMenu=model.menuTarget()!
        model.loadDirectory(da,select:true)
        try require(RepositoryBrowserPathIdentity.equal(model.snapshot!.directory,da) && !model.acceptsMenu(oldMenu),"Canonical folder navigation or stale menu identity")
        model.selection=[model.entries[0].id];model.refresh()
        try await RepositoryBrowserTableVerification.wait{!model.busy}
        try require(model.directories.count == 3 && model.expanded.isSuperset(of:["",da,db]) && model.selected.count == 1,"Refresh lost exact folder/selection identities")
        for appearance in [NSAppearance.Name.aqua,.darkAqua] {owner.window!.appearance=NSAppearance(named:appearance);owner.window!.contentView!.layoutSubtreeIfNeeded()}
        owner.close();try require(!model.acceptsMenu(captured),"Closed owner retained historical action")
        // No view owns this model, so the expected refusal is observed without
        // presenting a real alert to the user's desktop.
        let gate=RepositoryBrowserWindowModel(repository:repo,access:nil,revision:tree,preferences:prefs)
        defer{gate.invalidate()};gate.refresh();try await RepositoryBrowserTableVerification.wait{!gate.busy && gate.snapshot != nil}
        var compared:[String]=[];gate.onCompare={path,_ in compared.append(path)}
        guard let snapshot=gate.snapshot else{throw Failure(description:"Working comparison fixture lost displayed snapshot")}
        try require(gate.canUseMenu && snapshot.entries.contains(be),"Working comparison fixture was not admitted before validation")
        var expectedRefusal:String?
        do {
            try await repo.validateRepositoryBrowserWorkingPath(snapshot,entry:be)
        }catch RepositoryBrowserFailure.normalizationCollision(let path) {
            try require(Data(path.utf8)==Data(b.utf8),"Typed collision witness changed exact requested UTF-8 spelling")
            expectedRefusal=RepositoryBrowserFailure.normalizationCollision(path).localizedDescription
        }catch {throw Failure(description:"Expected typed working-path collision, got: \(error)")}
        guard let expectedRefusal else{throw Failure(description:"Typed validation admitted the NFD alias of the exact cached NFC path")}
        gate.compareEntryToWorkingTree(be)
        try require(gate.busy,"Working comparison never entered validation; error="+(gate.error ?? "nil"))
        try await RepositoryBrowserTableVerification.wait{!gate.busy}
        try require(compared.isEmpty,"Working comparison dispatched alias callback(s); raw UTF-8="+compared.map{Data($0.utf8).base64EncodedString()}.joined(separator:","))
        try require(gate.error==expectedRefusal,"Working comparison lost typed collision diagnostic; actual="+(gate.error ?? "nil")+"; expected="+expectedRefusal)
        gate.error=nil;gate.compareEntryToWorkingTree(gate.entries.first{$0.name == "plain.txt"}!)
        try await RepositoryBrowserTableVerification.wait{!gate.busy && compared.count == 1}
        try require(compared.count==1 && Data(compared[0].utf8)==Data("plain.txt".utf8),"Valid working callback refused or changed raw path")
        try require(try Data(contentsOf:root.appendingPathComponent(a)) == working && Data(contentsOf:root.appendingPathComponent(".git/index")) == index,"Browser path actions changed working/index state")
        let after=try await repo.run(["rev-parse","HEAD"]).stdout;try require(after == head,"Browser path actions changed HEAD")
        print("PASS: exact Unicode tree/list IDs, native selection, captured Copy/blob bytes, parallel folder caches/nodes/refresh, retired menus, guarded async working comparison and unchanged HEAD/index/disk; owned window closed")
    }
}
