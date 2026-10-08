# Import Patch port

The import engine is implemented; the native Import Patch dialog and its menu
entry remain pending. This page is a port audit, not instructions for a completed
user-facing command.

Pinned source: `7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseProc/ImportPatchDlg.cpp/.h`.

## Engine

`GitRepository.importMailPatch` invokes Git's mail-patch importer with literal
argument arrays and an explicit `--` before the file path. The source defaults
are preserved: Three-way, Ignore space change and Keep CR enabled; Sign-off
disabled. Git retains mail author/date/message metadata and creates commits.
An active import prevents starting a second one. Git failures retain recovery
state rather than automatically discarding it.

The worktree-specific Git paths distinguish an `am` session from either rebase
backend. Abort, Skip and Resolved run the exact source `git am` recovery commands
only for mail application; they cannot accidentally abort a rebase. Linked
worktrees have independent session state. The API accepts existing readable
local files, supports streamed Git output and cancellation, and rejects invalid
files or pre-cancelled requests before invoking the importer.

## Verification

`python3 scripts/test-mail-patch.py` runs five real-Git cases. The four-engine
record is [mail-patch QA](qa/mail-patch-2026-10-08.json). Cases cover Unicode
mail paths with a leading dash, author/date/body/sign-off preservation, real
conflicts followed by Abort/Skip/Resolved, rejection during an actual apply-backend
rebase with exact HEAD/index preservation, linked-worktree isolation, invalid
file/non-file URL and cancellation before mutation.

## Native dialog still required

The source dialog needs checked and ordered patch rows, Add/Remove/Up/Down and
patch-list context commands, checkbox enablement, patch preview and log tabs,
per-row Applying/Success/Failure/Skipped state, retained cursor/retry, batch stop
after the current Git command, active-session recovery and close confirmation.
The source's options remain fixed for an active batch. Native file access must
retain security scope or app-owned snapshots for sandboxed Git. Identity checks,
window/splitter persistence, progress output/action logs, source icons, keyboard,
light/dark appearance and physical/signed acceptance remain pending. No screenshot
or App Store readiness claim covers this engine-only checkpoint.
