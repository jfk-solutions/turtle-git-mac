# Send Patch parity

The dialog and delivery remain unported. The first foundation is source-style
message preparation in TurtleGitCore. Existing Format Patch and Import Patch
consumers still invoke macOS composition directly; they do not yet expose these
options. No native Send Patch or SMTP acceptance is claimed.

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`.

| Upstream source | Replacement / audit scope |
| --- | --- |
| SerialPatch.cpp/.h | SerialPatch.swift: bounded file read, source headers/folded subject, LF/CRLF body boundary and exact original bytes |
| SendMailPatch.cpp/.h | PatchMailPreparation.swift: separate/combined, inline/attachment messages |
| SendMail.cpp/.h | Checked-list ordering only; delivery/retry/sender identity remain pending |
| SendMailDlg.cpp/.h / IDD_SENDMAIL | Controls and defaults reviewed below; native dialog pending |
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
the checkbox. Patch-list add/drop/removal/order/context behavior and the SMTP
settings link require their own native port, along with all callers.

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

This foundation does not read Git sender identity, build MIME envelopes, write
mail drafts, invoke a mail client or send anything. The future native window must
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
