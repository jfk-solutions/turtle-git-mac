# Shared editable revision combo

Pinned source: `7338078f8ddd924b8cddee35f512f2286072136d`,
`CChooseVersion` in `ChooseVersion.h`, `HistoryCombo.cpp/.h`, and the
`IDC_COMBOBOXEX_VERSION` controls in the Switch/Merge/Branch/Tag/Reset/New Worktree/Export
resources.

The commit-revision row previously used a plain NSTextField. It now uses one
editable NSComboBox implementation in Switch, Merge, Branch/Tag, New Worktree and
Reset and Export, retaining each caller's own focus/enablement/selection ownership. The
separate Reset text-field adapter has been removed. Branch/tag popups retain their
existing full-reference behavior.

CChooseVersion::SelectRef adds an otherwise-unclassified revision to its version
combo. The native models now retain those programmatic custom selections during
the dialog session and show them in the combo. Initial custom presets enter the
same list. CR/LF folding, surrounding whitespace trimming and the bounded append
behavior follow HistoryCombo. Ordinary typing does not normalize text or add an
entry; Log's selected hash changes the text without inserting a history item,
matching the source's SetWindowText call. No new persistent history store is used:
ChooseVersion does not load a version history, and Switch's SaveHistory call is
commented out.

Native choices retain exact UTF-8 identity, including case and Unicode variants,
so distinct Git tokens are not collapsed. This deliberately differs from the
source HistoryCombo's default case-insensitive duplicate search. Native values
also retain qualified custom refs, consistent with the existing native picker
routing, instead of stripping the source's `refs/` prefix. Full Windows locale,
whitespace and overflow behavior remains unverified.

The combo disables automatic completion, preserves text/caret when its item list
changes, and binds both typing and native popup selection to the captured model.
Disabled and dismantled controls reject callbacks. Scheduled focus requires a
live enabled control/coordinator and then uses each owner's existing focus guard.
Checkbox options, repository operations, progress and modal picker ownership are
unchanged by this control replacement.

The existing Switch and creation picker receivers now join the common app-object
cache and default CI group; their standalone scripts delegate to it. The grouped
check also retains Merge picker coverage. This does not certify physical popup
mouse/Return/Escape/VoiceOver behavior, every layout/theme/minimum size, signed
sandbox execution or complete ChooseVersion/dialog parity.

Eight grouped native cases passed with both Git engines, followed by two affected
control cases after adding Export. The final Debug build passed; Core was unchanged
and not retested. See the [scoped acceptance](qa/version-combo-2026-10-13.json).

The connected [Log reference-navigation family](LOG-REFERENCE-NAVIGATION-PARITY.md)
adds source reference-set scopes, multi-tip/range picking, bounded exact recents
and owned browser/preparation lifetime. ChooseVersion histories remain session-only.

The shared dropdown popup now rejects disabled/dismantled callbacks and deferred
focus on retired controls. Rebase uses it with original reference icons; see
[Rebase reference preparation](REBASE-REFERENCE-PREPARATION-PARITY.md).

## Shared ChooseVersion handoffs — October 15, 2026

Pinned `ChooseVersion.h::OnBnClickedChooseVersion` starts a single-selection Log
at the entered revision and excludes the working-tree row. Its BrowseRefs route
refreshes the catalog even on Cancel, preserving canonical branch/tag/custom
reference identity. The shared native coordinator now supplies the revision
before constructing Log, with private preferences and the owner's appearance and
opacity. Switch, Create Branch/Tag and New Worktree now configure the same shared
production Log commands as Merge and Reset. That checkpoint added accepted hashes
to editable session choices; the November 27 correction below restores the
source text-only behavior. ChooseVersion does not load/save a persistent version
history here.

One request owns its pending return until both child retirement and actual sheet
detachment. Duplicate, refused, obsolete and retired callbacks cannot replace a
newer request. A byte-exact snapshot of target and revision inputs rejects results
that would overwrite an edited draft. Branch/Tag additionally retains its HEAD,
name and follow-up options; New Worktree retains its HEAD, destination and branch
options. Catalog results also validate their initiating selection draft after
Git returns. Cancel still refreshes catalogs for an unchanged draft.

Export participates in the same chooser handoff, retaining its target, destination
and whole-project selection. Its former insertion of accepted commits into session
choices is superseded by the November 27 correction below.
Merge/Export catalog reads and Create Branch/Tag metadata now keep global Quit/access
ownership until settlement after forced owner close, matching the existing
shared Switch reader. This is a workflow handoff improvement; it does not prove
all options, complete visual parity or signed sandbox acceptance. The dated QA
record states the actual grouped native scope and any observed failures.

[Shared chooser QA](qa/version-picker-lifecycle-2026-10-15.json) records the actual
source comparison, six accepted case/Git pairs, original failures/repairs and
owned-process cleanup. Full dialog/application parity remains incomplete.

## Cancel refresh correction — November 25, 2026

The shared coordinator now forwards an unchanged Cancel to the reference reader,
as required by pinned `ChooseVersion.h` lines 148–163. The read retains its owner
and draft guards. An unchanged result preserves custom tracking and creation
options instead of reporting another selection to Branch/Tag or Worktree.
The reference control receives one focus request. Existing native fixtures now
create a reference after opening the picker and require it in the parent catalog
after Cancel; their draft, stale-callback and retirement assertions remain.
Validation is recorded in the recovery checkpoint, not inferred from this code.


## Log selection history correction — November 27, 2026

The grouped CI repair reached the version-combo assertion and exposed a product
regression introduced by the later shared picker handoffs. Pinned
`ChooseVersion.h` lines 96–118 assigns the selected Log hash with `SetWindowText`;
`SelectRef` lines 198–204 separately inserts an unclassified programmatic
reference with `AddString`. `CGitSwitchDlg::OnVersionChanged` only updates defaults.
These paths must preserve that distinction.

Switch, Merge and Export now assign the accepted Log hash without appending it
to session choices. Branch/Tag and Worktree inherit the shared Switch chooser
behavior; Reset's separate accepted Log callback follows the same rule. Existing
one-use return, target/draft checks, retirement, defaults and focus guards remain.
Programmatic custom reference selections continue to enter the session list.
The six-consumer combo fixture retains its original text-only assertion and adds
exact unchanged-choice checks for the other consumers. Actual Branch and Export
picker returns retain their cancellation, stale-draft and Git-data assertions
while requiring the exact preexisting choice lists.

Validation is pending the combined repair checkpoint. This source change does
not alter Core or bundled runtimes and does not certify every physical picker
interaction or the complete upstream dialog inventory.
