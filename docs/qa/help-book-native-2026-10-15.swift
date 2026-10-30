// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

@main struct HelpBookVerification {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct Catalog:Decodable {
        struct Topic:Decodable {let id:String;let document:String}
        let topics:[Topic]
    }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw Failure(description: message) } }
    @MainActor static func wait(line: UInt = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(nanoseconds:10_000_000) }
        throw Failure(description:"Help fixture did not settle at line \(line)")
    }
    @MainActor static func views(_ view:NSView)->[NSView] { [view] + view.subviews.flatMap(views) }
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        guard let bundle=Bundle(path:CommandLine.arguments[1]) else { throw Failure(description:"Missing built application bundle") }
        let service=TurtleGitHelpService(bundle:bundle)
        guard let book=service.bookURL else {throw Failure(description:"Missing bundled Help book")}
        let resources=book.appendingPathComponent("Contents/Resources/en.lproj")
        let catalog=try JSONDecoder().decode(Catalog.self,from:Data(contentsOf:resources.appendingPathComponent("topics.json")))
        let bundledIDs=catalog.topics.map(\.id),nativeIDs=TurtleGitHelpTopic.allCases.map(\.rawValue)
        try require(!bundledIDs.isEmpty && Set(bundledIDs).count==bundledIDs.count && Set(nativeIDs).isSubset(of:Set(bundledIDs)),"Duplicate/missing bundled Help topic identity")
        for topic in catalog.topics {
            try require(!topic.document.contains("/") && topic.document.hasSuffix(".md"),"Invalid bundled Help document: "+topic.id)
            let page=resources.appendingPathComponent(String(topic.document.dropLast(3))+".html")
            let html=try String(contentsOf:page,encoding:.utf8)
            try require(html.contains("name=\"topic-"+topic.id+"\""),"Missing bundled topic anchor: "+topic.id)
        }
        try require(Set(service.topics.keys)==Set(TurtleGitHelpTopic.allCases.map(\.rawValue)),"Bundled topic catalogue differs from native routes")
        var registrations=0, anchors:[String]=[], urls:[URL]=[]
        service.registerBook={_ in registrations += 1; return true}; service.openAnchor={ anchor,book in anchors.append(book+"#"+anchor) }; service.openURL={ urls.append($0) }
        for topic in TurtleGitHelpTopic.allCases {
            guard let url=service.localURL(for:topic) else { throw Failure(description:"Missing local topic: "+topic.rawValue) }
            let html=try String(contentsOf:url,encoding:.utf8)
            try require(html.contains("name=\"topic-"+topic.rawValue+"\""),"Missing named topic anchor: "+topic.rawValue)
            service.show(topic)
        }
        try require(registrations==1 && anchors.count==TurtleGitHelpTopic.allCases.count && urls.isEmpty,"Help registration/anchor dispatch")
        try require(anchors.contains("org.turtlegit.macos.help#topic-commit"),"Help uses bundled book identifier")
        let fallback=TurtleGitHelpService(bundle:bundle); fallback.registerBook={_ in false}; fallback.openURL={urls.append($0)}
        fallback.show(.push)
        try require(urls.last?.isFileURL==true && urls.last?.fragment=="push","Failed registration loses offline topic fallback")
        let missing=TurtleGitHelpService(bundle:Bundle(for:NSWindow.self)); missing.openURL={urls.append($0)}; missing.show(.commit)
        try require(urls.last?.host=="jfk-solutions.github.io" && urls.last?.path.hasSuffix("GETTING-STARTED.html")==true,"Missing book fallback is not Mac documentation")
        let old=TurtleGitHelp.service; TurtleGitHelp.service=service; defer { TurtleGitHelp.service=old }
        let repository=GitRepository(root:URL(fileURLWithPath:CommandLine.arguments[2]))
        let suite="TurtleGit.Help.QA."+UUID().uuidString, preferences=UserDefaults(suiteName:suite)!
        defer { preferences.removePersistentDomain(forName:suite) }
        let commit=CommitWindowController(repository:repository,access:nil,defaults:preferences)
        let fetch=FetchWindowController(repository:repository,access:nil,isPull:true,preferences:preferences)
        for window in [commit.window,fetch.window].compactMap({$0}){window.alphaValue=0;window.setFrameOrigin(.init(x:-18000,y:-18000))}
        defer { commit.close(); fetch.close() }
        try require(TurtleGitHelp.context(commit.window) == .commit && TurtleGitHelp.context(fetch.window) == .pull,"Actual repository controller context")
        // Reformatting a title must retain its semantic topic; dynamic Rebase titles map too.
        RepositoryWindowTitles.set(commit.window,repository:repository.root,dialog:"Commit",preferences:preferences)
        try require(TurtleGitHelp.context(commit.window) == .commit && TurtleGitHelp.topic(dialog:"Cherry Pick") == .cherryPick && TurtleGitHelp.topic(dialog:"Request pull") == .patches,"Semantic context mapping")
        let window=commit.window!; window.alphaValue=0; window.orderFront(nil)
        func key(_ code:UInt16,_ modifiers:NSEvent.ModifierFlags=[])->NSEvent { NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code)! }
        let count=anchors.count
        try require(TurtleGitHelp.handleHelpKey(key(122)) && anchors.last?.hasSuffix("#topic-commit")==true,"F1 context dispatch")
        try require(!TurtleGitHelp.handleHelpKey(key(122,.option)) && anchors.count==count+1,"Modified F1 was consumed")
        let sheet=NSWindow(contentRect:.init(x:0,y:0,width:260,height:120),styleMask:[.titled],backing:.buffered,defer:false);sheet.isReleasedWhenClosed=false
        sheet.alphaValue=0;sheet.setFrameOrigin(.init(x:-18000,y:-18000))
        window.beginSheet(sheet,completionHandler:{ (_: NSApplication.ModalResponse) in })
        try require(TurtleGitHelp.context(sheet) == .commit,"Owned sheet inherits repository context")
        TurtleGitHelp.attach(sheet,topic:.authentication);try require(TurtleGitHelp.context(sheet) == .authentication,"Sheet-specific topic overrides parent")
        window.endSheet(sheet);sheet.orderOut(nil);sheet.close();try await wait { window.attachedSheet==nil }
        commit.close();try require(TurtleGitHelp.context(window) == .overview,"Closed context remains registered")
        // Actual Settings footer Help button uses the selected page's topic.
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false), appearance=AppAppearance(preferences:preferences)
        let navigation=SettingsNavigationController(workspace:workspace,appearance:appearance,globalOnly:true,preferences:preferences,initialPage:.savedData)
        let settings=NSWindow(contentRect:.init(x:0,y:0,width:1040,height:740),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        settings.isReleasedWhenClosed=false;settings.contentViewController=navigation;settings.alphaValue=0;settings.setFrameOrigin(.init(x:-18000,y:-18000));settings.orderFront(nil)
        defer { navigation.invalidate();settings.close() }
        settings.contentView?.layoutSubtreeIfNeeded()
        guard let help=views(settings.contentView!).compactMap({$0 as? NSButton}).first(where:{$0.title=="Help"}) else { throw Failure(description:"Missing native Settings Help button") }
        try require(NSApp.sendAction(help.action!,to:help.target,from:help) && anchors.last?.hasSuffix("#topic-savedData")==true,"Settings Help topic dispatch")
        let info=try PropertyListSerialization.propertyList(from:Data(contentsOf:book.appendingPathComponent("Contents/Info.plist")),format:nil) as? [String:Any]
        try require(info?["HPDBookCSIndexPath"] as? String == "TurtleGitHelp.cshelpindex" && info?["HPDBookIndexPath"] == nil,"Help book does not declare its current CoreSpotlight index")
        let index=book.appendingPathComponent("Contents/Resources/en.lproj/TurtleGitHelp.cshelpindex")
        try require((try Data(contentsOf:index)).count>0,"Missing built CoreSpotlight Help search/anchor index")
        print("PASS: \(bundledIDs.count) bundled topics, \(nativeIDs.count) native routes, registration/anchor and offline fallback routing, real controller/Settings Help, F1/sheets/close lifetime, built index")
        let report:[String:Any] = ["bundledTopics":bundledIDs.sorted(),"nativeRoutes":nativeIDs.sorted()]
        print("HELP_BOOK_COMPLETED: "+String(data:try JSONSerialization.data(withJSONObject:report,options:.sortedKeys),encoding:.utf8)!)
    }
}
