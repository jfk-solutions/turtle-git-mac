# Revision lookup and exact reference existence

Reference: pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
This family connects the existing Create Branch/Tag, Switch, Push, Fetch/Rebase
and Synchronization workflows to their accepted revision engine. It adds no
backend control or transport operation.

## Source distinctions

[Git.cpp:1248–1332](https://github.com/TortoiseGit/TortoiseGit/blob/7338078f8ddd924b8cddee35f512f2286072136d/src/Git/Git.cpp#L1248)
accepts a complete SHA-1 identity before opening a repository. That GetHash fast
path is not an existence check. Other names use the master UseLibgit2 switch,
independently of the operation mask; unborn HEAD has a distinct successful-empty
result. The libgit2 path uses revparse without automatically peeling a tag.
[Git.cpp:1550–1635](https://github.com/TortoiseGit/TortoiseGit/blob/7338078f8ddd924b8cddee35f512f2286072136d/src/Git/Git.cpp#L1550)
checks branch/tag collisions with exact namespace lookups. Two canonically
equivalent Unicode spellings must not become one reference identity.

[CreateBranchTagDlg.cpp:160–205](https://github.com/TortoiseGit/TortoiseGit/blob/7338078f8ddd924b8cddee35f512f2286072136d/src/TortoiseProc/CreateBranchTagDlg.cpp#L160)
checks names/existence and cross-kind confirmation before accepting the form.
[AppUtils.cpp:1111–1193](https://github.com/TortoiseGit/TortoiseGit/blob/7338078f8ddd924b8cddee35f512f2286072136d/src/TortoiseProc/AppUtils.cpp#L1111)
uses separate branch/tag Git commands. A tag may point at a tree, blob or another
annotated-tag object; the native preparation must not silently require a commit
or replace that tag object with its peeled commit. Branch creation and Switch
need an actual commit. Source Switch strips a local-head prefix to retain branch
attachment rather than detaching merely because a full reference was selected.

## Native Core contract

`GitRevisionLookup` separates optional `objectID` from `unbornHead`. Callers choose
one of four requirements:

| Requirement | Meaning |
| --- | --- |
| `sourceObject` | Source GetHash semantics: raw object identity, SHA-1 text fast path, distinct unborn HEAD. |
| `existingObject` | Require an actual stored object; preserve an annotated tag's own identity. |
| `commit` | Require/peel to a real commit. |
| `tree` | Require/peel to a real tree. |

The forty-hex fast path normalizes hexadecimal case and also accepts all-zero
text as an identity. It does not turn that zero into a working-tree sentinel.
Typed lookups verify stored objects, including complete hexadecimal input.
Sixty-four-hex input is not the source's forty-hex fast path; existing CLI SHA-256
repository support remains separate from the SHA-1 libgit2 runtime.

A missing name, invalid revision expression or incompatible object type returns
no identity. Structural NUL/oversized text, selected-runtime failure, malformed
metadata and cancellation throw distinct failures. Unexpected repository or
process errors are not manufactured into a missing revision, clean state or
unknown remote branch. This intentionally preserves stronger diagnostics than
source TODO paths that swallow some repository errors.

The new private helper verb returns one bounded, versioned canonical-base64 JSON
receipt. Exact keys, booleans, OIDs, operation and final framing are validated;
textual stderr is never parsed as an identity. Invalid selected-engine output
cannot fall back to CLI. No batch endpoint is added merely to reduce test calls.
The source master switch governs this lookup, not GetCommit14 or another mask.
Revision metadata commands remain read activity for Finder operation fencing.

`referenceExists` inspects an exact full reference, including the reference
itself when symbolic and dangling. Revision expressions are not names for this
API. `branchTagNameIsUnique` captures one backend and checks the corresponding
heads/tags names. CLI syntax validation precedes symbolic/reference probing;
real probe failures remain errors instead of broad fatal-exit suppression.

## Connected workflow ownership

Create Branch/Tag captures the backend in its accepted form and reuses it during
object resolution. Tag plans now allow tree/blob/raw-tag targets; branch and
Switch preparation retain commit requirements. Prepared local targets retain
validated object IDs, while existing remote-branch tracking semantics remain.
Names, messages, description timing and follow-up choices keep their established
controls and source icons.

Push captures the engine through uniqueness, existence and default mapping
reads. Short branch/tag collisions are rejected before transport, while qualified
references retain their distinct identities. Fetch/Rebase and Sync use typed
commit resolution at existing preparation, inspection and continuation points;
an unresolved source preset remains an editable Rebase preset according to the
separate Fetch-refspec contract. This family does not reinterpret literal
refspecs or replace the actual CLI/libgit2 transport selection.

Literal revision/configuration arguments use command-only
`core.precomposeunicode=false`; the repository's stored normalization setting is
not changed. Exact NFC/NFD packed references remain independently selectable.
Accepted native reads retain cancellation, generation, draft, sheet/child and
retirement ownership; late callbacks cannot publish into another request.
Existing query injections are retained for their original fixture contracts.
Automatic Branch-to-Switch and Fetch/Sync-to-Rebase handoffs carry the accepted
repository actor through deferred work and queued preparation. Reusing an idle
Rebase window retains that actor for default action reads/writes; a later
independent load returns to fresh settings. An active Rebase refuses a competing
automatic handoff before replacing owner callbacks. Successful Pull retains its
completed Git result if subsequent metadata fails, displays a completion warning,
withholds unavailable follow-ups and inhibits automatic closing.

## Grouped verification and remaining limits

Nineteen focused `GitRevisionLookupTests` methods cover source/typed identities,
unborn/detached HEAD, tag/tree/blob peeling, exact Unicode names, dangling
symbolics, collisions, selected-runtime and malformed-wire failures, cancellation,
accepted-form backend retention, read activity, actual tree/blob/tag creation,
actual Switch and read-only Push/Sync preparation. Private fixtures use a stored
normalization setting of true and literal packed siblings; no external server is
contacted. CLI command-warning/probe fixtures explicitly disable the master
helper so they continue to exercise the intended CLI boundary.

The grouped Core checkpoint covers 135 distinct methods cumulatively. Its first
run passed 127; the focused recheck passed all eight initially failing methods
and three affected retained CLI oracles. Repairs resolve `revision:path` before
applying object-type requirements, preserve literal Unicode at the helper
boundary, and preserve Sync's required-revision `GitFailure` contract. No
behavioral assertions were removed. Both architecture helper contracts, including
the new revision/reference protocol, pass. The final Debug build exited zero;
two contradictory generic exit-zero compiler diagnostics remain recorded.

All eight native case/engine pairs pass with system and bundled Git. They cover
actual Branch/Tag creation, Switch/Push preparation, root Fetch/Sync-to-Rebase
handoffs, successful Pull followed by malformed metadata, queued Rebase actor
retention, a later independent load, cancellation and malformed-helper refusal.
The first attempt stopped at fixture compilation before launching a receiver;
explicit actor isolation on the fixture context repaired that compile boundary.
All eight attempted receiver processes were reaped and independently absent.
The [dated checkpoint](qa/revision-lookup-family-2026-10-24.json) records actual
attempts, source identities, repairs and scope.

Physical controls, hosted full CI, minimum-OS/Intel, signed/App Store deployment,
SHA-256 libgit2 support and every remaining caller outside this accepted workflow
family remain separate scope.
