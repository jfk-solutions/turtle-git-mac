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

Earlier cross-pane acceptance exposed a mismatch: commands selected the
destination model while accessibility focus remained on the source. The original
record preserves that observation; the side-specific update below addresses
model activation and documents the remaining keyboard-only reverse-menu case.

## Side-specific editor updates

The editor coordinator now reads, writes and records Undo for its own side.
Context commands dispatch directly to that side's editor instead of temporarily
activating it. Inactive-side edits do not set the active caret or move its
selection. Native acceptance now shows Base staying read-only and focused when
its whole-file command writes Mine. Enabling Base and typing edits Base without
changing the Mine draft, and independent Undo restores each side. A reverse
prepend from Mine similarly leaves Mine active while updating Base.

The initial side-specific acceptance still required a click before keyboard
editing after the reverse menu action. That observation is preserved in the
[side-specific acceptance record](qa/comparison-side-edit-2026-10-05.json).
The menu-close update below verifies the previously failing keyboard-only case;
complete keyboard/context-menu parity remains unproven.

## Return keyboard focus after native menu tracking

The comparison text view is now its context menu's delegate. On menu close it
restores the originating active text view as the first responder and
accessibility focus, provided no operation, Quit confirmation or sheet is active.
This finishes the native menu-tracking handoff without selecting the transfer's
other destination.

Native acceptance repeated the previously failing reverse prepend case:
select Mine, choose “Prepend this block to left,” then immediately use Command-A
and paste without a text-view click. Mine received the new draft; Base retained
its prepend. Independent keyboard Undo restored Mine, then Base. Exact original
comparison bytes/modes and repository HEAD/index/working bytes remained intact.
Debug and unsigned App Store builds and both bundle/runtime audits passed.
The preview quit normally and no TurtleGit process remained. See the
[menu-close acceptance record](qa/comparison-menu-close-2026-10-05.json).
Other menu/cancellation/key variants, complete upstream state behavior and
signed sandbox acceptance remain pending.

## Comparison whitespace and line-ending menus

`BaseView.cpp:2468–2505` adds leading tab/space conversions, trailing whitespace
removal and the EOL submenu to writable panes. The implementations at 6041–6070
and 6420–6552 operate on real source lines and preserve missing final endings.
TurtleGit's working comparison panes now expose the three commands and all nine
ending styles. They transform the selected pane's full draft, excluding aligned
display gaps; no-op whitespace commands are disabled. Ending checkmarks derive
from current draft styles. The read-only pane omits these controls.

Native acceptance verified both indentation conversions with keyboard Undo,
trimming and its disabled no-op state, LF conversion/Save and ending Undo/Save.
The external Mine file retained UTF-16LE/BOM, 0755 permissions and missing final
newline: exact LF output was 40 bytes; ending Undo restored a 44-byte CRLF output
while keeping trimming. Base and bootstrap repository HEAD/index/working bytes
were unchanged. Ten existing whitespace/ending regressions, Debug and unsigned
App Store builds and both bundle/runtime audits passed. Every preview quit and
process absence was checked. See
[formatting acceptance](qa/comparison-formatting-2026-10-05.json).

Other ending styles/checkmarks, mixed endings and marked-block variants still
need native acceptance. These commands do not establish per-pane tab-width or
inserted-line default-ending metadata parity. File Encoding and historical-copy
editing, locale-sensitive Unicode trimming and signed sandbox acceptance remain
pending.

## Working comparison File Encoding menu

Upstream `FileTextLines.cpp:489–537,610–637` defines the Unicode output
formats and BOM rules; `BaseView.cpp:6078–6087` marks encoding changes modified.
Writable comparison panes now expose UTF-8 and UTF-16LE/BE with optional BOMs,
and UTF-32LE/BE with BOMs. Encoding belongs to each draft independently. An
encoding-only change enables Save; Save and Save As encode that pane's current
text, and Save resets its baseline. Unrepresentable characters are rejected
before changing the format. The explicit Windows-1252 choice is a macOS
adaptation of upstream ASCII, which uses the Windows system ANSI code page.

Native acceptance verified rejection without draft changes, exact 64-byte
UTF-32BE Save and Reload, and exact 23-byte UTF-8 BOM Save As and Save. Chinese
text and an emoji, CRLF, missing final newline and 0755 permissions survived.
Base and bootstrap repository HEAD/raw index/working bytes remained unchanged.
Both sequential previews quit normally and no app remained running. See the
[encoding record](qa/comparison-encoding-2026-10-05.json). Literal-byte tests cover
all nine formats, Unicode round trips, malformed data, encoding-only dirty
state, independent export/save and stale-write refusal. All 353 tests, both
builds and bundle/runtime audits passed.

Remaining formats and menu checkmarks need native checks. Legacy input
selection, Windows system code pages, BOM-less non-Latin Unicode detection,
empty-file format inference, three-pane conflict controls, historical-copy
editing and signed sandbox acceptance remain incomplete. This does not
establish full upstream encoding/loading/writing parity.

## Pane format status controls

Upstream `BaseView.cpp:269–430` places encoding, EOL and tab mode in each pane's
status ribbon. TurtleGit now shows original source encodings and current draft
ending styles in both comparison and conflict panes. Writable panes provide
encoding and EOL menus with checkmarks; read-only panes report their formats.
The comparison byte count is explicitly labeled saved bytes, because a draft's
output format can change before Save. Conflict documents retain Base/Mine/Theirs
encoding metadata across result saves. Ending changes use existing Undo paths.

