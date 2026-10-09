# Manage Remotes

Reference: pinned `CSettingGitRemote` and `IDD_SETTINREMOTE`, upstream
`7338078f8ddd924b8cddee35f512f2286072136d`.

The native page now replaces the Push/Fetch remote form and is available from
Browse References remote folders with the original Settings icon. The source
list/field/button order, URL/Push URL, legacy key, tag combo, Push Default and
three-state Prune are mapped to native AppKit controls. Apply/OK/Cancel/Help adapt
the enclosing Windows property sheet. The port remains partial until native
identity transport and physical/signed acceptance are verified.

## Configuration behavior

`RemoteSettings` reads raw effective URL, Push URL, legacy PuTTY key file, tag
policy, native SSH key path, literal true/false/inherited Prune and byte-exact Push Default identity.
URL aliases are not expanded in the settings editor. Empty and unknown tag
policies map to reachable; nonliteral Prune values map to inherited, as upstream.

`RemoteSettingsFields` retains the source changed-mask values. Apply writes Push
Default first, then adds a remote when the name bit is set, then writes URL, key,
tags, Prune and Push URL in source order, then the native SSH key adaptation. A new remote uses its raw URL; subsequent
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

## Native behavior and remaining transport work

Rename is separate from Add New/Save. Native Save/Discard and overwrite/removal
questions use source messages; overwrite defaults to No. New remotes offer the
no-tags warning with a saved Yes/No suppression choice and a Fetch offer. The
Browse References page owns the resulting shared Fetch controller; Push/Fetch
embedded pages suppress that offer, matching the source default-page settings
route. URL entry in an empty list prefills origin. Field edits retain a source
changed mask, and failed saves during a dirty selection change still report the
error and proceed to the selected remote, as source selection handling does.

All Git reads/writes, collision checks, rename/removal and reference reloads are
owned and fenced against close and late confirmation callbacks. Parent close and
Quit are blocked during busy requests/attached children. Closing a page forcibly
cancels its requests. Cancel discards unsaved fields; earlier Apply/Save operations
remain. Errors appear in the native footer; the key tooltip identifies the Windows
interop limitation. Sync URL history cleanup, the timed origin hint balloon,
complete enclosing Settings tree and native OpenSSH transport loading remain pending.

`puttyKeyFile` preserves Windows configuration for interoperability only. A
separate native SSH Key row selects a file and remembers a private read-only
bookmark. Typed paths do not authorize key access. The native setting preserves
Windows paths rather than interpreting `.ppk` as OpenSSH. See
[identity selection](SSH-IDENTITY-PARITY.md). A global SSH command cannot implement
multiple identities for Fetch All; source loads keys into Pageant. The private
[agent primitive](SSH-AGENT-PARITY.md) is not yet wired into Git transport.

Physical layout, light/dark, keyboard, accessibility, signed Finder/App Store,
authentication, live forced-process cancellation timing and broad config races
remain unverified. Backend tests are not evidence of a completed dialog.
