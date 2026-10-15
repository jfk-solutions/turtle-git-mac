# Shared message hotspot interaction — partial port

Source host resources include `IDD_COMMITDLG`, `IDD_MERGE`, `IDD_REBASE`,
`IDD_INPUTDLG` and `IDD_LOGMESSAGE`. Existing control mappings remain partial.

Baseline: pinned SciEdit.cpp's SCN_HOTSPOTRELEASECLICK/SCN_DWELLSTART handling,
LogDlg::OnEnLinkMsgview and the existing source issue/URL styling at
`7338078f8ddd924b8cddee35f512f2286072136d`.

Commit, Merge, the shared Rebase message editor, Input, Edit Notes and branch
Description now share an explicit AppKit hotspot handler. It takes the styled
range's actual target, preserving source issue escaping and ordinary URL/email
values, and prevents default AppKit dispatch from bypassing its owner checks.
Commit's delegate entry point uses the same handler. Native target tooltips keep
the resolved literal address; styling and message bytes are unchanged.

The editable pane's Open link and Copy link address commands capture text bytes,
styled range, target, owner window and interaction generation. Editing, restyling,
detachment or closure invalidates old commands, including restoring the exact old
text. Nonempty selection suppresses opening; disabled editors, marked text,
blocked models and owned sheets prevent target actions. A successfully accepted
open remains an ordinary explicit NSWorkspace request; it is not revoked after
another application accepts the URL.

Native link-specific AppKit actions are removed by selector, independent of menu
language, so they cannot open an unvalidated current target alongside the captured
commands. Existing editing/spelling/history menus remain. Open/Copy and standard
Copy/Paste/Undo/Redo/Delete use the available upstream artwork and the owning
ShowAppContextMenuIcons preference. Cut uses a native scissors glyph because no
Cut artwork is shipped. Log uses the same menu-item implementation and URL adapter,
while retaining its separate read-only hash/message identity and navigation guards.

Source review corrected the previous relative-URL gap description: LogDlg has
GetAbsoluteUrlFromRelativeUrl, but m_sRepositoryRoot has no assignment in the pinned
source, and SciEdit sends its target directly to ShellExecute. This batch preserves
literal target dispatch and does not infer a Git remote as that repository root.
Working remote-relative issue URL behavior is therefore not claimed. Foundation
URL construction/encoding replaces ShellExecute parameter handling on macOS.

Actual public tracker/browser acceptance, physical click/hover/context-menu and
VoiceOver gestures, every localized native menu variant and signed App Store
behavior remain open. This family does not certify complete dialog parity.

## Grouped checkpoint — October 15, 2026

The Debug build passed. Six native cases (new links, existing styles and rich Log,
each with system and bundled Git) passed using one cached app-object link and
one fixture compilation. All six receivers were reaped and checked absent.
Core was unchanged and was not rerun. The new fixture required explicit
synchronous sheet completion, router-equivalent Merge/Commit loading and exact
Git-created note bytes rather than the unnormalized notes input. Two earlier
stalled receivers were explicitly terminated/reaped after sampling/phase tracing;
two subsequent fixture failures and their corrections are recorded in
[exact evidence](qa/source-message-links-2026-10-15.json). No production rebuild
or source behavior change was needed for those fixture repairs.
