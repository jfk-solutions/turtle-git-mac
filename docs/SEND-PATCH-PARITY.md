# Send Patch parity

Native options now have a dialog/model foundation; caller routing and delivery
remain unported. The Core foundation includes source-style
message preparation and MIME serialization in TurtleGitCore. Existing Format Patch and Import Patch
consumers still invoke macOS composition directly; they do not yet expose these
options. No end-to-end Send Patch, physical UI or SMTP acceptance is claimed.

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.

| Upstream source | Replacement / audit scope |
| --- | --- |
| SerialPatch.cpp/.h | SerialPatch.swift: bounded file read, source headers/folded subject, LF/CRLF body boundary and exact original bytes |
| SendMailPatch.cpp/.h | PatchMailPreparation.swift: separate/combined, inline/attachment messages |
| SendMail.cpp/.h | Checked-list ordering, source sender capture API and immutable delivery settings; transport orchestration/delivery/retry pending |
| Utils/HwSMTP.cpp/.h | PatchMailMIME.swift: envelope, body and ordered attachments only; SMTP pending |
| SendMailDlg.cpp/.h / IDD_SENDMAIL | SendPatchWindow.swift / SendPatchList.swift: native options, checked/highlighted state and captured preparation; production viewer/review/apply routing and delivery pending |
| AppUtils.cpp SendPatchMail / SendMailCommand.cpp | Entry points reviewed; native routing still pending |
| Settings/SettingSMTP.cpp/.h | Native Email settings, app-private Keychain Store/Clear and pair capture source; transports and actual signed access pending |

## Audited dialog behavior

Mail group: To, CC and Subject fields. Below it: Patch As Attachment, Combine One
Mail, eMail settings link, then a resizable checked patch list and Send/Cancel/Help.
To/CC autocomplete share semicolon-separated address history. All supplied files
start checked. A single file starts highlighted; highlighting determines the
read-only subject preview independently of checked files. Subject is editable
for Combine One Mail, otherwise it displays the single highlighted patch's
subject or clears for multiple/no highlights. Attachment/Combine default false,
persisted after Send; combined subject is retained while toggling the mode.

Send captures checked paths in list order, remembers recipients and both options,
and then starts mail progress. With no checked paths it starts no delivery. The
mail-client mode permits empty To/CC so the composition UI can fill them; SMTP
requires at least one recipient. Double-click opens the patch viewer except on
the checkbox. Native patch-list drop/context controls are implemented below;
production action routing and all callers remain pending.

## Prepared message behavior

- Separate inline: each patch's Subject, body bytes after the mail header boundary,
  no attachment. Separate attachment: each Subject, empty body, one original file.
- Combined inline: chosen combined Subject, concatenation of the complete original
  patch files in checked order, no inserted separator. This intentionally includes
  their mail headers, matching SendAsCombinedMail.
- Combined attachment: chosen Subject, each patch Subject followed by CRLF in
  the body, plus all checked files in order as attachments.
- To and CC remain separate, preserving display names/commas and source semicolon
  splitting. Preparation permits empty recipients; delivery-mode validation is a
  future transport requirement. Fields used as headers reject CR/LF/NUL bytes.
- Patch headers use the source's exact From/Date/Subject prefixes. Folded Subject
  continuation whitespace is preserved. Encoded words are left opaque as in the
  pinned parser; a broader encoded-header display/transport audit is pending.
- Nonempty headerless files can be attached, matching Parse(parseBody=false).
  Inline modes require a mail header/body separator. Empty/unreadable/non-file
  inputs and files at or above source INT_MAX are rejected. Readable symlinks
  follow their target while retaining the selected URL; dangling links fail.
  Headers scan in place rather than materializing all file lines.
- Patch bodies and attachment payloads retain their bytes, including CRLF, binary
  patches and non-UTF-8 bytes. Attachment requests retain an immutable byte
  snapshot alongside the original URL. Delivery must use that snapshot (or a
  private file made from it), not reread a changed or removed selected file.

The preparation foundation does not write mail drafts, invoke a mail client or
send anything. Sender identity capture is now available separately as described
below. The native window must
retain repository/per-file scopes and capture the complete options and ordered
checked list before dispatching a cancellable delivery. Credentials must stay in
Keychain, not these options or preferences. Client/SMTP delivery and retries need
actual backend and signed sandbox verification; attaching all files through the
current composition service is not full Send Patch parity.

## Verification

The [preparation QA record](qa/send-patch-preparation-2026-10-10.json) records six
Core tests with system and packaged Git. They cover all four modes, list order
and duplicate inputs, separate To/CC/display names, folded/opaque encoded subjects,
LF/CRLF and empty-body boundaries, binary/non-UTF-8 byte retention, invalid files,
source INT_MAX sparse-file rejection, readable/dangling symlinks, immutable attachments after replacement
and deletion, and single-line headers (including CRLF graphemes). The combined
inline body from two real binary format-patch files applies with git am to the
same tree; original HEAD/index are unchanged. Tests create no mail drafts or
network connections and perform no delivery. Native UI and all delivery gates
remain pending.

