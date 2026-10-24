# Optional libgit2 engine

TurtleGit includes an optional libgit2 engine for checkbox Commit preparation, Add, Clone, Fetch and the Fetch
operations in Synchronization, including Fetch & Rebase and fetching a tag.
It also lists remote references, deletes remote tags/branches, and materializes
historical files when their corresponding source command-mask bits are enabled.
Selected Reset, Log commit reversion, unified patch display and history changed-file
lists also have their own captured source-engine branches.
The normal Clone/Fetch defaults remain Git commands, matching TortoiseGit's
per-command defaults. SVN, ordinary Pull/Merge, Push, Prune and Remote Update
continue through their existing command workflows.

The Advanced **UseLibgit2** preference is the master switch. Like upstream,
`UseLibgit2_mask` is a separate expert preference rather than an additional
Advanced table row. Clone uses bit `0x2`, Fetch uses bit `0x4`; enabling both while
retaining the source default mask means `0x66786` (decimal `419718`). Disabling the
master switch chooses Git commands for these selectable operations regardless of
the mask. Add progress mode post-actions keep their source index-adapter path.
A requested engine
that is missing reports an error; it does not silently change the selected engine.
The backend choice is captured when an operation starts, so editing Settings
cannot change an operation already waiting for a folder, key or credential.

Branch, tag and configured-remote choices, History reference labels and annotated
tag information follow the master **UseLibgit2** switch independently of the
per-command mask. Disabling individual command bits therefore does not force
those metadata lists to Git. Reference Browser retains its separate ForeachRef
choice. Log action columns, path/action filtering, Synchronization action columns
and combined changed-file reads follow LogListDiff bit `0x8000`, using bounded
batches. Accepted reads keep their captured preference store even if Settings
changes while they are pending. These are metadata reads; ordinary Push transport
keeps its existing Git command. See the
[backend metadata source comparison](BACKEND-METADATA-PARITY.md).

Revision resolution and exact branch/tag existence checks also follow the master
switch independently of the command mask. Create Branch/Tag, Switch, Push,
Fetch-to-Rebase and Synchronization retain the backend accepted for their current
operation, including owned continuations and retries. Branch creation and Switch
still require a commit; tags retain their existing target object, including a
tree, blob or annotated tag. Push validates an existing object without changing the
submitted source reference. These checks do not change the transport or mutation
command. Missing selected helpers and invalid helper responses are reported
instead of silently choosing Git. See the
[revision lookup source comparison](REVISION-LOOKUP-PARITY.md) for raw source
resolution, unborn HEAD and exact-name boundaries.

For SHA-1 repositories, Repository Browser's initial object/tree read uses the
helper unconditionally, matching the source's static repository lookup. The
existing macOS SHA-256 Browser extension chooses Git explicitly from the stored
object format; a failed selected helper never triggers that choice. Later comparison marks and file
actions follow the master switch while keeping the displayed object fixed.
Historical submodule Log pinning distinguishes an absent entry from an ordinary
file and a gitlink; disabling the source master flag skips that pin lookup.
Generic addition/deletion comparisons retain valid missing sides. History
reference deletion retains its accepted engine through confirmation and stale
identity checks. See [historical navigation](HISTORICAL-NAVIGATION-PARITY.md) for
the source boundaries and remaining CLI tree-inventory adaptation.

Unified patch display uses Diff bit `0x10`; historical changed-file lists and
history file searches use LogListDiff bit `0x8000`. Both are off in the source
default mask. Selected unified output includes source full statistics and patch
bytes; its context, merge and rename defaults differ from Git command output.
Index-only and editable staging patches keep their existing Git reader. History
lists retain actual merge-parent groups, renamed paths, binary counts and object
metadata; changing engines cannot reuse a cache belonging to the other engine.
See the [diff/history source scope](DIFF-BACKEND-PARITY.md).

