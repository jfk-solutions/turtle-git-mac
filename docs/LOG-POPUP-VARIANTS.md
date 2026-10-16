# Log revision popup variants

This connected family follows `GitLogListBase.cpp`'s selected-count branches,
parent menus, clipboard/Find tail, and `GitLogListAction.cpp`'s comparison and
`ID_FINDENTRY` handlers at pinned commit
`7338078f8ddd924b8cddee35f512f2286072136d`.

## Source-shaped command groups

| Selection | Native revision popup behavior |
| --- | --- |
| No rows | No revision commands |
| One ordinary commit | Working-tree comparison, unified diff, previous revision, then existing revision commands |
| Root commit | Working-tree comparison; no invented previous-parent or parent unified command |
| Merge commit | Parent/mode unified submenu and parent comparison submenu |
| Two revisions | Endpoint comparison, unified diff, three range Log orientations and change-set comparison; no disabled single-commit commands |
| Three or more contiguous revisions | Endpoint comparison; unified two-revision command omitted |
| Three or more discontinuous revisions | Endpoint comparison and Format Patch omitted; other eligible multi-selection commands remain |
| Working-tree row | Commit/operation commands, HEAD comparisons when HEAD exists, shared clipboard and Find tail |
| Working tree plus a contiguous range | Comparison uses the oldest selected commit and live working tree; Revert retains the original row count but skips the synthetic row before Git |
| Bare repository | Revision/parent comparison retained; working-tree and unified commands omitted according to the source masks |

Existing branch/ref targeting, transport, Rebase/Merge, Revert, Combine,
Cherry Pick, patch, Bisect, deletion and clipboard payloads retain their current
native factories and captured-menu ownership. Main command ordering follows the
source comparison group. Separator normalization removes leading, trailing and
adjacent separator entries without changing command payloads. This does not
claim complete consumer-specific menu-mask parity.

## Find and clipboard

Find now appears after the clipboard submenu, with the original filter-edit
icon. It opens the existing native Find window. The popup captures the clicked
selection mark before menu tracking ends; Find starts from that row even after
menu-close cleanup. Keyboard context menus capture their selected row. Other
menu commands no longer reset the Find cursor merely by opening the popup.
Find is dispatched through the same one-use captured target as the other revision
commands, so selection replacement, away/return, reload or another use refuses
an old invocation. Existing Command-F and Find window ownership remain intact.

Working-tree clipboard commands use the synthetic row's displayed subject/body
and captured tracked-file snapshot, rather than asking Git to resolve its empty
hash. Full details include status/path/rename origins; no-path details omit that
list. Mixed selections preserve displayed order and include both synthetic
working-tree details and pinned commit details. Empty revision/author/date fields
remain empty for the synthetic row. A private clipboard can be injected for QA.
The existing cancellable commit-detail reader and permission checks are retained.

## Verification and remaining work

[Dated results](qa/log-popup-variants-2026-10-16.json) record the actual Debug
build, native menu/clipboard/Find checks and retained history/Find regressions on
system and bundled Git. The new receiver uses a real native Log and bare clone;
comparison and Revert dialog handoffs are injected. It checks exact endpoints,
synthetic-row exclusion and unchanged HEAD/index/working contents.

No new popup screenshot or physical tracking/VoiceOver claim is made. All
consumer-specific masks, minimum-size/long-label positioning, signed Finder and
full application parity remain open. The connected
[Revert selection continuation](LOG-REVERT-PARITY.md#original-selection-context--october-16-2026)
preserves mixed working-tree/root, merge and stash batch semantics. Incomplete/
discontinuous Follow history still needs further source comparison and acceptance;
the synthetic row is never passed to Git as a commit.


## Filtered and projected range selection — October 16, 2026

Pinned `GitLogListBase::IsSelectionContinuous` treats one selected row as
continuous. For multiple rows, the shown list must contain every loaded walk row
and the selected indices must be adjacent. It does not infer continuity merely
from adjacency after a filter, graph compression or rollup has hidden rows.

The native Log now retains the raw walk row count with each displayed projection.
Compare for three or more selections, Format Patch ranges of three or more and
Combine use this source rule. Two-row endpoint comparison and Format Patch keep
the source's explicit exception even when other rows are hidden; Combine still
requires continuity. A single filtered row remains continuous. An active filter
that matches every row does not disable range commands. File-scoped/Follow walks
use their own raw result rather than treating unrelated repository commits as
hidden display rows. Follow does not acquire a new single-tip or ancestry rule.

Incremental history prefixes publish their source count with their graph/rows.
Cancellation or failure restores the previous coherent count and display. A
finished walk counts its optional working-tree row consistently with the displayed
list. Existing limits define the loaded walk, not an assertion that the repository
history has no additional commits.

Revision popup relays now capture the display projection epoch in addition to
load generation, selected hashes and references. Replacing rows/order expires an
old popup even when its selected entries remain unchanged. Combine's asynchronous
ancestry check and final dispatch retain the same projection identity; late
validation cannot enable an old menu item after filtering/reordering. Busy history
loads do not start new Combine validation reads from their partial prefix.

Ordinary revision picker Logs retain the ordinary upstream Log menu mask.
`SetSelect` changes selection behavior; it does not impose an invented read-only
command set. Dedicated Rebase/Blame/RefLog lists retain their existing native
consumer-specific command implementations. This continuation addresses range
eligibility, not complete mask certification for every consumer.

See [grouped native evidence](qa/log-range-selection-2026-10-16.json) for actual
filtered/labeled/Follow menus, captured patch ranges, failed-load restoration,
held Combine read and retained popup/history/streaming checks. Core code and the
existing `FormatPatchPreset.hasHiddenRows` policy are unchanged. Full physical
menu tracking, all rollup/filter/Follow combinations, visual/VoiceOver behavior,
signed Finder and App Store acceptance remain open.
