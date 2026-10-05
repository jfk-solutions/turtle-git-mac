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
Application bundles and native document opening replace Windows command-line
launching in this implementation. Custom argument templates and `%1`/`%title`
substitution are still pending, so external command parity is incomplete.

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
single revision retains first-parent/root behavior; two revisions retain the
older-to-newer comparison. Selected files retain visible order, duplicate
suppression and both paths for renames. Core now exposes Data-returning diff
APIs; existing String callers keep their prior UTF-8 presentation. Native Log
now uses the shared colored read-only patch window for its built-in choice. Close and Quit are blocked while Log's
diff request/open callback is busy, and all external viewer callbacks have a
shared pending-request Quit guard. Merge-parent/combined variants and other
callers remain pending.

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
`TurtleGit.NumDiffWarning` preference; an Advanced settings editor remains
pending. Individual failures are reported together after trying remaining files.
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
