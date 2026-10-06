# Empty replay results and conflict-message hints

Rebase and Cherry Pick now offer **Commit**, **Skip** and **Cancel** when a Pick
or Edit recovery would produce the same tree as destination HEAD. This includes
already-applied patches and a checked-file selection that excludes every change.
The check builds the selected tree in a temporary index; it does not stage files,
move HEAD or change working contents.

An already-applied patch that stops Git opens the choices automatically. Continue
also checks the selected tree after conflict resolution. Cancel leaves replay
active, preserving HEAD, the real index, working files and the message for another
attempt. Skip uses Git's replay Skip operation and discards the current commit's
resolution edits. Commit explicitly permits an empty message-only commit,
retaining the replayed source author and original author-date timezone. Unchecked
changes remain available through the [native amendment loop](REBASE-CONFLICT-FILES.md).
An Edit action still pauses for message approval after applying the empty commit.

## Conflict-message warning

Before continuing a conflict, TurtleGit detects the commented conflict list using
TortoiseGit's exact newline/comment-prefix pattern. **Ignore** continues with the
message; **Abort** returns to the message editor without applying the selected
commit. Abort is the default button. Ignore can persist **Do not show again**;
choosing Abort never stores that preference.

The detector uses `core.commentchar` (default `#`) and honors upstream's
`core.cleanup` exemptions `verbatim`, `whitespace` and `scissors`. It does not
remove the message's commented lines. Upstream's global Strip Commented Lines
setting remains a separate unported preference.

## Verification and limits

Focused Rebase tests check tree-based emptiness, real-index preservation,
explicit empty-commit permission, source metadata, unchecked changes and dirty
continuation rejection. They also cover exact conflict-hint patterns, custom
comment prefixes and cleanup exemptions. The whole-native receiver drives the
actual models through automatic Cancel, Skip and Commit decisions, checks HEAD
and source metadata, and exercises conflict-hint Abort/Ignore before opening the
actual Commit model.

Prompt answers and sheets are injected in hidden native receivers; displayed
button focus, mouse/keyboard gestures and accessibility are not verified. Squash
conflict checkbox selection and its empty-result grouping need separate porting.
No new screenshot establishes these prompts' appearance, and unsigned builds do
not prove signed sandbox execution or App Store acceptance.

Pinned upstream: `7338078f8ddd924b8cddee35f512f2286072136d`,
`src/TortoiseProc/RebaseDlg.cpp` (`IDS_CHERRYPICK_EMPTY` and conflict continuation),
`src/TortoiseProc/AppUtils.cpp` (`MessageContainsConflictHints`).
Evidence: [QA record](qa/rebase-empty-results-2026-10-06.json).
