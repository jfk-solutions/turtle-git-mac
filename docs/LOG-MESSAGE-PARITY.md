# Log rich message pane — partial port

Resource: `src/Resources/TortoiseProcENG.rc` / `IDD_LOGMESSAGE` / `IDC_MSGVIEW`.

Baseline: `7338078f8ddd924b8cddee35f512f2286072136d`, LogDlg's
FillLogMessageCtrl, FindGitHashPositions, LookLikeGitHash, OnEnLinkMsgview and
JumpToGitHash; AppUtils rich-edit formatting and ProjectProperties issue positions.

The native read-only NSTextView replaces the Log pane's plain OutputView. Its
SHA-1/optional branch-number/Describe header, subject, body, Notes and Tag Info
keep source text order, optional asterisk prefixes and CR removal. Subject and
section labels remain bold even when StyleCommitMessages is disabled. Inline
bold/italic/underline uses the RichEdit UTF-16 routine, accumulating overlapping
traits; it does not substitute SciEdit's mutually exclusive byte-based styles.
The source's initial-marker behavior is retained. Native Unicode classification
replaces Windows IsCharAlphaNumeric; full locale equivalence remains unverified.

Lowercase hexadecimal hash links exclude the metadata/Describe header, require
3–40 characters after the source signed-DWORD clamp of
ShortHashLengthForHyperLinkInLogMessage (default 8), reject word/email/long-hash
suffixes, handle the source `g` prefix and skip exact Signed-off-by, Change-Id and
git-svn-id trailer lines. Clicking a hash searches below the current row first,
wraps through visible entries and excludes the current row, including ambiguous
prefixes. It selects/scrolls to the first visible match and updates normal Log
selection history. It does not resolve another revision or silently widen the
current filtered/path/date/range scope. Missing matches reuse the owned warning
and private-domain Do not show again preference.

Issue links use the ProjectProperties UTF-16 ECMAScript helper, including template
positions and invalid-expression tolerance; URL/email detection shares the source
URLFinder policy. URL links supersede overlapping issue/hash regions. Formatting
adds font traits without deleting link targets. Applied Log filters color matches
within the source subject/body/hash/notes/tag-info sections using FilterMatch.
Pending or failed history-filter drafts do not replace the applied message query.

A nonempty text selection suppresses link activation. Native menus expose Jump
to commit/Open link, Copy hash/link address, Copy and Select All; command entries
use original icons and the existing icon preference. Copy writes only plain text.
Menu actions retain their message request identity, so selection changes, refresh,
closure or leaving and returning cannot redirect them. Busy/modal/picker states
block navigation and external opening. Native keyboard/VoiceOver gestures and
full source message context-menu coverage remain acceptance work.

Styling captures the document, project properties and preferences, cancels
superseded helper requests and fences late results by message/owner identity.
Attribute-only updates retain text selection and viewport, and private Log font
preferences apply. Closing retires the view and cancels its work; Quit remains
blocked until outstanding reads settle. External URL opening requires an explicit
link action. No Git index, working file or commit content is written by this pane.

Relative bugtraq URLs still require the source remote-relative resolver. Exact
RichEdit adjacent-link merging, all Windows Unicode/locale boundaries, source
message clipboard/context-menu variants, physical interactions and signed
App Store acceptance remain open. No dialog is certified complete.

## Grouped checkpoint — October 15, 2026

The Debug build passes after renaming a menu selector that collided with NSObject
perform methods. Fourteen distinct focused Core cases pass: the initial group
had two assertions fail in one formatting case because its expected nested marker
pattern violated the source ending-boundary rule; correcting that example and
rerunning only the affected case passed. Production formatting was unchanged.

One fixture compilation against current Debug objects passed with system and
bundled Git. Real private Log entries and notes verify issue callbacks, visible
hash selection/scroll, selected-text and busy refusal, stale menus after leaving
and returning, font/style/hash-length preferences, selection-preserving restyle,
held-style retirement/Quit accounting and owned missing-hash sheets/private
suppression preferences. Two raw light/dark captures were reviewed. All owned
windows and receivers were closed/reaped. No real browser, shared clipboard or
external tracker was used; actual copy publication, physical link/keyboard/menu
gestures and signed sandbox execution remain unverified. Filter section ranges
were tested in Core; full native filtered-history highlight acceptance remains
open. See [exact evidence](qa/log-message-2026-10-15.json).
