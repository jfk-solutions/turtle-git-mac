# Blame parity

Target: the native equivalent of TortoiseGitBlame, including its annotated source
layout, colors, navigation, context menus and settings. A first native historical
viewer is available from the Log changed-file context menu. Full parity is pending.

## Baseline

Upstream source baseline: `7338078f8ddd924b8cddee35f512f2286072136d`.

- [TortoiseGit Blame manual](https://tortoisegit.org/docs/tortoisegit/tgit-dug-blame.html).
- `src/TortoiseGitBlame/TortoiseGitBlameData.cpp`: annotation parsing, origin paths
  and line numbers, encoding conversion and search behavior.
- `test/UnitTests/TortoiseGitBlameDataTest.cpp`: empty files, BOM, trailing blank
  lines, UTF-16 and legacy encoding cases.
- [Git blame manual](https://git-scm.com/docs/git-blame): line porcelain, whitespace,
  moved/copied line detection and automatic whole-file rename following.

These files have been reviewed for the data reader; their complete behavior has
not been ported. The macOS reader uses `--line-porcelain`, repeating metadata on
all lines, rather than caching metadata from upstream's ordinary porcelain mode.

## Implemented data behavior

`Sources/TurtleGitCore/GitBlame.swift` reads a regular historical UTF-8 file at a
resolved commit. It now also decodes UTF-16 LE/BE as described below. It retains
the pinned revision and raw file contents, and returns
revision, author/email, timestamp/timezone, summary, boundary flag, origin path,
origin line number, current line number and source for each annotated line.

Git runs with argument arrays and literal pathspecs. Quoted origin filenames are
decoded from Git's byte escapes, preserving Unicode, tabs and newlines. Optional
ignore-whitespace, moved-line and copied-line detection use Git's `-w`, `-M` and
single `-C` switches. Whole-file rename following is Git's automatic behavior.

Every returned source line is checked against the pinned blob bytes. CR, tabs,
UTF-8 BOM, blank lines and missing final LF are retained in the data layer. The
future display must remove encoding/line-ending markers for presentation without
changing those bytes. Empty files return no annotations. Malformed, truncated or
unsupported output fails rather than displaying misleading attribution.

Six focused tests cover parser metadata and invalid input; real Git renames with
literal pathspec-looking Unicode/newline paths; two authors; exact source bytes;
whitespace-only attribution; moved/copied origins; empty files; and unsupported,
missing or escaping paths. The rename test verifies unchanged HEAD, index and
working file contents after historical annotation.

Validation for this milestone: all 266 core tests passed, unsigned Debug and
AppStore builds succeeded, and both bundle checks passed. The AppStore audit also
runs historical line-porcelain Blame with `-w`, `-M` and `-C` against its packaged
Git 2.55.0, checking attribution and unchanged HEAD/index/working contents. This
checks the local packaged runtime, not signed sandbox or App Store acceptance.
The documentation site build passed. No app process was launched for these checks.

## Native historical viewer

`Sources/TurtleGitMac/BlameWindow.swift` uses an AppKit annotation table in a
resizable native window. Revision, author, localized date and line number precede
monospaced source. Horizontal/vertical scrolling retain source order. Find searches
revision, author and source with optional case sensitivity and wraps in either
direction; Go To Line selects and scrolls to a valid source line. This is native
navigation, not a source-line filter. Tooltips and the selection footer show the
origin filename/line and commit summary.

Ignore whitespace, moved-line and copied-line options reload at the already pinned
commit. Colorize by age uses the original light/dark palette endpoints and upstream
integer history-rank interpolation. Ranks currently come from Git's `--follow`
file history; merge ordering and copied origins outside that history still need
comparison against the upstream log list. The source display removes a leading BOM
and trailing CR markers while the underlying snapshot preserves all bytes.

The line menu has original Log/Copy icons, Show log, Copy revision and Copy source
line. Show log and double-click use the line's origin filename and commit rather
than the current filename. The Log Blame item uses the unchanged original
`TortoiseGitBlame.ico` application artwork with verified Git blob identity and
SHA-256 provenance; the exact upstream command-icon mapping remains pending.

The controller retains its repository security-scoped lease and invalidates pending
UI updates on close. It does not edit or stage files. Native QA verified root-file
annotations, Find, Go To Line, historical Show log, three authors, and Show log for
the original filename before a rename. Dark age shades were visually verified;
[the actual screenshot](site/assets/blame-dark.png) is included in the site gallery.
All QA processes were quit after their scenarios and repository HEAD/index/source
baselines were unchanged. Light age colors have now also been checked using the
disposable preview's initial appearance preset, with an actual light screenshot.
Clicking a revision margin highlights its lines and uses a lighter shade for
other revisions by the same author. Clicking that revision again clears the sticky
highlight. Native light QA checked the author/revision distinction, clearing and
persistence after focus moved to Find. Custom row selection drawing preserves the
sticky background when the table loses focus. Hover tracking applies transient
revision/author shades in the information columns; pointer-hover and dark sticky
acceptance still need separate native checks. Author metadata is cached by revision
so highlighting avoids searching every source line for every rendered cell.

Viewer milestone validation: Swift build and the six Blame tests passed; unsigned
Debug/AppStore builds and bundle audits passed with 62 upstream icon resources.
The packaged universal Git audit, including historical Blame, and the site build
also passed. The earlier full 266-test run covers the unchanged annotation reader.

The highlighting milestone passed Swift, unsigned Debug/AppStore builds, both
bundle audits and the site build after the native light checks. It leaves the
annotation reader unchanged. Mouse tracking is confined to the Blame window and
uses AppKit's [tracking areas](https://developer.apple.com/documentation/appkit/nstrackingarea).

## Show changes from an annotated line

The line context menu now offers Show changes for each relevant parent of the
line's origin commit. This follows the gates in upstream
`src/TortoiseGitBlame/TortoiseGitBlameView.cpp`: compare an existing modified or
renamed file, using the old filename on the parent side of a rename. Root commits,
newly added files and parents that did not change the origin file have no previous
comparison. A single relevant parent gives one command; multiple relevant parents
appear in a submenu with their commit identifiers and actual parent numbers.

The native read-only comparison opens pinned parent/origin versions, independently
of later working file changes. The menu lookup finishes before AppKit starts menu
tracking; cached choices avoid repeated Git reads. Closing or reloading Blame
invalidates pending menu presentation. Right-click and Control-click are routed
through this lookup; separate native keyboard and Control-click acceptance remain
pending.

Nine focused Blame tests now cover the reader and parent comparisons, including a
literal Unicode/newline rename, root and non-root file birth, and a conflict
resolution attributed to a two-parent merge. Comparison bytes, parent order and
rename paths are checked; the historical operations preserve HEAD, index and
working source. The full core suite passed all 269 tests. Swift and unsigned Debug/AppStore
builds passed without compiler warnings. Both bundle audits passed with all 62
upstream icons; the packaged universal Git 2.55.0 audit verified its 11 Mach-O files
and local Git operations including Blame. The documentation site build passed.
Signed sandbox and App Store acceptance remain pending.

Native QA verified the absence of Show changes on a root-origin line, both choices
for a merge-origin line, and each parent's source against the merge resolution in
the read-only viewer. The second-parent check showed Side greeting against Resolved
greeting with the corresponding pinned hashes. Each QA app was closed after its
scenario; the final process check found no running TurtleGit app, and fixture HEAD,
index and working source matched their baseline.

## Blame previous revision

The line menu now places Blame previous revision before Show changes, following
upstream's ordering. It uses the same relevant-parent gates and rename-aware
parent filenames. One relevant parent is a direct command; multiple parents have
separate choices with the original Blame artwork. Each menu item captures its
parent snapshot and the annotated line's original line number when the menu opens.

Choosing a parent opens or reuses a retained native Blame window for that historical
filename and commit. The window keeps the repository access lease and selects the
original line after annotations finish loading, scrolling it into view. If that
number exceeds the previous file's length it selects the last line; an empty
previous file reports that it has no lines.

Native QA verified selecting the second merge parent: the previous file showed
Side greeting and selected line 8. A separate disposable fixture inserted three
header lines after the rename. Selecting its earlier origin (displayed line 8,
origin `repository.swift:5`) opened `repository.swift` at the root parent commit
and selected line 5. Both QA app instances were quit immediately after their
scenarios; no TurtleGit app remained running, and fixture HEAD, index and working
source matched their recorded baselines. Empty/short previous files, reused-window
navigation and keyboard/VoiceOver acceptance still need native checks.

This UI milestone leaves the Git data reader unchanged; its previous full 269-test
run covers the parent choices and historical bytes. Swift and unsigned
Debug/AppStore builds passed without compiler warnings. Both bundle audits passed
with 62 icons and the packaged universal Git 2.55.0 runtime; the documentation site
build passed. Signed sandbox acceptance remains pending.

## Full log clipboard

Copy log message follows the Blame context action's use of the Log list's full
clipboard output. Reviewed baseline:
[GitLogListBase.cpp, CopySelectionToClipBoard](https://github.com/TortoiseGit/TortoiseGit/blob/7338078f8ddd924b8cddee35f512f2286072136d/src/TortoiseProc/GitLogListBase.cpp).
The native command reads the captured origin hash, then copies revision, author,
author date, complete subject/body/trailers, Git notes, annotated-tag contents and
changed paths. Rename paths include their previous names. Merge paths are read
against every parent. A separator divides Show log from the copy commands, as in
upstream; Copy source line remains an additional native command.

`GitRepository.commitLogText` resolves a commit before reading metadata, tags and
paths; each annotated tag is read by its captured object hash. The UI retains the
repository access lease and ignores the result if Blame closes, reloads or receives
a newer copy action during the read. A progress indicator shows the pending read;
errors are shown in the window. Output uses macOS LF line endings, ISO
author dates and Git's raw annotated-tag representation. Upstream localized date
preferences and tag presentation still need parity work. Log now shares this reader
for full clipboard details with and without changed paths; see [Log parity](LOG-PARITY.md). Nested annotated tags and
multi-revision selection remain pending.

Ten focused Blame tests passed, including a multiline subject/body/trailer, note,
annotated tag, Unicode rename and unchanged HEAD/index/working source. The merge
fixture checks paths from both parents. Native QA copied a message and pasted it
into Find, verifying the revision, body, note, tag and path. The QA app was quit
immediately after this check; no TurtleGit process remained, and the disposable
fixture matched its recorded HEAD/index/source baseline.

The full suite passed all 270 core tests. Swift and unsigned Debug/AppStore builds
passed without compiler warnings, and both bundle audits passed with 62 icon
resources. The AppStore audit verified the universal Git 2.55.0 runtime's 11 Mach-O
files and local operations including Blame. The documentation site build passed.
Cancellation and overlapping clipboard requests still need targeted native
acceptance; signed sandbox checks remain pending.

## UTF-16 source decoding

The historical reader now supports UTF-16 little/big endian with BOMs and
conservatively detected BOM-less files. The snapshot records the detected encoding,
and the native footer displays it. Every annotation retains its exact source
payload bytes separately from decoded text; those payloads are checked against
splitting the original pinned blob at Git's byte-LF delimiters. Metadata remains
strict UTF-8 and cannot contain NULs.

Upstream `TortoiseGitBlameData.cpp` and its unit tests were reviewed for these
cases. Like upstream, decoding removes the LF's carried zero byte from later LE
records and the incomplete LF prefix at the end of BE records. LE files ending in
LF retain Git's extra trailing empty annotation; BE files retain their corresponding
Git line count. BOM-only files produce one empty annotation. CR is retained in the
data layer and removed for display; raw file bytes are unchanged.

BOM-less automatic detection requires a consistent zero-byte pattern and valid
UTF-16 with printable text. Explicit encoding choices now handle ambiguous files
and legacy code pages as described below. Odd byte lengths, embedded NUL code units, unpaired surrogates
and byte-LF within another Unicode code unit are rejected instead of silently
truncating text. The last case needs further upstream parity work because Git's
byte line boundaries cannot directly represent its Unicode source lines.

Twelve focused Blame tests passed. A real Git matrix covers both byte orders,
BOM/no BOM, missing final LF, LF, CRLF, trailing blank lines, emoji/surrogate pairs,
BOM-only files and exact payload/blob bytes. A second UTF-16 fixture checks that
editing the second line retains the first line's original attribution; malformed
encoding cases fail. The fixtures preserve HEAD, index and working content.

Native light QA verified a BOM-marked UTF-16 LE file from Log to Blame, rendering
Unicode and emoji, CRLF and blank lines, with UTF-16 LE in the footer. The one app
was quit immediately afterward; no TurtleGit process remained and its fixture
HEAD/index/working bytes matched their baseline. Native BE, BOM-less, dark,
Find/Go To Line and previous-revision encoding checks remain pending.

The full suite passed all 272 core tests. Unsigned Debug/AppStore builds passed
without compiler warnings, and both bundle audits passed with 62 icon resources.
The packaged universal Git 2.55.0 audit verified 11 Mach-O files and real UTF-16
LE/BE BOM/no-BOM porcelain payloads, alongside the existing UTF-8 and local Git
operations. These runtime checks preserve repository and source state. The static
documentation build passed; signed sandbox and App Store acceptance remain pending.

## Explicit encoding selection

The native Encoding popup offers Automatic, UTF-8, UTF-16 LE/BE and installed
macOS codecs compatible with Git's byte-LF delimiter. The list comes from Apple's
[available encodings API](https://developer.apple.com/documentation/corefoundation/cfstringgetlistofavailableencodings())
and displays Windows code-page numbers where Core Foundation supplies them.
It includes Western Windows-1252, OEM850 and Japanese Shift-JIS/CP932 alongside
other installed codecs; its contents depend on the host's conversion support.

Changing the selection reloads annotations at the pinned commit with the retained
repository grant. Explicit UTF-16 bypasses the conservative automatic-detection
heuristic while retaining strict code-unit validation. Legacy source is decoded
as a whole before assigning text to Git's annotation records, preserving shift
state for stateful codecs. Commit metadata and filenames remain UTF-8. Both raw
source payloads and the historical blob are retained and checked unchanged.
On decoding failure the previous table, selection and highlights are cleared;
the popup remains available to recover with another encoding. Automatic legacy
fallback and saved defaults still differ from Windows' system-codepage behavior.

Fourteen focused tests passed. Real Git fixtures cover Windows-1252 euro/dash/
accented text, OEM850, Shift-JIS Japanese text and a BOM-less Japanese UTF-16 file
that needs an explicit choice. They check exact source/blob bytes, UTF-8 author
metadata, unchanged HEAD/index/working source and rejected wrong UTF-8 choices.
The existing UTF-16/UTF-8 matrix continues to pass.

Native QA verified that Automatic cannot decode a Windows-1252 fixture, selecting
CP1252 renders euro/dash/accents, selecting UTF-8 clears the table and reports an
error, and choosing CP1252 again restores it. The one app was quit immediately;
no TurtleGit app remained and the fixture HEAD/index/source baseline was unchanged.
Native OEM850, CJK/stateful codecs, dark appearance, accessibility, persistent
defaults remain pending. Previous-revision option inheritance is described below.

The full suite passed all 274 core tests. Unsigned Debug/AppStore builds passed
without compiler warnings, and both bundle audits passed with 62 original icons.
The packaged universal Git 2.55.0 audit verified 11 Mach-O files and annotation
payload bytes for UTF-8, UTF-16, Windows-1252, OEM850 and CP932, plus existing local
operations. The static documentation build passed. These checks do not establish
signed sandbox or App Store acceptance.

## Previous-revision option inheritance

Blame previous revision carries the encoding, whitespace, moved-line and copied-line
options used to produce the displayed annotations. Menu targets capture those
applied options, so edits awaiting Reload do not change the meaning of an existing
annotation. New parent windows apply the options before loading. Existing parent
windows reconfigure and reload when necessary, ignoring superseded read results;
the original line is selected after loading. Reopening an existing viewer from Log
preserves that viewer's settings.

Native QA used a Windows-1252 history containing euro, dash and accented text.
The child viewer had CP1252 and all three annotation options enabled. Blame previous
revision opened the parent with those settings, rendered the original text and
selected line 1 without another encoding selection. The app was quit, no TurtleGit
process remained, and HEAD, index and source bytes matched the recorded baseline.
Native reused-window reconfiguration, merge-parent option inheritance and keyboard
acceptance remain pending. Failed loads also clear obsolete navigation text and
age-history counts along with the annotation table.

The core reader is unchanged by this UI change; the preceding full 274-test run
remains its validation baseline. Swift and unsigned Debug/AppStore builds passed
without compiler warnings. Both bundle audits passed with 62 icons; the packaged
Git 2.55.0 runtime passed its architecture and local-operation checks. The static
documentation build passed. Signed sandbox and App Store acceptance remain pending.

## Move/copy detection modes and thresholds

The native viewer now offers the five choices from the pinned upstream
`BlameDetectMovedOrCopiedLines.h`, `TortoiseGitBlameDoc.cpp` and
`SettingsTBlame.cpp`: Disabled, Within file, From modified files, At file creation
and From existing files. The former independent move/copy checkboxes are replaced
by this mutually exclusive choice. Git receives `-M<n>`, `-C<n>`, `-C -C<n>` or
`-C -C -C<n>` respectively. Separate character counts default to upstream's 20
within a file and 40 between files. Only the count relevant to the mode is enabled.
Counts use the upstream unsigned 32-bit range; invalid input reports an error
without starting another annotation read. Changing mode reloads automatically;
changed counts are applied by Reload or an encoding change. Applied mode and both
counts travel with previous-revision menu targets alongside encoding/whitespace.

Real Git tests distinguish copying from a modified donor, copying from an unchanged
donor at file creation, and copying from an unchanged donor in a later edit. They
check original filenames/line numbers, within-file movement at low/high thresholds,
a separate short copied block at low/default thresholds and high-threshold rejection.
Adjacent copied lines are scored as a block by Git, so the short-block fixture uses
a separate destination file. Literal Unicode/newline/pathspec-like filenames are
covered, and HEAD, exact index and an unrelated working edit stay unchanged.
All 15 focused Blame tests passed.

Native light-mode QA verified all five chooser entries, default disabled threshold
fields, file-creation attribution to an unchanged donor, enabled between-file count,
a high count reverting attribution, rejection of 4294967296 and recovery at 40.
The actual captured window is `site/assets/blame-modes-light.png`. The QA process
was stopped after the scenario and absence verified; HEAD, exact index and source
files matched their recorded baseline. An open Commit window can require cancel
confirmation when Quit is requested; the isolated process was terminated after
issuing Quit. No replacement instance was launched. Native within-file count
enablement, remaining copy modes, threshold inheritance/reuse, dark appearance,
keyboard/VoiceOver, settings persistence and first-parent filtering remain pending.
The native controls currently live in the viewer rather than the complete upstream
settings dialog and View menu; full layout/menu parity is not established.

The full suite passed 275 tests. Swift and unsigned Debug/AppStore builds passed
without compiler warnings; both bundle audits passed with 62 icons. Packaged Git
2.55.0 passed its 11-Mach-O architecture audit and existing local-operation/encoding
fixtures. The static site built with the new verified screenshot. These checks
do not establish signed sandbox or App Store acceptance.

## Only consider first parents

The native checkbox now matches the upstream View/settings option and reloads
annotations immediately. The reader uses Git's documented
[first-parent traversal](https://git-scm.com/docs/git-blame#Documentation/git-blame.txt---first-parent)
at the resolved historical commit. Side-branch lines become attributed to the
merge that introduced them into the integration branch. Source/blob validation,
encoding, whitespace and move/copy options continue to apply. The age-history read
also restricts traversal to first parents. Previous-revision menu targets retain
the applied flag, and both new and reconfigured viewers use it when reading.

Upstream builds a `rev-list --first-parent` ancestry file and passes it with `-S`.
A real Git test reproduces that exact file construction and compares hash, original
line and filename attribution with the new traversal. The fixture distinguishes
main-branch, unchanged and side-branch lines; it also checks root and single-parent
history, combined whitespace/copy options, literal Unicode/newline/pathspec-like
paths and preservation of HEAD, exact index bytes and independent working edits.
All 276 core tests passed, including this merge comparison.

Native QA opened a pinned merge from Log. Enabling the checkbox changed the side
line's hash from the side commit to the integration merge while retaining all source
text. Blame previous revision → Parent 1 opened the main parent with the checkbox
still enabled and original line 3 selected. Expanding that submenu and accepting
with Return exercised native keyboard command dispatch. A subsequent Window-menu
selection returned stale automation targets; reused-window restoration remains
unverified. The one QA process quit after the scenario, absence was verified and
HEAD/index/working source matched the recorded baseline. No new screenshot is
claimed for this checkbox.

Swift and unsigned Debug/AppStore builds passed without compiler warnings. Both
bundle audits passed with 62 icons. The packaged universal Git 2.55.0 audit now
executes a real merge and verifies ordinary versus first-parent attribution,
unchanged HEAD/index/source, plus its previous encoding/local-operation fixtures.
Its 11 Mach-O files passed architecture checks. Saved preferences, complete View/
settings layout, renamed/complex merge histories, full age-color/history behavior,
dark/VoiceOver and signed sandbox acceptance remain pending.

## Native settings and saved annotation defaults

The Settings window now has a Blame page for the upstream five-way detection mode,
within/between-file character counts, Ignore whitespace and Only consider first
parents on blame. The relevant character field is enabled for the selected mode;
invalid counts disable Apply. Apply saves the draft and broadcasts an update to
open Blame viewers, retaining each viewer's encoding and selected original line.
Cancel restores the draft and closes Settings. The shared settings window now has
room for these controls. Font, tab size, age colors and complete-log/follow-renames
settings from the upstream page are not yet implemented.

New viewers load the saved annotation defaults. Changing the viewer's mode,
whitespace or first-parent checkbox saves that individual field and reloads.
Changed valid counts are saved on user-triggered Reload/encoding/mode changes.
Programmatic previous-revision option inheritance does not overwrite saved defaults.
Each field edit reloads the current preference store before saving, retaining
choices made by other viewers. Encoding remains a per-window choice; no persistent
system-codepage fallback is added. Annotation defaults use the application's own
macOS preference domain.

Two isolated preference tests cover default values, reopen, zero/max unsigned counts,
malformed stored mode/count fallback, interleaved field updates and exclusion of
encoding from the saved annotation defaults. All 18 focused Blame/preferences tests
passed. The preceding full 276-test reader run remains the wider baseline; no new
full-suite result is claimed for this settings change.

Native light-mode QA verified default disabled count fields, selecting From existing
files, rejection of 4294967296 with disabled Apply, valid threshold 17, both flags
and successful Apply. `site/assets/blame-settings.png` is the inspected actual
window. Closing Settings timed out in the UI tool; reselecting the still-running
process also timed out, so existing-viewer update is not claimed as native acceptance.
Quit stopped that process and absence was verified before reopening. The reopened
viewer restored the mode, count and both flags and displayed first-parent merge
attribution. Turning Ignore whitespace off saved that field while the first-parent
choice remained enabled. The second run was quit immediately and process absence
verified. HEAD, exact index bytes and working source matched the fixture baseline.

Native unsaved Cancel, within-file count editing, multi-window updates, open-viewer
encoding preservation, pending-load updates, dark/keyboard/VoiceOver and complete
upstream settings layout remain pending. Existing windows receive explicit Settings
Apply updates; ordinary viewer edits are defaults for subsequent viewers rather
than a broadcast to every currently open viewer.

Swift and unsigned Debug/AppStore builds passed without compiler warnings. Both
bundle audits passed with 62 icons and the packaged Git 2.55.0 runtime's existing
local, encoding and first-parent checks. The static documentation build passed
with the inspected Settings screenshot. Signed sandbox/App Store acceptance and
the full upstream settings page remain unverified.

## CI rename fixture across Git versions

The macOS run at `b8c418b` failed four attribution assertions in
`testRenamesAuthorsAndExactSourcePreserveRepositoryState`; the remaining tests
passed. Reproduction with official Git 2.39.5 showed that the original 17-byte
fixture is detected as add/delete, while Apple Git 2.50.1 detects a 62% rename.
The fixture now retains three lines but lengthens the two unchanged lines:
Git 2.39.5 and Apple Git 2.50.1 both detect a rename (97% and 98% respectively).
The expected author, hash, original filename, timezone, BOM, CRLF, tab, empty
historical line and unchanged index/worktree/HEAD assertions are retained.
Production Blame behavior is unchanged. CI reports the system Git version as
well as PATH Git, since integration tests use `/usr/bin/git`.

## Native presentation settings

Blame Settings now groups Colors, Font and Blame controls in the upstream order.
The native presentation defaults are Menlo 10 points and tab width 4; Menlo
replaces the Windows Consolas default. Installed fixed-width font families can be selected,
with a native monospaced fallback for missing families. Font and tab sizes are
validated from 1 through 1000, a native limit rather than upstream DWORD parity.
The editable native size combo offers upstream presets 6 through 30 in steps
of 2. Native QA observed Andale Mono, Courier New, Menlo, Monaco and PT Mono,
all thirteen size presets and successful typed size entry. Preset selection by
mouse/keyboard and font preview drawing still need native acceptance.

Source cells use attributed Cocoa text with tab intervals measured from the
selected font's space width. Row heights and source widths update with the
presentation settings. Tabs, source BOM and CR display handling do not rewrite
historical bytes or the source used by clipboard actions. Colors retain upstream
integer interpolation and default yellow/white and dark yellow/gray endpoints.
Separate saved light and dark endpoints are exposed through native color wells;
Restore Default restores colors without resetting font or annotation choices.
Settings Apply broadcasts presentation and annotation defaults to open viewers.

Two presentation tests cover saved values, field independence, malformed values,
range handling and custom/default light/dark interpolation. All 280 core tests
passed after the CI rename fixture correction. Swift and unsigned Debug/AppStore
builds and both bundle audits passed; the packaged runtime audit verified 11
universal Mach-O files and Git 2.55.0 integration behavior.

Native QA saved Menlo 14 and tab width 8, verified those isolated preferences after
Quit, then opened a new viewer. The actual viewer showed larger source text,
leading and intervening tabs at the expected eight-space intervals, including
Unicode and emoji source lines. HEAD, index and source bytes were unchanged.
Each QA process was quit before another launch, and no app process remained.
`site/assets/blame-presentation-settings.png` is the inspected actual Settings
capture (1240 by 1396). An earlier source screenshot did not finish writing before Quit; the subsequent
final viewer capture was saved and inspected before Quit and is published as
`site/assets/blame-font-tabs-light.png` (2240 by 1464). Native custom-color selection, dark/Restore Default,
invalid-size input, other fonts, preset selection, multi-window updates, unsaved Cancel and
accessibility checks remain pending. Full Log settings and editor layout remain
partial.

## Embedded Log and history settings

Compared against pinned upstream `SettingsTBlame.cpp`, `TortoiseGitBlameDoc.cpp`,
`OutputWnd.cpp`, `TortoiseGitBlameView.cpp` and `LogDataVector.cpp`.
Show complete log defaults on; Follow renames defaults off. Complete history is
available only with disabled/within-file detection and without first-parent mode.
Settings clears unavailable flags; the viewer retains saved flags while gating
their effective values. Disabling complete history in Settings also clears Follow.

Complete history uses the pinned revision and literal file path, without a row
cap, optionally following renames. Otherwise the Log loads every distinct source
attribution hash, including copied-file origins. Direct children precede parents;
other rows use descending committer date with a deterministic hash tie-break.
The compact graph appears only for complete history without Follow. Age shading
uses loaded Log ranks; absent hashes use the light/dark window background.

The native split view includes SHA-1, Message, Author and Date columns, multiple
selection support and source focus. Single-selection message text and Show log,
Copy SHA-1 and Copy log message actions are provided. Hash copying cancels any
older asynchronous clipboard request. Full Properties, locator, docking and Log
context-menu parity remain pending.

Native QA observed one rename row with complete history, four rows with Follow
and no graph, and source line 2 focused by selecting its restoration commit,
including its full message. No saved source screenshot was obtained for that
scenario; an unresponsive menu prevented normal Quit, so the sole known preview
process was terminated and absence verified. A separate Settings check verified
first-parent and cross-file modes clearing/disabling both Log options, persistence
and Apply becoming disabled after save. That process quit normally. The inspected
actual capture is `site/assets/blame-log-settings.png` (1240 by 1576).

The initial repository overview refreshed Git's index stat-cache size and checksum;
staged blob, path, mode, HEAD and working source remained unchanged. After settling
that cache before the second baseline, HEAD, raw index and working bytes were
identical after Settings QA. Direct history tests also preserve all three exactly.

All 282 core tests passed, including literal rename, complete/follow/origin
histories, copied donor origins, empty sources and option dependencies. Focused
Blame runs passed 22 tests plus the copied-source test. Debug and App Store builds and both bundle audits passed, including 62 original
icon resources and 11 universal packaged Git binaries. The documentation site
build and whitespace check passed. Native multi-selection, viewer dependency
changes, context menus/clipboard and dark layout still require
acceptance. This remains a partial port.

## Right-hand Properties pane

Compared `PropertiesWnd.cpp` and `MainFrm.cpp` with the pinned upstream tree.
The native pane is right of the annotated source and bottom Log, with a resizable
split divider and a Properties visibility toggle. Its read-only, selectable fields
cover hash, author/name/email/date, committer/name/email/date, subject, full body
and all parent hashes. Parent subjects come from the loaded Log cache, as upstream
does; a parent absent from that cache has an empty subject. Empty or multiple Log
selection clears the Properties fields. Content scrolls vertically without the
previous four-line message limit. Dates currently retain Git's ISO timestamps;
upstream's local minute precision display, property description area, collapsible
groups, docking persistence and full context-menu behavior remain pending.

Blame history now loads separate committer identity and timestamp in both complete
and distinct-origin modes. Existing callers of LogEntry retain their default empty
committer fields. The history test uses Unicode author/committer identities and
different explicit dates/time zones to ensure these fields are not conflated;
parent and subject assertions are included. An initially incorrect expected author
date was corrected against the epoch conversion; the final focused 18 Blame tests
passed.

Native light QA verified blank fields before selection, selected restoration
metadata/body and cached parent subject, alongside line-2 source focus. The first
layout took excessive source width; the final version uses compact rows and a
narrower pane. Both isolated QA instances quit normally, one at a time, with no
process left running. HEAD, raw index and working source were identical to the
settled fixture baseline. The actual UI screenshot was inspected through CUA;
the save-to-file attempt lost its window and produced no PNG, so no new screenshot
is published. All 282 core tests passed after the change. Debug and App Store builds and both
bundle audits passed, including the 62 original icons and 11 universal Git
binaries; documentation site and whitespace checks passed. Dark mode,
multi-selection clearing, long-body/multi-line-subject handling, splitter resizing,
property text copy and hide/show require native acceptance.

## Properties text and date formatting

Reviewed upstream `GitRev.cpp`'s libgit2 `ParserFromCommit`, which splits raw
messages at the first newline, and `PropertiesWnd.cpp`, which trims Body and
formats local `CTime` values as `%Y-%m-%d %H:%M`. The existing Body split already
matched this behavior. Properties Subject now uses the raw first line rather than
Git `%s`, which folds the first paragraph. The full original log message remains
unchanged for clipboard output. Author and committer dates now use the local time
zone and minute precision with a fixed Gregorian/POSIX format. Unknown timestamp
strings are preserved rather than replaced with misleading dates.

Parent labels use seven-character hashes; help text retains the full hash and
cached subject. The parent context menu copies the full hash and uses the original
copy icon. It routes through the viewer's clipboard generation guard so an older
asynchronous log-copy request cannot overwrite the chosen parent hash.

Three focused presentation tests passed. Coverage includes a multi-line first
paragraph, Unicode body and trailers, single-line/empty messages, different
source offsets, UTC and Berlin summer time, winter time crossing midnight,
invalid timestamps and retained full messages. This supplements the prior
282-test full-suite baseline; the full suite was not rerun for this formatting
change. Debug and App Store builds and both bundle audits passed.

One isolated native light QA instance showed the first-line Subject, separate
local minute dates and abbreviated parent with full help text. A stale file-menu
accessibility ID was recovered by invoking the same observed Blame action with
keyboard navigation. The long-body scroll attempt returned `noWindowsAvailable`;
it does not establish scrolling acceptance. No new screenshot file was produced
or published. The app quit normally, process absence was verified, and HEAD,
raw index and working source stayed identical to baseline. Parent copy/icon
rendering, long-body scrolling, dark mode and full Properties interactions still
need native acceptance. Overall Blame remains partial.

## Whole-file source locator

Reviewed upstream `DrawLocatorBar` and `GetLineColor` in the pinned
`TortoiseGitBlameView.cpp`, plus `LOCATOR_WIDTH` in its header. The native strip is
10 points wide and sits left of the annotated source. It maps the full file into
integer vertical bands using loaded Log age ranks and saved palette endpoints.
The visible section blends age colors 10 percent toward the light/dark text color;
two one-point boundary lines mark its position. It does not use revision-selection
or hover colors, matching upstream's locator. Disabled age shading and hashes
absent from the Log use the window background. Source scrolling and resizing
invalidate the strip; its accessibility value identifies the current line range.
The strip is a visual overview, as in the reviewed upstream implementation.

A native 400-line fixture verified initial age bands and movement after Go To Line
200. The first check exposed an existing layout issue: showing selected-source
metadata shrank the source after the initial scroll and hid the selected line.
The container now tiles on resize and keeps the selected row visible. A second
native check verified line 200 visible after the footer appeared. Both QA
instances quit normally, one at a time; process absence was verified and HEAD,
raw index and source bytes were identical to baseline. The actual final screenshot
was saved, inspected and published as `site/assets/blame-locator-light.png`
(2240 by 1464), including the compact graph and Properties pane.

All four focused presentation tests passed. The new assertions compare upstream
integer viewport blending in light/dark modes and background behavior with age
disabled or an unmapped hash. This supplements the prior full-suite baseline;
no additional full-suite run was needed for the locator color helper. Debug and
App Store builds and both bundle audits passed, including the Finder extension,
62 original icon resources and 11 universal packaged Git binaries. The
documentation site build and whitespace check passed. Native dark/color-off
behavior, keyboard paging, resize
variants, empty/very long files and accessibility reading remain pending.
`NSTableView` can retain rows partly occluded by its header in `visibleRect`;
exact viewport boundaries against that header still require comparison and
acceptance. This partial locator does not establish complete Blame parity.

## Table-header viewport and dark acceptance

The locator now converts the native floating header into source-table coordinates
and removes its overlap from `visibleRect` before asking AppKit for visible rows.
This corrects the range previously including rows hidden behind the header. The
range includes partly visible first/last rows, consistent with the native clipped
table. Empty source/viewport states clear the accessible locator value rather
than leaving an earlier file's range.

Native dark QA on the 400-line fixture verified the initial range 1–10 and, after
Go To Line 200, range 193–202. The screenshot shows line 193 partly under the header,
line 200 selected/visible and line 202 partly at the bottom. The earlier range
192–201 included an occluded row; that geometry is now corrected for this case.
Turning Colorize by age off removed the source/locator age bands and retained the
viewport lines and shaded section. The actual age-on capture was saved and
inspected, then published as `site/assets/blame-locator-dark.png` (2240 by 1464).

A click/Page Down automation timed out, then its accessibility recheck timed out
and reset the CUA kernel. The same live PID was confirmed; no second app was
launched. A two-second process sample showed the main thread mostly idle in the
AppKit event loop, which does not support claiming an app hang. Rebinding to that
same app recovered the UI and normal Quit succeeded. The locator remained at the
previous range, so keyboard paging was not accepted. Process absence and exact
HEAD, raw index and source preservation were verified after Quit.

Debug and App Store builds passed without compiler warnings, and both bundle
audits verified the Finder extension and 62 original icons; packaged Git verified
11 universal Mach-O binaries and integration behavior. Documentation site and
whitespace checks passed. The geometry change
is confined to the native view; prior four presentation tests cover locator colors
and no implementation-mirroring test was added. Further light/header variants,
keyboard paging, scrolling, empty-file native accessibility and full Blame editor
parity remain pending. This evidence covers the observed dark scenario, not every
viewport configuration.

## Remaining work

- Native multi-revision selection acceptance, full locator acceptance and complete revision-log layout;
  pointer-hover and dark sticky native acceptance.
- Syntax highlighting, source selection and native editor scrolling behavior.
- Upstream Find/Go To Line dialogs, menu shortcuts, match highlighting and
  revision/block navigation.
- Clipboard presentation/localized dates, export commands and remaining original
  menu icons.
- Complete Blame settings layout, revision chooser, font preview drawing,
  native preset/color acceptance and full log preferences parity; native multi-window updates and unsaved Cancel acceptance.
- Persistent/system encoding defaults, chooser/accessibility parity, unsupported
  codecs and byte-LF within other UTF-16 code units; binary, malformed text and
  symlinks remain unsupported.
- Working/uncommitted content, Finder routing, cancellation/progress and signed
  sandbox acceptance, including security-scoped access retained by the window.
- Full light/dark visual comparison and keyboard/VoiceOver acceptance.

The native viewer is partial; populated controls do not establish full source-file parity.
