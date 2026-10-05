# Finder two-file Diff

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
`ContextMenu.cpp`'s Diff dispatcher passes the first selection as `/path` and
second as `/path2`; `MenuInfo.cpp` admits two targets without the folder flag,
including files outside repositories.

Finder now exposes Diff for two outside files and retains their ordered absolute
paths in the immutable request. Repository-dependent commands stay hidden there.
File/folder selections do not satisfy this source alternative.

The app routes a two-path Diff before repository acquisition/session opening.
`WorkingFilePairAccess.prepare` creates a direct working-file comparison and
acquires a grant for each file through the existing comparison permission flow.
Each grant must contain its target; App Store mode also requires a live security
scope. Both checks precede file reads. Cancelling either permission picker aborts
preparation and releases acquired leases. The native comparison window model
retains both leases, independently of the active repository session, and checks
access again on loading/saving. Closing releases its retained controller through
the existing window-close callback.

The first selected file is the base pane and the second the destination pane.
Both use current working bytes rather than Git HEAD/index snapshots. Existing
text encoding, binary preview, save, stale-content safeguards and unsaved-close
behavior come from the shared file comparison viewer. No comparison mark is
created or consumed and no repository switch is required. Single-target Diff
retains the existing working-change route.

## Verification and limits

Core tests exercise a Finder URL round trip with Unicode/newline/literal names,
ordered raw BOM/binary bytes, subsequent live changes, independent folder grants,
lease lifetime/release, cancellation of the second grant, wrong/unavailable grants,
non-sandbox access, invalid counts/duplicates, directories and missing files.
A real repository fixture also verifies current UTF-16 working bytes are read
while staged index bytes and HEAD remain unchanged. Four new cases, the earlier
39-test comparison/request/rules run and nine access regression tests pass.
Debug and unsigned AppStore builds, both bundle audits and site generation pass.
The actual extension menu builder receiver verifies two outside files expose only
Diff with the captured ordered paths, excludes a file/folder pair and preserves
source ordering and artwork. It activates no extension/controller/window.

The app route and shared window integration compile in Debug and unsigned
AppStore configurations. This is not native menu activation or signed sandbox
acceptance. Actual Finder clicks, permission pickers, window close/save gestures,
Shift's alternative-tool behavior and full visual comparison with TortoiseGit
remain pending. Symlink preview still uses the shared viewer's link-target text;
Windows external-tool symlink equivalence requires separate acceptance.

Evidence is recorded in [the verification record](qa/finder-two-file-diff-2026-10-06.json).
