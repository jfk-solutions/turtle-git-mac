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
| SendMail.cpp/.h | Checked-list ordering only; delivery/retry/sender identity remain pending |
| Utils/HwSMTP.cpp/.h | PatchMailMIME.swift: envelope, body and ordered attachments only; SMTP pending |
| SendMailDlg.cpp/.h / IDD_SENDMAIL | SendPatchWindow.swift / SendPatchList.swift: native options, checked/highlighted state and captured preparation; production viewer/review/apply routing and delivery pending |
| AppUtils.cpp SendPatchMail / SendMailCommand.cpp | Entry points reviewed; native routing still pending |
| Settings/SettingSMTP.cpp/.h | SMTP/mail-client settings, Keychain credentials, encryption and delivery remain pending |

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
production action routing and the SMTP settings link remain pending, along with
all callers.

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
backend, and eMail settings without its settings callback. Existing callers are
unchanged; this window is not yet exposed as a complete Send command.

Remaining work includes native entry-point routing, patch viewer/settings
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
