# Merge Find and Replace

Baseline: pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`FindDlg.cpp/.h`, `BaseView.cpp::OnFindDialogMessage`, `Search`,
`BuildFindStringArray`, `GetCharGroup` and `IDD_FIND` in
`src/Resources/TortoiseMergeENG.rc`.

The two-pane comparison and three-pane conflict editor now use a pane-local,
modeless native Find window. Search for and Replace with are editable history
combos. The left column contains Match case, Limit search to modified lines,
Search up and Whole word; the right column contains Find, Replace, Replace All,
Count and Cancel. Return runs Find, Escape closes this window, and Command-G /
Shift-Command-G navigate matches. The existing original Find icon remains in
viewer menus. Source panes retain read-only replacement controls.

Search is literal and line-local, with UTF-16 ranges for AppKit. Synthetic gaps
are excluded. Modified-only search excludes normal and regex-filtered lines;
source removed/added/conflicted rows remain searchable. Result lines use the
existing comparison/locator state projection. Whole word follows the source's
space/tab/control/punctuation separators and honors the WordSeparators setting.
Underscores and non-ASCII letters are not automatically classified as separators.
Find wraps in either direction and reports top/bottom reached in green; no-match
status is red and Count is blue. Colors use native semantic light/dark variants.

Match case, modified-only and whole word persist. Search Up stays session-local,
as upstream. Search/replacement histories are separate, case-sensitive,
untrimmed and limited to the source's 25 entries. Empty replacements are valid but are not
added to history; CR/LF in history entries become spaces as in CHistoryCombo. A selected pane substring seeds the search
when showing its dialog. Dialog geometry uses the shared native geometry store;
separate upstream pane-relative X/Y placement is not reproduced yet.

Replace starts at the current selected occurrence. Replace All takes the current
nonoverlapping matches, then applies one grouped native edit, so replacement
text containing the search term is not searched again. Two-pane display ranges
are mapped back to original source ranges: display-only gaps/removed base rows
never become working-file text. Three-pane edits use the conflict editor's
existing grouped undo path. Neither action saves to disk or stages the index.
Busy/confirmation/attached-sheet gates are checked at execution time. Each Find
window follows its owner and closes with it; it retains only a weak pane reference.

## Validation and remaining work

The Core receiver covers literal/case matching, UTF-16 and mixed EOL offsets,
modified/gap filters, custom whole-word boundaries, nonoverlapping counts,
direction/wrap/replace-current behavior and preference defaults. The native
receiver exercises actual two/three-pane text views, Count, modified filtering,
wrap status, Unicode Replace All, grouped Undo/Redo, readonly/busy gates, source
mapping, owner closure and unchanged original files/index. All eight focused Core tests and the final native receiver passed. The app
built successfully. See the [dated QA record](qa/merge-find-2026-10-12.json) for
exact scope and the initial fixture correction. Offscreen captures were rejected
for missing native controls; no new screenshot was published.

Still partial: physical keyboard/menu/VoiceOver acceptance, full screenshots in
light/dark and minimum-size windows, signed sandbox acceptance, source search
highlight painting in every pane, pane-relative geometry, and exact Windows
case-conversion differences for rare Unicode expansions. The result's modified
states inherit the existing locator projection rather than adding a new engine.
