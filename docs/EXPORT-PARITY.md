# Export parity

Export remains partial. The native options and owned result adapt pinned
TortoiseGit 7338078f8ddd924b8cddee35f512f2286072136d, ExportDlg.cpp/IDD_EXPORT,
Commands/ExportCommand.cpp and CAppUtils::Export. Physical and signed acceptance
remain pending.

Options retain ZIP destination, HEAD/Branch/Tag/Commit choice, branch/reference
and Log pickers, Whole Project and OK/Cancel/Help. Revision choices use native
macOS radio buttons. A missing extension becomes .zip. Directories are rejected before prompting. Existing files ask for
replacement with Cancel default. The selected revision, scope and destination
are captured before awaiting that answer. No, or cancellation during the prompt,
leaves existing bytes and starts no archive/result. Root scope fixes Whole Project;
a selected existing directory can export its contents without its prefix.

Production now owns a separate native progress sheet. Options stay locked until
acknowledgement. Success offers Show in Finder with the original Explorer icon,
including the split menu. It releases both result and options before revealing
the captured ZIP, once. No Finder reveal happens just by constructing the action.
Failures/cancellation have no post-actions, matching the source callback's lack of
Retry. Failed Close restores the native options for another reviewed export,
an existing Mac ownership adaptation rather than upstream's discarded options.
Headless callers without a presenter retain the previous inline result API.

AutoCloseGitProgress is captured when the result is constructed after overwrite
acceptance. Manual keeps results; no-options keeps success because Explore is
available; no-errors closes successful results without invoking Explore. Failures
remain open. ConfirmKillProcess defaults through the shared preference and uses
native Yes/No, Yes default. No keeps running; Yes cancels only the owned Git group.
Completion during a pending question delays automatic close until its answer;
a late Yes does not cancel an already completed result.

Core archiveRevision resolves a commit/tree and delegates ZIP/attributes/modes to
Git. It writes an owned temporary sibling, checks cancellation, then replaces the
destination with rename. Failure/cancellation preserves a previous ZIP and removes
the temporary. This differs from upstream's direct write, protecting an existing
archive. HEAD/index/working contents are not intentionally mutated. Scope and
metadata-directory guards remain active. Native Store models retain repository
and exact destination access leases and recheck them at progress execution;
unsigned checks do not establish signed grants or Finder access.

[Progress QA](qa/export-progress-2026-10-08.json) records four-Git real ZIP contents
for whole/scoped exports across policies, captured owner fields and once-only
reveal callback, overwrite No/pre-presentation cancellation, error/options return,
owned cancellation with old ZIP/temporary preservation and fresh/deferred exports.
The [October 10 progress QA](qa/export-progress-2026-10-10.json) covers the new
streaming and forced-close cases with system and packaged Git. This update uses the shared read-only AppKit output view,
original Copy icons, source error/warning and success/failure footer colors,
captured output bounds, current-work/percentage parsing, and timing/locale footer
preferences. Git archive normally emits paths without numeric progress; the bar
stays at zero until completion unless the command supplies a progress line. Core streams only the verbose archive command, never revision or
metadata probes or binary ZIP contents. Command failures retain the streamed
diagnostic once and add the actual exit-code footer; validation and filesystem
failures still append their own diagnostic. Close remains visible and disabled while
busy; Abort cancels while running, closes a failed result, and is disabled after
success. Escape follows the same guarded cancellation/completed-close behavior.

A forced result/parent closure invalidates presentation, dismisses pending
confirmation state, and cancels the owned operation. Options are unlocked only
after Git and temporary-file cleanup finishes. Late chunks and confirmation
answers cannot revive the abandoned result. Pre-start invalidation completes the
owner handoff without spawning Git. Closing the options owner during overwrite
confirmation cancels that attempt and fences a later Replace answer. Normal cancellation still retains its result
for acknowledgement and preserves an existing ZIP.

Native options/result controls are hosted without displayed windows. Actual
Finder reveal, physical sheet/default-button/keyboard/close/Quit interaction,
rendered themes, accessibility, geometry, filesystem completion, full progress
parity and signed sandbox/Finder/App Store acceptance remain pending. Existing
screenshots predate this owned result and radio replacement.

## Sync revision export and options lifetime (October 11)

The single-row Sync history menu now offers **Export this version…**, in the
source position after branch/tag commands, with the original Export icon. It
captures the full selected hash, preferring the first tag pointing at that commit
as `GitLogListAction.cpp` does. The pointed branch label does not override this
choice; multiple selection omits Export. Root commits remain exportable.

Sync owns the native Export options sheet and its existing archive progress.
Competing actions and normal parent closure are blocked while it is open. Cancel
ends the sheet explicitly; forced owner closure dismisses children and cancels
startup reference/branch reads. Those reads retain their access lease, own a
cancellation token/task, and cannot publish fields or errors after cancellation.

