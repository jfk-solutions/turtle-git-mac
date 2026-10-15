# Unified diff viewer selection

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.

This is a partial port of the unified patch viewer setting and the Shift actions
in Format Patch, Log, Commit, Working Tree and Changed Files. It does not complete
TortoiseGitUDiff, external revision comparison tools, extension-specific tools or
all unified-diff callers.

| Source | Blob | Native replacement |
| --- | --- | --- |
| `src/TortoiseProc/AppUtils.cpp`, StartUnifiedDiffViewer | `ad5cf29edc933f6469fb9a961b84e8251f5fc563` | `UnifiedDiffViewer.swift`, Format Patch viewer dispatch |
| `src/TortoiseProc/Settings/SettingsProgsDiff.cpp`, GNU patch viewer controls | `9cd5e7c658477fd8120a7f521c8ce0f16cc10175` | `UnifiedDiffViewerSettings.swift` |
| `src/TortoiseProc/FormatPatchDlg.cpp`, unified diff button | `b8ad0c02bb27397700a6aee773d87ce7656d62c8` | `FormatPatchWindow.swift` |
| `src/TortoiseProc/GitLogListAction.cpp`, ID_GNUDIFF1/ID_GNUDIFF2 | `88c255c4c80578c099bbcd4604f6e088f2f9d40a` | `LogWindow.swift`, byte-preserving `CommitHistory.swift` APIs |
| `src/Git/GitStatusListCtrl.cpp`, IDGITLC_GNUDIFF1 | `bb3424966659715269d38fca610c8d46810b0b15` | `CommitWindow.swift`, `StatusWindow.swift`, raw patch/working-tree diff APIs |
| `src/TortoiseProc/FileDiffDlg.cpp`, ID_GNUDIFFCOMPARE/CheckMultipleDiffs | `fe4171a852023344cac5af1711873104393e1b0a` | `RevisionComparisonWindow.swift`, raw comparison patch API |
| `src/TortoiseUDiff/MainWindow.cpp`, SaveFile | `fc1d4053019e4b8bc5c2a1c08837d19c7c506751` | `UnifiedDiffDocument`, read-only `PatchWindow` Save As |

## Selection rules

Upstream keeps an external viewer command in `DiffViewer`. A leading `#`
disables it while retaining its configuration. Shift reverses that choice.
Native preferences represent enabled/disabled explicitly and preserve the saved
application and security bookmark independently of Alternative Editor settings.

| Saved external viewer | Ordinary click | Shift click |
| --- | --- | --- |
| None | Built-in | Built-in |
| Configured and enabled | External | Built-in |
| Configured and disabled | Built-in | External |

Invalid configured application paths report an error when the external viewer
is requested; choosing the built-in viewer does not launch them. Settings use
the source's GNU patch viewer group, built-in/external radio choices, path field
and Browse button. Disabling the external viewer keeps its path/bookmark.
Application bundles retain native document opening when their Arguments field is
empty. Configured argument templates and executable tools are supported by the
external-document continuation below; complete Windows command/environment and
signed macOS launch equivalence remain unverified.

## Native handoff and lifetime

Format Patch samples Shift before its asynchronous HEAD/working-tree diff runs.
The built-in choice displays the existing read-only syntax-colored Patch window.
Its Refresh updates that same window directly; it does not reselect an external
viewer from changed preferences. External selection writes the original Git
stdout bytes into a unique private directory (0700) and `diff.patch` (0444),
without a lossy text conversion. A failed launch discards only that owned preview;
a successful launch retains it until TurtleGit exits. Output files in the user's
repository are unaffected.

Log revision and selected-file context actions also sample Shift before their
asynchronous diff request, and share the external launch/preview lifetime. A
whole working-tree row now uses that same external/built-in selection instead
of always opening the built-in viewer. Revision, working-tree and selected-file
reads discard their viewer handoff when selection changes or Log is invalidated;
late errors from those stale requests are discarded too.
An external launch already handed to macOS is not recalled by changing selection.
A single revision retains first-parent/root behavior; two revisions retain the
older-to-newer comparison. Selected files retain visible order, duplicate
suppression and both paths for renames. Core now exposes Data-returning diff
APIs; existing String callers keep their prior UTF-8 presentation. Native Log
now uses the shared colored read-only patch window for its built-in choice. Close and Quit are blocked while Log's
diff request/open callback is busy, and all external viewer callbacks have a
shared pending-request Quit guard. Merge-parent/combined variants and other
callers remain pending.

