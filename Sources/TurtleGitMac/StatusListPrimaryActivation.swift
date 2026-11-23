// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// Exact accepted status row; selection order is supplied by the native report,
/// independently of checkbox membership or the order of a Set of path IDs.
struct StatusListPrimaryFile {
    let entry:StatusEntry
    let isDirectory:Bool
    let isSubmodule:Bool
}
enum StatusListPrimaryActivationMode:Equatable {case primary,compareWithBase}
enum StatusListPrimaryFileAction {
    case conflict(StatusListPrimaryFile)
    case comparison(StatusListPrimaryFile)
    case workingFile(StatusListPrimaryFile)
    case skipMissing(StatusListPrimaryFile)
    var file:StatusListPrimaryFile {
        switch self {case .conflict(let row),.comparison(let row),.workingFile(let row),.skipMissing(let row):return row}
    }
}

/// Source owns confirmation, cancellation and preparation. Root consumes this
/// already-confirmed immutable plan without another selected-count warning.
@MainActor struct StatusListPrimaryActivation {
    let actions:[StatusListPrimaryFileAction]
    let selectedCount:Int
    let repository:GitRepository
    let preferences:UserDefaults
    let window:NSWindow
    let base:ComparisonRevision
    let amendToParent:Bool
    let isRebase:Bool
    let alternateTool:Bool
    let mergeTools:MergeToolPreferences
    let conflictIdentity:ConflictIdentityOptions
    let expectedConflicts:[ConflictEntry]?
    let ownerIsCurrent:()->Bool
}

@MainActor enum StatusListPrimaryActivationSession {
    typealias Launch=(StatusListPrimaryActivation,OperationCancellation) async throws -> Void

    static func action(_ row:StatusListPrimaryFile,mode:StatusListPrimaryActivationMode = .primary)->StatusListPrimaryFileAction {
        // Explicit Compare invokes StartDiff for every selected row. Default
        // Return instead chooses ConflictEdit/current-file/missing handling.
        if mode == .compareWithBase {return .comparison(row)}
        let entry=row.entry
        if entry.state == .conflicted {return .conflict(row)}
        if entry.state == .untracked || entry.state == .ignored || entry.hasUnversionedCopy {return .workingFile(row)}
        // Shared GitStatusListCtrl permits Deleted|Missing and
        // Modified|Deleted|Missing, but not Added/Renamed/Copied|Missing.
        // Porcelain retains the original index/worktree distinction; the
        // single display caption must not replace those accepted status bits.
        if entry.worktree == "D",!entry.canCompareWithBaseFromStatusList {return .skipMissing(row)}
        return .comparison(row)
    }

    /// Capture tool/backend intent synchronously at the native event, before
    /// the source model publishes busy or creates an asynchronous task.
    @MainActor struct Intent {
        let repository:GitRepository,sourceRepository:GitRepository
        let preferences:UserDefaults,window:NSWindow
        let amendToParent:Bool,alternateTool:Bool
        let diffData:Data?,mergeData:Data?
        let identity:ConflictIdentityOptions,tools:MergeToolPreferences
        init(repository:GitRepository,preferences:UserDefaults,window:NSWindow,amendToParent:Bool,alternateTool:Bool) {
            sourceRepository=repository;self.repository=repository.capturingDiffBackend(preferences:preferences)
            self.preferences=preferences;self.window=window;self.amendToParent=amendToParent;self.alternateTool=alternateTool
            diffData=preferences.data(forKey:"TurtleGit.DiffTools");mergeData=preferences.data(forKey:"TurtleGit.MergeTools")
            identity=ConflictIdentityOptions(defaults:preferences);tools=MergeToolPreferences.load(from:preferences)
        }
        var settingsCurrent:Bool {
            preferences.data(forKey:"TurtleGit.DiffTools")==diffData && preferences.data(forKey:"TurtleGit.MergeTools")==mergeData &&
                ConflictIdentityOptions(defaults:preferences)==identity &&
                NativeDiffBackendIdentity(sourceRepository.capturingDiffBackend(preferences:preferences).libgit2Configuration)==NativeDiffBackendIdentity(repository.libgit2Configuration)
        }
    }

