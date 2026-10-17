# Finder cache filename identity

Finder's shared status cache now preserves raw Git filenames through collection,
publication, app cache reuse, badge projection and context-menu checks. Canonically
equivalent Unicode names can exist as distinct Git index entries even when the
local filesystem presents them as aliases.

## Cache and compatibility

`statesV2` and `overlayEntriesV2` contain lossless path/value records, using the
same exact-key representation as index flags. Current readers prefer these fields
and reject duplicate raw keys. Old snapshots without them remain readable.
The original `states` and `overlayEntries` object fields remain available to older
installed extensions during updates. Their unavoidable canonical collisions use a
deterministic highest-status-priority projection; that projection is never used
by current readers when modern records exist.

Snapshot construction and parent badge propagation avoid Foundation filename
normalization. Subtree replacement and foreground model storage retain the exact
maps. Submodule configuration path membership also retains both raw spellings.
Index flag reads explicitly disable Git path precomposition.

## Menus, requests and badges

Direct menu status lookup prefers exact cached components. A unique canonical
alias is accepted only within the selected parent namespace. A missing child in
one exact directory cannot borrow a status from its canonically equivalent peer.
Request preparation preserves raw components through existing and missing parents,
while retaining its existing standardization of filesystem root aliases and
literal symlink-leaf policy. Representative shell flags consume the captured URL
without a second Foundation normalization.

Badge projection retains both raw paths. Case-sensitive badge lookup retains
literal identity; insensitive lookup combines aliases using the existing status
priority. Skip-worktree still takes precedence over assume-unchanged for normal
entries, matching pinned `src/TortoiseShell/IconOverlay.cpp` (blob
`d2a725ca3530cb23bccc090e2d49615f5b2e4226` at upstream
`7338078f8ddd924b8cddee35f512f2286072136d`). Raw file URLs are used when notifying
Finder of badge changes. Badge caches remain independent of mutation eligibility;
the app revalidates requests before executing Git.

## Verification boundary

[The checkpoint](qa/finder-exact-cache-2026-10-17.json) records focused Core,
shipping native menu source and existing app handoff checks, including the failures
that exposed additional normalization sites. It does not establish installed
Finder behavior, signed sandbox grants, App Store acceptance, physical gestures or
complete upstream dialog parity. Canonical alias badge behavior on every macOS
filesystem, including case-sensitive volumes, still needs installed acceptance.
