# Selected-file comparison workflow

The pinned TortoiseGit source is `7338078f8ddd924b8cddee35f512f2286072136d`.
`GitStatusListCtrl.cpp::CheckMultipleDiffs` and
`FileDiffDlg.cpp::CheckMultipleDiffs` use the selected-row count, a strict greater
than comparison, the unsigned DWORD `NumDiffWarning` default 10, and a minimum
threshold of 3. Yes is the default answer. Ordinary GNU status-list patches are
aggregated; two-revision/per-file viewers receive the many-viewer warning.

Native selected-file launches share one owner from initial confirmation through
Git preparation and viewer handoff. The originating window is captured before
suspension, including callbacks from Log, Commit, Working Tree, Add, Repository
Browser and Blame. No performs no preparation or launch. A source-window close
cancels its owned alert and Git child; a delayed injected Yes cannot revive the
launch. Quit is blocked while the operation still owns a read or question, even
if its source controller has been removed.

The shared routes cover ordinary working files, previous versions, two working
files, two historical files, prepared historical/working marks, historical path
lists and grouped merge-parent file lists. Groups are prepared together before
any viewer opens and share one selected-row question. Captured paths and resolved
snapshot endpoints feed the viewers; later highlight changes do not retarget
them. Existing per-path viewer reuse and submodule handoffs are retained.

Commit’s aggregate patch captures its amend/base and staged/working choice before
suspension. Log’s revision, selected-file and working-tree patch reads retain
selection/generation fences and now cancel owned Git processes. Working Tree uses
its existing operation token. Aggregate patches remain one viewer and do not
ask a many-viewer question. Changed Files’ explicit per-file unified command
shares the same question/session ownership as its comparison command.

A child file viewer also owns its initial/replacement historical blob read.
Retirement cancels that read and cannot publish a document, error or external
launch afterward. Closing while the read is running cancels preparation, then
returns through the normal close/dirty-document handling. Active reads retain
repository/file access leases and guard Quit until they finish.

## Validation and remaining acceptance

The grouped receiver is `docs/qa/comparison-launch-native-2026-10-14.swift`.
It uses private repositories/preferences, captured presentation callbacks,
actual NSAlert ownership and intentionally delayed Git children. It covers
working/historical/grouped endpoints, threshold equality, refusal/approval,
retired approval, parent closure, started preparation/blob cancellation,
aggregate Commit/Working Tree/Log patches, and unchanged HEAD/index/work bytes.
The QA record separately reports actual results; this description is not itself
a passing result.

Physical user interaction, visual comparison with upstream, configured external
tool activation, signed sandbox grants, minimum-OS execution and full hosted CI
remain separate acceptance work. This batch does not certify all comparison
menus or the complete TortoiseGit port. Other viewer/editor source-parity gaps
remain tracked in their comparison documents and the dialog coverage ledger.

The shared [rename/copy detection family](DIFF-DETECTION-PARITY.md) now connects
source percentages, paired file/patch reads, pinned snapshot policy and historical
cache invalidation. Its separate validation record reports the actual scope.