Single-commit details use GetCommit bit `0x4000`, enabled by default. Commit
amendment, accepted Log message selection, Rebase reference details and eligible
message/metadata reads, containing-reference details, comparison endpoints and
parent captions use the source-selected reader. Declared encodings apply to
names, email addresses and the full raw message; display subjects split at the
first line feed. Mailmap remains a separate display choice. Working Tree and
explicit tree endpoints retain their own types. Bulk history and hash-only
structural metadata use their existing readers. See
[single-commit source scope](SINGLE-COMMIT-DETAILS-PARITY.md).

Replay and merge readiness use their own source inspection choices. MergeBase
bit `0x80` selects the common-ancestor/fast-forward decision; CheckConflicts bit
`0x2000` selects index conflict presence; GetConflictInfo bit `0x20000` selects
requested stage lookup for Resolve **Mine/Theirs**. These are enabled by default.
Resolve **Current** keeps its existing staging workflow. A conflict already
resolved by another tool is skipped by Mine/Theirs; changed conflict stages still
require a refresh before mutation.

CheckCleanWT bit `0x1000`, disabled by default, selects tracked cleanliness
inspection for replay and SVN readiness. Untracked files alone do not require
stashing; submodules follow the source exclusion policy. Some continuation checks
allow staged changes while requiring a clean working copy. Inspection can refresh
Git's index stat cache; it does not commit or resolve a conflict. Missing requested
runtimes and incomplete inspection output fail explicitly. See
[replay and resolution source scope](REPLAY-INSPECTION-PARITY.md).

The same choices apply to fast-forward history jumps, eligible unmerged-branch
deletion warnings and forward/rewind classification in initialized submodules.
Child inspection retains the accepted helper configuration and Git executable.
Combine Commits uses tracked cleanliness with staged changes disallowed;
untracked files and child dirtiness follow the source exclusions. Preparation
and execution retain the accepted settings, and inspection failures stop the
action before reset or deletion confirmation. See the
[history inspection source scope](HISTORY-INSPECTION-PARITY.md).

Local reference browsing uses ForeachRef bit `0x40000`, enabled in the source
default mask, for the unfiltered catalog. **Only merged** and **Only unmerged**
retain Git commands, matching TortoiseGit. **References commit is on** uses
BranchContains bit `0x10000`, disabled by default. Revision-name completion
follows the master switch directly, independently of ForeachRef's bit.

Local branch/tag deletion uses DeleteTagBranch bit `0x100`, enabled by default.
This includes deleting a local remote-tracking name through a history menu;
deleting a branch on the server still uses the separate remote-deletion route.
A confirmation retains the displayed reference identity and selected engine.
Changing Settings while it is open does not retarget that accepted attempt.
A moved reference or checked-out branch is refused; earlier completed deletions
remain completed if a later item fails. Refresh and inspect the reported result
before retrying. See [local reference source scope](LOCAL-REFERENCE-ENGINE-PARITY.md).

Reset uses bit `0x20` and Log commit reversion uses bit `0x40`, also off by
default. Their accepted attempt captures its engine before work starts. Hard
Reset can recycle originals through checked prewrite notifications, and its
result list retains actual updated paths. Source-library conflict and partial
failure behavior is retained for explicit review/recovery. See
[Reset/revert scope](RESET-REVERT-BACKEND-PARITY.md).

Add uses bit `0x400` (decimal `1024`), already enabled in the source default
mask. Its normal, executable and symlink actions apply the selected engine to the
reviewed paths. The default libgit2 branch uses configured one-shot clean filters;
disabling Add's bit or the master switch uses Git's `add -f` workflow. Both keep
working files intact and publish the prepared index only after successful work.
Progress mode post-actions update existing staged objects through the bundled
index adapter. See the [Add/index source comparison](ADD-INDEX-FILTERS-PARITY.md).

Checkbox Commit preparation uses command 3, bit `0x8`, disabled in the source
default mask. It is independent of Add's bit. If enabled, checked files use
libgit2's configured one-shot clean filters and a private prepared index; Git
creates the commit without re-adding their working bytes. Unchecked-row resets
and optional restoration, executable/link modes, amendment and cancellation stay
owned by the accepted attempt. **Staging support** still commits the index exactly
as staged, including partial files. See the [Commit index comparison](COMMIT-INDEX-ENGINE-PARITY.md).

