# Native About dialog family

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`. Reviewed TortoiseProc's
AboutDlg, TortoiseGitMerge's AboutDlg, Blame's About procedure, IDiff's About
resource and their version/credit controls.

The application About entry and Finder About command now open a native TurtleGit
window instead of the macOS standard About panel. App menu → About Tools opens
separate Merge, Blame, Image Diff and Unified Diff windows. Each uses the renamed
tool title, original artwork, purpose and upstream attribution. Tool variants
share the native layout and show the fork's packaged version information; they
are not separate standalone executable distributions.

The layout retains a prominent icon/title, contributor text, website/source
links, selectable Version Information, Check For Updates and default OK. Copy
Version Information copies the same diagnostic report displayed in the window,
including the host macOS version. License and Notices open the app's bundled
LICENSE/NOTICE. Missing files disable their buttons. Return activates OK;
Escape and the standard close control close the owned window. Reopening a tool's
About entry reuses its existing window; closing releases its service registration.

Version reports label **Bundled components** and read bounded manifest files
from the application bundle: Git, LFS, SVN/Perl, OpenSSH/OpenSSL and EditorConfig.
SVN/Perl versions use the compact installed-component summary in the Git manifest,
not its much larger file-hash inventory. They retain the pinned TortoiseGit resource
commit when available. They do not
run Git, inspect the current repository, read user credentials, report a custom
PATH tool as the bundled engine or start background network work. Unknown,
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
