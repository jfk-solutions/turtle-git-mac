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
does not delete its key or grant. Settings → Saved Data → SSH key file permissions → Manage now opens the native
permission manager described below.

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


## Connected permission management family — October 15, 2026

Saved Data's new macOS row opens Key File Permissions beside Saved Passphrases in
the same owned authentication window. It displays key filenames and configured
paths in a native table, with original key/command artwork, multi-selection,
context Copy Path/Forget Selected/Authorize File, Delete-to-confirm, Refresh and
Forget All. The listing reads only the app's grant records: it does not resolve
bookmarks, start security scopes, inspect private key bytes or renew records.
Missing/moved files can still be listed and forgotten. Canonically equivalent
configured names keep separate byte identities.

Authorize File uses an owned native single-file picker and the existing read-only
bookmark/format/scope validation. Cancel and repeated/retired callbacks cannot
remember a file. Key bytes, passphrases and Git settings are not copied into this
list or changed by forgetting. Settings Apply/Cancel does not govern these
immediate permission actions, matching the existing Saved Data clear controls.

Confirmed removal captures opaque grant snapshots and writes one atomic update.
A changed, renewed, missing or duplicated reviewed grant refuses the batch and
refreshes its error/list rather than deleting a replacement. Newly added unreviewed
permissions survive. Running operations retain their already acquired leases until
settlement; forgetting affects future acquire attempts. Forget All targets only
the displayed reviewed records. Files and saved Keychain passphrases are managed
separately.

The manager blocks ordinary Close while selecting/confirming and retains global
Quit accounting through an outstanding confirmation, including after forced owner
closure. Forced retirement ends owned panels/alerts and ignores their late replies.
Saved Data owns and closes the same child; the permissions page can be opened
directly without first querying saved passphrases. No signed bookmark acceptance
or live transport authorization is inferred from injected bookmark providers.

Grouped evidence and remaining limits are in
[permission-manager QA](qa/ssh-permissions-2026-10-15.json). Native theme hosts are
not a complete screenshot, physical keyboard/mouse or VoiceOver certification.
Signed file access, real bookmark renewal/moved-file dialogs and live server
loading remain release acceptance work. This is a macOS sandbox adaptation, not
an invented completed Windows resource control.
