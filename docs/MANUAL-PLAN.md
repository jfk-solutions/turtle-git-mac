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
