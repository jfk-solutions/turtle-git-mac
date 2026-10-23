# Commit scope and file-list message report

This continuation compares pinned `CommitDlg.cpp` initialization (220–221),
`StatusThread`, `OnBnClickedWholeProject` (2798–2824), and
`HandleMenuItemClick`'s Paste file list branch (2208–2244), together with
`GitStatusListCtrl::Show`, `Clear`, and `CTGitPath::GetActionName`.
The exact source revision remains recorded in `upstream.json`.

## Repository scope and accepted refresh

Show Whole Project now remembers a per-repository choice in the supplied private
or production preference store through `CommitScopePreference.key(root:)`.
A subpath launch defaults to false. Opening the repository root still displays
the full project because the invocation itself covers the root; this does not
turn a later subpath launch into a whole-project launch or overwrite its saved
choice. When the saved choice is true, the original requested files/directories
remain in `scopePaths`, so unchecking the option restores that scope.

Both the actual checkbox and the Commit command menu invoke
`setShowWholeProject(_:)`. The transition runs a full status preparation, including
current index/working statuses, metadata, changelists, statistics, staging state,
report policy and patch refresh. It does not merely reveal an old hidden row.
Read and owner cancellation reuse Commit's retained reload worker and token checks.
The accepted scope, title, rows, checks and saved preference remain in place while
the read is held; an error, cancelled read or retired owner cannot install the
requested scope or write its preference. An accepted snapshot updates scope,
window title and stored choice together. Native form receipts reject delayed
checkbox/menu actions behind another operation or owned sheet.

The source's filename-to-checkbox map matters: `Show` restores known check states
before applying `dwCheck`, and `Clear` does not clear that map. Native scope
transitions likewise preserve known manual checks and deselections across scope
shrink/expansion. Newly discovered versioned rows use source whole-project
selection defaults, including when ordinary automatic selection is disabled.
Explicitly requested unversioned files remain eligible for their direct-file
check; other loose files stay unchecked. Missing-file, submodule and
ignore-on-commit policies remain in force for automatic selection.

`StatusThread` includes staged files outside the selected working-tree scope in
both modes. Native visibility retains those rows; the initial classic defaults
can include their staged contents. In staging mode the displayed three-state
checkboxes continue to reflect the index, including partial state, rather than
being changed by the scope preference. A scope change performs no independent
stage/unstage action. Existing explicit missing-staged-file recovery retains its
own user decision and operation ownership.

## Paste file list

The message editor's existing Paste file list command now takes its file order
from the same sorted and grouped rows as the table, excluding group headers.
Its membership comes from classic checked paths or actual staged/mixed checkbox
state. Changing highlighted selection alone does not change the report.

`CommitFileListReport` follows the source action priority and captions, including
Conflict, Added, Missing, Deleted, Modified, Rename and Copy. An unversioned file
selected for Commit is reported as Added. Copy/rename statistics supply the
original path where porcelain status has none. The table's Path cell and report
share full/abbreviated rename/copy formatting, using this window's preference
store. Raw Git names, including Unicode spelling, spaces, stars and newlines,
are not trimmed, translated or split. Captions use a minimum ten UTF-16-unit
field width without truncation. Native editor line endings remain LF.

The legacy `tsvn.logfilelistenglish` project key now has an explicit native
consumer, refreshed with the accepted list. Its default is true; false localizes
only known action captions. Effective local/worktree/command configuration takes
precedence over `.tgitconfig`, which takes precedence over global/system values,
through the existing project-property reader. Invalid boolean values produce a
read diagnostic and retain the preceding accepted snapshot.

This language policy is a documented native adaptation: pinned
`ProjectProperties.h` declares the key and a default-true field, but the pinned
source never assigns that field from configuration. The Paste branch computes a
`langID` and does not apply it to the already obtained `GetActionName()` result.
Thus the pinned code does not demonstrate a working language switch in this
branch; the native consumer honors the declared intent explicitly.

## Implementation evidence and remaining work

The focused Core fixtures are
[CommitScopeReportTests.swift](../Tests/TurtleGitCoreTests/CommitScopeReportTests.swift).
They cover exact root keys, private preference isolation, ordered checked
membership, raw filename spellings, action priority, copy/rename formatting,
caption-only localization/padding, and effective project-policy precedence.
The shared
[native scope/report/Push fixture](qa/commit-scope-report-push-native-2026-10-23.swift)
uses the production owner and editor action, held/cancelled scope reads, private
preferences and native controls. The
[shared checkpoint](qa/commit-scope-report-push-2026-10-23.json) records their actual
local results; fixture existence alone does not establish a pass.

The connected footer/progress Push continuation is implemented by the Push family;
Commit carries an explicit origin and the captured attempt's Amend flag across
that handoff. Its progress, destination and transfer evidence is recorded with
that family at the same checkpoint.

Full physical checkbox/menu/paste/IME and VoiceOver acceptance, every localized
source action resource, signed permission flows and all upstream Commit states
remain open. This batch does not establish whole-dialog or whole-application
completion.

This is a partial continuation of `IDD_COMMITDLG`; its static control mappings
and full layout/behavior acceptance remain separate. The
[shared checkpoint](qa/commit-scope-report-push-2026-10-23.json) records actual results.

## Grouped validation checkpoint

The [dated shared checkpoint](qa/commit-scope-report-push-2026-10-23.json) records
22 relevant Core methods and six native case/engine pairs passing. The first Core
attempt stopped during new-test compilation because a fixture constructor omitted
a required argument; supplying it repairs the test without a production change.
The Debug app build exited zero with 29 generic “failed with exit code 0”
diagnostics. Native scenarios passed on their first execution; all six receivers
were reaped and independently confirmed absent. The two scope receivers each
emitted two AppKit table-delegate reentrancy warnings. A bounded static review
identified shared row-decoration callbacks as a plausible cause; no runtime stack
was captured, and a related native-list follow-up remains open. This checkpoint
does not certify physical interaction, signed execution, current hosted integration
or whole-dialog parity.
