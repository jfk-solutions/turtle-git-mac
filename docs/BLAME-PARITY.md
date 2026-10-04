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

BOM-less detection requires a consistent zero-byte pattern and valid UTF-16 with
printable text. A future encoding chooser is still needed for ambiguous files and
legacy code pages. Odd byte lengths, embedded NUL code units, unpaired surrogates
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

## Remaining work

- Multi-revision selection, full source locator and integrated revision-log layout;
  pointer-hover and dark sticky native acceptance.
- Syntax highlighting, source selection and native editor scrolling behavior.
- Upstream Find/Go To Line dialogs, menu shortcuts, match highlighting and
  revision/block navigation.
- Clipboard presentation/localized dates, export commands and remaining original
  menu icons.
- Blame options dialog, revision chooser, complete copied-line modes/thresholds,
  settings and persistent preferences.
- An encoding chooser, ambiguous BOM-less UTF-16, legacy encodings and byte-LF
  within other UTF-16 code units; binary, malformed text and symlinks remain unsupported.
- Working/uncommitted content, Finder routing, cancellation/progress and signed
  sandbox acceptance, including security-scoped access retained by the window.
- Full light/dark visual comparison and keyboard/VoiceOver acceptance.

The native viewer is partial; populated controls do not establish full source-file parity.
