# Synchronization literal reference identity

This family preserves the selected branch and remote bytes through Sync's
outgoing projection, checkout, tracking configuration and transport. It adds no
new controls. The existing local picker distinguishes Git reference names by
bytes; Git execution must preserve that selection too.

## Source behavior

The pinned TortoiseGit source is
`7338078f8ddd924b8cddee35f512f2286072136d`. `SyncDlg.cpp::FetchOutList`
(lines 1360–1445) reads the remote, remote branch and local branch, resolves those
names and uses their commits for outgoing history and files.
`AskSetTrackedBranch` (lines 108–134) writes the captured local branch keys,
remote value and stripped remote branch merge value after Yes; it does not add
a separate branch-existence restriction. Pull and Push call that question from
their selected fields. The action paths retain those identities for checkout
and transport.

macOS Git can precompose command arguments when `core.precomposeunicode=true`.
Two packed references can have canonically equivalent display names and different
bytes and commits. Passing a selected name through ordinary Git argument
normalization can inspect or change the other reference. Swift's ordinary String
equality can likewise conflate those names in a stale-selection witness.

## Connected implementation

Sync uses invocation-only `-c core.precomposeunicode=false` for selected revision
resolution, branch-specific configuration, both separate and direct checkout
paths, actual transport and fast-forward continuation. Outgoing history/files
and incoming comparisons resolve the selected names to object IDs before later
readers. Email patch ranges likewise capture exact endpoint IDs before the shared
Format Patch reader. Stored worktree precomposition configuration is unchanged.

`setSynchronizationTracking` performs the source's two sequential approved config
writes using the captured local branch, remote and remote branch bytes. The
native owner retains its existing question, suppression preference, cancellation
and closed-owner gates and calls this Core boundary after Yes. The method does
not introduce a transaction or branch-existence rule absent from source. The
remote branch follows source prefix stripping and trailing-whitespace trimming.

Public transport plans and `executedArguments` retain the requested command.
Internal invocation configuration is removed from public Git failure arguments;
stream delivery metadata and stderr are retained. Engine selection, source
mapping decisions and command-completion ownership remain unchanged. Existing
byte-exact native picker and form witnesses continue to fence stale actions;
no defensive changes to unrelated history matching are included.

The separate checkout child receives the same captured repository object used
by its subsequent transport. This preserves both the selected backend and Core's
checkpoint identity guard. Previously the controller created checkout with the
original repository while transport used its captured copy, so an approved Pull
checkout could complete and then its continuation was refused as stale.

## Validation and limits

The grouped checkpoint records 51 distinct Core methods cumulatively passing,
including nine new exact-reference methods. Initial fixture failures read the
invocation override instead of local stored configuration, and attempted a
wildcard update of colliding loose ref paths; focused repairs retain the exact
identity and configuration assertions.

Six distinct native case/engine pairs pass cumulatively: Push, Pull and held
tracking lifetime with system and bundled Git. They exercise real offscreen
windows and the shipping local-picker binding, outgoing projections, exact
tracking writes, actual transport, the default controller-owned checkout child,
stale form receipts and cancellation/closure. Physical popup dispatch is not
established by the binding checks. Initial attempts assumed an AppKit picker
class that SwiftUI does not expose here and used a filesystem-aliasing direct
ref lookup. Raw reference enumeration proves the selected and sibling logical
names and object IDs without repacking the tested remote.

The native Pull case also exposed the repository-copy handoff defect described
above. Only the affected native application was rebuilt after its repair;
Core production remained unchanged. The final build exits zero with two
contradictory generic compiler exit-zero diagnostics recorded. See the
[dated checkpoint](qa/sync-literal-reference-family-2026-10-24.json) for failures,
focused repairs, retained progress checks and process ownership evidence.
Existing tag operations already use literal invocation arguments and are not a
new feature of this batch.

On a filename-normalizing macOS filesystem, Git's files reference backend can
still fail when a wildcard fetch simultaneously updates two equivalent-looking
loose reference paths. Literal argv cannot remove that filesystem constraint.
Packed references support the distinct names used by this family; the configured
Pull fixtures use a narrow mapping so only the selected tracking reference must
become loose. The port retains the actual Git failure when a real mapping cannot
be materialized; it does not silently rename or discard either reference.

Full hosted integration, authenticated servers, physical Finder and keyboard
acceptance, complete `IDD_SYNC` layout parity and signed distribution remain
separate requirements.
