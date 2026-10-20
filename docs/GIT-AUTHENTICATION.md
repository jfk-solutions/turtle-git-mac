# Git authentication prompts

The Xcode app bundle includes a native Git askpass helper. When a network command
needs an HTTPS username or password and configured credential helpers have not
supplied it, Git opens **Authentication – TurtleGit** with its original request,
one response field, OK and Cancel. Recognized username requests are visible;
password and unfamiliar authentication requests are masked. Return accepts and
Escape cancels. Closing the window returns no response and clears its field.

The helper writes an accepted single-line response only to Git’s private pipe,
then exits. It does not save passwords or create a credential file. Git’s
configured credential helpers govern storage and approval after authentication.
Configure them in Credential settings or the First Start Wizard. This CLI prompt
has no Save authentication checkbox, matching the upstream SshAskPass resource;
it is separate from the saved SSH key-passphrase workflow.

Explicit `GIT_ASKPASS`, `core.askPass` (including an empty configured value),
command-line overrides and `--config-env` choices take precedence over the
bundled default. Terminal prompting remains disabled. For headless execution,
`TURTLEGIT_DISABLE_ASKPASS=1` suppresses the bundled default; an explicitly selected
external helper retains its own behavior. The standalone Swift Package app does
not embed this tool: use the Xcode bundle or an installed credential helper.

The helper is an accessory process with one native window and no persistent Dock
instance. It exits after OK or Cancel. Its process belongs to the Git operation’s
owned process group; cancellation uses that existing ownership. The app’s chosen
light/dark appearance is passed to the helper. The dialog uses the shared TurtleGit turtle/Git artwork from the packaged icon
resources, matching the app and Finder menus.

This implements Git CLI responses, including the generic fallback used by HTTPS
operations. Certificate dialogs,
OAuth manager behavior and signed inherited-sandbox execution remain separate
acceptance work. Private checks do not prove live public-server authentication
or every credential-helper combination. See [source audit](GIT-AUTHENTICATION-PARITY.md).

## OpenSSH prompts

Network Git operations also supply a separate `TurtleGitOpenSSHAskpass` alias
when the caller has not selected `SSH_ASKPASS`. OpenSSH receives the direct path
and defaults to `SSH_ASKPASS_REQUIRE=force`, allowing native interaction without
an X11 display. Existing helpers, an explicit `never`/`prefer` requirement and
the headless disable flag retain precedence. The private SSH agent’s dedicated
passphrase helper and saved-key workflow remain independent.

SSH password and fallback passphrase fields are secure. Host-key questions and
OpenSSH permission hints use a visible response field and **Continue / Cancel**;
Cancel has initial focus and is the default button. Continue explicitly sends
`yes` when the field is empty, or the entered fingerprint/answer otherwise.
OpenSSH decides whether to accept it and where to store known hosts under its
existing configuration. Retry questions keep the same confirmation mode.
No host is trusted automatically. Escape cancels every prompt.

OpenSSH’s `none` hint presents a notification, such as a request to touch a
security key, without a response field or Continue action. The owning SSH
process controls completion and termination; closing the notification does not
itself guarantee cancellation of the security-key operation. SSH responses are
limited to 1,023 UTF-8 bytes, matching the pinned OpenSSH reader. Oversized or
multiline responses keep the dialog open instead of silently truncating input.

This is a native OpenSSH adaptation, not certification of the complete upstream
TortoisePlink host-key dialog. Live-server, security-key device and signed
sandbox interaction remain acceptance work.


## SSH signing

When Git is configured to sign commits or tags with an encrypted SSH key, local
signing commands can use the same secure OpenSSH response window. The owning
Git operation controls cancellation. Explicit askpass helpers and requirement
settings keep their precedence; TurtleGit does not change the login agent or
signing configuration. Existing GPG pinentry and external signing agents keep
their configured behavior. See [Commit preparation and signing](COMMIT-IDENTITY-PARITY.md)
for the source boundary, validation scope and remaining signed acceptance.
