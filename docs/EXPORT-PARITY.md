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
