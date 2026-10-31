# Report a problem

Choose **Help → Report a Problem**. You can prepare a report without opening a
repository. The window includes application and bundled-component versions,
your description, and an optional Apple crash report.

## Describe and review the problem

1. Enter what happened and the steps needed to reproduce it. Include the command
   or dialog involved, the result you expected, and the result you observed.
2. If you have an Apple crash report, choose **Choose Crash Report…**. Select a
   `.ips` or `.crash` file; reports larger than 4 MiB cannot be imported.
3. Select **Include the selected crash report** when you want its contents in
   the report. Importing or replacing a crash report leaves this option off.
4. Review the exact text in the preview. **Replace my home folder path with
   <HOME>** replaces that path in the description and included report. Other
   private information can remain, so check the text before sharing it.

**Cancel reading** stops an in-progress import. The current description, report
and inclusion choice remain intact. The window waits for the read to finish
before accepting another import; cancelling does not delete the Apple report.
The status area shows progress and errors without moving the editor or preview.

## Copy, save or open the issue form

**Copy Report** copies the preview text. **Save Report…** opens a native Save
sheet and writes the reviewed text to the file you choose. Cancel the sheet to
leave the destination unchanged. Once a save is accepted, let the atomic write
finish before closing the window.

**Open Issue Form** opens the project's blank GitHub issue form. It does not put
your description, crash report or device information into the web address, and
does not submit an issue. Paste or attach the report there when you are ready.
Copy and Save keep the report local.

## Review a report after a crash

When a recent report for TurtleGit is available, a launch notice offers
**Review Report…** or **Dismiss**. Review opens the same report window with the
crash report excluded until you select Include. If the report window is busy,
finish or cancel that operation and try Review again.

Dismiss closes the notice and leaves the Apple report on disk. TurtleGit
remembers a bounded content hash to avoid repeatedly offering a report you have
already reviewed or dismissed. You can turn **Check for crash reports at
launch** off or on in the report window. If macOS does not allow discovery of the
DiagnosticReports folder, use the file chooser to select a report explicitly.

The window's **Help** button and F1 open this guide. See [Privacy](PRIVACY.md)
for how local report discovery and sharing work.
