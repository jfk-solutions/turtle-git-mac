# Historical file and folder transfer

Baseline: TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d`,
RepositoryBrowser.cpp and GitDataObject.cpp. The native adaptation uses
NSItemProvider and NSFilePromiseProvider while retaining immutable displayed
revision/tree snapshots and original suggested file/folder names.

The [raw individual-file continuation](RAW-HISTORICAL-FILE-TRANSFER-PARITY.md)
extends file providers and promises to historical names that cannot become native
filenames. These files use explicit safe proposed leaves; ordinary names remain
unchanged. Literal folder transfers retain their complete-inventory and original
filename requirements. Its checkpoint is separate from the earlier results below.

Transport definitions are independent of the browser window model. The folder
button and its SwiftUI adapter live with the browser UI, while the standalone
CI receiver compiles the production transport against Core only. This corrects
the previous accidental dependency on RepositoryBrowserWindowModel. The CI job
at `2fdc2546` failed in the historical provider step; its raw log/annotations were
unavailable through the connector. Local standalone validation is required to
verify the identified compile defect; no hosted recovery is inferred from it.

Each item provider now owns its prepared historical copies. Its release cleans
those copies; a weak registry permits final application cleanup without retaining
every past export until Quit. Active requests keep their payload and repository
scope through completion. Cancellation checks before retention prevent cancelled
exports from entering the successful ownership set. Progress finishes with the
exported file count, and its cancellation reaches owned Git preparation.

Transfer activity is counted before dispatching a request to the main actor,
including callbacks arriving on other threads. Quit therefore sees queued as well
as running delivery work. The receipt remains through the completion callback.
Provider and promise captures remain independent of later source selection,
branch movement and window closure, as required for actual receiver delivery.

Promised writes use the receiver-supplied destination and NSFileCoordinator,
following [Apple's file-promise delivery contract](https://developer.apple.com/documentation/appkit/nsfilepromiseproviderdelegate/filepromiseprovider(_:writepromiseto:completionhandler:)).
Materialized content is copied to a unique sibling staging path off the main actor,
then atomically published with an exclusive rename. Existing files/directories
are preserved even if they appear during publication. Failed/cancelled staging is
removed, and the historical temporary export is discarded on every path. File
coordination and filesystem copies retain the original scope on the main actor
until the detached write finishes. Signed receiver access remains unverified.

A receiver must consume NSItemProvider's system copy inside its completion
handler, because [Apple documents that temporary copy's callback lifetime](https://developer.apple.com/documentation/foundation/nsitemprovider/loadfilerepresentation(fortypeidentifier:completionhandler:)).
The app's prepared copy and the system's receiver copy are separate ownership
layers. This batch does not assume that arbitrary external applications keep
using a URL after their callback returns.

The standalone script caches compilation by transport/receiver sources, Core and
SMTP objects/modules/maps/header, architecture, compiler and flags. It supports
both native SwiftPM and Xcode-backed SwiftPM layouts, builds only Core when needed,
and reaps its owned receiver/helpers on success, failure or timeout. The existing
shell CI entry delegates to that script. Default CI still runs the check rather
than skipping the failed step.

The receiver checks pinned binary file/folder bytes, prepared-copy release,
queued activity, coordinated/exclusive promise delivery, collision preservation,
pre-cancel and actual started Progress cancellation, HEAD/index/work bytes and
staging cleanup. Browser table/lifecycle checks cover root/folder/list promise
handoffs after source close. Actual results are recorded separately in the dated
QA report. Physical Finder/other-app interoperability, signed sandbox access,
minimum-OS execution, current-head hosted success and full browser/app parity
remain open.


### Historical materialization continuation — October 19, 2026

The [historical file family](HISTORICAL-MATERIALIZATION-PARITY.md) connects the
source default GetOneFile backend to historical opening/editors, Save As and
selected/recursive output. Accepted operations retain their engine choice through
panels and delayed file delivery. Raw comparison and Blame readers remain distinct;
source filter semantics and actual grouped evidence are recorded in that family.

### Recursive selection text and source root naming

The [historical delivery family](HISTORY-FILE-DELIVERY-PARITY.md) extends the
native Browser gesture paths with complete recursive path text, including
nonmaterialized gitlinks, and source root/nested export names. Existing file
promises, exclusive writes and accepted receiver lifetime remain in use. Its
checkpoint records the newly covered native gestures and inventory limits.

The October 23 delivery continuation extracts shared accounting, export retention
and exclusive publication into `NativeFileTransfer.swift`. The standalone transport
runner includes that production source explicitly; it no longer depends on helpers
accidentally available only in the full app file-list adapter. Its cache includes
the additional source without removing any behavioral assertions.
