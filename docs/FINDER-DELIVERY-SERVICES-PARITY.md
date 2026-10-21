# First-use Finder comparison, patch and export delivery

This family connects eight explicit macOS Services to existing native TurtleGit
workflows: Mark/Compare, Clear comparison mark, Export, Create Patch Serial,
Apply Patch Serial, Review/apply single patch, Send Mail and Request Pull.
They append to the previous forty-seven declarations, retaining their original
order and contents. The installed bundle registers fifty-five entries: fifteen
folder entries and forty selected-item entries.

## Source behavior and macOS selection

Pinned TortoiseGit `7338078f8ddd924b8cddee35f512f2286072136d` supplies the
`TortoiseShell/MenuInfo.cpp` DiffLater, Export, FormatPatch, ImportPatch,
ApplyPatch and Sendmail predicates. `ContextMenu.cpp` changes DiffLater from
marking one file to comparing another with it; Control clears the mark and Shift
chooses the alternate tool. The macOS Services menu has static captions, so it
also provides an explicit Clear entry. Existing Finder Sync menus retain their
dynamic marked-path captions and icons.

Mark/Compare accepts one nonfolder without requiring a Git repository. Export
accepts one Git folder or bare repository; Format Patch requires one Git folder.
Import accepts selected patch files or one Git folder. Review accepts one patch,
or an arbitrary nonfolder through the source extended-action clause; Send Mail
accepts its ordered patch/file selection through the corresponding clause.
Invoking a Services item is an explicit action, so it does not depend on a
physical Explorer extended-menu modifier. Request Pull has no source Shell
MenuInfo entry: its Services adaptation uses Export's repository-folder scopes
and opens the existing Request Pull form. Services has no independent Explorer
background folder, so ambiguous repository selections are not silently narrowed.

The source `ImportPatchCommand.cpp` chooses a repository for a patch outside a
working tree. TurtleGit separately authorizes selected input files and chooses
the destination repository before opening Apply Patch Serial. It does not infer
that an unrelated active workspace is the requested target. Opening review,
mail, export or patch options performs no implicit application, send or export.
Each existing native workflow retains its reviewed action and Git operations.

## Captured authority, settings and files

The private Services pasteboard and strict URL envelope carry paths and tool
choice, never permission. File-first entry points do not adopt an unrelated
workspace through repository discovery.
Marked comparisons retain independent grants for both files; two-file Diff uses
the same path. A missing grant uses an asynchronous owned file/folder chooser.
The mark ID, initial mark decision, paths, settings and alternate-tool choice are
captured before authorization. A changed mark refuses the old request; failed
access/read, cancellation or rejected presentation preserves the mark.
Consumption checks the accepted ID so that a newer mark survives.

The authorized comparison read runs outside the UI thread. Its first native
load consumes the same document through the existing owned viewer/tool session,
retaining original bytes and editing permissions. Explicit Reload reads the
current files again. Closing the workspace cancels pending authorization or
preparation and suppresses late presentation while keeping actual work counted
until it drains.

Repository delivery captures its primary access, executable and preferences
through discovery and successor pickers. Cache reuse requires the same context
and a live controller. Late close callbacks remove only their own controller;
they cannot evict a newer replacement. Import, Export, Format Patch and Request
Pull retain their existing reviewed Git and output workflows and source artwork.

Mail preserves unavailable entries in its checkbox list so they can be unchecked.
It can use an authorized sender repository; outside Git it uses an exclusive
private directory to read global sender settings without borrowing a checkout.
Review can target an ordinary directory. Neither operation requires an unrelated
repository merely because a workspace is open. Preparation, target questions,
native pickers, comparison/editor children and real workers remain owned through
closure. Send, Review and working-tree patch owner releases also block Quit until
their actual children and pending decisions drain.

## Validation and limits

The grouped native entry point is `scripts/test-finder-delivery-services.py`.
It composes cold/active provider and registration checks, arbitrary-file
comparison/mark races and patch/mail delivery, actual repository windows and
held preparation/editor/picker ownership. Checks use private repositories,
preferences and pasteboards, invisible windows and identified helper cleanup.
Existing operation assertions remain in their own workflow families.
The [dated checkpoint](qa/finder-delivery-services-2026-10-21.json) records actual
executions, repairs and the precise remaining acceptance scope.

This scope does not certify physical Services activation, signed sandbox file
grants, every source dialog/control, Windows menu placement or App Store
distribution. macOS controls Services ordering and does not provide Explorer's
per-entry shell icons through this registration; native controls retain their
existing icon mappings. Complete source and release acceptance remain open.
