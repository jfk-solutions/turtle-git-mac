# Reference refresh: Rebase, Fetch/Pull and Push

This family ports the remaining dialog refresh behavior against the pinned
TortoiseGit source. It does not certify the complete Rebase or transport port.

## Source controls and routes

- `RebaseDlg.cpp:873–878` sends unmodified F5 to `Refresh()`.
  `2739–2755` refreshes conflict files in conflict/squash-conflict recovery,
  does nothing in ordinary Cherry Pick, and rereads branch information and the
  log plan in Choose Branch. `LoadBranchInfo():471–508` selects the current HEAD
  branch and retains the displayed upstream, or selects an existing tracked
  upstream when that field is empty. `FetchLogList():665–739` rebuilds the plan
  in source order, resets actions to Pick and recomputes patch-equivalent Skip
  defaults. Refresh does **not** preserve user Add/order/action edits.
- `PullFetchDlg.cpp:63–66` maps `IDC_REMOTE_COMBO`, `IDC_REMOTE_BRANCH` and
  `IDC_REMOTE_MANAGE`. The manager return at `466–471` invokes `Refresh()`.
  `271–337` rereads the current branch, tracked remote/branch and registered
  submodule `.gitmodules` branch default, inserts the branch choice, reloads
  remotes and runs the selected remote's tag/prune hint consumer. The first
  available combo row is the fallback: All Remotes for Fetch with multiple
  remotes, otherwise the first named remote. No global F5 route was found in
  this pinned Pull/Fetch dialog; this batch does not invent one.
- `PushDlg.cpp:61–63` maps source/destination/remote selectors. Its existing F5
  route at `577–588` and `Refresh():218–287` reread remote/reference catalogs.
  Native Push's previously implemented owner-scoped F5 remains in place.
- Synchronization already implements source F5 and full catalog refresh; its
  exact form receipts and source history policies are retained. Select Remote
  Reference already implements source F5. Neither is replaced by a duplicate
  refresh mechanism in this batch.

## Native behavior

`RebaseNativeWindow` handles F5 for its own key dialog, including field editors.
A discoverable Refresh button uses the existing source refresh icon. A sheet,
modal dialog, Quit, reference picker, revision Find/containing-reference owner,
execution/recovery question, retired window or incompatible replay phase blocks
this route. During conflict recovery it uses the existing owned session refresh.
Ordinary Cherry Pick and non-conflict execution phases remain unchanged.

Idle refresh reads the complete reference catalog, exact symbolic HEAD (or
its detached commit), the applicable upstream default, a fresh replay plan and
reference tooltips. Success publishes them together, selects the first new row,
clears old Add/order/action drafts and displays the selected commit message.
Branch/upstream/onto and unrelated replay options follow the source rules above;
Start is disabled while the read is pending. Superseded reads are canceled and
cannot publish or release the newer request. Cancellation and failures retain
the last accepted plan and draft. Refresh never starts replay or writes refs,
index or configuration. The native asynchronous atomic publication is an
adaptation of the source synchronous refresh.

Fetch/Pull now own the actual embedded remote-manager instance and a captured
receipt containing the form identity, owner window and exact draft values. The
manager's native retirement callback supplies that receipt. The parent waits
for that particular child's worker and sheet release before rereading repository
defaults, rather than copying the child's cached remote list. The child inherits
its owner's appearance and visibility, including offscreen verification windows.
Late, duplicate, mismatched, retired or Quit-blocked callbacks do not dispatch a
refresh. The parent's existing preparation counter retains its access grant and
owned work through cancellation/drain.

The return refresh updates the source remote/branch defaults and selected
remote's tag/prune hints without resetting manual tag/prune overrides, URL mode,
refspec mode, depth or Pull integration flags. Configured remote fallback uses
actual membership. The captured defaults retain raw `branch.remote` separately:
an absent configured tracking remote falls back to the first source combo row;
a remembered remote is considered only when the raw tracking setting is empty. Cancellation preserves the accepted form and offers Retry
loading using the same captured form; failure diagnostics remain available.
No refresh writes remembered selections or Git configuration.

Core `fetchDefaults`/`pushDefaults`, named Fetch/Push submission validation, and consumed Fetch/Push initial/reload
membership checks compare exact UTF-8 remote identities. An NFC remote does not
validate a removed NFD sibling. The existing native popups already add distinct
`NSMenuItem`s and use `GitReferenceName` for catalog/index lookup; their controls,
icons and callbacks remain. Windows combo case-folding and history insertion
rules are separate from Unicode canonical equivalence: shared history policy is
not globally changed by this correction.

## Checkpoint and remaining acceptance

Implementation adds `ReferenceRefreshTests` and the cached private runner
`scripts/test-reference-refresh.py` with `rebase`, `metadata` and `lifetime`
cases. The receiver exercises actual owned windows, native F5/popup targets,
real manager retirement and Git defaults, captured held reads, cancellation,
supersession, failure, conflict-phase routing and forced retirement. It uses
private preferences/repositories, invisible/offscreen windows and owned helper
cleanup, with system and bundled Git executable selections. It does not claim
physical keyboard/mouse/VoiceOver or signed sandbox grant acceptance.

The grouped checkpoint passes the Core exact-identity method and all six
native case/engine pairs. Fixture entry/API compile corrections and actual
error-sheet acknowledgment were repaired without production changes; only the
affected lifetime pairs were rerun. All seven attempted receiver PIDs were
independently confirmed absent. See the [batch evidence](qa/reference-ssh-overlay-family-2026-10-24.json). Existing full replay,
transport/backends and hosted CI remain broader acceptance scopes. Source custom
Windows combo drawing/placement and every exceptional remote configuration are
not certified by these focused refresh cases.
