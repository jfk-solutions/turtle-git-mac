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
file's edited helper/username/useHttpPath keys; other URL sections and unrelated
keys remain intact. Editing Use HTTP path component to unchecked unsets that
origin's key, restoring inheritance, as in the pinned source. Untouched boolean
entries are retained verbatim. Explicit Add New/Save confirms replacing an
existing configuration and writes all known fields. Remove
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


## Settings transaction and selection ownership — 2026-10-12

Helper selection now owns a single pending operation, so repeated clicks cannot
open overlapping discard prompts. Retirement releases that operation and fences
its response even if the same page is activated again. Save and Remove check the
captured generation before requesting permission following confirmation; advanced
Apply also enforces the same writable-target restriction as the visible Save
button. Simple replacement checks retirement before starting configuration writes.

The Debug build exited 0. The expanded object-linked Credential receiver passed
with both system and bundled Git, one compilation and two reaped processes. It
also exercises the shared Settings participant: Apply, destination-only Cancel,
invalid-helper validation and Cancel recovery. An actual external Git edit rejects
stale native Apply and remains preserved. A held selection confirmation plus a
second click creates only one confirmation; its accepted late response cannot
replace the selected group or unsaved draft after deactivation/reactivation.
This native-only extension did not rerun Core tests. Real native sheets, keyboard
acceptance and signed deployment remain unverified.

## Source inputs and coherent refresh — October 17, 2026

The source URL, Helper and Username labels now remain visible with populated
fields. Helper uses an editable native combo with installed helpers in its
completion/dropdown list, replacing the separate text-field/menu arrangement.
Selecting a group preserves its complete helper/reset chain; an explicit helper
edit intentionally replaces that chain with the entered value. Field callbacks
capture the accepted editor identity, so a removed/replaced/retired field cannot
edit a different group after reactivation. Cached page activity is observable and
restores the enabled state when the page returns.

The Helpers list follows source title sorting, distinguishes the known XDG origin
with its source X prefix and provides each group's full file/origin tooltip.
Native locale sorting may differ from Windows. Config type and HTTP-path controls
retain the existing scoped write behavior. The independent Keychain Access entry
now stays available in simple modes, matching `EnableAdvancedOptions`, which does
not disable the source Windows Credential Manager button. Saved SSH Authentication
remains a separate native addition.

Refresh collects configuration-file origins, credential entries and installed
helper metadata before changing the accepted display. Failure/cancellation keeps
the previous accepted origins/list/mode/draft. Refresh refuses unsaved edits. If a
selected group disappeared externally, successful refresh clears that selection
and its saved draft rather than retaining a valid-looking helper that could
recreate the removed credentials. Unknown list identities cannot clear a current
group. Source-ordered immediate Add New/Save/Remove and property-sheet Apply/Cancel
remain distinct.

A helper-selection/discard question owns a single selection request, Settings
close/page-switch and application Quit. Duplicate selection clicks share one
question. Retirement releases the modal request and fences late responses,
including when the same page is activated again. Read tasks retain their separate
read/access lifetime. Authorized configuration writes retain their existing
independent save/drain policy.

All eighteen `IDD_SETTINGSCREDENTIAL` controls have recorded partial mappings.
The two Windows administrator/elevated-relaunch controls are platform adaptations:
macOS uses existing configuration-folder authorization and reports unwritable
system configuration; it does not install a privileged helper or promise elevated
system writes. The credential-manager action maps to Keychain Access. These
adaptations are not full Windows elevation equivalence or App Store acceptance.
Four grouped native case/engine combinations pass with system and bundled Git. Both raw light/dark page captures were individually reviewed: labels, editable Helper, list, actions and footers fit without clipping. All four owned receivers were reaped and independently absent. Core algorithms were unchanged and their suite was not repeated. Physical keyboard, signed Keychain/Finder and complete upstream acceptance remain open. See [batch evidence](qa/credential-source-family-2026-10-17.json).


## Advanced editing and source Save/Apply — October 18, 2026

The advanced editing family now separates partial property-sheet Apply from
explicit Add New/Save. This supersedes the earlier full-field Apply and explicit
false override behavior. Existing helperless groups accept username/HTTP-path
edits; unrelated raw/repeated fields and included origins remain untouched.
Selection provides the source Save/Discard choices, with an additional native
Cancel action. All editor/list callbacks capture their accepted editor identity.

Implementation details, source references, proposed grouped verification and
remaining acceptance gaps are recorded in
[CREDENTIAL-ADVANCED-EDITING-PARITY.md](CREDENTIAL-ADVANCED-EDITING-PARITY.md).
The October 18 extension has not yet passed its grouped checkpoint; earlier
receipts establish their stated historical coverage only.
