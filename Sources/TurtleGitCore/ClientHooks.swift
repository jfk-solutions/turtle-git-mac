// SPDX-License-Identifier: GPL-2.0-or-later
// Adapted from Utils/Hooks.cpp/.h and ProjectProperties::FetchHookString.
import Foundation

public enum ClientHookType: String, CaseIterable, Codable, Hashable, Sendable {
    case startCommit = "start_commit_hook", preCommit = "pre_commit_hook", postCommit = "post_commit_hook"
    case prePush = "pre_push_hook", postPush = "post_push_hook", preRebase = "pre_rebase_hook"
    public var title: String {
        switch self {
        case .startCommit: return "Start-commit hook"
        case .preCommit: return "Pre-commit hook"
        case .postCommit: return "Post-commit hook"
        case .prePush: return "Pre-push hook"
        case .postPush: return "Post-push hook"
        case .preRebase: return "Pre-rebase hook"
        }
    }
    public var configurationPrefix: String {
        switch self {
        case .startCommit: return "hook.startcommit."
        case .preCommit: return "hook.precommit."
        case .postCommit: return "hook.postcommit."
        case .prePush: return "hook.prepush."
        case .postPush: return "hook.postpush."
        case .preRebase: return "hook.prerebase."
        }
    }
}

public struct ClientHook: Equatable, Codable, Sendable, Identifiable {
    public var type: ClientHookType
    /// An absolute macOS path, or the upstream wildcard '*'.
    public var path: String
    public var command: String
    public var wait: Bool
    public var show: Bool
    public var enabled: Bool
    public var local: Bool
    // String equality folds canonical Unicode spellings; configured scopes do
    // not. Encode the path so SwiftUI/Set identity preserves its original bytes.
    public var id: String { type.rawValue + "\0" + (local ? "local" : "global") + "\0" + GitPathRowIdentity.encode(path) }
    public static func == (lhs:Self,rhs:Self)->Bool {
        lhs.type == rhs.type && GitReferenceName.equal(lhs.path,rhs.path) &&
        GitReferenceName.equal(lhs.command,rhs.command) && lhs.wait == rhs.wait &&
        lhs.show == rhs.show && lhs.enabled == rhs.enabled && lhs.local == rhs.local
    }
    public init(type: ClientHookType = .startCommit, path: String = "", command: String = "", wait: Bool = true, show: Bool = true, enabled: Bool = true, local: Bool = false) {
        self.type = type; self.path = path; self.command = command
        self.wait = wait; self.show = show; self.enabled = enabled; self.local = local
    }
    public var validationError: String? {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Enter a command line to execute." }
        guard !command.contains("\0"), !command.contains("\n"), !command.contains("\r") else { return "A hook command must fit on one line." }
        guard path == "*" && !local || path.hasPrefix("/") else { return "Choose an absolute working tree path, or * for all repositories." }
        guard !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else { return "The hook path contains an unsupported character." }
        return nil
    }
    /// Approval is bound to repository, type and exact command, as in upstream.
    /// Codable persistence stores this tuple, avoiding delimiter collisions.
    public var approvalIdentity: ClientHookApprovalIdentity { .init(root:path,type:type,command:command) }
}

public struct ClientHookApprovalIdentity: Hashable, Codable, Sendable {
    public let root: String
    public let type: ClientHookType
    public let command: String
    public init(root:String,type:ClientHookType,command:String) { self.root = root; self.type = type; self.command = command }
    public static func == (lhs:Self,rhs:Self)->Bool {
        lhs.type == rhs.type && GitReferenceName.equal(lhs.root,rhs.root) && GitReferenceName.equal(lhs.command,rhs.command)
    }
    public func hash(into hasher:inout Hasher) {
        hasher.combine(type);hasher.combine(Data(root.utf8));hasher.combine(Data(command.utf8))
    }
}

