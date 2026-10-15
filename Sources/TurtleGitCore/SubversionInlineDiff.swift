// SPDX-License-Identifier: GPL-2.0-or-later
// Callback/hash behavior ported from TortoiseMerge SVNLineDiff.cpp.
// Copyright (C) 2006-2009, 2011 - TortoiseSVN
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// In-process access to the already-bundled svn_diff_diff_2. Inline painting
/// must not launch a process for each line or choose Swift's different LCS ties.
enum SubversionInlineDiff {
    struct Segment { let common: Bool; let base: Range<Int>; let destination: Range<Int> }
    private typealias Open = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Int64>?, UnsafeMutablePointer<Int64>?, UnsafePointer<Int32>?, UInt) -> OpaquePointer?
    private typealias Close = @convention(c) (UnsafeMutableRawPointer?, Int32) -> OpaquePointer?
    private typealias Next = @convention(c) (UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?, UnsafeMutableRawPointer?, Int32) -> OpaquePointer?
    private typealias Compare = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>?) -> OpaquePointer?
    private typealias Discard = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias DiscardAll = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias Emit = @convention(c) (UnsafeMutableRawPointer?, Int64, Int64, Int64, Int64, Int64, Int64) -> OpaquePointer?
    private final class Context {
        let tokens: [[UInt16]], hashes: [UInt32], baseCount: Int, destinationCount: Int
        var positions = [0, 0], result: [Segment] = [], valid = true
        init(_ base: [[UInt16]], _ destination: [[UInt16]], word: Bool) {
            tokens = base + destination; baseCount = base.count; destinationCount = destination.count
            hashes = tokens.map { token in
                guard word else { return UInt32(token[0]) }
                // SVNLineDiff::Adler32 starts with zero and hashes Windows UTF-16LE.
                var first: UInt32 = 0, second: UInt32 = 0
                for unit in token {
                    for byte in [UInt32(unit & 255), UInt32(unit >> 8)] {
                        first = (first + byte) % 65521; second = (second + first) % 65521
                    }
                }
                return second << 16 | first
            }
        }
        func emit(_ common: Bool, _ start: Int64, _ length: Int64, _ other: Int64, _ otherLength: Int64) {
            guard start >= 0, length >= 0, other >= 0, otherLength >= 0,
                  start <= baseCount, length <= Int64(baseCount) - start,
                  other <= destinationCount, otherLength <= Int64(destinationCount) - other else { valid = false; return }
            result.append(.init(common: common, base: Int(start)..<Int(start + length), destination: Int(other)..<Int(other + otherLength)))
        }
    }
    private static func context(_ baton: UnsafeMutableRawPointer?) -> Context { Unmanaged<Context>.fromOpaque(baton!).takeUnretainedValue() }
    private static let open: Open = { _, prefix, suffix, _, _ in prefix?.pointee = 0; suffix?.pointee = 0; return nil }
    private static let close: Close = { _, _ in nil }
    private static let next: Next = { hash, token, baton, source in
        let owner = context(baton); token?.pointee = nil
        guard source == 0 || source == 1 else { owner.valid = false; return nil }
        let index = Int(source), position = owner.positions[index], count = index == 0 ? owner.baseCount : owner.destinationCount
        guard position < count else { return nil }
        let item = position + (index == 0 ? 0 : owner.baseCount)
        hash?.pointee = owner.hashes[item]; token?.pointee = UnsafeMutableRawPointer(bitPattern: item + 1)
        owner.positions[index] += 1; return nil
    }
    private static let compare: Compare = { baton, a, b, output in
        let owner = context(baton), left = Int(bitPattern: a) - 1, right = Int(bitPattern: b) - 1
        guard owner.tokens.indices.contains(left), owner.tokens.indices.contains(right) else { owner.valid = false; output?.pointee = 0; return nil }
        let lhs = owner.tokens[left], rhs = owner.tokens[right]
        output?.pointee = lhs == rhs ? 0 : lhs.lexicographicallyPrecedes(rhs) ? -1 : 1
        return nil
    }
    private static let discard: Discard = { _, _ in }
    private static let discardAll: DiscardAll = { _ in }
    private static let common: Emit = { baton, start, length, other, otherLength, _, _ in context(baton).emit(true, start, length, other, otherLength); return nil }
    private static let modified: Emit = { baton, start, length, other, otherLength, _, _ in context(baton).emit(false, start, length, other, otherLength); return nil }
    private static let inputFunctions: [UnsafeRawPointer?] = [unsafeBitCast(open, to: UnsafeRawPointer.self), unsafeBitCast(close, to: UnsafeRawPointer.self), unsafeBitCast(next, to: UnsafeRawPointer.self), unsafeBitCast(compare, to: UnsafeRawPointer.self), unsafeBitCast(discard, to: UnsafeRawPointer.self), unsafeBitCast(discardAll, to: UnsafeRawPointer.self)]
    private static let outputFunctions: [UnsafeRawPointer?] = [unsafeBitCast(common, to: UnsafeRawPointer.self), unsafeBitCast(modified, to: UnsafeRawPointer.self), nil, nil, nil]

    private final class API {
        typealias Initialize = @convention(c) () -> Int32
        typealias CreatePool = @convention(c) (UnsafeMutablePointer<OpaquePointer?>?, OpaquePointer?, UnsafeRawPointer?, OpaquePointer?) -> Int32
        typealias DestroyPool = @convention(c) (OpaquePointer?) -> Void
        typealias Diff = @convention(c) (UnsafeMutablePointer<OpaquePointer?>?, UnsafeMutableRawPointer?, UnsafeRawPointer?, OpaquePointer?) -> OpaquePointer?
        typealias Output = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?, UnsafeMutableRawPointer?) -> OpaquePointer?
        typealias ClearError = @convention(c) (OpaquePointer?) -> Void
        let handle: UnsafeMutableRawPointer, create: CreatePool, destroy: DestroyPool, diff: Diff, output: Output, clear: ClearError
        init?(url: URL) {
            #if canImport(Darwin)
            guard let library = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else { return nil }
            func function<T>(_ name: String, _ type: T.Type) -> T? { dlsym(library, name).map { unsafeBitCast($0, to: type) } }
            guard let initialize = function("apr_initialize", Initialize.self), let create = function("apr_pool_create_ex", CreatePool.self),
                  let destroy = function("apr_pool_destroy", DestroyPool.self), let diff = function("svn_diff_diff_2", Diff.self),
                  let output = function("svn_diff_output2", Output.self), let clear = function("svn_error_clear", ClearError.self), initialize() == 0 else { dlclose(library); return nil }
            handle = library; self.create = create; self.destroy = destroy; self.diff = diff; self.output = output; self.clear = clear
            #else
            return nil
            #endif
        }
        // APR and its library remain initialized for the process lifetime. Each
        // concurrent comparison owns a distinct pool and callback context.
    }
    private static let api: API? = {
        var candidates: [URL] = []
        if let bundled = try? SubversionMergeDiff.runtimeRoot() { candidates.append(bundled) }
        if !GitRuntime.isAppStoreBuild && Bundle.main.bundleURL.pathExtension != "app" {
            // Standalone Core/native development receivers, never a packaged app.
            candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/git-runtime/Git"))
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        for root in candidates {
            if let loaded = API(url: root.appendingPathComponent("libexec/git-svn-runtime/" + architecture + "/Subversion/lib/libsvn_diff-1.0.dylib")) { return loaded }
        }
        return nil
    }()
    static var available: Bool { api != nil }
    static func segments(base: [[UInt16]], destination: [[UInt16]], word: Bool) -> [Segment]? {
        guard let api, base.allSatisfy({ !$0.isEmpty }), destination.allSatisfy({ !$0.isEmpty }) else { return nil }
        var pool: OpaquePointer?, result: OpaquePointer?
        guard api.create(&pool, nil, nil, nil) == 0, let pool else { return nil }
        defer { api.destroy(pool) }
        let owner = Context(base, destination, word: word)
        let address = Unmanaged.passUnretained(owner).toOpaque()
        return withExtendedLifetime(owner) {
            if let error = inputFunctions.withUnsafeBufferPointer({ api.diff(&result, address, $0.baseAddress, pool) }) { api.clear(error); return nil }
            if let error = outputFunctions.withUnsafeBufferPointer({ api.output(result, address, $0.baseAddress, nil, nil) }) { api.clear(error); return nil }
            return owner.valid ? owner.result : nil
        }
    }
}
