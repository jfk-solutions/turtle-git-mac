# Diff tools and associations — implementation in progress

Reference: pinned SettingsProgsDiff, SetProgsAdvDlg, ToolAssocDlg and
AppUtils::PickDiffTool/StartExtDiff at
`7338078f8ddd924b8cddee35f512f2286072136d`.

The native Diff Viewer page groups the two-file diff program and existing GNU
patch viewer controls, with Merge Editor as its child. Unified Diff's separate
page now holds appearance settings; the viewer draft has one owner. The two-file
program has internal/external selection, a saved application, arguments, Browse
and Advanced. Advanced has Extension/Program columns, Add/Edit/Remove, nested
association editing and separate OK/Cancel drafts. Parent Apply persists the
associations; dismissing Advanced leaves the parent draft unchanged. Extension
keys trim leading asterisks and compare without case, accepting filenames too.
Duplicate normalized keys and invalid enabled programs prevent Apply.

Selection follows destination filename → base filename → destination extension.
An explicit disabled association selects the internal tool. Default image
extensions retain the image viewer before the general text program. Shift
inverts enabled/disabled external programs; a disabled saved application remains
available. Image Shift's source switch between IDiff and Merge still needs exact
comparison; this implementation preserves the native image path when there is
no explicit association.

A macOS .app plus an argument template replaces the Windows executable command.
The source placeholders `%base`, `%mine`, `%bname`, `%yname`, `%bpath`, `%ypath`,
`%brev`, `%yrev`, `%wtroot` are supported. Absent both file placeholders, the two
file arguments are appended. Quote/escape parsing happens before single-pass
substitution, keeping paths with spaces or placeholder-looking text intact. No
shell interprets the template. NSWorkspace launches a new tool instance with
arguments, because an existing app instance may ignore launch arguments.

The shared comparison window routes its first read through the selected program,
covering callers that use FileComparisonWindowController (including revision,
working-file and change-set comparisons). Successful external opening closes the
internal window after its load becomes idle. Closing fences late routing and
callbacks. Other specialized comparison helpers still require the source audit;
this is not a claim that every application compare command uses this route.

Regular working-tree files use their original URLs and retained folder grants,
so supported external tools may edit them. Historical, empty and symlink contents
are copied byte-for-byte into private read-only files. Copies persist until app
termination; failed launches delete their copies. Selected app bookmarks are
resolved without UI and retained through launch. AppStore builds require the
selected application and working-file security scopes. Active launch requests
block app termination; termination removes retained comparison copies. Browse
panels for both diff programs and unified viewers belong to their hosting window
and are canceled when their form disappears.

This entire continuation is **uncompiled and untested**. Meaningful argument/
selection/persistence checks, native association/table/sheet/keyboard acceptance,
actual receiving-app arguments, regular working-file edits, source image and
helper boundaries, failures/close races, retained copies, signed AppStore grants,
and light/dark screenshots remain in the grouped section validation. Older
Unified Diff QA covers its earlier viewer implementation, not these additions.
External merge-program associations and source Merge tool configuration are
still pending; existing Merge Editor controls cover built-in editor preferences.
Inventory counts remain unchanged; no dialog is newly certified.
