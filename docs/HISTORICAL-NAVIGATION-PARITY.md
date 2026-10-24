# Historical navigation and revision ownership

Pinned source: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
This record covers the connected Browser, historical submodule, history-reference
and accepted child-operation readers. It does not declare the complete history
or Repository Browser port finished.

## Source boundaries

`RepositoryBrowser.cpp:448–527` opens a libgit2 repository for `ReadTree`, checks
unborn HEAD and calls the static `CGit::GetHash(repository, revision + "^{}")`.
That initial tree read does not consult the master `UseLibgit2` preference.
Commits yield their tree; standalone trees remain trees; an annotated tag is
dereferenced. A blob or unavailable object cannot become an empty tree.

Later Browser commands use instance `g_Git.GetHash`, including comparison marks
at lines 893/906, Save As at 1233 and Open at 1257. Those reads follow the source
master switch, independently of individual command-mask bits. The native port
keeps the initial/static versus later/master distinction explicit through
`repositoryBrowserRevision(initialization:)`. Immutable Browser snapshots and
file bytes remain pinned to their accepted object/tree; moving a displayed
branch does not silently replace the snapshot.

`Git.cpp:1392–1433`, `GetSubmoduleHash`, returns without a historical lookup when
the source master flag is off. When enabled it requires an actual commit, its
tree, the literal selected path and a commit-mode tree entry. A missing path or
ordinary file is an error for this source Log-pin consumer. `FileDiffDlg.cpp:682`
uses the resulting child hash to select its Log revision. This differs from a
generic old/new gitlink comparison, where an absent entry is a legitimate
addition/deletion side. The APIs therefore distinguish `.missing`, `.other` and
`.gitlink`, while `submoduleLogRevision` preserves the stricter source boundary.

`RepositoryBrowser.cpp:1265–1300` validates the displayed gitlink in the child
checkout before opening that child's Browser. It does not substitute the child's
current HEAD for an unavailable displayed commit.

`GitLogListAction.cpp:1040–1060` dispatches reference deletion to
`CAppUtils::DeleteRef` (`AppUtils.cpp:3788` onward). Native confirmation receipts
retain exact reference bytes, object identity and symbolic target. Execution
rechecks those witnesses before deletion; a canonically equivalent Unicode name
is a separate Git reference. Read failure does not certify an unchanged target.
These stale-state fences are stronger native ownership checks, rather than a
claim that upstream performs an atomic transaction across every confirmation.

## Connected native behavior

Accepted reads capture the owning preferences/backend once. Log integration,
Browser navigation and comparison marks, historical submodule Log/revision
commands, and reference deletion retain that capture through their owned reads.
Automatic prepared Rebase passes its accepted actor through `acceptedRepository`.
Merge receives the parent actor, while its later options actions capture settings
separately. A Bisect handoff rechecks and pins its revision preset; the independent
Bisect dialog captures its own preferences at load/start rather than inheriting
the Log actor. These are separate acceptance boundaries.

Bisect preparation and post-operation reads retain their accepted actor through
Stash, Start, Reset and recovery. Actual Bisect Git commands remain CLI, matching
the existing source operation route; this does not invent a new masked libgit2
Bisect mutation. Existing Jump and Notes dialogs are outside this batch.

Query injection hooks remain available for native fixtures. Cancellation and
retirement fence publication and retain access/process ownership until children
drain. Missing selected helpers, invalid framing and process diagnostics remain
errors; they do not trigger a CLI fallback or an invented empty/absent result.

## Literal data and protocol

Reference and Git-tree path comparisons use UTF-8 byte identity, including packed
NFC/NFD reference pairs and distinct canonical path spellings in one tree.
Invocation-only `core.precomposeunicode=false` preserves selected data without
changing the stored normalization preference. The native filesystem may be unable
to represent both canonical spellings as loose files; tests keep such reference
pairs packed and build historical tree objects directly.

Browser resolution reuses the strict single-revision protocol. Historical entry
lookup uses `turtlegit-historical-gitlink`, a bounded stdin request containing
version, resolved revision, literal path and the commit-only requirement. Its
single canonical-base64 reply has exactly `status` and `oid`; missing/ordinary
entries carry null, and a gitlink carries a validated object ID. Malformed data,
extra fields, invalid identities and oversized output are refused.

## Grouped validation and remaining limits

`HistoricalNavigationTests` contains sixteen focused Core methods. They cover
real commit/tree/raw-tag and unborn Browser reads, packed Unicode aliases,
immutable snapshot bytes after ref movement, initial-static versus later-master
routing, snapshot/backend retention, malformed/process/runtime errors, pre-cancellation and live owned-helper
drain, generic absent/ordinary/gitlink distinctions, strict source Log pins,
canonical historical paths, and exact stale-reference deletion.

The grouped Core run covers 77 distinct methods cumulatively. Its initial run
passed 73; eight focused methods pass after preserving the existing SHA-256
Browser extension and correcting three fixture contracts. The live cancellation
oracle accepts both supported cancellation error types while retaining process
reaping assertions. The retained CLI wrapper explicitly selects its CLI engine;
the ancestry stub delegates new metadata reads to the real helper. Original
repository-state and identity assertions remain intact.

Both architecture helper contracts pass, including actual gitlink/missing/ordinary
entry probes and unchanged HEAD/index/configuration. The final Debug build exits
zero; one contradictory generic exit-zero compiler diagnostic remains recorded.
All eight new native case/engine pairs and four retained Browser routing/lifecycle
pairs pass with system and bundled Git. One retained lifecycle attempt timed out
waiting for its legacy command marker; its exact phase was not identified. The
fixture now holds the actual typed helper and explicitly selects CLI for its
listing/materialization/writer boundaries, retaining all live-process, Quit, close
and repository-state assertions. Only those two affected pairs were repeated. All
thirteen attempted receivers were reaped and independently absent. See the
[dated checkpoint](qa/historical-navigation-family-2026-10-24.json).

Bounded `ls-tree` inventories remain a CLI implementation adaptation; this batch
does not claim that every Browser byte is read through libgit2.

Remaining limits include full physical keyboard/menu/drag acceptance, signed
sandbox deployment, and every broader history/Browser workflow. Error diagnostics
and cancellation fences are native adaptations where the source may suppress a
failure or run a separate process without equivalent owner tracking. This batch
does not change Notes storage, general Jump behavior, or add new backend controls.

## Explicit SHA-256 Browser extension

The pinned libgit2 supports SHA-1 repositories. The existing macOS Browser also
supports Git's SHA-256 repositories and pinned 64-digit restore targets. Browser
readers now elect that extension explicitly from `rev-parse --show-object-format`
before launching a helper: SHA-1 retains the unconditional static initial lookup
and master-selected later commands; SHA-256 uses the existing CLI typed object
and subtree readers and records that choice in child snapshots. Invalid or failed
format detection remains visible. Missing, failed or malformed SHA-1 helper output
does not trigger a fallback. Directory/file snapshots retain the SHA-256 choice
and immutable object identity through restore, without modifying repository config.
