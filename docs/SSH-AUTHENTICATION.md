# Saved SSH authentication

When a network workflow loads an encrypted OpenSSH key, TurtleGit asks for its
passphrase in a secure native field. **Save authentication** is off by default.
Select it to save the passphrase in this Mac’s Keychain after the key loads
successfully. An incorrect response or Cancel does not create a saved entry.

On a later operation, TurtleGit first tries normal key loading, then tries the
saved passphrase if one is available. A rejected saved response returns to the
native prompt. Entering a new response with Save authentication unchecked uses
it for that operation without replacing the saved entry. Select the checkbox to
replace the entry after successful loading. If reading a saved entry fails,
the prompt explains that it is unavailable and permits a manual response.

This applies to the shared **Auto-load SSH key** workflow used by network dialogs
and reference commands, including explicit selected keys in Clone and Submodule
Add. It does not supply HTTP credentials, host-key trust decisions or an SSH
server’s account password. Existing Git credential helpers still govern HTTP.

Open **Saved SSH Authentication…** from the application menu or Credential
settings to list saved key labels. Select entries and choose **Remove…** to
remove them after confirmation. Cancel leaves the entries intact. Removal saves
immediately; it is not part of Settings Apply/Cancel. It does not unload a key
already held in an active operation’s private agent. That agent closes when its
operation owner finishes.

Entries identify the exact private-key file content by SHA-256, rather than its
path. Replacing a key at the same filename does not reuse the old entry. Moving
the same file can reuse its entry after granting access to the new path. Old
entries remain listed until removed. Keychain stores the passphrase and filename
label, not the private-key bytes or full path. Entries do not synchronize through
iCloud and are accessible while this device is unlocked. The entry list requests
metadata only; it does not read or display saved passphrases.

The key-loading owner retains file permission through hashing, prompting and
loading. Observable file changes are checked before and after loading. Cancel
and retired-window replies cannot start another load or save. Quit waits for
active preparation and credential management; a Keychain write already in
progress may finish before cancellation is observed. Save failures report the
Keychain error and stop preparation before network transport begins.

Private checks use injected Keychain storage. Live signed Keychain behavior,
physical keyboard/theme/VoiceOver acceptance and exhaustive file-replacement
races remain unverified. See [SSH transport audit](SSH-TRANSPORT-PARITY.md).
