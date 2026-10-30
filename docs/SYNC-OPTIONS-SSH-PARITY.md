# Synchronization options and SSH identity ownership

Pinned source: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseProc/SyncDlg.cpp` around 256–274. Sync loads the configured key into
Pageant before opening the full Fetch/Pull options dialog. Disabling automatic
key loading in that child does not remove an identity already available in the
agent.

The native port uses private operation-owned OpenSSH agents. Preparing Sync's
agent and then giving the options dialog an independent coordinator lost that
source behavior: a child could miss the prepared identity or ask for its
passphrase again. A scoped borrowing context now carries the prepared identity
set into the full-options workflow without modifying the login agent or global
process environment.

The child keeps its own saved Auto-load SSH key choice. Disabling it preserves
the inherited identities; enabling it permits loading keys for newly selected
remotes into the same private agent. New-key questions belong to the current
child. Closing a borrowing coordinator does not close the original owner's
agent. Cancellation and retirement invalidate late requests and retain the
actual child workers through their drain before the parent releases ownership.
Remote-reference queries reached from the child use the same captured context.
Unrelated Fetch/Pull dialogs retain their normal independent agent lifecycle.

This is a source-specific identity/lifetime handoff, not shared global Pageant
emulation. The existing configured-key permissions, exact identity revision,
passphrase retry and optional saved-authentication policies still apply.
The connected native checkpoint records actual private keys, agent/socket
identity, additional-key loading, child and parent cancellation, prompt ownership
and source option routing separately from physical interaction and signed
external repository/key grants. No public-server authentication or App Store
acceptance is implied.


The [grouped checkpoint](qa/file-activation-sync-options-2026-10-30.json) passes
with system and bundled Git. It retains the callback-readiness, remote-edit and
retired-field fixture failures and the real picker-drain repair. Both active-
picker and picker-first close orders keep the agent and parent ownership alive
until a deliberately held real key-read worker returns. Earlier passing
activation/control/GUI families were not repeated for that Fetch-only repair.
Installed build41 predates this continuation.
