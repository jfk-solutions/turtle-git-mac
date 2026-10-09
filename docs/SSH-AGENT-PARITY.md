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

`SSHAgentSession` is a preparatory Core transport primitive, not yet called by
the application's Fetch/Push or key picker. It starts a foreground OpenSSH agent
in an owned process group, with an atomically-created mode-0700 directory and
private socket. It never changes the login agent. Command arguments remain
literal byte-preserving arrays. Loading multiple unencrypted identities uses
owned `ssh-add` commands; earlier successful keys remain after a later failure.
Close cancels and reaps the agent and any active key loader before removing its
directory. The worker retains separate state, so releasing a session also closes
it. Socket path length is checked against macOS's Unix-domain socket limit.

Development resolves system OpenSSH tools when bundled helpers are absent. The
App Store resolver requires both bundled agent/add helpers and refuses fallback.
Those helpers are not packaged yet. The headless loader rejects passphrase
prompting; encrypted-key native prompts/Keychain and a bundled askpass helper are
still required. This is not authentication or signed sandbox acceptance.

## Remaining end-to-end work

- Package pinned universal OpenSSH helpers, notices/reconstruction material and
  signed sandbox inheritance; audit their own dependencies and runtime behavior.
- Add native identity selection, app-private file bookmarks, renewal and scope
  leases held through key loading; preserve Windows PuTTY configuration without
  treating `.ppk` as an OpenSSH key. Conversion or native PPK support is pending.
- Implement native encrypted-key prompts and Keychain decisions with owned
  cancellation. Keep private bytes out of command output, Finder and docs.
- Wire source Auto-load behavior into Fetch/Pull/Push, remote tags, remote-branch
  deletion, Clone/submodules and Sync, including all-remotes and failure ordering.
- Test actual SSH authentication/host-key handling, saved and expired grants,
  connection errors, both architectures and signed App Store/Finder routes.

Local tests generate private fixture keys, load two real identities into a private
agent, reject an encrypted fixture without prompting, preserve earlier additions,
check literal punctuation paths, and verify live helper/child termination during
forced closure. They do not contact an SSH server or exercise the application.
