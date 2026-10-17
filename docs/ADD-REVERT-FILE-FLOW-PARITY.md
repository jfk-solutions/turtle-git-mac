# Add and Revert file-command flow

Reference: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`CGitStatusListCtrl::WriteCheckedNamesToPathList`, `CTGitPathList::SortByPathname`,
`CTGitPath::Compare`, Add/Revert dialog acceptance and their status-list file
commands. The source collects checked rows, then sorts pathnames. It does not
submit the current visual sort order unchanged.

## Checked operation order

Add and Revert accept each checked plan once. Repeated OK/keyboard acceptance
cannot launch a second copy of the plan while the first handoff closes its
window. Starting an explicit new scope resets that acceptance state.

GitPathOperationOrder keeps exact valid UTF-8 membership, compares ASCII letters
without case in UTF-16 ordinal order, and compares slash separators as the
upstream backslashes while retaining the original returned macOS path. Exact
bytes break ties without merging Git names. File10 precedes File2 regardless of
logical/numeric display sorting. Add preparation and mode post-actions, Revert
preparation/Retry and bounded removal/restore batches use the same ordering.

The source's non-ASCII fallback uses Windows CRT `_wcsicmp`; complete locale-
dependent CRT equivalence is not certified. The native comparator deliberately
retains distinct valid Git spellings, including canonical Unicode aliases and
macOS filenames containing literal backslashes. Arbitrary invalid UTF-8 names
and physical filesystem aliases remain separate work.

## Native chooser and launch ownership

OwnedFilePanelSession now serves Add's Save As, Export and Open With, and Revert's
shared file commands. It captures the exact picker and continuation, accepts one
reply, and resumes only after AppKit releases that picker from its owner. A
foreign picker callback or a duplicate response is ignored. Cancellation and
forced retirement override a queued approval, end the owned sheet and reject
late OK replies. A sheet-ending notification schedules the release check on the
next main-queue turn. The session cannot be reused after retirement.

Add owns a single file request from destination/application selection through
copy or external-launch completion. Busy state prevents duplicate requests and
checked-plan acceptance. Its existing global operation count blocks application
Quit and retains the repository grant until the worker drains, including after a
forced window close. A cancelled outstanding chooser cannot start a later launch;
an external launch already in progress drains before releasing its lifetime.
Late success/error cannot publish into a retired dialog.

Save/Export retain their captured source paths and use the existing atomic copy
and destination-grant backend. Open With retains its selected application scope
through the workspace callback. Alternative Editor now uses this Add dialog's
preferences and awaits the existing editor launch completion with retained
repository permissions. Picker cancellation returns to the unchanged Add window;
parent cancellation during work waits for completion before closing the parent.

Revert's existing shared Status operation owner and Save As owner now use the
same picker session. Cancellation dismisses their pending picker; forced closure
retires it before model teardown. Busy/Quit ownership continues through the
existing operation's continuation and worker drain.

## Evidence and remaining acceptance

See [batch evidence](qa/add-revert-file-flow-2026-10-17.json) for actual build,
Core/native results and cleanup. The checkpoint passed 53 distinct relevant Core
cases across retained/affected runs and twelve native case/engine combinations
with system/bundled Git. Three affected fixture callers also compile. All owned
receivers/helpers were reaped and independently absent. The first native attempt
was stopped before launch by an unchanged-source timestamp guard; normal rebuild
resolved it. One bundled refresh assertion was rechecked after the preceding
keyboard selection was explicitly settled; no unique production root cause is
claimed. The native case checks source pathname order
under a different visual sort, repeated acceptance, captured Open With targets,
held launch/Quit lifetime, cancellation before late approval, real Save/Export
bytes, editor routing and actual native panel cancellation/reuse/forced close.
External application launches use injected completions, so no unrelated user
application is launched by this fixture.

No changed dialog layout is claimed. Existing Add/Revert screenshots remain in
[selection parity](ADD-REVERT-IDENTITY-PARITY.md). Physical Browse/selection,
accessibility, signed chooser grants and external application handoff, complete
non-ASCII Windows sort equivalence, the retained Revert AppKit delegate warning,
full source popup/state coverage and signed Finder/App Store acceptance remain
open.


## Hosted compiler compatibility

The two preceding hosted heads failed before native checks at Blame selection's
ordinary Set equality against an array literal. Newly introduced cross-type
GitPathSet/Set operators made overload resolution ambiguous on that compiler.
Those global operators are removed; exact-path callers compare the same explicit
type. Blame selection semantics remain unchanged. The affected 22 Core cases
passed locally after the repair, retaining 31 unaffected passes. A new hosted
build must still verify the repair; this is not a full CI-green claim.
