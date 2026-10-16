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
light/dark and minimum-size windows, signed sandbox acceptance, pane-relative geometry, and exact Windows
case-conversion differences for rare Unicode expansions. The result's modified
states inherit the existing locator projection rather than adding a new engine.

## Pane-local painting and selected-text search — October 15, 2026

Find, Count and Replace now retain a pane-local search snapshot and paint every
match over the existing diff/inline colors using the source `IntenseColor(30)`
rule. The layout manager owns temporary foreground/background attributes; source
text styles, saved bytes and Undo history stay independent. Closing Find retains
the search. Text/state changes, Undo/Redo, filtering, folding and theme updates
refresh the paint; folded marker/hidden rows retain their own rendering. As in
source drawing, modified-only restricts navigation/count/replacement while the
query still paints matches on unchanged lines. Matching
ranges are cached against exact UTF-8 text, line states, query and options.

Source `OnEditFindnextStart`/`OnEditFindprevStart` use the selected text as a new
case-insensitive, unrestricted, non-whole-word query. The native commands follow
that behavior, with Command-Option-G / Shift-Command-Option-G and original icons
in both editor context menus. Control-F3 / Control-Shift-F3 retain the source
shortcuts; F3 / Shift-F3 and Command-G / Shift-Command-G repeat the pane's committed
search. No selection clears its search, as upstream. Clear Search Highlights is
also explicit in the native menus. These commands do not overwrite Find's draft
or persisted options. Repeated search with no active query does nothing.

Commands recheck busy, pending-choice, attached-sheet and retired-owner gates.
The three-way source and result panes have independent queries, as do the two
comparison panes. Temporary paint is never an edit or save. Source Windows
flash/no-match rendering, pane-relative Find geometry,
physical gestures/VoiceOver, exact platform font/case metrics and signed sandbox
acceptance remain open. The Debug build and grouped native Find receiver passed
with system and bundled Git after the recorded compile/fixture repairs. See
[search painting evidence](qa/merge-find-highlights-2026-10-15.json). Core matching
was unchanged and no Core suite was repeated.

The connected [marked-word and locator continuation](MERGE-LOCATOR-PARITY.md#find-bands-and-shared-marked-words--october-15-2026) adds independent word marking,
layered source paint and Find/marked-row bands, with its own grouped evidence.


## Aligned-result hosted fixture repair — October 16, 2026

The hosted `MergeFindNativeVerification` timeout was reproduced locally at its
result locator assertion. The fixture counted serialized conflict-marker bodies,
while the native aligned unresolved result correctly displayed a Base placeholder.
It now checks that initial `[2,1,2]` marked-row state, chooses Mine then Theirs
through the real merge action, waits for the aligned displayed result and retains
the original `[2,3,2]` locator and Find/Replace/Undo assertions. Wait diagnostics
identify the fixture line. The isolated repaired phase passed without app/Core
changes or repeating the full LFS/mail suite. See
[actual attempts and limits](qa/merge-find-ci-repair-2026-10-16.json).
Full hosted rerun and signed/physical acceptance remain pending.