Native acceptance verified distinct UTF-32BE, UTF-8 BOM and UTF-16LE BOM source
indicators, CRLF/LF conversion with Undo, result encoding changes/checkmarks,
and two-pane footer behavior. Loaded mixed-ending and single-line files show
Mixed EOL and No line ending. Source files and repository bytes remained
unchanged by the UI. The twelve conflict tests and both builds/bundle audits
passed. The actual light-window screenshot is published; all QA processes were
closed. See [record](qa/format-status-2026-10-05.json).

Dark/narrow layout, remaining native formats, absent/binary sources, upstream
read-only-source format interaction, insertion defaults and signed sandbox
acceptance still need work. Mixed-ending paste normalization is existing editor
behavior; this change does not establish paste or full status/view parity.

## Independent tab settings and source-mapped indentation

`BaseView.cpp:254–267,3873–3877,6332–6401` provides the tab-mode label and
selected-line Tab/Shift-Tab behavior. Comparison Base and Mine now retain
independent tab width, Tab/Space and smart-mode overrides initialized from
saved merge preferences. The same native menu component is used in three-pane
footers. Rendering, insertion and whole-file indentation conversions use the
selected pane's width. Formatting preferences reset pane overrides when changed;
line-number-only changes retain them. View settings do not dirty the file.

Tab commands map display selections to the real source before editing, excluding
alignment gaps and preserving source endings. Multi-line Tab and Shift-Tab
retain the edited source selection, share the existing pane Undo history, and
keep absent EOF newlines intact. Keyboard indentation uses the existing manual-edit
annotation path; its Leave-only-marked interaction still needs native acceptance.
Single-line Tab uses the existing UTF-16 tab
stop/smart algorithm. A collapsed Shift-Tab currently makes no change, matching
the existing partial three-pane selected-block implementation.

Native acceptance kept Base at Tab 4 while selecting Mine Space 8. Tab after
Chinese/emoji text inserted five spaces; Save produced exact 30-byte UTF-16LE
BOM output with CRLF, missing final newline and 0755. Selected-line indentation
and removal skipped the display gap; keyboard Undo/Redo returned to saved text.
Smart mode chose a literal tab from surrounding content and Undo restored the
file. Base and repository HEAD/raw index/working bytes stayed unchanged. All QA
apps quit normally and process absence was checked. The 36 focused comparison,
whitespace, preferences and conflict tests, both builds and audits passed. See
[acceptance](qa/comparison-tabs-2026-10-05.json).

Base editing, native preference Apply/reset variants, full Undo selection state,
blank/end-boundary variants, arbitrary widths, EditorConfig, dark/narrow layouts,
refactored three-pane menu acceptance, insertion ending metadata and signed
sandbox acceptance remain pending. This is partial tab/view behavior parity.

## Marked-block File Save decisions

The writable Mine pane now offers the source FileSave warning when marked
blocks remain. **Save and Include** keeps marked rows and manual edits, taking
other rows from Base. **Save and Exclude** restores marked rows from Base while
retaining unmarked rows and manual edits. **Save Only Manual Edits** keeps edited
rows and takes the rest from Base. Cancel retains text and marks without writing.
The transformation uses the pane's dominant line-ending style and preserves absent EOF
newlines, alignment gaps and manual edits even when also marked. It clears marks
through the existing native Undo history; Undo/Redo can restore the decision.
Save locks other edits/reload/save calls while the sheet is pending. Existing
stale-file and sandbox authorization checks still run before writing; a failed
save retains the transformed draft and its Undo history.

Mapped source: MainFrm.cpp FileSave (1656–1684) and BaseView.cpp
LeaveOnlyMarkedBlocks/UseViewFileOfMarked/UseViewFileExceptEdited (6243–6260),
pinned at `7338078f8ddd924b8cddee35f512f2286072136d`. The warning applies to
Mine File Save. Source writable Base saves and automatic PatchSave bypass it;
Review Patch's automatic patched-result Save retains that distinction. Exact
source toolbar/close routing for every patch-edit state remains pending.

The headless native receiver checks all three decisions and Cancel using actual
aligned editor coordinators, exact CRLF/no-final-newline writes, Base preservation,
Undo/Redo, stale external writes and reentry guards. Choices are injected; physical
sheets, accessibility/layout, full three-pane merge decisions and signed sandbox
acceptance remain unverified. See [marked-save QA](qa/marked-save-2026-10-08.json).

## Nine-style line-ending editing

Two-pane alignment now uses the shared source-mapped boundary parser for CRLF,
LF, CR, LFCR, VT, FF, NEL, LS and PS. Original cell text retains each ending;
display cells strip that ending and render a display-only LF. Typing and incoming
block/marked-policy rows use the target's dominant ending. Mixed-style ties use
EOL.h order (CRLF, LF, CR, LFCR, VT, FF, NEL, LS, PS), matching FileTextLines.cpp
countEOLs selection. Files without any endings retain the macOS LF default.
Manual/retained rows keep their original endings, and missing final endings remain
absent. Combining blocks now recognizes all nine existing endings, preventing an
extra separator after an exotic ending.

[Editor endings QA](qa/editor-endings-2026-10-08.json) records focused Core and
headless native checks. The native receiver exercises every style through actual
aligned display, insertText, private Undo/Redo, ordinary Save and block transfer,
checking exact output bytes and unchanged Base. Physical format-menu interaction,
three-pane alignment, explicit pane-style persistence after deleting/changing the
dominant ending, and exhaustive mixed-ending/selection combinations remain pending.
