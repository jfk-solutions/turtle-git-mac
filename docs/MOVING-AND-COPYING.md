# Moving and copying files

TurtleGit uses Git-aware Move so a renamed or relocated versioned file keeps its
index contents separately from any further working-file edits. These operations
change files and the index; they do not create a commit.

## Transfer a Finder selection

Select files or folders in Finder and choose **TurtleGit → Transfer…**. Choose the
destination working tree's repository root, then use the native transfer dialog
for a subfolder if needed. The source list is captured when the menu opens;
changing Finder selection or clipboard contents does not retarget it. The
**Show Transfer and clipboard Copy/Add and Move in Finder** setting controls this Finder entry.

The destination button and **Recent destinations** use the captured working tree.
Every chosen or remembered folder is checked again before its actions become
available. History remembers up to twelve destinations per repository. Move and
single-item Move and Rename require versioned sources in that same working tree;
external or unversioned sources offer Copy and Add. These buttons open the existing
operation review window; choosing a destination alone changes no files or index.

Cancel or close the transfer dialog to abandon it. Closing its initiating window
cancels destination/preparation work. The accepted action starts only after the
chooser and any destination sheet have actually detached. External file access
is requested separately by Copy and Add when necessary.

## Drop files into TurtleGit

Drop local files or folders onto the main workspace file list or a Working Tree
window's file list. The receiving sheet shows the captured paths and destination.
Use the destination button to choose another folder in the same working tree.

For versioned sources in that working tree, choose **Move here**. A single source
also offers **Move and rename here**. External or unversioned sources offer
**Copy and add here**. Cancel the receiving sheet to leave everything untouched.

The selected action opens its operation window. Review the destination and start
Move or Copy and Add. Move/Rename asks for the new name when execution begins.
An occupied name keeps the name sheet open until a valid destination is entered.

A failed item in a dropped Move offers Ignore or Abort. Earlier successful moves
remain applied. Clipboard Paste Move stops at its first failure. Review the
operation output and current status before retrying either workflow.

## Drag files out of a file list

In Commit, Working Tree and Add, highlight the file rows to transfer and drag
them to Finder or another application. The highlighted rows determine the drag;
the checkboxes still determine the dialog's Git operation. Group headings and
checkbox clicks do not start a file transfer.

Working files are offered as their actual file URLs. Deleted or missing files,
directories and submodules do not offer file contents. The text representation
retains the selected paths, including paths without file contents. An accepted
transfer retains its repository permission even if its source window closes.
Dropping the same drag back onto its originating list does not start an incoming
Copy/Add, Move or selection operation. Other incoming drops keep their existing
review workflow.

Changing a file outside TurtleGit does not create a commit or stage the change.
Review the refreshed working-tree state afterward. Physical modifier/move,
cross-application destination naming and signed Finder delivery still require
installed acceptance; see [the source comparison](FILE-LIST-DRAG-PARITY.md).

## Copy and Add

Copy and Add accepts external source files and folders. Overwrite replaces an
existing file; Keep retains and stages the destination's existing contents;
Cancel stops the sequence. Existing directory-to-directory targets are kept.
A copied repository prompts for Delete, Ignore or Abort: Delete removes only its
copied Git metadata, Ignore excludes that copied repository from staging, and
Abort retains copied files for recovery. The original source remains untouched.

External source permissions are requested by the Copy/Add window when needed.
Cancellation may leave already copied or staged items. The output and refreshed
file list show the result; review those items before running the operation again.

## Clipboard and menus

Versioned-file menus offer Move, Copy files and Copy and Add. Copy files puts local
file URLs on the clipboard. Paste Move accepts versioned paths from the same
working tree; Paste Copy and Add copies the captured URLs into the destination.
Finder's destination-folder clipboard entries require an enabled Finder extension.

The receiving sheet is the current macOS application adaptation of TortoiseGit's
Windows drag context menu. FinderSync has no public drag-destination menu hook;
the Finder Transfer action and app-owned drop sheet are the macOS adaptations.
Signed permission delivery and physical drag acceptance are still pending.
