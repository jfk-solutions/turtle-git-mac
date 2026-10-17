// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import UniformTypeIdentifiers
import TurtleGitCore

@main struct FileTransferIdentityVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String) throws {if !value {throw Failure(description:message)}}
    @MainActor static func views(_ view:NSView?) -> [NSView] {guard let view else{return []};return [view]+view.subviews.flatMap {views($0)}}
    @MainActor static func wait(_ window:NSWindow? = nil,line:Int = #line,_ ready:()->Bool) async throws {
        for _ in 0..<2500 {window?.contentView?.layoutSubtreeIfNeeded();if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Transfer wait at \(line)")
    }
    @MainActor static func main() async {
        NSApp.setActivationPolicy(.prohibited)
        do {try await verify();print("PASS Transfer identities: distinct native source rows, private URL clipboard and Finder request roundtrip, captured multi-source drop, exact staged/working Move and existing-identity Copy/Add, unchanged alias entries and HEAD; owned windows closed")}
        catch {fputs("Transfer identity failure: \(error)\n",stderr);exit(1)}
    }
    @MainActor static func verify() async throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1]), repo = GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Transfer QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null"),("core.precomposeunicode","true")] {_ = try await repo.run(["config",key,value])}
        let a = "café.txt", b = "cafe\u{301}.txt", moving = "move-cafe\u{301}.txt", copyName = "copy-cafe\u{301}.txt", externalName = "copy-café.txt"
        let folder = root.appendingPathComponent("target"), external = root.appendingPathComponent("external-input")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);try FileManager.default.createDirectory(at:external,withIntermediateDirectories:true)
        func install(_ path:String,_ text:String) async throws {
            let object = try await repo.run(["hash-object","-w","--stdin"],input:Data(text.utf8)).text.trimmingCharacters(in:.newlines)
            _ = try await repo.run(["update-index","-z","--index-info"],input:Data("100644 \(object)\t\(path)\0".utf8))
        }
        try Data("alias working\n".utf8).write(to:root.appendingPathComponent(a))
        try Data("move working\n".utf8).write(to:root.appendingPathComponent(moving))
        try Data("old copy\n".utf8).write(to:folder.appendingPathComponent(copyName))
        try Data("new copy\n".utf8).write(to:external.appendingPathComponent(externalName))
        try await install(a,"first alias\n");try await install(b,"second alias\n");try await install(moving,"move staged\n");try await install("target/"+copyName,"old copy\n")
        _ = try await repo.commit(message:"transfer baseline")
        let head = try await repo.run(["rev-parse","HEAD"]).stdout
        let aliases = try await repo.run(["-c","core.precomposeunicode=false","ls-files","--stage","-z","--",a,b]).stdout
        let suite = "TurtleGit.TransferIdentity."+UUID().uuidString,prefs = UserDefaults(suiteName:suite)!,clipboard = NSPasteboard.withUniqueName()
        defer {prefs.removePersistentDomain(forName:suite);clipboard.releaseGlobally()}
        let urls = [FileTransferPaths.fileURL(root.path + "/" + a),FileTransferPaths.fileURL(root.path + "/" + b)]
        FileTransferClipboard.copy(urls+[urls[0]],pasteboard:clipboard)
        try require(FileTransferClipboard.urls(clipboard).map {GitReferenceName($0.path)} == urls.map {GitReferenceName($0.path)},"URL clipboard collapsed Unicode sources")
        let request = FinderRequest(action:.pasteCopy,paths:[folder],sources:FileTransferClipboard.urls(clipboard))
        guard let encoded = request.url, let decoded = FinderRequest(url:encoded) else {throw Failure(description:"Transfer request encoding")}
        try require(decoded.sources.map {GitReferenceName($0.lastPathComponent)} == [GitReferenceName(a),GitReferenceName(b)],"Finder request retargeted a source")
        let move = FileMoveWindowController(repository:repo,access:nil,paths:[a,b,a],preferences:prefs,savesGeometry:false)
        let copy = FileCopyWindowController(repository:repo,access:nil,sources:urls+[urls[0]],preferences:prefs,savesGeometry:false)
        defer {move.close();copy.close()}
        for owner in [move as NSWindowController,copy as NSWindowController] {owner.window!.alphaValue = 0;owner.window!.orderFront(nil)}
        try await wait(move.window) {views(move.window?.contentView).compactMap {$0 as? NSTableView}.contains {$0.numberOfRows == 2}}
        try await wait(copy.window) {views(copy.window?.contentView).compactMap {$0 as? NSTableView}.contains {$0.numberOfRows == 2}}
        try require(move.model.paths.map {GitReferenceName($0)} == [GitReferenceName(a),GitReferenceName(b)] && copy.model.sources.count == 2,"Native source models merged peers")
        let drop = FileDropTransferWindowController(repository:repo,access:nil,preferences:prefs)
        defer {drop.close()};drop.window!.alphaValue = 0;drop.window!.orderFront(nil)
        var accepted:[URL] = [];drop.onAccepted = {choice,sources,destination in if choice == .copyAdd && destination == root {accepted = sources}}
        let providers = (urls+[urls[0]]).map {NSItemProvider(item:$0.dataRepresentation as NSData,typeIdentifier:UTType.fileURL.identifier)}
        drop.model.load(providers);try await wait(drop.window) {!drop.model.busy && drop.model.ready}
        try require(drop.model.sources.count == 2 && !drop.model.canMove && drop.model.choices == [.copyAdd],"Drop lost sources or enabled ambiguous Move")
        drop.model.accept(.copyAdd)
        try require(accepted.map {GitReferenceName($0.path)} == urls.map {GitReferenceName($0.path)},"Drop handoff changed captured sources")
        move.close();copy.close()
        let movingOwner = FileMoveWindowController(repository:repo,access:nil,paths:[moving],preferences:prefs,savesGeometry:false)
        defer {movingOwner.close()};movingOwner.window!.alphaValue = 0;movingOwner.window!.orderFront(nil)
        movingOwner.model.setFolder(folder);try await wait(movingOwner.window) {!movingOwner.model.busy}
        var moved:[(String,String)] = [];movingOwner.model.onMoved = {old,new,_ in moved.append((old,new))}
        movingOwner.model.move();try await wait(movingOwner.window) {!movingOwner.model.busy}
        try require(!movingOwner.model.failed && movingOwner.model.moved == 1 && moved.count == 1 && GitReferenceName.equal(moved[0].0,moving) && GitReferenceName.equal(moved[0].1,"target/"+moving),"Native Move lost exact target or callback")
        try require(try await repo.run(["-c","core.precomposeunicode=false","show",":target/"+moving]).stdout == Data("move staged\n".utf8),"Move lost staged bytes")
        try require(try Data(contentsOf:folder.appendingPathComponent(moving)) == Data("move working\n".utf8),"Move lost working bytes")
        movingOwner.close()
        let copyingOwner = FileCopyWindowController(repository:repo,access:nil,sources:[external.appendingPathComponent(externalName)],folder:folder,preferences:prefs,savesGeometry:false)
        defer {copyingOwner.close()};copyingOwner.window!.alphaValue = 0;copyingOwner.window!.orderFront(nil)
        var collisions:[String] = [];copyingOwner.model.collision = {path in collisions.append(path);return .overwrite}
        copyingOwner.model.run();try await wait(copyingOwner.window) {!copyingOwner.model.busy}
        try require(!copyingOwner.model.failed && copyingOwner.model.copied == 1 && collisions.map {GitReferenceName($0)} == [GitReferenceName("target/"+copyName)],"Copy/Add failed to retain existing index identity")
        try require(try await repo.run(["-c","core.precomposeunicode=false","show",":target/"+copyName]).stdout == Data("new copy\n".utf8),"Copy/Add staged wrong path/bytes")
        let allPaths = try await repo.run(["-c","core.precomposeunicode=false","ls-files","-z"]).stdout.split(separator:0).map {String(decoding:$0,as:UTF8.self)}
        try require(GitPathSet(allPaths).contains("target/"+copyName) && !GitPathSet(allPaths).contains("target/"+externalName),"Copy/Add created a second index spelling")
        try require(try Data(contentsOf:external.appendingPathComponent(externalName)) == Data("new copy\n".utf8),"Copy/Add changed source")
        copyingOwner.close()
        try require(try await repo.run(["-c","core.precomposeunicode=false","ls-files","--stage","-z","--",a,b]).stdout == aliases,"Transfer changed unselected alias entries")
        try require(try await repo.run(["rev-parse","HEAD"]).stdout == head && Data(contentsOf:root.appendingPathComponent(a)) == Data("alias working\n".utf8),"Transfer changed HEAD or unselected workfile")
        try require(FileMoveWindowModel.activeOperations == 0 && FileCopyWindowModel.activeOperations == 0 && FileDropTransferModel.activePreparations == 0,"Transfer operations failed to drain")
    }
}
