# Windows Port — Prerequisites

**Date:** 2026-09-21
**Status:** Checklist, not started
**Scope:** Everything that must be true *before* the first line of C# is written.
The port itself (WPF app, installer, signing) is out of scope here.

## Decision recap

The Windows version will be a **separate native app** (C# / .NET 8 / WPF),
ported by hand from the Swift sources. No shared compiled core, no
cross-platform UI toolkit. Rationale: `Engine/` + `Models/` is ~600 LOC of
subprocess glue; the real shared asset is the *contract* (tags, flags, state
machine, edge cases), not code. See the conversation notes for the rejected
alternatives (Rust/Go core + FFI, Tauri/Flutter/Avalonia, Swift on Windows).

Upstream reference: [ip-web/Fujify](https://github.com/ip-web/Fujify) is a
3,300 LOC WPF app, last release v1.0.0 Beta 5 (2024-10-15), bundles
exiftool + dnglab + libraw. It proves the trick works on Windows but is not
a codebase to build on.

---

## 1. Land the in-flight Mac work

The working tree has an uncommitted feature (converter banner + "skipped"
status for RAWs in DNG-only mode + `refreshConverterAvailability()`).

- [ ] Finish and commit it. The port must start from a clean, tagged
      baseline so the contract doc below describes one exact behaviour.
- [ ] Tag the commit (e.g. `mac-v1.0`) so the Windows port can cite it.

## 2. Write the pipeline contract (the actual shared core)

Create `docs/PIPELINE-CONTRACT.md` at the repo root, extracted from the
Swift sources. Both apps must implement it verbatim. It must cover:

- [ ] **The seven exiftool write tags** and flags, copied from
      `Engine/ExifTool.swift`:
      `-CameraProfilesMake=FUJIFILM`, `-CameraProfilesModel=X-T5`,
      `-CameraProfilesUniqueCameraModel=Fujifilm X-T5`,
      `-CameraProfilesCameraRawProfile=True`,
      `-UniqueCameraModel=Fujifilm X-T5`, `-overwrite_original`, `-m`.
      Document *why* `-m` is non-negotiable ("Error copying hidden data"
      minor warning otherwise aborts the write).
- [ ] **Read commands**: `-j -Make -Model <file>` and `-j <file>` (Inspector
      dump). Both apps parse the first object of the JSON array.
- [ ] **Adobe DNG Converter invocation**: `-c -fl -p2 [-e] -d <outdir> <src>`;
      always writes `<stem>.dng` into `<outdir>`; caller renames if a
      different destination was requested; treat "exit 0 but no file" as
      failure.
- [ ] **dnglab invocation**: `convert [--embed-raw false] <src> <dst>`;
      stderr regex `Unknown camera, model '([^']+)'` → typed
      *unsupported camera* outcome (skipped, not error).
- [ ] **Supported extensions** (the 24-entry set in `Models/Pipeline.swift`).
- [ ] **Converter resolution rules**: preference `auto | adobe | dnglab |
      dng-only`; an explicit choice whose tool is missing degrades to
      dng-only, never silently to the other backend.
- [ ] **Per-file state machine**: `pending → processing → done | error(msg)
      | skipped(reason)`; cancel reverts the in-flight item to `pending`;
      dng-only mode marks non-DNG items `skipped` on add, and they flip
      back to `pending` when a converter appears.
- [ ] **Destination rules**: DNG in place when no output folder; DNG copied
      atomically when an output folder is set; RAW → `<outdir or src
      dir>/<stem>.dng`.
- [ ] **Atomicity guarantee**: destination is only replaced after the new
      file fully exists (temp sibling + replace).
- [ ] **Concurrency**: batch is serial; metadata/thumbnail population is
      bounded at 8 concurrent.
- [ ] **Cancellation semantics**: Stop terminates the running child process,
      deletes any partially written output DNG, reverts the in-flight item
      to pending, and leaves the remaining queue untouched.
- [ ] **Target camera as data**: each target is `(make, model,
      uniqueCameraModel)`; built-in list plus user-added entries.
- [ ] **Skip rule**: "already tagged" means the file's tags equal the
      *current* target's; a per-item force flag (Process Again) bypasses it.
- [ ] **In-place rule**: DNG input with no output folder is rewritten in
      place only after the once-per-batch confirmation (or the persisted
      "don't ask" setting); RAW input never modifies the source.

## 3. Build a fixture set and a contract test

The contract needs to be *checkable* on both platforms with the same script.

- [ ] Collect sample RAWs covering the converters' interesting cases:
      at least one ARW (Sony), CR3 (Canon), NEF (Nikon), RAF (Fuji), a
      pre-made DNG, and one body dnglab does *not* support (e.g. Sony A7 V)
      to exercise the skipped path. [raw.pixls.us](https://raw.pixls.us) is
      a CC0 source; keep fixtures out of git (gitignore + a fetch script).
- [ ] Write `tools/verify-dng.sh` (and later a `.ps1` twin): run
      `exiftool -j` on an output DNG and assert the five injected tag values.
      This is the golden test both apps run in CI/manually.
- [ ] Run it against the current Mac build to establish the baseline.

## 4. Verify the Windows-specific unknowns *before* designing around them

Each of these needs a Windows machine (VM is fine, see §6) and ~an hour.

- [ ] **Adobe DNG Converter CLI on Windows**: confirm the default install
      path (`C:\Program Files\Adobe\Adobe DNG Converter\Adobe DNG Converter.exe`)
      and that the same flags work and produce `<stem>.dng` in `-d`.
- [ ] **exiftool on Windows**: pick a distribution to bundle. Options are
      the official `exiftool(-k).exe` self-extracting build and the
      Oliver Betz installer build. Confirm `-j` output and the write flags
      behave identically, and that `-m` is still required.
- [ ] **dnglab on Windows**: confirm the release `.exe` runs standalone,
      the stderr unsupported-camera message is byte-identical, and whether
      an ARM64 build exists (matters if developing on an Apple Silicon VM).
- [ ] **Thumbnails**: QuickLook has no Windows equivalent. Validate the
      planned replacement — `exiftool -PreviewImage -b <raw>` (embedded JPEG
      preview) — across the fixture set. Check which formats need
      `-JpgFromRaw` or `-ThumbnailImage` as fallbacks. Decide whether to
      also switch the Mac app to this for parity (optional).
- [ ] **End-to-end Lightroom test**: process a fixture on Windows, import
      into Lightroom Classic on Windows, confirm the Fuji profiles appear.
      This is the only test that proves the port is worth doing.

## 5. Bundling and licence compliance

Decided during the design pass (see 2026-09-21-design-first.md): **both**
apps bundle exiftool and dnglab. Adobe DNG Converter stays user-installed
on both, because Adobe's licence forbids redistribution.

- [ ] Mac: add the exiftool Perl distribution and the dnglab binary to the
      app bundle, sign them with the app, and make ToolLocator prefer a
      newer Homebrew exiftool when present. Remove the Homebrew steps from
      the README.
- [ ] Windows: same two tools inside the installer and the portable zip.
- [ ] Confirm licence obligations for redistribution: exiftool (Perl
      Artistic / GPL dual), dnglab (LGPL 2.1), the app itself (GPL v3,
      inherited). Ship the licence texts in the installer and list them in
      an About screen, matching what upstream did.
- [ ] Decide the update path for bundled binaries (pin versions in a
      manifest; document how to bump).

## 6. Development environment

- [ ] Windows 11 machine or VM. On Apple Silicon this means Windows on ARM
      (Parallels / UTM); x64 exiftool and dnglab run under emulation, but
      test the *shipped* x64 build on real x64 hardware at least once.
- [ ] Lightroom Classic installed on that Windows environment (Adobe
      subscription already covers it).
- [ ] .NET 8 SDK + Visual Studio 2022 (or Rider). Confirm WPF designer
      works on the chosen setup.
- [ ] Adobe DNG Converter installed on Windows.

## 7. Repository layout

Decide before adding a second project, because it moves every Swift file.

- [ ] Recommended: monorepo.
      ```
      Fujify/
      ├── docs/PIPELINE-CONTRACT.md
      ├── fixtures/          (gitignored, fetch script committed)
      ├── tools/             (verify scripts, icon renderer)
      ├── mac/               (everything currently at root)
      └── windows/           (new .NET solution)
      ```
- [ ] Move Swift sources under `mac/`, update `project.yml` paths, re-run
      `xcodegen generate`, confirm the Mac build still works.
- [ ] Update `.gitignore` for .NET artifacts (`bin/`, `obj/`, `.vs/`).
- [ ] Update README: it currently says "Mac only" and "not distributed";
      restructure into platform sections.

## 8. Decisions to record (write them down, don't re-litigate later)

- [ ] **UI stack**: WPF on .NET 8 (recommended: mature, no MSIX friction,
      matches upstream). WinUI 3 only if the Fluent look is worth the
      packaging cost.
- [ ] **Installer**: Inno Setup (installer) + portable zip, same shape as
      upstream. Alternative: Velopack for auto-update.
- [ ] **Code signing**: Azure Trusted Signing or an OV/EV cert. Unsigned
      builds hit SmartScreen and most users will not get past it. Budget
      time and money for this; it is on the critical path for
      "distribution", not a nice-to-have.
- [ ] **Settings storage**: JSON file in `%APPDATA%\Fujify\`.
- [ ] **Minimum Windows version**: Windows 10 21H2+ or Windows 11 only.

## 9. Assets

- [ ] Produce a Windows `.ico` (16/32/48/256) from the existing icon
      artwork. `tools/render-icon.swift` is AppKit-only; export PNGs from it
      and convert to `.ico` (ImageMagick `convert` or a one-off script).
- [ ] Decide on the app name on Windows. Upstream already ships as
      "Fujify" on Windows; consider "Fujify" with a version note, or a
      distinct name to avoid confusing users of the original.

## 10. Mac distribution (parallel track, not a blocker)

Not required for the Windows port, but the goal is distribution on both:

- [ ] Apple Developer Program membership, Developer ID certificate.
- [ ] Enable hardened runtime, sign, notarize, staple.
- [ ] Decide DMG vs. zip; consider Sparkle for updates.
- [ ] Update README "Install" section.

---

## Definition of "ready to port"

All of the following are true:

1. Mac work is committed and tagged.
2. `docs/PIPELINE-CONTRACT.md` exists and `tools/verify-dng.sh` passes
   against the Mac build on the fixture set.
3. The Windows unknowns in §4 are each answered with a one-line note in the
   contract doc (paths, flag behaviour, thumbnail method).
4. The end-to-end Lightroom test on Windows has passed at least once using
   hand-run exiftool, proving the trick before any GUI exists.
5. The repo is restructured and the Mac build still compiles.
6. The §8 decisions are written into this file.
