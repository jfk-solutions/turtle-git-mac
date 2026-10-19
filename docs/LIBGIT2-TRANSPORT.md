# Optional libgit2 transport

TurtleGit includes an optional libgit2 engine for Clone, Fetch and the Fetch
operations in Synchronization, including Fetch & Rebase and fetching a tag.
It also lists remote references, deletes remote tags/branches, and materializes
historical files when their corresponding source command-mask bits are enabled.
The normal Clone/Fetch defaults remain Git commands, matching TortoiseGit's
per-command defaults. SVN, ordinary Pull/Merge, Push, Prune and Remote Update
continue through their existing command workflows.

The Advanced **UseLibgit2** preference is the master switch. Like upstream,
`UseLibgit2_mask` is a separate expert preference rather than an additional
Advanced table row. Clone uses bit `0x2`, Fetch uses bit `0x4`; enabling both while
retaining the source default mask means `0x66786` (decimal `419718`). Disabling the
master switch chooses Git commands regardless of the mask. A requested engine
that is missing reports an error; it does not silently change the selected engine.
The backend choice is captured when an operation starts, so editing Settings
cannot change an operation already waiting for a folder, key or credential.

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

An HTTP authentication challenge opens a native combined Username/Password dialog.
This is libgit2's own credential callback. Git commands retain their existing
credential-helper/askpass workflow. Password answers from this dialog are not
written to progress output.
The new callback does not save credentials or edit Keychain trust.

When the actual HTTPS connection presents an invalid certificate, **Certificate
verification failed!** shows its hostname, issuer and fingerprints. **Cancel** is
the default. **Open certificate** opens the native read-only inspector with public
DER/PEM export. **Accept certificate** is temporary and exact to the actual host,
port and certificate bytes in this operation; redirects to another authority
cannot inherit it. Authentication and Git object transfer wait for the decision.

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

Clone and Fetch in the optional engine do not currently run external Git
filter/LFS process drivers or ordinary Git hooks. Historical-file materialization
has a separate source-compatible smudge path described below. Repository template files are copied, but copying a hook
is separate from executing it. Conventional custom `GIT_ASKPASS` programs and
Git credential helpers are not consumed by this engine; use its native prompt or
the default Git engine for those workflows. URL-specific HTTP headers, proxy and
CA settings are resolved for the actual request URL, including redirects.

Each separate list, delete and refill currently establishes its own helper
connection. An accepted invalid certificate is temporary within that call; it
is not yet shared across the dialog's later calls. The original Windows process
keeps a certificate cache across calls. This remaining usability difference is
recorded with the [remote-reference source comparison](REMOTE-REFERENCE-ENGINE-PARITY.md).

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
protocol or working-tree-encoding conversion in libgit2. Clone/Fetch filter and
hook behavior remains the separate limitation above. ZIP Export continues to use
Git archive and its archive attributes.
