# Blame focused revision and source synchronization

This connected family implements bidirectional focused-revision behavior. Its
focused native checkpoint passed with system and bundled Git. It does not
certify the full Blame dialog or replace earlier search, navigation, menus and
toolbar receipts. The grouped [checkpoint record](qa/replay-blame-family-2026-11-23.json)
retains the earlier fixture failures and their focused repairs.

## Source evidence

At pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`OutputWnd.cpp:144–173` builds the complete selected hash set and separately
passes the revision whose native selection state changed. `FocusOn` in
`TortoiseGitBlameView.cpp:1815–1836` collapses source selection at its active
caret, navigates to the first source line of a newly focused selected revision,
and clears Properties for a non-singleton selection. It does not choose the
lowest selected Log row as the focused revision.

The reverse `OnLButtonDown:1727–1779` maintains additive revision highlights
and explicitly calls EnsureVisible for the clicked source revision, including
when toggling it off. GotoLine at 682–718 selects the destination line. The
existing Next/Previous block algorithm remains separate and unchanged.

## Native behavior

The model separates its highlighted hash set from focusedHistoryHash. The native
Log records the actual pointer or keyboard selection endpoint. Command-additive
and Shift-range selections retain all highlighted revisions; Properties remains
defined only for a singleton. Avatar focus follows the focused selected revision.
`NSTableView.selectedRow` can already report the recently selected endpoint; it
must not be described as the minimum selected index. The native minimum is
`selectedRowIndexes.first`. Verification separately checks that minimum, the
focused endpoint and the exact native selection projection.

History focus synchronously collapses native source selection. A newly selected
focused revision selects its first attributed source line; deselection or focus
within an already selected revision collapses without jumping to another row.
The text view remembers selection direction, including Shift navigation, and
the accepted-Find end-caret receipt remains authoritative. History retains
keyboard focus while its source caret and viewport update.

Source-margin selection publishes a one-use reveal receipt for its clicked hash.
The native Log reveals that row even when other earlier entries remain selected
or the clicked hash was removed. Horizontal scroll position is retained.
Keyboard Shift-F10 and accessibility menus anchor at the focused selected row,
while every highlighted revision remains the menu action set. Existing history
commands, source Copy/Find, columns, fonts and toolbar state retain their contracts.

## Ownership and replacement

Focus/reveal receipts carry the document source version and a unique serial.
New source actions supersede old intent; replacement and retirement discard
pending work. Hidden, disabled, foreign-window, field-editor, busy, sheet/modal
and retired native history entry points refuse navigation. Detached/reparented
source chrome cannot apply a caret handoff to another owner. Retired callbacks
are cleared. This introduces no Git writes, helpers or additional Quit counter:
selection work stays synchronous within the existing document ownership.

## Prepared verification and remaining scope

The new callable fixture joins the existing cached Blame menu/editor driver as
`--only focus`; the default driver retains all previous cases. A private real
13-revision Unicode repository exercises native additive pointer selection,
active-caret collapse on deselection, source reveal/toggle-off and horizontal
retention, keyboard range endpoints, focused accessibility menu anchors,
foreign/hidden/field/busy refusal, replacement receipts, closure and exact
original HEAD/index/source bytes. These are prepared checks, not passing evidence.

The locator already draws the pinned age/viewport overview, and extracted lexer
configuration already runs the pinned Lexilla helper. This family does not
invent locator dragging or infer brace-matching requirements from style constants.
Every editor gesture, all noncontiguous TextKit selection variants, VoiceOver
presentation, signed delivery and complete TortoiseGit parity remain separate.
