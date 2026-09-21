# Design-first phase — plan

**Date:** 2026-09-21
**Status:** Design signed off; the macOS implementation is complete.
See "Implementation status" at the end.
**Decision:** Design and UX for both platforms are drafted and agreed on a
shared canvas *before* any Swift or C# is written. Implementation planning
(contract doc, fixtures, Windows port) resumes afterwards, using
[2026-09-21-windows-port-prerequisites.md](2026-09-21-windows-port-prerequisites.md).

## Where the design lives

Design canvas (private, owner only until shared):
https://claude.ai/artifact/5aPDVzRTxN3kS2d7E115wL

Rows on the canvas:

1. **macOS** — main window: empty, processing, finished + Inspector.
2. **Windows 11** — the same three states in Fluent terms.
3. **Target camera** — picker menu and Add Camera form on both OSes.
4. **Settings** — three tabs on macOS (General, Cameras, Converter), one
   scrolling settings page on Windows.
5. **Failed and skipped detail** — a failed and a skipped file selected on
   each OS, with the status filter active.
6. **Context menu and drag-over** — right-click menu on a row, and files
   being dragged over the window, on each OS.
7. **Dark mode** — the finished-with-pane state on each OS in the system
   dark appearance, with the custom colour map in the sticky note.
8. **App icon** — the Mac icon as shipped with a proposed small-size
   monogram, and the Windows icon at every .ico size in taskbar and
   Explorer context.
9. **In-place DNG confirmation** — the once-per-batch alert on each OS.

Sticky notes on each row record the rationale and OS mappings.

## Decisions made so far

- Mac flow stays as it is today. Refinements: labelled Process/Stop pill,
  "Save to" label on the folder popup, one-word status with the reason in
  grey, post-run status filter, Inspector Result card with the injected tags
  highlighted, explanatory empty state, converter shown in the status bar.
- Windows is a native translation, not a copy: title bar + CommandBar,
  Details pane, InfoBar for the converter warning, accent Process button,
  ListView selection indicator, ComboBox status filter, in-app Settings.
  exiftool and dnglab ship inside the Windows app; only Adobe DNG Converter
  is optional.
- **New feature: target camera.** Batch-level "Profile as" control in the
  toolbar, default Fujifilm X-T5. Curated list (X-T5, X100VI, X-T50,
  GFX100 II) with a note of what each unlocks (Reala Ace is the draw).
  "Add Camera…" takes Make + Model, links to Adobe's supported-cameras
  page for the exact spelling, previews the four tags that will be written,
  and states that the app cannot verify the name.
- **Settings.** Mac keeps the ⌘, window with three toolbar tabs. Windows
  uses an in-app page with Windows 11 settings cards and expanders.
  Contents on both: converter choice with live install status per tool,
  default target camera and the camera list (built-in ones tagged and
  non-removable), save-to default, embed original RAW, after-batch
  notification and reveal-folder toggles, About and licences (Windows).
  The Converter tab replaces today's first-launch ToolSetupSheet: nothing
  interrupts launch when a converter is present, and the in-window banner
  points to Settings when one is not.
- New settings proposed on both platforms: "Skip files that already have
  Fujifilm tags", "Show a notification when a batch finishes", "Reveal the
  output folder when a batch finishes".
- **Failed and skipped detail.** The Result card keeps one shape for every
  outcome: icon, one word, the step it happened in, then what happened
  (naming the tool), what to do, and the Output / Converter facts. Actions
  are specific to the cause, primary first. Raw tool output is collapsed
  under "Output from <tool>" with a Copy button. The list filter narrows
  to the same outcome so failures can be walked with the arrow keys.
  Retry re-queues one file; Retry All appears in the status bar when a
  filter is active.
- **Context menu.** Same items in the same order on both OSes, in each
  platform's words: Open (Windows) / Open With (Mac), Show in Finder or
  File Explorer, Show Output DNG (Done only), Open in Lightroom,
  Inspect or Details, Copy Path, Process Again and Retry (one always
  disabled so the menu keeps its shape), Remove from List. Multi-select
  keeps the verbs and pluralises where the OS does. Retry is enabled when
  any selected file failed or was skipped.
