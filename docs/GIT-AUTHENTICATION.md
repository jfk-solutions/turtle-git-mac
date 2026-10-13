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
light/dark appearance is passed to the helper. The dialog uses the original
TortoiseSmall artwork from the packaged icon resources.

This implements Git CLI responses, including the generic fallback used by HTTPS
operations. OpenSSH host-key/account-password prompts, certificate dialogs,
OAuth manager behavior and signed inherited-sandbox execution remain separate
acceptance work. Private checks do not prove live public-server authentication
or every credential-helper combination. See [source audit](GIT-AUTHENTICATION-PARITY.md).