public enum ClientHookConfiguration {
    public static let pattern = "^hook\\.(startcommit|precommit|postcommit|prepush|postpush|prerebase)\\.(cmdline|wait|show)$"
    /// Source registry format: five LF-terminated lines per hook. Partial final
    /// records and unknown types are ignored; duplicate map keys retain the first.
    public static func parse(_ text:String, local:Bool = false, root:String = "") -> [ClientHook] {
        let lines = text.components(separatedBy:"\n")
        var result:[ClientHook] = [], seen = Set<String>()
        var index = 0
        while index + 5 < lines.count {
            defer { index += 5 }
            guard let type = ClientHookType(rawValue:lines[index]) else { continue }
            var path = lines[index+1], enabled = true
            if path.hasPrefix("!"), path.count > 1 { enabled = false; path.removeFirst() }
            if path.hasPrefix("?") { path = root }
            let hook = ClientHook(type:type,path:path,command:lines[index+2],wait:lines[index+3].lowercased()=="true",show:lines[index+4].lowercased()=="show",enabled:enabled,local:local)
            if seen.insert(hook.id).inserted { result.append(hook) }
        }
        return sorted(result)
    }
    public static func serialize(_ hooks:[ClientHook]) throws -> String {
        try validate(hooks)
        return sorted(hooks.filter { !$0.local }).map {
            [$0.type.rawValue, ($0.enabled ? "" : "!") + $0.path, $0.command, $0.wait ? "true" : "false", $0.show ? "show" : "hide"].joined(separator:"\n") + "\n"
        }.joined()
    }
    public static func validate(_ hooks:[ClientHook]) throws {
        var seen = Set<String>()
        for hook in hooks {
            if let error = hook.validationError { throw ClientHookFailure.configuration(error) }
            guard seen.insert(hook.id).inserted else { throw ClientHookFailure.configuration("A hook with this type and path already exists.") }
        }
    }
    public static func sorted(_ hooks:[ClientHook]) -> [ClientHook] {
        let order = Dictionary(uniqueKeysWithValues:ClientHookType.allCases.enumerated().map { ($0.element,$0.offset) })
        return hooks.sorted {
            if $0.type != $1.type { return order[$0.type]! < order[$1.type]! }
            if $0.local != $1.local { return !$0.local }
            if !GitReferenceName.equal($0.path,$1.path) { return $0.path.utf16.lexicographicallyPrecedes($1.path.utf16) }
            // Valid configurations have one entry per type/scope. Keep even an
            // unvalidated list deterministic without canonical String ties.
            if !GitReferenceName.equal($0.command,$1.command) { return $0.command.utf16.lexicographicallyPrecedes($1.command.utf16) }
            if $0.enabled != $1.enabled { return $0.enabled }
            if $0.wait != $1.wait { return $0.wait }
            return $0.show && !$1.show
        }
    }
    /// At each path source checks global before local, then walks the ancestors.
    /// A local entry is selected even when disabled so its approval decision can
    /// suppress execution; disabled globals are skipped. Wildcard is last.
    public static func selected(type:ClientHookType,workingTree:URL,hooks:[ClientHook]) -> ClientHook? {
        // Filesystem URL standardization/ancestor construction can normalize
        // Unicode on macOS. Walk the supplied URL's original path lexically so
        // approval and configured-scope identity stay byte-exact.
        var components:[Substring] = []
        for component in workingTree.path.split(separator:"/") {
            if component == "." {continue}
            if component == ".." {if !components.isEmpty {components.removeLast()}}
            else {components.append(component)}
        }
        while true {
            let path = "/" + components.joined(separator:"/")
            for local in [false,true] {
                if let hook = hooks.first(where:{ $0.type == type && GitReferenceName.equal($0.path,path) && $0.local == local && ($0.enabled || $0.local) }) { return hook }
            }
            if components.isEmpty {break}
            components.removeLast()
        }
        return hooks.first { $0.type == type && $0.path == "*" && !$0.local && $0.enabled }
    }
}

public enum ClientHookFailure: LocalizedError {
    case configuration(String), messageEncoding
    public var errorDescription: String? {
        switch self {
        case .configuration(let detail): return detail
        case .messageEncoding: return "The hook wrote a commit message that is not valid UTF-8."
        }
    }
}

