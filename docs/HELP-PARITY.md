# Contextual Mac Help

Dialog Help buttons now use TurtleGit's Mac guides in a bundled Apple Help book.
The application Help menu, Command-?, F1/Help key, First Start documentation link,
Settings footer and Compare/Merge Help actions share the same service. The book
is generated from the Mac Markdown guides and bundled screenshots, with stable
topic anchors and no remote fonts or scripts. Dated checkpoints below retain
their original catalogue and validation scope.

The installed bundle registers its help book and requests a topic anchor through
NSHelpManager. The book's bundle identifier is separate from its displayed title.
Registration failure opens the same local HTML chapter in the default browser;
a missing book falls back to the online Mac manual. The Xcode build verifies the
copied resources and generates a local search/anchor index with hiutil before
signing. SwiftPM copies the HTML book and retains the offline browser fallback.

## CoreSpotlight search index — October 30, 2026

The build now generates `TurtleGitHelp.cshelpindex` with
`hiutil -I corespotlight` and declares it with `HPDBookCSIndexPath`. Apple's
installed `hiutil(1)` manual requires Spotlight-format Help indices on macOS
Mojave and later; TurtleGit supports macOS 13 and later. The installed Apple
`/Library/Documentation/Help/Offline.help` uses the same metadata key and a
`.cshelpindex` resource. The earlier LSM format and `HPDBookIndexPath` are not
used for new TurtleGit bundles.

Generation verifies every declared source resource hash, then creates a fresh
index in private sibling staging outside the indexed HTML directory. One
300-second deadline covers generation and read-only Apple index inspections;
there is no automatic retry. The `-D` anchor dictionary must resolve every
catalogue topic and the Help home anchor to its expected local chapter. The
`-F` file inventory must match all bundled HTML chapters. Only a successful,
nonempty, readable index is published with an atomic replacement. Failed
generation or inspection preserves the previous index. A successful migration
removes only the obsolete build-owned `TurtleGitHelp.helpindex` filename before
publishing the new index; unrelated extra files remain an explicit failure.
Start, success and failure messages report the deadline or elapsed time.

CoreSpotlight preserves the exact topic key, including mixed-case IDs. Its
anchor dictionary can associate several aliases with a chapter's canonical
first-anchor URL. Validation therefore checks the exact requested key and
intended chapter, verifies that the requested named anchor exists in that
hash-validated HTML, and verifies that the reported canonical fragment is also
a real named anchor of the same chapter. It does not case-fold IDs, accept a
different chapter, or require every alias to replace the canonical URL fragment.

Current distribution audits inspect the actual packaged CoreSpotlight index,
metadata, chapter inventory and topic anchors. The Help family keeps its default
resource source as the built app; an explicit `--app` path permits a private
resource/controller check without implying a rebuilt or installed application.
The generated book version includes the generator's source hash, so changes to
index metadata also retire the previous Help book cache version. Historical
build receipts are retained unchanged.

These source and index checks do not by themselves establish physical Help
Viewer search, display, registration or accessibility acceptance. The dated
validation record must distinguish private resource/controller checks from a
rebuilt signed deployment.

A weak window binding records each repository/editor/settings context. Settings
updates its binding when the selected page changes. Reformatting repository
window titles retains their semantic context. Owned sheets inherit their parent
unless they have a more specific topic. Close removes the binding. F1/Help-key
handling leaves modified function keys alone, and starts at application launch.
Related dialogs and settings categories can share chapters. The current topic
inference for repository/progress titles uses English semantic labels; complete
localized/context-specific routing remains open.

## Source comparison

The pinned TortoiseGit baseline is
`7338078f8ddd924b8cddee35f512f2286072136d`. The IDHELP buttons in its dialog
resources and their ShowHelp/HTML topic routing are represented by native buttons
and typed Mac topic calls. Existing upstream artwork on Help command labels is
preserved. Documentation describes Mac staging, permission, tool and replay
workflows rather than presenting Windows setup instructions as Mac behavior.
The [user guide](HELP.md) explains the available routes and fallback behavior.

This checkpoint records partial IDHELP mappings in `IDD_OPENDLG`,
`IDD_REPOSITORY_BROWSER`, `IDD_PULLFETCH`, `IDD_PUSH`, `IDD_GITSWITCH`,
`IDD_NEW_BRANCH_TAG`, `IDD_APPLY_PATCH_LIST`, `IDD_REBASE`, `IDD_SUBMODULE_ADD`,
`IDD_SENDMAIL` and `IDD_BROWSE_REFS`. These are help-control mappings, not complete
dialog reviews. Source dialogs without an implemented Help control, full keyboard
and accessibility discovery, native Help Viewer registration/search/display,
localization and signed distribution remain open.

## Grouped checkpoint

The final Debug build passed. A native fixture verifies all 46 bundled topic
URLs/named anchors, one-time registration dispatch, local and online fallback,
actual Commit/Pull contexts, dynamic title context, F1/modifier refusal, sheet
inheritance/override, closed-owner removal, the actual selected-page Settings Help
button and a nonempty built search/anchor index. Viewer/browser registration and
opening are injected; this does not establish actual Help Viewer acceptance.
Both owned receivers were reaped and checked absent.

The first native pass preceded a focused F1 concurrency cleanup. The subsequent
build showed a second unused observer result warning, which was also corrected;
the final build and affected native fixture passed. The final log has no new
TurtleGitHelp warning. Core was unchanged and was not rerun. Generated-help and
website checks passed. Exact logs, repairs and scope are in
[the checkpoint](qa/help-book-2026-10-15.json). No dialog is newly certified.


## Bound-window close registration — October 17, 2026

The [byte-editor checkpoint](qa/unified-byte-buffer-2026-10-17.json) exposed a
private AppKit cursor-window close entering the broad Help observer after a
fixture Undo-group consistency exception. Close notifications now register per
bound app window and update a locked closed marker without an actor assertion.
Context lookup/registration retires closed bindings, preserving immediate closed
context behavior. F1 routing remains synchronous and unchanged. Existing bundled
Help, real controller/Settings context, sheet inheritance and close checks pass;
all physical/SDK callback combinations remain unverified.
