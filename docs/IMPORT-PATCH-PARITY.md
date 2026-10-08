# Import Patch port

The native **Apply Patch Serial…** command imports mail patches using `git am`.
Open it from the Repository menu or sidebar, or the TurtleGit Finder menu in a
known working tree. Add patch files, check the ones to import, order them with
Up/Down, review the Patch tab, and choose Apply. This is a partial native port;
the remaining parity work is listed below.

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

## Native dialog

Checked paths, Add/Remove/Up/Down, the four source option defaults, Patch/Log tabs,
and per-row Applying/Success/Failed/Skipped state are implemented. Stable row IDs
preserve checks, selection and results while reordering. Options and input rows
are fixed for the active batch, with model guards as well as disabled controls.
A successful row is not re-imported when continuing after a failure. A skipped
row can be checked again to make it eligible for a later attempt.

On a failed import, resolve and stage conflicts before choosing Apply again;
the recovery prompt offers **Abort / Skip / Resolved / Cancel**. Abort restores
the failed row for retry; Skip/Resolved mark it only when Git finishes that
session. Additional failures retain recovery state. For a pre-existing external
session, recovery does not incorrectly mark the first newly added patch done.
An active rebase is refused. Git committer identity is checked before importing.

**Abort** while a batch runs stops after the current Git command; it does not
kill that command or close the window. Idle Cancel/window-close checks the Git
session and offers Abort, Keep session or Cancel. Failed aborts keep the window
open. Quitting is refused during an operation or attached sheet. Patch-file
security-scope leases and repository access remain retained by the model.

The command uses the original patch icon in the app and Finder. Finder command
ordering and the pinned folder/patch-file conditions are mapped; selected `.patch`
and `.diff` files in a known working tree prefill the dialog. Finder's existing
repository authorization still applies. File selections outside known working
trees and the source's repository chooser remain pending. Geometry uses the
source `ImportDlg` identity. Log text uses the shared log font; Git output is
buffered until each command returns, matching this source dialog's workflow.

`python3 scripts/test-import-patch.py` checks the real native table and preview,
row movement/checks, fixed batch input/options, two real mail commits and sign-off,
retained conflict cursor and all recovery choices, Cancel/Keep/Abort close choices,
and a slow real Git hook proving that batch stop completes the current command.
The [native QA record](qa/import-patch-native-2026-10-08.json) records four Git engines.
Finder checks cover menu order, conditions, icons and routing metadata; they do
not prove a deployed Finder extension.

## Remaining parity work

Patch-list context commands, drag/drop, the source's splitter persistence,
unified-diff preview highlighting, identity configuration prompts and idle-session
application-quit prompts remain pending. Physical keyboard/accessibility,
light/dark visual comparison, signed sandbox access for files outside the repository,
deployed Finder integration and App Store acceptance are unverified. No screenshot
or release-readiness claim covers these hidden native checks.
