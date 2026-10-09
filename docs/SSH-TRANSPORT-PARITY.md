# SSH preparation at Git transport boundaries

Pinned upstream `7338078f8ddd924b8cddee35f512f2286072136d`:
`AppUtils.cpp::DoFetch`, `DoPull`, `DoPush` and `LaunchPAgent`.
Source Fetch All loads every configured remote key before one fetch invocation;
Push loads each remote's key immediately before that remote's push. The return
from source LaunchPAgent is ignored by these callers. Complete native error and
retry decisions remain a coordinator responsibility, not proven source parity.

Core Fetch, Fetch for Rebase, Pull, Push and remote-branch lookup now accept an
optional awaited `SSHTransportPreparation` callback. Callers without a callback
retain normal Git environment behavior. Fetch/Pull/Push and Fetch branch browsing
now supply an operation-owned native coordinator when Auto-load SSH key is enabled.

Fetch validates its options, then supplies either the selected destination or
all remote names once before running Git. Fetch for Rebase forwards the callback
through its selected-branch fetch; target capture and recovery reads do not
re-run preparation. Pull supplies its destination before the transport command.
Branch lookup supplies its destination before ls-remote. Push validates the plan,
retains its existing saved-config effects, then prepares one remote before its
first push. All-branches plus tags shares that session for both commands.

The callback can suspend for native grant or passphrase decisions and reenter
the repository actor for settings reads. It returns an owned `SSHAgentSession`
or nil. A returned session is retained through the command, including both Push
branches/tags invocations and error/cancellation paths. Git receives its private
socket and an empty `SSH_AGENT_PID`; an inherited login-agent PID is not paired
with that socket. A coordinator may retain a shared session to accumulate keys,
and must eventually close/release it. File grants must remain held during key
loading. No credentials are added to Git argv or environment.

Preparation receives the caller's cancellation token, or an owned token when
none was supplied. Cancellation is checked before and after awaiting the response
so a late response cannot launch Git. Preparation errors abort the current
transport. Push wraps such failures with prior completed destinations and stops
later remotes; successful earlier pushes and prior saved config are retained.
This hook behavior is not a claim that native error decisions exactly match the
source callers' ignored Pageant return value.

Six new tests use a real private agent, generated fixture key and a controlled
Git wrapper. The wrapper refuses to query any agent unless its socket is inside
the fixture, verifies the public fixture identity before executing real Git, and
asserts an inherited sentinel PID is cleared. Local repositories verify Fetch,
Fetch for Rebase, Pull and branch lookup, Fetch All's one callback, Push's ordered
partial success, shared branches/tags lifetime, validation/pre-cancel/late-cancel,
and live Git helper/child plus agent reaping. No SSH server is contacted: local
Git effects and Unix-agent access prove the preparation channel, not network
SSH authentication. Nil-callback Fetch/Pull/Push regression tests also run.

## Native auto-load coordinator

Fetch/Pull and Push expose **Auto-load SSH key**, available only when the private
agent, loader and response helper resolve. It defaults on for an available runtime
and is saved per repository and dialog mode. Each submission captures a factory;
subsequent checkbox changes cannot change that operation. Each retry creates a
fresh coordinator. Remote branch browsing also prepares its selected remote.
Arbitrary URLs without a configured remote key do not select an identity.

The coordinator reads the native `remote.<name>.turtlegitsshkeyfile` setting and
holds the private read-only bookmark lease through loading. It creates a private
agent lazily, batches Fetch All identities, and accumulates Push identities in
remote order. A successfully loaded file is deduplicated by byte-exact path,
device, inode, size and nanosecond modification time. Replacing/modifying a key
reloads it; this is not a cryptographic fingerprint or proof against all races.

Loading first refuses interactive askpass. macOS OpenSSH can report that refusal
with status 1 and no diagnostic. A bounded 256-byte header check recognizes
encrypted OpenSSH (including CRLF), encrypted PKCS#8 and traditional encrypted
PEM before requesting a response in that case. Recognized incorrect-passphrase
diagnostics also request a retry. The loader uses invocation-local `LC_ALL=C`.
Unrecognized headers and other loader errors remain errors; this is not a complete
key-format parser. A native secure response window owns one response, clears on
Cancel/closure and shows a retry explanation after an incorrect response.

Prompt Cancel, operation cancellation and parent invalidation stop preparation;
late responses cannot launch Git. The private agent closes when transport ends.
Invalid grants/keys and loader failures abort instead of silently continuing as
the source callers can after ignoring Pageant's return. Earlier successful pushes
and saved config remain retained. This is an explicit macOS adaptation.

