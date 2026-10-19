# Remote-reference engine workflow

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d` and its
libgit2 gitlink `f7164261c9bc0a7e0ebf767c584e5192810a8b24` (1.9.4).
This is a partial workflow-family port record, not complete app certification.

## Source and connected consumers

Related source resources are `src/Resources/TortoiseProcENG.rc` /
`IDD_SELECTREMOTEREF`, `IDD_DELETEREMOTETAG`, `IDD_BROWSE_REFS`, `IDD_SYNC` and
`IDD_SETTINGS_CONFIG`. Their menu/control mappings remain partial; this family
connects their existing native actions to the selected engine.

`CGit::GetRemoteRefs` (`Git.cpp`, around 1984–2080) uses command index2/Fetch
(bit `0x4`) for direct remote connect/ls with credential and certificate callbacks.
`SelectRemoteRefDlg.cpp` calls it for branches and `DeleteRemoteTagDlg.cpp` for
tags. The libgit2 branch retains advertised HEAD when branches are included;
the source CLI branch uses `ls-remote --refs` and excludes it. Tag queries include
advertised peeled records; their native consumer decides which rows to show.

`CGit::DeleteRemoteRefs` (`Git.cpp`, around 2089–2142) uses command index11/Push
(bit `0x800`) for direct `git_remote_push` deletion refspecs. BrowseRefsDlg remote
branch deletion and DeleteRemoteTagDlg use that method. The ordinary Push dialog
and Sync tag Push use their existing CLI construction, rather than this method.

Native `RemoteReferenceChoices`, `RemoteTags`, `ReferenceBrowser` and Sync tag
catalog/deletion now select the actual pinned helper at their source gates.
Missing requested runtimes fail explicitly. Default masks and ordinary CLI
behavior remain unchanged. Backend choices are captured before asynchronous
preparation/confirmation; the originating private/production preferences flow
through native picker/tag/browser/Sync progress and post-delete refill.
The Advanced master-switch tooltip now describes these actual consumers.

The helper's Git-shaped ls-remote form connects and reads advertisements through
libgit2. Its default output includes HEAD; --refs excludes HEAD/peeled rows, and
-t selects tag advertisements. OID/ref records use stdout; diagnostics and owned
progress use stderr. A URL read from an ordinary folder uses in-memory repository
configuration without initializing a filesystem repository. Named remotes and URL
rewrites retain captured config and the actual-request HTTP settings reader.

The helper accepts Push only for deletion refspecs. `git_remote_push` callbacks
report each reference's actual result; any per-reference rejection fails the
command even when libgit2's outer return alone reports success. Completed refs
remain deleted and their output remains available. Grouped Browser remotes keep
source order and stop on failure/cancellation. Existing exact reference names,
selection/hash validation, confirmation and Sync snapshots stay in effect.
Successful libgit2 deletion also updates matching local remote-tracking refs:
the pinned `git_remote_push` calls `git_remote_update_tips`, whose push update
removes a tracking ref mapped by the configured fetch refspec. Local branches,
local tags, HEAD, index and working bytes retain their separate invariants.

## Authentication and ownership

These operations use the already connected native credential/certificate protocol,
actual-peer DER/hostname/port, custom CA/header/proxy resolution and temporary
host+port+DER exceptions. They do not probe a second endpoint or disable global
TLS verification. Prompt cancellation, accepted certificate export drainage and
process-group reaping retain the shared lock/marker handshake. Native workers,
coordinators, progress/error decisions and Quit ownership remain retained until
the actual operation and owned presentations settle. Retired callbacks cannot
start deletion or publish replacement catalogs.

The original Windows `last_accepted_cert` cache in AppUtils::Git2CertificateCheck
is process-wide. The [shared authentication continuation](REMOTE-AUTHENTICATION-PARITY.md)
adds process-memory acceptance across native list/delete/refill helper calls,
scoped to exact actual host+port+DER. Credential saving, permanent trust and Git
credential-helper protocols are not part of this source callback.

## Evidence and remaining scope

[Batch QA](qa/remote-reference-engine-2026-10-19.json) records actual hashes,
attempts, failures/repairs and retained passes after the grouped checkpoint.
New Core cases use the actual helper with private repositories and a loopback
smart HTTPS server. The native receiver uses actual list/delete/Sync models and
private preferences; it does not duplicate or certify physical authentication UI.

Physical remote-picker/tag/Browser/Sync keyboard/menu interaction, real network
providers, signed SSH/HTTPS grants and current App Store deployment remain open.
Other local libgit2 mask consumers, external filter/LFS drivers, Git hooks,
conventional custom askpass and Git credential helpers retain their recorded
optional-engine gaps. Current full hosted CI and complete source parity are not
proved by this focused family checkpoint.

## October 19 grouped checkpoint

37 distinct focused Core methods pass: 36 on the initial grouped run, then the
single corrected tracking-ref contract method. The initial test incorrectly
required tracking-ref retention; pinned libgit2 source proves deletion of its
mapped tracking ref. Local branch/tag and HEAD/index/working invariants remain.
The actual universal helper passes ARM and Intel clone/fetch/list/delete checks
after correcting missing-ref fixture exit-code assumptions. Both unchanged C
slices were reused when republishing the validator provenance.

Debug passes after the first embedding attempt rejected the concurrently changed
validator fingerprint. The actual packaged helper's signed/unsigned mapping,
source pins and complete source hashes match the prepared runtime. One offscreen
native receiver passes the picker, tag, Browser, Sync, captured-confirmation,
stale-callback and actual cancellation/child-reaping family. Its PID 41370 was
reaped, with owned windows/sheets/workers drained. Native zero-size split-view
layout diagnostics from invisible windows are retained in the log. These checks
do not prove full hosted CI, physical UI acceptance or signed deployment.
