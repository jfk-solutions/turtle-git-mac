# Presentation comment revision family — October 24, 2026

This continuation implements comment decisions in the existing native two-way
presentation review. It does not call a hidden Mac PowerPoint Merge operation.
The pinned `contrib/diff-scripts/diff-ppt.js` delegates its review to Windows
PowerPoint's opaque Merge engine. Microsoft's [review workflow](https://support.microsoft.com/en-us/powerpoint/track-changes-in-your-presentation)
includes comments, navigation and deletion alongside change decisions. The same
page says Compare/Merge is unavailable on Mac and retired from Microsoft 365
Windows version 2502. The historical pinned workflow remains the port target.

## Implemented package contract

The Core review inventories classic PresentationML comments/authors and verified
MS-PPTX 2018 modern GUID authors, comments and replies. Each record exposes its
source slide, author, initials, literal text, creation time, status, anchor and
thread/parent identity. Replies are independently reviewable. Classic p15
threading preserves presentation-wide parent author/index references, including
cross-slide threads. Author matching uses complete metadata rather than display
name alone. Modern task assignment IDs are captured and remapped with the chosen
author registry; dates, completion and titles remain in the selected XML.

Comments have separate accept/reject decisions from shapes and slide
properties. Explicit deletion, including unchanged comments, uses the same
Undo/Redo history and saved decision receipt as the existing editor. Deleting a
parent excludes its replies; an independently selected orphan reply is refused.
Deletion resolves a changed comment without requiring another accept/reject
choice. Restoring or undoing deletion restores any unresolved state.

Mixed export starts from comment-free structural packages and installs only the
chosen comment graph. Author/comment identities and classic indexes are
allocated consistently. Modern slide and drawing monikers follow the selected
output identities. A retained text-range comment requires the selected shape to
retain its text, rather than guessing a new character range. A rejected/missing
slide or anchor produces an explicit error requiring coherent decisions.

Complete-source choices retain the existing opaque-preservation and security
rewrite route. Macro parts are not executed; signature removal remains disclosed.
Archive, XML, shape, dependency, cancellation and output-publication protections
remain in force. Comment inventory is bounded to 50,000 records and thread depth
64; classic numeric identity aliases are checked for collisions.

## Verified primary format references

- [Classic PresentationML comments](https://learn.microsoft.com/en-us/office/open-xml/presentation/working-with-comments): author ID, document-wide author/index identity, position and literal text.
- [MS-PPTX CT_Comment](https://learn.microsoft.com/en-us/openspecs/office_standards/ms-pptx/161bc2c9-98fc-46b7-852b-ba7ee77e2e54): modern anchor forms, reply list, status and task properties.
- [MS-PPTX CT_CommentReply](https://learn.microsoft.com/en-us/openspecs/office_standards/ms-pptx/bcc2b4ae-7571-4ecc-8e94-982f69f793db): reply properties and structure.
- [MS-PPTX CT_CommentThreading](https://learn.microsoft.com/en-nz/openspecs/office_standards/ms-pptx/0bb9f3a2-637d-4068-913f-e5db40743a30) and [CT_ParentCommentIdentifier](https://learn.microsoft.com/en-us/openspecs/office_standards/ms-pptx/db7e8969-80af-4891-bc49-4d2111bfd82c): classic p15 reply links and time-zone bias.
- [MS-PPTX slide moniker](https://learn.microsoft.com/en-us/openspecs/office_standards/ms-pptx/856b398e-1b99-46c7-aba1-d26043ba7968): output slide identity.
- Microsoft Open XML SDK [modern author part](https://github.com/dotnet/Open-XML-SDK/blob/main/generated/DocumentFormat.OpenXml/DocumentFormat.OpenXml.Generator/DocumentFormat.OpenXml.Generator.OpenXmlGenerator/Part_PowerPointAuthorsPart.g.cs), [comment part](https://github.com/dotnet/Open-XML-SDK/blob/main/generated/DocumentFormat.OpenXml/DocumentFormat.OpenXml.Generator/DocumentFormat.OpenXml.Generator.OpenXmlGenerator/Part_PowerPointCommentPart.g.cs) and [drawing command schema](https://github.com/dotnet/Open-XML-SDK/blob/main/data/schemas/schemas_microsoft_com_office_drawing_2013_main_command.json) establish package relationship/content types and drawing moniker identity fields. Format facts are independently implemented; SDK source is not copied into the application.

## Explicit limits and validation

Unknown comment/person registries, modern extensions outside the verified 2018
schema, comment parts with relationship dependencies, and unknown author/comment
extensions remain complete-source-only. They are not silently flattened or
claimed as merged. Modern social tags/likes and embedded extension mentions are
not yet independently remapped. Optional creation anchors require a corresponding
selected identity. Complete animation/comment/unknown extension combinations and
live Office reopening remain open. Native package editing does not replace the
existing Office requirement for faithful visual rendering or legacy `.ppt`
conversion.

Nine focused Core methods were authored for modern mixed replies/authors/tasks,
unchanged and changed deletion/Undo, classic cross-slide threading, missing
anchors, opaque complete-source preservation and malformed/cancelled inventory, and valid root-level main-part relationship composition and independent same-GUID reply moves between threads.
Two retained classic-comment checks now select independent comment changes and
verify rebuilt semantic identities instead of requiring old incidental indexes.
All 28 relevant Core methods pass cumulatively after the recorded compile and
independent-oracle repairs; see the [dated family checkpoint](qa/presentation-comments-family-2026-10-24.json).
The Debug app, native review/lifecycle cases, independent ZIP/XML checks and final
light/dark captures pass across the recorded fixture and layout repairs. All four
comment receivers are independently absent. Only affected review/capture checks
were repeated for layout repairs. Generic exit-zero compiler diagnostics and an
NSTableView delegate warning are retained in the checkpoint; full hosted, physical
input and installed Office rendering acceptance remain open. No complete-port
claim is made from this implementation.
