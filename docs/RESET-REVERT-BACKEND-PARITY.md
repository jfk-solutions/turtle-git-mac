# Reset and Log commit-revert selected backend

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
This is a partial workflow-family audit of `IDD_RESET`, Log's selected-commit
Revert action and shared `IDD_SVNPROGRESS`; it does not clear every control in
those resources or every libgit2 operation.

## Source behavior

`Git.h` assigns Reset command index 5 and Revert index 6. `Git.cpp::UsingLibGit2`
requires `UseLibgit2` and the operation's bit in `UseLibgit2_mask`. The pinned
default mask excludes these two operations. Ordinary CLI Reset therefore retains
its transcript presentation; enabling libgit2 globally alone does not select
this result-list family.

`ResetProgressCommand.cpp::Run` reports Reset, mode and revision, displays a
progress bar and updates its completed/total count from checkout's progress
callback. Its notify mask is precisely `GIT_CHECKOUT_NOTIFY_UPDATED`. With
`RevertWithRecycleBin` enabled (default true), it moves the notified existing
path to the recycle bin before appending the Checkout row and allowing checkout
to continue. Failure stops the operation. This callback precedes the actual
write: a row is an accepted update notification, not proof that the write
completed. Soft and mixed reset do not fabricate checkout rows.

The selected native Reset captures backend and recycle preferences once when
accepting the mutation. Retry retains those values and the checked plan while
starting a new result attempt. The parent process owns macOS Trash requests and
acknowledges them before the helper proceeds; private helper framing is never
interpreted from stderr or displayed as command output. Failed or cancelled
operations retain accepted rows and diagnostics. The real command outcome is
kept separate from notification transport warnings, and a warning prevents
unattended automatic closing.

`GitProgressList.cpp` gives stopped-worker file rows Show Log, Open, Open With,
and Explore. Row menus capture the attempt and row identity. Keyboard Copy and
Select All have a separate running-worker gate; Copy includes action/path,
whereas context Copy publishes selected displayed paths. Native Reset uses the
shared colored Action/Path list and source icons, preserves selected row UUIDs
when sorting and keeps command/footer rows outside sorted file blocks. It
revalidates repository containment and target identity across asynchronous
application selection. A chooser or file launch owns its window/grant until the
actual reply drains; Close, retry, post-actions and Quit respect that ownership.

`GitLogListAction.cpp::RevertSelectedCommits` asks Yes/No (default No), iterates
selected commits with commit-level progress, supports Skip/Abort after failures
in a multiple selection, and accumulates successful `MERGE_MSG` text. A
successful operation offers Commit review. `Git.cpp::GitRevert` uses
`git_revert` for the selected backend and returns the actual library outcome;
the CLI branch uses `revert --no-edit --no-commit`. Neither route commits.
The native operation captures Revert's backend after the accepted Yes and keeps
it across the selected entries and Skip decisions, including the legacy Log
command route. Its originating preferences and access lease reach the child
and Commit review. It retains commit-level progress rather than inventing a
per-file result table for Log Revert.

A libgit2 zero result can leave conflict index stages, `REVERT_HEAD` and
`MERGE_MSG`. The pinned Log loop counts that as integrated and can offer Commit
review; native code preserves that behavior and does not relabel the library
result as a failed process or claim that the index is conflict-free. Existing
Commit conflict review remains responsible for unresolved paths.

## Validation and remaining limits

`docs/qa/reset-backend-notifications-native-2026-10-19.swift` and
`scripts/test-reset-backend-notifications.py` form the grouped actual-native
checkpoint. They use private repositories, preferences and pasteboard, inject
file-launch responses, and hide/reap owned windows and helper process groups.
Optional `--helper` selects the packaged runtime; `--captures` records actual
Reset list content in light and dark appearances during the same checkpoint.
The [dated checkpoint](qa/reset-revert-backend-2026-10-20.json) records the actual
checks and failed attempts. The initial focused Core group covered 27 methods:
26 passed; the directory-transition expectation failed. The affected recovery
check exposed the separate missing-typechange omission, which was repaired in
the helper. Six affected Reset methods then passed, retaining the final-byte
assertions and earlier unaffected evidence. The universal helper builds for
arm64/x86_64, the Debug app build and six native case/engine pairs pass.

Actual capture review repaired the list's original green-arrow background,
reserved usable height, and separated row glyphs from watermark artwork. Only
the two affected Reset case/engine pairs were repeated after each visual repair;
Log, lifecycle and Core checks were retained. Both final captures were individually
reviewed: [light](site/assets/reset-checkout-results-light.png) and
[dark](site/assets/reset-checkout-results-dark.png). Every owned receiver was
reaped and independently absent. These inactive native-content captures do not
include compositor chrome or prove physical keyboard/Finder acceptance.

Windows recycle-bin UI is adapted to macOS Trash. No physical Finder, signed
installation, hosted CI or complete Reset/Log visual-parity claim follows from
these focused checks. Pinned Reset's `IDI_UPDATE_BKG` maps to the copied `UpdateBackground.ico` with
source provenance; colorful rows retain separate source command glyphs.
Unrelated libgit2 mask consumers and Windows-specific shell integrations remain
outside this family.

## Directory-to-file recycling limitation

The first grouped Core checkpoint exposed an incorrect first-attempt-success
expectation for a directory-to-file transition. Libgit2's
`checkout_action_with_wd_dir` selects `UPDATE_BLOB`, invokes the source
`UPDATED` callback, then still needs its workdir iterator to descend the
notified directory. Recycling the directory synchronously removes that iterator
path and the actual Reset fails with “failed to open directory”. The pinned
`ResetProgressCommand` calls `CTGitPath::Delete(true, true)` synchronously at the
same callback point; this source ordering does not justify silently skipping
recycling or inventing an empty-directory placeholder. This reasoning does not
claim an independently executed Windows result.

The affected fixture retains the real failure, checks unchanged HEAD and the
first-phase recovered directory contents, symbolic-link target and untouched
external destination, then explicitly prepares and retries Reset. The originals
remain in private injected recycle storage, and missing-path retry must restore
both target files without recycling those originals again. Earlier file
notifications remain notifications even though later checkout planning failed.
The initial checkpoint's other 26 methods passed; later repeats were limited to
the helper's affected Reset paths.

The first focused recovery recheck also exposed a separate libgit2 omission:
`checkout_action_no_wd` does not schedule absent regular/link targets for a
`TYPECHANGE`. A retry could therefore return zero and update HEAD/index while
leaving both target files missing. Final-byte assertions are retained. The
bounded helper correction captures only originally missing regular/link
TYPECHANGE targets before Hard Reset; after a successful library reset, it
materializes only still-missing captured paths against the explicit captured
target baseline, with literal pathspecs and the same callbacks, filters and
cancellation. It does not scan for Trash candidates, sweep unrelated paths or
include gitlinks. A later completion failure remains a real partial failure:
HEAD/index may already be at the requested target. The initial directory-iterator
failure remains visible and recoverable; this is not a claim of first-attempt
success. The affected fixture now uses wildcard, newline, tab and Unicode path
names and additionally checks final HEAD/index bytes. Validation of this bounded
completion correction passed the six affected Reset methods, including exact
final HEAD/index/worktree bytes for the literal special-character paths.
