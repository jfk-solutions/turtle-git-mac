# Release update checking and downloads

Partial source review against pinned SetMainPage/CheckForUpdatesDlg at
`7338078f8ddd924b8cddee35f512f2286072136d`. macOS release metadata uses the
[GitHub Releases API](https://docs.github.com/en/rest/releases/releases),
adapting the Windows version feed and installer workflow.

General and the application menu expose Check for Updates. The source weekly
automatic preference shares VersionCheck with Advanced; startup and a six-hour
timer check the seven-day deadline. Manual checks can promote an existing
background request without duplicating it. Explicit quiet, visible and Force
commands retain their separate presentation policies.

The configured public repository supplies bounded release metadata and validated
GitHub release links. Stable/preview preferences, numeric version comparison,
malformed versions, empty feeds and request failures have distinct results.
Changelog text, a checked file list, per-file status, progress, Abort, retry and
Finder reveal adapt the source result/download hierarchy. Verified files publish
without overwriting existing files; completed files survive a later failure or
Abort. No installer or downloaded executable is launched.

App Store builds do not check or download GitHub releases. Only a configured
public Store listing enables the Store action; local test builds do not imply
published Store availability. The dated continuations below distinguish focused
validation from public-network, installed, signed and complete-source acceptance.

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


## Download list, stable feedback and chooser drainage — October 31, 2026

The pinned CheckForUpdatesDlg initializes a two-column report list without
column headings, with checkboxes and a visible border (`CheckForUpdatesDlg.cpp`
115–117; `IDD_CHECKFORUPDATES/IDC_LIST_DOWNLOADS`). The native result now uses a
bordered alternating file list, keeping filename/selection and per-file status
aligned. Exact asset IDs, captured selection generations, unavailable digest
rows and already-downloaded files retain their existing eligibility rules.
Long filenames keep a full-name tooltip.

Feedback has a reserved scrollable area, and Download/Abort/Show in Finder share
a fixed-height operation band. Loading, errors, verification status and retry
do not insert rows above the list or change its operation band's height. The
window's minimum size accounts for those controls.

The native destination chooser starts at the account's Downloads folder, uses
the owner's appearance and supports exactly one directory. Its completion is
single-use and retains the request until both panel and parent report physical
sheet detachment. Abort and forced owner close cancel accepted work without
launching a transfer from a late chooser reply. Controller retirement waits for
its actual feed, chooser or download worker; reopening Updates during that drain
creates a fresh owner rather than reviving a retired one. Existing per-request
progress fences and non-overwriting file verification/publication are unchanged.

Help and F1 now open the bundled [update guide](RELEASE-UPDATES.md), covering
manual/weekly checks, checked files, destination permission, Abort/retry, Finder
reveal and the separate unpublished Store-build state.

The [combined checkpoint](qa/utility-workflow-batch-2026-10-31.json) passes the
Debug build and source/lifetime native cases. Actual native list/scroll/group
geometry remains stable across operation states; hidden chooser, retirement,
verification and stale-callback checks pass. The prohibited receiver has no
SwiftUI semantic accessibility tree: native toggle gestures, labels/IDs and
VoiceOver are unverified. Retained fixture observation failures and the final
native-geometry fallback are recorded explicitly. Public CDN behavior, signed
delivery, physical acceptance and complete source parity remain open.
