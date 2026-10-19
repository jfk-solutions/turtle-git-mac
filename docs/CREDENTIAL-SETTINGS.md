# Credential settings

Open **Settings → Git → Credential** to choose how Git obtains and stores HTTPS
credentials. This page configures Git's helpers and matching rules. It does not
edit saved passwords; use **Keychain Access** for credentials stored by the macOS
Keychain helper. SSH keys use the separate [SSH workflow](SSH-AUTHENTICATION.md).

## Choose a helper mode

The simple selector offers available helpers, None and Advanced. A simple choice
replaces the displayed credential configuration with the selected default helper,
or clears it for None, after confirmation. Review that confirmation when several
URLs or configuration files are listed. Choose Advanced to keep separate rules.

The Helpers list groups rules by configuration file, scope and URL. Select a row
to edit its Config type, URL, Helper, Username and Use HTTP path component fields.
Config type selects the destination file; included files and other origins remain
visible as distinct entries. URL spelling and entered helper/username text are
preserved exactly; visually identical Unicode spellings can be separate Git
rules. Select the intended row before applying or removing it. System files require write access. The app does not
start a privileged helper to bypass file permissions.

## Apply edits or save a new rule

For a selected rule, **Apply** writes only the fields you edited in the same file
and URL. Changing a username leaves its helper chain and HTTP-path entries intact.
Existing rules that contain only a username or HTTP-path setting can be edited
without adding a helper. Changing URL or Config type with Apply writes the helper
and only optional fields you edited. Untouched username and HTTP-path values
already at the destination remain intact. Untouched repeated values, empty helper
resets and values from other configuration files remain intact.

**Add New/Save** saves the complete draft immediately. It requires a helper and
asks before replacing a matching destination. Changing the URL or Config type
prepares a rule at that destination; it does not remove the original rule. To
remove the original, select it and use **Remove**. Remove clears that rule's
configuration fields after confirmation, including fields not shown in the form.
It does not delete passwords retained by the helper.

When you change the selected row with unsaved edits, choose Save to apply those
edits before switching, Discard to leave those edits unsaved before switching, or Cancel to keep editing. Closing
Settings with Cancel discards pending edits; changes already saved with Add
New/Save or Apply remain saved.

## Empty fields and inherited settings

Clearing an edited Username removes that key from the selected file. Clearing
an edited helper removes that file's helper entries. An untouched empty helper
inside an existing chain remains Git's inheritance reset and is preserved.

Unchecking an edited **Use HTTP path component** removes the selected file's
setting, matching TortoiseGit. Another matching Git configuration rule may still
enable HTTP-path matching. Unrelated edits do not create an explicit false value
or rewrite this setting. Use the effective Git configuration to inspect inherited
values when a broader rule supplies one.

External configuration changes cause a stale save to be refused. Reload and
review the current rule before saving again. Multi-key writes follow source
order and use Git's file locks; a later failure can leave earlier accepted writes
in place, so review the reported result before retrying.

Credential-helper availability, live server authentication and signed sandbox
acceptance still need separate verification. See the
[credential source audit](CREDENTIAL-SETTINGS-PARITY.md) and
[authentication prompts](GIT-AUTHENTICATION.md) for scope and remaining limits.
