# Local acceptance checklist

Use this checklist for the exact local candidate supplied with its build record.
Check **About → version and build number** first: source fixes and separately
packaged candidates do not update an installed copy automatically. Record the
build number, macOS version and repository size with any result.

Start with a disposable repository. The [offline review sample](app-store/turtlegit-review-demo-v1.zip)
provides branches, staged and unstaged changes, untracked files and a separate
merge conflict. Its README describes the initial state and reset procedure.

## Commit and history

- Open Classic Commit. Type a message, select/check files and toggle Amend. The
  message area, list headers and footer should stay in place while work loads.
  Check the author/date, unversioned, whole-project and message-only options, and
  the Commit / ReCommit / Commit & Push choices.
- Switch to Git Gui-style staging using the compact selector. Both file lists
  should be recognizable when empty. Double-click a file to stage or unstage it;
  selection, counters and patch preview should follow the action without shifting
  the lists. Return to Classic and check the preserved message and repository.
- Open Log. Select commits and inspect their graph lanes, message and changed
  files. Open a file comparison using Return or double-click. Resize the columns
  and repeat in light and dark appearance.
- In Compare/Merge, inspect context-menu and toolbar-overflow icons, the compact
  presentation selector and Encoding choice. An accepted choice should apply
  once; Cancel should leave the document unchanged.

## Finder and standalone windows

- With TurtleGit closed and its Finder extension enabled, choose **Add to
  TurtleGit…** on a disposable existing repository. If access is required, the
  chooser should start at that folder. Allow access. Registration should enable
  the repository menu and status badges without opening a workspace.
- With the app closed again, invoke **Commit…** from that folder. The Commit
  dialog should open directly. Note separately the time until the window appears
  and until its changed-file list is ready; use the owner's large repository for
  a read-only timing observation as well.
- Copy a repository URL, invoke **Clone…** inside a chosen parent, and inspect the
  suggested destination. For `rough.git`, it should end in `parent/rough`. After a
  successful disposable clone, check its Finder menus and badges without another
  registration step.
- Inspect the icon during cold launch and in the Dock. Open About and Settings
  directly: neither should open an otherwise absent workspace. Finder Services
  should expose **Open in TurtleGit**, without duplicating every Git command.
- Open Settings, inspect the Remote list, and exercise Apply, Cancel, close and
  reopen. Use only a disposable remote when testing changes. Closed dialogs must
  not reappear or apply a delayed reply.

## Documentation and cleanup

Open bundled Help and the [homepage](https://jfk-solutions.github.io/turtle-git-mac/).
Check the Getting Started images, light/dark examples, support, privacy and
Impressum links. Port authorship belongs in About and Credits, without dominating
the homepage.

Close test windows and remove only the disposable repositories, registrations and
permissions created for the check. Restore any background-refresh preference you
changed. Report an unexpected result with the build number, exact steps and
expected/actual behavior; do not include credentials or private repository data.

This checklist covers the original reported user journeys. It does not replace
[full source-parity tracking](PORTING.md), hosted CI, supported-platform checks or
[the later App Store requirements](APP-STORE-SUBMISSION-DRAFT.md). Local owner
testing comes before publication; no upload or Store submission is implied.