- **Drag-over.** Mac keeps the 3 px accent border, adds a faint accent
  wash and a centred "Drop to add to the queue" pill. Windows uses a
  dashed accent border inside the content layer, the same pill, and the
  system drag caption "Add to Fujify". Dropping during a batch appends to
  the queue as pending.
- **Wording rule:** the action is "Open in Lightroom", never "Open in
  Lightroom Classic". It hands the file to whichever Lightroom is installed
  and must not imply a catalog import. Explanatory copy may still name
  Lightroom Classic where the trick specifically depends on it.
- **Dark mode.** Follows the system setting on both platforms, no in-app
  toggle. Only custom colours need mapping; system colours adapt on their
  own. Mac: accent #0a84ff, status green #30d158 / yellow #ffd60a / orange
  #ff9f0a, highlighted tags #409cff, pills #3a3a3c with a light edge.
  Windows: accent #60cdff with black text on the Process button (Fluent's
  dark accent), status success #6ccb5f / caution #fce100 / critical
  #ff99a4, surfaces Mica #202020, layer #2b2b2b, cards #323232.
- **App icon.** One mark on both platforms: green #00A651, the white
  "fujify" wordmark in the system heavy weight, the three-simulation
  stripe. Only the container changes. Mac stays as shipped (squircle inset
  10%, radius 22.5%) with one proposed change: 16 and 32 px switch to an
  "f" monogram, stripe kept at 32 and dropped at 16. Windows fills 92% of
  the canvas with an 18% radius because Windows adds no shadow or mask.
  One .ico with 256, 48, 32, 24, 20, 16: wordmark at 256 and 48, monogram
  with stripe at 32 and 24, monogram alone at 20 and 16.
- **RAW files are never changed; DNGs in place are a deliberate choice.**
  RAW input always produces a new DNG. A DNG dropped in with Save to set
  to In place has its tags rewritten in the original file, so when Process
  starts with In place set and any DNGs queued, the app asks once per
  batch: Update in Place (default), Choose Folder, Cancel, with a "Don't
  ask again" checkbox that persists as a setting. RAW-only batches and
  batches with an output folder never see the dialog. All copy now reads
  "RAW files are never changed. Fujify asks before updating a DNG in
  place."
- **exiftool and dnglab ship inside the Mac app too.** Same as Windows.
  Nothing to install with Homebrew; only Adobe DNG Converter is optional
  and user-installed, because Adobe's licence forbids redistribution. A
  newer exiftool at the Homebrew path is used if present. The Settings
  Converter tab shows both as Built in, and the first-launch tool sheet is
  gone.
- **"Skip already tagged" compares against the current target camera.**
  A file tagged as X-T5 is not skipped when the target is X100VI, so
  re-tagging a batch for Reala Ace works. Process Again always bypasses
  the skip.
- **Name.** Stays "Fujify". Before the Windows build ships, contact the
  original author about the shared name. Add a "not affiliated with
  Fujifilm" line to the README and About.
- Thumbnails are placeholders.

## Still to design

Nothing. The design pass is complete; next step is sign-off, then the
implementation plan.

## Carry into implementation later

- The target camera becomes data in the pipeline contract: `(make, model,
  uniqueCameraModel)` per target. `uniqueCameraModel` is currently derived
  as `"Fujifilm " + model` from the X-T5 case; verify against a real X100VI
  DNG before shipping.
- Added cameras persist in settings on both platforms.
- The Inspector reads the *output* DNG after processing, not the source.
- Status filter and post-run summary need counts exposed by the Pipeline.
- Failures need structure, not just a message: which step (convert or
  write tags), which tool, the tool's raw stderr, and a cause category
  the UI can map to actions (read-only folder, unsupported camera, already
  tagged, disk full, tool missing). Per-file Retry and Retry All.
