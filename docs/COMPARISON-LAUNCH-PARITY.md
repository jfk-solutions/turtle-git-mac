# Selected-file comparison workflow

The connected [historical command family](COMMAND-LINE.md#historical-comparison-cat-references-and-graph-output)
adds source ShowCompare, Cat, containing-reference and Revision Graph entry,
authorized staged output, independent reference windows and hidden graph exports.
Existing native layouts, original icons and renderer/comparison consumers remain.
[Batch evidence](qa/history-commands-2026-10-18.json) retains focused checks and
explicit Windows-format/process, physical, signed and complete parity gaps.

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


## Captured tool selection — October 15, 2026

The selected-file launch owner now captures Shift at dispatch. Its task-local
invocation value survives confirmations and Git preparation, and nested routes
inherit it without changing independent launches. A child comparison captures
that value during construction, before SwiftUI starts its later loading task.
This ports GitLogListBase's captured bShift and AppUtils' alternative-tool
inversion to asynchronous native workflows. It covers working/checked files,
historical pairs, merge-parent groups and marked-file comparisons through the
shared launch path. Finder file-pair permission prompts capture the choice before
permission selection. Conflict-editor handoffs inherit the same choice.

Changed Files and repository comparison caches distinguish default and alternate
invocations, so an existing built-in viewer cannot absorb an alternate-tool
request. Blame's parent/source Compare action explicitly carries its chosen
modifier into the shared route. Sync change-set comparison captures before
format-patch, and its selected-file unified action now forwards Shift instead of
always choosing the default. Sync and Changed Files pass their owning tool
preferences to both native children and external dispatch.

An external application launch failure leaves tool dispatch retryable in the
same comparison window. Reload clears the prior error and retries the original
choice. Failed launch snapshots are removed; successful launch snapshots remain
available through the existing app-owned external-preview lifetime. Cancellation
is checked before snapshot preparation and immediately before dispatch. Once an
external application has accepted the launch, the app does not terminate it.

Grouped native evidence and limits: [tool-selection batch](qa/comparison-tool-family-2026-10-15.json).
Core engine behavior is unchanged; no Core suite was repeated for these native
routing changes. Physical Shift/menu gestures, actual third-party application
activation, signed grants and all-dialog parity remain separate acceptance work.


[Changed Files workflow parity](COMPARE-WORKFLOW-PARITY.md) continues the native
comparison controls, exact file selections/caches, compared-range Log routing,
owned Save/Export/Open With/list panels and exact Revert/Export backends. Its
grouped evidence and explicit acceptance limits supplement this family.
