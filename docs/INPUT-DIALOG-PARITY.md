# Shared Input dialog

Pinned source: `7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseProc/InputDlg.cpp`, `AppUtils.cpp::EditNote`,
`BrowseRefsDlg.cpp` and `IDD_INPUTDLG` in `TortoiseProcENG.rc`.

Branch descriptions and the standalone Log note action now use the same native
InputWindowController. The source order is hint, multiline editor, optional
checkbox, OK/Cancel. Both current callers hide the checkbox; the reusable form
preserves its label, initial state and accepted state. The source log font and
InputDlg saved geometry are shared. Initial content has a clean undo buffer,
focus and an end caret. Plain Return inserts a line; Ctrl+Return accepts, with
Command+Return as the native equivalent. Empty descriptions are accepted; notes
use the captured project's UTF-16 minimum length. NUL text is rejected.

The editor inherits the shared project-language, spelling and log-width
presentation. Automatic quote, dash and replacement substitutions are disabled.
Log reads effective project settings before presenting its child. The branch
caller retains its existing default project settings. Complete SciEdit issue
styling/completion, source checkbox callers and physical/accessibility acceptance
remain open.

Log owns a native sheet and captures the note's revision and notes ref. Changing
selection after opening does not redirect the save. The backend preserves exact
UTF-8 note bytes and leaves HEAD/index/worktree unchanged. Errors retain the
editable draft; success ends the sheet explicitly before releasing parent state.
Cancel does not write. Saves disable input and dismissal until settlement.
Forced closure cancels the form token and fences presentation; already authorized
Git notes writes remain noninterruptible and counted until completion. Quit
checks the shared count even after a window closes. Retired Log models do not
update displayed notes or emit revision callbacks.

Synchronization now uses InputWindowController directly. Rebase and Log use
the same CommitNotePresenter for an owned Input sheet. All three note callers
load effective project language, width marker and minimum-length settings before
enabling their form. Legacy model save entry points synchronously capture and
gate the accepted draft before scheduling work. The former SwiftUI notes hosts
and their separate editor adapters have been removed. This resource
is partially replaced, not certified complete. The grouped receiver includes
new Input checks and existing branch-description assertions through the common
compilation cache; no timed/full-suite repetition is required for this batch.

Four backend tests and four grouped native cases passed across both Git engines.
See the [scoped evidence](qa/input-dialogs-2026-10-13.json).


## Connected host consolidation — 2026-10-13

The shared form now lives in `Sources/TurtleGitMac/InputWindow.swift`, with one
owned note presenter for Log and Rebase. Synchronization's captured revision
window inherits the same form and saved InputDlg geometry. Loading disables the
editor/OK, failures retain an explicit error state, and Cancel closes without
saving. The reusable checkbox remains hidden for these source note callers.

Rebase blocks its revision context actions while a note is open and invalidates
its revision model on retirement. Pending read cancellation is propagated; late
results cannot reopen a sheet or populate a closed form. Note readers and saves
remain globally counted until completion, including after forced closure, so
Quit cannot leave owned work running. Save callbacks observe settled busy state.
Core notes writes remain noninterruptible once authorized.

Full SciEdit completion/issue styling, physical keyboard/accessibility/layout,
and signed access acceptance remain open. Branch descriptions intentionally use
the source non-project route, as clarified in the shared styling family below.

The consolidation passed the Debug build and six grouped native cases across
system and bundled Git. Core was unchanged and was not retested. See the
[host acceptance record](qa/input-hosts-2026-10-13.json).

## Shared source-style presentation — October 15, 2026

The [shared message styling family](SHARED-MESSAGE-STYLES.md) connects issue/URL
hotspots and source text formatting to the native Input, Notes, Merge and Rebase
editors, with owning font/style preferences, IME protection and owned cancellation.
Descriptions keep the source non-project route. Earlier missing issue-styling
statements above are superseded only for this implemented scope; full physical,
Scintilla and signed acceptance remain open. See its dated evidence.
