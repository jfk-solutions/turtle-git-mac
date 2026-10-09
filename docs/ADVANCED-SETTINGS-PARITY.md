# Advanced Settings port audit

Target: TortoiseGit commit `7338078f8ddd924b8cddee35f512f2286072136d`.
The native editor and storage are implemented. This is not complete settings or
application parity: most setting consumers and native visual/gesture acceptance
remain pending.

## Source and catalogue

- `SettingsAdvanced.cpp`, blob `1b222ebf9053e0e902f79413899dc92d35071464`:
  52 definitions, source order, defaults, Name/Value presentation, Apply and F2/
  double-click label editing.
- `SettingsAdvanced.h`, blob `86f71b16237139ab46530d5ddbc988649f96ae31`:
  boolean and DWORD validation, empty-value removal and changed-value writes.
  Its StringSetting class has no registered settings in this baseline and is
  not implemented by the native catalogue.
- `IDD_SETTINGS_CONFIG`: list followed by the original warning/default-reset text.
- [Pinned catalogue](upstream-advanced-settings.json): all 52 names, types,
  literal/default expressions. The short-hash default is 8, following the pinned
  `CGit::GetShortHASHLength` implementation rather than the user's Git abbreviation.

`AdvancedSettingDefinition.all` preserves this complete registered catalogue.
The native Settings window adds Advanced after the existing tabs, retaining
Appearance as its initial page. Its AppKit table shows Name then Value, keeps Name
read-only, and edits Value on double-click or F2. Column reordering is disabled,
matching the source's fixed displayed order. The source's global settings tree,
page icon and full property-sheet host remain pending.

## Editing and persistence

Boolean input accepts exactly `true`, `false` or empty. Numeric input currently
accepts ASCII decimal digits or empty, including zero and leading zeros, without
a convenience-widget range restriction. Source `_istdigit` locale/non-ASCII
behavior still needs Windows comparison; the current validator does not claim
that broader parity.

Empty input removes the stored override on Apply. Display of a saved DWORD uses
its signed 32-bit representation, matching source `%ld`. Positive conversion
saturates at `2147483647`, following Windows `_wtol`/LONG behavior; this is not
macOS's 64-bit `long` conversion. [Microsoft's `_wtol` reference](https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/atol-atol-l-wtol-wtol-l?view=msvc-170)
confirms positive overflow returns `LONG_MAX`. Numerically equivalent input does
not create or rewrite an override. The store validates a changed batch before
writing it; source normally validates each edit before Apply.

The native model holds drafts until Apply and preserves the entered text after
Apply, including blanks and overflowing input, as the source list does. Its
modified state resets and notifies the view. Cancel discards drafts and reads
saved values; window-close notification also discards the page's drafts. Apply
writes only this page's edited rows, preserving changes from existing native
settings tabs that share the same keys. Weak window references and a static
repaint callback avoid retaining the settings window/view through the model.

Apply invalidates open native views so the implemented list-background preference
can redraw. Existing consumers also read completion minimum/parse size/
unversioned parsing/extension removal, commit-message styling and app context-menu
icons and separate Finder menu icons. Finder settings publish on Apply and app
startup through an independent presentation cache; signed handoff remains pending.
See [menu audit](CONTEXT-MENU-ICONS-PARITY.md). Other settings
are stored for subsequent ports; their row tooltips state that they have no
effect yet. Storage/editor parity is not proof of their runtime behavior.

## Verification and remaining scope

Four core tests compare the entire catalogue with the pinned fixture, then cover
strict boolean input, invalid batches without mutation, blank deletion, absent
unchanged defaults, numeric equivalence, zero, leading zeros, overflow and signed
stored DWORD presentation. The most recent full core run, before the menu icon
follow-ups, passed 460 tests with zero failures. Focused follow-up verification
is recorded in the menu audit.

The Swift 6/macOS 13 standalone driver instantiates the actual native table/model
without displaying a window. It verifies all 52 rows, Name/Value order,
read-only/editable columns, fixed order, geometry, cancelled label-edit receiver,
draft Apply/Cancel, default deletion, modified-state notifications, preservation
of another page's changes, zero/overflow and source input retention. CI includes
this receiver check after the Debug app build.

Actual F2/double-click/field-editor gestures, Escape/focus behavior, Apply/Cancel
buttons, window reopening/closing, cross-tab lifecycle, repainting an open
Worktree List, light/dark screenshots, source locale digits and signed acceptance
remain unverified. Full settings navigation and remaining consumers remain part
of the full-app goal. See [verification record](qa/advanced-settings-2026-10-06.json).

SanitizeCommitMsg is now consumed by the shared Commit/Rebase message-file
formatter, using the source default-on ASCII trimming and blank-line rules.
Native commits with verbatim Git cleanup verify that disabling it preserves
blank lines while retaining source per-line trailing-space/CR trimming. See
[message formatting](COMMIT-PARITY.md#commit-message-file-formatting-and-comment-stripping)
and [QA record](qa/commit-message-file-2026-10-07.json). Other consumers and full
settings acceptance remain incomplete.

LogIncludeBoundaryCommits is now consumed when opening a Log. Its source
default false and saved boolean enable Git left-right/boundary output, preserve
full commit hashes and parents, and carry the minus mark into boundary lane
states. The Advanced tooltip now identifies it as effective. Real difference/
symmetric/full-history reads and native private-preference checks are recorded
in [boundary history QA](qa/history-boundaries-2026-10-09.json).
