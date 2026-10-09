# SSH identity and agent port

Reference: pinned `CAppUtils::LaunchPAgent`, `DoFetch`, `DoPush`, Sync and
BrowseRefs callers, upstream `7338078f8ddd924b8cddee35f512f2286072136d`.

TortoiseGit's PuTTY-key setting supplies a key to Pageant. Selected remotes load
their key before transport; Fetch All loads multiple keys into the agent. It is
not a per-remote `core.sshCommand` assignment. A global identity command would
change the behavior of other remotes and cannot represent this workflow.

OpenSSH documents its foreground agent and multiple-identity behavior in the
[agent manual](https://man.openbsd.org/ssh-agent), and key loading in the
[ssh-add manual](https://man.openbsd.org/ssh-add). System and embedded tools are exercised
locally; these upstream manuals do not establish signed macOS acceptance.

`SSHAgentSession` is a preparatory Core transport primitive. Core Fetch/Pull/Push
now accept awaited preparation and retain a returned agent through transport;
[transport boundaries](SSH-TRANSPORT-PARITY.md) documents the tested channel.
Native Clone/Submodule Add/Fetch/Pull/Push and configured remote browsing/deletion routes now
supply this callback. Native key selection and file grants are documented in
[identity selection](SSH-IDENTITY-PARITY.md). The session starts a foreground OpenSSH agent
in an owned process group, with an atomically-created mode-0700 directory and
private socket. It never changes the login agent. Command arguments remain
literal byte-preserving arrays. Loading multiple identities uses
owned `ssh-add` commands; earlier successful keys remain after a later failure.
Close cancels and reaps the agent and any active key loader before removing its
directory. The worker retains separate state, so releasing a session also closes
it. Socket path length is checked against macOS's Unix-domain socket limit.

Development resolves system OpenSSH tools when bundled helpers are absent. The
App Store resolver requires both bundled agent/add helpers and refuses fallback.
Xcode builds now embed the pinned universal agent/add tools and SSH client.
Build, signing and audit preparation are tracked in
[OpenSSH runtime preparation](OPENSSH-RUNTIME.md). The app now embeds an original Swift askpass
CLI. A supplied response can load an encrypted key through a private one-use
channel; without a response, the headless loader rejects interactive prompting.
The native secure response dialog now connects to configured-key loading in
Clone/Fetch/Pull/Push, remote branch browsing, remote tags, BrowseRefs remote deletion and Log server deletion. Keychain integration is pending. See
[SSH passphrase parity](SSH-PASSPHRASE-PARITY.md). This is not authentication or
signed sandbox acceptance.

## Remaining end-to-end work

- Verify signed parent invocation of embedded OpenSSH helpers and transports.
  Packaged Git now prefers the bundled client; static signing checks are not execution acceptance.
- Verify signed identity selection, renewal and loading; add permission management. Native mock-scope loading exists and Windows PuTTY configuration is preserved. Conversion or native PPK support remains pending.
- Verify physical encrypted-key response sheets and add Keychain decisions with owned
  cancellation. Keep private bytes out of command output, Finder and docs.
- Extend existing auto-load to submodule Update and the broader SyncDlg transport window, preserving destination
  and failure ordering.
- Test actual SSH authentication/host-key handling, saved and expired grants,
  connection errors, both architectures and signed App Store/Finder routes.

Local tests generate private fixture keys, load two real identities into a private
agent, reject an encrypted fixture without prompting, preserve earlier additions,
check literal punctuation paths, and verify live helper/child termination during
forced closure. They do not contact an SSH server or exercise the application.

Submodule Sync is a local configuration operation and does not require SSH
preparation. Its native port is documented in SUBMODULE-SYNC-PARITY.md.

## Bundled encrypted-key and abandonment checks

Unsigned native receivers load each Debug/AppStore bundle's actual Core image
and resolve its bundled agent, key loader and response helper. Disposable
OpenSSH-generated keys exercise missing, wrong and correct responses, preserve
earlier identities, reject pre-cancelled loading and leave no response/output
files. Unicode and shell punctuation remain literal key paths. A monitor execs
the real agent in its owned PID/group for cleanup observation.

A controlled loader wrapper holds a pending response while an owned child waits.
Closing the session reaps agent, loader and child and removes the private
directory. An injected failure checks the same cleanup through deferred closure.
The driver checks every registered PID and directory before deleting the fixture;
emergency cleanup targets only positively identified fixture-owned groups and
fails the test if needed. See the
[bundled-agent audit](qa/bundled-ssh-agent-2026-10-10.json). These checks launch no
app window, use no user key/login agent and contact no server. Signed sandbox
invocation, real authentication and physical response-window acceptance remain
unverified.
