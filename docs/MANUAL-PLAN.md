# TurtleGit user manual plan

The user guide will follow the organization and terminology of the
[TortoiseGit manual](https://tortoisegit.org/docs/tortoisegit/), with original TurtleGit
macOS screenshots and instructions adapted to Finder, macOS permissions, menu
placement and keyboard shortcuts. This plan does not claim the guide or full port
is finished. Engineering inventories and parity evidence remain separate.

| Chapter group | TurtleGit content to cover |
| --- | --- |
| Introduction and installation | What TurtleGit does, Git prerequisites, distribution, Finder extension activation |
| Basic concepts | Repositories, working tree, index/staging, commits, branches and remotes |
| Daily use | Open/clone/create, overlays/status, commit and partial staging, log, diff, Pull/Fetch/Push |
| Branching and history | Branch/tag, Switch/Checkout, merge, Rebase, cherry-pick, revert/reset and conflict resolution |
| Advanced work | Stash, submodules, worktrees, patch workflows, hooks, signing and credentials |
| Settings | General, Appearance/colors, Git/remotes, tools, Finder menus and saved data |
| Reference and troubleshooting | Dialog options, native shortcuts, recovery, permissions, runtime/authentication and limitations |

For each implemented workflow, show its real dialog, explain options and results,
and include recovery steps that were verified against Git. Document unsupported
features explicitly. Use macOS shortcut names and screenshots, and retain useful
upstream vocabulary so users can move between the two applications.

Use upstream material as a reference, preserving attribution/license requirements
for anything reused. Do not copy Windows instructions or screenshots into the Mac
manual as though they describe TurtleGit behavior. Published pages should describe
the shipped behavior; engineering parity documents track what still needs work.

The [Edit Notes guide](GIT-NOTES.md) now documents that implemented workflow and
its recovery behavior. Its macOS screenshots remain pending.

The [Revert from Log guide](REVERT-COMMIT.md) now covers the single-revision and
merge-parent workflow. Displayed screenshots and remaining workflows are pending.

The [Cherry Pick guide](CHERRY-PICK.md) documents selected commit plans, merge-parent
prompts, attribution and recovery. Displayed macOS screenshots remain pending.

The [Getting started chapter](GETTING-STARTED.md) now covers opening/cloning,
checked-file commits, staging and inspecting history. It links existing native
captures with their checkpoint limits; it does not complete the remaining chapters.


## Finder command and Settings ownership acceptance

Use a signed App Group build and one app process; close it after this grouped
section. Record selected paths and check repository/working/index bytes where
applicable. The Core/menu receiver checkpoint is in
`qa/finder-command-handoffs-2026-10-12.json`; it does not certify these gestures.

- Open Sync from Finder's first-level menu and verify branch/remote/dialog handoffs,
  then confirm it is absent during merge and bisect. Close each child afterward.
- Blame a tracked file; verify its selected path and saved detection preferences.
  Check conflict editing for text/image paths and a multiple-file source selection.
- Compare a file with two path-history commits separated by unrelated commits:
  the base must be its second history entry and the destination current working
  bytes. Verify staged/index/HEAD preservation and meaningful insufficient-history
  feedback. Compare a directory and change revisions/options; its scope and patch
  must exclude similarly named siblings throughout reloads.
- At a registered submodule root, normal Log must show the child's history; Show
  log of this folder must authorize the parent and show the parent's gitlink path.
  Recheck stale registration and a child-only sandbox grant.
- Cmd-comma and repeated Finder Settings requests must reuse the native window.
  Close/Cancel and reopen to verify fresh drafts/cache/transaction and child cleanup.
- Finder Settings in a different known repository must authorize/adopt that target.
  Outside/empty requests must use Global Settings and suppress Local/project/Remote
  without altering the active repository. Dirty/busy context switches must retain
  the old context and provide feedback, rather than discard edits.
- Invoke Help/About outside Git and from bare-root menus. Verify the website and
  native fork/license/artwork panel, cold-launch delivery, themes and keyboard focus.
- Verify source alternative-tool modifiers and signed App Store execution separately.

## Finder LFS and Send Mail acceptance

Run this section with one signed app process and close it afterward. The private
native receiver is a partial proof; real Finder/sandbox gestures remain open.

- Verify the LFS marker gate and outer/inner clauses for a tracked file, multiple
  tracked files, versioned folder, untracked path, bare root and linked worktree.
  Check default nesting, first-level placement, Shift-only policy, exclusions and
  icon suppression. Menu construction must not query remote ownership.
- Remove/change an indexed target after opening the menu: preflight must reject
  invalid paths before server commands. Check staged deletions, literal Unicode,
  tabs/newlines and similarly named directories. Use a controlled LFS endpoint.
- Verify standalone cold-launch progress and an owned-sheet launch. Cancel/Force
  retry must retain captured targets and completed results; Close must clean up
  once and refresh the right repository. Check the successful-lock Pull handoff
  and global Quit guards, then close every child/result.
- Open Send Mail on a patch file outside Git and on an extended-menu ordinary file.
  Opening/Cancel must not submit, change the active checkout or delete source files.
  Check mixed selections, requested order and original capture versus later Finder
  changes. Verify local first-file sender identity and global no-repository identity.
- In the sandbox, reuse grants and authorize missing files/folders/root as needed.
  Check a symlink target outside the selected folder, stale roots and discovered
  roots outside the grant. An owned global context must not become a fake bookmark.
- From outside-repository mail, Review/Apply must choose and authorize the target
  working repository. Test cancellation, owner close/late replies, wrong/bare root,
  blocked controls during discovery and retained patch-file grants. Pure non-Git
  directory review/application remains unfinished rather than certified here.
- Exercise mail-client privacy/Apple Events and controlled SMTP delivery separately
  from this opening/Cancel check. Verify settings/cancellation/progress lifetime
  under the signed App Store configuration.

The [Moving and copying guide](MOVING-AND-COPYING.md) covers native drop choices,
Move/Rename, Copy/Add collision/repository handling and clipboard recovery.
New receiving-sheet screenshots and physical/signed acceptance remain pending.

The [Reverting working files guide](REVERTING-FILES.md) covers the baseline,
Trash recovery, protected-step cancellation, Retry and captured close policy.