- "Already tagged" is a new skip reason that requires reading the
  existing tags before processing and comparing them to the current
  target's (make, model, uniqueCameraModel). Process Again sets a
  per-item force flag that bypasses it.
- In-place DNG confirmation: the Pipeline must report, before starting,
  how many queued items are DNGs that would be rewritten in place, so the
  UI can ask. New setting `confirmInPlaceDng` (default true). Cancel
  leaves the queue untouched; Choose Folder sets the output folder and
  proceeds.
- Bundling on the Mac: exiftool (Perl distribution) and the dnglab binary
  go into the app bundle's Resources; ToolLocator prefers a Homebrew
  exiftool if newer, otherwise the bundled one. Both need to be signed and
  notarized with the app. Licence texts ship in the bundle and are listed
  in About.
- Decision still open: a "Remove Fujify tags" revert action. Cheap only if
  the original camera identity is stashed in a custom tag at write time.
- Each FileItem needs to remember its output URL after processing so
  "Show Output DNG" and "Open in Lightroom" can target it.
- Adding files while a batch is running must be safe: the running batch
  holds its own snapshot today, so new items need to be picked up by a
  follow-on pass or the batch loop must read from the live queue.
- Windows drop needs the DragUIOverride caption; Mac needs the drop
  overlay to ignore drags that contain no supported files.
- Extend `tools/render-icon.swift` with a Windows profile (inset 4%,
  radius 18%, monogram below 48 px) and a monogram branch for the Mac 16
  and 32 px sizes; pack the Windows PNGs into `fujify.ico` with
  ImageMagick.


---

## Implementation status (2026-09-21)

The macOS app now matches the design. Seven stages, each its own commit,
from tag `mac-v1.0`:

| Stage | What landed |
|---|---|
| 0 | `docs/PIPELINE-CONTRACT.md`, fixtures, `tools/verify-dng.sh`, test target |
| 1 | Target cameras, bundled ExifTool + dnglab, structured failures, tag stash |
| 2 | Skip rule, in-place count, retry/reprocess, live queue, partial-output cleanup |
| 3 | Toolbar, status filter, empty state, in-place confirmation, Add Camera |
| 4 | Inspector Result card, highlighted tags, Open in Lightroom |
| 5 | Context menu, drag-over overlay, multi-select |
| 6 | Three-tab Settings, batch notifications |
| 7 | Small-size icon monogram, Windows icon profile, About box, README |

48 Swift Testing cases pass. A clean clone builds and runs with nothing
installed.

### Verified

- Every fixture converts and passes `tools/verify-dng.sh`, including the
  Nikon D1H that dnglab rejects and Adobe DNG Converter handles.
- A DNG tagged for the X-T5 is skipped for the X-T5 and re-tagged for the
  X100VI, and the XMP-fujify stash keeps the *original* camera across that
  re-tag rather than recording the Fujifilm identity written last time.
- The bundled ExifTool and dnglab do the full job from inside the app
  bundle, with no Homebrew copy present.

### Still needs a human

- **Lightroom import.** Nobody has confirmed that an X100VI-targeted DNG
  actually offers Reala Ace. This is the open `uniqueCameraModel` question
  from §2 of the contract, and only Lightroom can answer it. If the string
  is wrong, one field on `TargetCamera.x100VI` changes.
- **Visual comparison against the canvas.** Screen-recording permission was
  not available to the terminal, so the built UI has not been put
  side-by-side with the boards.
- **Intel Mac.** dnglab ships no x86_64 macOS build, so the bundled copy
  cannot run there. The code handles it by running every candidate and
  discarding what fails, but that path has not been exercised on real
  hardware.
- **Icon at small sizes.** The white "f" on a green rounded square reads a
  little like a well-known social icon at 16px, where the differentiating
  stripe is dropped. Worth a second opinion.

### Deferred by decision

Developer ID signing, notarization and a DMG; Sparkle auto-update (the
Updates section is deliberately absent from Settings); the "Remove Fujify
tags" action, though every write now stashes what it would need.