## MIME serialization

`PatchMailMIME.data` consumes a prepared message, a supplied sender name/address,
and optional date/UUID. The sender must eventually come from repository Git
configuration, not the patch author. From, separate To/CC, Subject, UTC Date,
unique Message-ID and TurtleGit X-Mailer precede a plain body or multipart/mixed
body with ordered original attachments. Empty recipients are permitted for future
mail-client review; SMTP envelope validation remains a transport responsibility.

Base64 uses CRLF framing and 76-character lines. Payload decoding preserves the
captured bytes exactly, including original LF/CRLF and binary attachments; this
is a native adaptation of upstream's 8bit text/CRLF normalization and Base64
attachments. UTF-8 subjects/display names use short encoded words, split on
Unicode scalar boundaries. ASCII Git encoded subjects remain opaque so a mail
reader decodes them once. Filename parameters use percent-encoded UTF-8
continuations, preserving quotes, semicolons, newlines and long Unicode names
without injecting headers. Standards: [RFC 2045](https://www.rfc-editor.org/rfc/rfc2045),
[RFC 2047](https://www.rfc-editor.org/rfc/rfc2047),
[RFC 2231](https://www.rfc-editor.org/rfc/rfc2231), and
[RFC 5322](https://www.rfc-editor.org/rfc/rfc5322).

Mailbox support includes ASCII dot atoms, quoted local parts, domain literals,
and optional quoted/Unicode display names. Comments, groups, comma-separated
address lists within a recipient, and international mailbox addresses fail
explicitly rather than being silently changed. Existing source semicolon
splitting is retained. Header control bytes and lines longer than 998 bytes are
rejected; fields containing encoded words also enforce the 76-character line
limit, including the header name and folded address lines. Unfoldable long
opaque encoded subjects or long addresses in encoded-name fields fail explicitly.
UTF-8 is the default body charset and invalid UTF-8 fails explicitly;
Latin-1 can be selected by the future encoding UI without altering body bytes.
Broader encodings, mixed raw-Unicode/encoded-word subjects, unusual mailbox syntax
and large-message streaming still need acceptance. SMTP dot stuffing, TLS,
authentication, credentials, envelope recipients, retry/cancellation, native
composition and signed sandbox integration remain pending.

Six MIME tests use Python's independent standard-library email parser to verify
all four modes, distinct recipients/display names, long Unicode subjects and
filenames, exact body/attachment bytes, opaque encoded subjects, empty recipients,
unique IDs, explicit charset choice and invalid-header/mailbox failures. The
existing real binary-series test also applies serialized separate inline MIME
messages with Git am and verifies the resulting tree and unchanged source index
and HEAD. See [MIME QA](qa/send-patch-mime-2026-10-10.json).

## Native options foundation

`SendPatchWindowController` hosts native macOS fields and a resizable AppKit
checked list in the source order: Mail To/CC/Subject group, Patch As Attachment,
Combine One Mail and eMail settings, patch paths, then Send/Cancel/Help. The
pinned `doc/images/en/SendPatch.png` was inspected alongside `IDD_SENDMAIL` and
SendMailDlg. Source labels and layout grouping are retained with native macOS
spacing, original colored patch icons and semantic light/dark colors. Physical
visual acceptance remains pending; hidden host layout does not prove visual parity.

Every supplied row starts checked; a single row also starts highlighted, while
multiple rows have no initial highlight. Duplicate paths retain independent row
IDs. Clicking a checkbox or pressing Space changes checks independently of the
highlight. One highlight previews that patch's subject even if unchecked;
multiple/no highlights clear it. Combine enables the separately retained custom
subject. Preview reads are asynchronous, cached by row identity, and fenced after
highlight/mode changes or owner invalidation. Submission captures checked paths
in list order and all options before asynchronous immutable preparation; duplicate
submission is blocked. Failure remains retryable; closing the owner cancels work
and suppresses late preview, submission and close callbacks.

To/CC share private-injectable address history and last-token semicolon
completion. An accepted Send remembers source attachment/combine defaults
and a deduplicated newest-first history capped at 65535 addresses. Mail-client
preparation allows empty recipients; SMTP preparation requires at least one
nonblank To/CC token. With all rows unchecked, Send saves those preferences and closes without
preparation or backend invocation, matching upstream. Preparation failure or
subsequent cancellation retains accepted options. Actual delivery validation
still belongs to the backend.
AppStore reads require retained security-scoped file/folder leases; signed
scope acceptance is pending. Send stays disabled without an injected submission
backend. The controller now installs the native eMail settings route. Existing callers are
unchanged; this window is not yet exposed as a complete Send command.

Remaining work includes native entry-point routing and patch viewer
callbacks, production CPatchListCtrl viewer/review/apply routing, sender capture routing,
transport progress/cancellation/retry, actual Mail/SMTP delivery and signed
sandbox acceptance. Help currently links to upstream's patch documentation.

The [native dialog QA record](qa/send-patch-dialog-2026-10-10.json) records actual
model and AppKit control checks, private preference cleanup, Core regression
results, and unsigned Debug/AppStore compilation/bundle audits. The receiver
uses a prohibited activation policy and never orders the options window on
screen. Its light/dark host layout check is distinct from physical visual or
signed acceptance. Paths remain horizontally scrollable to the last native
column as the viewport changes. No mail client or delivery is exercised.

## Patch list source audit and native controls

`PatchListCtrl.cpp/.h` was reviewed in full for the Send Patch instance.
Its menu contains View Patch (default) and Review Patch with the merge tool for
one highlighted row; Apply Patch for one or more. Send Mail is masked out by
SendMailDlg to prevent recursive Send dialogs. Actions use highlighted rows,
independently of checks. This list has no Add/Remove/Up/Down controls: those
belong to ImportPatchDlg. Earlier backlog references to adding those controls
to Send Patch were corrected after inspecting this source.

The native menu preserves that order/cardinality, marks View Patch in bold,
uses original upstream icons as requested, and honors the application's context
icon preference. Default and alternate (Shift) viewer intent, review and apply
have explicit callbacks; Apply captures highlighted file IDs in displayed order,
including initial duplicate rows. Callbacks remain gated until wired to actual
viewer/review/import consumers. A closed or busy owner ignores actions.

File URL drops append in incoming order, check newly inserted rows, ignore
directories and already listed standardized paths, and leave existing checks
and highlights unchanged. Initial duplicate rows remain independently selectable;
dropping that path does not create another row or recheck an unchecked one.
Remote URLs are rejected. Dropped URL security leases are retained with the model;
AppStore drops require a new or existing matching grant. Actual signed drag grants
remain unverified. No removal/reorder controls were invented for this dialog.

The expanded hidden [receiver](qa/send-patch-dialog-native-2026-10-10.swift)
checks selection-dependent menu order/icons, callback dispatch against captured
unchecked rows, alternate viewer intent, highlighted duplicate ordering for
Apply, icon preference, disabled/closed guards, append/dedup/directory behavior,
and native file-URL pasteboard decoding. It opens no viewer, applies no patch,
and sends no mail. See [list QA](qa/send-patch-list-2026-10-10.json).

## Sender identity capture

`GitRepository.patchMailSender` captures the pinned CSendMail constructor's
GetUserName/GetUserEmail behavior independently for name and address: nonempty
GIT_AUTHOR_NAME/GIT_AUTHOR_EMAIL, then nonempty author.name/author.email, then
user.name/user.email. Empty overrides fall through. Committer identity and EMAIL
are not fallback inputs. The sender is independent of the patch file's author.
Git reads effective configuration, including included files and local overrides;
missing values remain empty rather than synthesizing a login identity. Malformed
configuration and invalid UTF-8 output fail explicitly. NUL-framed values retain
embedded newlines so MIME header validation rejects them instead of silently
changing identity. A shared cancellation token fences reads and returned capture.

The caller can inject environment overrides for private tests and must capture
this identity before transport submission. This API does not set Git config,
compose drafts or send mail. Production routing, settings and all delivery gates
remain pending. Three real-Git sender tests exercise precedence, included config,
missing values, malformed config, cancellation, unchanged config and MIME header
rejection. See [sender QA](qa/send-patch-sender-2026-10-10.json).

## Native Email settings

The Email tab in macOS Settings now follows IDD_SETTINGSMTP and the inspected
SettingsEmail.png: Delivery; SMTP Server and Port on one row; disabled empty
From; Encryption; authentication checkbox; Credentials group with read-only
selectable Login, Store credentials and Clear. Original colored Send Mail icon
and native light/dark colors are retained. Windows MAPI is labeled Mail client
on macOS. All three source delivery choices and encryption choices are retained;
this settings page does not yet provide the transports.

Server, Port, Encryption and Authentication are enabled only for configured
SMTP. Login/Store additionally require authentication. Clear depends on an
existing login independently of delivery/authentication, matching upstream.
Encryption changes do not guess a port. Apply saves the five SendMail settings;
Cancel discards unapplied options. Port entry follows source DWORD validation
(0 through 4294967295); actual transport must validate its TCP port separately.
The settings page's missing delivery preference defaults to direct SMTP (0),
while upstream SendMail's missing preference defaults to MAPI (1). This upstream
difference is recorded for future entry-point routing rather than silently
using the page default as the transport default.

Store opens a native username/password sheet. Username is required; empty
password is permitted by the source. Stored login is prefilled and password
focus is requested when it exists. Cancel clears the transient password.
Credential Store/Clear effects are immediate and are not rolled back by the
page's Cancel, matching upstream. Credentials never enter UserDefaults.
Security calls are serialized off the main actor; controls are gated while
work runs, inputs are captured once and invalidated owners ignore late results.

The production adapter uses an app-private, non-synchronizing generic password
item in the data-protection Keychain. Login refresh requests attributes only,
with a noninteractive authentication context; Store updates in place and only
adds on item-not-found; Clear treats item-not-found as success. SDK references:
[generic password items](https://developer.apple.com/documentation/security/ksecclassgenericpassword),
[adding items](https://developer.apple.com/documentation/security/secitemadd(_:_:)),
[updating/deleting](https://developer.apple.com/documentation/security/updating-and-deleting-keychain-items),
[authentication context](https://developer.apple.com/documentation/security/ksecuseauthenticationcontext),
and [noninteractive access](https://developer.apple.com/documentation/localauthentication/lacontext/interactionnotallowed).

Hidden native tests exercise the actual model and read-only Login control with
private preferences and a private credential store. The production adapter's
branches are tested through simulated Security APIs; tests never touch the user's
Keychain or send mail. This is not signed Keychain/file-grant, sheet interaction,
physical visual or transport acceptance. See [Email settings QA](qa/email-settings-2026-10-10.json).
The native Send Patch settings link is now routed as described below;
sender/credential transport capture remains pending, along with Mail/SMTP delivery and the full port.

## Settings link and captured delivery configuration

Send Patch's eMail settings link now opens a retained independent Email settings
window. Upstream launches `/command:settings /page:smtp` as a separate process;
the native adaptation reuses one app-owned settings window, with OK/Cancel/Apply,
and leaves the Send dialog usable. Closing Send does not close these settings.
The window owns its credential work, refuses user close during credential
operations or a credential sheet, and invalidates late callbacks on close.
OK ends field editing, validates the port, applies options and closes. Cancel
discards unapplied options; credential effects remain immediate.

Default Send models now read the current delivery preference when Send is clicked,
including changes applied through the settings window. Missing preference uses
mail client (1), matching SendMailDlg/SendMail; the settings page still uses direct
SMTP (0). Explicit delivery injection remains available for private tests.
The captured SendPatchRequest includes an immutable EmailConfiguration: delivery,
server, UInt32 port, encryption and authentication flag. Settings changes during
asynchronous patch loading cannot change that request. SMTP recipient validation
uses the same captured delivery; separate To/CC and all four prepared modes remain
unchanged. The backend must validate network ports and consume this capture
rather than rereading defaults mid-operation.

SMTPKeychainStore also exposes a transport-only credential source. One
attribute-and-data query captures username/password atomically; missing item
returns nil and malformed/access failures are explicit. Login display continues
to request attributes only. The captured pair is never saved in preferences or
logged. Transport must request it only when configured authentication is required
and retain it only for the operation. Real signed access and transport use remain
pending.

Expanded hidden receivers test the independent settings callback/controller,
invalid OK and applied shared settings, close lifetime/fencing, differing absent
defaults, current SMTP recipient gates, immutable request capture across later
settings changes, and atomic credential decode using simulated Security APIs.
The settings presenter is injected to keep all windows unordered; actual user
opening/reuse, credential sheet gestures and signed Keychain acceptance are not
proved by these tests. See [routing QA](qa/send-patch-settings-routing-2026-10-10.json).

## Configured SMTP transport

`PatchMailSMTP.send` now performs one configured-server submission using a small
C adapter and the macOS SDK's system libcurl. It captures the prepared message,
sender, server, authentication, date/Message-ID and MIME bytes before transport;
no selected patch file is reread. To/CC headers remain distinct while both lists
contribute validated bare envelope addresses, preserving recipient order.
The source None choice attempts optional STARTTLS when available and falls
back to plaintext when unsupported; the other choices require STARTTLS or use
implicit TLS. LOGIN authentication matches the source rather than selecting an
ambient Kerberos identity. STARTTLS requires a successful upgrade; peer and hostname verification
remain enabled. An optional retained private CA file is supported for trusted
private servers and isolated QA without changing the user's certificate store.
References: [SMTP example](https://curl.se/libcurl/c/smtp-tls.html),
[required TLS](https://curl.se/libcurl/c/CURLOPT_USE_SSL.html),
[envelope recipients](https://curl.se/libcurl/c/CURLOPT_MAIL_RCPT.html), and
[cancellable progress](https://curl.se/libcurl/c/CURLOPT_XFERINFOFUNCTION.html).

The worker runs off the main actor, feeds captured MIME in chunks, reports byte
progress, and aborts through the transfer/read callbacks on owned token or Swift
task cancellation. Host, TCP port, timeouts, mailbox and credential NUL validation
precede connection. Ambient proxies/netrc are disabled; transcripts, passwords
and server reply text are never logged. Numeric transport/SMTP status is returned.
Once the complete payload has been supplied, a failed final reply is reported as
possibly accepted rather than promising cancellation or encouraging automatic
retry. Successful acceptance remains successful if cancellation arrives afterward.
There is no automatic retry or submission queue in this API.

The SDK C framework is built through SwiftPM/Xcode and embedded beside Core,
including App Store builds; Finder's existing outer-framework search path resolves
Core's dependency. Bundle QA now checks its presence, SDK system-only linkage,
Core linkage, and universal App Store architectures. This compiles with macOS 13
deployment but runtime transport tests currently cover this host's system library,
not all supported macOS versions or a signed sandbox.

Four real loopback tests cover all four modes from a two-patch series, exact
wire MIME and independent Python body/attachment decoding, separate To/CC
envelopes and negotiated SIZE, optional/required STARTTLS and implicit TLS LOGIN
authentication with private
CA trust, hostname mismatch and untrusted certificate rejection, missing STARTTLS,
recipient/auth rejection before DATA, ambiguous lost final reply, validation,
pre-cancel and Swift task cancellation while waiting for greeting. Fixtures bind
only 127.0.0.1, generate private certificates, and touch no real mail service or
credential store. The existing preparation/MIME/sender tests also run. See
[SMTP QA](qa/send-patch-smtp-2026-10-10.json).

A separate native receiver links the built Debug Core/SMTP frameworks, submits
captured binary attachments to the private loopback server, and verifies exact
wire bytes with an independent MIME decoder. Packaging checks inspect system
libcurl dependencies and Core linkage separately for each architecture; the
unsigned App Store build includes both Intel and Apple Silicon SMTP slices.

This is a working configured-server Core transport, still unwired to native Send
Patch production callers. Sender/Keychain capture orchestration, ordered message
native progress/explicit recovery, direct-to-MX delivery, Mail-client composition, broader
SASL/OAuth/encoding acceptance, signed Keychain/file grants and full physical UI
acceptance remain pending. Optional private CA grants, older system-libcurl
variants and cancellation after upload require distribution acceptance.

## Ordered configured-server submission

`PatchMailSMTP.sendSeries` submits prepared messages in order and reports the
current item, attempt, upload bytes, retry and acceptance. Like upstream
`CSendMail::SendMail`, each failed message gets at most three attempts with a
two-second delay. The shared cancellation token interrupts both submission and
the delay; cancellation stops before the next item. A lost final acknowledgement
stops immediately with possible delivery, rather than risking a duplicate.
This is a macOS adaptation of the source's unconditional retry behavior.

The series captures one date and Message-ID per message before its first
attempt, retaining those values across retries. All message headers, recipients
and bodies are validated before the first submission, so an invalid later
message cannot leave an earlier partial delivery. On transport failure the
result identifies the failed item, attempts and already accepted prefix;
consumers must not restart that accepted prefix silently. Queue tests exercise
successful retry order, exhaustion, partial acceptance, ambiguous delivery,
cancellation during delay and immediately after acceptance, plus a real
loopback series submission after rejecting malformed later input.

Production sender/credential capture, native progress and caller routing are
still pending; the series API alone does not establish that user flow.
See [ordered SMTP QA](qa/send-patch-smtp-series-2026-10-10.json).

## Configured delivery capture orchestration

`SendPatchSMTPDelivery` now connects the captured SendPatchRequest to Git sender
capture, the app-private atomic credential source and ordered Core SMTP. Its
production entry retains the repository access lease and checks App Store scope
before reading Git identity. It consumes the request's delivery/server/port/TLS,
messages and immutable attachment bytes without rereading preferences or patch
files. Git identity and, when required, one credential pair are captured once
before the queue; retries retain those values. Empty prepared input makes no
credential query or connection.

Configuration and every message's sender/header/address/body validation precede
Keychain access. Missing required credentials fails with an Email settings
instruction. Authentication disabled never queries credentials. Cancellation is
checked before and after each asynchronous capture; cancellation while reading
credentials cannot start transport afterward. The shared token and progress
callback pass through to the queue, including its accepted-prefix failures.
Mail-client/direct delivery is rejected by this configured-only entry rather
than silently substituting SMTP.

Expanded hidden native checks use an injected sender, credential actor and
transport to verify captured server/TLS/To/CC/messages after preference/file
changes, authenticated versus unauthenticated credential counts, missing pair,
invalid port/sender, wrong delivery and late cancellation gates. They do not
touch real Keychain or send mail. See
[capture QA](qa/send-patch-smtp-capture-2026-10-10.json).
The same receiver also exercises the production configured entry with a private
Git repository, isolated Git configuration and a loopback SMTP server. Actual
Git sender capture and the built SDK Core/SMTP queue submit a combined message
with two captured attachments; the server independently decodes and compares
the body and attachment bytes and checks distinct To/CC envelope recipients.
This private local submission touches no real mail service or user Keychain.
Native configured progress and Format Patch/Import Patch routing are described
below; full direct/Mail-client options and delivery remain pending.

## Native configured SMTP progress and callers

Configured SMTP now routes Format Patch's mail handoff and Apply Patch Serial's
selected Send Mail action through retained native Send Patch options, then a
separate progress/result window. Exported or selected file grants stay retained
through preparation, and the repository grant stays retained through sender
capture and transport. Parents stay busy until options cancellation or final
result close. Format Patch's export outcome remains independent of mail outcome;
Apply Patch Serial unlocks after the mail result is dismissed, matching source
command behavior. Mail-client/direct preferences retain their existing composition
path; full options/delivery support for those modes remains pending. Changing to
those modes in open configured options produces an explicit unsupported-route
result rather than substituting a transport.

The progress model reports current item/attempt, coalesced upload percentage,
ordered retry/acceptance notifications, accepted-prefix failures and a completion
footer. It supports read-only output/copy icons, original Mail artwork, shared
output limits/action logs, Close/Abort, Escape, optional Abort confirmation and
successful auto-close. Failure and ambiguous delivery remain visible until close;
ambiguous delivery cannot be reported as a simple cancellation. Window close
requests cancellation while busy, and repeated start/confirmation callbacks are
fenced. This output adaptation does not complete upstream's notification-table,
all progress menus or physical/signed acceptance.

Hidden native checks now exercise the actual configured Format controller route,
options, progress and real private Git/loopback SMTP. They also cover Import's
selected-mail/cancel parent lifetime, partial acceptance/ambiguity, retry/footer,
Abort No/Yes and unordered light/dark layout. An injected presentation hook keeps
all test windows hidden. No real mail service or user Keychain is touched. See
[native progress QA](qa/send-patch-native-progress-2026-10-10.json).

## Send Mail notification list

The configured progress window now uses native Action/Path report columns,
matching `IDD_SVNPROGRESS`/`CGitProgressList` rather than the CLI RichEdit dialog.
The table leads the layout; the progress label/bar sits below it while running.
Command uses the source gray Cmd color, Sending uses Modified, errors use
Conflict, Notice is neutral, and Finished! is blue/red with an elapsed-time and
locale-aware date string. The fixed date preference is respected. Sending keeps
the selected native path (blank for combined mail); filenames with CR/LF use
visible glyphs in cells while retaining the original value for copying.

Header sorting is disabled while running. Completed sorting affects only
contiguous Sending blocks, keeping Command/Notice/Error/Finished rows in place.
The notification list retains all control rows independently of the CLI text
output byte limit, including the final result. Selection identities survive appended notifications; the view follows new rows
only when the user is already near the bottom. Initial content sizing covers the
first 30 notifications, and viewport layout preserves user column widths.

Base Send Mail notifications have no source file menu or double-click action.
Their completed context menu contains only Copy to clipboard, with the original
Copy icon and icon preference; it copies Path values. Cmd-A selects all and
Cmd-C works while running, copying Action/Path with the source's empty third
column spacing and CRLF. Native checks use a private pasteboard and exercise
columns, row kinds/colors, busy gates, copy distinctions, sorting boundaries,
selection retention and width retention alongside real loopback delivery. See
[notification QA](qa/send-patch-notifications-2026-10-10.json).
Other GitProgressList consumers, full shared progress UI, displayed/signed
acceptance and complete mail-client/direct delivery remain pending.

## View Patch from Send Mail

Configured Send Mail options now install the PatchList's View Patch and Shift
alternate-viewer callbacks. A highlighted file opens independently of its Send
checkbox. Loading retains the file grants, reads a regular file off the UI
thread, and preserves the original bytes for the native viewer's Save As. The
native viewer is read-only, uses the filename as its comparison title, disables
repository refresh and reuses its owned window on the next view request.

Send and further list actions are guarded while loading. Closing the options
cancels the owned read and fences late presentation/errors; missing files and
invalid alternate-viewer settings restore the controls and report an error.
Busy viewer operations or an attached viewer sheet guard Send and options close.
The child closes with its options owner. The viewer's appearance/width and
external selection use the caller's preferences, allowing hidden verification
with a private defaults suite instead of changing user settings.

The hidden native receiver verifies exact original bytes, an unchecked highlighted
filename containing a newline, normal/Shift built-in reuse, invalid external
settings without launching an app, missing-file recovery, duplicate-open guards,
busy-child close gates and pending-read close fencing. It also verifies the
actual configured Format workflow installs both callbacks. See
[viewer QA](qa/send-patch-view-2026-10-10.json). Actual external-app launching,
physical gestures/rendering and signed sandbox file grants remain unverified.
Review Patch and Apply Patch callbacks in Send Mail, full mail-client/direct
routes and complete application parity remain unfinished.

## Review and Apply from Send Mail

Configured Send Mail now installs both remaining PatchList command callbacks.
Review uses the single highlighted patch's original bytes in the native
TurtleGitMerge working-tree patch-review window. Apply opens Apply Patch Serial
with the highlighted rows in source list order, independently of the Send
checkboxes. Every selected row remains distinct; an unselected duplicate is not
included. Opening Apply does not immediately import anything: the tool retains
its normal checked rows, options, Apply and recovery controls.

These two tools have independent retained window lifetimes, matching upstream's
separate process launches. Closing Send Mail leaves them open; their own guarded
close releases retention. Application termination still checks their existing
busy-operation and draft/session guards. Review loading uses the existing owned
read/cancellation fence, so closing Send before the load finishes prevents a late
tool window. Serial import inherits matching file grants, including a granted
output directory outside the repository, instead of attempting to reacquire
access from plain file URLs.

Hidden native checks exercise actual Review/Apply controllers and disposable
Git repositories: exact highlighted unchecked patch bytes, original selection
order, inherited grant identity, independent lifetime, busy Quit guards, review
application that preserves HEAD/index, and importing two real commits in order.
The configured Format workflow's callback installation is also checked. See
[command handoff QA](qa/send-patch-tools-2026-10-10.json). These checks do not prove
physical gestures, signed access, external merge-tool selection, all error/draft
flows or complete mail-client/direct delivery and application parity.

## Direct delivery MX dependency

`SMTPMXResolver` now replaces the Windows `DnsQuery` dependency used by
`CHwSMTP::SendSpeedEmail` with macOS's system DNS-SD service. It returns MX
preference/hostname records in response order and identifies the root exchange
as a null MX. The C decoder bounds each standalone RDATA record, validates label
lengths and ASCII hostname bytes, and rejects compression pointers, truncation,
trailing bytes and hostnames beyond the DNS limit. The Swift entry validates
domains/timeouts and runs the lookup off the UI thread.

The lookup owns its DNSServiceRef and releases it on completion, error, timeout
or cooperative cancellation. A monotonic deadline and short poll intervals bound
waiting. No credentials are requested and this API performs no SMTP submission.
It uses the DNS-SD symbols re-exported by SDK libSystem; no external DNS library
or helper process is bundled.

Five tests cover wire records/null MX/boundaries, rejected inputs, pre-cancel,
an opt-in read-only system query, and 32 post-open cancellations that leave the
process descriptor count unchanged. The built Debug frameworks also performed
the read-only query and passed the existing private loopback MIME check. See
[MX dependency QA](qa/send-patch-mx-2026-10-10.json). Domain grouping, per-domain
envelopes, MX failover, partial acceptance/retry handling and application entry
routing still need implementation before direct delivery is functional. Full
mail-client delivery and signed/physical/application parity remain unfinished.

## Direct SMTP queue and application routes

Direct delivery now captures the Git sender and immutable messages, groups the
validated To/CC envelope recipients by domain, and queries each domain's system
MX records. The transport tries returned exchanges in response order on port 25,
using the existing optional STARTTLS behavior without configured-server
credentials. Each domain receives only its own envelope recipients; MIME To/CC,
attachments, Date and Message-ID stay unchanged across exchanges and retries.
The whole series is validated before any DNS query or submission.

The queue remembers accepted domains within each message. Its three-attempt
retry resumes remaining domains instead of resending an accepted domain. An
ambiguous upload stops failover and retry; failure reports accepted domains as
well as the whole-message accepted prefix. Cancellation after partial-domain
acceptance remains a delivery failure in the native progress window. A null MX
is a permanent failure. Empty exchanges and transient query/transfer failures
follow the bounded retry policy.

Format Patch and Import Patch now route direct delivery through the same retained
native options/progress workflow as configured SMTP. Direct capture bypasses
configured server validation and credential reads. Hidden native checks verify
real Git sender capture, immutable messages, both callers' options/Cancel
lifetimes and partial-domain failure classification. Twenty-seven focused mail
tests passed with system and packaged Git, covering grouping, failover,
accepted-domain retry fencing, uncertainty, cancellation, null/empty MX and full
MIME headers with a reduced envelope. The actual Debug frameworks also exercised
the direct queue and transport against an owned loopback SMTP server, with exact
MIME byte comparison and independent attachment decoding. No public mail or
user Keychain access was used. See [direct delivery QA](qa/send-patch-direct-2026-10-10.json).

This checkpoint remains a partial port. Its initial attempt stopped at the first
failed domain; the continuation checkpoint below supersedes that limitation. Full mail-client delivery,
other entry points, actual public MX submission, displayed/physical UI and signed
sandbox/Finder/App Store acceptance remain pending. Earlier sections describe
historical checkpoints, whose pending direct work is superseded only within the
scope above.

## Later-domain continuation and retry-wait cancellation

The direct queue now matches `SendSpeedEmail` by continuing to later recipient
domains after a definite lookup or submission failure. It remembers the first
failure, completes later deliveries, then reports the failure with the complete
accepted-domain set. A retry skips all accepted domains. Null MX still permits
later domains to receive mail before returning a permanent failure. Cancellation
and ambiguous submission stop immediately.

Cancelling during the retry delay now retains the prior direct failure's accepted
domains while replacing its cause with cancellation. Previously the generic
series wrapper lost that partial-delivery context at this boundary. The progress
window can therefore continue to show the existing partial-delivery warning.

The focused mail suite now has 28 tests. The new three-domain scenarios cover
first-domain transient failure/recovery, later acceptance and retry skipping,
permanent null MX with later acceptance, uncertain first-domain stop, and retry
wait cancellation retaining later domains. See
[continuation QA](qa/send-patch-domain-continuation-2026-10-10.json). Full
mail-client/public delivery, other entry points, physical dialogs and signed
sandbox/Finder/App Store acceptance remain pending.

## Request Pull ordinary-document mode

Request Pull now uses the shared native configured/direct SMTP workflow with
SendMailDlg's custom subject. Generic document preparation retains full text
rather than stripping mail-patch headers; attachment bytes are captured exactly.
The subject stays editable independently of Combine One Mail and highlighted
rows. Existing Format/Import callers retain patch mode. See
[Request Pull parity](REQUEST-PULL-PARITY.md) and
[mail QA](qa/request-pull-mail-2026-10-10.json). Mail-client mode and complete
physical/signed/application parity remain pending.

## Mail-client options and Apple Mail drafts

Format Patch, Import Patch and Request Pull now open the same retained native Send
Mail options for every delivery mode, including the absent-preference mail-client
default. Patch callers keep their patch subjects/four preparation modes; Request
Pull keeps generic full-document/custom-subject behavior. The old file-only
NSSharingService bypass is removed. Apple Mail is the explicit macOS client
adapter; Email settings labels it Apple Mail drafts.

The client adapter captures the Git sender, validates the entire prepared series,
and stages each immutable attachment in its own private subdirectory, retaining
its original basename and duplicate order. It passes sender, subject, complete
UTF-8 body, separate To/CC addresses and staged paths as typed Apple Event
arguments to a static compose-only handler. User text is never interpolated into
the program. Mail receives visible drafts for review; the handler contains no
send command. Progress says drafts were prepared and directs the user to review
and send in Mail, rather than claiming SMTP acceptance.

Capture and attachment staging run outside the UI actor. AppleScript runs on one
serialized worker queue, with cancellation checked before compilation and again
before invoking its handler. Cancellation gates capture/staging and subsequent drafts. A confirmed earlier
draft remains part of the prepared prefix; ambiguous automation failures stop
without automatic retry and tell the user to inspect Mail. Attachment files are
retained for Mail until Saved Data cleanup rather than removed when our window
closes. Failures before any invocation remove their private staging directory.
Mail may finish an already issued Apple Event before cancellation can stop the
remaining queue; external draft editing/sending belongs to Mail.

The App Store sandbox target is restricted to `com.apple.mail.compose`, using
Apple's documented scripting-targets entitlement, automation permission and a
specific usage description. No temporary Apple Events exception or inbox-reading
access group is requested. Bundle auditing checks the configuration; unsigned
builds cannot prove that the signed sandbox or TCC accepts it.

[Client QA](qa/mail-client-2026-10-10.json) records injected draft capture and
native caller checks. Actual Apple Mail handler compilation/execution, attachment
import/retention, configured-account sender selection, permission denial, external
draft lifecycle, displayed UI and signed App Store acceptance remain unverified.
The adapter does not yet support other mail applications or upstream's modal
MAPI completion/retry lifecycle. Full mail/client/application parity remains open.

Platform references:
[Apple scripting-targets example](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html),
[automation entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events),
[Apple DTS worker-thread guidance](https://developer.apple.com/forums/thread/759287).
The installed macOS Mail.sdef provides the outgoing-message and recipient schema;
its compose access group is inspected as source evidence, not runtime acceptance.

The MailMsg.cpp/.h contract review found additional differences: MAPI keeps
recipient/sender display names and stores attachments in a path-keyed sorted map
that deduplicates paths. The current Mail adapter passes mailbox addresses and
retains captured attachment order/duplicates. Those semantics, default-client
discovery, unconfigured Git identity fallback and modal completion/retry still
require alignment. The BSD CrashRpt Windows helper implementation is not copied.
