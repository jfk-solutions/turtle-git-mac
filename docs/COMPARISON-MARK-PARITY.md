# Comparison marks: app and Finder

This is an in-progress source port, not a claim of complete DiffLater parity.
The native historical Log mark/compare route is recorded separately in
[Log parity](LOG-PARITY.md). Finder's shared working-file command route is implemented; signed Finder
activation and end-to-end menu acceptance remain pending.

## Upstream behavior

Audited pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`:

- `src/TortoiseShell/ContextMenu.cpp:590–604` changes DiffLater's label to
  Compare with and compacts the saved absolute path.
- `ContextMenu.cpp:1350–1371` sets a mark on the first single-file invocation,
  invokes file Diff with the current and saved paths on the next invocation,
  then removes the external mark. Control clears it; Shift requests an
  alternative comparison tool.
- `src/Git/GitStatusListCtrl.cpp:3170–3179` imports a changed external mark as a
  working-copy path, including marks outside the current repository.
- `GitStatusListCtrl.cpp:2155–2166` keeps a dialog-local historical mark after
  comparison, but consumes an external mark if that saved path is the one used.

Windows registry state must become app-private bookmark storage plus a shared
menu record on macOS. A Finder URL is a selection request, not a permission.

## Implemented storage and access foundation

`WorkingComparisonMarkStore` in `RepositoryAccess.swift` persists one file mark
and its authorization bookmark in the containing app's private support folder.
The bookmark may grant that file or a containing folder. Relative paths allow
folder bookmarks to renew after a move. Every operation reloads the private
record; consumption compares the mark's unique ID, so an old comparison cannot
consume a replacement mark, even at the same path. Missing files and unavailable
permissions fail without clearing the saved mark. The acquired access object
retains its scope lease until the comparison releases it. Corrupt records fail
visibly. File/directory permissions are 0600/0700.

`WorkingComparisonMarkSnapshot` in `FinderCache.swift` publishes only an ID and
absolute path, never a bookmark, into the entitled app-group container. Its
reader validates the path. An unsigned process without that entitlement gets
no implicit shared-container access. Tests use explicit disposable paths.
Neither the private store nor shared snapshot launches Git or changes file bytes.
The preview app's private storage remains isolated by its bundle identifier.

Thirteen repository/mark access tests pass. The four new mark tests cover
relaunch, literal Unicode/newline paths and binary bytes, metadata-only sharing,
permissions, scope lifetime, moved file and folder bookmarks, access failures, deleted
files, replacement/consumption, directory and escaping-link rejection, and
corrupt storage. These use an injected bookmark provider; they do not establish
signed macOS permission behavior. Debug and unsigned App Store builds pass. Bundle audits verify the embedded
Finder extension, 64 original icon resources, and 11 universal Git runtime
Mach-O files with local Git operations. Signed runtime acceptance remains
pending. No QA app was launched for this storage-only change.

## Working-file command route (2026-10-05)

Finder now offers a single-file mark/compare action with original comparison
artwork. Its label reads the shared metadata record; Control invokes clearing.
The app exposes the dynamic action and explicit Clear comparison mark command
in its TurtleGit menu, and the working file table offers the same action for a
single selection. With no selection, the app uses a native file chooser.
The request handler routes these commands before repository discovery, so both
files can belong to different repositories or lie outside repositories.

The app reuses saved repository access or requests the current file/containing
folder in the App Store configuration. It reacquires the marked bookmark and
retains both leases in the comparison window. WorkingFileComparison reads exact
regular-file bytes or literal symlink target text and rejects directories. The
existing viewer supplies Reload, explicit editing, Save/Save As and diff tools.
Both standalone and repository saves now share the existing byte/mode validation,
encoding preservation and temporary-file replacement helper. Git metadata is
not touched by standalone comparison or Save. Only the consumed mark ID clears;
failed authorization or reads leave the mark available.

Twenty-nine focused comparison, mark-access and Finder-request tests pass,
including two new standalone tests for literal paths in separate locations,
UTF-16/BOM and executable permissions, saving either side, unchanged Git index
and HEAD, binary/symlink reading, stale bytes/modes, foreign documents and invalid
locations. New mark/clear URL round-trip coverage confirms that these actions do
not produce Git command arguments. Debug and unsigned App Store builds and
both icon/runtime audits pass. The preceding storage commit's macOS and Pages
runs passed; this change's CI requires a separate check after push.

## Native acceptance and limits

An ad-hoc Debug preview received a single-file mark request after opening a
known disposable repository. The main window reported the marked path and the
native TurtleGit menu showed Compare with that path plus Clear comparison mark.
Menu activation attempts returned stale accessibility IDs; no successful direct
menu chooser handoff is claimed. The app quit normally with the mark persisted.
After verifying process absence, the same preview was configured with an outside
file request and deliberately relaunched. The native viewer compared the marked
14-byte `later working` with the outside file's 17-byte `external partner`.
Enable editing made the marked pane editable; toggling it off restored the
read-only view. No Save or file mutation occurred. The private mark was consumed,
the app quit normally, and exact HEAD/index/working/outside bytes and deleted-file
absence were verified. Only one QA process was alive at a time.

[Recorded evidence](qa/working-mark-2026-10-05.json) and the
[actual native screenshot](site/assets/working-mark-comparison.png) cover the
request route, persisted access, viewer contents and editing toggle. This is not
an activated Finder extension or signed sandbox acceptance test.

## Remaining parity and acceptance

- Match compacted menu labels and Shift alternative-tool behavior.
- Verify native file-chooser cancellation, direct menu activation, explicit Clear,
  Control clearing from Finder, Reload, Save/Save As and external-change refusal.
- Verify different repositories, moved/missing files, symlinks/binary/encoded
  contents, Finder extension activation and signed sandbox permission behavior.

Full DiffLater, Log and Finder parity remain incomplete.


## External working marks in Log (2026-10-05)

Log now imports the saved working-file mark when opening and when the containing
app publishes a new mark. A retained bookmark lease belongs to the Log dialog;
the absolute path is not interpreted as a historical Git path. A new mark ID
replaces the imported mark. An unchanged ID does not overwrite a later local
historical mark. Windows tracks changes to the saved path; the macOS token also
distinguishes a newly marked instance of the same path.

Compare with resolves the selected commit once and reads the historical blob
without checkout. The external side reads live working bytes. Reload keeps the
historical revision pinned while rereading the external side. Explicit editing
and Save apply only to the external regular text file, using the same encoding,
permission and external-change validation as the other working-file viewer.
The App Store route checks both the repository grant and marked-file lease.
A successful handoff consumes the shared mark's ID; the Log dialog retains its
mark and lease for later comparisons, matching the upstream local retention.

Twenty-four focused comparison/editing/mark-access tests pass. The new real-Git
regression advances HEAD after preparing the mixed comparison, verifies exact
old committed bytes and live external BOM/CRLF text, saves only the external
file with its executable permissions retained, checks raw Git index/HEAD/working
preservation, reloads, and rejects stale external bytes and a missing file.
Debug and unsigned App Store builds and both resource/runtime audits pass.
The queued local commits have not been pushed because GitHub's saved credential
is unavailable; no CI pass is claimed for these commits.

Native QA opened Log with an outside file marked. The historical `right.txt`
context menu displayed Compare with the external absolute path, then opened a
viewer containing 17-byte `external partner` and 15-byte committed `selected right`
at `3afaeae0ad99d25e865b3f9072bdc5d8bc91d17c`. The later disk contents are
14-byte `later working` and were not used as the historical side. Enable editing
made only the external Base pane editable; turning it off restored read-only
mode. The shared private mark record became empty. Closing the viewer and using
the same Log action again opened the correct pair through the retained lease.
No Save was performed. Normal Quit left no QA app process; exact HEAD/index,
working/external bytes and deleted-file absence were verified.

[Native record](qa/log-working-mark-2026-10-05.json) and
[actual screenshot](site/assets/log-working-mark-comparison.png) document the
route. Signed Finder/app sandbox handoff, native Save/Reload, alternate tools,
compacted labels, new-mark/local-mark precedence variants and additional native
file types remain pending. Full Log/Finder parity is still incomplete.


## Native Save/Reload and correct file prompts (2026-10-05)

Native QA compared an external UTF-16 LE/BOM/CRLF executable file with pinned
historical `right.txt`. Editing through the text view and Save produced the exact
30-byte UTF-16 output, preserving BOM, CRLF and 0755. Only the external file
changed. A later independent edit made the working file differ from the loaded
document: Save refused it with the changed-file error and preserved those bytes.
Reload Cancel retained the draft; Reload Without Saving read the current 40-byte
external file and kept the historical 15-byte contents at the pinned hash.
Exact HEAD/raw index/repository working bytes and deleted-file absence remained
unchanged, and no temporary sibling remained.

The native run exposed a mislabeled Reload prompt: it named the historical
comparison path instead of the edited external path. Reload, window Close and
application Quit now use the document's actual editable path. A second sequential
preview verified all three corrected prompts, cancellation retaining the draft,
and Quit without Save leaving disk bytes untouched. The first clean QA process
needed a second normal Quit; both launches were individually checked terminal,
with no remaining app process. [Recorded evidence](qa/comparison-save-2026-10-05.json)
details this coverage. No new screenshot is claimed.

Save As now starts and balances destination scope through its write. For an
App Store working-file Save, the app checks access to the parent needed by the
existing temporary-sibling replacement. If only a file grant is retained, it
asks for that containing folder when Save is explicitly requested; cancellation
keeps the draft. The granted scope remains held through the write and window
lifetime. This follows the app's replacement strategy and macOS user-selected
access model; [Apple's sandbox documentation](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
and [read/write entitlement reference](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.files.user-selected.read-write)
provide the platform access context. The folder-authorization branch and Save As
scope still require signed native acceptance. Debug and unsigned App Store builds
and both bundle/runtime audits pass; the new scope and prompt code does not
change the previously tested core save algorithm.

## Independent working-pane drafts and Save

The upstream audit of `TortoiseProc/GitDiff.cpp:361–482` and
`TortoiseProc/AppUtils.cpp:466–521` identifies the saved comparison file as Base
and the current file as Mine. `TortoiseMerge/MainFrm.cpp:918–939` permits changing
the left pane's writability and makes the right pane the default target;
`OnEditEnable` at 2482–2507 changes the active view.

TurtleGit now labels the right pane Mine and enables editing there by default
when it is a regular working text file. Clicking a pane selects its independent
editing state, draft, annotations and Undo/Redo history. Base starts read-only
and can be enabled explicitly. Both drafts participate in alignment; switching
panes preserves them. Save writes only the active dirty pane. Close, Reload and
Quit list all dirty file paths and their Save choice saves every dirty pane.
If a later save fails, earlier successful saves remain saved and the unsaved
pane remains dirty; the pair is not an atomic multi-file transaction.

Native acceptance used two disposable files outside the repository: UTF-8 Base
and UTF-16LE/BOM/CRLF Mine with executable permissions. Both drafts survived pane
switches, each toolbar Undo/Redo changed only that pane, saving Base left Mine's
original disk bytes untouched, and Close/Cancel retained both drafts. Close/Save
wrote both exact drafts with their original encodings and modes. Command-Z and
Shift-Command-Z were verified in a later sequential preview; on this machine's
keyboard layout the automation's physical Y key sends Z. A final Quit/Save wrote
the remaining UTF-16 draft and exited. No QA processes remained. HEAD, raw index
and working bytes in the bootstrap repository matched the recorded baseline.

Two new core regressions cover independent drafts and exports, one-side saves,
immutable historical/binary panes, and annotation realignment without false
changes. All 22 comparison tests, Debug/App Store compilation and both bundle
checks passed. See [native evidence](qa/comparison-panes-2026-10-05.json).

Historical-copy editing and Save As, signed security-scope acceptance, and full
TortoiseMerge menu/layout parity remain incomplete. Edit-menu activation was
not verified: its accessibility snapshot reported disabled actions despite
successful editor keyboard and toolbar history operations. The source routes
Undo/Redo selectors to the active history, but that alone does not prove native
menu acceptance. Full TortoiseGit dialog parity remains the goal.

## Two-pane context-menu destinations

`LeftView.cpp::AddContextItems` and `RightView.cpp::AddContextItems`, together
with `BaseView.cpp:2524–2565`, distinguish two command sets. The primary
Use-this/Use-other/both-block commands always write to Mine. If Base is writable,
both menus additionally offer prepend, replace and append into Base, plus the
reverse whole-file command. These destinations do not follow whichever pane was
last active. English labels for the added commands are taken from
`Resources/TortoiseMergeENG.rc:894–899`.

TurtleGit now dispatches context commands to those explicit destinations and
checks each destination's own editing state. Right-pane mark/leave-marked
commands also target Mine; toolbar commands continue to operate on the active
pane. Native acceptance verified Base's whole-file command writing only Mine,
its Undo, and Base's prepend-right-block command plus independent keyboard Undo.
Core coverage uses both pending drafts and verifies incoming line endings match
the chosen destination. Both blocks/order variants, reverse whole-file native
acceptance, historical-copy editing and complete upstream state transitions
remain pending. See [acceptance record](qa/comparison-transfer-2026-10-05.json).

Cross-pane keyboard-focus synchronization remains incomplete: native commands
write the correct destination and select its model history, but accessibility
focus can remain on the source. The pending record explicitly preserves this
issue; automatic focus handoff and subsequent typing are not verified.
