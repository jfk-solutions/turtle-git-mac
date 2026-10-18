// SPDX-License-Identifier: GPL-2.0-or-later
// Native caller/approval adaptation of Utils/Hooks.cpp.
import AppKit
import SwiftUI
import TurtleGitCore

struct ClientHookOperationFailure: LocalizedError {
    let type:ClientHookType, code:Int32, detail:String
    var errorDescription:String? { "\(type.title) failed (exit \(code)).\n\n" + detail }
}

@MainActor enum ClientHookScriptAccess {
    struct Bookmark:Codable {let path:String;let data:Data}
    struct ScopeIO {
        var resolve:(Data)throws->(url:URL,stale:Bool)
        var bookmark:(URL)throws->Data
        var start:(URL)->Bool
        var stop:(URL)->Void
        static var live:ScopeIO {ScopeIO(resolve:{data in
            var stale=false
            let url=try URL(resolvingBookmarkData:data,options:[.withSecurityScope,.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale)
            return(url,stale)
        },bookmark:{try $0.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil)},start:{$0.startAccessingSecurityScopedResource()},stop:{$0.stopAccessingSecurityScopedResource()})}
    }
    /// A launch retains each acquired grant through actual process completion.
    /// Release is idempotent so partial acquisition and launch errors share cleanup.
    final class Lease {
        let url:URL
        private var stop:((URL)->Void)?
        init(url:URL,stop:@escaping(URL)->Void){self.url=url;self.stop=stop}
        func release(){guard let stop else{return};self.stop=nil;stop(url)}
    }
    private static let bookmarkKey="ClientHooks.ScriptAccess.v2"
    private static func entries(_ preferences:UserDefaults)->[Bookmark] {
        if let data=preferences.data(forKey:bookmarkKey) {return (try? JSONDecoder().decode([Bookmark].self,from:data)) ?? []}
        // Preserve old ordinary grants. A legacy dictionary may already have
        // collapsed Unicode keys; the resolved URL is independently checked.
        let legacy=preferences.dictionary(forKey:"ClientHooks.ScriptBookmarks") as? [String:Data] ?? [:]
        return legacy.map{Bookmark(path:$0.key,data:$0.value)}
    }
    static func storeBookmark(_ data:Data,for url:URL,preferences:UserDefaults)throws {
        let path=url.path
        var values=entries(preferences).filter{!GitReferenceName.equal($0.path,path)}
        values.append(Bookmark(path:path,data:data));values.sort{$0.path.utf8.lexicographicallyPrecedes($1.path.utf8)}
        preferences.set(try JSONEncoder().encode(values),forKey:bookmarkKey)
    }
    static func bookmark(for url:URL,preferences:UserDefaults)->Data? {
        entries(preferences).first{GitReferenceName.equal($0.path,url.path)}?.data
    }
    static func remember(_ url:URL,preferences:UserDefaults)throws {
        guard GitRuntime.isAppStoreBuild else{return}
        try storeBookmark(ScopeIO.live.bookmark(url),for:url,preferences:preferences)
    }
    static func acquire(_ command:String,root:URL,access:RepositoryAccessLease?,preferences:UserDefaults,
                        appStore:Bool=GitRuntime.isAppStoreBuild,io:ScopeIO? = nil)throws->[Lease] {
        guard appStore else{return []}
        let io=io ?? .live
        guard access?.hasSecurityScope==true,access?.contains(root)==true else{throw RepositoryAccessFailure.securityScopeUnavailable}
        let words=try ClientHookCommand.arguments(command,root:root.path)
        var scopes:[Lease]=[],seen=Set<String>()
        do {
            for word in words where !word.hasPrefix("-") && !word.isEmpty {
                // Standardizing a filesystem URL can rewrite Unicode. Clean
                // only lexical dot components and retain the command's bytes.
                var components:[Substring]=[]
                for part in (word.hasPrefix("/") ? word:root.path+"/"+word).split(separator:"/") {
                    if part == "." {continue};if part == ".." {if !components.isEmpty{components.removeLast()}}else{components.append(part)}
                }
                let path="/"+components.joined(separator:"/"),url=URL(fileURLWithPath:path)
                guard FileManager.default.fileExists(atPath:path),access?.permits(url) != true else{continue}
                if ["/bin/","/usr/bin/","/usr/sbin/","/sbin/"].contains(where:{path.hasPrefix($0)}){continue}
                guard seen.insert(GitPathRowIdentity.encode(path)).inserted else{continue}
                guard let data=entries(preferences).first(where:{GitReferenceName.equal($0.path,path)})?.data else{throw RepositoryAccessFailure.securityScopeUnavailable}
                let resolved=try io.resolve(data),actual=resolved.url
                guard actual.isFileURL,GitReferenceName.equal(actual.path,path),io.start(resolved.url) else{throw RepositoryAccessFailure.securityScopeUnavailable}
                let lease=Lease(url:resolved.url,stop:io.stop);scopes.append(lease)
                if resolved.stale {try storeBookmark(io.bookmark(resolved.url),for:resolved.url,preferences:preferences)}
            }
            return scopes
        }catch{scopes.forEach{$0.release()};throw RepositoryAccessFailure.securityScopeUnavailable}
    }
}

