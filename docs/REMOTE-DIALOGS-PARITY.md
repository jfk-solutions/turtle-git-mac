# Add Remote and Select Remote Ref

Pinned reference: `7338078f8ddd924b8cddee35f512f2286072136d`,
`AddRemoteDlg.cpp`, `SelectRemoteRefDlg.cpp`, `PullFetchDlg.cpp` and the
corresponding `IDD_ADD_REMOTE` / `IDD_SELECTREMOTEREF` resources.

Add Remote has Name, URL, OK/Cancel/Help in a compact native sheet owned by
Browse References. Its original-icon Add Remote entry appears in the remotes
folder beside Manage Remotes. Accepted inputs are captured before asynchronous
work. Git validates/adds the local remote without overwriting an existing one,
changing unrelated settings or fetching. Errors retain the draft; closing or
retiring cancels owned work and the parent refreshes after settlement.

The pinned AddRemote form only returns its fields; BrowseRefs has a dormant
handler that opens it and refreshes, with no add operation or emitted menu entry.
The native fork deliberately completes that intended workflow through the
existing remote-settings backend. It does not reproduce the source no-op.

Fetch and Pull now own Select remote ref as a separate native sheet. It shows the
captured Remote read-only, an editable Remote Branch combo, OK and Cancel.
Loading clears old values; successful loading selects the first result. An empty
or failed query disables OK; F5 refreshes. Case-sensitive typed values are kept.
Lists use exact UTF-8 identity, including canonically equivalent names.

The source CLI uses `ls-remote --refs`, excludes tags, strips `refs/heads/` and
keeps other namespaces. The new backend follows that contract, validates returned
OID/UTF-8 records, and applies natural ordering with a byte tie-breaker. Exact
Windows logical ordering for every locale remains unverified. Merely listing
remote refs does not fetch or update local refs, HEAD or index.

The picker owns its authentication coordinator and passphrase sheets, so SSH
questions attach to that child rather than its blocked parent. The remote and
repository/access lease remain captured. Closing during loading requests
cancellation and waits for owned work; forced closure fences late replies.
Active accounting guards Quit after forced closure. An accepted branch updates
the parent only if its captured remote is still current. Rejected presentations
release the parent gate. Refresh never applies an operation to the repository.

Loading is an inline native progress state instead of the Windows system
progress dialog. Source layout, physical combo/F5/Return/Escape/VoiceOver,
authenticated servers, signed file grants and complete dialog acceptance remain
open. The existing focused Core/native checks establish their recorded scope,
not the full application or App Store release.

Fetch/Pull branch history now also follows the source’s case-sensitive setting,
using exact byte identity and retaining the chosen spelling rather than replacing
it with a case-insensitive historical entry. Sheet completion explicitly ends
the child sheet before delivering its once-only result to the parent.

The connected remote-dialog batch passed 22 Core tests and six grouped native
checks across system and bundled Git. See the [scoped QA record](qa/remote-dialogs-2026-10-13.json).
