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

## Source downloads and native ownership — October 17, 2026

The source source/version/result/link, Change log, Download/list/progress/action
and Close/automatic opt-out hierarchy now has a native counterpart. Published
GitHub release assets retain names, sizes, state and optional SHA-256 digests.
The Mac application archive starts checked; other eligible files can be checked
independently. Missing/invalid digests, unuploaded files and files outside the
one-GiB bound remain visible but cannot use the in-app download. The website
link remains available. Old release metadata without assets is still supported.

The metadata and file URLs must belong to the configured repository and release
tag, with literal safe names, unique identities/names and HTTPS links. Downloads
use a private URLSession without shared credentials/cookies, bounded request and
resource times, GitHub HTTPS redirects, byte/size bounds and SHA-256 verification.
See [GitHub asset metadata](https://docs.github.com/en/rest/releases/assets) and
[Apple download delegates](https://developer.apple.com/documentation/foundation/urlsessiondownloaddelegate).
This digest checks public-feed integrity; it does not independently authenticate
the publisher or replace macOS code signing.

A native folder sheet owns one checked batch. The folder's security scope remains
live through verification and accepted file publication. Files download into a
private staging directory; complete files publish via a private same-volume sibling
and a non-replacing hard link. Existing files are preserved. Filesystems without
hard-link support report a destination error. Multi-file batches retain completed
files when a later file fails or Abort is requested; checked failed files can be
retried. The final button reveals downloaded files in Finder. It does not unpack,
launch or install executable code. Windows installer execution, independent release
signatures and signed macOS installer/update acceptance remain open.

Progress/selection/Abort and late results are scoped to the captured owner and
request. Normal Close waits for downloads; Abort cancels owned chooser/transport
work, while Quit accounting remains until actual tasks drain. Forced close retires
delivery and keeps accepted file work/scopes alive to completion. Manual release
checks now retain that same independent accounting. Preferences and channel are
captured from the model's own store; automatic opt-out does not write another store.
App Store builds never check/download GitHub assets and use the installed App Store.

All thirteen static resource controls have partial mappings. The Debug build, nine focused Core checks and both grouped native families pass. Core covers metadata/eligibility, old feeds and duplicate assets, real URLSession transport through a private URLProtocol, cancellation, digest/size rejection and non-overwriting file publication. Native checks cover captured feed/defaults, native/injected folder cancellation, two verified file installs, existing-file and digest failure, held request drain, late replies and App Store isolation. Initial captures exposed unbounded hosting growth; disabling automatic host sizing repaired it, and the affected source case passed again. All four final raw light/dark captures were individually reviewed, and all three owned receivers were reaped and independently absent. See [batch evidence](qa/release-download-family-2026-10-17.json) for exact scope and limits. Actual public-network/CDN
behavior, large-file/mount/permission boundaries, independent signatures, signed
Finder/App Store deployment and full dialog parity remain unverified.

## Explicit utility commands and result visibility — October 18, 2026

Source `updatecheck` now reaches the native service without Git/repository
requirements. `visible` shows the check and all results; an ordinary quiet command
shows only an available release. Explicit checks bypass the automatic scheduling
preference/deadline. A visible request promotes the current background model;
repeated commands retain its window, generation, selections and accepted work.

Source `force` treats a valid published equal/older version as available. It can
promote an in-flight check or an already-displayed result without refetching or
replacing download state. Normal up-to-date results now hide/disable source
download controls; Force makes them available. Malformed versions, feed/URL/asset
validation and verified non-overwriting downloads retain their existing gates.
The message distinguishes forced availability from a genuinely newer version.

Automatic results retain the weekly preference gate; explicit quiet results are
independent of it. Quiet result footers offer Remind me later/Don’t ask again only
when the owning store enables automatic checks; visible/forced results use Close.
Promoting an already-displayed automatic result updates only that footer; its
model, generation, selected files, status message and accepted work remain. Pending hidden checks own a model and active counter through
actual cancellation drain. Late retired replies cannot create a result window.
App Store quiet checks finish without a background request; visible/forced checks
show the Store result and cannot enable GitHub downloads.

See [service command evidence](qa/service-commands-2026-10-18.json) for exact local
scope, retained download/lifetime checks and remaining public CDN, physical,
signed and complete-source acceptance. No installer/code execution is added.


## Explicit publication availability — 31 October 2026

The App Store build flag is now separate from an optional validated publisher
listing (`TurtleGitAppStoreListingURL`). No listing is supplied by default. Initial
and manually reopened Store-compatible review windows say that no listing is
configured; they neither claim installed local candidates have Store-managed
updates nor open `com.apple.AppStore` generically. Only a configured public
`https://apps.apple.com/.../id...` page enables the Store action. Direct build
release checks, asset verification, cancellation/retirement and preference policy
remain intact. About reports **Build configuration** and gates the same page using
the shared availability model.

The [grouped validation record](qa/utility-distribution-ownership-2026-10-31.json)
records a passing Debug build and two focused ApplicationDistribution Core methods
for optional metadata, build/listing separation and rejected URL forms. About
source/availability/retirement passed against system and bundled Git; release
lifetime/listing/quiet-versus-forced ownership passed its native receiver. Existing
utilities/reopen, command diagnostics and selected-file Services checks also
passed their recorded scopes, with owned receivers reaped. Only affected reopen
cases were repeated after the retained fixture failures; full Core was not rerun.

These checks cover initial unavailable state, disabled/guarded About action, exact
configured URL dispatch, retired-owner refusal and no Store-mode GitHub fetch or
download. Private homes/preferences and captured browser callbacks do not certify
public Store publication/purchase, physical utility interaction or complete hosted
CI. Installed signed44 predates this family; its close/observe reopening was
temporally ambiguous and is not proof of active-owner causation.

A quiet or automatic background network check is not a utility-window owner.
Only an actual controller, synchronous presentation construction or a deliberate
forced pending presentation fences workspace reopen. Cancellation drops that
presentation intent immediately while the actual fetch remains in worker/Quit
accounting until it returns. The lifetime fixture holds quiet/forced checks,
asserts the negative/positive ownership distinction, then cancels/drains both
without a late window.
