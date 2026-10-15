# Finder LFS and Send Mail — implementation in progress

Source: MenuInfo.cpp, ContextMenu.cpp's InsertLFSSubmenu, TGitPath::HasLFS,
LFSCommands.cpp/LFSSetLockedProgressCommand.cpp, SendMailCommand.cpp,
SendMailDlg.cpp and AppUtils::SendPatchMail at
7338078f8ddd924b8cddee35f512f2286072136d.

Finder now offers the original nested LFS group: Show locked files for a single
versioned folder, and Lock/Unlock for versioned file selections. The outer group
and inner clauses are separate, in source order. Original LFS/list/lock/unlock
artwork is retained. All children share the LFS preference ID, so first-level
placement, Shift-only visibility, path exclusions and icon suppression move or
hide the entire group with its nested commands. A group header is not a URL
command. The existing source order/condition oracles include these clauses and
record the separate ContextMenu.cpp blob used for the three inner conditions.

The containing app caches hasLFS metadata from the common Git administration
directory's local LFS marker, including linked worktrees. Finder does not run
Git or query lock ownership to build menus. Old cache JSON defaults the new flag
to false until refreshed. Opening the Locks dialog retains its existing remote
ownership query and UI. Lock/Unlock revalidate LFS configuration and literal
versioned non-directory paths before remote operations. Index files and HEAD
files are accepted, retaining staged-deletion eligibility. An invalid target
rejects the whole preflight before any remote command; newline/Unicode paths and
argument-like spellings remain literal.

Finder file operations use the existing per-file result, cancellation, Force
retry, successful-lock Pull handoff and Quit guards. LFSFileOperationController
can now own standalone progress when a containing window is not yet available,
while ordinary Commit/Working Tree calls keep owned sheets. A controller starts
once and closes once; failed presentation is not retained. The repository model
retains operations through result review and refreshes appropriate owner dialogs
on closure. The pinned bundled Git LFS runtime already exists in the Git helper
bundle; this batch does not change its version or provenance.

Send Mail uses the source patch-file/extended-file clauses, even outside a Git
repository. It captures the Finder file URLs, uses the native checked/highlighted
options dialog and existing mail-client/SMTP progress workflows, and never submits
mail merely by opening the command. Source files are retained on cancellation.
The app's active checkout is not changed. A known first-file repository supplies
local sender configuration; file and root permissions are required in the signed
sandbox. Existing repository grants are reused, with a native files/folders
chooser when needed. Desktop can discover the first file's actual repository;
sandboxed discovery occurs only under an authorized containing folder. An actual
sender root outside those grants is rejected rather than silently borrowed.

Outside a repository, an exclusive 0700 application-owned directory supplies
Git's global sender configuration. It is represented by ApplicationMailContext,
not a fabricated security-scoped bookmark. Delivery accepts that context only
for its exact owned directory/device/inode. A substituted directory is rejected,
and teardown refuses to remove the replacement. The workflow/progress retains
the context through sender resolution and result review; external source files
still require their ordinary preparation grants. Global configuration/Keychain/
mail-client permissions keep their existing separate gates.

The unified patch viewer remains available from outside-repository mail. Review
and Apply open an owned target-repository chooser instead of treating the global
sender directory as a working tree. The selected root is discovered/revalidated,
its grant retained and late replies fenced after owner closure. Existing in-
repository mail uses its captured target directly. Pure non-Git directory patch
review/application and the standalone Finder Review Patch group remain part of
the unfinished broader patch-review port.

Grouped validation: the final incremental Debug arm64 build exited 0. 65 focused
Core tests passed, zero failures, in 7.251 seconds, including all 58 pinned
conditions, old/cache/linked-worktree metadata, literal versioned target preflight,
invalid/cancellation paths, HEAD/index preservation and existing mail/menu checks.
The actual Finder builder exited 0, matching all 55 projected root entries and
new nested LFS/mail conditions. The combined actual native LFS/mail receiver
exited 0: standalone lifetime, injected LFS outcomes, outside-repository Finder
composer/Cancel, owned sender identity/replacement/cleanup and the prior native
mail/viewer/review/apply fixtures passed. Its sole real delivery was to a private
loopback SMTP fixture, with separate MIME verification. No installed app or
Finder extension was launched. Final incremental build diagnostics were empty;
receiver compilation retains existing warnings, so this is not a clean full-build
claim. See qa/finder-lfs-mail-batch-2026-10-12.json.
The new native runner uses whole-module Onone compilation and an executable
cache keyed by source/framework/toolchain; both receivers share one compilation.
It runs both existing LFS
and mail receivers in one process. LFS responses are injected; mail uses only a
private loopback SMTP server with independent MIME decoding. Native Finder,
permission/target chooser gestures, actual external LFS locking, mail-client
Apple Events and signed App Store execution remain separate acceptance. The
catalog has 49 available groups and six unavailable groups: four SVN commands,
Daemon and Review Patch. This is not full application or dialog certification.


The six-unavailable-group count above is historical. The current catalog has
routes for all 55 groups; see [current handoff coverage](FINDER-COMMAND-HANDOFF-PARITY.md).
This does not establish complete command behavior or activated/signed Finder parity.
