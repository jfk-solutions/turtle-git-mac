# General settings — implementation in progress

Reference: pinned SetMainPage.cpp and IDD_SETTINGSMAIN at
`7338078f8ddd924b8cddee35f512f2286072136d`.

General now uses an application group and Git for macOS group instead of only
appearance controls. The application group exposes the installed English UI and
shared System/Light/Dark draft. English is currently the only implemented UI
translation; other languages are not offered as if translated.

The Git group provides automatic/bundled, system and custom engine selection,
Git executable path, owned native Browse, Extra PATH, version Check now and Show
Environment Variables. Custom selection replaces the Windows Git.exe folder
setting with a macOS executable file. Selected file bookmarks resolve without UI;
access leases remain alive for engines captured by repositories and open dialogs.
Custom engine selection is validated by running `git --version` in private app
temporary storage, with draft runtime environment, before Apply saves it.
Version checks are cancelable and fence callbacks when the page disappears.
The environment viewer is an owned read-only native sheet, supports selection,
and shows the effective draft process variables without writing them to logs or
files. Shared property-sheet Apply/Cancel owns the preference draft.

Runtime selection is consumed by GitRuntime.executable for newly created
repositories. Existing repository objects retain their captured engine, matching
the source restart requirement; the UI asks the user to reopen after changes.
Extra PATH augments the runtime PATH, preserving bundled Git/SSH precedence.
Its entries must be absolute directories and cannot introduce empty/current-
directory components. With no extra directories, existing external-engine
behavior remains unchanged. No shell evaluates the configured path.

The AppStore build ignores custom/system engines and Extra PATH. It retains the
existing requirement for bundled Git and SSH; these controls are disabled and
show the automatic selection. This implementation does not turn folder access
into permission to execute an unbundled engine in the AppStore sandbox.

This continuation is **uncompiled and untested**. The previous grouped build and
four tool tests do not cover it. Runtime-selection, bookmark moves/renewal,
PATH precedence, validation failures, native Check/Browse/environment ownership,
Apply/Cancel, reopened repositories, Finder/background engine boundaries and
signed sandbox checks remain in the next combined General-section validation.
Language assets/localization, weekly release checking/Check now, full First Start
Wizard and Windows Create Library's macOS adaptation remain pending. No inactive
controls are presented as those implemented features. General is not certified
and inventory counts remain unchanged.

## Weekly update check continuation (uncompiled and untested)

The weekly preference and Check now are now connected to a native release-check
window and GitHub release metadata for this fork. AppStore builds open their
managed-update result instead. See [Release updates](RELEASE-UPDATES-PARITY.md)
for request/version rules, owned windows/confirmation, remaining source installer
scope and grouped acceptance. The pending weekly-check statement above describes
the previous checkpoint; both General continuations remain unverified.

## First Start Wizard continuation (uncompiled and untested)

General's Re-run First Start Wizard and the application menu now open the native
five-stage manual setup flow. See [First Start Wizard](FIRST-START-WIZARD-PARITY.md)
for source-ordered saves, credential preservation, permission ownership and the
remaining automatic-first-run/key-generation/Advanced/native acceptance scope.
This and the preceding General/update work await grouped validation.

## Grouped General/Updates/Wizard checkpoint — 2026-10-11

Debug Xcode build exited 0. The focused GeneralSetupBatchTests, GitRuntimeSSHTests
and GitConfigurationTests group passed: 13 tests, zero failures, 3.018 seconds.
Coverage includes selective identity saves, preservation of includes/scoped
credentials, validation before writes, idempotent helper clearing, engine
preference persistence, PATH validation/precedence and App Store isolation,
version/prerelease ordering, malformed tags, feed filtering and unexpected links.
No app was launched and no live release request was tested. Xcode emitted existing
warnings and six unusual SwiftCompile diagnostics reporting exit code 0 with no
output; this is not a clean diagnostics claim. Logs and remaining acceptance are
in `qa/general-setup-batch-2026-10-11.json`. Native visual/keyboard/ownership, live
network, bookmark renewal and signed sandbox acceptance remain open. This
checkpoint supersedes the uncompiled/untested statements above. Inventory is
unchanged; no dialog is newly certified.
