# Release update checking — implementation in progress

Reference: pinned SetMainPage/CheckForUpdatesDlg at
`7338078f8ddd924b8cddee35f512f2286072136d`. macOS release metadata uses the
[GitHub Releases API](https://docs.github.com/en/rest/releases/releases), rather
than TortoiseGit's Windows version feed and installers.

General now exposes the source weekly automatic-check preference and Check now;
the application menu also offers Check for Updates. Disabling automatic checks
uses an owned confirmation with Abort as the default key action. The preference
shares the existing VersionCheck key with Advanced. Automatic checks run at
startup when due, and a lightweight six-hour timer checks the seven-day deadline
while the app remains open. Failed attempts are throttled too; manual checks
remain available. Documentation-preview app bundles skip automatic checks.

The repository is read from optional TurtleGitUpdateRepository bundle metadata,
defaulting to the verified current origin jfk-solutions/turtle-git-mac. Only
public release metadata is requested, without an authorization token or active
repository data. Stable mode filters draft/prerelease entries; the existing
VersionCheckPreview preference includes published prereleases. Numeric version
components, prerelease ordering and optional v/build suffixes are compared.
Malformed versions produce a visible comparison error rather than an up-to-date
claim. Release links must use HTTPS on GitHub and point to this repository's
release-tag path. Response size and request time are bounded. HTTP/feed failure
and an empty release list have distinct results.

Manual checks reuse one native result window. A manual request during the
background check promotes that request instead of creating a second network
request/window. The result shows installed/available versions, status, changelog,
errors and Open release page. Closing cancels the task and fences stale callbacks.
An automatic check opens a result only for a newer version; it offers Remind me
later and Do not ask again. Changelog content is displayed as plain selectable
text. No executable is downloaded, unpacked or installed by this implementation;
release assets and signed installer/download parity remain to be mapped.

AppStore builds skip GitHub checks and disable the weekly checkbox. Manual Check
now displays the App Store result and opens the installed App Store application.
No undocumented deep-link or unconfigured product ID is assumed.

This continuation is **uncompiled and untested**. The preceding General runtime
controls are also outside the prior passing Settings/Tools checkpoint. Version/
prerelease/feed/rate/error/cancellation tests, actual repository public releases,
window reuse/close/confirmation, timer/date changes, preview preference behavior,
installed App Store opening, native keyboard/visual acceptance and signed sandbox
network execution remain in the next grouped General validation. A production
release feed, release assets/signatures, localization and complete First Start
Wizard remain open. Inventory counts are unchanged; no dialog is newly certified.
