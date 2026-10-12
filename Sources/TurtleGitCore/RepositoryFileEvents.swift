// macOS adaptation of TGitCache/DirectoryWatcher change notification ownership.
// GPL-2.0-or-later; Copyright (C) 2005-2008, 2011-2012 TortoiseSVN;
// Copyright (C) 2008-2026 TortoiseGit.
import Foundation
import CoreServices

public struct RepositoryFileEvent: Sendable {
    public let path:String
    public let flags:UInt32
    public var requiresFullRescan:Bool {
        flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount) != 0
    }
    public init(path:String,flags:UInt32) { self.path=path;self.flags=flags }
}
public enum RepositoryFileEventFailure: LocalizedError, Equatable {
    case invalidRoots, stream
    public var errorDescription:String? { self == .invalidRoots ? "Choose absolute repository watch directories." : "Filesystem monitoring could not be started." }
}
private final class RepositoryEventCallback: @unchecked Sendable {
    private let lock=NSLock()
    private var active=true
    let deliver:@Sendable ([RepositoryFileEvent])->Void
    init(_ deliver:@escaping @Sendable ([RepositoryFileEvent])->Void) { self.deliver=deliver }
    func stop() { lock.lock();active=false;lock.unlock() }
    func receive(_ values:[RepositoryFileEvent]) { lock.lock();let permitted=active;lock.unlock();if permitted { deliver(values) } }
}
/// Owns one dispatch-based FSEvents stream. Stop/deinit retire callbacks and release it.
public final class RepositoryFileEventMonitor {
    public let roots:[URL]
    private var stream:FSEventStreamRef?
    private let state:RepositoryEventCallback
    private let queue=DispatchQueue(label:"org.turtlegit.repository-events")
    public init(roots:[URL],latency:TimeInterval = 0.2,onEvents:@escaping @Sendable ([RepositoryFileEvent])->Void) throws {
        guard !roots.isEmpty,roots.allSatisfy({ $0.isFileURL && $0.path.hasPrefix("/") && !$0.path.contains("\0") }),latency.isFinite,latency>=0 else { throw RepositoryFileEventFailure.invalidRoots }
        var seen=Set<String>();self.roots=roots.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
        state=RepositoryEventCallback(onEvents)
        var context=FSEventStreamContext(version:0,info:Unmanaged.passUnretained(state).toOpaque(),retain:{ pointer in
            guard let pointer else { return nil };_ = Unmanaged<RepositoryEventCallback>.fromOpaque(pointer).retain();return pointer
        },release:{ pointer in
            if let pointer { Unmanaged<RepositoryEventCallback>.fromOpaque(pointer).release() }
        },copyDescription:nil)
        let callback:FSEventStreamCallback={ _,context,count,paths,flags,_ in
            guard let context else { return }
            let names=unsafeBitCast(paths,to:NSArray.self) as! [String]
            let values=(0..<min(count,names.count)).map { RepositoryFileEvent(path:names[$0],flags:flags[$0]) }
            Unmanaged<RepositoryEventCallback>.fromOpaque(context).takeUnretainedValue().receive(values)
        }
        let options=FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard let stream=FSEventStreamCreate(nil,callback,&context,self.roots.map(\.path) as CFArray,FSEventStreamEventId(kFSEventStreamEventIdSinceNow),latency,options) else { throw RepositoryFileEventFailure.stream }
        self.stream=stream;FSEventStreamSetDispatchQueue(stream,queue)
        guard FSEventStreamStart(stream) else { stop();throw RepositoryFileEventFailure.stream }
    }
    public func stop() {
        state.stop()
        guard let stream else { return };self.stream=nil
        FSEventStreamStop(stream);FSEventStreamInvalidate(stream);FSEventStreamRelease(stream)
    }
    deinit { stop() }
}

extension GitRepository {
    /// Include shared administration for linked worktrees; preserve embedded newlines.
    public func finderWatchDirectories(cancellation:OperationCancellation? = nil) throws -> [URL] {
        try cancellation?.check()
        var result=[root.standardizedFileURL]
        for argument in ["--git-dir","--git-common-dir"] {
            var bytes=try run(["rev-parse","--path-format=absolute",argument],cancellation:cancellation).stdout
            if bytes.last==10 { bytes.removeLast() }
            guard let path=String(data:bytes,encoding:.utf8),path.hasPrefix("/"),!path.utf8.contains(0) else { throw RepositoryFileEventFailure.invalidRoots }
            result.append(URL(fileURLWithPath:path,isDirectory:true).standardizedFileURL)
        }
        var seen=Set<String>();return result.filter { seen.insert($0.path).inserted }
    }
}

/// Coalesces invalidations; busy work retains a pending refresh until explicitly released.
@MainActor public final class RepositoryEventRefresh {
    private var pending=false
    private var retired=false
    private var generation=0
    private var task:Task<Void,Never>?
    private let delay:UInt64
    private let available:()->Bool
    private let refresh:() async -> Void
    public init(delay:UInt64 = 200_000_000,available:@escaping ()->Bool,refresh:@escaping () async -> Void) { self.delay=delay;self.available=available;self.refresh=refresh }
    public func invalidate() { guard !retired else { return };pending=true;kick() }
    public func kick() {
        guard !retired,pending,task==nil else { return }
        let identity=generation
        task=Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds:delay)
            guard !retired,generation==identity,!Task.isCancelled else { return }
            guard available() else { task=nil;return }
            pending=false
            await refresh()
            task=nil
            if pending { kick() }
        }
    }
    public func retire() { retired=true;generation += 1;pending=false;task?.cancel();task=nil }
}
