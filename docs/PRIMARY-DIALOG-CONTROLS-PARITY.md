# Commit, Log and Settings controls

This continuation compares the native main dialogs with pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`. It addresses connected controls,
layout, saved choices and their owning windows. It does not certify complete
dialog or application parity.

## Commit

The source form options and focus commands belong to the same Commit draft:
new branch, amendment, author/date overrides and resets, comparison with the
previous commit, staging support, unversioned files, submodule autoselection,
whole-project scope and message-only commits. Native menu actions must obey the
same conditional availability as their corresponding form controls.

Opening a menu does not authorize a later action against a changed draft or a
closed window. Metadata reads must also remain tied to their accepted owner and
Quit state; dismissing a Quit question does not make an old read current again.
The existing checked-file/index preparation, staging transactions, status colors
and remembered Commit/ReCommit/Commit & Push actions remain separate implemented
parts of the family.

## Log

The source `ColumnManager` excludes Graph from the visibility menu. The default
native list keeps the small graph first and preserves source-supported column
reordering. Reset and divider fitting use content and header measurements;
Shift fitting returns a column to automatic sizing. These operations persist
through the existing column preference store.

Header menus, their Reset confirmation and the delayed Ordering route must retain
their accepted list, preferences and window context. Closing the parent must
drain a real outstanding confirmation before releasing its repository access.
The main native window also retains its declared minimum size when SwiftUI
updates its content.

Source references: `src/TortoiseProc/ColumnManager.h`,
`src/TortoiseProc/ColumnManager.cpp` and `src/TortoiseProc/LogDlg.cpp` in the pinned
checkout. Existing graph painting, colored reference labels, search/date
controls, split proportions and changed-file actions have their own family
evidence; adding column controls does not replace that evidence.

## Settings

Opening Colors directly must support saving appearance without first visiting
General. The owning Settings transaction therefore registers its appearance
draft independently of the currently constructed page. Theme changes preview
immediately; Apply saves the accepted choice and Cancel restores the saved
choice. Preview ownership must end when the sheet is retired.

Git configuration, Dialogs 3 and Colors retain the source groups with compact
native fields and thin group frames. Status/reference color samples and graph
lane samples reflect draft values before Apply. Restore Default participates in
the same draft transaction. Existing config-source/inherit/save scopes and the
bordered Remote list and repaired OK/Cancel closure remain part of the native
Settings family.

Source references: `SettingsColors.cpp`, `SettingsColors2.cpp`,
`SettingsColors3.cpp`, the Git configuration and Dialogs property pages and their
resource definitions in the pinned checkout.

## Validation and remaining work

The grouped checkpoint uses `scripts/test-primary-parity-family.py` for the three
native families after the complete implementation freezes. The
[dated record](qa/primary-dialog-controls-2026-10-21.json) reports actual results
and failures; the presence of this guide alone does not establish a passing check.

Full upstream state/layout coverage, physical keyboard and accessibility
acceptance, installed signed Finder entry points, minimum-version/Intel
acceptance and a complete current hosted integration pass remain open. The
dialog ledger tracks review coverage rather than a feature completion percentage.

## Commit option bands and Log menu artwork — October 23, 2026

The pinned `IDD_COMMITDLG` resource places the conditional “Show diff to last
commit” checkbox at the right of the Amend band. File statistics appear directly
below the file list, above the patch links. The native dialog now follows those
positions, with the lower checkbox and statistics columns aligned at their tops.
The footer retains Commit's split action, Cancel and Help; Refresh remains on F5
and the Commit menu, as advertised in the Changes caption. No commit, staging,
author/date or checked-file semantics change with this layout correction.

Log's native Copy submenu and merge-parent Revert submenu now obtain their icon
visibility from the same captured preferences as the rest of that popup. This
matters when an owning workspace has a distinct preference domain. The existing
SwiftUI root already supplies that domain to its font and date consumers; no
font/date propagation defect was established by this review.

The grouped checkpoint is recorded in
[the dated batch evidence](qa/primary-layout-patch-encoding-2026-10-23.json).
This correction does not certify every conditional layout or physical gesture.
