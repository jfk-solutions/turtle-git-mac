# URL and path word navigation

The native path editor, Commit's new-branch and author fields, Clone histories,
Fetch histories (also reused by Pull, Push and Sync), and Bisect revision combos
now adapt TortoiseGit's URL/path word boundaries. Option-Left/Right moves by the
components of a path, URL, reference or email address. Adding Shift extends the
selection; reversing direction retains its anchor. Option-Delete/forward delete
uses the same boundaries and native text editing, bindings and Undo.

Advanced Settings → `UseCustomWordBreak` retains the source modes:

- **0:** use the native macOS editor behavior.
- **1:** customize the connected plain fields; leave combos native.
- **2 (default):** customize the connected plain fields and editable combos.
- Other nonzero values apply to plain fields only, matching the source condition.

ASCII whitespace and punctuation delimit components. The colon and first slash
in `://` stay with the scheme, so movement passes the scheme as one component.
Consecutive separators are skipped. CR sequences before LF follow the source's
special classification. Cocoa caret stops are adjusted to composed-character
boundaries, preserving emoji and combining text. Non-ASCII punctuation/locale
behavior is not claimed equivalent to every Windows CRT locale.

Each control coordinator owns its navigation state. A changed editor, selection
or raw text abandons an earlier extension anchor. Read-only selectable author
text still supports movement; deletion requires editing permission. Disabled,
hidden, detached, wrong-delegate and attached-sheet contexts decline custom
commands. Marked IME text remains on AppKit's normal path. Standard non-word
commands, completion and history dropdown deletion retain their existing routes.
Clone now supplies its owning preference domain to the native SwiftUI root too.

## Source and verification scope

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
`src/Utils/MiscUI/EditWordBreak.cpp` blob
`edf8f7eadccacdf220c54a9c08ea7e33fc1b0c79` supplies delimiter rules;
`src/Utils/MiscUI/StandAloneDlg.h` blob
`9318dc83e07aaefdd8890ac66ffcd4c1f7ad39b4` supplies the setting/default and
combo inclusion rule. The USER callback-order workaround is specific to Windows;
the native adapter receives Cocoa word commands directly.

This covers the connected native controls listed above. Arbitrary SwiftUI text
fields, other standalone controls, mouse double-click word selection, physical
keyboard layouts and VoiceOver remain separate work. It does not replace the
Commit message editor or Merge's own text/word navigation, and does not establish
full application or signed Finder/App Store parity.

[Batch evidence](qa/input-word-navigation-2026-10-17.json) records the first-pass
11 Core cases, build and eight native family/engine checks, including receiver
ownership and the precise remaining acceptance scope.
