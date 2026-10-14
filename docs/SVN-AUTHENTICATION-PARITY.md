# SVN native authentication and certificate prompts

Pinned callers are Git 2.55.0's `Git/SVN/Prompt.pm` and `Ra.pm`, packaged with the
pinned Perl/Subversion runtime. TortoiseGit's native prompt families include
`IDD_USER_PASSWD`, `IDD_CERTCHECK`, `IDD_SIMPLEPROMPT` and `IDD_PROMPT`.

The bundled runtime's five authentication callbacks use a versioned bounded
base64 JSON askpass request only when GitRepository installs TurtleGit's own
helper. Explicit custom Git askpass settings retain original prompt behavior.
Username/password, username-only and certificate-password requests show the realm,
normal username and secure password fields, optional Save authentication and
OK/Cancel. Save follows the callback's may-save/no-auth-cache flags. Subversion
performs credential caching through its native providers after authentication;
the pinned build requires macOS Keychain and disables plaintext password storage.

Certificate Check carries hostname, issuer, validity dates, fingerprint and exact
Subversion failure bits into a selectable, scrolling native window. Reject is
the default and Escape/close reject. Temporary and Permanent are explicit actions;
Permanent appears only when the callback allows saving. No generic affirmative
answer accepts an unknown certificate. The provider retains the exact failure
mask rather than blindly accepting additional failures.

Client-certificate selection uses an owned file panel. A picker-authorized regular
file is copied into the command's private 0700 folder with 0600 file permissions,
so the already running SVN process can read it without inheriting a separate
helper's file grant. The source is unchanged. That ephemeral filename is not
cached by SVN, and command cleanup removes it on success/failure/cancellation.
Certificate passphrases use the secure native prompt and existing provider policy.

The Git/Perl process group retains and cancels its own helper processes through
the existing command cancellation route; helper windows settle once, clear secret
fields and dismiss owned panels. Invalid structured requests/responses fail closed.
Legacy HTTP/OpenSSH askpass behavior remains separate. Runtime builds retain
native dependency caches, patch only the pinned Perl module, and record the adapter
hash and required Keychain/plaintext policy in the reconstruction manifest.

These windows adapt the source's separate combined/string/certificate forms;
physical keyboard/layout/theme/VoiceOver and signed helper/grant/Keychain acceptance
remain open. Public SVN server authentication and TLS/client-certificate acceptance
require separate tests; simulated callbacks are not a live server acceptance claim.
No whole authentication/App Store or full dialog certification is claimed.

Source CertCheck additionally exposes separately named SHA-1/SHA-256 values and
Open certificate. This SVN adaptation currently carries the SVN fingerprint only;
those source controls remain pending. Four prompt family reviews are partial,
and unmapped controls are retained in the ledger.

The first checkpoint passed the cached runtime rebuild/179-binary install audit,
Debug, fourteen Core tests, shipped Perl callback checks and four native cases.
All owned receivers were reaped. Actual scope and limits are recorded in
[the batch evidence](qa/svn-authentication-2026-10-14.json).
