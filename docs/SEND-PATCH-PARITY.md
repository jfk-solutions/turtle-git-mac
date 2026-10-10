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
progress/explicit retry, direct-to-MX delivery, Mail-client composition, broader
SASL/OAuth/encoding acceptance, signed Keychain/file grants and full physical UI
acceptance remain pending. Optional private CA grants, older system-libcurl
variants and cancellation after upload require distribution acceptance.