/// The source passes temporary files, not the message/path text on the command
/// line. A plan owns its private directory until execution and message readback
/// have finished. Non-waiting executions must retain the plan until they exit.
public final class ClientHookInvocation: @unchecked Sendable {
    public let hook: ClientHook
    public let workingTree: URL
    public let arguments: [String]
    public let directory: URL
    public let messageFile: URL?
    public let originalMessage: String
    public init(hook:ClientHook,workingTree:URL,paths:[String] = [],message:String = "",amend:Bool = false,error:String = "",upstream:String = "",rebasedBranch:String = "",temporaryRoot:URL? = nil) throws {
        if let error = hook.validationError { throw ClientHookFailure.configuration(error) }
        guard workingTree.isFileURL, !workingTree.path.contains("\0") else { throw ClientHookFailure.configuration("Invalid working tree path.") }
        guard !paths.contains(where:{ $0.contains("\0") || $0.contains("\n") || $0.contains("\r") }) else { throw ClientHookFailure.configuration("A hook path list cannot represent newline or NUL characters.") }
        self.hook = hook; self.workingTree = workingTree; originalMessage = message
        let base = try temporaryRoot ?? TurtleGitTemporaryStorage.root
        let directory = base.appendingPathComponent("TurtleGitHook-" + UUID().uuidString,isDirectory:true)
        self.directory = directory
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        func write(_ name:String,_ text:String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data(text.utf8).write(to:url,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
            return url
        }
        do {
            switch hook.type {
            case .startCommit,.preCommit:
                let list = try write("paths",paths.map { $0 + "\n" }.joined())
                let messageURL = try write("message",message)
                messageFile = messageURL; arguments = [list.path,messageURL.path,workingTree.path]
            case .postCommit:
                messageFile = nil; arguments = [workingTree.path,amend ? "true" : "false"]
            case .prePush,.postPush:
                messageFile = nil; arguments = [try write("error",error).path,workingTree.path]
            case .preRebase:
                messageFile = nil; arguments = [upstream,rebasedBranch,try write("error",error).path,workingTree.path]
            }
        } catch { try? FileManager.default.removeItem(at:directory); throw error }
    }
    public func readMessage(exitCode:Int32) throws -> String {
        guard exitCode == 0, let messageFile else { return originalMessage }
        guard var text = String(data:try Data(contentsOf:messageFile),encoding:.utf8) else { throw ClientHookFailure.messageEncoding }
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        return text
    }
    deinit { try? FileManager.default.removeItem(at:directory) }
}

public struct ClientHookResult: Sendable {
    public let exitCode: Int32
    public let output: String
    public let error: String
    public let message: String
    public init(exitCode:Int32,output:String,error:String,message:String) {
        self.exitCode = exitCode; self.output = output; self.error = error; self.message = message
    }
}

/// A native command line uses literal POSIX quoting, without implicit shell
/// expansion. Users can explicitly configure /bin/sh -c when a shell is wanted.
public enum ClientHookCommand {
    public static func arguments(_ command:String,root:String) throws -> [String] {
        var words:[String] = [], word = "", quote:Character?, escaped = false, started = false
        for character in command {
            if escaped {
                if quote == "\"", ![Character("$"), "`", "\"", "\\", "\n"].contains(character) { word.append("\\") }
                if character != "\n" { word.append(character) }
                escaped = false; started = true; continue
            }
            if character == "\\", quote != "'" { escaped = true; started = true; continue }
            if let current = quote {
                if character == current { quote = nil } else { word.append(character) }
                continue
            }
            if character == "'" || character == "\"" { quote = character; started = true }
            else if character.isWhitespace {
                if started { words.append(word); word = ""; started = false }
            } else { word.append(character); started = true }
        }
        guard quote == nil, !escaped else { throw ClientHookFailure.configuration("The hook command contains an unfinished quote or escape.") }
        if started { words.append(word) }
        guard let first = words.first, !first.isEmpty, !words.contains(where:{ $0.contains("\0") }) else { throw ClientHookFailure.configuration("Enter a valid hook executable.") }
        // Replace after tokenization so a root containing spaces/quotes remains
        // one literal argument. Windows commands must be adjusted for macOS.
        return words.map { $0.replacingOccurrences(of:"%root%",with:root) }
    }
}

private final class ClientHookLaunchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void,Error>?
    private var waiter: CheckedContinuation<Void,Error>?
    func complete(_ value:Result<Void,Error>) {
        lock.lock()
        if case .some = result { lock.unlock(); return }
        result = value; let waiter = waiter; self.waiter = nil; lock.unlock()
        waiter?.resume(with:value)
    }
    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with:result) }
            else { waiter = continuation; lock.unlock() }
        }
    }
}

