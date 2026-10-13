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

Synchronization and embedded Rebase retain their existing workflow hosts, but
share InputMessageTextView and the same log-font/keyboard policy. Their complete
host consolidation and project-settings propagation remain open. This resource
is partially replaced, not certified complete. The grouped receiver includes
new Input checks and existing branch-description assertions through the common
compilation cache; no timed/full-suite repetition is required for this batch.

Four backend tests and four grouped native cases passed across both Git engines.
See the [scoped evidence](qa/input-dialogs-2026-10-13.json).