The October 7 hidden native check exercises whole working-tree external selection
with an invalid configured application, including a disabled viewer requested
with Shift. Those requests report the configuration error without launching an
app or opening the built-in viewer. It checks enabled-plus-Shift built-in choice
through the shared selector, exact literal-path patch bytes through an injected
viewer, and stale working/revision/selected-file reads after selection changes or
invalidation. HEAD, index and working bytes remain unchanged across all four Git
versions. This does not establish successful external application launch or
displayed viewer acceptance.

Commit's explicit unified-diff menu now shares this dispatch, including its
staged/unstaged and amend-to-parent comparisons. Working Tree adds the explicit
unified-diff menu next to Diff, which continues to open the ordinary comparison
viewer. Both unified actions sample Shift before async Git and retain a busy
guard through the external receiver callback. Working Tree Close/Quit also
blocks while busy or a save sheet is open. Its Save unified diff writes the
original Data to the selected file rather than decoding/re-encoding it. Existing
partial-staging previews still reject non-UTF-8 patches, avoiding lossy editable
patch application. Native menu activation, chooser/receiver completion, row-order
and rename variants remain unverified.

Changed Files now separates the explicit unified-diff context command from
View Patch. The context command opens one viewer per selected file in visible
order, honoring the shared setting and Shift. Each built-in context viewer
refreshes its captured resolved revision snapshot instead of following later
dialog changes, and is reused by path. External viewers receive the original
bytes. Rename patch scope includes old and new names. The multi-diff warning
uses upstream's default ten and minimum three, with the optional native
`NumDiffWarning` Advanced setting. The older `TurtleGit.NumDiffWarning`
alias is migrated when the setting is edited or cleared. Individual failures are reported together after trying remaining files.
View Patch stays built-in and follows selection. Parent Close/Quit guard busy
context viewers, which close with their parent; patch windows also guard their
own busy/confirmation/sheet lifetime. These native behaviors compile but have
not been interactively verified.

Read-only patch windows retain a `UnifiedDiffDocument` containing original bytes
separately from their UTF-8 display/parser text. Format Patch, Changed Files
context viewers, View Patch and Commit's read-only preview now feed this data
through refresh. Save As captures the document before showing the panel and
writes that immutable snapshot atomically. Direct replacement of the displayed
document invalidates the old raw snapshot; switching back to editable staging
also drops it. Busy/confirmation/sheet guards prevent overlapping Save panels
and protect Close/Quit. Invalid UTF-8 is still shown using replacement characters;
encoding selection, editable UDiff behavior and exact native Save panel/refresh
acceptance are pending. This ports byte-oriented read-only output, not the full
upstream Save/Edit workflow.

The selected application's bookmark is resolved and scoped for the native open
request. Store builds require successful scoped access; the error directs the
user to Browse when needed. The Format Patch controller blocks close, Quit and
input changes while the open request is pending, retaining the preview through
NSWorkspace completion. Actual receiver timing and signed document acceptance
remain unverified. App termination cleans up retained owned previews. A saved
viewer is not actually launched during automated tests.

Settings now reserve 760×700 points for the existing tabs plus Unified Diff
Viewer. Actual tab visibility, light/dark layout and keyboard behavior remain
unverified. App inventory responded during this turn's QA attempt, but both
attempts to inspect the one running preview failed with “Sky Computer Use native
pipe closed before response.” No accessibility state or screenshot was returned.
The exact owned PID/executable was rechecked and terminated because normal Quit
was unavailable through that connection. No screenshot is fabricated for this change.

## Evidence and remaining work

Three `UnifiedDiffViewerTests` verify all selection states, invalid paths, saved
disabled configuration, independence from Alternative Editor preferences, exact
non-UTF-8 preview bytes, private/read-only modes, independent copies and cleanup.
These tests do not verify NSWorkspace launch, security bookmarks, actual Shift
clicks, settings geometry or signed App Store behavior.

