# Author pictures in Log

Choose **View → Gravatar** in Log Messages to show an author picture beside the
commit message. Select one commit to load its author's image. Selecting several
commits, the working-tree row or no commit clears it. The choice is remembered
separately for each repository.

Gravatar starts disabled. **Settings → Dialogs → Enable Gravatar** sets the default
for repositories without a saved choice. Existing repository choices keep their
own setting. When enabled, the app sends a hash of the selected author's email to
the configured avatar provider; it does not send the email as plain text.

The default URL is `https://gravatar.com/avatar/%HASH%?d=identicon`. You can enter
a custom HTTP(S) avatar URL. `%HASH%` is replaced with the SHA-256 digest of the
trimmed, lowercased email's UTF-8 bytes. Enable **Use MD5 for Gravatar** for a
provider that requires the older digest. Custom endpoints must satisfy macOS
transport security.

The app waits briefly after selection changes, cancels superseded requests and
caches successful pictures for seven days in its temporary directory. A provider
failure leaves an empty picture area and does not interrupt Git operations.
Closing Log or hiding Gravatar cancels its current image request.

The native implementation is still undergoing displayed and signed sandbox checks.
See [Log parity](LOG-PARITY.md#gravatar) for verification and remaining work.
