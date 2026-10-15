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
    static func remember(_ url:URL,preferences:UserDefaults) throws {
        guard GitRuntime.isAppStoreBuild else { return }
        var values = preferences.dictionary(forKey:"ClientHooks.ScriptBookmarks") as? [String:Data] ?? [:]
        values[url.path] = try url.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil)
        preferences.set(values,forKey:"ClientHooks.ScriptBookmarks")
    }
    static func acquire(_ command:String,root:URL,access:RepositoryAccessLease?,preferences:UserDefaults) throws -> [URL] {
        guard GitRuntime.isAppStoreBuild else { return [] }
        guard access?.hasSecurityScope == true, access?.contains(root) == true else { throw RepositoryAccessFailure.securityScopeUnavailable }
        let words = try ClientHookCommand.arguments(command,root:root.path), values = preferences.dictionary(forKey:"ClientHooks.ScriptBookmarks") as? [String:Data] ?? [:]
        var scopes:[URL] = []
        do {
            for word in words where !word.hasPrefix("-") && !word.isEmpty {
                let url = word.hasPrefix("/") ? URL(fileURLWithPath:word) : root.appendingPathComponent(word)
                guard FileManager.default.fileExists(atPath:url.path), access?.permits(url) != true else { continue }
                if ["/bin/","/usr/bin/","/usr/sbin/","/sbin/"].contains(where:{url.path.hasPrefix($0)}) { continue }
                guard let data = values[url.path] else { throw RepositoryAccessFailure.securityScopeUnavailable }
                var stale = false
                let resolved = try URL(resolvingBookmarkData:data,options:.withSecurityScope,relativeTo:nil,bookmarkDataIsStale:&stale)
                guard !stale, resolved.standardizedFileURL == url.standardizedFileURL, resolved.startAccessingSecurityScopedResource() else { throw RepositoryAccessFailure.securityScopeUnavailable }
                scopes.append(resolved)
            }
            return scopes
        } catch { scopes.forEach { $0.stopAccessingSecurityScopedResource() }; throw error }
    }
}

