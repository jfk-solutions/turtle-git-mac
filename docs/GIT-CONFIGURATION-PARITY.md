# Git configuration page — implementation in progress

Pinned reference: `7338078f8ddd924b8cddee35f512f2286072136d`,
`SettingGitConfig.cpp`, `GitSettings.h` and `IDD_SETTINGIT_CONFIG`.

The Settings → Git page now implements the source selector (Effective, Local,
Global, System), User Info (Name, Email and Signing key ID with individual inherit
checkboxes), AutoCrLf/SafeCrLf choices, three-state QuotePath/Prune checkboxes and
separate Local/Global Save to selection. Effective values are read-only. Local
is unavailable when no repository is open. System values can be copied to a
Local/Global destination; the source page does not offer system as a save target.

The repository layer reads scoped Git configuration with includes, preserving
empty versus absent identity values. Effective identity follows upstream's
GIT_AUTHOR_NAME/GIT_AUTHOR_EMAIL, author.name/author.email, then user.name/email
precedence. Effective missing QuotePath defaults to true and Prune to false;
scoped absence is mixed/inherited. Git normalizes boolean aliases. The special
input/warn line-ending values remain distinct. This page does not honor
.tgitconfig for these seven fields, matching InitGitSettings(false).

When effective Name and Email are both empty on initial load, the page selects
Global, clears their inherit flags and selects Global as the save destination.
Switching sources reloads/discards drafts as upstream does. Selecting Local or
Global also selects that save target. Apply to a different source/destination
asks Save/Abort with Abort as the default. Apply writes the seven source fields
in source order; failure stops remaining writes and reports that earlier values
may already have been saved. Empty line-ending and mixed/inherit controls unset
the destination entry; explicitly empty non-inherited identity remains empty.
Repeated entries are replaced/removed by the CLI adapter rather than relying on
libgit2's multivariable write behavior; cross-engine compatibility needs review.

View effective config and View systemwide gitconfig display selectable read-only
text with Git's origin annotations. Reads use owned cancellation, and switching
repository/source or leaving the page rejects stale results. Loading failures
keep Apply disabled. Saving retains its repository permission grant and completes
its source-ordered batch after owner closure; Quit remains blocked until it ends.
Repository-scoped access is checked in AppStore builds. Global paths currently
follow the Git runtime environment, including the app's sandbox home; external
user-global config selection/bookmark integration remains to be implemented.

## Remaining section scope

- Original Edit local/global/XDG/system config buttons and .tgitconfig editing,
  bare-repository .tgitconfig viewing, and the configured alternative editor route.
- Global/config-file permissions and persisted grants, signed sandbox execution,
  included-file write compatibility and external configuration changes.
- The source hierarchy hint and full Settings tree/property-sheet host.
- Real repository/environment/inheritance/write/error checks across Git engines,
  native scope switching, three-state input, confirmation, close/quit ownership,
  keyboard/focus, light/dark screenshots and displayed acceptance.

This is production implementation registered in SwiftPM/Xcode, but **uncompiled
and untested**. Validation is deferred while the full Git settings section is
being implemented. No dialog is newly certified and the inventory counts are
unchanged. Existing history/Settings QA records do not cover this page.
