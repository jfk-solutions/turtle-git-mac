# Git LFS locks

Git LFS locking coordinates edits to files, commonly binary assets, with the
configured LFS server. The repository and server must support the LFS operation;
installing TurtleGit alone does not create a locking service.

Open **Show locked files** to list server locks. The list shows paths, extensions
and lock owners by default. Header menus expose filenames, modification dates and
sizes and let you arrange columns. Double-click a header to fit it; Option-double-click
restores its default width. Reset columns restores the default layout. The native
list uses the original lock background artwork, controlled by the list-background
preference. F5 or Refresh fetches the list again. A failed
or cancelled query does not present unknown ownership as an unlocked file.

Select rows to use their context menu. With the owner column visible, a uniformly
locked selection offers LFS Unlock. With that column hidden, the menu offers both
LFS Lock and LFS Unlock. Folders are not lock targets. Menu actions keep the paths
and displayed order that were captured when the menu was prepared; a refreshed
list invalidates those actions.

Checking files controls the **Unlock** button. Checking a selected row applies
the same check state to the selected rows; checking an unselected row affects
that row. Space changes checks using the marked row. Select all offers the
checked, mixed and unchecked states independently of row highlighting.

**Force** applies to the checked-file Unlock operation. After a failed Unlock,
the results window also offers **Force unlock**, retrying the captured targets.
Review server ownership and permission errors before retrying.

Progress shows Command, Lock/Unlock file and Error rows, followed by completion
information. The counter advances as files finish. Right-click one file row for
Show log, Open, Open With, Explore to, LFS Lock and LFS Unlock. Double-click opens
a file or reveals a folder. Auxiliary messages and multiple selected rows offer
Copy only. Header clicks sort file groups between command/error messages.

Menu Copy copies path/message text. Command-C copies each selected row as
`Action: Path`; Command-A selects all rows. Completion always shows Success/Fail,
elapsed milliseconds and local date/time. File rows use ordinary text; errors use
the configured conflict color. Original lock/unlock background artwork follows
ShowListBackgroundImage.

Cancel stops remaining work where possible. Completed server changes remain;
cancellation does not undo a lock or unlock already accepted by the server.
If a request ends without a complete result for every selected file, the results
retain the server changes already reported and show failure. Missing results do
not mean those files succeeded. Failed Unlock still offers Force for the original
captured selection. Close the results to refresh the list once. A complete
successful Lock offers the existing Pull workflow; opening its options does not
run Pull automatically.

The same owned progress flow is used by Add, Commit, Working Tree and Finder
file commands. The initiating window stays protected until result review ends.
Saved progress action logs retain the recorded command/file/error rows for each
attempt. See [Saved Data](SAVED-DATA.md) and [the action log](ACTION-LOG.md).

Authenticated server, physical Finder and signed sandbox acceptance remain in
progress. Full dialog layout, accessibility and source behavior acceptance are
still incomplete.

[Source comparison and native captures](LFS-PARITY.md) record the tested scope.