The native revision-list fixture passed with system Git 2.54.0 and packaged Git
2.55.0. It verifies captured actions across tab/selection changes, root and tag
selection, modal ownership, real ZIP contents, progress closure, startup Cancel
and forced-parent process cleanup. Refs, index and configuration remain unchanged
by Export. Receivers 62480 and 63395 were reaped. Debug and unsigned AppStore
bundle audits passed. Physical save panels, full chooser behavior, visual matching
and signed repository/destination/Finder acceptance remain unverified.
See [the Export verification record](qa/synchronization-export-2026-10-11.json).

### Export sheet geometry follow-up

Actual light/dark captures exposed intrinsic sheet sizing that clipped the top
group title and footer. Export now gives its hosted root the native minimum size
and sets window content/minimum sizes from the fitted view before presentation.
Repeated two-engine native checks passed (receivers 67677 and 68628, both reaped),
including the minimum-content-size assertion, archive and cancellation cases.
Inspected captures show the complete source group order, full hash, Whole Project
and OK/Cancel/Help controls without clipping. The original upstream ExportURL.png
and IDD_EXPORT resource were compared. Native radios/popups/buttons adapt their
appearance to macOS; complete chooser/edit-history and physical/signed acceptance
remain pending. See [light](site/assets/sync-export-light.png) and
[dark](site/assets/sync-export-dark.png) captures. All 18 static Export controls
are now mapped as partial in the inventory; this does not certify the dialog.

### Export version pickers follow-up

Export's Branch ellipsis now uses the shared full Browse References window in
all-reference, single-selection mode. This replaces the earlier branch-only list.
It follows CChooseVersion::OnBnClickedButtonBrowseRef: both an accepted canonical
name and Cancel reload the reference catalog, classify branch/tag choices, and
preserve the typed commit draft. Selecting a tag from the branch chooser changes
the selected radio to Tag. Unknown reference names remain editable commit
expressions. Export retains its root/directory scope and ZIP destination.

The Commit ellipsis now uses the shared owned Log picker at the typed revision,
with single selection and working-tree rows disabled. Cancel retains the draft;
OK captures the full selected hash. Both children prevent competing pickers,
Export and normal options closure. Forced options closure ends its child sheet,
cancels reads and rejects late callbacks. Reference refresh owns its task/token
and access lease; Cancel export can also terminate this read and close options.
Complete source focus restoration, revision edit-history, physical input and
signed repository/chooser acceptance remain open. The previous layout captures
retain their rendering scope; these changes affect picker routing, not the options
layout. Verification is recorded separately in
[the picker record](qa/export-version-pickers-2026-10-11.json).

The two-engine native run completed successfully with actual reference/Log
sheets, fresh tag creation/selection, Cancel catalog refresh, forced child closure
and real process cleanup for startup/selection reads. Final Debug and unsigned
AppStore compilation passed; the current Debug bundle audit and inventory gate
passed. See the dated record for exact scope and receiver PIDs.

Export now uses the shared [editable revision session combo](VERSION-COMBO-PARITY.md)
for its Commit row. The underlying captured ZIP export/picker workflow is unchanged.
Full physical/signed acceptance remains open.

## Command settlement, atomic finalization and result ownership — October 19

Pinned `CAppUtils::Export` (`AppUtils.cpp:1055–1113`) uses generic command progress
and a success-only Explore action. The native result retains that action and
source icon, captured ZIP/revision/scope/permissions and existing options/pickers.
The streamed preamble now comes from Core's actual executable/argv rather than a
separate display reconstruction. It truthfully names the owned temporary archive
path used by the native atomic-export adaptation. Display quoting is POSIX;
metadata probes and binary archive bytes are not presented as command output.

A command receipt follows actual archive process/output drain before destination
replacement. The existing styled footer/timing and completed 100 percent are
retained through finalization. Command success and workflow success are separate:
an atomic replacement failure adds a diagnostic and offers no Explore action,
without claiming that Git failed. Cancellation after command completion can still
prevent finalization, preserving an old ZIP and removing the owned temporary.
The output view now receives the original private preferences and pasteboard.

Start reserves actual queued work before scheduling. Invalidated or forcibly
closed results retain worker/finalization ownership until cleanup settles;
result/options callbacks wait for actual native detach and question release.
One-shot No/Yes replies cannot revive a retired result, cancel settled command
work or act during Quit. Show in Finder is dispatched only after an intended
result/options close, once; forced closure drops a queued reveal. Options progress
inherits the parent's appearance/opacity value. Normal and background Quit gates
include actual workers and outstanding native release transitions.

The [grouped record](qa/stash-export-progress-family-2026-10-19.json) preserves
actual validation attempts. The atomic sibling/rename behavior remains a macOS
adaptation. Physical Finder reveal, rendered dialog geometry/themes, keyboard/
VoiceOver, signed repository/destination grants, hosted CI and complete port
acceptance require separate evidence.
