# Git Synchronization parity

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`, `SyncDlg.cpp`
(`FetchOutList`, `ShowInCommits`), its inline `AddDiffFileList` in `SyncDlg.h`,
and `Git.cpp::IsFastForward/GetCommitDiffList`. The native synchronization window
and its command integration are not implemented yet. This is a backend port,
not a completed dialog.

## Comparison backend

`GitRepository.synchronizationOutgoing` returns a pinned, read-only projection of
the local and remote-tracking revisions. Equal revisions produce Up to date with
no outgoing comparison. A missing remote branch produces the source unknown
branch state. The source's slash/backslash URL heuristic is retained: a typed URL
or path is unknown without contacting the server, even with Force enabled.

For a fast-forward push, the outgoing Log range is remote..local and the file
comparison is remote to local. Divergence without Force produces the blocked
state. Force keeps the remote..local Log range but compares files from the merge
base to local. The full history is requested, bypassing Log's ordinary 200-row
limit. File comparisons enable the source default 50-percent copy detection and
retain original paths. Existing other comparison callers keep their defaults.

An unusual pinned-source behavior is preserved: no merge base leaves a zero
CGitHash; GetCommitDiffList interprets zero as the working-copy revision. Forced
unrelated histories therefore keep outgoing commits and use working tree to local
for their file comparison. A forced behind branch can have zero outgoing commits
while still enabling Email Patch, just as the source does.

`synchronizationIncoming` compares the captured pre-operation revision with the
actual completed revision (HEAD after Pull, fetched upstream after Fetch), returning
that pinned comparison and old..new history. Equal revisions return empty lists.
Resolving hashes uses stdout independently of diagnostic output. Input NULs and
pre-cancelled operations are rejected; the token is forwarded through Git reads.
The snapshots do not authorize transport operations.

## Verification scope

Five real-Git tests cover equal/ahead/missing/URL states, incoming and unchanged
results, pinned snapshots after a tracking reference moves, divergence/Force,
merge-base file scope, the unrelated working-copy fallback, copy identity,
205 outgoing commits, cancellation and invalid inputs. Staged/unstaged contents,
raw index and refs are preserved by the covered comparison cases.

The existing 15 revision-comparison regressions run alongside the new tests to
check the shared options change. Their fixtures use system Git; the five new tests
explicitly select the requested Git executable. No full-suite, native Sync-window,
transport, physical-input or signed-runtime acceptance claim follows from them.

## Remaining full port

- Native source layout: local/remote branch controls and owned choosers, editable
  remote URL/history, Manage, Force, SSH-key controls, tabs and status/progress.
- Outgoing/incoming Log graphs, change lists, reference changes, conflict lists,
  native context menus, persistence, icons and light/dark acceptance.
- Pull/Fetch/Rebase/Fetch All/Remote Update/Prune/Compare Tags, Push/Tags/Notes,
  Submodule and Stash split actions, Apply/Email Patch, Show Log and Commit.
- Operation snapshots, live progress, cancellation, hooks, authentication,
  retained results, refresh, owner lifetimes and factory/app/Finder routing.
- Configured similarity thresholds beyond the pinned default, libgit2 route
  equivalence, external writers, physical accessibility and signed sandbox grants.
- Signed Finder/App Store/distribution acceptance and complete application parity.
