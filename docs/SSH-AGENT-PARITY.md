# SSH identity and agent port

Reference: pinned `CAppUtils::LaunchPAgent`, `DoFetch`, `DoPush`, Sync and
BrowseRefs callers, upstream `7338078f8ddd924b8cddee35f512f2286072136d`.

TortoiseGit's PuTTY-key setting supplies a key to Pageant. Selected remotes load
their key before transport; Fetch All loads multiple keys into the agent. It is
not a per-remote `core.sshCommand` assignment. A global identity command would
change the behavior of other remotes and cannot represent this workflow.

OpenSSH documents its foreground agent and multiple-identity behavior in the
[agent manual](https://man.openbsd.org/ssh-agent), and key loading in the
[ssh-add manual](https://man.openbsd.org/ssh-add). Host macOS tools are exercised
locally; these upstream manuals do not establish signed macOS acceptance.

`SSHAgentSession` is a preparatory Core transport primitive. Core Fetch/Pull/Push
now accept awaited preparation and retain a returned agent through transport;
[transport boundaries](SSH-TRANSPORT-PARITY.md) documents the tested channel.
Native Clone/Fetch/Pull/Push and configured remote browsing/deletion routes now
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
Those helpers are not packaged yet. The app now embeds an original Swift askpass
CLI. A supplied response can load an encrypted key through a private one-use
channel; without a response, the headless loader rejects interactive prompting.
The native secure response dialog now connects to configured-key loading in
Clone/Fetch/Pull/Push, remote branch browsing, remote tags, BrowseRefs remote deletion and Log server deletion. Keychain integration is pending. See
[SSH passphrase parity](SSH-PASSPHRASE-PARITY.md). This is not authentication or
signed sandbox acceptance.

## Remaining end-to-end work

- Package pinned universal OpenSSH helpers, notices/reconstruction material and
  signed sandbox inheritance; audit their own dependencies and runtime behavior.
- Verify signed identity selection, renewal and loading; add permission management. Native mock-scope loading exists and Windows PuTTY configuration is preserved. Conversion or native PPK support remains pending.
- Verify physical encrypted-key response sheets and add Keychain decisions with owned
  cancellation. Keep private bytes out of command output, Finder and docs.
- Extend existing auto-load to submodules and Sync, preserving destination
  and failure ordering.
- Test actual SSH authentication/host-key handling, saved and expired grants,
  connection errors, both architectures and signed App Store/Finder routes.

Local tests generate private fixture keys, load two real identities into a private
agent, reject an encrypted fixture without prompting, preserve earlier additions,
check literal punctuation paths, and verify live helper/child termination during
forced closure. They do not contact an SSH server or exercise the application.
