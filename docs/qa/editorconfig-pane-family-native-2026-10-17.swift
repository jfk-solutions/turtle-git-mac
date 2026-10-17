import AppKit
import TurtleGitCore

final class EditorConfigGate: @unchecked Sendable {
    let released = DispatchSemaphore(value:0)
    private let lock = NSLock()
    private var began = false
    var started: Bool { lock.lock(); defer {lock.unlock()}; return began }
    func run() -> MergeEditorConfigProperties { lock.lock(); began=true; lock.unlock(); _=released.wait(timeout:.now()+10);return .init(properties:["tab_width":"99"]) }
}
@main struct EditorConfigPaneFamilyVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:message)}}
    @MainActor static func wait(_ condition:()->Bool) async throws {
        for _ in 0..<1000 {if condition(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"Timed out waiting for pane family")
    }
    @MainActor static func main() async throws {
        NSApp.setActivationPolicy(.prohibited)
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),parser=URL(fileURLWithPath:CommandLine.arguments[3])
        let suite="TurtleGit.EditorConfig.Panes."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        MergeEditorPreferences().save(to:defaults)
        defaults.set(false,forKey:"TurtleGitMerge.FirstDiff");defaults.set(false,forKey:"TurtleGitMerge.FirstConflict")
        func read()->MergeEditorConfigRead {let value=MergeEditorConfigRead();value.folderAccess.requireScope=false;value.resolve={try EditorConfigRuntime.resolve(file:$0,executable:parser,cancellation:$1)};return value}
        let left=root.appendingPathComponent("left"),right=root.appendingPathComponent("right")
        try Data("left\n".utf8).write(to:left);try Data("right\n".utf8).write(to:right)
        try Data("root=true\n[*]\ntab_width=7\nindent_style=space\n".utf8).write(to:root.appendingPathComponent(".editorconfig"))
        let owner=FileComparisonWindowController(comparison:try WorkingFileComparison(base:left,destination:right),permissions:[],preferences:defaults)
        defer {owner.close()};let model=owner.model,window=owner.window!
        window.alphaValue=0;window.orderFront(nil);model.makeEditorConfigRead=read;model.load()
        try await wait {!model.busy && !model.filtering && model.document != nil}
        try require(!model.captureTabCommand(base:true).writable,"Read-only tab commands enabled")
        model.activatePane(base:false);model.editingEnabled=true
        let first=model.captureTabCommand(base:false)
        try require(first.writable && !first.editorConfigLoaded,"Writable initial pane state")
        model.applyTabCommand(first,base:false,action:.width(8))
        model.applyTabCommand(first,base:false,action:.spaces(true))
        try require(model.tabWidth(base:false)==8 && !model.useSpaces(base:false),"Retired tab callback was accepted")
        let stale=model.captureTabCommand(base:false);model.busy=true;model.busy=false
        model.applyTabCommand(stale,base:false,action:.width(1));try require(model.tabWidth(base:false)==8,"Busy epoch replay")
        model.setEditorConfig(true,base:false)
        try await wait {model.editorConfigLoading.isEmpty}
        try require(model.editorConfigLoaded[false]==true && model.tabWidth(base:false)==7 && model.useSpaces(base:false),"Real parser result was not applied")
        model.applyTabCommand(model.captureTabCommand(base:false),base:false,action:.editorConfig(false))
        try require(model.editorConfigLoaded[false]==true && model.tabWidth(base:false)==4 && !model.useSpaces(base:false),"Source loaded-state/default reset")
        model.applyTabCommand(model.captureTabCommand(base:false),base:false,action:.editorConfig(true))
        try await wait {model.editorConfigLoading.isEmpty}
        try require(model.tabWidth(base:false)==7,"Re-enable from retained loaded state")
        let gate=EditorConfigGate(),held=MergeEditorConfigRead();held.folderAccess.requireScope=false;held.resolve={_,_ in gate.run()}
        model.makeEditorConfigRead={held};model.setEditorConfig(true,base:false)
        try await wait {gate.started};let count=MergeRegexOperations.activeRequests
        try require(count>0,"Read did not own Quit lifetime")
        owner.close();try require(held.cancellation.isCancelled && MergeRegexOperations.activeRequests==count,"Close dropped undrained read")
        gate.released.signal();try await wait {MergeRegexOperations.activeRequests==0}
        try require(model.tabWidth(base:false) != 99,"Late parser result updated retired model")
        try require(try Data(contentsOf:left)==Data("left\n".utf8) && Data(contentsOf:right)==Data("right\n".utf8),"Tab settings wrote input files")
        let folder=root.appendingPathComponent("repo");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let repo=GitRepository(root:folder,executable:git),file=folder.appendingPathComponent("file.txt")
        _=try await repo.run(["init","-b","main"])
        for (key,value) in [("user.name","Pane QA"),("user.email","pane@example.invalid"),("commit.gpgsign","false")] {_=try await repo.run(["config",key,value])}
        try Data("base\n".utf8).write(to:file);try await repo.stage(["file.txt"]);_=try await repo.commit(message:"base")
        _=try await repo.run(["checkout","-b","other"]);try Data("theirs\n".utf8).write(to:file);try await repo.stage(["file.txt"]);_=try await repo.commit(message:"theirs")
        _=try await repo.run(["checkout","main"]);try Data("mine\n".utf8).write(to:file);try await repo.stage(["file.txt"]);_=try await repo.commit(message:"mine")
        _=try await repo.run(["merge","--no-edit","other"],successfulExitCodes:0...1)
        let index=try Data(contentsOf:folder.appendingPathComponent(".git/index")),working=try Data(contentsOf:file)
        let conflict=TextConflictWindowController(repository:repo,access:nil,path:"file.txt",preferences:defaults)
        defer {conflict.close()};let merge=conflict.model
        conflict.window!.alphaValue=0;conflict.window!.orderFront(nil);merge.makeEditorConfigRead=read;merge.load()
        try await wait {!merge.busy && merge.document != nil && merge.sourceToolsAllowed}
        let pane="Merged · \(merge.resultPath)",original=merge.result
        try require(!merge.captureTabCommand(pane:"Mine").writable && merge.captureTabCommand(pane:pane).writable,"Conflict pane writability")
        merge.setEditorConfig(true,pane:pane);try await wait {merge.editorConfigLoading.isEmpty}
        try require(merge.tabWidths[pane]==7 && merge.spacePanes[pane]==true,"Merge parser settings")
        let command=merge.captureTabCommand(pane:pane);merge.applyTabCommand(command,pane:pane,action:.smart(true));merge.applyTabCommand(command,pane:pane,action:.width(1))
        try require(merge.smartTabPanes[pane]==true && merge.tabWidths[pane]==7,"Merge captured command ownership")
        try require(merge.result==original && Data(contentsOf:folder.appendingPathComponent(".git/index"))==index && Data(contentsOf:file)==working,"Merge settings changed result/index/working bytes")
        conflict.close();try await wait {MergeRegexOperations.activeRequests==0}
        // Exercise the shipping owned permission sheet and cancellation drain.
        let panelWindow=NSWindow(contentRect:NSRect(x:0,y:0,width:400,height:220),styleMask:[.titled],backing:.buffered,defer:false)
        panelWindow.isReleasedWhenClosed=false;defer {panelWindow.close()};panelWindow.alphaValue=0;panelWindow.orderFront(nil)
        let panelRead=MergeEditorConfigRead();panelRead.folderAccess.requireScope=true
        var done=false,cancelled=false
        Task {defer {done=true};do {_=try await panelRead.read(file:right,permissions:[],window:panelWindow)}catch {cancelled=panelRead.cancellation.isCancelled}}
        try await wait {panelRead.folderAccess.panel != nil}
        try require(panelRead.folderAccess.panel?.prompt=="Read EditorConfig" && MergeRegexOperations.activeRequests>0,"EditorConfig permission sheet/lifetime")
        panelRead.cancel();try await wait {done && panelWindow.attachedSheet==nil}
        try require(cancelled && MergeRegexOperations.activeRequests==0,"Permission sheet cancellation did not drain")
        print("PASS EditorConfig pane family: real parser Compare/Merge, writable/loaded gates, captured commands, retained loaded flag, busy retirement, owned permission sheet, late read rejection and retained drain lifetime; input/index/result unchanged; owned windows closed")
    }
}