The six CommitHistoryTests also pass after the byte-preserving refactor. A new
real-Git regression generates a patch containing invalid UTF-8 text bytes,
verifies selected-file output and duplicate suppression, and passes Git's
reverse-apply check on the exact external preview. HEAD-relative working-tree
output also retains those bytes; generation/checking leave the index unchanged.
No GUI app or external viewer was launched for this Log follow-up.

A further 17 focused tests (UnifiedDiffViewer, GitPatch and WorkingTree) pass.
The new real-Git test distinguishes staged, unstaged and complete working-tree
changes containing invalid UTF-8 bytes, verifies exact preview applicability
against the index, checks partial-staging's encoding refusal, and preserves
HEAD/index/working bytes. Existing unborn working-tree and staged-hunk cases also
pass. This proves the Core byte routes, not native Commit/status menu or Save
panel acceptance. No GUI app or external viewer was launched for this follow-up.

Changed Files follow-up: 19 focused RevisionComparison/UnifiedDiffViewer tests
pass. The new real-Git regression verifies exact invalid-UTF-8 patch bytes,
reverse-apply checking, unchanged index/working bytes and a resolved snapshot
that remains stable after HEAD advances. Paths absent from that snapshot are
rejected. This does not verify native per-file ordering, warning, Shift, receiver
handoff or context-viewer refresh. No GUI app was launched for this follow-up.

Read-only Save follow-up: 25 focused UnifiedDiffViewer/GitPatch/RevisionComparison
tests pass. A new filesystem test verifies empty content, UTF-8 BOM/CRLF/no final
newline and invalid UTF-8 Save output, captured-document stability after a newer
document replaces it, replacement of an existing saved file and directory-target
failure without losing that file. The real-Git staged/working test also covers
raw read-only working-tree patch bytes. These are portable Core checks; native
model invalidation, panel Cancel, keyboard/menu invocation and signed output
grants remain unverified. No GUI app was launched for this follow-up.

Remaining: native settings/application-launch and Shift QA; failed/stale bookmark
and missing-app acceptance; signed document handoff; command argument templates;
other unified-diff entry points; full TortoiseGitUDiff behavior; the other groups
and Advanced options in upstream's Diff Viewer settings page. See also
[FORMAT-PATCH-PARITY.md](FORMAT-PATCH-PARITY.md).


Built-in presentation follow-up: Log revision/selected-file, Commit and Working
Tree explicit unified actions now use the shared syntax-colored patch window
with Find and original-byte Save As instead of plain OutputView sheets. A parent
retains one context viewer, reuses it for explicit new requests, and closes it on
parent close. Active Save sheets guard parent close and replacement. These
context windows keep their generated snapshot and hide Refresh, matching the
upstream UDiff menu rather than silently following selection changes. Embedded
staging/selection previews keep their existing Refresh behavior. Save As is
visible with the existing original icon and responds to Command-Shift-S; the
context action remains. Source accelerator pin: `TortoiseUDiff/TortoiseUDiff.rc`,
blob `1a5c590842d2d99b38eb53a6f11aa640f0d1cbca`. Working Tree presentation and basic Save/Find/Escape acceptance are recorded
below; the other routes, focus variants and dark mode remain unverified. Full
File/Open/Save/editing/encoding/Print/Apply Patch and settings remain pending.
The Core implementation is unchanged from the preceding 25-test acceptance;
that evidence does not prove the new native routes.


Native acceptance for this presentation follow-up: Working Tree unified menu
opened the colored read-only viewer; green additions, blue hunk headers and the
original Save As icon were visually inspected. Toolbar Save As and
Command-Shift-S opened the native chooser; Cancel returned to the unchanged
viewer. Keyboard filename editing was needed after AX setValue to trigger Save
validation. Actual export matched Git output exactly (254 bytes, SHA-256
`f6713365999ae746ec2c0d892ed86a4f7eb89cc416ec375cc12960b21b6d96dc`) and
preserved HEAD/index/working bytes. Command-F opened Find; Escape closed Find,
then the viewer. A transient ScreenCaptureKit -3811 error did not prevent later
AX verification. [Actual native capture](site/assets/unified-diff-viewer-light.png).
Commit menu appeared but activation did not establish a viewer; its close
confirmation inspection then timed out. Normal Quit did not end the process;
the exact owned PID/executable was rechecked and SIGTERM sent. No preview remains.
Log/Commit route activation, dark mode, Find matching, repeated-viewer reuse,
non-UTF-8 native Save and signed sandbox acceptance remain unverified.


