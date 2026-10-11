# Native SSH key generation — implementation in progress

The source FirstStartWizardAuthentication's Generate PuTTY key action launches
puttygen.exe. TurtleGit replaces that Windows utility entry with an owned native
OpenSSH key-generation window. It is also available from the application menu,
where repeated requests reuse one window. The wizard blocks navigation while its
key-generator sheet is open and retires that child on forced closure.

The Parameters group exposes Ed25519, RSA (2048/3072/4096) and ECDSA
(256/384/521), comment, passphrase and confirmation. Browse selects a destination
folder so Git's private/public pair and staging directory are covered by one
folder access lease. Filename defaults follow the selected algorithm. Generate
clears the native secure fields when it captures the request. Results show the
public key and SHA256 fingerprint, Copy public key and Show in Finder. Empty
passphrases produce an unencrypted key. Generated keys are not silently added to
the login agent or a repository; existing Remote key-file settings can select them.

The Core operation uses bundled ssh-keygen when available, system fallback only
in desktop builds, and no external fallback for App Store builds. It uses a
private 0700 staging directory inside the selected folder. Encrypted generation
passes its phrase through the existing bundled askpass helper using a private
0600 envelope, rather than argv or environment values. The dedicated keygen
protocol permits the two exact passphrase prompts; the Core operation removes
the reusable envelope and staging directory on success, failure or cancellation.
The existing agent protocol still consumes its envelope exactly once. All
helper input owner/mode/type/size/UTF8 checks remain in place.

Cancellable process groups stop ssh-keygen and its helper children. Private/public
files are complete before publication; exclusive same-volume hard links refuse
existing files, including symlinks, without an overwrite prompt. If public-file
publication fails after the private link, rollback checks inode identity before
removing the owned private link. Private files receive 0600 and public files 0644.
Close is guarded during generation; Cancel generation signals the active token.
Forced closure cancels work and fences result presentation. Active operations
block application termination until child cleanup completes.

The credential-settings continuation and key-generation work are being validated
as one authentication batch. Native screenshots/layout/theme/focus, physical
folder/save/cancel ownership, signed sandbox execution and every algorithm/bit
choice remain to be verified. This is not full PuTTYgen utility parity: import/
conversion, changing an existing key's passphrase/comment and third-party key
format interoperability remain open. Inventory certification is unchanged.

## Grouped authentication checkpoint — 2026-10-11

Credential settings and native SSH key generation were validated together. Debug
Xcode build exited 0. AuthenticationSettingsBatchTests, SSHAskpassTests and
GeneralSetupBatchTests passed: 17 tests, zero failures, 20.638 seconds. Coverage
includes live Git scoped writes, preservation of other URLs/includes/unknown
keys, helper reset chains, implicit versus explicit-empty booleans, stale save/
remove rejection, simple helper/None replacement, invalid-write refusal, plain
and encrypted Ed25519 generation, exclusive publication, file permissions,
fingerprint, private staging cleanup and existing one-use agent-helper behavior.
Real encrypted output was loaded into an owned private agent with its phrase;
loading without a phrase failed. Pre-cancelled requests publish nothing. No app
was launched and no full suite was rerun.

Xcode emitted existing warnings and four unusual SwiftCompile diagnostics
reporting exit code 0 with no output; this is not a clean diagnostics claim.
Native layout/keyboard/theme/owned sheets, live generation cancellation,
publication races, all algorithm/bit choices, read-only simplification,
partial-write failures and signed sandbox acceptance remain open. Logs and
limitations are in `qa/authentication-settings-batch-2026-10-11.json`.
This supersedes the uncompiled/untested statements above. Full-port and inventory
certification remain unchanged.