Hidden native fixtures exercise real encrypted keys, wrong/correct responses,
replacement-key reload, balanced mock bookmark leases, token/forced closure,
shipping model Fetch/Pull/Push/browse effects and checkbox snapshots with system
and bundled Git. A shipping Push controller is closed while awaiting a response:
no transport or late success callback may follow. Windows are not ordered or
shown; sheet focus, physical keyboard behavior and signed bookmark access remain
unverified. No login agent, user key or real SSH server is used.

App Store runtime resolution still refuses missing bundled OpenSSH agent/add;
auto-load is disabled there until packaging is complete. Unsigned Debug uses the
system OpenSSH tools plus the embedded response helper.

## Remote tags and Browse References deletion

Remote tag listing and accepted deletion now use the same awaited preparation
boundary. Tag names are validated before loading any key; each catalog, deletion
and post-deletion refresh owns a fresh coordinator and agent. These dialogs add
no auto-load checkbox. Available native runtimes automatically prepare a
configured native key; absent/unavailable native keys retain ordinary Git behavior.
This extends macOS key loading to the source remote-tag workflow; the pinned
DeleteRemoteTagDlg itself does not call LaunchPAgent.

BrowseRefs remote-branch deletion follows the source's sorted remote groups:
one preparation immediately before each remote's batch Push. Local branch/tag
deletions perform no preparation. One operation-owned coordinator can retain
loaded identities across groups; any preparation/Push failure stops later groups,
retaining earlier server effects. The single-reference Core convenience route
forwards the same optional hook. Log's separate history-reference deletion route is described below.

Native owners present encrypted-key responses using their existing window or
progress window. Forced closure cancels their existing token, rejects late prompt
answers and closes the agent. Physical nested-sheet and signed acceptance remain
unverified. Preparation remains optional for Core callers.

## Log reference deletion

Log retains the source DeleteRef remote/local-tracking choices. Only the remote
server choice prepares its configured remote before Push. An operation-owned
coordinator can retain loaded identities across the source All-label sequence;
local branch/tag/generic-ref and stash choices do not load keys. Runtime
availability determines automatic loading; no additional checkbox is introduced.

One owned token now covers reference validation, current/merged reads, snapshot
reads, destructive commands and the shared stash/reflog batch helpers. Closing
Log cancels that token, dismisses attached sheets and prevents late errors,
acknowledgements or reloads. Shared batch deletion stops on cancellation rather
than treating it as an ordinary command failure and continuing to another entry.
Earlier successful deletions remain retained.

After suspended SSH preparation the backend checks the local tracking reference
snapshot again before Push. A changed snapshot aborts that transport; this is a
native guard, not a claim that the remote server ref cannot change concurrently.
The existing source All-label behavior remains: reported remote/stash errors can
continue, ordinary/local-tracking errors stop, and Cancel stops the sequence.
Signed access, physical sheet interactions and all races remain unverified.

Remaining: other SSH consumers (submodule Update and broader SyncDlg), bundled
OpenSSH, Keychain, host-key/password prompts, physical UI/sheet acceptance,
signed App Store/Finder and real network authentication. Concurrent config/ref changes across suspended preparation
and complete source failure equivalence remain unverified.


## Clone selected identity

Pinned CloneDlg restores the auto-load preference/key history; CloneCommand loads
that explicit key before a repository/remote exists and stores it before Log.
Native Clone supplies an explicit-key coordinator preparation with an empty remote
list. Validation precedes preparation, and preparation/cancellation failure cannot
start Clone. Both direct and captured-progress paths own a fresh coordinator;
Retry creates another. The read-only identity store supplies the selected grant.

After success, native Core writes remote.<origin>.turtlegitsshkeyfile using the
literal key path and precomposeunicode=false, including bare/default-origin clones.
It leaves core.sshCommand and Windows puttykeyfile unset. Legacy Core sshKey callers
retain the previous shell-command mode unless loadSSHKeyWithAgent is selected.
The native mode requires a returned session; missing runtime fails before cloning.
Post-clone key-config write failure retains the destination and reports failure,
an explicit difference from source's StorePuttyKey error box followed by continued
result actions.

Hidden receiver coverage includes direct/progress effects and forced options-window
closure during an encrypted-key response, no late adoption/error/permission changes,
and private agent/grant cleanup. Actual server, modal picker ownership, displayed
sheets, recursive SSH/SVN, signed scope and post-clone metadata cancellation remain
unverified. See CLONE-PARITY.md and qa/ssh-clone-2026-10-09.json.

Submodule Add now shares explicit-key preparation before a child remote exists,
then saves the native origin key on the added child. Its captured native owner
holds grants and fences closure/late results. See [Add parity](SUBMODULE-ADD-PARITY.md)
for source Force precedence, verification and remaining progress/signed limits.
