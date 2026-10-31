# Blame File Open source comparison

Pinned upstream: `7338078f8ddd924b8cddee35f512f2286072136d`.

## Source and native workflow

`TortoiseGitBlameENG.rc` exposes File Open, four recent files, Settings and Exit.
`TortoiseGitBlameDoc::OnOpenDocument` reuses the SDI document, defaults subsequent
Open to HEAD and registers only successful HEAD documents in MRU. Save/Save As
strings are unused standard resources, rather than missing Blame export commands.
The native adaptation uses File Open, Recent Files, Settings and Close.

Owned file/repository-folder sheets capture grants before Git discovery. Cancel
and failed permission/Git reads retain the current document, window and recent
list. Preparing a document blocks ordinary Close and holds Quit ownership.
Cancellation waits for actual readers; forced retirement cancels owned processes
and fences late picker/data replies. Successful preparation pins the HEAD blob,
annotations, project history metadata and options before replacing the same
native window. Existing modeless Find state rebinds to its replacement; source
callbacks from the old document retire. The repository registry updates identity
while retaining independent windows for the same file.

The private four-file archive stores scoped bookmarks and relative repository/file
locations. Atomic replacement uses mode0600. Restored/moved grants are revalidated,
renewed on successful reopening and retain their record identity. Invalid or
corrupt archives are refused. Blob reads use rev-parse, literal NUL-delimited
ls-tree and cat-file, without a whole-tree diff. Blob/blame/history reads retain
cancellation and exact bytes. HEAD remains the requested identity for Reload;
displayed snapshots pin their historical data. Reads do not mutate HEAD/index or
working files.

## Recent-history publication continuation — October 31, 2026

The [connected checkpoint](qa/blame-recent-publication-2026-10-31.json) records
initial/replacement publication, independent recent-save warnings, captured
model/document/lease ownership, historical exclusions, retained-byte recovery and
selected literal-file Services behavior. One Debug build and the File Open/recent-history and literal-file Services
cohorts pass with system and bundled Git. Only the Services fixture repeated after
an access-level compilation repair; the passing build/Open cohort and unchanged
Core suite were not repeated. All five owned receivers are absent. These private
checks are not complete hosted or signed acceptance.
The older Services assertion combined filename, snapshot and error predicates.
Its message alone did not establish whether the literal filename was lost or a
loaded document later reported a recent-history save failure.

## Historical checkpoint — October 13, 2026

The following results describe that dated source, not a certification of later
source or every File/Edit/View/global-menu/accessibility state.

Debug and AppStore builds and both distribution audits passed. The focused Core
scope passed collectively: 27 existing Blame/presentation checks passed in the
initial run, and the new direct-read/cancellation test passed after its fixture
accepted the established Git cancellation error type. That test holds/reaps each
of rev-parse, ls-tree, cat-file, blame and history reads and refuses a whole-tree
diff dependency. Only the failed Core case was repeated.

Eight grouped native File Open/Find/source/wrap cases passed with system and
packaged Git. Initial File Open verification compared directory URL strings with
and without a trailing slash; canonical-path comparison repaired the fixture while
retaining all replacement/permission assertions. Native coverage includes retained
Find drafts, HEAD Reload after a new commit, two owned paused-read Cancel/retirement
paths and simulated moved recent grants. Process/window ownership and detailed
limits are in [batch evidence](qa/blame-file-open-2026-10-13.json). No new screenshot
or complete global-menu/registry/signed acceptance is inferred from these checks.


## Remaining acceptance

Physical picker/keyboard input, real signed bookmark relocation, source layout,
accessibility, minimum-macOS/Intel execution and full hosted integration remain
separate gates. The current private fixtures do not prove responsiveness of
synchronous bookmark resolution on every external volume. No additional product
deadlock was demonstrated by that limitation.

## Linked-worktree authority continuation

The separate narrow-grant gap identified after the recent-warning checkpoint has
an implemented [authority workflow](qa/blame-linked-authority-2026-10-31.json).
Recent entries retain bounded primary and related metadata bookmarks, and the
File Open/Recent owner prepares missing Git/common/object-store permissions before
Git discovery. Primary working-folder containment remains unchanged. Initial file,
repository-folder and metadata choices retain one captured owner and wait for
physical sheet detachment before handing off; cancelled, replaced or closed owners
cannot start late Git reads. The connected editor checkpoint records its actual
validation separately; these source changes are not signed/physical acceptance.
