# Native source form controls

This partial family audit follows pinned TortoiseGit
`7338078f8ddd924b8cddee35f512f2286072136d`. It connects the native control and
keyboard behavior of Branch/Tag, Switch, Merge, Reset, Push and Synchronization.
Existing Git operations and source option semantics remain in their family
implementations. This record does not certify complete upstream parity.

## Reference selection forms

Branch/Tag, Switch, Merge and Reset expose owned form commands for source version
selection, focus, browsing and available options. Option mnemonics operate outside
editable text; discoverable Command-Option aliases preserve macOS text composition
inside editors. Commands and native radios respect the current owner, sheets,
reads, progress, Quit and closure. Captured menu commands expire when their form
state changes. Disabled source options remain disabled in the menu.

Current branch and full-reference captions use bounded, selectable native fields
with exact full tooltips. Long names cannot expand the window or push its option
controls offscreen. Responsive rows retain the source option relationships.
Existing confirmation and Git mutation paths are reused.

The shared reference controls honor the offered native layout width instead of
expanding to the longest menu item. Full names remain in menu titles and tooltips.
Each window retains its declared minimum frame/content size when SwiftUI hosting
recomputes its limits, keeping the source radios, browse buttons and footer usable.

## Push and Synchronization

Push's source F5 refresh reloads actual branch/remote metadata while retaining the
current form draft. It belongs to the key owner and refuses attached sheets,
reads, progress, Quit and a retired window. A closed preparation keeps its actual
worker lifetime until drainage. Push participates in both app Quit freeze paths.

Synchronization uses four native momentary split controls for Pull, Push,
Submodule and Stash. Main segments repeat the remembered action; menus retain
source order, current checks and command icons. Focused Return/Space invokes the
primary action, Shift preserves existing alternate routes, and F4, Option-Down,
Shift-F10 or accessibility Show Menu expose the action menu. Captured actions are
one-use and expire on form/model changes, sheets, Quit or owner closure.

Remote/local branch fields, history deletion and Force now mutate through captured
form contexts. A late callback cannot overwrite a read-busy, disabled, superseded
or retired form. Refresh and action menus share the same ownership boundary.
Editable remote/reference typing follows the source one-second idle timer,
coalescing successive text changes before acquiring outgoing history. Active
transport, children, Quit and owner closure retire the typing receipt and timer.

Source references: `PushDlg.cpp` initialization/Refresh and F5 handler,
`SyncDlg.cpp` split-button menu setup and action handlers, `CreateBranchTagDlg.cpp`,
`SwitchDlg.cpp`, `MergeDlg.cpp`, `ResetDlg.cpp`, and their
`src/Resources/TortoiseProcENG.rc` resources (`IDD_NEW_BRANCH_TAG`,
`IDD_GITSWITCH`, `IDD_MERGE`, `IDD_RESET`, `IDD_PUSH`, `IDD_SYNC`).

## Blame branding continuation

The preserved custom TurtleGit source now has a 512px attribution variant with a
native magnifying-glass cue. Git lettering and the green mascot remain visible.
`MenuIcon.blame`, legacy `TortoiseGitBlame` resource lookups and the custom resource
alias use that PNG. App menus, Settings and Finder consumers therefore share the
fork's artwork. Upstream ICO originals and source resource identities remain
archived with their existing provenance. Icon visibility preferences are retained.

The deterministic generator and branding manifest retain the variant's hash.
The application/document identity validator checks the bundled variant, and the
native branding receiver checks actual Finder file-menu artwork and both aliases
in light/dark appearances. This does not install a Finder extension.

## Validation and remaining acceptance

The Debug build, one relevant Core resource method, native branding and identity
checks pass. Both Git engines pass the reference and transport groups, covering
all seven forms. Actual native typing verifies one read after the source 1000ms
idle delay, retained field-editor focus and cancelled deferred reads. The grouped
[checkpoint](qa/source-form-controls-2026-10-20.json) records failures, affected
repairs, fourteen reviewed captures and fifteen reaped receivers. The reference
checks include exact full menu titles/tooltips and native minimum-size retention
after model publications, sheets and simulated hosting resets. Visual inspection
found and repaired Merge's too-short minimum; it now uses 660×570 content points.
Physical pointer/menu tracking, VoiceOver, all long-reference/locale combinations,
complete source control acceptance, current installed signed Finder behavior and
App Store distribution acceptance remain separate work. Hidden SwiftUI virtual
accessibility limitations are retained explicitly in native verification scope.
The hidden Push receiver injects only the key-owner query; production uses actual
native key ownership. Its event-window, sheet, modal and model-state guards remain
active. This does not establish physical keyboard acceptance.

| Native capture | Light | Dark |
| --- | --- | --- |
| Branch | [Light](site/assets/branch-source-controls-light.png) | [Dark](site/assets/branch-source-controls-dark.png) |
| Tag | [Light](site/assets/tag-source-controls-light.png) | [Dark](site/assets/tag-source-controls-dark.png) |
| Switch | [Light](site/assets/switch-source-controls-light.png) | [Dark](site/assets/switch-source-controls-dark.png) |
| Merge | [Light](site/assets/merge-source-controls-light.png) | [Dark](site/assets/merge-source-controls-dark.png) |
| Reset | [Light](site/assets/reset-source-controls-light.png) | [Dark](site/assets/reset-source-controls-dark.png) |
| Push | [Light](site/assets/push-source-controls-light.png) | [Dark](site/assets/push-source-controls-dark.png) |
| Synchronization | [Light](site/assets/sync-source-controls-light.png) | [Dark](site/assets/sync-source-controls-dark.png) |

These are complete owned-window captures from private fixtures, including
deliberately long names. The Synchronization capture is an up-to-date empty
outgoing list; graph/row rendering has separate family evidence.
