// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// Resolve and Sync retain real conflict-stage identities, rather than
/// manufacturing porcelain flags for a shared status-row presentation.
@MainActor struct ConflictListPrimaryActivation {
    let entries:[ConflictEntry]
    let repository:GitRepository
    let preferences:UserDefaults
    let window:NSWindow
    let isRebase:Bool
    let alternateTool:Bool
    let mergeTools:MergeToolPreferences
    let conflictIdentity:ConflictIdentityOptions
    let ownerIsCurrent:()->Bool
}

@MainActor enum ConflictListPrimaryActivationSession {
    typealias Launch=(ConflictListPrimaryActivation,OperationCancellation) async throws -> Void

    static func run(entries:[ConflictEntry],intent:StatusListPrimaryActivationSession.Intent,isRebase:Bool,
                    cancellation:OperationCancellation,ownerIsCurrent:@escaping()->Bool,
                    confirmation:((Int) async -> Bool)?,launch:@escaping Launch) async throws {
        guard !entries.isEmpty else{return}
        guard GitPathSet(entries.map(\.path)).count==entries.count else{throw ResolveFailure.stale}
        let current:()->Bool={ownerIsCurrent() && !cancellation.isCancelled && intent.settingsCurrent}
        let session=FileListComparisonSession(window:intent.window,preferences:intent.preferences,
            cancellation:OperationCancellation(parent:cancellation),alternateTool:intent.alternateTool)
        session.isOwnerCurrent=current;session.confirmation=confirmation
        let readerWatch=Task { @MainActor in
            while !Task.isCancelled {
                if !current() {session.cancel();return}
                do {try await Task.sleep(nanoseconds:10_000_000)} catch{return}
            }
        }
        defer{readerWatch.cancel()}
        do {
            try session.check()
            guard try await intent.repository.conflictIsRebase(cancellation:session.cancellation)==isRebase else{throw ResolveFailure.stale}
            try session.check()
            let plan=ConflictListPrimaryActivation(entries:entries,repository:intent.repository,preferences:intent.preferences,
                window:intent.window,isRebase:isRebase,alternateTool:intent.alternateTool,mergeTools:intent.tools,
                conflictIdentity:intent.identity,ownerIsCurrent:current)
            try await session.run(selectedCount:entries.count) {token in
                try session.check();try await launch(plan,token)
            }
        } catch OperationCancellationFailure.cancelled {
            // Closing or replacing an accepted read-only request is retirement,
            // not a new error to display in a replacement document.
        }
    }
}
