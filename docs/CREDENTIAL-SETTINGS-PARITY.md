# Git credential settings — implementation in progress

Reference: pinned SettingGitCredential.cpp/.h, Settings.cpp and
IDD_SETTINGSCREDENTIAL at 7338078f8ddd924b8cddee35f512f2286072136d.

The native Git → Credential page follows the source structure: simple helper
selector above the Helpers list, with Config type, URL, editable Helper,
Username, Use HTTP path component, Add New/Save and Remove beside it. Installed
macOS helpers replace Windows-only wincred/winstore choices. Local, Global and
System choices appear when their files are available. Keychain Access replaces
the Windows Credential Manager entry. The original gitcredential.ico is copied
with its hash recorded in the icon provenance manifest.

The Core reader uses Git's scope/origin/NUL output, retaining ordered repeated
helpers, empty helper resets, usernames, HTTP-path settings, unknown credential
fields and included/XDG/system/worktree origins. The list groups entries by
scope, exact file and URL. Selecting a group preserves its helper chain until an
explicit helper edit replaces it. Advanced writes affect only the selected
file's helper/username/useHttpPath keys; other URL sections and unrelated keys
remain intact. False HTTP-path writes are explicit, so a higher-level true value
is overridden. Add New/Save confirms replacing an existing helper chain. Remove
confirms before clearing that URL's known and unknown credential fields in the
selected file. Passwords held by credential helpers are not deleted.

Simple choices replace all listed credential settings with one selected default,
or clear them for None, following the source simplification behavior. A native
confirmation describes the URL/username replacement. The backend checks the
loaded snapshot before changing it and preflights all affected files for write
access. Command-scope/read-only entries prevent simplification rather than
silently retaining conflicting configuration. Per-file Git locks serialize each
write; multi-key/multi-file changes are source-ordered and are not atomic.
Advanced save/remove also reject stale snapshots. Later failures report earlier
writes where the shared Git configuration failure type is used.

Add New/Save and Remove save immediately, matching the source. Property-sheet
Apply saves pending fields or the selected simple mode; Cancel restores only
unsaved fields. Cached hidden pages can apply through the owning Settings window.
Repository-context changes remove the cached credential participant. Saves block
Settings page switches, ordinary closure and application termination. Authorized
writes may finish after forced owner closure, with late presentation fenced.
Reads use cancellation/generation checks; owned permission and confirmation
sheets are dismissed and answered once on retirement. System configuration does
not launch a privileged helper: a writable authorized file is required.

The First Start Wizard's Advanced configuration button now opens this page as an
owned native sheet with OK/Cancel/Apply. While open, wizard navigation is blocked.
Closing reloads the effective helper choices and advanced state without changing
identity fields. Retiring the wizard retires its credential child too.

This section is **uncompiled and untested**. It was implemented as one large
backend/UI/integration batch. Builds, focused tests and native launches are
deferred to the authentication section boundary, including the remaining native
SSH key-generation workflow. The earlier General/setup checkpoint does not cover
these changes. Outstanding validation includes exact source layout, theme/focus,
keyboard/selection prompts, simple and advanced saves, includes/XDG/worktree,
helper-chain/reset ordering, Git boolean edge cases, no-repository contexts,
external edits and partial failures, owned-sheet closure and signed sandbox
permissions. Credential helper availability and Keychain Access lookup need
native acceptance. No inventory dialog is newly certified.

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


## Native scoped saves and lifecycle checkpoint — 2026-10-12

Config type changes now count as unsaved edits, including changes with identical
helper fields. Cancel restores the saved destination. Explicit Save copies the
captured draft into the chosen destination without deleting the original group.
Settings validation rejects unavailable simple helper/scope choices. Late reads,
selection confirmations and errors are fenced by the page generation; authorized
Apply completion after closure does not reactivate the page or reload credentials.
Password-manager routing and file/confirmation/read/write seams allow private
native checks while retaining the production adapters.

Debug build exited 0. Eight AuthenticationSettingsBatchTests passed with zero
failures in 3.206 seconds. One cached object-linked receiver compilation ran two
owned processes, one each with system and bundled Git; both exited 0 and were
reaped. Checks covered ordered helper reset/chain import, destination-only copy
and Cancel, accepted/rejected replacement/discard/removal, unknown-key retention,
simple None and unavailable helper validation, forced-close Apply, retired read,
Aqua/Dark Aqua host construction and injected password-manager failure. Private
global/XDG configuration and repositories were used; no credential helper, user
Keychain or network was invoked. No full Core/reference suite was rerun.

The resource is now partial-native-replacement, not certified complete. Physical
layout/keyboard/selection acceptance, real owned sheets, all helper availability
variants, includes/worktree/no-repository native flows, partial-write native
failures, production Keychain and signed sandbox/App Store acceptance remain open.
No new screenshot or full hosted CI pass is claimed.