    static func run(rows:[StatusListPrimaryFile],intent:Intent,cancellation:OperationCancellation,
                    ownerIsCurrent:@escaping()->Bool,confirmation:((Int) async -> Bool)?,expectedConflicts:[ConflictEntry]?=nil,expectedRebase:Bool?=nil,mode:StatusListPrimaryActivationMode = .primary,launch:@escaping Launch) async throws {
        guard !rows.isEmpty else{return}
        let current:()->Bool = {ownerIsCurrent() && !cancellation.isCancelled && intent.settingsCurrent}
        let session=FileListComparisonSession(window:intent.window,preferences:intent.preferences,cancellation:OperationCancellation(parent:cancellation),alternateTool:intent.alternateTool)
        session.isOwnerCurrent=current;session.confirmation=confirmation
        // Also cancel the initial base/rebase Git reads on row/document changes;
        // FileListComparisonSession's own watcher begins with its warning phase.
        let readerWatch=Task { @MainActor in
            while !Task.isCancelled {
                if !current() {session.cancel();return}
                do {try await Task.sleep(nanoseconds:10_000_000)} catch{return}
            }
        }
        defer {readerWatch.cancel()}
        do {
            try session.check()
            // Root commits use .emptyTree without writing a mktree object.
            let base=try await comparisonBase(repository:intent.repository,amend:intent.amendToParent,token:session.cancellation)
            let actions=rows.map{action($0,mode:mode)}
            let conflictPaths=rows.filter{$0.entry.state == .conflicted}.map{ $0.entry.path }
            if let expectedConflicts {
                let expectedPaths=GitPathSet(expectedConflicts.map(\.path))
                guard expectedPaths.count==expectedConflicts.count,
                      expectedPaths==GitPathSet(conflictPaths),conflictPaths.count==expectedConflicts.count else{throw ResolveFailure.stale}
            }
            let rebase:Bool
            let hasConflicts = !conflictPaths.isEmpty
            if hasConflicts {
                rebase=try await intent.repository.conflictIsRebase(cancellation:session.cancellation)
            } else {rebase=false}
            if hasConflicts,let expectedRebase,expectedRebase != rebase {throw ResolveFailure.stale}
            try session.check()
            let plan=StatusListPrimaryActivation(actions:actions,selectedCount:rows.count,repository:intent.repository,preferences:intent.preferences,window:intent.window,
                base:base,amendToParent:intent.amendToParent,isRebase:rebase,alternateTool:intent.alternateTool,
                mergeTools:intent.tools,conflictIdentity:intent.identity,expectedConflicts:expectedConflicts,ownerIsCurrent:current)
            try await session.run(selectedCount:rows.count) {token in
                try session.check();try await launch(plan,token)
            }
        } catch OperationCancellationFailure.cancelled {
            // A stale selected-row request is retired rather than publishing a
            // new error in its replacement document/selection.
        }
    }

    private static func comparisonBase(repository:GitRepository,amend:Bool,token:OperationCancellation) async throws -> ComparisonRevision {
        let head=try await repository.run(["rev-parse","--verify","--quiet","HEAD^{commit}"],successfulExitCodes:0...1,cancellation:token)
        try token.check()
        guard head.exitCode==0 else{return .emptyTree}
        let hash=head.text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard [40,64].contains(hash.count),hash.utf8.allSatisfy({(48...57).contains($0) || (97...102).contains($0)}) else{throw RevisionComparisonFailure.range}
        guard amend else{return .revision(hash)}
        let parent=try await repository.run(["rev-parse","--verify","--quiet",hash+"^1^{commit}"],successfulExitCodes:0...1,cancellation:token)
        try token.check()
        return parent.exitCode==0 ? .revision(parent.text.trimmingCharacters(in:.whitespacesAndNewlines)):.emptyTree
    }
}
