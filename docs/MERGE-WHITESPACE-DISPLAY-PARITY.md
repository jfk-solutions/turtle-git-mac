# Merge whitespace display

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`,
BaseView.cpp::DrawLineEnding and its space/tab drawing, MainFrm.cpp::OnViewWhitespaces.

Both native comparison windows now expose **View → Show Whitespaces** and
**Line-ending icons**. Merge Editor Settings has the same saved options through
its existing Apply/Cancel transaction. Source defaults are retained: whitespace
visible and IconLFs off. Unlike Windows registry editing, macOS exposes IconLFs
as a native control. View choices apply to every text pane in that window;
Settings Apply refreshes open windows through their existing preferences notification.

The native overlay draws the source's two-point space rectangle, tab arrow and
ending paths. CRLF bends from the top before returning left; CR returns left;
LFCR returns left then down; LF points diagonally down-left. VT/FF/NEL/LS/PS add
the source separator rule and ending arrow. Unended lines have no ending symbol.
Tabs follow native glyph geometry and the current tab stops rather than replacing
the buffer with expanded spaces.

Icon mode reuses the original unmodified LineEndingCR.ico, LineEndingLF.ico and
LineEndingCRLF.ico, with pinned blob and SHA-256 provenance. As upstream, icon
mode draws only these three styles. When both compared rows have different real
endings, the icon background uses the original inline added/removed palette;
the two-pane Inline diff switch gates that background.

Markers use UTF-16 display coordinates. Aligned panes use captured original
ending metadata, never the synthetic LF used to display a gap or an unended
final line. Removed Base rows retain their original endings. Merged/Base raw
text uses the shared nine-ending parser. Only ASCII spaces and tabs are marked;
Unicode nonbreaking spaces are retained without being mislabeled. Marker plans
are cached between draws, and visible-glyph bounds limit painting. Appearance
changes use native dynamic marker colors and original image alpha. Dark-mode
icons tint the original silhouette using an opaque resolved native foreground;
the bundled ICO bytes remain unchanged.

Rendering changes no text-storage characters, source numbers, selection offsets,
copy/export data, draft bytes, Undo history or comparison keys. Toggling it does
not spawn an engine helper or mark the document dirty. Busy/Quit/retired models
refuse stale View dispatch. This adds display controls; the existing whitespace
conversion commands remain separate editing operations.

## Evidence and remaining work

Thirty-four grouped Core tests passed, including all nine endings, UTF-16 emoji/
NFD offsets, real versus synthetic endings, gap rows, comparison ending changes,
source defaults/persistence and the existing ending/whitespace/source/presentation
and original icon tests. The unsigned Debug build passed with existing diagnostic
noise. See [the batch record](qa/merge-whitespace-display-2026-10-12.json).

Two combined native receiver runs passed the production owners, including
three-pane visibility updates and two-pane source markers, persistence, stale
busy refusal and unchanged selection/history/text/files. Visual review exposed
insufficient dark-icon contrast. After an AppKit import-name repair, the icon
callback was changed to capture a color resolved under the view's actual
appearance. A focused whitespace-only receiver and final build passed; the
inspected final captures show readable arrows on dark backgrounds. The Core
suite was not repeated for these rendering changes. Actual app/Finder resource
auditing also passed, including all 294 bundled original icon resources.

The website includes four native component captures (shapes/icons, light/dark).
They are source text-view captures, not full-window or physical menu acceptance.
All owned windows/helpers closed. No installed application was launched.

Remaining acceptance: full physical menu/Settings Apply/Cancel, native CR/LF and
rare-ending glyph geometry, long-line/high-contrast/resize behavior, three-pane
inline-diff controls and full character-difference equivalence, wrapping/folding
integration, minimum-OS and signed sandbox acceptance. This does not certify
complete TortoiseGitMerge or application parity.