private final class ClientHookCompletionState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    func finish() { lock.lock(); finished = true; lock.unlock() }
    var isFinished:Bool { lock.lock(); defer { lock.unlock() }; return finished }
}

/// Retain an execution until its completion settles, including non-wait hooks.
/// The native owner can cancel on close/Quit; each child owns its process group.
public final class ClientHookExecution: @unchecked Sendable {
    public let cancellation: OperationCancellation
    public let completion: Task<ClientHookResult,Error>
    private let launch: ClientHookLaunchGate
    private let state: ClientHookCompletionState
    private init(invocation:ClientHookInvocation,environment:[String:String],cancellation:OperationCancellation) {
        self.cancellation = cancellation
        let launch = ClientHookLaunchGate(); self.launch = launch
        let state = ClientHookCompletionState(); self.state = state
        completion = Task.detached {
            defer { state.finish() }
            do {
                try cancellation.check()
                let words = try ClientHookCommand.arguments(invocation.hook.command,root:invocation.workingTree.path)
                let executable:URL
                if words[0].hasPrefix("/") { executable = URL(fileURLWithPath:words[0]) }
                else if words[0].contains("/") { executable = invocation.workingTree.appendingPathComponent(words[0]).standardizedFileURL }
                else {
                    let search = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").components(separatedBy:":")
                    guard let found = search.map({ directory in
                        (directory.hasPrefix("/") ? URL(fileURLWithPath:directory) : invocation.workingTree.appendingPathComponent(directory)).appendingPathComponent(words[0])
                    }).first(where:{ FileManager.default.isExecutableFile(atPath:$0.path) }) else { throw ClientHookFailure.configuration("Hook executable not found: " + words[0]) }
                    executable = found
                }
                let outputURL = invocation.directory.appendingPathComponent("stdout"), errorURL = invocation.directory.appendingPathComponent("stderr")
                for url in [outputURL,errorURL] {
                    try Data().write(to:url); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
                }
                let output = try FileHandle(forWritingTo:outputURL), error = try FileHandle(forWritingTo:errorURL)
                defer { try? output.close(); try? error.close() }
                let exitCode = try CancellableGitProcess.run(executable:executable,arguments:Array(words.dropFirst()) + invocation.arguments,
                    environment:environment,output:output.fileDescriptor,error:error.fileDescriptor,cancellation:cancellation,
                    terminateDescendantsOnExit:true,workingDirectory:invocation.workingTree,didStart:{ launch.complete(.success(())) })
                try cancellation.check()
                func read(_ url:URL) throws -> String {
                    let handle = try FileHandle(forReadingFrom:url); defer { try? handle.close() }
                    let bytes = try handle.read(upToCount:1024 * 1024 + 1) ?? Data()
                    return String(decoding:bytes.prefix(1024 * 1024),as:UTF8.self) + (bytes.count > 1024 * 1024 ? "\n[Hook output truncated]" : "")
                }
                return ClientHookResult(exitCode:exitCode,output:try read(outputURL),error:try read(errorURL),message:try invocation.readMessage(exitCode:exitCode))
            } catch { launch.complete(.failure(error)); throw error }
        }
    }
    public static func start(invocation:ClientHookInvocation,environment:[String:String] = ProcessInfo.processInfo.environment,cancellation:OperationCancellation = OperationCancellation()) async throws -> ClientHookExecution {
        let execution = ClientHookExecution(invocation:invocation,environment:environment,cancellation:cancellation)
        do { try await execution.launch.wait(); return execution }
        catch { execution.cancel(); _ = try? await execution.completion.value; throw error }
    }
    public func cancel() { if !state.isFinished { cancellation.cancel() } }
    deinit { if !state.isFinished { cancellation.cancel() } }
}
