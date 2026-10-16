# Rebase reference controls and preparation

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`, `IDD_REBASE`,
RebaseDlg::LoadBranchInfo, OnBnClickedButtonBrowse, OnBnClickedButtonOnto,
and its branch/upstream change handlers.

Branch and Upstream now use dropdown-only native popups, as the pinned resource
does. Branch includes local and remote branches rather than only local branches.
Upstream also includes tags and a valid for-merge FETCH_HEAD. Both preserve exact
canonical identities separately from their short display labels and show original
branch/tag/fetch artwork. An explicit preset not in the reference list remains a
selectable item, including an immutable hash supplied by Fetch. No selection shows
a placeholder rather than making the displayed first item look selected in the
model. Disabled and dismantled shared popups reject callbacks and scheduled focus.

Upstream Browse now opens the full native reference browser with its existing
hierarchy, filters, columns and configured context routes. It retains the owning
Rebase's repository, preferences and access lease. Onto is the source-style
pushlike checkbox that opens the same browser; its selected identity is shown as
a tooltip. The previous extra editable Onto row and small filtered list sheet
are removed. Cancellation clears an existing Onto choice, as source PickRef does.
Refused presentation preserves fields. An accepted Onto is resolved separately and
cleared if its commit equals either Branch or Upstream, including a differently
named tag. Invalid selections clear Onto and retain a diagnostic. No Git mutation
occurs while selecting or preparing these references.

Picker requests capture Branch, Upstream and Onto and retain an independent
identity. Accepted values survive the browser's close-before-completion ordering.
A stale or retired request cannot replace fields or create another plan. Closing
the parent retires its browser; delayed callbacks cannot revive it. Pending Fetch
handoffs remain queued until the picker/preparation releases the owner.

Initial reference/state loading, ordinary and Cherry Pick plan capture, active
replay metadata and selected commit details now share cancellable owned reads.
Core cancellation reaches revision/state paths, commit message decoding, replay
entries, the log/cherry/ancestor queries and Onto alias resolution. Expected
missing-reference and detached-head handling cannot swallow cancellation and
continue to another read. Ancestor failures no longer silently become ready plans.

Replacing fields cancels the previous plan and selected-detail read. Each result
checks its captured generation and token before publishing; an old defer cannot
clear a newer plan's loading state. Byte-based option signatures coalesce duplicate
field notifications while retaining canonically distinct Git names. Explicit
refresh and accepted browser choices bypass that cache. Re-selecting an unchanged
name after its ref moves therefore captures a fresh hash, as PickRefForCombo does. Start remains unavailable until the current plan
settles. A preparation progress/Cancel control is separate from replay mutation
controls. All owned reads retain access and global Quit accounting until their
Git children settle, even after forced window retirement.

This batch does not replace the replay mutation/active-session recovery engine.
The remaining hook/network/signing, active-session refresh, full conflict menus,
physical Return/Escape/popup/VoiceOver input, whole-window light/dark layout,
complete reference tooltips and signed sandbox/Finder acceptance remain open.
The Debug build passed after exposing the shared cancellation check across the
module boundary. The 96-test affected Core group found one cancellation-fixture
exception-type mismatch; its focused recheck passed, giving all 96 cumulative
passing evidence. Ten grouped native cases passed across system/bundled Git.
An accepted-reference cache correction then passed its two affected native checks
without repeating Core or the other native families. All twelve receivers were
reaped. See [actual results and repairs](qa/rebase-references-2026-10-14.json).


## Canonical Log presets and warning-safe IDs — October 16, 2026

Log's local-branch preference now retains its canonical identity through all
repository-configured Log-to-Rebase callbacks, including child picker Logs.
A same-named tag cannot change the native Upstream preset or captured plan hash.
Switching between canonical branch and tag choices rebuilds the corresponding
plan. Unlabelled Log commits retain their exact object ID. Git stdout supplies
commit identities and symbolic branch names; stderr remains diagnostic output.
The existing cancellation, stale-plan execution checks and Git's typed-revision
resolution are retained. See [connected evidence](qa/log-canonical-integration-2026-10-16.json).
Full physical/signed and complete dialog parity remain open.
