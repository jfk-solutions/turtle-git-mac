# Saved Data settings

Open Settings → Saved Data to clear histories or make previously suppressed
questions appear again. The controls follow TortoiseGit's Saved Data page.

- **URL history → Clear** removes Clone URLs, Fetch/Pull URLs, repository-specific
  Push URLs, Request Pull URL history and Format Patch output-directory history.
- **Log messages (Input dialog) → Clear** removes saved Commit message histories
  across repositories. The history backend reloads storage on each access, so an
  existing history object sees the cleared entries and can save new messages.
- **Stored decisions → Clear** forgets remembered answers and suppressed warnings.
  This includes Fetch/Rebase decisions, Stash Pop changes questions, Merge conflict
  hints, Push All Branches confirmation and Commit cancellation/template hints.
- **Action log** has its own line limit, Show and Clear controls. See the
  [Action log guide](ACTION-LOG.md).

Hover over URL or input-message history controls to see the current number of
saved entries and histories. Their Clear buttons are disabled when no matching
saved history exists. Stored decisions can always be cleared, matching upstream.
The controls act immediately; there is no extra confirmation for these groups.

Newly opened dialogs load the cleared histories. An already open dialog can keep
its current text and loaded dropdown choices; clearing saved data does not cancel
an operation or erase the text being edited. Its next submission can save a new
history entry.

These controls target explicit preference keys. They preserve repository bookmarks,
working files, commits, indexes, SSH key-path history, branch/revision histories,
ordinary dialog options, appearance settings and the separately managed action log.
They do not delete private key files or credentials.

## Source and current limits

Adapted from pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseProc/Settings/SetSavedDataPage.cpp/.h` and
`src/Resources/TortoiseProcENG.rc`. The [decision fixture](upstream-saved-decisions.json)
records all 21 source TortoiseGit decision keys and the source merge-editor key,
with the source blob and pin. Native aliases map Commit and Stash choices to their
macOS preference names. Windows registry histories become native preferences.
URL histories include Request Pull's existing native list; its other per-repository
input defaults are preserved.

Remaining Saved Data groups include authentication data, dialog sizes/positions,
Show Log cache, temporary files/Gravatar images and future approved-hook decisions.
Merge input-message history is not implemented yet. The merge-editor reset key is
included for future use, but its corresponding prompt is not implemented. No
completion claim covers those groups or physical/signed UI acceptance.

Core tests check the source catalogue, reset scope, multiple Commit repositories,
false/integer remembered answers and preserved neighboring keys. After a Debug
build, `python3 scripts/test-saved-data.py` checks real native model loading, private
histories, restored Stash Pop questions and a hidden settings host. These headless
checks use isolated preferences and repositories; they do not launch the main app.