@MainActor final class ClientHookProcessPool: ObservableObject {
    static let shared = ClientHookProcessPool()
    @Published private(set) var activeScripts = 0
    private var executions:[UUID:ClientHookExecution] = [:]
    private var pending:[UUID:OperationCancellation] = [:]
    private var consoles:[UUID:HookScriptConsole] = [:]
    func cancelAll() { pending.values.forEach{$0.cancel()};for execution in executions.values { execution.cancel() } }
    private func updateCount(){activeScripts=executions.count+pending.count}
    func execute(_ invocation:ClientHookInvocation,access:RepositoryAccessLease?,scopes:[ClientHookScriptAccess.Lease],cancellation:OperationCancellation,sourceWindow:NSWindow? = nil) async throws -> ClientHookResult {
        let id=UUID();pending[id]=cancellation;updateCount()
        let execution:ClientHookExecution
        do { execution = try await ClientHookExecution.start(invocation:invocation,cancellation:cancellation) }
        catch {pending.removeValue(forKey:id);updateCount();scopes.forEach { $0.release() };throw error}
        pending.removeValue(forKey:id);executions[id]=execution;updateCount()
        if invocation.hook.show, !cancellation.isCancelled {
            let console = HookScriptConsole(type:invocation.hook.type,command:invocation.hook.command,cancel:execution.cancel,sourceWindow:sourceWindow)
            consoles[id] = console; console.showWindow(nil)
        }
        Task {
            _ = try? await execution.completion.value
            consoles.removeValue(forKey:id)?.finish()
            executions.removeValue(forKey:id);updateCount()
            scopes.forEach { $0.release() }; withExtendedLifetime(access) {}
        }
        // Non-wait source callers continue immediately, retaining the original
        // message. Pool ownership keeps files, access and children alive to exit.
        if !invocation.hook.wait { return ClientHookResult(exitCode:0,output:"",error:"",message:invocation.originalMessage) }
        return try await execution.completion.value
    }
}

@MainActor final class ClientHookSession {
    struct Approval { let approved:Bool; let remember:Bool; let cancelled:Bool }
    let preferences:UserDefaults
    var windowProvider:() -> NSWindow? = { nil }
    var approval:((ClientHook) async -> Approval)?
    var continueAfterFailure:((ClientHookOperationFailure) async -> Bool)?
    private(set) static var activeOperations=0
    private(set) static var activeQuestionReleases=0
    var readProjectHooks:((GitRepository,OperationCancellation)async throws->[ClientHook])?
    var presentQuestion:(NSWindow,NSAlert,@escaping(NSApplication.ModalResponse)->Void)->Bool = {owner,alert,reply in
        guard owner.attachedSheet==nil else{return false};alert.beginSheetModal(for:owner,completionHandler:reply);return true
    }
    private var operations:[UUID:OperationCancellation] = [:]
    private var retired = false
    private final class Question {
        let id=UUID(),alert:NSAlert
        let cancellation:OperationCancellation
        var watcher:Task<Void,Never>?
        let reply:(NSApplication.ModalResponse?,Bool)->Void
        var settling=false
        init(alert:NSAlert,cancellation:OperationCancellation,reply:@escaping(NSApplication.ModalResponse?,Bool)->Void){self.alert=alert;self.cancellation=cancellation;self.reply=reply}
    }
    private var question:Question?
    var questionWindow:NSWindow? {question?.alert.window}

