# Working Tree scope, staged rows and accepted Revert

This connected continuation ports Changed/Working Tree's original acquisition
boundary, conditional staged inventory and action operands for `IDD_CHANGEDFILES`. It preserves global
workspace Status and embedded Revert consumers. It is not a complete-dialog or
whole-port completion claim.

## Source and actual gap

Pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`:

- `src/TortoiseProc/ChangedDlg.cpp:167–168` installs `m_bIncludedStaged` from
  Show Staged and passes either the original path list or null for Whole Project
  into `GetStatus`. The staged checkbox is independent of Whole Project.
- `ChangedDlg.cpp:450–462` persists each checkbox and starts a fresh acquisition.
  Loaded-category filters for unversioned, ignored and locally ignored files
  retain their existing status-list meaning. ChangedDlg has no separate Show
  Unstaged checkbox; outside partial staging remains actual XY metadata, not a new
  staged-only filter invented for this port.
- `src/Git/GitStatusListCtrl.cpp:4136` passes the list and included-staged policy
  into `GetWorkingTreeChanges`. `src/Git/Git.cpp:3460–3512` queries each original
  scope independently; only included-staged admits a global cached raw query.
  Source raw action/origin union and cached-first statistics distinguish an
  accepted scoped Added leaf from a global Rename.

Previously the native dialog captured its filter but read global status, global
line statistics and a global gitlink roster, then filtered the published rows.
Besides walking unrelated generated directories, that can classify a rename
across the invocation boundary differently and expose an old-name action or
historical Compare operand that the source scoped query did not accept.

## Connected behavior

Accepted Revert retains a `WorkingFileRevertReadScope`: original read paths,
included-staged policy, and a separate exact allowlist made only from the selected
outside staged rows and their accepted source-Rename origins. The allowlist does
not become the query scope and cannot reclassify a cached Rename as independent
per-name Added/Deleted rows. It survives partial index publication through Retry;
unselected staged names, parent directories and unrelated outside files are not
operation authority. Source and progress own this receipt until acknowledgment.

`StatusWindowModel.reload` captures the complete filter before suspension. Its
default status reader passes `paths` and `includedStaged` into Core before Git:
null scope means explicit Whole Project/global; a selected path list retains
literal names and independent source raw queries. Existing injected token-only
`readStatus` closures remain supported, and embedded report reloads retain their
parent's established callback.

Show Staged off acquires only the original invocation. Show Staged on keeps global
cached staged visibility, while outside actual XY metadata is queried only for
accepted cached names with untracked discovery disabled. Outside mixed index /
working rows retain their actual XY; unrelated unstaged-only, ignored and
unversioned directories do not become globally inventoried. Whole Project on
explicitly reacquires global data; turning it off reacquires the original scope.

Statistics use the same original independent scopes. Whole-working statistics win
inside them; cached statistics supply accepted outside staged rows without a new
outside whole-working diff. That cached fallback retains source default50 C-before-M;
configured similarity belongs to whole-working detection, independently of ordinary
staging APIs. Exact accepted report paths supply gitlink metadata,
and existing index flags and filesystem metadata keep their bounded readers.
Captions, source icons, old-name menus, clipboard, line counts, explicit Compare
and default activation consume the accepted source action/origin together.
An Added scoped arrival therefore compares from the empty side rather than
silently reacquiring a Rename origin from a later global status query.

## Accepted Revert and Retry

The synchronous menu acceptance captures three separate facts until its owned
callback acknowledges completion:

1. Original accepted read paths, null for Whole Project/global.
2. The accepted included-staged policy.
3. Exact outside names from the explicitly selected staged rows and their
   accepted source-Rename origins, with byte-exact stable deduplication.

`WorkingFileRevertReadScope` carries these through Root, progress, fresh mutation
preflight and Retry. The additional names are an operation allowlist, not an
expanded source query: separately querying old and new names as new original
scopes could reclassify a cached global Rename into Added/Deleted rows. No other
staged row or containing directory gains permission merely because it was shown.
The exact allowlist also survives partial index publication before Retry, without
reacquiring unrelated outside unstaged files. Existing Add/Revert invocation and
legacy global callers retain their default APIs and policy.

Failed Revert progress retains source/Quit ownership until acknowledgment. Refresh
is deferred while an owned mutation runs. Cancel of a normal refresh keeps the
previous complete table and source window; a separately queued scope remains
owed. Forced closure retires late publication, cancels the actual read and waits
for the owned worker/window release.

## Prepared native verification

The dedicated receiver is
`docs/qa/changed-scoped-status-native-2026-11-23.swift`, run by
`scripts/test-changed-scoped-status.py`. It reuses helper-only copies of retained
private native fixtures and the receiver compilation cache. Its three repair
selectors are `projection`, `retry` and `cancellation`; the default retains all
assertions with system and bundled Git.

The authored cohort uses literal Unicode/newline/glob-looking directory names,
actual natural index renames and mixed staged/working files. It verifies real
mounted reports, source Added-versus-Rename and old-name menus across Show Staged
and Whole Project toggles, actual Root empty-side comparison bytes, inside whole /
outside cached line counts, and a real Root-owned outside-Rename Revert failed
attempt and Retry. The retry preserves unrelated staged entries and restores the
accepted original source bytes. Turning Show Staged off cannot accept that
outside target. Held actual Git status reads cover Cancel, queued rescope,
forced close, Quit guards and unchanged repository bytes.

NUL-delimited executable argv receipts enforce scoped status/raw/index operands.
Global cached discovery is admitted only under the included-staged policy;
outside status supplements must name an accepted staged leaf and disable
untracked discovery. Phase receipts persist under `build/qa`. Helpers use private
repositories/preferences, invisible windows and verified owned-process cleanup.
No timing threshold is used as a performance assertion.

The [grouped checkpoint](qa/changed-scoped-status-2026-11-23.json) records 67 distinct
focused Core methods cumulatively, six native cohort/Git passes, the final Debug
build and 47 distinct CI-contract passes. Initial fixture compilation, scored-R/argv
witness and hosted-neighbor failures remain recorded with focused repairs. Passing
scopes were not repeated. All six logged compiler/receiver/build PIDs were absent;
no installed app was updated. Physical keyboard and
VoiceOver, signed grants, Finder deployment, full layout comparison and complete
hosted CI remain separate acceptance work. The current source batch does not
modify the ongoing WMF/EMF implementation.
