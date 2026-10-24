// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import TurtleGitCore

/// A real initial read owns the first repository worker while a second accepted
/// Rebase handoff waits. No arbitrary sleep substitutes for either receipt.
@MainActor enum RevisionLookupQueuedVerification {
    static func verify(_ c:RevisionLookupVerification.Context)async throws {
        let started=c.base.appendingPathComponent("queued-started")
        let released=c.base.appendingPathComponent("queued-release")
        let claimed=c.base.appendingPathComponent("queued-claimed")
        let resource=c.base.appendingPathComponent("queued-owned-resource")
        let wrapper=c.base.appendingPathComponent("queued-git")
        try Data().write(to:resource)
        let quote=RevisionLookupVerification.quote
        let script="""
        #!/bin/sh
        exec 9< \(quote(resource.path))
        if /bin/mkdir \(quote(claimed.path)) 2>/dev/null; then
          : > \(quote(started.path))
          while ! test -f \(quote(released.path)); do /bin/sleep .02; done
        fi
        exec \(quote(c.git.path)) "$@"
        """
        try Data(script.utf8).write(to:wrapper)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        defer{try? Data().write(to:released)}
        let before=try ["HEAD","index","config"].map{try Data(contentsOf:c.root.appendingPathComponent(".git/"+$0))}
        c.prefs.set(false,forKey:"UseLibgit2")
        let initial=GitRepository(root:c.root,executable:wrapper,askpass:nil,libgit2Configuration:.init(enabled:false,mask:0))
        let owner=c.own(RebaseWindowController(repository:initial,access:RepositoryAccessLease(url:c.root),preferences:c.prefs))
        try c.clear();owner.model.load(upstream:"refs/heads/main")
        try await RevisionLookupVerification.wait{owner.model.busy && FileManager.default.fileExists(atPath:started.path)}
        c.prefs.set(true,forKey:"UseLibgit2")
        let accepted=c.repo.capturingDiffBackend(preferences:c.prefs)
        owner.model.load(upstream:"refs/heads/main",acceptedRepository:accepted)
        try RevisionLookupVerification.require(owner.model.inheritedOperationRepository==nil,"Queued handoff replaced the repository of an active initial read")
        c.prefs.set(false,forKey:"UseLibgit2")
        try Data().write(to:released)
        try await RevisionLookupVerification.wait{owner.model.inheritedOperationRepository === accepted && !owner.model.busy && owner.model.pendingBatchWorkers==0}
        try RevisionLookupVerification.require(owner.model.error==nil && owner.model.plan != nil && c.calls().contains("turtlegit-checkout-refs"),"Queued handoff did not use the accepted actor for actual default reference reads")
        // A separate, subsequently accepted load returns to current preferences.
        try c.clear();owner.model.load(upstream:"refs/heads/main")
        try await RevisionLookupVerification.wait{!owner.model.busy && owner.model.pendingBatchWorkers==0}
        try RevisionLookupVerification.require(owner.model.inheritedOperationRepository==nil && owner.model.error==nil && c.calls().isEmpty,"Independent Rebase load retained an earlier handoff's backend")
        let after=try ["HEAD","index","config"].map{try Data(contentsOf:c.root.appendingPathComponent(".git/"+$0))}
        try RevisionLookupVerification.require(before==after,"Queued read-only handoff changed HEAD, index or configuration")
        owner.close()
        try await RevisionLookupVerification.wait{owner.model.pendingBatchWorkers==0}
    }
}