@MainActor final class ClientHookProcessPool: ObservableObject {
    static let shared = ClientHookProcessPool()
    @Published private(set) var activeScripts = 0
    private var executions:[UUID:ClientHookExecution] = [:]
    private var consoles:[UUID:HookScriptConsole] = [:]
    func cancelAll() { for execution in executions.values { execution.cancel() } }
    func execute(_ invocation:ClientHookInvocation,access:RepositoryAccessLease?,scopes:[URL],cancellation:OperationCancellation) async throws -> ClientHookResult {
        let execution:ClientHookExecution
        do { execution = try await ClientHookExecution.start(invocation:invocation,cancellation:cancellation) }
        catch { scopes.forEach { $0.stopAccessingSecurityScopedResource() }; throw error }
        let id = UUID(); executions[id] = execution; activeScripts = executions.count
        if invocation.hook.show {
            let console = HookScriptConsole(type:invocation.hook.type,command:invocation.hook.command,cancel:execution.cancel)
            consoles[id] = console; console.showWindow(nil)
        }
        Task {
            _ = try? await execution.completion.value
            consoles.removeValue(forKey:id)?.finish()
            executions.removeValue(forKey:id); activeScripts = executions.count
            scopes.forEach { $0.stopAccessingSecurityScopedResource() }; withExtendedLifetime(access) {}
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
    private var operations:[UUID:OperationCancellation] = [:]
    private var retired = false
    private var alert:NSAlert?
    private var answer:((Approval) -> Void)?
    init(preferences:UserDefaults = .standard) { self.preferences = preferences }
    func retire() {
        retired = true; operations.values.forEach { $0.cancel() }; operations.removeAll()
        if let alert { alert.window.sheetParent?.endSheet(alert.window,returnCode:.abort) }; alert = nil
        let reply = answer; answer = nil; reply?(Approval(approved:false,remember:false,cancelled:true))
    }
    func run(_ type:ClientHookType,repository:GitRepository,access:RepositoryAccessLease?,paths:[String] = [],message:String = "",amend:Bool = false,error:String = "",upstream:String = "",rebasedBranch:String = "",cancellation:OperationCancellation? = nil,allowContinue:Bool = false) async throws -> ClientHookResult? {
        guard !retired else { throw OperationCancellationFailure.cancelled }
        let id = UUID(), token = cancellation ?? OperationCancellation(); operations[id] = token
        defer { operations.removeValue(forKey:id) }
        func check() throws { try Task.checkCancellation(); if retired || token.isCancelled || operations[id] !== token { throw OperationCancellationFailure.cancelled } }
        try check()
        var hooks = ClientHookPreferences.globals(preferences)
        hooks += try await repository.projectClientHooks(cancellation:token)
        try check()
        guard let hook = ClientHookConfiguration.selected(type:type,workingTree:repository.root,hooks:hooks) else { return nil }
        if hook.local {
            let accepted:Bool
            if let stored = ClientHookPreferences.decision(hook,preferences:preferences) { accepted = stored }
            else {
                let response = await ask(hook); try check()
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
            catch { scopes.forEach { $0.stopAccessingSecurityScopedResource() }; throw error }
            let result = try await ClientHookProcessPool.shared.execute(invocation,access:access,scopes:scopes,cancellation:token)
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
            if allowContinue, await continueFailure(failure) {
                try check()
                return failedResult ?? ClientHookResult(exitCode:failure.code,output:"",error:failure.detail,message:message)
            }
            try check()
            throw failure
        }
    }
    private func ask(_ hook:ClientHook) async -> Approval {
        if let approval { return await approval(hook) }
        guard !retired, let window = windowProvider(), window.attachedSheet == nil else { return Approval(approved:false,remember:false,cancelled:true) }
        let question = NSAlert(); question.messageText = "Run this repository hook script?"
        question.informativeText = hook.command + "\n\nOnly run scripts from repositories you trust."
        question.addButton(withTitle:"Yes"); let no = question.addButton(withTitle:"No"); question.addButton(withTitle:"Cancel")
        question.buttons.first?.keyEquivalent = ""; no.keyEquivalent = "\r"; question.window.defaultButtonCell = no.cell as? NSButtonCell
        question.showsSuppressionButton = true; question.suppressionButton?.title = "Do not ask again for this script"
        alert = question
        return await withCheckedContinuation { continuation in
            var answered = false
            let reply:(Approval) -> Void = { value in guard !answered else { return }; answered = true; continuation.resume(returning:value) }
            answer = reply
            question.beginSheetModal(for:window) { [weak self] response in
                guard let self, self.alert === question, !self.retired else { reply(Approval(approved:false,remember:false,cancelled:true)); return }
                self.alert = nil; self.answer = nil
                reply(Approval(approved:response == .alertFirstButtonReturn,remember:question.suppressionButton?.state == .on,cancelled:response != .alertFirstButtonReturn && response != .alertSecondButtonReturn))
            }
        }
    }
    private func continueFailure(_ failure:ClientHookOperationFailure) async -> Bool {
        if let continueAfterFailure { return await continueAfterFailure(failure) }
        guard !retired, let window = windowProvider(), window.attachedSheet == nil else { return false }
        let question = NSAlert(); question.messageText = "Hook script failed"; question.informativeText = failure.localizedDescription
        question.addButton(withTitle:"Abort"); question.addButton(withTitle:"Continue")
        alert = question
        let response = await question.beginSheetModal(for:window)
        if alert === question { alert = nil }
        return !retired && response == .alertSecondButtonReturn
    }
}

@MainActor private final class HookScriptConsole:NSWindowController,NSWindowDelegate {
    private var running = true
    private let cancelScript:() -> Void
    init(type:ClientHookType,command:String,cancel:@escaping () -> Void) {
        cancelScript = cancel
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:620,height:170),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = type.title + " – TurtleGit for Mac"; window.isReleasedWhenClosed = false
        super.init(window:window); window.delegate = self
        window.contentViewController = NSHostingController(rootView:VStack(alignment:.leading,spacing:16) { Text(command).textSelection(.enabled); HStack { ProgressView().controlSize(.small); Text("Running hook script…"); Spacer(); Button("Cancel Script",action:cancel) } }.padding(20))
        window.center()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    func finish() { running = false; window?.close() }
    func windowShouldClose(_ sender:NSWindow) -> Bool { if running { cancelScript(); return false }; return true }
}
