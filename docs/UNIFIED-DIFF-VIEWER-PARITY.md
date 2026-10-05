# Unified diff viewer selection

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.

This is a partial port of the unified patch viewer setting and the Shift actions
in Format Patch and Log. It does not complete TortoiseGitUDiff, external revision
comparison tools, extension-specific tools or all unified-diff callers.

| Source | Blob | Native replacement |
| --- | --- | --- |
| `src/TortoiseProc/AppUtils.cpp`, StartUnifiedDiffViewer | `ad5cf29edc933f6469fb9a961b84e8251f5fc563` | `UnifiedDiffViewer.swift`, Format Patch viewer dispatch |
| `src/TortoiseProc/Settings/SettingsProgsDiff.cpp`, GNU patch viewer controls | `9cd5e7c658477fd8120a7f521c8ce0f16cc10175` | `UnifiedDiffViewerSettings.swift` |
| `src/TortoiseProc/FormatPatchDlg.cpp`, unified diff button | `b8ad0c02bb27397700a6aee773d87ce7656d62c8` | `FormatPatchWindow.swift` |
| `src/TortoiseProc/GitLogListAction.cpp`, ID_GNUDIFF1/ID_GNUDIFF2 | `88c255c4c80578c099bbcd4604f6e088f2f9d40a` | `LogWindow.swift`, byte-preserving `CommitHistory.swift` APIs |

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
keeps its existing built-in diff sheet. Close and Quit are blocked while Log's
diff request/open callback is busy, and all external viewer callbacks have a
shared pending-request Quit guard. Merge-parent/combined variants and other
callers remain pending.

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

Remaining: native settings/application-launch and Shift QA; failed/stale bookmark
and missing-app acceptance; signed document handoff; command argument templates;
other unified-diff entry points; full TortoiseGitUDiff behavior; the other groups
and Advanced options in upstream's Diff Viewer settings page. See also
[FORMAT-PATCH-PARITY.md](FORMAT-PATCH-PARITY.md).
