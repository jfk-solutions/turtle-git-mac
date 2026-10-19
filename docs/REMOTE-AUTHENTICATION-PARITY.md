# Shared Git transport authentication

Pinned TortoiseGit: `7338078f8ddd924b8cddee35f512f2286072136d`.
This family covers the shared libgit2 callbacks used by Clone, Fetch, Sync Fetch,
remote reference listing and remote tag/branch deletion. It is a partial source
comparison, not certification of every authentication provider or the whole port.

## Source contract

`AppUtils.cpp::Git2GetUserPassword` opens `CUserPassword` with the callback URL and
optional username. `IDD_USER_PASSWD` in `src/Resources/TortoiseProcENG.rc` contains
two aligned Username/Password rows and OK/Cancel. `UserPassword.cpp::OnInitDialog`
adds the URL to the Password title and focuses Password when Username is already
filled. Empty usernames keep the dialog open and return focus to Username.
`UserPassword.h` sets a 256-unit password buffer; the edit limit is 255 UTF-16
units. Destruction clears the secure edit and source buffers.

`AppUtils.cpp::Git2CertificateCheck` and `CCheckCertificateDlg` use `IDD_CERTCHECK`
with the actual validation error, friendly certificate/issuer names, separate
SHA-1/SHA-256 fields, Open certificate, Accept certificate and default Cancel.
The source `last_accepted_cert` survives separate callback invocations within the
Windows process. It is not a permanent trust installation.

The selected source libgit2 callback asks for credentials directly; it does not
call Git credential-helper fill/approve/reject or persist the password. Ordinary
Git commands retain their separate configured-helper workflow.

## Native implementation

`GitSVNPromptWindowController` has a dedicated Git credential form with aligned
native fields, the source title/focus/validation behavior and no Save
Authentication option. SVN keeps its existing separate form and save policy.
The active secure editor and stored field values are cleared when the Git form
finishes or is cancelled. This does not establish secure erasure of every copy
made by AppKit or Swift.

Certificate review displays a readable issuer and a bounded actual Security
validation diagnostic, with the existing generic descriptions as a fallback for
older prompt payloads. It retains the source certificate icon, readonly identity
and fingerprint fields, default Cancel and the owned native inspector/export.
The Git-only diagnostic field cannot enable SVN persistence or additional Git
prompt kinds.

The Core process retains up to 128 memory-only temporary acceptances.
Each selected helper receives a snapshot through its operation-owned private
exchange and returns only actual accepted certificate decisions. The cache key
includes the actual hostname, port and complete DER bytes, strengthening the
source certificate-only comparison. A different authority or certificate must
be reviewed independently. Failed authentication after an accepted certificate
does not discard that decision. Cancellation does not import new decisions.
The exchange is removed with its operation's temporary directory; no password,
Keychain record, trust setting or persistent certificate cache is written.
An exchange admits at most 256 records (snapshot plus new accepts), 13 MB in total,
with certificate DER at most 36 KB and hostnames at most 1,024 UTF-8 bytes. The
actual diagnostic is at most 4,096 UTF-8 bytes, within the complete 65,535-byte
prompt bound. Oversized or malformed payloads fail explicitly.

The existing prompt/filter lock and cancellation marker continue to own actual
child retirement. A certificate export already accepted drains before the native
prompt replies and before the helper's process group is interrupted. Viewing or
exporting a certificate does not accept it. Retired callbacks cannot restart the
operation.

## Evidence and remaining scope

[Grouped batch evidence](qa/remote-authentication-2026-10-19.json) records the
actual checkpoint results, failures and focused repairs. The native content
captures in [transport parity](LIBGIT2-TRANSPORT-PARITY.md) show production
controllers with private sample data, rather than public-server or physical
window-compositor acceptance.

Public providers, proxy/redirect/authentication combinations beyond the recorded
loopback cases, physical keyboard and VoiceOver behavior, current signed sandbox
execution, complete hosted integration and App Store submission remain open.
The optional engine does not acquire a credential-helper or permanent trust
feature from this family. See the [user guide](LIBGIT2-TRANSPORT.md) and
[remote-reference family](REMOTE-REFERENCE-ENGINE-PARITY.md) for connected callers.


## October 19 grouped checkpoint

Fifteen distinct focused Core methods pass. The first group passed twelve methods
and exposed the empty-file EOF bug in three actual HTTPS methods. After the
production repair, only those three and the affected accepted-certificate
cancellation path were repeated. Actual repeated list/delete/refill and
Clone/Fetch calls now retain the exact acceptance; changed peers and rejected or
cancelled decisions remain independently reviewed. A fresh uncached custom-CA
peer retains the separate configured-CA/header proof.

Both architecture helpers rebuilt successfully using the unchanged pinned C
slices. Initial ARM/Intel operation checks passed; the EOF repair subsequently
passed reconstruction/structure checks and local actual HTTPS cases. This does
not establish Intel HTTPS or signed sandbox authentication. The final Debug app
contains the repaired helper with matching source and unsigned/signed identities.

The grouped native receiver passes after two fixture compilation repairs, with
all credential/certificate assertions retained. Its four light/dark content
captures were individually inspected and published. Owned receiver PID 66612 was
reaped and independently absent; native windows/sheets and active operations
drained. No full Core suite or unrelated native groups were repeated.