Remote reference/tag listing uses the Fetch bit `0x4`. Remote-reference deletion
uses the source Push bit `0x800`; enabling it with Clone/Fetch while retaining the
other source defaults gives `0x66f86` (decimal `421766`). Ordinary Push and Sync tag
Push keep their command-line workflow, as in the source; the deletion bit does
not select a general libgit2 Push implementation.

Select Remote Ref, Delete Remote Tags, Browse References remote-branch deletion
and Sync tag compare/delete use the same accepted engine choice through their
owned work. A post-delete refill keeps that choice even if Settings changed while
you answered the deletion question. Invalid or stale selections still fail before
mutation. Remote deletions can complete partly; inspect the reported refs before
retrying, because successful deletions are not rolled back when another ref or
remote rejects its update.

With libgit2 enabled for listing, the branch picker also retains advertised
**HEAD**, matching TortoiseGit's libgit2 branch. Its default Git-command branch
uses `--refs` and excludes HEAD. Listing does not fetch objects or change your
local branches, tags, HEAD, index or FETCH_HEAD.

Both engines use the existing Clone/Fetch forms. Branch, origin, bare/no-checkout,
recursive submodules, shallow depth, fetch destinations, tags, pruning and the
pinned Rebase handoff retain their corresponding operation choices. Progress and
cancellation remain owned by the window that started the operation. Fetch updates
references and FETCH_HEAD; it does not itself merge, switch or overwrite working
files. Follow-up Rebase/Merge remains a separate reviewed action.

The dedicated Clone and Fetch progress windows list reference updates when
their captured backend is libgit2. Each row retains the complete old and new commit IDs and labels the
change as unchanged, new, deleted, forward, rewind or a divergent change ordered
by commit time. **Show Log** on a reference result opens those captured endpoints;
a later update to the reference does not change the selected range.

Clone also lists checked-out files. After the operation stops, file rows offer
history, Open, Open With and Finder reveal. Recursive checkout rows retain their
own submodule repository and relative path. Bare and no-checkout clones have no
checkout-file actions. Sort completed notifications with the Action/Path headers;
context Copy copies selected displayed paths, while Command-C includes the action.
A Retry starts a fresh result list. Notifications already received remain visible
when an operation fails or is cancelled; they do not imply that later work
succeeded. The default command-line backend and Synchronization’s separate transport output
retain their text progress display.

An HTTP authentication challenge opens a native Password dialog with aligned
Username/Password fields. A username supplied by the URL starts focus in Password;
an empty username must be filled before OK can close the dialog.
This is libgit2's own credential callback. Git commands retain their existing
credential-helper/askpass workflow. Password answers from this dialog are not
written to progress output.
The new callback does not save credentials or edit Keychain trust.

When the actual HTTPS connection presents an invalid certificate, **Certificate
verification failed!** shows its hostname, issuer and fingerprints. **Cancel** is
the default. **Open certificate** opens the native read-only inspector with public
DER/PEM export. **Accept certificate** is temporary and exact to the actual host,
port and certificate bytes. The running app remembers accepted certificates across
subsequent libgit2 calls, including a list, delete and refill. Quitting the app
clears that memory. A different authority or certificate needs its own review.
Authentication and Git object transfer wait for the decision.

Cancelling an operation dismisses its owned authentication question. A certificate
export already accepted finishes before the prompt releases its operation lock
and before the transport process group is terminated. A late acceptance cannot
restart a cancelled operation. Merely viewing or exporting a certificate does not
accept it, install it in Keychain or change Git configuration.

SSH transport uses the bundled OpenSSH integration and its existing key/agent and
host-key workflow. See [SSH authentication](SSH-AUTHENTICATION.md) and
[repository folder access](REPOSITORY-FOLDER-ACCESS.md). The
[source and validation record](LIBGIT2-TRANSPORT-PARITY.md) distinguishes implemented
behavior from public-server, signed sandbox and complete upstream acceptance.

