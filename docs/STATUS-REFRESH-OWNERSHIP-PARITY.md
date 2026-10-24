# Working Tree, Commit, Log and Finder refresh ownership

This family separates fresh display reads from optional index-stat writes and
makes Working Tree cancellation settle without immediately replaying an older
passive refresh. The initial Core checkpoint found a real remaining diff-write
path and a subsequent stale-stat display artifact. Four distinct Core methods
with each Git executable and six native case/engine pairs now pass after the
recorded repairs. Signed build/static checks, recoverable installation and
focused physical refresh/close acceptance also passed.
[QA record](qa/status-refresh-family-2026-10-25.json).

## Source and observed problem

Pinned upstream `7338078f8ddd924b8cddee35f512f2286072136d`,
`TortoiseProc/ChangedDlg.cpp:150–172`, changes the primary button to Cancel,
disables refresh/filter controls and explicitly calls `RefreshGitIndex` before
acquiring status. Its `OnOK`/`OnCancel` at 201–218 cancel busy acquisition and
return without closing; idle invocation closes the dialog. Commit also calls
`RefreshGitIndex` at `CommitDlg.cpp:1386`.

The [previous installed checkpoint](WORKSPACE-REPORT-OWNERSHIP-PARITY.md) observed
Working Tree refresh recurring between close attempts. Cancel followed by
Command-W closed it; stale accessibility elements complicated that observation.
Raw index SHA-256 changed from `1dc9d64e…` to `e0b7f945…` while staged content
still matched unchanged HEAD and all four entries retained ordinary flags.
An index-stat refresh was inferred, not established as the sole cause. That
historical evidence is retained rather than rewritten as a clean acceptance.

## Native behavior

`GitStatusReadPolicy.automatic` computes current status with
`GIT_OPTIONAL_LOCKS=0`. It suppresses Git's optional on-disk index-stat refresh,
which otherwise generates watched index/index.lock events. It does not reuse an
old status cache or suppress subsequent external filesystem changes. Working
Tree display reads and both Commit status/index-flag display reads use this
policy. Finder's already read-only CLI collection now names the policy
explicitly; its helper receives the same environment contract, while its
existing read-only C collection algorithm remains unchanged.

This is a macOS adaptation for live filesystem observers: upstream explicitly
refreshes index stats. Manual native Refresh still reacquires current repository
state using the read-only display policy. Commit/Working Tree file statistics
and staged/unstaged display diffs use command-local
`-c diff.autoRefreshIndex=false` plus the optional-lock environment for their
name-status, numstat and raw reads. Git diff's quiet index refresh ignores the
optional-lock gate; protecting only the status command would leave that write
able to trigger the same observer echo. Repository configuration is unchanged.
Log's working-tree history and selected working-file patch readers use the same
command-local suppression, so that observing or previewing that row cannot
publish another index-stat event.

With auto-refresh disabled, Git name-status/raw output may retain an `M` entry
when only stat metadata changed. The display-file parsers now omit only `M`
rows without a corresponding numstat path record. This tests record presence,
not numeric totals: real binary `-/-`, mode/gitlink `0/0`, type changes and
staged renames remain visible. Log retains its existing status-gated inventory.
Mutating Git actions retain their
normal index writes. Public Core `status(refreshIndex:)` and
`workingTreeStatus(refreshIndex:)` retain their existing default `true`, mapping
to `.refreshIndex`; an explicit caller can still request that behavior.

Working Tree busy Cancel clears passive reloads already queued before the
cancellation. It retains a separately accepted invocation scope in
`pendingScope`, so that requested operation is not silently discarded. A later
external change may queue a new reload. Cancel retains the last accepted table
and leaves the dialog open; failed or cancelled acquisition cannot publish a
partial replacement. Idle close, manual refresh, selection restoration,
repository/access ownership, modal/Quit guards and retirement remain governed
by the existing owned operation token and file-list lifecycle.

## Checkpoint and remaining limits

Four authored Core cases independently inspect raw index bytes, inode and
nanosecond modification/change times; real FSEvents boundaries plus an explicit
index-refresh positive control; external edit/deletion/untracked freshness;
Finder full and overlay modes; and cancellation without a surviving lock.
Repeated reads include actual working-tree and both staging display-diff paths,
with external modification/deletion assertions on the resulting file records.
The positive control explicitly skips if the caller globally disabled optional
locks. These are behavioral witnesses, not only command-string assertions.
The authored [native fixture](qa/status-refresh-native-2026-10-25.swift) and
`scripts/test-status-refresh-family.py` cover three connected cases with both
Git executables: actual workspace/Working Tree monitoring plus Commit reload,
busy cancellation and subsequent freshness, and pending-scope/Quit/retirement
ownership. Windows and sheets remain test-owned and offscreen; held reads are
injected only for deterministic cancellation boundaries. Grouped results will
be recorded after the implementation freezes.

