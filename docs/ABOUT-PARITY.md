# Native About dialog family

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`. Reviewed TortoiseProc's
AboutDlg, TortoiseGitMerge's AboutDlg, Blame's About procedure, IDiff's About
resource and their version/credit controls.

The application About entry and Finder About command now open a native TurtleGit
window instead of the macOS standard About panel. App menu → About Tools opens
separate Merge, Blame, Image Diff and Unified Diff windows. Each uses the renamed
tool title, shared TurtleGit artwork, purpose and upstream attribution. The
[application identity](APPLICATION-IDENTITY.md) records the custom source and
derivatives; earlier screenshots retain their capture-date artwork. Tool variants
share the native layout and show the fork's packaged version information; they
are not separate standalone executable distributions.

The layout retains a prominent icon/title or animated banner, contributor text,
website/source links, selectable Version Information and default OK. The main
application also offers Check For Updates. Copy
Version Information copies the same diagnostic report displayed in the window,
including the host macOS version, architecture and captured selected Git engine. License and Notices open the app's bundled
LICENSE/NOTICE. Missing files disable their buttons. Return activates OK;
Escape and the standard close control close the owned window. Reopening a tool's
About entry reuses its existing window; closing releases its service registration.

Version reports label **Bundled components** and read bounded manifest files
from the application bundle: Git, LFS, SVN/Perl, OpenSSH/OpenSSL and EditorConfig.
SVN/Perl versions use the compact installed-component summary in the Git manifest,
not its much larger file-hash inventory. They retain the pinned TortoiseGit resource
commit when available. These bundled metadata rows never report a custom engine as bundled. A separate
Selected Git row now runs --version using the executable/environment captured
from General preferences when About opens. It does not inspect the current
repository, read credentials or start network work. Unknown,
malformed or over-limit metadata is explicitly reported as unknown. The update
button uses the existing macOS release/App Store adapter when clicked.

Upstream contributor names are labeled as original TortoiseGit/TortoiseSVN
credits, not as authors of this macOS fork. Complete attributions and bundled
component licenses remain available through NOTICE and the packaged source kits.
The source donation/support workflow is adapted to the upstream contributors
link; no donation transaction is performed.

## Evidence and remaining work

Two focused Core tests passed with zero failures, checking captured manifest
versions, source pins, license/notices availability and malformed/oversize fallback.
The unsigned Debug build passed with existing diagnostic noise. See
[the batch record](qa/about-2026-10-12.json).

Initial native checks passed all five window constructions and their injected
routes. Offscreen full-content captures omitted some standard button labels;
they were rejected and are not published. Reviewing their version text found
that the bounded reader skipped the large SVN inventory. The report now reads
its compact installed-version summary and explicitly checks real SVN/Perl versions.

The repaired native receiver passed all five actual windows, including real
bundled Git/SVN/Perl versions, selectable report/private-pasteboard copy, injected
license/notices/update targets, default OK and close callbacks. All owned windows
closed; no installed application, external URL or update request was launched.
The final app build passed. Screenshot acceptance remains open.

Remaining: physical menu/button/keyboard tracking, complete light/dark/resize and
VoiceOver acceptance, singleton multi-window and busy/quit interaction, signed
bundle/source links and complete upstream animated-banner/credits layout. This
is a partial native adaptation, not full application or App Store acceptance.


## Source banners, tool layouts and owned reports — October 17, 2026

The main app and Merge About windows now use the source WaterEffect banner.
The renamed title and original tool/turtle artwork are rendered natively, with
the source eight-neighbor height fields, damping, refraction, color clamp,
alternating pages and pointer/drop disturbances. Native bitmap alpha is retained;
Windows RGB discarded it. Even raster widths and bounded dimensions/input avoid
source out-of-bounds shapes. Native animation follows the source 40 ms cadence
and roughly 1.5 second automatic-drop cadence. Reduce Motion restores the static
artwork and removes the timer. Occluded/minimized/hidden windows pause it; closing
retires timers, observers and tracking areas. Blame/Image/Unified use their own
source-style icon/title/version headers and smaller native layouts.

Original contribution text, version group/scroll view, website, upstream support,
TortoiseSVN attribution and OK retain their source grouping. Copy/license/notices
occupy a separate row so they cannot crowd the source update/OK footer. Effective
native minimum constraints replace the old ineffective contentMinSize setting.
All five windows still report the shared captured app bundle and remain parts of
one native app. The source main About's donation and Merge's contribution links
open those upstream pages only when clicked.

Selected Git checks are asynchronous and cancellation-aware, retain the exact
executable/environment and reject late publication after closure. Repeated reads
while busy are ignored. Quit accounting remains held until the backend actually
settles even if the window has closed. Link controls retain their registered URL;
mutating a button identifier or retaining a foreign/closed control cannot redirect
it. Copy, update and close actions retire once. Tool singleton reuse checks the
exact closing controller, so an old close callback cannot remove a replacement.
Command-C copies the report when there is no selected native text; ordinary text
selection keeps its normal copy behavior.

All 27 source controls across TortoiseProc, Merge, Blame and Image About resources
receive partial mappings. The Unified Diff variant remains a native adaptation
of its source About command rather than a resource dialog. Banner title text is rendered natively as TurtleGit alongside the original
artwork. Pixel/font/retina and all physical pointer/keyboard/VoiceOver/signed bundle
acceptance remain open. The complete crash-reporting subsystem is a separate
unported family; these version reports do not upload anything.

The grouped checkpoint passed cumulatively: five distinct Core cases, 96 frames
against the pinned original C++ implementation, a current Debug app build and the
complete five-window native family with system and bundled Git. The source oracle
initially used an incorrect unsigned Windows color-getter shim; correcting it to
BYTE semantics fixed the oracle without changing the Swift effect. Native repairs
covered the default-button assertion, effective full-width layout/footer, an
injected visibility signal for prohibited test receivers, and original tool icons.
All ten final raw light/dark captures were reviewed; all nine receivers and their
private helper paths were independently absent. Detailed attempts and limitations
are recorded in [the checkpoint](qa/about-source-family-2026-10-17.json).

Actual native timers are exercised, but OS occlusion in an active user session
is not proven by these nonactivating receivers. Captures use Reduce Motion and
are static, not evidence of animated presentation. Retina banner text sharpness,
physical interaction and component-specific APR/APR-util version details remain
open alongside the broader acceptance above. Earlier records cover the static
implementation.
