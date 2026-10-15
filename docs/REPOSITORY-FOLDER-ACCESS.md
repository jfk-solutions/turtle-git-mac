# Repository folder access

A linked worktree or submodule can keep Git metadata outside its working folder.
A shared clone can also read objects from another repository. In an App Store
build, choosing the working folder alone does not grant access to those locations.

When opening such a repository, TurtleGit shows **Allow repository folder access**
with the reason and exact folder needed. Select that folder, or a parent folder
containing it, then choose **Allow Access**. A narrow worktree metadata grant can
reveal a second request for its common Git directory; granting the common directory
covers both. External object-store chains can require additional choices.

Cancel keeps the previous workspace. Choosing an unrelated folder reports an error
and also keeps the previous workspace. Closing the initiating window cancels its
picker; a late result cannot save access or open another repository.

Successful opening remembers the extra folder grants with that repository in the
app's private repository archive. Reopening renews available stale bookmarks and
reuses valid grants. An unrelated expired grant does not prevent opening: the
workspace asks only for currently required folders that remain uncovered. The
Finder service retains its separate strict authorization policy.

Open repository windows and their child tools keep these permissions active until
they finish. Closing the workspace does not drop access from an already-open Log
or other child window. Primary working-folder containment remains separate from
metadata access, so a metadata choice does not change which repository was opened.
Authorized metadata directories can participate in file monitoring, and an already
authorized template or approved client hook can use that folder permission.

Workspace grants live with the repository in Recents. Forget that saved repository
and close its windows to discard the saved grants; opening it again asks for the
needed folders. A dedicated workspace grant editor remains to be ported. Active
operations retain permissions they already acquired until their windows finish.

Background Finder watches have a separate archive and authorization lifecycle.
Their grants are managed under **Settings → Icon Overlays → Watched Repositories →
Additional folder access**. Opening a workspace does not itself enable that service
or copy its new grants into the watch archive.

The current implementation covers Git files, common worktree directories, bare
repositories, symlinked metadata and recursive `objects/info/alternates`, including
quoted paths. It rejects malformed path metadata and bounds dependency traversal.
Unsupported non-UTF-8 filesystem paths remain a separate native policy limitation.

[Recorded Core/native checks](qa/workspace-metadata-access-2026-10-15.json) use
private repositories and an injected bookmark provider. They do not establish
signed sandbox inheritance, physical powerbox behavior, network filesystem
behavior or complete App Store acceptance. Local clone-source and SSH-key grants
remain separate workflows.
