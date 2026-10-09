# Native SSH identity selection

Reference: pinned `CSettingGitRemote::OnBnClickedButtonBrowse`, source key field
and Pageant loading callers at `7338078f8ddd924b8cddee35f512f2286072136d`.
Source Browse selects an existing file and updates the draft changed mask;
Apply/Save writes the remote setting. macOS requires a file permission as well.

Manage Remotes adds an SSH Key row with a native single-file picker. The existing
PuTTY Key row retains `remote.<name>.puttykeyfile` for Windows interoperability;
the native path uses `remote.<name>.turtlegitsshkeyfile`. These are independent.
The native row is an explicit platform adaptation, not an upstream extra control.
Fetch/Pull/Push, remote branch browsing, remote tags, BrowseRefs remote deletion and Log server deletion now consume this setting when
Auto-load SSH key is enabled (automatic where no checkbox is shown); see [transport parity](SSH-TRANSPORT-PARITY.md).

Only edited fields are written; native key writes follow the source fields.
Remote rename moves the native setting with Git's section; clearing it leaves
Windows configuration untouched. Settings commands override
`core.precomposeunicode=false` for that invocation so raw config keys/values
retain their argument bytes. This does not modify the repository's preference.

Browse prefills an existing key's folder/name, accepts one file and blocks page
edits while the panel is attached. Selecting a key captures a read-only bookmark
in `TurtleGit/ssh-identities/grants.json` in the app's private Application Support
folder. Its parent is mode 0700; exclusive temporary writes start at mode 0600
and are atomically renamed. Records contain paths/bookmarks, no private key or
passphrase bytes. They are never put in Git config or the Finder App Group.

Typed config paths do not grant access. Loading must acquire a remembered file
permission and retain it through ssh-add. Resolving a stale bookmark renews it;
a moved file is returned without silently rewriting Git config. Failed/revoked
permissions require Browse again in signed builds. File grants reject missing
files, directories, final symlinks and the bounded PuTTY format marker, regardless
of extension. Other key-format compatibility is determined by OpenSSH, not this
store. Symlink-parent races and all adversarial same-user changes are not proved
safe by these checks.

The selected permission remains available after canceling the settings page,
but unsaved draft paths are discarded. Earlier Apply/Save operations remain.
Grants are reusable by path across remotes and repositories; removing a remote
does not delete its key or grant. A Core forget operation exists; a user-facing
permission-management page is still pending.

Tests use private fixtures and an injected bookmark provider to prove persistence,
renewal, moved paths, exact-byte lookup, balanced scope lifetime, permission denial,
malformed storage, format rejection and no private content persistence. These
mocks do not establish real sandbox access. Hidden native tests exercise the
shipping selection callback, field/save and config effects, legacy preservation,
typed-path nonauthorization, child gates and late selection refusal. Actual
picker gestures, physical appearance/keyboard/VoiceOver, signed file grants,
real transport authentication remain pending. Hidden coordinator fixtures now
verify automatic loading with balanced mock scope leases; signed loading remains
unverified.

See [SSH agent](SSH-AGENT-PARITY.md) and [encrypted response](SSH-PASSPHRASE-PARITY.md).

Clone and Submodule Add now remember the selected key through this same read-only store and write
the native remote setting after success (Add writes it on the child origin).
Old cloned-repository key bookmarks remain
legacy compatibility paths; new native clones do not send those to repository
adoption. See [Clone parity](CLONE-PARITY.md) for verification and remaining work.
