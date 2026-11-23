# Scoped Add, Revert and Commit working reads

This family preserves the original invocation boundary through the Git reads,
report refresh and accepted Revert operation. Scoped Commit preserves the source
requirement to include staged changes outside that boundary. It does not change
ordinary global Working Tree inventory, explicit global Commit inventory, the
Commit Whole Project policy, selection
checkboxes, source action captions, or the independent staging state.

## Pinned source behavior

The reference is TortoiseGit commit
`7338078f8ddd924b8cddee35f512f2286072136d`:

- `src/TortoiseProc/AddDlg.cpp:148` passes `m_pathList` to
  `GetStatus(&m_pathList, false, includeIgnored, true)`.
- `src/TortoiseProc/RevertDlg.cpp:117` passes `m_pathList` to `GetStatus`.
- `src/Git/GitStatusListCtrl.cpp:4136` forwards the selected
  path list into working-tree discovery.
- `src/Git/Git.cpp:3460–3512` constructs the path filters before querying status
  and raw changes. The cached global inventory is conditional on the independent
  `includedStaged` policy; it is not required for every scoped dialog.

- `src/TortoiseProc/CommitDlg.cpp:1404` enables the independent included-staged
  policy. Scoped Commit reads must therefore retain outside staged files while
  limiting current working/untracked discovery to the selected folder.

Filtering an already-completed global inventory does not implement this behavior:
Git may have walked unrelated untracked directories before the filtered rows
reach the dialog.

## Implementation

Revert also queries gitlink metadata only for its accepted report paths through
the bounded submodule catalog API. Unrelated index entries are not needed to
classify the selected rows; existing callers that omit the scope retain their
global catalog. The strict native argv oracle caught and motivated this consumer
repair rather than permitting an unbounded metadata read.

Core status and source-action readers accept optional literal `paths` and the
independent `includedStaged` switch. `nil` is an explicitly global read, `[]`
reads no paths, and `["."]` is the repository-root invocation. User path bytes
remain literal, including spaces, Unicode, newlines, tabs and glob characters.
Each scoped raw source-action query retains its own boundary and pinned copy /
rename argument order; a clean direct file can still become an Add report row.
A rename's origin remains available when the actual source query includes both
names. Discovery does not widen a single destination request merely to find an
old name outside its invocation.

Commit passes its captured accepted invocation to the combined display reader.
The current/untracked side stays scoped; the cached/staged source pass remains
global by design. Parent-amend support retains its source-wide base semantics.
Whole Project explicitly switches to global discovery, and switching it off
reloads the original scope. Classic and Git Gui staging reports consume the same
accepted data. The default Core API remains global for existing consumers.

Add captures its scope and ignored-file option before suspension. Its index-flag
metadata comes from an exact accepted-row index query rather than a second
whole-repository status read. The existing direct-file, ignored-file, clean-file
and checked-row policies remain in place.

Revert captures its scope for status, index flags and statistics before report
publication. Refresh and a replacement scope use their own owned cancellation
receipt. Existing injected status/statistics closures retain their token-only
API. Embedded Revert progress and Root's accepted/direct Revert handoff capture
`invocationPaths` synchronously. The progress model keeps this immutable boundary
for fresh selection, Retry and mutation instead of consulting a later source
model. Ordinary global callers retain the default `nil` boundary.

## Grouped verification scope

`docs/qa/scoped-working-reads-native-2026-11-23.swift` and
`scripts/test-scoped-working-reads.py` define four connected native cohorts:

- Actual Classic and Git Gui Commit reports with outside staged visibility and
  unrelated unstaged/untracked exclusion, real Whole Project on/off reloads,
  literal status/current/raw/index operands, and held-read Cancel/Quit drainage.
  Only the source-required cached diff may query global staged inventory. An
  outside partially staged MM file remains in both staging panes; its accepted
  working-side state/statistics are read through bounded exact-file queries. A
  separate outside unstaged-only file remains excluded. Classic source statistics
  retain cached fallback outside the invocation and whole-working priority inside.
- Actual Add report folder and direct-file reloads, clean/ignored rows, accepted
  index flags and exact path-bounded status/raw/index argv.
- Actual Revert report and reload, rename origin inside the selected directory,
  a real Root-owned failed progress attempt followed by Retry and actual selected
  restoration, with the original invocation scope and unrelated staged data
  preserved.
- A held initial status read replaced by another scope, rejection of its retired
  result, Quit ownership while reads are active, and actual Add Cancel drainage.

The executable wrapper records NUL-delimited argv from the real Git processes;
setup reads use a separate executable so they cannot masquerade as bounded UI
queries. The cohort authors unrelated generated files and staged changes, and
requires every current/status query to carry literal paths within its admitted
boundary. Commit cached diff queries are the explicit source exception, and its
accepted-row index metadata and supplemental working diffs may include the
authored accepted outside staged file; outside status metadata must use `--untracked-files=no` without ignored discovery.
Untracked discovery remains within the original invocation. It checks real mounted report projections and exact HEAD/index/working
bytes around read-only operations. It uses private repositories/preferences,
invisible windows and owned-process cleanup. `--only` selects an affected cohort
for a focused repair; the default retains all assertions for both Git engines.

The coordinated batch checkpoint passed. Argv receipts demonstrate
query scope, not a timing benchmark, complete hosted CI, physical Finder behavior,
signed deployment or visual acceptance of every upstream dialog. No claim of full
port completion follows from this family.

## Recorded checkpoint

The [family receipt](qa/scoped-working-reads-2026-11-23.json) records 95 distinct
focused Core cases across retained scopes and repair checks, eight scoped native
cohort/Git passes, two retained Sync/Git passes and 46 workflow-contract checks.
It preserves initial fixture compile errors, the missed global gitlink catalog
query and the conflict-stream multiplicity regression with their actual repairs.
No wall-clock speed guarantee, complete hosted pass, physical Finder acceptance,
signed deployment or whole-port completion follows from these checks.