A fresh single-instance acceptance retry at `07e8895` verified Commit Cancel’s
No keeps the dialog open and Yes closes it normally (three changed files, empty
message, staging off, no restore copies). The earlier close/inspection timeout
did not reproduce, and no cause or code defect was established. In that same
instance, Log double-click on `cc4ec2840a76b97fe6f7c46debd7a0288c11913c` opened
the shared read-only viewer with the expected newly added Repository.swift patch.
Normal Command-Q exited with Log/viewer open; no process remained and no signal
was needed. Exact HEAD/index/working state still matched the preceding owned
fixture snapshot. [Acceptance record](qa/commit-close-log-unified-2026-10-05.json).
This verifies the double-click route only; explicit Log/Commit menus, multi-row
variants, changed-message/restore/suppression cancellation and signed acceptance
remain pending. The earlier timeout record remains valid historical evidence.

## Appearance settings (native acceptance pending)

The native Appearance tab ports the six foreground/background pairs from
`IDD_SETTINGSUDIFF`: command, position, header, comment, added lines and removed
lines. Light and dark palettes can be configured separately. Restore Default
resets the selected palette only; font and tab size remain unchanged. The Font
group offers fixed-pitch fonts, font size and tab size. Menlo replaces the Windows
Consolas default. Apply persists preferences and updates open patch viewers.

| Source | Blob | Replacement |
| --- | --- | --- |
| `src/TortoiseProc/Settings/SettingsTUDiff.cpp` | `f7013ed3cb19b7c3c625d98c8d15e437a6862da6` | Native appearance settings |
| `src/TortoiseProc/Settings/SettingsTUDiff.h` | `f4ab493bfaf15d299da6c47a0ffe0ef0ef775968` | Native settings state |
| `src/TortoiseUDiff/UDiffColors.h` | `65d7e61aa154245193bce08fbbea75d2f4c49034` | Light/dark default RGB palettes |
| `src/TortoiseUDiff/MainWindow.cpp` | `fc1d4053019e4b8bc5c2a1c08837d19c7c506751` | Line styles, font and tab spacing |

