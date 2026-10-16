# Reference browser presentation and keyboard

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`IDD_BROWSE_REFS`, BrowseRefsDlg's column version 7, RefBrowserSortCol/RefBrowserSortDesc,
FillListRefLeafs and PreTranslateMessage; ColumnManager's header menu and reset.

The native browser now saves the nine columns' order, widths and visibility in
its supplied preference store. Branch Name remains visible and is excluded from
the toggle menu, matching ColumnManager's first-column rule. Unknown/duplicated
column IDs, invalid widths and malformed records fall back safely while preserving
valid settings. Widths use native points, bounded to 40–10000; the JSON key is
versioned independently of the Windows registry format.

Right-click the native header for Reset column order and the eight source column
choices. Native resize/reorder and double-click sizing persist. Shift-double-click
also includes the title in the measured width. Column changes preserve the table
selection and vertical reading position; unchanged row data no longer causes an
unnecessary table reload/recentering. Current branch bolding and exact reference
identity remain part of the displayed-row signature.

The namespace/list splitter also remembers its width, with native minimum tree
and list bounds; the filter spacer follows the actual divider. This macOS layout
preference complements the source's saved window frame. Reset restores natural
column order, default logical widths and visibility after the source Yes/No
confirmation, while retaining the splitter and sort. Namespace refresh continues
to force Tracked branch/Description visible for local branches and hidden outside
them; other column choices persist. Reset in another namespace retains those
conditional hides as a native adaptation.

Column-sort choices use the source numeric RefBrowserSortCol and exact TRUE
RefBrowserSortDesc keys. Invalid stored values restore Name/ascending. Header
sort indicators and row ordering follow the restored state in standalone and
revision-picker windows. The existing native logical/numeric/string comparators
remain; this does not establish exact Windows locale sorting.

F5 refreshes only the owning active browser. Ctrl-E and native Cmd-E focus/select
the Filter field. Escape clears a nonempty active filter. Ctrl-A/Cmd-A select all
when the multi-select reference list owns focus; text editors keep their normal
selection handling, and single-selection pickers retain their restriction. F2
starts inline rename on the first selected local branch, including multi-selection,
without replacing the visible selection. Name scrolling brings the editable label
into view. Existing native Return/Escape rename completion remains in use.

Keyboard dispatch is scoped to the event window and current key-window provider.
Busy, child/question, inline rename and retired owners reject competing actions.
Header commands retain their layout revision and weak owner; stale or retired
menus cannot change replacement settings. Reset questions retain the existing
browser mutation/Quit lifetime until their owned continuation settles; normal
Close is gated and forced closure settles the actual native question as No.
Late accepted replies cannot change closed/replaced layouts.

Physical header dragging/sizing, keyboard layouts/VoiceOver, exact source geometry,
minimum-OS and signed Finder/App Store acceptance remain open. These controls do
not certify every Browse References dialog action or the whole application.

Grouped native evidence is recorded in [the presentation QA record](qa/reference-presentation-2026-10-16.json). The receiver exercises the actual AppKit header, table, splitter, keyboard dispatcher and private preferences, plus retained target, folder and inline-rename workflows with system and bundled Git. No Core changes or Core-suite repetition were needed.
