# Native patch file panel

Source pin: `7338078f8ddd924b8cddee35f512f2286072136d`,
`TortoiseMerge/FilePatchesDlg.cpp` Init, OnLvnItemchangedFilelist,
OnNMDblclkFilelist, OnNMRclickFilelist, PatchAll and PatchSelected;
`MainFrm.cpp` OnUpdateViewShowfilelist/OnViewShowfilelist.

Review/apply single patch now uses an AppKit table for Files to patch. Its
unsorted Path/State columns retain patch order, multiple selection, native file
icons, basename labels, complete target-path tooltips, bold current preview,
muted patched rows and red error rows/diagnostics. The existing per-file Git
application, independent checked backend API and immutable source patch remain.

Highlighting changes only the selection, matching LVN_ITEMCHANGED; it does not
replace a comparison or change checkboxes. Double-click, Return/keypad Enter or
Preview patched file load exactly one selected eligible file. Error-row Preview
shows its existing diagnostic inline. Completed rows cannot be previewed again.
This supersedes the earlier single-highlight automatically opening a comparison.

Native right-click selection preserves an existing multi-selection. Context
commands retain source order: Preview patched file, Patch all files, Patch selected
files. They reuse the original comparison/patch icons and application context-icon
preference. Shift-F10 opens that native menu at the selected row; ordinary AppKit
arrow/Shift/Command selection and type selection remain native behaviors. Captured
menus bind both their selection and loaded generation. Validation and dispatch
recheck operation/draft/refresh/retirement gates. Dismantling a hidden table retires
its coordinator so an old retained menu cannot apply files.

View → Patch file list and the window's Hide/Show file list button toggle the
panel. This is a per-window view choice, as the source command is; no global
preference is introduced. Hiding a focused list transfers focus to the comparison
and keeps highlighted IDs. The menu remains available to restore the panel.

Review contributes scoped native Open/Reload/Save, applicable Find/patch commands,
View file-list state, Settings and Help through the shared Merge menu owner. It
inherits reconstruction/tracking, key-window epochs and detached/retired refusal.
Unsupported comparison commands and regex submenus are not added. Embedded
comparison controls keep their existing separate presentation and ownership.

[The batch evidence](qa/patch-file-panel-2026-10-16.json) records eight passing
native case/engine runs across seven distinct pairs. This includes both Git
versions for the panel, per-file application and full import/editor/lifecycle/output
ownership, plus the scoped comparison/merge menus. A retained Import fixture now
waits for the actual Go to Line gate before its unchanged enabled/range/byte
assertions. A wrong Help topic and the readiness helper's protocol constraint were
corrected during compilation. All owned receivers were reaped and independently
absent. No Core behavior changed or Core suite reran. Remaining work includes initial failed-hunk/conflict counts,
source hunk/conflict application behavior, complete editor/ribbon commands,
physical keyboard/context-popup/accessibility and width/geometry acceptance,
large-patch performance and signed installed Finder/sandbox/App Store execution.
This is partial source parity, not certification of the full patch family.

Actual AppKit result-list captures are published in
[light appearance](site/assets/file-patches-light.png) and
[dark appearance](site/assets/file-patches-dark.png). They show two patched rows,
a failed row and its diagnostic alongside the original patch. Comparison-view
candidates also confirmed the initial viewport and file icons; they are retained
in local QA. These captures do not prove keyboard popup or full dialog parity.