The initial system-Git run executed all four Core methods: cancellation and
Finder collection passed; the two automatic-read/index-event cases failed seven
assertions. Actual FSEvents included index/index.lock and the raw index witness
changed. Git's `builtin/diff.c` `refresh_index_quietly` does not honor the
optional-lock environment gate, so the related display-diff commands also need
command-local `-c diff.autoRefreshIndex=false`. That production repair is now
authored; the focused recheck is pending. The original assertions remain intact,
with separate raw-index witnesses after each actual display read to identify a
remaining writer precisely.
Initial Debug build session 57974 exited zero before this repair, with 38
contradictory “command failed with exit code 0” diagnostics and the simulator
version warning retained. The second focused system run passed the index-event
method, but the repeat-read method failed its clean-diff emptiness assertion:
all index witnesses passed, exposing the stale-stat `M` artifact described
above. The third focused run, session 85933, passed that affected method with
real binary, chmod, type, dirty nested-gitlink and staged-rename variants.
Together with the original cancellation/Finder passes this covers all four
distinct system methods cumulatively; it does not erase either earlier failure.
Repair Debug sessions 8726 and 62883 exited zero at their respective source
states, both with zero contradictory exit-zero diagnostics. Bundled four-method
Core run 19707 exited zero, giving eight distinct method/engine passes across
the cumulative system and bundled scopes.

Initial native run 59645 failed the system monitor external-change wait. The
diagnostic run 24674 retained that failure and showed fresh workspace entries
but a fixture-created repository URL with `isDirectory=false`, unlike the
workspace's `true` URL. The fixture now uses the production directory URL form;
no behavioral assertion was removed and no production change was made for that
mismatch. System monitor repair 15472 passed, cancel/scope run 12910 passed all
four pairs, and bundled monitor run 64950 passed. These six distinct native
pairs use the cached receiver library. All eight attempted receivers, including
the original failure and diagnostic, were reaped and independently absent:
73918, 74393, 74625, 74847, 74907, 74981, 75035 and 75127. Only the existing
Finder extension 67907 remained; no GUI/cache process survived the checks.

Monitor and cancellation cases emit the reentrant NSTableView delegate warning;
that diagnostic remains open. These are functional passes, not clean runtime or
full visual parity certification. Localization check passed 38 locales/1,318
labels. Signed build 82197 exited zero, retaining three contradictory exit-zero
diagnostics, against measured source inputs
`f5a4d7afb2fe9575ae08eb1f1696d618a84d7901ba0ce15f9d64ed8d11e005b6`;
static session 11133 exited zero with those inputs unchanged. It verified eight
universal owned components, 206 runtime code items and 6,356 inventory members
(SHA-256 `f6d3f6cdbd7af92d8d560a9125aa75b3ebef74e46d5b53033eb5db6648056093`),
same-team app/Finder/cache identity and App Group, version 0.1.0/build 2.
These are static checks, with zero new functional runtime cases or GUI launches
before installation. Recoverable install session 28138 then exited zero,
matching all 6,356 measured inventory members; the displaced installation is
retained at `build/qa/status-refresh-displaced-installed-2026-10-25`. Installed
main executable SHA-256 is
`dd67f67fcff7aa2b52309906c69d99dccec62e7e5b73b1a9a05960a3b55aeb1b`.
The changed Finder binary was registered through supported pluginkit operations
and elected at the single installed path. Extension 67907 retired naturally;
77954 replaced it without a direct Finder-process kill.

The [focused installed receipt](qa/status-refresh-installed-2026-10-25.json)
records an unchanged tracked file's deliberately stale stat before launch, then
the actual installed app opening the private fixture through Open Panel.
Working Tree automatically reflected an external edit and its restoration;
idle OK closed once. Commit's Git GUI staging display loaded three unstaged
files, manual Refresh was invoked, and Cancel/Yes retired it. Command-Q exited
normally without a signal. Raw index SHA-256 remained `e0b7f945…` throughout
this checkpoint, with HEAD, config and all six original working files unchanged.
This new evidence does not overwrite the earlier index-delta observation.

Cleanup restored the file timestamp and forgot only the fixture's permission,
preserving the unrelated Recent repository; the cleanup app quit normally.
Independent process inspection found no owned GUI/cache/receiver remaining,
preserving Finder extension 77954. No new screenshots, appearance checks or
wider physical Finder-command tests were performed in this focused acceptance.

Read-only investigation identified synchronous table view requests/artwork
configuration inside `NativeListSelection` row delegates as a possible warning
origin. No diagnostic stack establishes that cause; no repair is claimed.
Coverage reconciliation passed (130 resource dialogs, 120 partial, 10 pending,
85 unmapped controls, zero certified); these are audit counts, not a completion
percentage. Final site generation rendered 450 documents with zero unresolved
fragments.

At this checkpoint the de753 Pages run 40139781184 succeeded; macOS run
40139781252 remained in progress. Prior macOS run 40132230473 is a terminal
failure, not a live run. No complete current hosted CI pass is claimed.

This bounded family does not prove every status-dependent dialog, every external
tool/index writer, wider physical Finder integration or the full upstream port.
The shared-list warning, complete current hosted CI, App Store archive/export/
submission and wider source parity remain open.
