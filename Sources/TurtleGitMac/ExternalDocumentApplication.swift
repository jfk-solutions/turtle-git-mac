// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// UDiff and Alternative Editor share launch/scoping, while preserving their
/// distinct source arguments and their native default document-open behavior.
@MainActor enum ExternalDocumentApplication {
    enum Failure: LocalizedError {
        case programPermission
        var errorDescription: String? { "Choose the application or executable again using Browse in Settings to renew its permission." }
    }
    typealias Launch = (URL, [URL], NSWorkspace.OpenConfiguration) async throws -> Void
    private(set) static var activeRequests = 0
    static func open(file: URL, program: DiffToolProgram, arguments: [String], nativeDocumentOpen: Bool,
                     permissions: [RepositoryAccessLease] = [], cancellation: OperationCancellation? = nil,
                     provider: any RepositoryBookmarkProvider = SystemRepositoryBookmarkProvider(),
                     requiresScopes: Bool = GitRuntime.isAppStoreBuild, requiresProgramScope: Bool = true,
                     launch: Launch? = nil) async throws {
        try cancellation?.check()
        guard file.isFileURL, !file.path.contains("\0"), arguments.allSatisfy({ !$0.contains("\0") }) else { throw DiffToolFailure.arguments }
        activeRequests += 1
        defer { activeRequests -= 1 }
        let application = try program.bookmark.map { try provider.resolve($0).url } ?? URL(fileURLWithPath: program.applicationPath)
        guard application.isFileURL else { throw DiffToolFailure.application }
        let grant = RepositoryAccessLease(url: application, provider: provider)
        let app = application.pathExtension.caseInsensitiveCompare("app") == .orderedSame
        guard !requiresScopes || !requiresProgramScope || grant.hasSecurityScope else { throw Failure.programPermission }
        let ownedFile = RepositoryAccessLease.pathIsContained(file, by: FileManager.default.homeDirectoryForCurrentUser) ||
            ((try? TurtleGitTemporaryStorage.root).map { RepositoryAccessLease.pathIsContained(file, by: $0) } ?? false)
        guard !requiresScopes || ownedFile || permissions.contains(where: { $0.permits(file) }) else { throw RepositoryAccessFailure.securityScopeUnavailable }
        try cancellation?.check()
        if !app {
            guard FileManager.default.isExecutableFile(atPath: application.path),
                  try application.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw DiffToolFailure.application }
            // External tools are detached, as upstream. The pool retains scopes
            // through process settlement and supports explicit application cleanup.
            _ = try await ExternalToolProcesses.start(application, arguments: arguments, root: file.deletingLastPathComponent(), permissions: permissions + [grant])
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = nativeDocumentOpen ? [] : arguments
        configuration.createsNewApplicationInstance = !nativeDocumentOpen
        let documents = nativeDocumentOpen ? [file] : []
        defer { withExtendedLifetime(grant) {}; withExtendedLifetime(permissions) {} }
        if let launch { try await launch(application, documents, configuration); return }
        try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
            let completed: @Sendable (NSRunningApplication?, Error?) -> Void = { _, failure in
                if let failure { reply.resume(throwing: failure) } else { reply.resume() }
            }
            if nativeDocumentOpen { NSWorkspace.shared.open(documents, withApplicationAt: application, configuration: configuration, completionHandler: completed) }
            else { NSWorkspace.shared.openApplication(at: application, configuration: configuration, completionHandler: completed) }
        }
    }
}
