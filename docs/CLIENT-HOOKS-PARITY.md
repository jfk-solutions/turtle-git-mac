# Client Hook Scripts — implementation in progress

Source: Utils/Hooks.cpp/.h, ProjectProperties::FetchHookString,
Settings/SetHooks.cpp, SetHooksAdv.cpp and the two Hook Scripts resources at the
pinned revision in PORTING.md. GPL-2.0-or-later.

The Core layer now represents all six client hook types, the five-line global
format, shared `hook.<type>.cmdline/wait/show` values and source nearest-path
selection (global then local at each ancestor, wildcard last). Local approval is
bound to repository/type/exact command and must remain in per-user storage.
Saving local hooks updates the eighteen recognized `.tgitconfig` keys and
preserves unrelated configuration/includes. It rejects bare repository saving.
Writes use Git's individual configuration locks, not a cross-key transaction.

Owned invocation plans create private UTF-8 path/message/error files and retain
them through execution/readback. Commit hooks receive path file, message file and
working tree; post-commit receives working tree/amend flag; Push receives error
file/working tree; Rebase receives upstream/branch/error file/working tree.
Success reads back the mutable UTF-8 message; failure retains the original.
Newline-containing path-list entries are explicitly unsupported by this source
file protocol and must be reported by the caller.

The execution API launches a literal POSIX command line in the working tree and
owns its process group. `%root%` is substituted within parsed arguments, preserving
roots containing spaces/quotes. Explicit `/bin/sh -c` is supported through normal
arguments; Windows commands need macOS equivalents. Launch acknowledgment and
completion are separate so the caller can implement the source non-wait option
while retaining cleanup/cancellation ownership. Output is file-backed and display
is capped at one MiB per stream. Child processes are stopped when execution is
cancelled or its leader exits. The source show/hide setting will control native
output presentation; it cannot control arbitrary script-created GUI windows.

The native Hook Scripts list/configuration dialogs, shared Apply/Cancel, per-user
approval decisions and Commit/Push/Rebase hook boundaries are now connected.
Enabling/disabling a local hook stores a per-user decision; it does not add a
non-upstream `enabled` key to the shared repository. Enabling a previously denied
hook clears denial so execution asks again. Changing its exact command also
requires a fresh decision. Global hooks are pre-approved, as in source.

Non-waiting scripts are retained by a shared owned pool; File → Cancel Running
Hook Scripts provides cancellation, and Quit waits for completion. Visible hook
progress windows close on completion. Show/Hide does not govern script-created
GUI windows. Pre-operation failures offer Abort/Continue; successful Git
operations remain successful when a post-hook fails, with a retained error.
Post-push also runs after failed non-cancelled transport attempts. Pre-rebase is
connected to native Rebase Start, excluding Cherry-pick, with upstream and branch.

App Store builds require the captured repository grant. Script Browse remembers
a security-scoped executable bookmark; execution retains scopes for literal
external file arguments that have matching bookmarks. Complex shell expressions
remain constrained by the sandbox, and signed execution acceptance is pending.

Remaining acceptance: exact Start-hook abort behavior, launch/preparation failure
Continue choices, post-action choices and the post-commit flag against the pinned
caller's `amend.IsEmpty()` expression,
source placement relative to Rebase autostash, Merge-created commits and alternate
replay/Sync pathways, comprehensive success/failure and cancellation combinations,
script-created UI and output presentation, stale/script folder grants, screenshots,
physical keyboard/VoiceOver and signed deployment. This family remains partial.

Passing `ClientHooksTests` cover format and selection, approval identity changes,
literal quoting, all payload layouts, private file modes, message readback and
cleanup, configuration retention/removal and cancellation, real cwd/output/message
mutation and owned leader reaping. The grouped native receiver covers shared
settings drafts and owned child dialogs, per-user decisions and late approval,
actual Commit/Push/Rebase boundaries, post-commit failure with preserved Git
success, non-wait ownership, Cancel All and Quit accounting. Results are recorded
only after the checks have run.


The first native attempt exposed completed-execution disposal cancelling the
caller's token. Execution now marks completion before publishing its result;
disposal and Cancel ignore completed executions. The Core check explicitly
asserts the successful caller token survives disposal. Final focused results and
initial failures are recorded in `qa/client-hooks-native-2026-10-12.json`.
