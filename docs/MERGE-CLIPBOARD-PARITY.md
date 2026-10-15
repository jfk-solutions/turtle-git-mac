# Compare and merge clipboard workflows

The pinned `TortoiseMerge/BaseView.cpp` defines `GetSelectedText`, `OnEditCopy`,
`OnEditCut`, `OnEditPaste` and `RemoveSelectedText`. Text selection takes priority
over block selection. Copy includes removed/conflict/filtered rows, skips Empty
alignment rows, and removes the selected block's synthetic final line break.
Source clipboard CRLF is adapted to native LF.

`MergeClipboard` supplies that payload policy across the three-pane merge editor,
two-pane comparison and combined comparison. An explicit block selection is
independent of the insertion caret. Right-click preparation selects the clicked
state group, including a group of Normal rows; navigation selects its destination
block. Keyboard Copy at an unselected caret leaves the clipboard unchanged.
Combined display blocks retain exact row ranges: adjacent Removed and Added or
neutral Base/Mine aliases do not become one implicit block. Ordinary text selection
retains partial Unicode text and takes precedence. Empty/gap-only payloads leave
the clipboard intact.

Merged text uses actual UTF-16 ranges and normalizes selected endings. Its explicit
block can select marker or ignored-conflict text. Source panes use aligned cells;
raw/temporarily unaligned source panes do not borrow a result conflict range.
[Navigation and history](MERGE-NAVIGATION-PARITY.md) records source context grouping,
automatic two-pane inline advancement and Undo/Redo selection clearing.

The source Cut behavior is deliberately preserved: it copies a block when no text
is highlighted, but `RemoveSelectedText` then returns without deleting anything.
Highlighted text is copied and deleted through the native editor, retaining Undo.
Paste inserts plain text through that same editor and uses the document's
predominant ending style. Read-only panes omit Cut/Paste; busy/Quit/sheet/retired
checks reject stale mutation actions. Read-only Copy remains usable while processing or confirming Quit in both
editors. Two-pane Copy also refuses retained actions after retirement.

Both context-menu families own their supplied pasteboard via a retained command
target with a weak editor reference. Three-pane context actions previously accepted
a supplied board for menu availability but invoked the system board; they now use
the supplied board for actual Copy/Cut/Paste. Standard responder actions continue
to use the system pasteboard. Original Copy/Paste icons and the context-icon setting
remain in place, with the native scissors symbol for Cut.

The cached native runner now includes `merge-clipboard` and `merge-source`.
`test-three-pane-endings.py` delegates to that runner instead of compiling every
app source for each invocation. The migrated source fixture retains its nine
ending-style alignment/clipboard/navigation/scrolling/format/Undo assertions;
its entry wrapper reports thrown failures and its menu assertion verifies callable
retained targets rather than requiring every clipboard command to target the
text view directly. Receiver ownership and timeout cleanup remain in the shared
runner.

Core coverage checks all nine endings, removed/conflict/Empty rows, block/text
precedence, Unicode, invalid ranges and paste normalization. Native coverage uses
private boards, preferences and repositories to dispatch real production context
commands. It checks source and block Copy, Cut/Paste with Undo, busy/retired refusal,
two-pane block-only Cut, combined removed/added Copy, and unchanged HEAD/index/
working-file bytes. No Save is submitted by those checks.

Physical Command-C/X/V, Services/drag and rich-text negotiation, gutter selection
of normal blocks, cross-pane block synchronization, native printer/clipboard
applications, every mixed-ending mutation, signed sandbox execution and full
merge-editor parity remain open. The explicit caret/block behavior does not
certify all upstream selection gestures.

Thirty focused Core cases, the repaired Debug build, and four grouped native
receivers passed. Native groups cover 18 source pairs across system/bundled Git,
plus production clipboard/Undo and combined-view checks. All four accepted and
seven earlier failed native receivers were reaped. Earlier compile, target-lifetime
and fixture layout/filtering failures are retained in the [QA record](qa/merge-clipboard-2026-10-13.json).
Two site documentation checks passed; the full suite and signed deployment were
not repeated for this batch.
