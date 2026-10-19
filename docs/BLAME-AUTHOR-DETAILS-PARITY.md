# Blame author and revision details

This connected native pane family follows TortoiseGit pinned at
`7338078f8ddd924b8cddee35f512f2286072136d`:

- `TortoiseGitBlame/OutputWnd.cpp:82–86,111–115,149–172`: opt-in shared
  Gravatar settings, 80-pixel area to the right of the embedded Log, and the newly
  selected row's author independently of single-revision Properties.
- `TortoiseGitBlame/PropertiesWnd.cpp:118–207,233–335`: read-only Basic information
  and Parents groups, full descriptions, parent subject values and indexed hash
  descriptions, Parents reset/expansion, and Copy of a selected non-group value.

## Native pane behavior

Blame now reserves an 80-point native image view beside its embedded Log when
`EnableGravatar` is enabled in the originating viewer's preferences. It shares the
existing Log avatar URL/hash/cache loader, including `GravatarUrl` and
`GravatarUseMD5`. Disabled viewers send no image request. The newly selected author
continues to update during multiple selection while revision Properties clears,
matching the source's separate selection roles. Deselecting the last row retains
the last selected author, as upstream does; hiding Log, loading/replacing a document,
disabling the feature or retiring its viewer cancels the owned request. Old images
clear when an author changes, and a cancelled request cannot repopulate a retired
viewer. URL/email identities preserve UTF-8 differences rather than implicitly
normalizing user values. The source's opt-in setting still controls network use.

Properties uses a native two-column, read-only table with collapsible Basic
information and Parents groups. The nine basic fields retain their source order.
A selected row displays its complete value below the grid, including multiline
Body text, rather than relying on a truncated cell or tooltip. The parents' cell
values are subjects; their descriptions contain zero-based ordinal, full hash and
subject. Parents reset and expand when the revision changes, while the Basic
information group's collapse choice survives. No selection/multiple selection
clears revision values and collapses Parents. Pane docking, floating, auto-hide,
font conventions and light/dark system colors remain shared with the viewer.

**Copy**, Command-C, Shift-F10/accessibility context entry and the native responder
Copy action use the complete selected property value. Parent Copy consequently
copies its subject, not a hidden hash. Group rows offer no Copy item. Context menus
use TurtleGit's existing source Copy icon and originating icon preference. A menu
retains the selected property/revision/value and refuses a stale invocation after
selection, value or document changes. Values, descriptions and identity comparisons
preserve exact bytes; user text and Git references are not localized. A native
split description area can be resized without editing repository data.

## Evidence and remaining work

The final universal helper/Debug checks, 32 distinct focused Core methods across
the initial and affected repair runs, and the Commit/Blame native groups with
system and packaged Git passed. Actual failures and repairs remain in the record;
this scoped result is not a full hosted or whole-application certification.

[Grouped evidence](qa/commit-index-blame-details-2026-10-19.json) retains actual
builds/checks and any failed attempts. This family is implemented together with
[Commit index selection](COMMIT-INDEX-ENGINE-PARITY.md); each native receiver owns
private preferences, repository, pasteboard and injected HTTP responses. Avatar
checks use actual URLSession/loader cancellation with no public network traffic.

The earlier October 15 pane captures and October 16 Go To captures predate this
property grid. Offscreen content-cache captures were inspected for this batch,
but their missing SwiftUI/window surfaces make them unsuitable for the public
gallery. They are excluded rather than presented as full appearance evidence.
The subsequent pane-interaction batch implements keyboard group navigation,
read-only native focus and responder Copy, a draggable property-name/value divider
with originating-preference persistence, and eight-character parent labels.
The embedded Log stores full hashes (native column clipping handles display),
and its keyboard/Edit Copy uses complete messages and changed paths, while the
explicit SHA-1 context command retains hash-only output. Clipboard reads check
focus again before publishing; property context invocations include a monotonic
selection generation so moving away and back cannot revive an old action.

Source evidence: `Git.cpp::GetShortHASHLength` returns eight;
`PropertiesWnd.cpp:280–282` uses zero-based ordinal/full hash/subject for the
parent description and the eight-character hash as its label.
`GitLogListBase.cpp:1548–1550` supplies the full hash cell;
`TortoiseGitBlameView.cpp:733–751` routes focused Log Copy to the default full
clipboard operation (`GitLogListBase.cpp:2378–2448`). MFC's property-grid keyboard
implementation is part of the Windows SDK, not the pinned repository. Left/Right,
Space/Return and Home/End behavior here is an explicit AppKit adaptation.

The new grouped native interaction/capture results are recorded in
[the pane-interaction evidence](qa/blame-pane-interaction-2026-10-19.json).
Physical keyboard/VoiceOver, every font/DPI/minimum OS, public avatar servers,
signed sandbox behavior and complete upstream layout remain open. This is not a
new static dialog resource, so no invented resource ID or whole-dialog
certification is added to the ledger.


The final pane-interaction group passed four native cases: new interaction and
retained author/details, each with system and bundled Git. No Core suite was
rerun for these native-only changes. The Debug app and generated localization/Help
checks passed. Both original WindowServer captures were inspected independently:
`site/assets/blame-properties-current-light.png` and
`site/assets/blame-properties-current-dark.png` (2560×1664). They show deliberately
roomy native pane dividers, all three sample Log rows, expanded Parents and the
complete Body description. Each was visible for under 0.4 seconds without app
activation. Original hashes, rejected earlier captures and scoped limitations
remain in the evidence record. These images prove this fixture's appearance,
not all-dialog layout or physical Finder/App Store acceptance.
