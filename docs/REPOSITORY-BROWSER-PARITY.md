# Repository Browser parity audit

This is a partial native replacement, not complete TortoiseGit parity.
The pinned source is TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.
The [upstream manual](https://tortoisegit.org/docs/tortoisegit/tgit-dug-repobrowser.html)
and the source/resource controls were reviewed together.

## Source and native mapping

| Source | Pinned blob | Native replacement |
| --- | --- | --- |
| RepositoryBrowser.cpp | ced08d910b48b8c261fe7d131a409d4dc44875ac | RepositoryBrowser.swift, RepositoryBrowserWindow.swift |
| RepositoryBrowser.h | 7d315c6c04315e5251f5bceb1e6725f545bb67bf | Snapshot, entry, lazy directory and window models |
| Commands/RepositoryBrowserCommand.cpp | bba0566a3673b25916b9edfcadd8a6ecb7377710 | App/Finder action and Log-selected revision routing |
| Commands/RepositoryBrowserCommand.h | 6bc4baecacb22d418706bacea7024531ab73ee44 | RepositoryAction.repositoryBrowser |
| TortoiseProcENG.rc IDD_REPOSITORY_BROWSER | See upstream-files.csv resource pin | Read-only Path, revision button, folder tree, contents list, information, OK/Cancel/Help |

Original menurepobrowse, executable, symlink and external overlay icons remain
unchanged; exact source blobs are recorded in the icon provenance manifest.
Normal macOS file-type and folder icons replace Windows shell file-type icons.
Source notices and GPL-2.0-or-later attribution are retained.

## Implemented behavior

The native window follows the source tree-left/list-right arrangement. An AppKit
split controller provides a draggable divider and autosave identifier. The list
has Name, Extension and right-aligned Size columns. The initial 1000×650 content
size was corrected after native testing exposed hidden names at the minimum size.
The revision button opens a single-selection Log sheet; changing its revision
retains the current directory if it exists. Return in the contents table opens
one file or enters one folder; F5 refreshes without overriding an attached sheet.

Directory contents load lazily using NUL-delimited `ls-tree -l`, with exact blob
bytes fetched by object ID. A snapshot pins the peeled revision and root tree so
moving HEAD cannot change an already displayed directory. Annotated tags, bare
repositories, tree object IDs and unborn HEAD are handled. Executable, symlink
and submodule modes remain distinct. Binary files, Unicode, tabs, newlines,
colon-containing directories and pathspec-like filenames are tested. Size and
object hashes come from the tree, not working files.

Folders stay first in both sort directions. Numeric/case-insensitive names use
native comparison. The upstream extension-sort name tie compares the right name
with itself; its subsequent size/name tie order is retained explicitly. macOS
locale comparison and byte-size formatting can differ from Windows.

File menus use the original command icons: Open, Open With, alternative editor,
working-tree comparison, Show log, Blame, Save revision to, Revert to this revision, Mark for comparison,
Compare with marked file, copy names and copy hashes. Directory menus provide
navigation, Log and copying. A marked historical file retains its path and peeled
revision when the browser changes revision; comparison uses the existing native
two-pane editor. An existing scoped working-file mark can also be imported.
The upstream source copies basenames despite the manual describing full paths;
native copying preserves basenames, using LF instead of Windows CRLF separators.

Opening a submodule from a working repository resolves its initialized checkout
and browses the recorded child revision, or offers the existing Update window
when unavailable. Bare/submodule Open With produces the source-style plain text
`Subproject commit <hash>` preview. Historical previews are read-only temporary
files retained by the app; Save writes the exact selected blob bytes. Sandbox
access checks and leases protect reads and historical comparison handoffs.

## Historical drag representations

`RecursivelyAdd`/`BeginDrag` and the historical file-content/descriptors branch of
GitDataObject.cpp were audited. The pinned data-object blobs are
`3ba63178f14e6f9102f87a9a7d97080c8162282c` (cpp) and
`2d75b20c4a079a6eb3feaaea3101ef6fd661ab87` (header). Other consumers and Windows
clipboard formats remain partial, not replaced by this one browser integration.

The native contents table now provides an item provider for each draggable row;
folder-tree labels also provide pinned directory exports. The implementation uses
Apple's [table-row item providers](https://developer.apple.com/documentation/swiftui/tablerowcontent/itemprovider%28_%3A%29)
and [file representations](https://developer.apple.com/documentation/foundation/nsitemprovider/registerfilerepresentation%28for%3Avisibility%3Aopeninplace%3Aloadhandler%3A%29)
with original suggested names and file/folder content types. Generation is deferred
until a receiver requests a representation. This implements native drag data;
it does not establish Finder drag acceptance yet.

The Core exporter reads only the snapshot's pinned blobs into a private temporary
container. A selected folder retains its name and recursive relative paths, while
the displayed directory can be exported for a tree drag. Gitlinks are skipped,
matching the source's IsDirectory descriptor exclusion. Symlink blobs become
regular files containing exact target text; no target is followed. Binary bytes
and unusual names remain unchanged. Empty export selections fail instead of
promising nonexistent files. Exported executable files retain executable bits as
a macOS adaptation to the source's ordinary Windows file attributes.

Load callbacks retain the repository permission on the main actor, revalidate
Store scope and hold exports until app cleanup. The application removes its own
export containers on normal Quit, and active representation loads block Quit.
Progress cancellation is checked at file boundaries; an in-flight Git read is
not terminated. Failed/cancelled generation removes the private partial container.
Window closure can precede completion because the provider retains its own lease
and pinned snapshot. Signed transfers and cancellation/quit timing need acceptance.

Two additional Core integration tests bring RepositoryBrowserTests to nine passing
cases. They verify pinned recursive binary contents after HEAD advances, Unicode/
colon/tab/newline names, plain symlink text, skipped gitlinks, current-directory
export, exact single-file names, explicit cleanup, foreign selection rejection,
pre-cancelled export and unchanged index/working contents. The production provider
was also compiled into a native receiver check: both file and folder NSItemProvider
callbacks delivered exact pinned binary bytes while preserving HEAD/index/working
contents. This is a real Foundation transport check, not a Finder test.
Run `scripts/verify-browser-item-provider.sh`; it creates and cleans up its own
fixture without launching a GUI app. The same receiver check is wired into the
macOS workflow after Core tests; its remote execution is pending publication.
Final Debug/Store builds and bundle audits passed. See [export evidence](qa/repository-browser-export-2026-10-05.json).

## Parent and child submodule history

A single gitlink now has both source commands: Show log opens the selected path
in the superproject at the displayed parent revision; Show submodule log opens
the child repository at the displayed gitlink hash. The child checkout's current
HEAD does not override this hash. The new Core resolution API validates that the
entry belongs to the displayed snapshot, is a gitlink and resolves to the same
recorded hash. Existing child-checkout containment checks remain in effect.

The native handoff shares this resolution with Open. An unavailable Open retains
the Update/Cancel sheet; unavailable child Log shows an explanatory error and
performs no update/fetch. The source child-Log command also does not dispatch
Submodule Update automatically. Bare repositories have no child working checkout;
the native command reports selection unavailability. Reads retain the parent scope
lease, validate Store access and suppress the handoff if the parent browser closes.
The child viewer uses the inherited Git runtime and lease.

Two additional integration tests exercise pinned history after the parent gitlink
and child HEAD move, exact parent/child index and dirty-file preservation, ordinary
entry rejection, missing/unrelated child repositories and bare rejection. Combined
RepositoryBrowserTests/SubmoduleComparisonTests pass 17 cases, zero failures.
Final Debug and Store builds and complete bundle audits passed. These are targeted
checks; no new full-suite run is claimed.

Native acceptance opened Show submodule log at the recorded old gitlink and
confirmed that only the pinned child commit appeared, excluding the newer child
HEAD. Parent and child HEADs, raw index hashes and uncommitted child bytes remained
unchanged. UI observation timed out during the subsequent close; normal Cmd-Q
on the same live process succeeded, and the final process scan was empty. Further
parent-Log, unavailable-Log and Open/update native acceptance remains pending.
No new screenshot was captured. See [submodule evidence](qa/repository-browser-submodule-2026-10-05.json).

## Revert to the displayed revision

For one or multiple selected ordinary files in a working repository, Revert uses
`git checkout --end-of-options <pinned object> -- <literal path>` for each file.
It updates both the index and working file without moving HEAD. Folders, gitlinks,
bare repositories and entries from a different listing are rejected. Destination
validation rejects paths through an ancestor symlink outside the repository or
inside Git administration directories. Argument arrays and literal pathspecs
preserve unusual names. Unlike the status-dialog Revert, this historical command
does not move replaced contents to Trash; that matches RepositoryBrowser.cpp.

Files are processed in displayed selection order. A native per-file error sheet
provides Continue/Cancel, and the final result reports successes, failures and
unattempted files. The source increments its reported count even after a failed
checkout when OK is chosen; the native adaptation reports only successful Git
operations. It restores the displayed pinned object rather than re-resolving a
branch/tag that may have moved while the browser was open. These adaptations
preserve the selected historical content and avoid an inaccurate success message.

Closing/Quitting is blocked during the mutation; quit-confirmation disables
browser actions. Leases remain held through the sequence and each file revalidates
Store scope. Completion refreshes existing Working Tree/Commit/workspace views.
Earlier successful files remain restored if a later file fails or is cancelled,
matching the source's per-file sequence rather than an atomic batch.

## Verification on 2026-10-05

The original four RepositoryBrowserTests exercise tree modes and exact bytes, pinned nested
reads after HEAD moves, annotated tags/bare/tree/unborn handling, sorting and
malformed records. FinderRequestTests adds action/selection URL round-trip and
bare-repository eligibility. The focused browser/Finder/submodule run passed
19 tests; the complete Core suite passed 415 tests, zero failures. These are Core
checks, not a claim that all native dialog behavior is covered. Final window
sizing and comparison wiring were built and checked separately in the native app.

Debug and App Store configuration builds succeeded. Both bundle audits passed:
71 original icon resources, Finder extension and licenses, universal helpers;
the Store bundle additionally includes the audited universal Git 2.55.0 runtime.
This is unsigned build evidence, not App Store signing or acceptance.

Native acceptance used an owned disposable repository with two revisions and a
separate uncommitted file. Return entered src and nested directories; natural
ordering showed file2 before file10. File context commands appeared. A file was
marked at the latest revision, the Log picker selected the older revision by
keyboard, and Compare with marked file opened exact Latest/First historical
contents in the read-only two-pane editor. The mark survived revision changes.
HEAD, raw index SHA-256 and working-file SHA-256 remained unchanged afterward.
The initial pane-width problem was corrected and all columns became visible.
Executable/symlink overlays were inspected in the root view. A real native light
screenshot was saved and inspected; dark-mode acceptance remains pending.
Three additional Revert integration tests now bring RepositoryBrowserTests to
seven passing cases. They verify pinned annotated-tag restoration after the tag
moves, binary/literal names, executable and symlink modes, exact index entries,
unrelated staged preservation, folder/gitlink/foreign/bare rejection, an escaping
ancestor symlink and index-lock failure/recovery. The focused seven-test run
passed with zero failures; the earlier 415-test full suite predates this mutation.
Final Debug/Store builds and audits passed after the new command was added.

Native Revert acceptance used a separate disposable repository with different
staged/working contents. A deliberate index lock produced the expected error;
Cancel yielded zero successes with raw index and both working files unchanged.
After removing only the owned test lock, Revert reported one success and restored
exact HEAD bytes into both index and working file. HEAD, the unselected working
file and unrelated staged file remained unchanged. Continue was activated through
the default error-sheet action, yielding an accurate zero-success result. Native
multi-file error sequencing remains unverified because selected-row context-menu
automation returned ambiguous-element errors; this is not counted as a pass.
The final result screenshot attempt failed with a macOS recording-stream error;
no new Revert screenshot is claimed. The earlier light browser screenshot is kept.
See [Revert evidence](qa/repository-browser-revert-2026-10-05.json).

Every QA app was closed using normal Quit, with a final empty process scan.
See [structured evidence](qa/repository-browser-2026-10-05.json).

![Native Repository Browser at an older revision](site/assets/repository-browser.png)

## Remaining parity work

- Native multi-file Revert menu and partial-success Continue/Cancel acceptance;
  the per-file backend, single-file recovery and rejection cases are verified.
- Actual Finder and other-app drops, multi-selected row drags, tree/root drag
  acceptance and file-object clipboard interoperability. Native historical item
  representations and file/folder receivers are implemented and checked.
- Broader native parent/child Log and initialized/missing child Open/update acceptance.
  Separate child Log and its pinned read-only routing are now implemented.
- Historical tree-object Log/Blame/compare handoffs: listing and blob reads accept
  tree objects, while existing helpers generally expect commits.
- Complete Open With, alternative editor, Save, Blame and working comparison
  acceptance from this window, plus imported Finder comparison marks.
- Persistent column choices, divider/frame restoration, full keyboard selection,
  accessibility and large repositories. Known-empty folders still show disclosure
  arrows; revision refresh can collapse ancestors of the retained current folder.
- Native dark appearance, signed Finder invocation and Store security scopes.
- Full cancellation of underlying Git reads; closed-window generation guards
  prevent late results from publishing but do not terminate an in-flight command.
- Invalid UTF-8 path bytes and nonstandard tree modes need a defined native policy.

The source inventory keeps this dialog and command files partial. The complete
application, all source commands and App Store distribution remain unfinished.

## Pinned restore compatibility and CI receiver check

Browser file Revert now passes the pinned hexadecimal object directly to Git
checkout, followed by -- and the literal path. Git 2.37 rejects checkout's newer
--end-of-options syntax; the restore regression reproduced that failure before
the change. Object validation rejects option-like strings, symbolic revisions and
short hashes before mutation. Both 40-character SHA-1 and 64-character SHA-256
object IDs remain supported. The restore fixture covers moved-tag pinning, binary
bytes, symlink/executable modes, unrelated staged content, unchanged HEAD, index
locks and unsafe/foreign selections, plus a real SHA-256 repository.

The item-provider verification script also had a malformed compiler output
argument joined to a duplicated Python receiver command. It now builds the
receiver inside its owned temporary directory and runs it once with a bounded
60-second timeout. This is the script invoked by the macOS GitHub Actions workflow;
local execution does not establish hosted CI success. No GUI app/Finder instance
is launched by this receiver.
