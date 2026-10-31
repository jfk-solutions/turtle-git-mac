# App Store submission dossier — draft, 26 October 2026

This is a reviewable preparation artifact, **not an approved listing, signed export,
license clearance or submission**. No App Store Connect fields were changed. The
accompanying [English listing payload](app-store/listing-en-US-draft.json) contains
copy that can be reviewed independently of the current signed development build.
Nothing in this dossier certifies complete TortoiseGit parity.
The next delivery is a local test build: the owner wants to test the finished app
before any later App Store distribution. No submission is authorized.

## Proposed listing

| Field | Draft | Decision |
| --- | --- | --- |
| Name | TurtleGit for Mac | Owner approval; 17 characters |
| Subtitle | Git history, commits and diffs | Owner approval; 30 characters |
| macOS port author | Jochen Kühner | Confirmed port credit; upstream rights remain distinct |
| Intended seller/publisher | Jochen Kühner | Confirmed by owner on 26 October 2026; actual enrollment/Connect record not inspected |
| Primary category | Developer Tools | Proposed; matches the implemented development workflow |
| Secondary category | Utilities | Optional proposal; owner may omit |
| Primary language | English (U.S.) | Proposal; compiled UI translations do not establish reviewed store localizations |
| Keywords | `repository,version control,branches,merge,blame,patch,clone,staging,ssh,submodules` | 82 ASCII bytes; owner approval |
| Description | Exact plain-text copy in the JSON payload | Owner approval; no price, release date or full-parity claim |
| Marketing URL | https://jfk-solutions.github.io/turtle-git-mac/ | TurtleGit homepage with native screenshots and the illustrated manual; final listing approval pending |
| Public support email | jochen.kuehner@gmx.de | Confirmed by owner on 25 October 2026; recorded in this draft |
| Support URL candidate | https://jfk-solutions.github.io/turtle-git-mac/ | Reachable, links to GitHub issues; Confirmed support email deployed and verified on 25 October 2026; final listing approval pending |
| Privacy Policy URL candidate | https://jfk-solutions.github.io/turtle-git-mac/manual/PRIVACY.html | Reachable policy; owner must approve for the exact release and identify the responsible publisher/contact |
| Proposed business model and price | Paid app; provisional €7.99 | Owner preference on 26 October 2026 (“I think 7,99”); EUR is the working storefront assumption. No price point configured |
| Copyright and SKU | Not supplied | Retained upstream/distribution rights and actual Connect app record remain separate from the confirmed seller name |
| Territories and later release method | Not supplied | Decide after local testing; no submission or public sale performed |
| Next delivery | Local test build | Owner tests the finished app before later App Store distribution |
| Version/build | Read from final exported archive | Do not copy a historical development build or assume its number is unused in Connect |

