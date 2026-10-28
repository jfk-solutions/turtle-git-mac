# Native issue-provider integration

Pinned source: `Utils/BugTraqAssociations.cpp`, `Settings/SetBugTraq.cpp`,
`SetBugTraqAdv.cpp`, `CommitDlg.cpp`, `IBugTraqProvider`/`IBugTraqProvider2`,
`IDD_SETTINGSBUGTRAQ`, `IDD_SETTINGSBUGTRAQADV`, and Commit's
`IDC_BUGTRAQBUTTON`, at `7338078f8ddd924b8cddee35f512f2286072136d`.

The native settings page supplies the association list with enable checkboxes,
Working Tree/Provider/Parameters columns and Add/Edit/Copy/Remove. The editor keeps
Enable, working-tree path and Browse, provider selection, parameters, Options and
OK/Cancel. The source Help button in the editor is disabled; no active Help
operation is claimed. Native multiline JSON parameters adapt its single-line
Windows edit; Options is an owned draft sheet with validation and Cancel.
Settings Apply writes a versioned app-private association archive; Cancel retains
saved rows. An unreadable archive is preserved and cannot be silently overwritten.

Association resolution matches the first enabled exact working-tree path, then
project configuration. macOS compares canonical path identity, rather than the
source's unconditional Windows case-insensitive comparison. Native fallback keys
`turtlegit.issueprovider` and `turtlegit.issueproviderparams` use the existing
Effective/Local/Project/Global settings reader/writer and are kept separate from
preserved Windows UUID/parameters. Associations take priority over that fallback.

Commit captures a provider on reload. The provider supplies its original-style
button text, selection result/message and issue-ID result, pre-commit check and
post-commit completion callback. The native owner retains its once-completed issue
sheet; Cancel preserves the message and ID. Selection locks Commit/Reload inputs,
retains the original repository permission and blocks Quit until the response
settles, including after forced closure. Retired or changed draft/scope replies
cannot replace the current message. Provider validation runs before Git staging
and commit. Completion errors report that the commit already succeeded.

The embedded Native issue catalog provider implements this contract locally. Its
JSON options supply button text, an optional single-line %BUGID% message template,
a required-issue check, and ordered ID/summary items. The searchable native table
supports multiple issues, preserves selections across filtering, and emits catalog
order. Changing a selection replaces its exact previous generated line; unrelated
message lines remain. It makes no remote writes. This is a functional embedded
provider and a native data contract, not execution of third-party Windows COM code.

The embedded HTTP adapter extends this contract with actual remote issue lists,
message preparation, pre-commit validation and success-only completion. A registry
supplies provider descriptors, parameter validation and native options. HTTP uses
version 1 JSON and an exact endpoint; locally enabled exact-root associations
authorize its callbacks. Project fallback alone cannot authorize network access.
Bearer credentials are separate Keychain drafts, published only with Settings
Apply/OK and rolled back on failed or retired publication. HTTP has bounded
requests, responses and deadlines, no redirects or persistent session state,
and cancellation waits for URLSession invalidation. Native sheets retire visually
while their operation and Quit ownership remain until drainage.

Commit captures the full revision within its synchronous repository operation
before awaiting completion. A delayed callback cannot substitute a newer HEAD.
Completion errors preserve Git success and report the failure through an owned
acknowledgement before valid source follow-up actions continue. Cancellation or
changed ownership suppresses those later actions, without retrying the successful
commit. The October 28 continuation below supersedes the earlier blanket
follow-up suppression.
The generic adapter runs as embedded native code in development and Store builds;
it does not load external binaries or downloaded provider code.

The app declares individual ATS insecure-HTTP exceptions for localhost,
127.0.0.1 and ::1, matching the adapter's loopback-only HTTP configuration gate.
No arbitrary-load exception is added. Apple's
[local networking documentation](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking)
describes the OS-version differences for IP-address exceptions; installed
minimum-OS acceptance remains separate from local receiver checks.

Third-party vendor-native discovery, arbitrary provider-specific options UI and
Windows COM binary execution remain open. The October 28 error continuation
below implements the pinned distinction between a failed provider invocation
and a successful call returning explicit refusal text.
The pinned GetCommitMessage2 declares revision-property arrays but does not
consume them; the adapter does not invent SVN revprop storage. Physical keyboard/menus/options/selection, signed sandbox,
minimum-OS and complete source control acceptance remain unverified. No complete
provider ecosystem or App Store certification is claimed. The HTTP family passed
nine distinct focused Core methods cumulatively, the app build and six grouped
native case/engine combinations. [The HTTP-family evidence](qa/native-issue-provider-family-2026-10-20.json)
records fixture/compile repairs, actual assertions, cleanup and remaining gates.

The first grouped checkpoint passed Debug, twelve Core tests and six native cases
with system and bundled Git. Actual association/draft/Commit/cleanup evidence and
acceptance limits are recorded in [the batch record](qa/native-issue-provider-2026-10-14.json).

A final ownership inspection added explicit settings-parent close retirement,
beyond navigation retirement. A focused native-only follow-up passed with both
Git engines, including an actual hosted-page parent close and rejection of later
editor acceptance. Core and the other passing native families were not repeated.
The evidence record distinguishes the initial six cases from these two cases.

## Provider errors and captured Commit continuation — October 28, 2026

Pinned `CommitDlg.cpp:821–838` reports a failed `CheckCommit` invocation and then
continues the same OnOK attempt. Only a successful provider call returning
nonempty refusal text returns without committing. Native
`NativeIssueProviderCommitRejection` expresses that refusal independently from
transport, protocol or invocation errors. The local catalog's required-issue
check uses the same explicit refusal type. HTTP `checkCommit` requires a valid
version-1 response and nonempty NUL-free error text for a veto; malformed fields,
HTTP failures and transport errors remain invocation failures. Token and Task
cancellation remain cancellation. Picker and completion error-field contracts
are not reclassified as commit vetoes.

An invocation failure presents an owned native OK sheet. The continuation keeps
the accepted message, exact path selection, options, form lifetime and attempt;
it never recursively invokes Commit, CheckCommit or the preceding hook. A
pending-only draft revision also rejects away-and-back edits. Native sheet
release completes before the captured operation resumes. Cancel, Quit,
retirement, changed drafts or refused presentation cannot authorize a commit.
The existing preflight cancellation and operation counters retain permission and
Quit ownership until the real work and acknowledgement drain.

Pinned `CommitDlg.cpp:928–965` likewise reports `OnCommitFinished` failures
without clearing a successful commit or its selected post-command. Native
completion notices are separate from actual restoration/post-hook/changelist
failures. A notice attaches to the live owned progress window when present,
otherwise the Commit owner. Acknowledging it permits only the still-current
captured ReCommit, Commit & Push or progress post-action; cancellation/retirement
suppresses continuation and never retries Git or the completion callback. Failure
to obtain an immutable commit receipt keeps its existing terminal diagnostic.
Provider callback context retains the original full revision even if HEAD moves.

The [error-family checkpoint](qa/issue-provider-errors-2026-10-28.json) records
actual Core/native validation, failures and affected repairs. Earlier family
passes above cover their dated source and do not certify this continuation.
Private HTTP tests do not establish real vendor/provider behavior, signed
external consent/grants, physical keyboard/VoiceOver or complete application
parity. Windows COM provider binaries are not executed by this Mac adapter.
