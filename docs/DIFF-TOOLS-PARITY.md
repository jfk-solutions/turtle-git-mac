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

The implementation checkpoint was uncompiled and untested. The later grouped
validation below supersedes compilation and the focused argument/selection/
persistence checks only. Native association/table/sheet/keyboard acceptance,
actual receiving-app arguments, regular working-file edits, source image and
helper boundaries, failures/close races, retained copies, signed AppStore grants,
and light/dark screenshots remain in the grouped section validation. Older
Unified Diff QA covers its earlier viewer implementation, not these additions.
The external merge continuation below adds source Merge tool configuration;
existing Merge Editor controls cover built-in editor preferences.
Inventory counts remain unchanged; no dialog is newly certified.

## External merge continuation

Merge Tool is now a child of Diff Viewer and has internal/external program,
arguments, Browse, Advanced associations, Block while merging and a displayed
Trust exit-code control. Matching follows the source's `.` + filename key before
extension keys. Argument fallback adds base/theirs/mine/merged only when none of
those placeholders is present. Shared Apply/Cancel handles its draft.

The main conflict-editor dispatch now checks the external selection before
opening the image/text editor. Delete/modify and submodule conflicts retain their
specialized workflows. Exact stage bytes are copied into read-only inputs;
Mine/Theirs swap for rebase as in the source. The merged output is the working
file. Conflict stages are validated before and after input reads. No source blob
is decoded and rewritten just to launch an external tool. App bookmarks and
repository grants remain alive through launch/wait.

Nonblocking mode returns after launch and leaves resolution to the user.
Blocking mode observes the launched app's termination, then asks an owned visible
caller window whether to mark the file resolved. Resolve revalidates the original
conflict stages. If that window has closed or has another sheet, no resolution is
performed. Temporary inputs stay until application termination; active waits and
launches block quitting. Successful external dispatch refreshes repository panes.

NSWorkspace app launches do not expose a process exit status. Trust exit-code
selection is unavailable for .app programs; an existing enabled value may be
cleared in Settings and produces an explicit launch error until cleared. This
source mode still requires an implementation for a compatible command-line tool;
it is not certified or silently treated as successful. Other direct conflict
helper launch paths, wait cancellation, tool process failures, stale app bookmark
renewal, exact source filename-key usability and signed sandbox receiving-app
behavior remain open.

A grouped Debug build has been started for the accumulated Dialogs/Colors/Tools
section. Its result and focused behavior tests will be recorded separately;
this document does not claim a passing build or native acceptance yet.


## Grouped validation result

The accumulated Debug Xcode build and Swift package build pass after fixing
continuation type inference and the current SDK's typed CoreFoundation locale
identifier bridge. Four tool tests pass with zero failures (0.773 seconds).
They verify selection/Shift/image precedence, literal argument parsing and
single-pass substitution, fallback file arguments, persistence/duplicate keys,
merge filename precedence, and real-Git exact stage bytes without index or
working-file mutation. See `docs/qa/settings-dialogs-tools-batch-2026-10-11.json`.
No application instances were launched. This evidence does not validate actual
receiving-app behavior, native sheets/layout, blocking mode or signed sandbox
permissions. Those checks and source exit-code trust remain open.


## Native association and parent Settings batch — 2026-10-12

Compared SetProgsAdvDlg's sorted columns, Add/Edit, double-click handler and
selection after Remove with the native controls. Advanced now uses an AppKit
NSTableView with single selection and the same next-row/previous-last-row removal
rule. Program cells include arguments and a full tooltip. Double-click routes
the clicked row to Edit; empty-area clicks do nothing. Editing keeps a separate
draft; Cancel preserves the list. Accepted extensions normalize and retain their
identity/selection when sorting moves the row. Duplicate/invalid entries cannot
replace another association. Merge Add uses the four merge file placeholders.
Parent Diff/Merge pages use a shared observable draft model with private-domain
injection, validation, Apply and Cancel; failed persistence retains the draft.

Debug Xcode build exited 0. One object-linked native receiver compilation/process
passed and was reaped. The receiver checked sorted native columns, row selection,
double-action wiring and argument display; model Add/Edit/Cancel/duplicate
refusal, next/previous Remove selection and merge Add defaults; both parent pages
registered with SettingsTransaction and persisted to a private UserDefaults
domain on Apply; validation failure and Cancel restored the saved draft; injected
persistence failure retained pending edits. Aqua/Dark Aqua hosts were constructed.
No receiving application launched, no signed grant was exercised, and no new
screenshot or physical double-click/sheet acceptance is claimed. Core selection/
argument/stage APIs were unchanged; their recorded four-test checkpoint was not
rerun. The full twelve-family receiver group was not rerun.

The Windows Restore Defaults button calls SetupDiffScripts for installed COM
document tools. Its macOS script/tool equivalents are not implemented, so this
control remains open; clearing all associations would not reproduce it. Actual
tool argument delivery/working-file edits, wait cancellation and exit status,
bookmark renewal, image Shift parity, owned native sheets and App Store sandbox
acceptance also remain open. Advanced, association editor and Merge Tool inventory
resources are now partial-native-replacement; no dialog is certified complete.
