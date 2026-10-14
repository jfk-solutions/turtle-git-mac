# Merge resolved and edited presentation

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`,
`BaseView` resolved-state conversion/editing and `SetColorPage::SaveData`.

The General/Colors controls were already implemented. This batch connects their
remaining resolved/modified channels to actual editing behavior. Picking a conflict
block or whole side creates resolved presentation. Manual text edits use Modified
background and Added foreground, matching Edited's channel assignment in upstream
SaveData. Actual conflict marker ranges continue to override these colors.

Result provenance uses UTF-16 runs separate from file contents. Several disjoint
edits retain unchanged middle regions and previous resolved choices rather than
painting everything between the first/last change as added. Emoji and line-ending
changes retain the authoritative String. The result pane, locator and modified-only
Find consume the same projected states. Two-pane manual editing uses its existing
edited annotations for display/locator colors without changing alignment rows.

Block and ordinary native typing Undo/Redo retain presentation snapshots along
with text. Saving retains editing presentation while writing exact encoded bytes;
reload regenerates engine states and resets history. Palette/theme changes repaint
existing runs without changing text, dirty state or Undo. Format/ending edits use
Edited; explicit whole-side choice uses Resolved. No color metadata is written into
source files or the index.

Source state aliases beyond the current native normal/removed/added/conflicted/
resolved/edited/empty/filtered catalogue remain incomplete. Empty resolved display
gaps, full multi-pane source alias painting, physical/VoiceOver and signed/minimum-OS
acceptance remain open. These changes do not certify every Merge dialog/state or
the whole application. The Debug build and 23 relevant Core cases passed after exposing the immutable
display-cell initializer. The native receiver first required a corrected two-pane
wait property, then exposed Undo grouping that combined choice and typing. Native
typing now follows the complete edit path with explicit command groups. Core was
not repeated for those native-only repairs. The final two-case native group passed
result/history/colors and clipboard regression checks with all owned processes
reaped. No duplicate Git-engine run was needed for standalone file-state checks.
See [batch evidence](qa/merge-result-colors-2026-10-14.json).
