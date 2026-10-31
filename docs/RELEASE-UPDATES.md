# Checking for updates

Open **TurtleGit → Check for Updates…**, or use **Settings → General → Check now**.
The window shows your installed version, the published version and release notes.
Weekly checks use the same preference in General and Advanced. Turning them off
leaves manual checks available.

A local test build can be newer than the latest public release, and this project
may have no public release yet. An empty release feed is reported separately
from a failed request. **Click here to go to the website** opens the configured
repository's release page.

## Downloading published files

For a release with download files, choose the checkboxes in the bordered file
list and click **Download**. The Mac application archive starts checked when
available. Files without a usable published SHA-256 digest remain visible but
cannot be downloaded inside TurtleGit.

Choose one destination folder in the macOS sheet. It starts at your account's
Downloads folder. This selection grants access to that destination for the
accepted operation; it does not register the folder as a Git repository.

The list shows each file's status while the progress bar tracks the batch.
**Abort** stops the current request. Files that finished downloading are retained;
remaining checked files can be retried. An existing destination file is preserved
and reported as an error. Choose another folder or resolve that filename before
retrying.

A file is published to the selected folder after its size and SHA-256 digest have
been verified. **Show in Finder** reveals completed downloads. Install an update
yourself after reviewing the release; TurtleGit does not unpack or launch a
downloaded installer.

## Store builds and local testing

Store builds use their configured App Store listing and do not fetch replacement
applications from GitHub. A local test build without a public listing says that
no listing is available and disables **View in App Store…**. That state does not
require an Apple account or purchase to continue testing the installed app.

Press **F1** or **Help** in the update window to open this guide.