The optional engine applies configured one-shot clean commands during Add and
smudge commands during Clone
checkout and historical-file materialization. It does not implement Git
filter-process drivers or ordinary Git hooks. Fetch reads objects/references
without checking out files. Repository template files are copied, but copying a hook
is separate from executing it. Conventional custom `GIT_ASKPASS` programs and
Git credential helpers are not consumed by this engine; use its native prompt or
the default Git engine for those workflows. URL-specific HTTP headers, proxy and
CA settings are resolved for the actual request URL, including redirects.

Certificate review shows the actual validation diagnostic and a readable issuer.
Temporary decisions are shared through private operation-owned exchanges and
retained only in the app process. No permanent trust setting is changed. See the
[shared authentication comparison](REMOTE-AUTHENTICATION-PARITY.md).

## Opening and exporting historical files

Historical Open, Open With, Alternative Editor, Save As and file/folder transfer
use the GetOneFile setting, bit `0x200` (decimal `512`). This bit is already enabled
in the source default mask `0x66780`. These actions pin the selected revision and
materialize the file without checking it out or changing the index.

With this backend enabled, libgit2 applies its checkout-side CRLF/ident filters
and configured `filter.<driver>.smudge` commands. The file's literal repository
path is substituted for `%f`; `%%` supplies a literal percent. A required smudge
failure reports an error and preserves the existing destination. An optional
filter failure passes through the preceding filter output, as in TortoiseGit's
custom filter. The selected engine and output ownership remain captured through
native panels, file promises and cancellation.

Disabling GetOneFile or the master switch selects the source's raw Git-command
file read. The standalone Cat command retains its separate source command rules;
its disabled-backend blob route returns raw bytes, while its nonblob route
uses Git show for the selected path, including commit/patch output. See the
[historical materialization comparison](HISTORICAL-MATERIALIZATION-PARITY.md). Blame, raw comparison baselines and raw patch
export use their existing independent readers.

These smudge commands are configured by the repository/user. They execute with
the captured Git environment and own their subprocesses until completion or
cancellation. This does not imply support for Git's persistent filter-process
protocol or working-tree-encoding conversion in libgit2. Persistent filter-process and
ordinary Git hooks remain outside this source adapter. ZIP Export continues to use
Git archive and its archive attributes.

## Clone checkout and configured LFS filters

When the Clone bit `0x2` is enabled, checkout applies libgit2 built-in filters and
configured `filter.<driver>.smudge` commands. Recursive Clone does the same in
each initialized submodule's checkout. Each command runs in that repository's
working directory, with the original selected Git environment and executable
search paths, so repository-relative tools and configured `git-lfs smudge` can
find their repository. The source default mask keeps ordinary Clone on Git.

Bare and No Checkout create no worktree file outputs and do not run these smudge
commands. A required filter failure during the initial clone follows libgit2's
destination cleanup: a new target is removed, while an originally empty target
folder is retained empty. A later submodule failure preserves the already cloned
superproject and completed child work. Progress reports the failure; inspect the
retained destination before retrying. Cancel waits for the actual owned filter
process group before allowing the helper and native progress to finish.

Configured Git LFS support uses its one-shot smudge command. It does not install
LFS settings or replace a configured external toolchain. The persistent
`filter.process` protocol, arbitrary LFS server/authentication combinations and
signed sandbox execution remain separate acceptance work. See the
[Clone filter source comparison](CLONE-CHECKOUT-FILTERS-PARITY.md).

## Git notes storage

Edit Notes follows the source's unconditional libgit2 route for SHA-1
repositories, independently of **UseLibgit2** and the command mask. It uses the
configured notes default and one configured user signature for author and
committer. Accepted edits retain their literal ref and revision through Settings,
retry and cancellation. Readback returns the captured note, with explicit saved
and uncertain-outcome handling. The existing SHA-256 Git extension is elected
from the repository format; helper failures do not cause a fallback. See
[Notes backend parity](NOTES-BACKEND-PARITY.md) for exact ref/signature rules,
bounds and remaining acceptance.
