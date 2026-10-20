# Blame source rendering and attribution dates

Source baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
`TortoiseGitBlame/TortoiseGitBlameView.cpp`: `DrawBlame`, `OnMouseMove`,
`OnLButtonDown`, `OnSciZoom`, wrapped source navigation and configured date
formatting. Native TextKit replaces Scintilla; the annotated source, author/revision
colors, syntax, viewport and immutable historical bytes retain their contracts.

The connected native implementation separates document content, base syntax styles,
selection/hover painting and glyph geometry. A new annotation history builds hash
and author row indexes once. Moving between lines of the same revision and author
changes no source attributes; crossing revisions updates only affected revision
and author rows. Persistent selected-revision/author colors preserve their source
priority over transient hover colors. Clearing selection restores the original
syntax foreground and end-of-line fill, including split syntax spans. Replacing
annotation history with identical source bytes also restores the cached syntax
when its selected revision disappears; it does not reconstruct text, base fonts
or glyph geometry.

Attribution cells are rebuilt for new annotations, visible-column changes,
font/zoom and date-presentation changes. Ordinary hover and selection repaint
existing visible cell colors without reloading the complete table. The age locator
retains its ranks and redraws for actual viewport/palette/history changes.

Glyph rectangles are retained across color, hover and selection changes. Actual
text, encoding, font, zoom, tab, wrapping, syntax-font and viewport-width changes
invalidate the necessary layout. Native exact UTF-16 selection and the source-row
viewport anchor survive reflow. Font and wrapping remain normal source settings;
no rendering cache is persisted. Document replacement and owner retirement cancel
syntax reads and refuse late publications. Queued SwiftUI updates also reject
retired owners before measuring/reloading attribution cells, including preference
changes that arrive between window closure and view detachment.

Attribution Date uses the same configured short/long, relative and system/invariant
locale policy as Log and revision tooltips. The native date column is measured
from those actual displayed values. Locale and timezone changes invalidate the cached date values and matching
column measurements. Relative strings refresh on the next ordinary view update
after their second changes, retaining the source's seconds display for recent
commits; no timer, periodic Git read or test run is scheduled. Native locale and timezone presentation replace Windows date formatting.

`docs/qa/blame-rendering-native-2026-10-20.swift` prepares a real 3,000-line,
four-commit, three-author private repository. Native work receipts distinguish
whole-document construction, base-style passes, glyph reconstruction, attribution
reloads and affected-row painting. The fixture checks actual source attributes,
background changes, same-revision hover, crossing-revision hover, selection
restoration, exact selection/viewport, wrapping and date preferences. A private
helper exercises the production syntax protocol decoder with colored, bold and
end-of-line styles; native assertions verify completion-driven reflow, selection
overrides and exact base-style restoration. Same-byte history installation drops a selected revision and checks cached
foreground/EOL restoration without complete base-style/layout work. Same-count
and appended-line historical reloads replace the cached document/indexes, and a deliberately late syntax reply
cannot paint a retired owner. Read-only phases verify repository invariants. These are behavioral work assertions rather than
machine-speed timing limits.

The Debug app and focused native family checks passed with Apple and bundled
Git across the grouped checkpoint and focused repairs. The receiver awaits actual
paint/geometry receipts before checking work counters; its earlier optimistic
80ms settle assumption and the unreproduced transient failure remain in the
[batch evidence](qa/history-editor-presentation-2026-10-20.json). The original
performance, style and retirement assertions remain. Core code was unchanged
and its suites were not repeated.

Large-repository loading, every TextKit/OS/assistive-input combination, physical interaction,
Windows pixel/font equivalence, signed distribution and complete Blame/application
parity remain separate work; this family does not certify those requirements.