The line classifier follows [pinned LexDiff.cxx](https://github.com/ScintillaOrg/lexilla/blob/ef08a1a00ce151ccdddf7da700fbe1a4934a9c71/lexers/LexDiff.cxx).
The renderer retains line termination for classifier decisions, including CRLF.
Combined added/removed styles share their corresponding palettes. Comments are
bold. Increased contrast uses native system text/background colors. Lexilla's
copyright and permission notice are included in the bundled NOTICE.

| Style | Light foreground/background | Dark foreground/background |
| --- | --- | --- |
| Command | `0A2436 / FFFFFF` | `C9E2F5 / 202020` |
| Position | `FF0000 / FFFFFF` | `FF2020 / 202020` |
| Header | `800000 / FFFF80` | `C00000 / 303000` |
| Comment | `008000 / FFFFFF` | `008000 / 202020` |
| Added | `000000 / CCFFCC` | `DDDDDD / 104010` |
| Removed | `000000 / FFDDDD` | `DDDDDD / 402020` |

Focused tests cover classification, palette defaults, separate-theme restoration,
preference persistence and invalid-value recovery. Native layout, live Apply,
light/dark rendering, high contrast and full-width line backgrounds still need
acceptance. Font size preset dropdown and owner-drawn font preview remain pending.
Existing viewer screenshots precede these palette changes. Lexer
folding, editable UDiff, printing and full encoding controls remain incomplete.

### Native settings navigation acceptance

Native testing exposed Settings toolbar promotion of the inner TabView: its
Appearance entry selected the global Appearance page. Unified Diff now uses an
in-page segmented selector. The corrected preview showed all twelve default
color wells and font/tab controls while retaining the Unified Diff toolbar tab.
The [actual settings capture](qa/unified-appearance-settings-light.png) was
inspected. Full footer geometry and live Apply remain pending; a Settings-close
AX timeout prevented those checks. Both isolated previews quit normally and no
TurtleGit process remained. No Core code changed in this navigation fix.
See [acceptance record](qa/unified-appearance-navigation-2026-10-05.json).

### Scrollable settings and editable size presets

Appearance settings now place color/font controls in a scroll view and reserve
the footer outside it, so content growth can scroll independently of Cancel and
Apply. The editable native font-size combo offers 6, 8, …, 30 and accepts typed
sizes, following SettingsTUDiff.cpp. Blame reuses the same existing combo through
`NativeFontSizeChoice`; its preset/delegate behavior is unchanged.

Both Debug and unsigned App Store builds and bundle audits pass. A single native
preview opened a Log diff and reached Unified Diff settings, but the computer-use
native pipe closed before the new Appearance page could be observed. A reconnect
failed too. The exact owned process was verified and terminated with SIGTERM;
no app process remained. No fresh screenshot, geometry acceptance, preset
selection, dark rendering or live Apply pass is claimed. The prior screenshot
precedes this scroll/preset change. Owner-drawn font preview remains pending.
See [verification record](qa/unified-appearance-footer-2026-10-05.json).

## Native Print command (partial port)

`PatchPrinting.swift` adapts MainWindow.cpp `ID_FILE_PRINT` at blob
`fc1d4053019e4b8bc5c2a1c08837d19c7c506751`. Command-P replaces the source
Control-P accelerator from TortoiseUDiff.rc. Toolbar and context Print actions
share the same handler, including the native responder `print:` action.

Printing captures an independent attributed snapshot and the current selection.
The native sheet's Unified Diff accessory selects printed text by default when
a nonempty range is selected; without a selection it prints the whole diff and
disables the selection choice. The accessory can switch to the whole diff.
Native copies, page range, paper size, orientation, scaling, preview and PDF
output replace the Windows printing interfaces. A retained operation and busy
state block Close, Quit, staging, refresh and duplicate printing until its
callback finishes. The displayed diff, selection and original Save As bytes are
not passed to pagination as mutable storage.

The implementation uses Apple's [print sheet callback](https://developer.apple.com/documentation/appkit/nsprintoperation/runmodal%28for%3Adelegate%3Adidrun%3Acontextinfo%3A%29)
and [native print responder action](https://developer.apple.com/documentation/appkit/nsview/printview%28_%3A%29).
`python3 scripts/test-patch-printing.py` compiles the real print helper and checks
PDF output without opening TurtleGit or a print sheet: a one-page selected
snippet excludes whole-document markers; a fresh whole-diff operation produces
six pages retaining the first and last markers; changing the caller's mutable
source after Print cannot alter the snapshot. Each real print request creates a
new operation; the test also uses independent operations for its saved PDFs.

Print sheet Cancel/completion, preview switching, paper variants, colors/fonts,
physical printers, signed sandbox access and File-menu exposure remain pending.
No native UI verification is claimed while the computer-use pipe is unavailable.
This does not complete UDiff's editable document, Open or all print behavior.

## Shared File-menu commands and native print acceptance

`PatchFileCommands` exposes Save As and Print in the macOS File menu, with the
source's Command-Shift-S/Command-P accelerator adaptations. `PatchMenuContext`
observes the key window and its model, disables both actions outside a diff or
during an operation/sheet, and rechecks the active controller when dispatching.
It holds no strong reference to a closed/background diff controller.

Native acceptance on a single isolated preview verified disabled commands in
Log, enabled commands in the active diff, File-menu Save As and Cancel, File-menu
Print and Cancel, disabled File commands while the print sheet is active, and
usable viewer controls after printing is cancelled. Command-A then Command-P
checked that the Unified Diff print accessory defaults to selected text; its
checkbox switched to whole diff and refreshed the preview. There was no printer
selected, so physical output was not attempted. The app quit normally and no
TurtleGit process remained. No new screenshot was captured in this check.

This advances the earlier print-sheet acceptance status. Page Setup's four
persistent margins, physical printers, partial-selection preview content,
multiple diff windows, Settings focus, queued busy transitions and signed
sandbox acceptance remain pending. See [native record](qa/unified-file-menu-2026-10-05.json).

## Page Setup margins

The native File → Page Setup sheet adapts MainWindow.cpp `ID_FILE_PAGESETUP`
and its print-margin conversion at blob `fc1d4053019e4b8bc5c2a1c08837d19c7c506751`.
Four saved margins start at one inch (25.4 mm / 72 points). Fields use the local
measurement system and decimal separator. Preferences store print points so a
locale change does not reinterpret the saved dimensions. Paper/orientation stay
in Print, following the source Page Setup's disabled paper/orientation controls.
OK persists valid margins; Cancel discards edits. Impossible/nonfinite/negative
margins are rejected, and stored malformed data falls back to source defaults.

Printing applies the saved margins and the current printer's minimum imageable
bounds. The current PDF fixture produces six pages at the source defaults and
eleven with larger top/bottom margins, retaining the first/last text markers.
An impossible area fails before showing Print. The three margin tests and eight
existing appearance/viewer tests pass. Both targets and bundle audits pass.

Native acceptance verifies metric defaults, negative input disabling OK, Cancel
preserving preferences, saving 12.7 mm, and reopening that value. The single
isolated preview quit normally; no app process remained. No new screenshot was
saved. Inch-locale UI, locale changes, native Print after a saved margin edit,
paper/printer changes inside Print, physical printer minimums and signed sandbox
acceptance remain pending. See [verification record](qa/unified-page-setup-2026-10-05.json).

## Native fixed-pitch font preview menu

`NativeFixedFontChoice` replaces the font-name picker with a native NSPopUpButton.
Each item retains its family name and uses an attributed title rendered in that
family's fixed-pitch face. The current saved family remains available if it is
missing from font enumeration, with a native monospaced preview fallback. The
binding stores the family name; the viewer still resolves the selected family
through NSFontManager. This adapts SettingsTUDiff.cpp `m_cFontNames.Setup` and
the font combo's owner-drawn resource style. Core preference behavior is unchanged.

Debug/unsigned App Store builds and bundle audits pass. A single fresh preview
opened the default-font Log diff and Settings. Entering the Appearance subpage
then lost the computer-use native pipe; retrying the same window failed too.
The attempt to quit normally was rejected because computer use was inactive.
Only the exact owned preview PID 1283 was revalidated and sent SIGTERM; no
TurtleGit process remained. No new screenshot or font-preview/live-Apply/dark
acceptance is claimed. The cause of the controller failure is not established.
See [verification record](qa/unified-font-preview-2026-10-05.json).


## Shared patch read/render lifetime — 2026-10-13

The shared native patch renderer now preserves the display document's final
newline state. Default working-tree/index readers own cancellable processes,
ignore obsolete results, and retain Quit accounting until every reader/mutation
settles, including after forced window closure. Original bytes still drive
Copy/Save/export independently of display decoding. These changes also serve
Commit's attached partial editor; its source-style bottom Find and Staging menus
are documented in [Commit parity](COMMIT-PARITY.md#attached-patch-window-find-and-owned-operations--2026-10-13).
Read-only viewers retain their existing toolbar and native macOS Find. External
owners' custom loaders and physical print/save/panel acceptance remain separate
from the default-read coverage of this batch.

## Editable documents, file actions and source Find — October 15, 2026

Standalone built-in UDiff windows now enable editing after their patch loads,
following `MainWindow.cpp` `InitEditor`/`SetupWindow`. Commit's partial patch and
embedded import previews retain their separate staging/read-only gates. Native
plain-text editing disables automatic quotes/dashes/replacements; syntax style
updates change attributes without replacing the edited text or clearing Undo.
Loading another document resets selection and Undo, even for identical text.
Undo back to the saved display text restores the original export bytes.

The focused UDiff window's File → Open (Command-O), Save (Command-S) and Save As
(Command-Shift-S) own the chosen patch file. Open accepts a single patch/diff or
other text file, holds its selected permission, refuses files reaching the source
250 MiB limit and fences late reads after forced closure. A file permission does
not select or grant a repository. Save As establishes the new destination; later
Save uses it. Direct Save refuses an externally changed file instead of replacing
it silently. Writes use atomic replacement. Original bytes are retained until
editing; edited files preserve detected UTF-8/UTF-16/UTF-32 BOM/endianness or the
existing Windows-1252 fallback. Unrepresentable legacy edits report an error and
leave the file unchanged. There is no encoding-conversion picker yet.

Close, Open, Refresh/replacement and app Quit resolve modified documents using
Save / Don’t Save / Cancel. Cancelled questions/panels retain the edits and Undo.
Normal parent closure for Graph, Changed Files, Format Patch and Send Mail first
routes an edited child through its own close decision. Forced retirement fences
late UI publication and retains operation/Quit accounting through owned file I/O.
The file-document session captures its own window; shared menu commands recheck
the focused controller and refuse background windows and active sheets.

`src/TortoiseUDiff/TortoiseUDiff.rc` **IDD_FINDBAR** now maps its six controls to
the shared native bottom bar, in source order: upstream `cancel-normal.ico`,
Find label, search field, Previous, Next and Match case. Command-F seeds selected
text and focuses Find; typing resets the cursor to zero and searches forward.
Next/Previous use the current selection end/start, stop without wrapping and
flash the owning frame on a boundary. Escape hides Find before closing its
window. Command-G/Shift-Command-G and F3/Shift-F3 use the same search actions.
Match case changes the next query; there is no extra regex or wrap option.
The same source bar remains available in attached partial patches. Embedded
Import/Review previews have no bottom-bar host and retain AppKit Find, with
read-only text and native show/hide checked separately.

The native checkpoint checks actual NSTextView edits/Undo and clean savepoints,
raw bytes, UTF-16 saves, legacy-encoding refusal, file-open/save cancellation,
external-change refusal, Cancel Quit, focused menu routing, source Find and an
uncooperative read settling after forced closure. The retained partial fixture
checks real line stage/hunk unstage, index isolation and Git process cleanup.
See [dated evidence](qa/unified-document-2026-10-15.json).

This remains a partial port. Source-specific byte/codepage search equivalence,
all physical panel/keyboard/context-menu gestures, multi-owner replacement titles
and interleavings, all ordinary parent-close decisions, arbitrary encodings,
huge/network-file behavior, filesystem publication cancellation races, signed
file grants, App Store execution and full UDiff layout/accessibility acceptance
remain open. In-flight writes may finish after a forced close; their late UI
result is suppressed. This batch does not add Apply Patch routing or certify the
dialog complete. Earlier read-only/native-Find descriptions document older states.

## Apply Patch, Settings and comparison replacement — October 15, 2026

The standalone document's File/context menus now expose **Apply Patch…** and
**Unified Diff Settings…** with the existing source artwork. Save remains visible
and disabled during owned work/sheets. Commands recheck the focused owner;
context actions also expire when their captured document identity changes.

Apply Patch follows `MainWindow.cpp` `ID_FILE_APPLYPATCH`: a named patch is passed
to the existing TurtleGitMerge review/apply workflow using its saved file, not
unsaved editor text. A generated comparison uses its immutable loaded bytes,
the native equivalent of TortoiseProc's read-only temporary patch in
`AppUtils.cpp` `StartShowUnifiedDiff`/`StartUnifiedDiffViewer`. A genuinely empty,
unnamed document uses the workflow's patch-file chooser. Target selection and
better-target detection retain their existing permission boundaries. Opening
review does not apply changes; the review window owns the subsequent Apply.
The originating patch, preferences, Git engine and retained file/repository
permissions are captured. Closing the UDiff owner during preparation cancels
that preparation and fences late review presentation. A prepared review is
independent, as in the source's detached Merge handoff.

Settings opens the existing native settings controller directly on **Unified
Diff**, using the owning preferences and a global-only settings context. Its
sheet locks document actions until dismissal. The settings navigator's optional
initial-page argument defaults to General for existing callers.

Standalone comparison producers now publish bytes, title, comparison labels,
paths, information and Refresh closure through one owned replacement request.
While an unsaved-change question is active, newer requests replace the pending
request; Cancel retains every field of the displayed document. A successful
Save or Don’t Save publishes only the latest request. Cancelled Save As also
retains the old context. Replacements clear obsolete saved-file identities and
retain a supplied source file's existing grant where applicable (Send Mail).
Refresh callbacks capture the document identity so an older read cannot replace
a different document opened in the same window. Embedded/Commit previews keep
their separate presentation paths.

The connected native evidence, including an actual saved-patch review/apply in a
private working tree, is recorded in [handoff QA](qa/unified-handoffs-2026-10-15.json).
This advances the previous batch's Apply Patch and replacement-metadata gaps.
Physical menu/panel gestures, all Settings Apply/font/palette transactions,
full producer-specific timing races, signed grants/App Store execution and
complete UDiff parity remain unverified. No dialog is certified complete.

## External viewer arguments and executable tools — October 15, 2026

Unified Diff Viewer now stores an **Arguments** field beside its selected app or
executable. `%1` supplies the patch path; `%title` supplies the captured comparison
title. If `%1` is absent, the patch is appended. For example, a tool that accepts
those flags can use `--title "%title" "%1"`. Quote grouping is parsed before
substitution, so spaces, Unicode, quotes, newlines and placeholder-looking text
in a filename/title remain within their original argument. There is no shell or
environment evaluation. Unfinished quotes/escapes and NUL values are refused.

This follows `AppUtils.cpp` `StartUnifiedDiffViewer`'s placeholder and implicit
patch argument behavior. Windows combined command text is represented by a
separate application/executable path and Arguments field. Existing preferences
load an empty Arguments value: app bundles continue native URL document opening.
A nonempty template uses a fresh app launch with expanded argv. Executables
always receive expanded argv. Built-in/external and Shift inversion retain the
selected path, bookmark and template, including while the external choice is
disabled. Choosing the built-in viewer does not evaluate invalid external args.

Callers now forward the same title used by their built-in comparison, along with
owning preferences and available grants. This includes Log, Commit/Status,
Changed Files, RefLog, reference browsers, Blame, Rebase conflict output, Sync,
Graph, Add, patch import and Send Mail. Format Patch's direct external launch
also forwards its template and HEAD-to-working-tree title.

The shared native launcher resolves the selected program bookmark, starts and
retains its scope through app-launch completion or managed executable settlement,
and preserves original-byte previews for successful detached viewers. Failed
launches remove only that request's preview. Cancellation before launch refuses
the tool. Executables use the existing Diff/Merge process pool and its group
cancellation/reaping; their caller grants survive a closed initiating window.
A lost program permission points to Browse in Settings, independently of the
repository-folder recovery used for missing file access.
External tools are independent after startup. Quit remains guarded while owned
launches or managed children are active, following the existing tool lifetime
policy. Signed grant transfer and arbitrary third-party app CLI/document behavior
remain unverified.

Alternative Editor uses this same launcher for app bundles or executable files,
retaining the source's single literal filename argument and TextEdit fallback.
It does not acquire a UDiff argument template. Working-file callers retain their
repository grants; historical/configuration previews keep their existing private
file lifetimes. Queued editor startup participates in the Quit guard.

See [external-document evidence](qa/external-documents-2026-10-15.json) for the
18 focused Core cases and native family check, actual private executable argv,
scope-provider simulations, descendant cleanup and current Settings-field scope.
No real user editor app was launched. Complete source command/environment
equivalence, physical Browse/panel gestures, every caller-specific race, signed
App Store/Finder execution and full dialog parity remain open.

The GNU patch group in `IDD_SETTINGSPROGSDIFF` maps its group title,
`IDC_DIFFVIEWER_OFF`/`IDC_DIFFVIEWER_ON`, command field and Browse to the native
GroupBox, radio picker, separate program/Arguments fields and owned chooser.
Those five source controls remain partial mappings; physical radio/Browse,
complete Diff settings geometry and signed permission acceptance are pending.