Apple currently limits app names/subtitles to 30 characters, description to 4,000
characters and keywords to 100 bytes. The ASCII keyword string also fits Apple's
100-character search guidance and avoids names of other apps. Categories are
proposals, not assigned account values. Sources: [app information](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information),
[version metadata](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information),
[search guidance](https://developer.apple.com/app-store/search/),
[category definitions](https://developer.apple.com/app-store/categories/).

### Deployed URL verification

Direct HTTPS GETs on 25 October 2026 returned HTTP 200 and the expected page titles
for the homepage, `manual/PRIVACY.html`, `manual/GETTING-STARTED.html` and
`manual/CRASH-REPORTING-PARITY.html`. These routes agree with
`scripts/site_docs.py`'s `manual/<document>.html` output and the site's existing
Support/Source links. No new page was published by this audit.

The owner confirmed **jochen.kuehner@gmx.de** as the public support email on
25 October 2026. The homepage's issue tracker is a useful technical support route;
the confirmed email was deployed and verified by direct HTTPS GET on
25 October 2026 (Pages run `40214801400`, commit `ca7c08d1f94d`). Apple describes
actual contact information for Support URL and requires a privacy URL; a reachable
page alone does not settle those fields. See [version metadata](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information)
and [App Privacy](https://developer.apple.com/help/app-store-connect/reference/app-information/app-privacy/).
On 26 October 2026 the owner separately confirmed **Jochen Kühner** as the intended
seller/publisher and a provisional paid price of **€7.99**. Those are preparation
preferences, not an inspected Apple enrollment record or configured store price.
The next delivery remains a local test build, with App Store distribution deferred
until after the owner has tested the finished app.

## Local testing before distribution

The owner wants to test the finished local app before App Store distribution.
The proposed seller and price are saved preferences for that later step, not
instructions to create an account, upload a build or configure a sale now.

Apple does not require paid program membership for development and personal
testing with Xcode. App Store distribution requires Apple Developer Program
membership, currently US$99 per membership year with regional pricing shown
at enrollment. Individual enrollment uses the person's legal name as the seller.
Sources checked on 26 October 2026: [program overview](https://developer.apple.com/help/account/membership/programs-overview),
[enrollment](https://developer.apple.com/programs/enroll/).
The test app's signing, entitlements and Finder integration still need their own
measured acceptance; an account answer is not evidence that a particular build
has passed those checks.

## Draft reviewer instructions

These instructions describe implemented workflows. The final Notes for Review
must add the actual build, attachment names/checksums, owner contact and any
restricted-feature credentials through Apple's private review channel.

1. **Open and authorize a repository.** Launch TurtleGit. Use the normal folder
   chooser to open the supplied disposable sample repository. Folder authorization
   is user controlled; passing a Finder or command-line path does not bypass it.
   Do not use a personal repository for mutation checks. Local history, comparison
   and Commit do not require a TurtleGit cloud account or Homebrew/Xcode Git.
   The AppStore configuration bundles its Git runtime and refuses external fallback.
2. **Finder first use.** Enable the signed TurtleGit Finder extension in macOS
   System Settings if disabled; the location/labels vary with macOS. Select a
   folder in Finder and open the TurtleGit submenu. Clone accepts a remote or local
   source and requests destination access. Add to TurtleGit registers a selected
   existing repository after access/root validation. Successful Clone registers
   its new repository using the accepted destination grant; a second registration
   chooser is not the expected route. Registration does not enable background
   refresh after Quit automatically. Add runs without opening the workspace;
   **Services → Open in TurtleGit** provides an explicit workspace entry point
   when Finder does not display the submenu. See the deployed
   [getting-started guide](https://jfk-solutions.github.io/turtle-git-mac/manual/GETTING-STARTED.html#start-from-finder).
3. **Local review and mutation.** Open Log and inspect the graph, commit message
   and changed paths. Compare a changed file. In a disposable repository, edit a
   sample text file, open Commit, select/check or stage the intended paths, enter a
   message and commit. Checked membership and row highlighting are independent.
   Ordinary Git hooks/filters execute within the sandbox's available permissions;
   the product does not promise unrestricted external executables.
4. **Optional background badges.** First register the sample repository. Enable
   Settings → Icon Overlays → Watched Repositories → Refresh after TurtleGit quits,
   and approve any macOS background
   registration prompt. Quit the main app normally, modify/restore one sample
   file and inspect Finder status. Restore the initial background setting and
   remove only the sample watch/grant afterward. No blanket disk access is required.
5. **Standalone patch documents / CLI.** File-open a supplied `.patch` file in
   the editable Unified Diff viewer; inspect Find, appearance and Save to a chosen
   new location. The combined app's explicit CLI entry is
   `--unified-diff --stdin --title 'Review changes'` for a pipe, or
   `--unified-diff --patchfile <file>` for a file. EOF, including empty EOF, is accepted. Plain
   `--unified-diff` opens an empty document; it does not auto-read stdin. CLI path
   requests remain subject to owned file/folder authorization. See
   [command-line usage](https://jfk-solutions.github.io/turtle-git-mac/manual/COMMAND-LINE.html#standalone-unified-diff).
6. **Patch export and email.** Format Patch exports selected revisions. The
   Fetch→Rebase completion Send Mail action exports the accepted upstream..branch
   range to the repository and then opens mail options; choosing that action does
   not itself transmit mail. Settings → Email configures direct SMTP (server,
   port, encryption/authentication) or installed Apple Mail where available. Do not
   send to real recipients for review. **Owner pending:** provide a controlled
   SMTP account/recipient or a private demonstration. Passwords must not be put in
   this public dossier. Apple Mail may request Automation consent and needs a
   configured Mail account; closing options is not evidence of delivery.
7. **Optional Office integration.** Word/Excel/PowerPoint comparison/export
   requires the relevant independently installed Microsoft application and macOS
   Automation approval. The built-in text tools work without Office. Denial is
   reported with a System Settings recovery hint. **Owner pending:** reviewer
   demonstration/material for optional Office features, and an explanation of the
   declared Apple-event exceptions. Do not claim that Office is bundled.
8. **Privacy and cleanup.** Offline Help includes Privacy. Optional Gravatar,
   HTTP issue providers, network remotes and email have separate explicit choices.
   After review, discard only the sample fixtures, remove their saved grants/watch
   entries and restore background preferences. Do not clear unrelated histories,
   repositories, Keychain entries or Finder windows.

**Offline review attachment prepared:**
[Download the synthetic review sample](https://github.com/jfk-solutions/turtle-git-mac/raw/refs/heads/main/docs/app-store/turtlegit-review-demo-v1.zip).
It contains Harbor's eleven-commit branched history, staged/unstaged/renamed/added/
untracked examples, a separate genuine merge conflict, an offline history bundle,
a patch document, GPL license, exact initial-state inventory and reset/cleanup
instructions. All identities are synthetic and there is no network remote or
credential. The ZIP is 96,445 bytes; SHA-256:
`8b4a36a69a9e6851e1a54aaf1991440d02dee7d8a4d26d23a86a19ab87816e5f`.
[The manifest](app-store/turtlegit-review-demo-v1.manifest.json) records every file
and the expected repository state. Rebuild it with
`python3 scripts/build-review-demo.py` using the pinned bundled Git.

A reviewer can inspect local core workflows without an external account. Final
owner approval and attachment to the actual Connect submission remain separate;
this sample does not supply optional SMTP/Office credentials or certify native
review of every scenario. The [attachment checkpoint](qa/review-demo-2026-10-25.json)
records file/metadata checks and actual offline clone, patch application and
conflict resolution with system and bundled Git; it is not app/sandbox acceptance.

Apple asks for working support links and sufficient specific review instructions,
including access to restricted features. These notes require final owner review
rather than a generic “all features tested” statement. [App Review preparation](https://developer.apple.com/app-store/review/).

## Privacy questionnaire evidence worksheet

These are evidence inputs, **not submitted answers**. Use the exact release and
Apple's current definitions, including integrated third parties, before selecting
“Data Not Collected” or any data category. [Manage App Privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/).

| Area | Current repository evidence | Owner confirmation needed |
| --- | --- | --- |
| Developer analytics/advertising | `docs/PRIVACY.md`: no TurtleGit analytics, advertising SDK or upload service | Confirm unchanged in final binary and seller services |
| Local repository data | User-selected files, Git metadata, bookmarks, histories, action logs, cache and optional crash-report review; private local storage/clear controls | Final retention/deletion wording and publisher contact |
| Remotes, hooks, filters, credential helpers | Requested Git/SSH operations can contact configured third parties; sandbox permissions still apply | Classify applicable disclosures for actual distributed integrations |
| Optional Gravatar | Disabled by default; author-email digest and normal network information go to configured provider when enabled | Provider terms/disclosure and Apple's collection/linkage classification |
| Optional HTTP issue provider | User-enabled endpoint receives captured paths/draft/issue/revision information; credentials stored separately in Keychain | Classification and third-party retention, including cancellation after server processing |
| Email | User-approved message, recipients and selected attachments go to chosen SMTP/Mail workflow | Applicable content/contact-data disclosures and controlled review account |
| Diagnostic reports | Local explicit review/copy/save; no automatic report upload claimed | Confirm any support sharing service used for release |
| Updates | AppStore update route is isolated from non-store GitHub feed/download checks | Confirm final channel behavior |

`docs/PRIVACY.md` and the bundled Help topic exist. No `PrivacyInfo.xcprivacy`
resource is currently declared. Do not convert that observation into an unsupported
macOS-only required-reason API blocker; review applicable SDK/manifest requirements
for the final components and distribution channel separately.

## Encryption/export worksheet — owner decision required

Encryption is present: packaged OpenSSH/OpenSSL, HTTPS Git/libgit2, SMTP TLS,
Keychain/Apple Security and optional network integrations. It would be inaccurate
to select “no encryption” solely because the Swift UI delegates cryptography.
`NOTICE`, runtime pin files and the candidate's runtime inventory identify the
actual components. The app Info.plist does not currently set
`ITSAppUsesNonExemptEncryption` or an export compliance code.

**Not decided here:** exemption/classification, any documentation/reporting,
France/other territories, final plist declaration and Connect responses. No
jurisdictional or legal conclusion is made. The owner must determine these for
the complete binary and intended territories, then record the basis. Apple's
[export-compliance overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)
and [encryption declaration guidance](https://developer.apple.com/documentation/Security/complying-with-encryption-export-regulations)
describe the determination and submission flow.

## Age-rating worksheet — do not preassign a rating

The shipped feature set is a developer utility, with no built-in gambling,
advertising, medical advice or supplied mature-media catalog identified by this
bounded review. Users can open arbitrary repositories and documents, invoke
external links and send email/issue-provider information. Review those capabilities
against the current questionnaire rather than treating user-provided content as
proof that every content/capability answer is “None.” No dedicated parental-control
or age-assurance flow is claimed.

**Owner pending:** answer each current capability/content/frequency question,
determine whether any override is appropriate, and record Apple's generated
regional ratings. Do not publish a guessed “4+” or “all ages.” Apple generates
ratings from the questionnaire. [Set an app age rating](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating).

## Screenshot plan — source material, not upload-ready assets

Plan five final English screenshots: (1) history/graph, (2) Commit/staging and
patch, (3) Finder entry points, (4) working-tree changes, (5) comparison/merge.
Use a sanitized redistributable example project, current signed release, normal
readable settings and a deliberate fully composed desktop capture. Preserve
actual product behavior; do not synthesize controls or imply all upstream
features are complete. Current UI translations and diagnostic colors are not
automatically suitable store marketing material.

| Proposed subject | Existing candidate/reference | Measured format/dimensions | Disposition |
| --- | --- | --- | --- |
| Finder Clone/Add | `qa/context-registration-2026-10-25/finder-first-use.png` | JPEG despite `.png` suffix; 3456×2168 | Viewed: real Finder/menu, German locale and personal sidebar/QA names; recapture sanitized/current |
| Log/context icons | `qa/context-registration-2026-10-25/log-context-icons.png` | JPEG despite suffix; 2240×1624 | Viewed: real Log/menu, mixed localization and small sample; recapture richer clean history |
| History | `qa/signed-consolidation-2026-10-25/log.png` | JPEG despite suffix; 2240×1624 | Historical signed reference, not current release acceptance |
| Commit | `site/assets/workspace-report-commit-light-2026-10-25.png` | JPEG despite suffix; 2000×1584 | Composition reference; predates later Commit changes |
| Current Commit and staging, light/dark | [October 31 manual captures](qa/manual-commit-captures-2026-10-31.json) | Four real compositor PNGs, 2320×1744, RGBA | All viewed; current Debug UI with synthetic Harbor data for website/manual. Not a signed release or approved store format; recapture for the final store target |
| Working Tree | `site/assets/workspace-report-status-light-2026-10-25.png` | JPEG despite suffix; 2200×1324 | Composition reference; refresh behavior has later evidence |
| Embedded patch appearance | `qa/editor-appearance-2026-10-25/commit-populated-dark.png` | PNG, 2360×1700, RGBA | Viewed: diagnostic/custom high-contrast rendering and incomplete native control composition; **exclude from store assets** |

Dimensions/formats were read without modifying images. None of these measurements
is an approved current 16:10 store screenshot. Apple currently accepts Mac
screenshots at 1280×800, 1440×900, 2560×1600 or 2880×1800, without alpha; one to ten
screenshots may be provided. Proposed final target: **2560×1600**, consistently
captured for the selected localization. Final PNG/JPEG files, visual review,
opaque encoding, dimensions, checksums and matching build provenance remain
pending. The October 31 manual refresh adds actual current Debug captures; no
image was edited into a store asset or submitted.
[Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications),
[upload requirements](https://developer.apple.com/help/app-store-connect/manage-app-information/upload-app-previews-and-screenshots/).

## Release decision record still to complete

| Deliverable | State / owner |
| --- | --- |
| Listing copy/category/localizations and support contact | Draft above; account owner approves |
| Seller identity, rights, license/distribution terms | Jochen Kühner is the intended seller; the [dated terms worksheet](DISTRIBUTION.md#terms-review-worksheet--october-31-2026) identifies the unresolved agreement/source/permissions decisions. No permission or clearance is inferred from this draft |
| Privacy/export/age questionnaire | Evidence worksheet; owner answers and documents decisions |
| Price/territories/tax/banking/agreements | Account-owner decisions; not queried or changed |
| App identifier/SKU/version/build admission | Confirm in the actual Connect record; do not infer from local build values |
| Distribution certificate/profile and App Group entitlement | Final channel/account verification; Apple Development signatures are not a submitted distribution export |
| Exact final archive/package/source+notice set | Match measured inputs, actual signed binary, symbols and corresponding source/reconstruction inputs; prior receipts remain historical |
| Final screenshots and sample review attachment | Offline synthetic attachment prepared with checksums/reset instructions; final screenshots and owner/submission approval remain pending |
| Hosted CI | [macOS run41219331855](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/41219331855) at `961daf9d` is pending as observed October 31, 2026, behind active older workflow lanes. Older `5432abbb` reported picker-focus and Daemon owner-completion assertions; repairs and a complete current-source hosted pass remain required. [Pages run41219331856](https://github.com/jfk-solutions/turtle-git-mac/actions/runs/41219331856) succeeded for `961daf9d`; website deployment does not prove native workflow coverage |
| Upload/validation/App Review/release | Not performed; only after owner approval and remaining gates |

Existing [distribution engineering](DISTRIBUTION.md), [privacy](PRIVACY.md),
[NOTICE](../NOTICE) and [release blockers](RELEASE-BLOCKERS.md) remain authoritative
for their actual dated evidence. This dossier adds a concrete submission draft;
it does not replace those records or certify release readiness.
