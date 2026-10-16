# Application and patch-document identity

The application asset catalog now packages all ten macOS AppIcon slots (16, 32,
128, 256 and 512 points at 1×/2×). It uses pinned upstream
`src/Resources/Tortoise.ico`, the `IDR_MAINFRAME` artwork. Patch/diff documents use
`src/TortoiseUDiff/TortoiseUDiff.ico` through a native ICNS. This follows the user's
request to retain the same original artwork. No new mascot or generated redesign
replaces it. Exact small frames are used where available; larger slots resample
the original maximum 256-pixel representation. A 1024-pixel slot therefore does
not claim newly drawn high-resolution detail.

`swift scripts/build-application-icons.swift "$PWD"` regenerates the catalog,
ICNS, development-launch PNG, web icon and provenance. The original ICO files,
resource license, upstream revision/source paths and output SHA-256 values are
included in `Contents/Resources/Branding`. NOTICE retains the TortoiseGit and
TortoiseSVN attribution and GPL alternative. The shared command/status icons and
Finder overlays retain their separate original provenance. This project remains
an independent fork with no upstream endorsement.

Xcode Debug and AppStore configurations share the compiled catalog and document
icon. SwiftPM development launches set their application image from the same
bundled PNG; SwiftPM itself does not create an installable application bundle.
The website header/favicon use the identical original application artwork.

## Finder file-open route

The bundle declares `.patch` and `.diff` as an **alternate** editor for its
existing `org.turtlegit.unified-diff` type, with filename/MIME tags and a document
icon. This supplies an Open With candidate; TurtleGit does not set the user's
default handler. Its existing SwiftUI file-URL event now opens an independent
native Unified Diff document. A repository is not required for opening/reading
that document, and the main workspace is not switched or blocked by the document.
Repository mutations remain behind the separate Apply Patch workflow.

Each exact file path owns a document window. Reopening focuses an existing
window and preserves its edits/Undo rather than replacing it. Save As changes
which filename focuses that window; reopening its old filename creates a separate
document without replacing the renamed window. Different documents
open independently. Initial reads use the existing cancellable, size-bounded,
scoped file reader, keep the file lease for Save, set the represented URL and
retain global Quit ownership through completion. Failed initial reads can be
retried by reopening the file. Forced close cancels and refuses delayed contents.
Unsupported file types do not enter the editor; a pending Quit refuses new opens.

Save, Save As, original encoding/bytes, native Undo/Redo, Find and dirty-close
questions use the shared standalone document session. It remains isolated from
index/HEAD/working-tree changes. Opening a patch through Finder is distinct from
automatically applying it.

## Acceptance

Debug and unsigned AppStore builds and both identity audits passed. The initial
native case required the existing post-Save native input-readiness wait before
Undo; the original assertions were retained. Six grouped native cases then
passed across system/bundled Git (file-open, retained document and Dock families).
Final source review found Save As needed current-file identity lookup; the UUID
ownership correction was rebuilt in both configurations and its two affected
native engine cases passed. The four unaffected document/Dock cases were not
repeated. All nine attempted receivers were reaped and independently absent.
No Core suite was rerun. Xcode's anomalous exit-zero/no-output diagnostics are
recorded in the [dated evidence](qa/application-identity-2026-10-16.json), together
with eight inspected native Dock renders and the original-resolution limit.
Physical Finder/Open With/proxy-icon
interoperability, Launch Services cache refresh across installs, all default-app
combinations, true signed sandbox file grants, App Store submission and complete
application parity remain open. Unsigned AppStore packaging is not signed runtime
or App Store approval. The original ICO's maximum resolution remains a visual
polish limit.
