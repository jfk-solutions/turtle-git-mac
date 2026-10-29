// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit

/// Volume events wake existing saved grants only. Each event burst gets a bounded
/// retry sequence; no directory scan, timer-based discovery or new grant occurs.
@MainActor public final class FinderVolumeRecovery {
    private let retry: () async -> Bool
    private let center: NotificationCenter
    private let delays: [TimeInterval]
    private let delay: (TimeInterval) async throws -> Void
    private var observers: [NSObjectProtocol] = []
    private var task: Task<Void,Never>?
    private var queued = false
    public private(set) var retired = false
    public var isPending: Bool { task != nil }
    public init(retry: @escaping () async -> Bool,
                notificationCenter: NotificationCenter? = nil,
                delays: [TimeInterval] = [0,1,3,10,30],
                delay: @escaping (TimeInterval) async throws -> Void = FinderVolumeRecovery.sleep) {
        self.retry=retry;center=notificationCenter ?? NSWorkspace.shared.notificationCenter
        self.delays=Array(delays.filter {$0.isFinite && $0>=0 && $0<=300}.prefix(16))
        self.delay=delay
        for name in [NSWorkspace.didMountNotification,NSWorkspace.didUnmountNotification,NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                Task { @MainActor in self?.volumeChanged() }
            })
        }
    }
    nonisolated public static func sleep(_ seconds:TimeInterval) async throws {
        try await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000))
    }
    public func volumeChanged() {
        guard !retired,!delays.isEmpty else{return}
        guard task==nil else {queued=true;return}
        task=Task { [self] in
            defer {task=nil}
            repeat {
                queued=false
                for seconds in delays {
                    guard !retired,!Task.isCancelled else{return}
                    do {if seconds>0 {try await delay(seconds)}} catch {return}
                    guard !retired,!Task.isCancelled else{return}
                    let remaining=await retry()
                    guard !retired,!Task.isCancelled else{return}
                    if !remaining {break}
                }
            } while queued && !retired && !Task.isCancelled
        }
    }
    /// Cancel waits immediately, but retain any already accepted retry until its
    /// real authorization/collector work drains. Its owner cancels that work.
    public func retire() {
        guard !retired else{return};retired=true;queued=false
        for observer in observers {center.removeObserver(observer)};observers=[]
        task?.cancel()
    }
    public func settle() async {await task?.value}
    deinit {for observer in observers {center.removeObserver(observer)};task?.cancel()}
}
