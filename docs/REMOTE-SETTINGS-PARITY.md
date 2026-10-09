# Manage Remotes

Reference: pinned `CSettingGitRemote` and `IDD_SETTINREMOTE`, upstream
`7338078f8ddd924b8cddee35f512f2286072136d`.

The Core configuration backend is preparatory work for the native page. The
existing Push/Fetch remote form still only edits names and fetch/push URLs; it
does not yet use this backend or provide the complete source page. Manage Remotes
in Browse References remains pending.

## Configuration behavior

`RemoteSettings` reads raw effective URL, Push URL, legacy PuTTY key file, tag
policy, literal true/false/inherited Prune and byte-exact Push Default identity.
URL aliases are not expanded in the settings editor. Empty and unknown tag
policies map to reachable; nonliteral Prune values map to inherited, as upstream.

`RemoteSettingsFields` retains the source changed-mask values. Apply writes Push
Default first, then adds a remote when the name bit is set, then writes URL, key,
tags, Prune and Push URL in source order. A new remote uses its raw URL; subsequent
URL edits convert backslashes to slashes. Earlier successful writes remain after
a later failure. Only edited fields are written. Git's single-value config setter
does not replace all multivalued settings. Unset failures are followed by an
effective-value check so inherited or remaining values cannot silently appear
cleared. Unchecking Push Default does not clear a different remote's default.

Adding an existing name fails unless the caller explicitly removes the name bit
after obtaining overwrite consent. Rename and Remove use Git's own remote
commands, retaining Git's refspec/tracking updates. Slash-containing remote names
are supported. All operations own cancellation tokens, including calls which
omit a token, to preserve argument bytes through the native process runner.

The collision advisory checks local configuration and includes, the four source
remote/SVN refspec key families, byte-exact own-fetch exclusion, and the first
destination substring with an end-or-slash boundary. A collision is advisory,
not a hard validation gate. Exact libgit2 include/regex edge equivalence remains
unverified.

## Remaining native and transport work

Implement the source list/fields/Rename/Add New-Save/Remove layout, tags combo,
tri-state Prune and Push Default, dirty selection Save/Discard, no-tags warning
and suppression preference, overwrite/removal confirmations, origin prefill,
new-remote Fetch offer, Apply/Cancel, help/tooltips and owned process lifecycle.
Exercise the actual application and Browse References routes before recording
native parity. Sync URL history cleanup is not yet ported.

`puttyKeyFile` preserves Windows configuration for interoperability only. It does
not make PuTTY keys usable by OpenSSH. A native identity picker requires real
per-remote transport support, conversion/format decisions, security-scoped file
access and signed App Store verification. A global SSH command cannot implement
different identities for different remotes in Fetch All.

Physical layout, light/dark, keyboard, accessibility, signed Finder/App Store,
authentication, live forced-process cancellation timing and broad config races
remain unverified. Backend tests are not evidence of a completed dialog.
