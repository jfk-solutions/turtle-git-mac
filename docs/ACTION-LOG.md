# Saved progress action log

Settings → Saved Data contains TortoiseGit's **Action log** group: **Max. lines
in action log**, **Show**, and **Clear**. The default is 4000 lines. Entering 0
disables new records and leaves the existing log available for Show or Clear.
Show opens the UTF-8 log in the system text viewer. Clear deletes this log only.

The following native progress windows save their displayed output when closed:
Clone, Commit, Push, Fetch, Pull, Merge, Abort Merge, Switch, Reset, Clean,
Export, and Format Patch. Each entry starts with an empty separator line, the
local date and time, and the repository path (Clone uses its destination).
Cancelled results append **User cancelled**. Quiet operations still save the
header. The stored text follows the visible output limit, rather than the full
raw output used internally to classify Git failures.

Retry and repeated operations save the previous result before replacing it.
Format Patch saves when its progress result returns to the options page or
hands off to Mail. Clean preserves the preview before performing deletion.
Logging failures do not change the Git result or block its recovery actions.

The line limit removes the oldest lines first. Like TortoiseGit, it always keeps
the whole newest operation, even when that operation alone exceeds the limit.
The app stores the log locally at `TurtleGit/logfile.txt` in its Application
Support directory; sandboxed builds use their private container. Log files use
owner-only permissions, and concurrent writers are serialized. This log can
contain displayed Git/hook output, paths and remote addresses. It is not
uploaded by TurtleGit.

## Source and verification

Compared against pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`:
`src/TortoiseProc/LogFile.cpp/.h`, `ProgressDlg.cpp::WriteLog`,
`Settings/SetSavedDataPage.cpp/.h`, and the Action log group in `Resources/TortoiseProcENG.rc`.
Native storage, UTF-8 encoding, atomic replacement and file locking replace
Windows local-app-data, MFC text files and sharing flags. Preferences save valid
values immediately, following the macOS Settings convention.

Core tests exercise source line splitting, Unicode, cancellation, permissions,
retention, concurrent writers, disabling and clearing. The headless native
receiver uses private temporary storage, real Git Reset results, actual hidden
window controllers, Retry, quiet output, settings validation, Show/Clear
callbacks and write-failure isolation. Run `swift test --filter ActionLogTests`
and, after a Debug build, `python3 scripts/test-action-log.py`.

This is partial Saved Data parity: other saved-data groups remain to be ported.
Other progress implementations, including replay and reference restoration,
have not yet been wired to this persistent log. Physical Show/text-viewer UI,
signed sandbox persistence and App Store distribution remain unverified.