    init(preferences:UserDefaults = .standard) { self.preferences = preferences }
    func retire() {
        retired=true;operations.values.forEach{$0.cancel()}
        if let question {settleQuestion(question,response:nil)}
    }
    func run(_ type:ClientHookType,repository:GitRepository,access:RepositoryAccessLease?,paths:[String] = [],message:String = "",amend:Bool = false,error:String = "",upstream:String = "",rebasedBranch:String = "",cancellation:OperationCancellation? = nil,allowContinue:Bool = false) async throws -> ClientHookResult? {
        guard !retired else { throw OperationCancellationFailure.cancelled }
        let id = UUID(), token = cancellation ?? OperationCancellation(); operations[id] = token;Self.activeOperations += 1
        defer {operations.removeValue(forKey:id);Self.activeOperations -= 1;withExtendedLifetime(access){}}
        return try await withTaskCancellationHandler(operation:{
            @MainActor func check() throws { try Task.checkCancellation(); if retired || token.isCancelled || operations[id] !== token { throw OperationCancellationFailure.cancelled } }
            try check()
            var hooks = ClientHookPreferences.globals(preferences)
            if let readProjectHooks {hooks += try await readProjectHooks(repository,token)} else {hooks += try await repository.projectClientHooks(cancellation:token)}
            try check()
            guard let hook = ClientHookConfiguration.selected(type:type,workingTree:repository.root,hooks:hooks) else { return nil }
            if hook.local {
                let accepted:Bool
                if let stored = ClientHookPreferences.decision(hook,preferences:preferences) { accepted = stored }
                else {
                    let response = await ask(hook,cancellation:token); try check()
                    if response.cancelled { throw OperationCancellationFailure.cancelled }
                    if response.remember { try ClientHookPreferences.remember(hook,approved:response.approved,preferences:preferences) }
                    accepted = response.approved
                }
                if !accepted { return nil }
            }
            try check()
            var failedResult:ClientHookResult?
            do {
                let scopes = try ClientHookScriptAccess.acquire(hook.command,root:repository.root,access:access,preferences:preferences)
                let invocation:ClientHookInvocation
                do { invocation = try ClientHookInvocation(hook:hook,workingTree:repository.root,paths:paths,message:message,amend:amend,error:error,upstream:upstream,rebasedBranch:rebasedBranch) }
                catch { scopes.forEach { $0.release() }; throw error }
                let result = try await ClientHookProcessPool.shared.execute(invocation,access:access,scopes:scopes,cancellation:token,sourceWindow:windowProvider())
                try check()
                if result.exitCode != 0 {
                    failedResult = result
                    throw ClientHookOperationFailure(type:type,code:result.exitCode,detail:result.error.isEmpty ? result.output:result.error)
                }
                return result
            } catch {
                // Cancellation/retirement and missing security scope must not turn
                // into an overridable command failure. Never launch on Continue.
                try check()
                if error is OperationCancellationFailure || error is CancellationError || error is RepositoryAccessFailure { throw error }
                let failure = (error as? ClientHookOperationFailure) ?? ClientHookOperationFailure(type:type,code:-1,detail:error.localizedDescription)
                if allowContinue, await continueFailure(failure,cancellation:token) {
                    try check()
                    return failedResult ?? ClientHookResult(exitCode:failure.code,output:"",error:failure.detail,message:message)
                }
                try check()
                throw failure
            }
        },onCancel:{token.cancel()})
    }
    private func showQuestion(_ alert:NSAlert,cancellation:OperationCancellation)async->(NSApplication.ModalResponse?,Bool) {
        guard !retired,!cancellation.isCancelled,question==nil,let owner=windowProvider(),owner.attachedSheet==nil else{return(nil,false)}
        alert.window.alphaValue=owner.alphaValue;alert.window.appearance=owner.effectiveAppearance
        return await withCheckedContinuation{continuation in
            let pending=Question(alert:alert,cancellation:cancellation){response,remember in continuation.resume(returning:(response,remember))}
            question=pending
            pending.watcher=Task { [weak self,weak pending] in
                while !Task.isCancelled {
                    guard let self,let pending,self.question === pending,!pending.settling else{return}
                    if cancellation.isCancelled {self.settleQuestion(pending,response:nil);return}
                    try? await Task.sleep(nanoseconds:10_000_000)
                }
            }
            if !presentQuestion(owner,alert,{ [weak self,weak pending] response in
                guard let self,let pending else{return};self.settleQuestion(pending,response:response)
            }) {settleQuestion(pending,response:nil)}
        }
    }
    private func settleQuestion(_ pending:Question,response:NSApplication.ModalResponse?) {
        guard question === pending,!pending.settling else{return};pending.settling=true;pending.watcher?.cancel();pending.watcher=nil
        let remember=pending.alert.suppressionButton?.state == .on
        Self.activeQuestionReleases += 1
        Task { [self,pending] in
            defer{Self.activeQuestionReleases -= 1}
            let child=pending.alert.window,parent=child.sheetParent
            parent?.endSheet(child,returnCode:response ?? .abort);child.orderOut(nil)
            while child.sheetParent != nil || parent?.attachedSheet === child {try? await Task.sleep(nanoseconds:5_000_000)}
            if question === pending {question=nil}
            pending.reply(retired ? nil:response,remember)
        }
    }
    private func ask(_ hook:ClientHook,cancellation:OperationCancellation) async -> Approval {
        if let approval {return await approval(hook)}
        let alert=NSAlert();alert.messageText="Run this repository hook script?"
        alert.informativeText=hook.command+"\n\nOnly run scripts from repositories you trust."
        alert.addButton(withTitle:"Yes");let no=alert.addButton(withTitle:"No");alert.addButton(withTitle:"Cancel")
        alert.showsSuppressionButton=true;alert.suppressionButton?.title="Do not ask again for this script"
        // NSAlert creates/layouts its window lazily and assigns the first
        // button's Return key then. Install the source No default afterwards.
        alert.layout();let window=alert.window
        alert.buttons.first?.keyEquivalent="";no.keyEquivalent="\r";window.defaultButtonCell=no.cell as? NSButtonCell
        let (response,remember)=await showQuestion(alert,cancellation:cancellation)
        return Approval(approved:response == .alertFirstButtonReturn,remember:remember,cancelled:response != .alertFirstButtonReturn && response != .alertSecondButtonReturn)
    }
    private func continueFailure(_ failure:ClientHookOperationFailure,cancellation:OperationCancellation) async -> Bool {
        if let continueAfterFailure {return await continueAfterFailure(failure)}
        let alert=NSAlert();alert.messageText="Hook script failed";alert.informativeText=failure.localizedDescription
        alert.addButton(withTitle:"Abort");alert.addButton(withTitle:"Continue")
        let (response,_)=await showQuestion(alert,cancellation:cancellation)
        return !retired && response == .alertSecondButtonReturn
    }
}

@MainActor private final class HookScriptConsole:NSWindowController,NSWindowDelegate {
    private var running = true
    private let cancelScript:() -> Void
    init(type:ClientHookType,command:String,cancel:@escaping () -> Void,sourceWindow:NSWindow?) {
        cancelScript = cancel
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:620,height:170),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = type.title + " – TurtleGit for Mac"; window.isReleasedWhenClosed = false
        if let sourceWindow {window.alphaValue=sourceWindow.alphaValue;window.appearance=sourceWindow.effectiveAppearance}
        super.init(window:window); window.delegate = self
        window.contentViewController = NSHostingController(rootView:VStack(alignment:.leading,spacing:16) { Text(command).textSelection(.enabled); HStack { ProgressView().controlSize(.small); Text("Running hook script…"); Spacer(); Button("Cancel Script",action:cancel) } }.padding(20))
        window.center()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    func finish() { running = false; window?.close() }
    func windowShouldClose(_ sender:NSWindow) -> Bool { if running { cancelScript(); return false }; return true }
}
