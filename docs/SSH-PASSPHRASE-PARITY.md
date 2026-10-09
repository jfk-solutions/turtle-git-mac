# SSH encrypted-key response port

Pinned upstream: `7338078f8ddd924b8cddee35f512f2286072136d`. The native
response contract replaces the `ask_passphrase` callback in
`src/TortoisePlink/pageant.h`; no PuTTY implementation is copied. This is a
preparatory component, not complete SSH authentication or dialog parity.

`SSHAgentSession.add(keys:passphrase:cancellation:)` accepts an optional response.
Each key receives a separate envelope in the owned agent directory (mode 0700).
The envelope is a plaintext temporary file, created exclusively with mode 0600;
it contains a protocol marker and single-line UTF-8 response. The response is
absent from argv, environment values and logs. Environment supplies only its
path and the helper path. The helper checks ownership, permissions, regular-file
type, single link, size, UTF-8 and inode identity, refuses symlinks, consumes the
file, and returns the response through OpenSSH's stdout pipe. Replay fails.
The owner also removes unconsumed envelopes on success, error or cancellation.
These checks do not establish protection against every same-user race or memory
inspection. No Keychain persistence or secure-memory erasure is claimed.

The native AppKit response window has a secure field, key filename, OK/Cancel,
Return/Escape configuration and one-shot response. Cancel/forced closure clears
the field; late actions cannot return another response. It is connected to Clone/Submodule Add/Fetch/Pull/Push and remote browsing through the
[native coordinator](SSH-TRANSPORT-PARITY.md). Hidden tests verify control configuration and callbacks; physical
focus, key presses, sheet appearance, long filenames, light/dark and VoiceOver
acceptance remain unverified. No Windows visual equivalence is claimed.

The built CLI is embedded under `Contents/Helpers/SSHAskpass/`, with source and
post-sign binary hashes. The bundle validator checks hashes, macOS 13 deployment,
architectures, system linkage and an unsigned private dummy-response invocation.
App Store builds require both architectures. Signed inherited-sandbox invocation
must be exercised from the signed app; unsigned Python is not acceptance evidence.

Local tests exercise a real encrypted ed25519 fixture with wrong/correct responses,
retained earlier identities, malformed responses, permissions, symlinks, replay,
and live loader/child cancellation with envelope removal. They do not use user
keys, inspect the login agent, contact an SSH server or launch the main app.

Key picker/bookmarks, scope leases and native auto-load/retry orchestration now
exist; see the linked identity and transport audits for scope and limitations.
Remaining: physical response-window acceptance, Keychain choices, PPK conversion/support,
signed bundled OpenSSH invocation, host-key/password authentication, signed Finder/App
Store acceptance and complete native UI comparison. See [agent parity](SSH-AGENT-PARITY.md).

The [bundled-agent native audit](qa/bundled-ssh-agent-2026-10-10.json) now exercises
the embedded OpenSSH key loader with the embedded one-use response CLI through
the actual Core framework in both unsigned app configurations. Correct responses
load encrypted fixture keys; wrong/missing responses preserve earlier identities.
Pre-cancellation, live loader closure and injected failures remove private files
and reap owned processes. This verifies the packaged response chain, not the
physical secure field, signed access, Keychain or server authentication.
