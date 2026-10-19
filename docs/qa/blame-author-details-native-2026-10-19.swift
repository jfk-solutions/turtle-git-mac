// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Foundation
import TurtleGitCore

/// Injected HTTP responses exercise the real shared avatar loader with no public traffic.
final class BlameAvatarTransport: URLProtocol {
    private static let lock=NSLock()
    private static var pending:[ObjectIdentifier:BlameAvatarTransport]=[:]
    private static var requests:[URL]=[]
    override class func canInit(with request:URLRequest)->Bool {true}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() { Self.lock.lock();Self.pending[ObjectIdentifier(self)]=self;if let url=request.url {Self.requests.append(url)};Self.lock.unlock() }
    override func stopLoading() { Self.lock.lock();Self.pending.removeValue(forKey:ObjectIdentifier(self));Self.lock.unlock() }
    static var count:Int {lock.lock();defer{lock.unlock()};return requests.count}
    static var waiting:Int {lock.lock();defer{lock.unlock()};return pending.count}
    static var last:URL? {lock.lock();defer{lock.unlock()};return requests.last}
    static func respond(_ bytes:Data) {
        lock.lock();let values=Array(pending.values);pending.removeAll();lock.unlock()
        for value in values {
            guard let url=value.request.url else {continue}
            value.client?.urlProtocol(value,didReceive:HTTPURLResponse(url:url,statusCode:200,httpVersion:"HTTP/1.1",headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            value.client?.urlProtocol(value,didLoad:bytes);value.client?.urlProtocolDidFinishLoading(value)
        }
    }
}
@MainActor enum BlameAuthorDetailsVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws{if !value{throw Failure(description:message)}}
    static func wait(_ message:String,line:Int = #line,_ ready:()->Bool)async throws {
        for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Blame author/details timeout at \(line): \(message)")
    }
    static func views(_ root:NSView?)->[NSView] {guard let root else{return []};return [root]+root.subviews.flatMap{views($0)}}
    static func drained()->Bool {BlameWindowModel.activeHistoryOperations==0 && BlameWindowModel.activeSyntaxRequests==0 && BlameAvatarTransport.waiting==0}
    static func verify()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),repo=GitRepository(root:root,executable:URL(fileURLWithPath:CommandLine.arguments[2]))
        _ = try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Author Snow 雪"),("user.email","One@Example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
        try Data("one\ntwo\n".utf8).write(to:root.appendingPathComponent("source.txt"));try await repo.stage(["source.txt"])
        _ = try await repo.commit(message:"Parent subject\n\nParent body")
        _ = try await repo.run(["config","user.name","Second Author"]);_ = try await repo.run(["config","user.email","Two@Example.invalid"])
        try Data("new\ntwo\n".utf8).write(to:root.appendingPathComponent("source.txt"));try await repo.stage(["source.txt"])
        let body="Long body with Unicode 雪🦎\n"+String(repeating:"Full selected property value must remain available. ",count:30)
        _ = try await repo.commit(message:"Child subject\n\n"+body)
        let baselinePaths=[".git/index",".git/HEAD",".git/config","source.txt"],baseline=try baselinePaths.map{try Data(contentsOf:root.appendingPathComponent($0))}
        let suite="TurtleGit.BlameAuthorDetails."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!,clipboard=NSPasteboard.withUniqueName()
        prefs.set(false,forKey:"EnableGravatar");prefs.set(false,forKey:"Blame.EnableLexer");prefs.set(false,forKey:"EnableLogCache");prefs.set(true,forKey:"ShowAppContextMenuIcons")
        prefs.set("https://avatar.invalid/blame/%HASH%",forKey:"GravatarUrl")
        let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[BlameAvatarTransport.self]
        let session=URLSession(configuration:configuration),cache=root.appendingPathComponent("private-avatars")
        let loader=LogGravatar(defaults:prefs,session:session,cache:cache,delay:0)
        let controller=BlameWindowController(repository:repo,access:nil,path:"source.txt",revision:"HEAD",preferences:prefs,gravatar:loader)
        let model=controller.model,window=controller.window!;window.alphaValue=0;window.orderFront(nil)
        defer{controller.close();session.invalidateAndCancel();clipboard.releaseGlobally();prefs.removePersistentDomain(forName:suite)}
        model.writeClipboard={text in clipboard.clearContents();clipboard.setString(text,forType:.string)}
        try await wait("actual Blame history") {!model.busy && model.historyEntries.count>=2}
        let child=model.historyEntries.first!,parent=model.historyEntries.first{$0.hash==child.parents.first}!
        model.focusHistory([child.hash],focus:child.hash)
        try await wait("actual properties grid") {views(window.contentView).contains{$0 is BlamePropertiesTable}}
        let grid=views(window.contentView).compactMap{$0 as? BlamePropertiesTable}.first!
        let coordinator=grid.delegate as! BlamePropertyGrid.Coordinator,details=model.revisionDetails
        try require(details.basic.count==9 && details.parents.count==1 && details.parentsExpanded,"Source property fields/parent expansion missing")
        window.contentView?.layoutSubtreeIfNeeded()
        let basicHeading=views(grid.view(atColumn:0,row:0,makeIfNecessary:true)).compactMap{$0 as? NSTextField}.first!
        try require(basicHeading.intrinsicContentSize.width<=basicHeading.bounds.width+1,"Basic information heading is clipped at default width")
        try require(BlameAvatarTransport.count==0 && !model.showGravatar && loader.image==nil,"Disabled Blame avatar sent traffic")
        func choose(_ id:String)throws {
            coordinator.update();guard let row=coordinator.rows.firstIndex(where:{$0.id==id}) else {throw Failure(description:"Missing property "+id)}
            grid.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false);coordinator.tableViewSelectionDidChange(Notification(name:NSTableView.selectionDidChangeNotification,object:grid))
        }
        try choose("basic.8")
        try require(details.selected?.value==body.trimmingCharacters(in:.whitespacesAndNewlines) && details.selected?.description==details.selected?.value,"Body description lost full multiline value")
        grid.copy(nil);try require(clipboard.string(forType:.string)==details.selected?.value,"Native responder Copy omitted body text")
        let contextPoint=grid.convert(NSPoint(x:20,y:grid.rect(ofRow:grid.selectedRow).midY),to:nil)
        let context=NSEvent.mouseEvent(with:.rightMouseDown,location:contextPoint,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        let copyMenu=grid.menu(for:context)
        try require(copyMenu?.items.count==1 && copyMenu?.items.first?.image != nil,"Source Copy menu/icon missing")
        let key=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"c",charactersIgnoringModifiers:"c",isARepeat:false,keyCode:8)!
        clipboard.clearContents();try require(grid.performKeyEquivalent(with:key) && clipboard.string(forType:.string)==details.selected?.value,"Native Command-C lost full property value")
        let stale=grid.menu!.items[0];try choose("basic.1");clipboard.clearContents();coordinator.copyMenu(stale)
        try require(clipboard.string(forType:.string)==nil,"Old property menu copied replacement selection")
        let parentID=details.parents[0].id;try choose(parentID);grid.copy(nil)
        try require(clipboard.string(forType:.string)==parent.subject && details.selected?.description=="0 - \(parent.hash)\n\(parent.subject)","Parent Copy must use subject; description must retain full hash/ordinal")
        let parentDisclosure=NSButton();parentDisclosure.identifier = .init("group.parents");coordinator.toggleGroup(parentDisclosure)
        try require(!details.parentsExpanded && details.selected==nil && !coordinator.rows.contains{$0.id==parentID},"Collapsed parent retained a hidden selected value")
        let basicDisclosure=NSButton();basicDisclosure.identifier = .init("group.basic");coordinator.toggleGroup(basicDisclosure)
        try require(!details.basicExpanded,"Basic information failed to collapse")
        model.focusHistory([parent.hash],focus:parent.hash);coordinator.update()
        try require(details.parentsExpanded && details.parents.isEmpty && !details.basicExpanded,"Revision update failed to reset Parents independently of Basic collapse")
        coordinator.toggleGroup(basicDisclosure)
        prefs.set(true,forKey:"EnableGravatar");model.refreshAuthorPreferences()
        try await wait("enabled injected avatar request") {BlameAvatarTransport.waiting==1}
        let expected=LogGravatarRequest.url(email:parent.email,template:prefs.string(forKey:"GravatarUrl")!,useMD5:false)
        try require(BlameAvatarTransport.last==expected,"Blame author hash did not use captured preferences")
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:2,pixelsHigh:2,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        for x in 0..<2 {for y in 0..<2 {bitmap.setColor(NSColor(deviceRed:0,green:0.6,blue:0.2,alpha:1),atX:x,y:y)}}
        let png=bitmap.representation(using:.png,properties:[:])!;BlameAvatarTransport.respond(png)
        try await wait("actual shared loader image") {loader.image != nil}
        do {try await wait("actual native author image") {views(window.contentView).compactMap{$0 as? NSImageView}.contains{$0.accessibilityLabel()=="Commit author Gravatar" && $0.image != nil && abs($0.frame.width-80)<1 && abs($0.frame.height-80)<1}}}
        catch {throw Failure(description:"Native author view diagnostics: "+views(window.contentView).compactMap{$0 as? NSImageView}.map{"label=\($0.accessibilityLabel() ?? "nil") frame=\($0.frame) image=\($0.image != nil)"}.joined(separator:"; ")+" loader=\(loader.image != nil) show=\(model.showGravatar)")}
        if CommandLine.arguments[2]=="/usr/bin/git", let output=ProcessInfo.processInfo.environment["TURTLEGIT_BLAME_DETAILS_CAPTURE"] {
            let directory=URL(fileURLWithPath:output);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try choose("basic.8")
            for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",.darkAqua)] {
                window.appearance=NSAppearance(named:appearance);window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds:80_000_000)
                guard let content=window.contentView,let bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds) else {throw Failure(description:"Native detail snapshot unavailable")}
                content.cacheDisplay(in:content.bounds,to:bitmap)
                guard let bytes=bitmap.representation(using:.png,properties:[:]) else {throw Failure(description:"Native detail snapshot encoding failed")}
                try bytes.write(to:directory.appendingPathComponent("blame-author-details-"+name+".png"))
            }
        }
        // The source avatar follows the newly selected row while Properties clears.
        model.focusHistory([parent.hash,child.hash],focus:child.hash)
        try await wait("newly selected author during multi-selection") {BlameAvatarTransport.waiting==1}
        try require(model.selectedHistoryEntry==nil && details.parents.isEmpty && details.basic.allSatisfy{$0.value.isEmpty} && loader.image==nil,"Multi-selection retained properties or the previous author picture")
        try require(BlameAvatarTransport.last==LogGravatarRequest.url(email:child.email,template:prefs.string(forKey:"GravatarUrl")!,useMD5:false),"Multi-selection avatar used wrong author")
        // Disable cancels the actual pending URLSession request and removes reserved space.
        prefs.set(false,forKey:"EnableGravatar");model.refreshAuthorPreferences()
        try await wait("disabled request drained") {BlameAvatarTransport.waiting==0 && loader.image==nil}
        for appearance in [NSAppearance.Name.aqua,.darkAqua] {
            window.appearance=NSAppearance(named:appearance);model.focusHistory([child.hash],focus:child.hash)
            coordinator.update();try choose("basic.8");window.contentView?.layoutSubtreeIfNeeded()
            try require(details.selected?.description==body.trimmingCharacters(in:.whitespacesAndNewlines) && grid.numberOfRows>=11,"Native details lost controls/value after appearance change")
        }
        // Exact Unicode value changes must reload the native row, not normalize it.
        var alias=child;alias.message="Child subject\n\né";model.historyEntries=[alias,parent];model.focusHistory([child.hash],focus:child.hash);coordinator.update();try choose("basic.8")
        let first=details.basic[8];alias.message="Child subject\n\ne\u{301}";model.historyEntries=[alias,parent];coordinator.update()
        try require(first != details.basic[8] && Data(details.basic[8].value.utf8)==Data("e\u{301}".utf8),"Canonical property edit aliased native value")
        // Property state belongs to the document across native dock/floating rebuilds.
        model.setPanePlacement(.properties,.floating)
        try await wait("floating selected property") {controller.floatingPaneWindow(.properties) != nil}
        let floating=controller.floatingPaneWindow(.properties)!
        try await wait("floating native grid") {views(floating.contentView).contains{$0 is BlamePropertiesTable}}
        try require(Data(details.selected?.value.utf8 ?? "".utf8)==Data("e\u{301}".utf8),"Floating Properties lost exact selected value")
        model.setPanePlacement(.properties,.right)
        try await wait("property redock") {controller.floatingPaneWindow(.properties)==nil && views(window.contentView).contains{$0 is BlamePropertiesTable}}
        // Retire while an injected request is still outstanding; no late image may publish.
        prefs.set("https://avatar.invalid/retiring/%HASH%",forKey:"GravatarUrl");prefs.set(true,forKey:"EnableGravatar");model.refreshAuthorPreferences()
        try await wait("owned retiring request") {BlameAvatarTransport.waiting==1}
        controller.close();try await wait("owned avatar/window retirement") {drained() && !window.isVisible && window.sheetParent==nil}
        BlameAvatarTransport.respond(png);try await Task.sleep(nanoseconds:30_000_000)
        try require(loader.image==nil && model.retired,"Retired author image republished")
        let after=try baselinePaths.map{try Data(contentsOf:root.appendingPathComponent($0))};try require(after==baseline,"Read-only Blame details changed repository bytes")
        print("PASS Blame author/details: source fields, full descriptions, exact Copy/menu icons, collapsible groups, parent subjects, multi-selection avatar, opt-in/cache requests and real retirement; light/dark native controls")
    }
}
