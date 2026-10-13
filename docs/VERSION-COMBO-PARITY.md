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
