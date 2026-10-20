# Synchronization reference and tag results

This partial family review follows pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`, `IDD_SYNC`,
`GitRefCompareList.cpp`, `GitTagCompareList.cpp` and their SyncDlg callers.
It covers the Ref List and Compare Tags result tables and their connected Log,
RefLog, comparison and tag-operation routes.

## Source controls and display

Ref List has seven fixed columns: Reference, Type, Change, Old hash, Old message,
New hash and New message. Type uses the original reference-type artwork. The
native Type caption distinguishes the second column from the source's duplicate
Ref caption. Compare Tags has six fixed columns: Tag, Status, Local hash, Local
message, Remote hash and Remote message. The source tag rows have no icons.
Context commands retain their source icons and conditional order.

The pinned `CGit::GetShortHASHLength()` implementation returns eight. Both native
tables retain eight-character hashes independently of `core.abbrev`, with full
hashes available in tooltips and immutable command targets. Native dialog fonts
remain the consumer; these tables do not inherit the Log file-list font setting.
Single-line captions preserve full user-derived values in tooltips.

Reference default sorting uses change kind and full reference name. Header sorts
are stable; a newly chosen column starts ascending. Logical comparison is limited
to names and message columns and respects the source policy. Tag default ordering
and SortTagsReversed retain their source behavior.

Tag Show recomputes header-based column widths, with the last column filling the
remaining viewport. This is the source `LVSCW_AUTOSIZE_USEHEADER` behavior, which
differs from fitting every row's contents; see [Microsoft's API documentation](https://learn.microsoft.com/en-us/windows/win32/api/commctrl/nf-commctrl-listview_setcolumnwidth).
Ref initialization uses header widths and its dedicated Reference width.

Both header menus provide only Hide unchanged. The initial value comes from the
configured preference; a header toggle belongs to the current window and does
not rewrite that preference. The source tables provide no clipboard, Return or
double-click actions, column visibility controls or Reset command.

## Result actions and ownership

The native result tables bind
reference and tag menus to their captured owner, projection and remote, preserves
Shift comparison choice, routes Log to the clicked revision and retires native
callbacks when their table or owner closes. Log receives both the selected and
end revision. Comparison retains the captured Shift alternative-tool choice;
Log, Compare and RefLog receive the Synchronization window's preferences.

Tag deletion retains its captured snapshot, exact remote and generation through
the owned confirmation. Closing or replacing that owner cannot authorize a late
reply. Confirmation and error callbacks settle after their native sheet actually
detaches, retaining the existing Git operations and progress consumers.

Physical pointer/key/menu tracking, VoiceOver, all layout/locale combinations,
installed signed grants and complete source acceptance remain separate gates.
This review does not certify the whole Synchronization dialog or port.

## Grouped checkpoint — October 21, 2026

The Debug app build and six native case/engine combinations passed on their
first attempts, using system and bundled Git. Actual private ref snapshots and
local tag deletion outcomes, configured Log/Compare/RefLog windows and delayed
owner/sheet/worker retirement were checked. Core was unchanged. Both owned
receivers are independently absent. [Evidence](qa/sync-reference-results-2026-10-21.json)
records the exact scope and local compiler diagnostics.

Reviewed captures show [Ref List light](site/assets/sync-reference-results-light.png)
and [dark](site/assets/sync-reference-results-dark.png), and [Compare Tags light](site/assets/sync-tag-results-light.png)
and [dark](site/assets/sync-tag-results-dark.png). The Tag captures deliberately
show the retained injected transport error after refill. Source header-sized
columns can truncate long row values; full tooltips remain available.
