# Comment comparison

Source pin: `7338078f8ddd924b8cddee35f512f2286072136d`. The original
`src/Resources/ignorecomments.txt` is bundled unchanged with blob/SHA-256
provenance in the shared Core resource directory. Its extension profiles retain
literal delimiters, including SQL's required space after `--`. Profile selection
uses Base, Mine, Theirs precedence. Unknown extensions disable Ignore Comments.
IgnoreComments defaults to false and is saved alongside comparison options.

The UTF-16 stripper ports FileTextLines.cpp::StripComments/IsInsideString.
Each source has independent multiline-block state. Comments are removed from
comparison keys before regex, whitespace and case conversion. Original source
text, ending styles, encoding metadata, numbered rows and save/transfer data
remain untouched. Both native viewers expose the command through the shared
Comparison menu; three-pane changes retain the dirty Save/discard/Cancel path.

The source deliberately uses a fast quote-count heuristic, not a language lexer.
It does not handle escaped/multiline strings completely, and its single-quote
scan advances through double quotes. Those behaviors are preserved. A quoted
line marker can also prevent removal of a later actual comment on that line.
The macOS port adds cancellation, iteration/time/input limits; failures are
reported instead of trapping preparation in an unbounded loop.

Grouped evidence: 26 Core tests passed, including profile lookup, literal SQL
markers, quoted delimiters, Unicode, independent multiline state, cancellation
and real engine filtering before regex. The unsigned Debug build completed with
existing diagnostics. Both native receivers passed in one compilation/process,
including recognized C++ support, saved Ignore Comments, actual comment-only
differences becoming filtered rows, unchanged input files and existing
editing/save/Undo/cancellation checks. Actual framework profile bytes and SHA-256
were verified. All owned windows/helpers exited. See
`qa/comment-comparison-2026-10-12.json`.

## Custom profiles and Settings

The comparison batch now also reads a user `ignorecomments.txt` from
`TurtleGitMerge` in the macOS Application Support directory (the private container
in Store builds). As in `MainFrm.cpp::LoadIgnoreCommentData`, an existing file
replaces the entire extension map. A missing file uses the unchanged bundled
profile; macOS creates a custom file only when the user applies an edit.

Merge Editor Settings provides Ignore Comments and Edit Comment Profiles with a
monospaced editor, source-format instructions, Restore Defaults and draft OK/Cancel.
The outer Apply/Cancel transaction controls persistence. SQL's trailing marker
space is retained. Validation rejects incomplete block pairs, invalid UTF-8/NUL
and files over 128 KiB. Invalid UTF-8 or oversized external files need correction
outside Settings; malformed UTF-8 definitions can be repaired in the editor.
The save checks the captured text to reject an intervening external edit and
uses an atomic replacement. A failed profile save leaves other merge preferences
unsaved. This is optimistic stale-edit detection, not an external-editor lock.

Both viewers capture custom definitions on Reload. Two-pane typing reuses its
captured map rather than reading Application Support on every keystroke. Three-pane
Cancel retains the previous result and profile support; successful reload changes
them together through the existing Save/discard/Cancel flow. These definitions
change comparison keys only, never original contents. The settings-file path is
injectable for private native fixtures.

Grouped file-profile validation passed 28 Core checks. Both native viewers passed
in the combined receiver, including custom marker changes, replacement-map
extension support, restoring defaults and three-pane dirty Cancel/discard.
The initial native attempts exposed an existing Unicode selection collapse.
The repair consumes caret/selection requests once and preserves native selection
in source coordinates while using the current alignment during hosting updates;
the final receiver passed selection, Undo/Redo and save checks. See
[the batch record](qa/comment-profile-file-2026-10-12.json). Physical interaction
with the new Settings editor remains unverified.

Remaining: exhaustive source-heuristic edge
equivalence, full language parsing if intentionally added later, physical menu
and source-layout comparison, complete captures, signed helpers/bookmarks and
App Store acceptance. This does not certify complete TortoiseGitMerge parity.
