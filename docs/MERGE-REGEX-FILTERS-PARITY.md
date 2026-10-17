# Merge regex filters

Source pin: `7338078f8ddd924b8cddee35f512f2286072136d`.
Reviewed `RegexFiltersDlg.cpp`, `RegexFilterDlg.cpp`, `IDD_REGEXFILTERS`,
`IDD_REGEXFILTER`, `MainFrm.cpp::OnRegexfilter/OnRegexNoFilter`,
`FileTextLines.cpp::LineRegex` and `DiffData.cpp` filtered row classification.

The native list retains the Regex column, Add Filter, Edit Filter, Delete Filter,
OK and Cancel. Selection enables Edit/Delete; double-click edits the selected
definition. The child dialog retains Name, Regex, Replace, OK and Cancel, with
initial Name focus and expression validation before accepting. macOS displays
errors inline. The list keeps a draft until OK; Cancel/close discards the draft.
Renaming and case-insensitive duplicate names replace named sections. Definitions
are persisted in the app's preference domain; the active filter is window-local.
An empty name is rejected to keep the native named menu usable.

Comparison windows provide No Filter, the named filters and Edit Filters with
checkmarks. Both ordinary and filtered two-pane results now use pinned Subversion
ranges; the Swift projection is temporary coordinate support during editing,
with comparison-dependent commands gated until completion. Applying a filter uses the existing bundled C++ helper's default
ECMAScript `std::wregex` and `std::regex_replace`, retaining Windows UTF-16 units
and capture/replacement semantics. Expressions are compiled once per batch and
applied separately to each line. A bounded framed protocol retains empty records,
Unicode and newline-containing replacements. EOL remains part of comparison keys.
Original text, source numbering and endings remain in every display row and in
the writable drafts. Filter-only differences use the upstream green background:
RGB 220/255/220 light, 73/83/73 dark. They are excluded from difference navigation
and inline change highlighting. Explicit block transfers still use original text.

Filtering runs off the UI thread, with a five-second helper bound, cancellation,
output bounds and generation checks. Changing the active filter or editing a
draft cancels previous work. Transfer/navigation is fenced during recomputation;
manual edits and Save retain the original draft contents. Filter errors fall
back to the ordinary comparison and show an error rather than silently changing
regex syntax. Closing retires owned filter dialogs, cancels validation/filtering
and rejects late replies. Quit waits for helper cleanup. Definition changes
refresh open comparisons. Source-based annotations are remapped when alignment
changes. Original Add/Delete artwork is reused in context entries.

Three-pane filtering now uses the Subversion adapter and original-text result
generation, with dirty Save/discard/Cancel and native Undo/Close checks. See
[the engine integration](SUBVERSION-MERGE-ENGINE.md).

Resolved-child metadata now supplies source-style padding without resolving
the parent. Remaining: complete upstream libsvn segmentation acceptance,
INI import/export and preset distribution, all MSVC/libc++ regex/locale edge
cases, replacements yielding unpaired UTF-16 (currently rejected), physical
keyboard/menu/layout comparison, very large files, signed helper/sandbox
acceptance. This implements the connected two-pane/list/editor workflow; it
does not certify full TortoiseGitMerge parity.

Grouped validation: 53 relevant Core tests passed with no failures, including
six new filter tests and existing expression/alignment/editing/source tests.
The universal helper audit and unsigned arm64 Debug build completed; existing
build diagnostics remain. The focused native receiver compiled once and passed
transactional list/rename/delete, invalid-expression correction, original-byte
panes, palette values, writable-draft recomputation, stale filter selection and
retired validation cleanup. It closed its hidden windows and removed private
preferences/files. Its body is included in the shared native CI receiver so
future CI does not compile all app sources again for this feature. This wrapper
integration has not been run remotely. See `qa/merge-regex-batch-2026-10-12.json`.

## Source list/editor ownership — October 17, 2026

The source Regex column, Add/Edit/Delete row and lower-right OK/Cancel remain;
original action icons now appear on the list buttons as well as its context menu.
The editor retains Name/Regex/Replace labels, initial Name focus and native
inline validation instead of Windows balloons. Blank or whitespace-only names
are explicitly refused to keep a usable named menu section.

A child now owns one captured list session. Parent actions and Close/Quit are
blocked while it is open; acceptance, Cancel/Escape, external sheet completion
and forced owner closure settle only that session. Closing a list retires its
callbacks, so a retained OK cannot save a discarded draft. Menu/button callbacks
capture list revision and definitions; old targets cannot edit/delete a new list.
Outer OK saves the draft once. If another window has saved shared definitions,
it preserves this draft and reports the conflict instead of overwriting that save;
Cancel/reopen loads the current definitions.

Validation snapshots all three fields and uses the existing ECMAScript helper.
Busy and retired bindings refuse input, duplicate OK is refused, a directly
changed draft must be validated again, and success retires delivery before parent
callbacks. Invalid expressions remain editable. Cancel/forced close cancels the
helper, while independent operation accounting keeps Quit guarded until actual
worker drain. No Core regex, alignment or serialization algorithm changed.

All fourteen list/editor controls receive partial native mappings. The Debug build and both grouped native families pass: source list/editor ownership and retained actual comparison filtering. Raw light/dark captures of both windows were individually reviewed; source labels, complete fields, action icons and footer buttons fit. The first capture exposed collapsed editor width, now fixed with an explicit native content size. A retained fixture expected content at the final EOF row; diagnostics showed source line 3 plus the deliberate blank line 4, and assertions now check both and the complete draft. All five owned receivers were reaped and independently absent. Core was unchanged and not repeated. See [batch evidence](qa/merge-regex-source-family-2026-10-17.json) for exact attempts and acceptance limits. INI import/export and
preset migration, all regex/locale/UTF-16 boundaries, physical keys/VoiceOver,
large files and signed helper/sandbox acceptance remain open. This is not full
Merge or dialog certification.
