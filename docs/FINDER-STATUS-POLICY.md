# Choosing Finder status behavior

Open **Settings → Icon Overlays** and use **Status cache** to choose how TurtleGit
collects badge status. Apply accepts the choice; Cancel keeps the previous one.

- **Default** compares working files, the index and HEAD and rolls changes up
  through parent folders. The unversioned-file and subrepository propagation
  options apply in this mode.
- **Shell Extended** uses the lighter index/working-file comparison and rolls
  changes up through parent folders.
- **Shell** uses the same lighter file comparison, but an ordinary changed file
  affects its direct folder rather than every ancestor.
- **None** shows normal badges on repository folders and suppresses file-state
  badges.

The lighter modes intentionally follow the pinned TortoiseGit implementation:
staged-only changes can remain Normal, and ignored files can appear unversioned.
Use Default when badges should include staged/HEAD differences. The app's Working
Tree window continues to show full Git status in every mode.

Finder reads published status and submits asynchronous refresh requests. It does
not run Git. To refresh watched repositories after quitting the main app, open
**Settings → Icon Overlays → Watched Repositories**. Use **Add…** to authorize a
repository folder, or **Renew Access…** for a selected repository whose permission
has expired. Enable **Refresh after TurtleGit quits** for background refresh.

Finder extension activation is separate: use **Settings → Icon Overlays → Manage
Finder Extension…**. Enabling the extension does not grant repository access.
Changing cache mode does not authorize or register folders, activate the extension
or enable the background service.

Opening an individual action window does not start a fresh scan of every saved
repository. Completed Git actions refresh the selected watched repository.
Opening the workspace resumes monitoring all saved repositories; Add to TurtleGit
and completed clones still prepare the saved permissions needed by an enabled
background service. An unavailable older saved folder leaves valid local
registration working; the background service retains its current permissions and
reports the access problem until it can synchronize the complete set.

Three related rows are available under **Settings → Advanced**:

| Setting | Default | Effect |
| --- | --- | --- |
| `OverlaysCaseSensitive` | `true` | Match index paths exactly. With `false`, retain the repository index's case capability. |
| `TGitCacheCheckContentMaxSize` | `10240` | KiB threshold for checking equal-size files whose recorded timestamp changed. |
| `BlockStatus` | `false` | Suspend Shell/Shell Extended status reads while native Git command work is active. |

The content threshold is strict: a timestamp-changed file at or above the limit
is marked Modified without hashing its content. A smaller file can be checked
against the indexed blob using its configured clean filters. Skip-worktree and
assume-unchanged flags retain their precedence. The collector does not rewrite
or refresh the index.

BlockStatus follows command ownership across all repositories. Merely leaving
the app open does not suspend status. Cancellation keeps ownership until the
command drains, and status can resume after the last command owner exits.

Advanced values remain drafts until Apply. A blank value restores its source
default. A failed publication retains the prior accepted policy and leaves the
draft available for retry. These settings have their own shared record, so an
Advanced Apply does not overwrite a pending Icon Overlays draft.

The [cache menu](CACHE-MENU.md) can disable badges or restore Default while
preserving the other overlay preferences. Source details, bounds and remaining
physical/signed acceptance are recorded in the
[status-policy audit](FINDER-STATUS-POLICY-PARITY.md).
