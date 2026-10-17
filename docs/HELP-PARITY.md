# Contextual Mac Help

Dialog Help buttons now use TurtleGit's Mac guides in a bundled Apple Help book.
The application Help menu, Command-?, F1/Help key, First Start documentation link,
Settings footer and Compare/Merge Help actions share the same service. The book
now contains 26 guides and 47 stable topic anchors. It is generated from the Mac
Markdown guides, includes no remote fonts/scripts, and occupies about 190 KB
before Apple's search index is added. The LFS interaction continuation adds the 47th topic; the original checkpoint below records its original 46-topic scope.

The installed bundle registers its help book and requests a topic anchor through
NSHelpManager. The book's bundle identifier is separate from its displayed title.
Registration failure opens the same local HTML chapter in the default browser;
a missing book falls back to the online Mac manual. The Xcode build verifies the
copied resources and generates a local search/anchor index with hiutil before
signing. SwiftPM copies the HTML book and retains the offline browser fallback.

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
