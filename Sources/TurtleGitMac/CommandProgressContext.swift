// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import TurtleGitCore

/// One command's completion choice is separate from saved preferences and from
/// another window using the same repository. Owners retain this value across
/// later button events; TaskLocal alone cannot survive an AppKit callback.
struct CommandProgressScope: Sendable, Equatable {
    let id: UUID
    let policy: CommandProgressAutoClose
    init(policy: CommandProgressAutoClose) { id = UUID(); self.policy = policy }
}

enum CommandProgressContext {
    @TaskLocal static var current: CommandProgressScope?

    static func perform<T>(_ scope: CommandProgressScope?, _ operation: () throws -> T) rethrows -> T {
        try $current.withValue(scope, operation: operation)
    }
    static func perform<T>(_ scope: CommandProgressScope?, _ operation: () async throws -> T) async rethrows -> T {
        try await $current.withValue(scope, operation: operation)
    }
    static func capture<Result>(_ scope: CommandProgressScope?, _ operation: @escaping () -> Result) -> () -> Result {
        { perform(scope) { operation() } }
    }
    static func capture<Result>(_ operation: @escaping () -> Result) -> () -> Result {
        capture(current, operation)
    }
    static func capture<Result>(_ scope: CommandProgressScope?, _ operation: @escaping () throws -> Result) -> () throws -> Result {
        { try perform(scope) { try operation() } }
    }
    static func capture<Result>(_ operation: @escaping () throws -> Result) -> () throws -> Result {
        capture(current, operation)
    }
    static func capture<Result>(_ scope: CommandProgressScope?, _ operation: @escaping () async -> Result) -> () async -> Result {
        { await perform(scope) { await operation() } }
    }
    static func capture<Result>(_ operation: @escaping () async -> Result) -> () async -> Result {
        capture(current, operation)
    }
    static func capture<Result>(_ scope: CommandProgressScope?, _ operation: @escaping () async throws -> Result) -> () async throws -> Result {
        { try await perform(scope) { try await operation() } }
    }
    static func capture<Result>(_ operation: @escaping () async throws -> Result) -> () async throws -> Result {
        capture(current, operation)
    }
    static func capture<A, Result>(_ scope: CommandProgressScope?, _ operation: @escaping (A) -> Result) -> (A) -> Result {
        { a0 in perform(scope) { operation(a0) } }
    }
    static func capture<A, Result>(_ operation: @escaping (A) -> Result) -> (A) -> Result {
        capture(current, operation)
    }
    static func capture<A, Result>(_ scope: CommandProgressScope?, _ operation: @escaping (A) throws -> Result) -> (A) throws -> Result {
        { a0 in try perform(scope) { try operation(a0) } }
    }
    static func capture<A, Result>(_ operation: @escaping (A) throws -> Result) -> (A) throws -> Result {
        capture(current, operation)
    }
    static func capture<A, Result>(_ scope: CommandProgressScope?, _ operation: @escaping (A) async -> Result) -> (A) async -> Result {
        { a0 in await perform(scope) { await operation(a0) } }
    }
    static func capture<A, Result>(_ operation: @escaping (A) async -> Result) -> (A) async -> Result {
        capture(current, operation)
    }
    static func capture<A, Result>(_ scope: CommandProgressScope?, _ operation: @escaping (A) async throws -> Result) -> (A) async throws -> Result {
        { a0 in try await perform(scope) { try await operation(a0) } }
    }
    static func capture<A, Result>(_ operation: @escaping (A) async throws -> Result) -> (A) async throws -> Result {
        capture(current, operation)
    }
    static func capture<A, B, Result>(_ scope: CommandProgressScope?, _ operation: @escaping (A, B) -> Result) -> (A, B) -> Result {
        { a0, a1 in perform(scope) { operation(a0, a1) } }
    }
    static func capture<A, B, Result>(_ operation: @escaping (A, B) -> Result) -> (A, B) -> Result {
        capture(current, operation)
    }
    static func capture<A, B, Result>(_ scope: CommandProgressScope?, _ operation: @escaping (A, B) throws -> Result) -> (A, B) throws -> Result {
        { a0, a1 in try perform(scope) { try operation(a0, a1) } }
    }
    static func capture<A, B, Result>(_ operation: @escaping (A, B) throws -> Result) -> (A, B) throws -> Result {
        capture(current, operation)
    }
    static func capture<A, B, Result>(_ scope: CommandProgressScope?, _ operation: @escaping (A, B) async -> Result) -> (A, B) async -> Result {
        { a0, a1 in await perform(scope) { await operation(a0, a1) } }
    }
    static func capture<A, B, Result>(_ operation: @escaping (A, B) async -> Result) -> (A, B) async -> Result {
        capture(current, operation)
    }
    static func capture<A, B, Result>(_ scope: CommandProgressScope?, _ operation: @escaping (A, B) async throws -> Result) -> (A, B) async throws -> Result {
        { a0, a1 in try await perform(scope) { try await operation(a0, a1) } }
    }
    static func capture<A, B, Result>(_ operation: @escaping (A, B) async throws -> Result) -> (A, B) async throws -> Result {
        capture(current, operation)
    }
    static func capture<A, B, C, Result>(_ scope: CommandProgressScope?, _ operation: @escaping (A, B, C) -> Result) -> (A, B, C) -> Result {
        { a0, a1, a2 in perform(scope) { operation(a0, a1, a2) } }
    }
    static func capture<A, B, C, Result>(_ operation: @escaping (A, B, C) -> Result) -> (A, B, C) -> Result {
        capture(current, operation)
    }
    static func capture<A, B, C, Result>(_ scope: CommandProgressScope?, _ operation: @escaping (A, B, C) throws -> Result) -> (A, B, C) throws -> Result {
        { a0, a1, a2 in try perform(scope) { try operation(a0, a1, a2) } }
    }
    static func capture<A, B, C, Result>(_ operation: @escaping (A, B, C) throws -> Result) -> (A, B, C) throws -> Result {
        capture(current, operation)
    }
    static func capture<A, B, C, Result>(_ scope: CommandProgressScope?, _ operation: @escaping (A, B, C) async -> Result) -> (A, B, C) async -> Result {
        { a0, a1, a2 in await perform(scope) { await operation(a0, a1, a2) } }
    }
    static func capture<A, B, C, Result>(_ operation: @escaping (A, B, C) async -> Result) -> (A, B, C) async -> Result {
        capture(current, operation)
    }
    static func capture<A, B, C, Result>(_ scope: CommandProgressScope?, _ operation: @escaping (A, B, C) async throws -> Result) -> (A, B, C) async throws -> Result {
        { a0, a1, a2 in try await perform(scope) { try await operation(a0, a1, a2) } }
    }
    static func capture<A, B, C, Result>(_ operation: @escaping (A, B, C) async throws -> Result) -> (A, B, C) async throws -> Result {
        capture(current, operation)
    }
    static func capture<A, B, C, D, Result>(_ scope: CommandProgressScope?, _ operation: @escaping (A, B, C, D) -> Result) -> (A, B, C, D) -> Result {
        { a0, a1, a2, a3 in perform(scope) { operation(a0, a1, a2, a3) } }
    }
    static func capture<A, B, C, D, Result>(_ operation: @escaping (A, B, C, D) -> Result) -> (A, B, C, D) -> Result {
        capture(current, operation)
    }
    static func capture<A, B, C, D, Result>(_ scope: CommandProgressScope?, _ operation: @escaping (A, B, C, D) throws -> Result) -> (A, B, C, D) throws -> Result {
        { a0, a1, a2, a3 in try perform(scope) { try operation(a0, a1, a2, a3) } }
    }
    static func capture<A, B, C, D, Result>(_ operation: @escaping (A, B, C, D) throws -> Result) -> (A, B, C, D) throws -> Result {
        capture(current, operation)
    }
    static func capture<A, B, C, D, Result>(_ scope: CommandProgressScope?, _ operation: @escaping (A, B, C, D) async -> Result) -> (A, B, C, D) async -> Result {
        { a0, a1, a2, a3 in await perform(scope) { await operation(a0, a1, a2, a3) } }
    }
    static func capture<A, B, C, D, Result>(_ operation: @escaping (A, B, C, D) async -> Result) -> (A, B, C, D) async -> Result {
        capture(current, operation)
    }
    static func capture<A, B, C, D, Result>(_ scope: CommandProgressScope?, _ operation: @escaping (A, B, C, D) async throws -> Result) -> (A, B, C, D) async throws -> Result {
        { a0, a1, a2, a3 in try await perform(scope) { try await operation(a0, a1, a2, a3) } }
    }
    static func capture<A, B, C, D, Result>(_ operation: @escaping (A, B, C, D) async throws -> Result) -> (A, B, C, D) async throws -> Result {
        capture(current, operation)
    }
    static func capture<A, B, C, D, E, Result>(_ scope: CommandProgressScope?, _ operation: @escaping (A, B, C, D, E) -> Result) -> (A, B, C, D, E) -> Result {
        { a0, a1, a2, a3, a4 in perform(scope) { operation(a0, a1, a2, a3, a4) } }
    }
    static func capture<A, B, C, D, E, Result>(_ operation: @escaping (A, B, C, D, E) -> Result) -> (A, B, C, D, E) -> Result {
        capture(current, operation)
    }
    static func capture<A, B, C, D, E, Result>(_ scope: CommandProgressScope?, _ operation: @escaping (A, B, C, D, E) throws -> Result) -> (A, B, C, D, E) throws -> Result {
        { a0, a1, a2, a3, a4 in try perform(scope) { try operation(a0, a1, a2, a3, a4) } }
    }
    static func capture<A, B, C, D, E, Result>(_ operation: @escaping (A, B, C, D, E) throws -> Result) -> (A, B, C, D, E) throws -> Result {
        capture(current, operation)
    }
    static func capture<A, B, C, D, E, Result>(_ scope: CommandProgressScope?, _ operation: @escaping (A, B, C, D, E) async -> Result) -> (A, B, C, D, E) async -> Result {
        { a0, a1, a2, a3, a4 in await perform(scope) { await operation(a0, a1, a2, a3, a4) } }
    }
    static func capture<A, B, C, D, E, Result>(_ operation: @escaping (A, B, C, D, E) async -> Result) -> (A, B, C, D, E) async -> Result {
        capture(current, operation)
    }
    static func capture<A, B, C, D, E, Result>(_ scope: CommandProgressScope?, _ operation: @escaping (A, B, C, D, E) async throws -> Result) -> (A, B, C, D, E) async throws -> Result {
        { a0, a1, a2, a3, a4 in try await perform(scope) { try await operation(a0, a1, a2, a3, a4) } }
    }
    static func capture<A, B, C, D, E, Result>(_ operation: @escaping (A, B, C, D, E) async throws -> Result) -> (A, B, C, D, E) async throws -> Result {
        capture(current, operation)
    }
    /// Controller-cache identity only. This key must never become a URL or Git
    /// path. Explicit commands get independent owners without retargeting an
    /// already open dialog's immutable completion policy.
    static func ownsWindowKey(_ key: String) -> Bool {
        let marker="\0command-progress:"
        guard let scope=current else {return !key.contains(marker)}
        return key.contains(marker+scope.id.uuidString)
    }
    static func windowKey(_ key: String) -> String {
        guard let scope = current else { return key }
        return key + "\0command-progress:" + scope.id.uuidString
    }
}
