# Working-file report-row geometry

This family extends the [Commit report-row policy](COMMIT-REPORT-ROWS-PARITY.md)
to the working-file lists in Resolve, Working Tree and Revert. It concerns these
three report tables, not every table or the full port.

The pinned source is TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`. In
`src/Git/GitStatusListCtrl.cpp:282–300`, the shared report control selects its
small status-image list and optionally installs the configured file-list font
when `LogFontForFileListCtrl` is enabled. `ChangedDlg`, `RevertDlg` and
`ResolveDlg` use that shared status control. The corresponding resources in
`src/Resources/TortoiseProcENG.rc` are `IDD_CHANGEDFILES`, `IDD_REVERT` and
`IDD_RESOLVE`. The native adaptation retains their
separate selection/check models, status artwork, columns and menu behavior while
making each report use one font-derived row height.

## Native behavior

`FileListUniformRowGeometry` resolves the ordinary system font or the originating
window's configured log font. Regular and bold line metrics, checkbox minimum
and padding determine a single report height. Captions use one line with tail
truncation; full original paths remain in repository-file help, and copy
commands retain their literal Unicode, newline and tab bytes. Metadata columns
follow the same single-line policy rather than making a long owner, name or
status label expand one row. Source status icons retain their 16-point bounds.

Working Tree and Revert opt into the existing `CommitFileInteraction` geometry
owner. Resolve opts in through `NativeListSelectionProbe`, which receives exact
ordered path-byte identities and the same geometry used by its SwiftUI cells.
The probe's default remains unset, so unrelated consumers retain their previous
sizing policy. Native table configuration remains deferred; row painting and
selection continue through the existing native selection adapter.
Label-only selection retains AppKit/SwiftUI’s original native row class.
Once-installed wrappers for the public selection drawing/background-style methods
consult an exact live row/table binding and forward to captured original methods
for other rows and full-row mode. Retirement removes the binding. This replaces
per-row class swapping, which produced a measured Swift array-bridge trap and an
AppKit dynamic-view-property abort during live environment updates. Other native
row behavior, including computed view metadata, remains with the original class.

Live `LogFontForFileListCtrl`, `LogFontName` and `LogFontSize` changes update both
the SwiftUI minimum and AppKit's custom report height. A nonempty highlighted
selection survives a height change only while the exact row identities and
native ownership still match. Checkboxes retain their independent checked set.
The label-selection overlay uses actual path-caption markers instead of assuming
that the full column width or a fixed inset represents the rendered text.

Detach, retirement and window replacement release the geometry and selection
owners together. Resolve’s probe retires on its actual window-close notification,
clears its model/settings closures and refuses subsequent SwiftUI updates; a
replacement table inside a retained closed host cannot acquire a new owner.
Resolve releases its hosting controller after owned sheets/windows and workers
drain; Working Tree also releases its closed hosting controller. This prevents
SwiftUI’s own font subscriptions from updating retained closed tables, independently
of the retired native adapters. Revert already released its hosting controller.
The shared geometry helper restores the native sizing settings
it captured before installation. A late update from a retired owner cannot
resize a replacement table. Closing and reopening creates a fresh table with
the current originating preferences.

## Grouped verification scope

The authored checkpoint is
`docs/qa/status-report-rows-native-2026-10-26.swift`, run by
`scripts/test-status-report-rows.py`. Its three cases are `resolve`, `status` and
`revert`, each scheduled with system and bundled Git. Receiver compilation uses
the existing source/framework/compiler-aware cache.

Private real repositories supply long Unicode and embedded-newline/tab paths.
Resolve uses actual unmerged stages; Working Tree and Revert use actual modified
files, with a long multiline owner in the Working Tree metadata column. The
checks inspect actual native row, caption, checkbox and available image-view
bounds at default and large fonts, after a resize/theme change and a live font
toggle. They retain a nonempty native/model selection, verify exact private copy
payloads and accessible checkbox names, detach/retire/reopen the
actual adapters, and compare HEAD, semantic index records and working bytes.
Full-path help assertions require an observable native help surface. In this
offscreen receiver, SwiftUI exposes neither virtual text accessibility help nor
AppKit tooltip registrations, including constant metadata help. Those runs report
tooltip display explicitly as unverified rather than treating an empty query as
a product regression or a successful tooltip check. If help is observable, exact
raw/absolute path content and live disable/re-enable assertions remain strict.
Actual hover display and VoiceOver require separate physical acceptance.
All owned windows and sheets stay offscreen with zero alpha; private preferences
and pasteboards are removed, and workers/receivers are drained.

[Current family evidence](qa/status-report-rows-2026-10-26.json) records the
failed attempts, repairs and final checks. Debug builds pass; all six actual
dialog/Git case pairs pass the geometry/data/close assertions after the recorded
repairs. The existing AppKit/SwiftUI selection-adapter check also passes native
keyboard navigation, checkbox action, column reorder and mode/style/delegate
restoration. All 19 attempted receiver PIDs are reaped and independently absent.
No table-delegate reentrancy warning occurs in the final six-case group; this does
not establish the cause of earlier Resolve mutation warnings or global resolution.
Every final tooltip result remains explicitly `unverified-offscreen`. The earlier
Commit checkpoint retains its own original scope. No Core behavior changes are part of this layout family. Physical
keyboard use, every column/locale/font combination, minimum-OS behavior, signed
sandbox acceptance and pixel-for-pixel Windows visual parity remain outside the
focused native assertions.
