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
