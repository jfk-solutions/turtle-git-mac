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

Remaining: user profile editing/override files, exhaustive source-heuristic edge
equivalence, full language parsing if intentionally added later, physical menu
and source-layout comparison, complete captures, signed helpers/bookmarks and
App Store acceptance. This does not certify complete TortoiseGitMerge parity.
