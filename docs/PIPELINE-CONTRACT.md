# Fujify pipeline contract

**Status:** normative. The macOS, Windows and web apps implement this
document. Where they differ, the difference is stated here explicitly.

This is the shared core of Fujify. The code that implements it is small
(~600 lines per platform) and not worth sharing through a compiled library
or an FFI boundary; the *contract* is what the two apps share. Anything in
here that changes must change in this file first.

Baseline: git tag `mac-v1.0`.

---

## 1. What the app does

For each input file:

1. If it is not already a DNG, convert it to DNG with the active converter.
2. Write a fixed set of camera-identity tags into the DNG so Adobe Lightroom
   offers that camera's film simulation profiles for the image.
3. Leave the source RAW untouched.

Step 2 is the whole trick. Lightroom gates camera-matching profiles on the
DNG's camera identity, so a DNG that claims to be a Fujifilm X-T5 is offered
the Fujifilm simulations regardless of which body actually took the frame.

---

## 2. Target camera

A **target** is three strings:

| Field                | Example         |
|----------------------|-----------------|
| `make`               | `FUJIFILM`      |
| `model`              | `X-T5`          |
| `uniqueCameraModel`  | `Fujifilm X-T5` |

`uniqueCameraModel` is stored explicitly, not derived. For every built-in
target it currently equals `"Fujifilm " + model`. Both built-ins are now
verified end-to-end in Lightroom: a Sony A7 V (`ILCE-7M5`) ARW converted
with the X100VI target lists **Reala Ace v2** in the profile browser
alongside Provia/Std, Astia/Soft and Velvia/Vivid (2026-09-21). Adding a
target still means guessing this string, which is why the Add Camera sheet
says the app cannot verify the name.

Built-in targets:

| Display name    | make       | model    | uniqueCameraModel | Note shown in the picker |
|-----------------|------------|----------|-------------------|--------------------------|
| Fujifilm X-T5   | `FUJIFILM` | `X-T5`   | `Fujifilm X-T5`   | Nostalgic Neg., Classic Neg., Eterna Bleach Bypass and the classics |
| Fujifilm X100VI | `FUJIFILM` | `X100VI` | `Fujifilm X100VI` | Adds Reala Ace |

Two entries, deliberately not a catalogue: the X-T5 for the classic
simulations and the X100VI for Reala Ace. Anything else the user adds
themselves, which also means the app never ships a model string nobody has
checked.

The X-T5 is the default target and the fallback whenever a selected target
disappears.

Users may add their own targets by entering `make` and `model`;
`uniqueCameraModel` is then generated as `"Fujifilm " + model` and the app
states plainly that it cannot verify the name — Lightroom is the judge. The
UI links to Adobe's supported-cameras list for the exact spelling. Built-in
targets cannot be removed.

The target is a batch-level setting, chosen in the toolbar and persisted
between launches.

---

## 3. exiftool

### 3.1 Writing the camera identity

Five tag assignments and two flags, in this order, then the file path:

```
-CameraProfilesMake=<target.make>
-CameraProfilesModel=<target.model>
-CameraProfilesUniqueCameraModel=<target.uniqueCameraModel>
-CameraProfilesCameraRawProfile=True
-UniqueCameraModel=<target.uniqueCameraModel>
-overwrite_original
-m
<dng path>
```

Both flags are required:

- `-overwrite_original` writes in place and leaves no `.dng_original`
  sibling. Without it every processed file gets a backup twin, which for a
  2,000-file wedding shoot is unacceptable.
- `-m` downgrades minor errors to warnings. **This is not optional.** Some
  DNGs produce `Error copying hidden data`, which without `-m` causes
  exiftool to refuse the write entirely and the file is left untagged. This
  was found during CLI testing on real Sony A7 V files and is the single
  most important line in this document.

Exit code 0 means success. Anything else is a failure; the full stderr is
kept for the user.

### 3.2 Stashing the original identity

The same invocation also records what the file used to be, so a future
"Remove Fujify tags" action can put it back. This uses a custom XMP
namespace defined in `tools/exiftool-fujify.config`, passed with `-config`
on every read and write:

```
-XMP-fujify:OriginalMake=<original Make>
-XMP-fujify:OriginalModel=<original Model>
-XMP-fujify:OriginalUniqueCameraModel=<original UniqueCameraModel>
-XMP-fujify:TargetModel=<target.model>
-XMP-fujify:Version=1
```

The original values come from a read performed immediately before the write
(§3.3). Both sets of tags go in **one** exiftool invocation so the file is
rewritten once, atomically.

If the file already carries `XMP-fujify:OriginalMake`, it has been processed
before: keep the existing stash rather than overwriting it with the
already-faked identity.

### 3.3 Reading

| Purpose | Arguments |
|---|---|
| Camera identity, for the skip rule and the stash | `-config <cfg> -j -Make -Model -UniqueCameraModel -CameraProfilesMake -CameraProfilesModel -CameraProfilesUniqueCameraModel -XMP-fujify:all <path>` |
| List column | `-j -Make -Model <path>` |
| Inspector dump | `-config <cfg> -j <path>` |
| Version check | `-ver` |

All `-j` output is a JSON array; the app uses the first object. A missing
tag is an absent key, which reads as an empty string, not an error.

### 3.4 Invocation

exiftool is a Perl script. On macOS it is run as
`/usr/bin/perl <script path> <args>`, using the system Perl (5.34 on Sonoma
and later). On Windows the packaged `exiftool.exe` is run directly.

---

## 4. Converters

### 4.1 Adobe DNG Converter (preferred, user-installed)

```
-c -fl -p2 [-e] -d <output directory> <source path>
```

| Flag | Meaning |
|---|---|
| `-c` | compressed DNG (the default, kept explicit) |
| `-fl` | embed fast-load data, so Lightroom opens the file faster |
| `-p2` | embed a full-size JPEG preview |
| `-e` | embed the original RAW inside the DNG; present only when the user enabled it |
| `-d` | output directory |

Adobe always writes `<source stem>.dng` into the `-d` directory and offers
no way to name the output. The caller therefore checks for that file after
a successful exit and renames it if a different destination was requested.

**Exit code 0 does not guarantee output.** If `<stem>.dng` is absent after a
zero exit, treat it as a failure with the message "Adobe DNG Converter
reported success but no DNG was produced".

Never redistributed. Adobe's licence forbids bundling it, so it is always
user-installed and always optional.

Locations:

- macOS: `/Applications/Adobe DNG Converter.app/Contents/MacOS/Adobe DNG Converter`
- Windows: `C:\Program Files\Adobe\Adobe DNG Converter\Adobe DNG Converter.exe`
  *(to verify on a real Windows install — see the port prerequisites doc)*

### 4.2 dnglab (bundled on both platforms)

```
convert [--embed-raw false] <source path> <destination path>
```

`--embed-raw false` is passed when the user has *not* enabled embedding;
dnglab embeds by default, and not embedding roughly halves the output size.
Unlike Adobe, dnglab takes an explicit destination path, so no rename is
needed.

Success requires **both** a zero exit code and the destination file
existing.

Unsupported cameras are detected by matching stderr against:

```
Unknown camera, model '([^']+)'
```

Capture group 1 is the model name. This is a *skip*, not a failure: the user
is told the camera is not supported yet and pointed at Adobe DNG Converter.
Check this pattern before checking the exit code, because dnglab may exit
non-zero for the same reason.

Version 0.8.0 is bundled. Coverage is broad but lags on newer bodies; the
Sony A7 V is the current example, and the Nikon D1H is a small fixture that
reproduces the message above.

**dnglab publishes no x86_64 build for macOS**, only arm64. The bundled copy
therefore cannot run on an Intel Mac. Rather than special-casing the
architecture, every tool candidate is verified by running it and reading back
a version string; one that cannot execute is discarded and the app falls back
to a Homebrew copy or to Adobe DNG Converter. That check also catches a
damaged or quarantined binary.

### 4.3 DNG-only mode

No converter runs. Only DNG input can be processed; other RAW files are
skipped with an explanation pointing at Lightroom Classic's
Library › Convert Photo to DNG. Only reachable by choosing it explicitly in
Settings, because dnglab now ships with the app.

### 4.4 Which converter runs

Resolved from the user's preference against what is actually present:

| Preference | Result |
|---|---|
| Automatic | Adobe if installed, else bundled dnglab |
| Adobe DNG Converter | Adobe if installed, else DNG-only |
| dnglab | bundled dnglab |
| DNG only | DNG-only |

An explicit choice never silently falls back to the *other* converter. If
the user asked for Adobe and Adobe is missing, the app degrades to DNG-only
and says so, rather than quietly using dnglab and producing different
output than expected.

---

## 5. Input

### 5.1 Accepted extensions

Case-insensitive, 24 entries:

```
dng  cr3  cr2  crw  erf  raf  3fr  kdc  dcs  dcr  iiq  mos
mef  mrw  nef  nrw  orf  rw2  pef  srw  arw  srf  sr2  ari
```

### 5.2 Adding files

Files and folders are both accepted, by drag-and-drop or a file picker.
Folders are walked recursively, skipping hidden files. Anything whose
extension is not in the list above is ignored silently. Duplicates, by
absolute path, are ignored.

Files may be added while a batch is running; they join the queue as pending
and the running batch picks them up.

### 5.3 Metadata population

On add, each file gets its camera make/model and a thumbnail, with a bounded
concurrency of **8** so that adding ten thousand files does not spawn twenty
thousand subprocesses.

Make is normalised for display only: `NIKON CORPORATION` is shown as
`NIKON`. The tag itself is never rewritten.

Thumbnails: QuickLook on macOS. Windows has no equivalent, so it extracts
the embedded preview with `exiftool -PreviewImage -b`, falling back to
`-JpgFromRaw` and `-ThumbnailImage`.

---

## 6. Output

Let `stem` be the source filename without its extension, and
`outputDir` be the user's chosen output folder, or the source file's own
folder when none is chosen ("In place").

The destination is always `outputDir/stem.dng`.

| Input | Output folder set | Behaviour |
|---|---|---|
| `.dng` | no | Tags are written **into the source file**. Requires confirmation (§7). |
| `.dng` | yes | Source is copied to the destination atomically, then the copy is tagged. Source untouched. |
| other RAW | either | Converter produces the destination DNG, which is then tagged. Source untouched. |

**RAW input never modifies the source file.** This is a guarantee the
interface makes to the user in plain words and must not be broken.

### 6.1 Atomic replacement

Any copy or rename that could overwrite an existing file writes to a hidden
sibling temp file first (`.<uuid>.<final name>`) and only then replaces the
destination. A failure part-way through can therefore never leave the user
with a missing or truncated file. On failure the temp file is removed.

---

## 7. In-place DNG confirmation

Rewriting a DNG in place is destructive in a way converting a RAW is not:
photographers keep DNGs as masters. So when a batch starts, if **all** of:

- the output folder is "In place", and
- the queue contains at least one pending `.dng`, and
- the user has not ticked "Don't ask again",

the app asks once for the whole batch:

> **Update N DNGs in place?**
> Save to is set to In place, so Fujify will rewrite the camera tags inside
> these DNG files. Your M RAW files are converted to new DNGs and never
> changed.

Three choices: **Update in Place** (default), **Choose Folder…** (sets an
output folder and proceeds, so nothing is rewritten), **Cancel** (queue
untouched). The "Don't ask again" tick persists as a setting and is
reversible in Settings.

RAW-only batches and batches with an output folder never see this.

---

## 8. Per-file state machine

```
pending ─► processing(step) ─┬─► done
                             ├─► failed(failure)
                             └─► skipped(reason)
```

`step` is `convert` or `writeTags`, so the UI can say what was happening.

| State | Meaning |
|---|---|
| `pending` | queued, not started |
| `processing(step)` | in flight |
| `done` | output DNG exists and carries the target's tags |
| `failed(failure)` | something went wrong; see below |
| `skipped(reason)` | deliberately not processed |

A `done` item also records its output path and which converter produced it.

### 8.1 Failures

A failure is structured, not a string:

| Field | Meaning |
|---|---|
| `step` | `convert` or `writeTags` |
| `tool` | which program failed |
| `cause` | see the table below |
| `toolOutput` | the tool's raw stderr, shown collapsed and copyable |

| Cause | Detected by (case-insensitive) | Actions offered |
|---|---|---|
| `readOnlyOutput` | `permission denied`, `error creating file`, `read-only file system`, `access is denied`, `operation not permitted`, `os error 13` | Retry, Choose Folder, Show in Finder |
| `diskFull` | `no space left`, `disk full`, `not enough space`, `os error 28` | Retry, Choose Folder, Show in Finder |
| `toolMissing` | `not found at`, or `no such file or directory` naming the tool | open Settings › Converter |
| `other` | anything else | Retry, Show in Finder |

**`error creating file` is not optional.** exiftool reports a permissions
problem as

```
Error: Error creating file: <path>_exiftool_tmp - <path>
```

with no mention of permissions anywhere. Matching only on `permission denied`
files it under "unknown error", and the user never gets the Choose Folder
button that would fix it. dnglab, by contrast, says
`I/O error: Permission denied (os error 13)`.

Both strings are captured verbatim in
`Tests/FailureClassificationTests.swift`.

Cause detection lives in exactly one function so both platforms and the unit
tests agree.

### 8.2 Skips

| Reason | When | Actions offered |
|---|---|---|
| `alreadyTagged(as:)` | the file already carries this target's tags (§9) | Show in Finder |
| `unsupportedCamera(model)` | dnglab does not know the body | Set up Adobe DNG Converter, Retry |
| `dngOnlyMode` | non-DNG input while DNG-only mode is on | open Settings › Converter |

### 8.3 Retry

- **Retry** returns a failed or skipped item to `pending`.
- **Process Again** returns any item to `pending` and sets a force flag that
  bypasses the already-tagged skip for that item only.

---

## 9. The already-tagged skip

Enabled by default, switchable in Settings.

Before converting, the app reads the file's camera tags. If
`CameraProfilesMake`, `CameraProfilesModel` and
`CameraProfilesUniqueCameraModel` all equal **the current target's** values,
the file is skipped as `alreadyTagged`.

The comparison is against the *current* target, not against "is it Fujifilm
at all". A file tagged as X-T5 is **not** skipped when the target is
X100VI — re-tagging a batch to pick up Reala Ace is exactly why the target
picker exists. Process Again always bypasses the skip.

---

## 10. Concurrency and cancellation

The batch is **serial**: one file at a time. Converters are already
CPU-saturating and the user's disk is the bottleneck; parallel conversion
made throughput worse in testing and made the progress bar meaningless.

Metadata and thumbnail population is parallel with a bound of 8 (§5.3).

**Stop** terminates the running child process, then:

1. deletes any partially written output DNG, unless it is the source file;
2. returns the in-flight item to `pending`;
3. leaves the rest of the queue untouched, still pending.

A half-written DNG must never be left on disk. On macOS the child gets
`SIGTERM`; on Windows it is killed through the process handle.

---

## 11. What the app tells the user

Wording that carries meaning and must not drift between platforms:

- **"Open in Lightroom"**, never "Open in Lightroom Classic". The action
  hands the file to whichever Lightroom is installed and must not suggest a
  catalog import. Explanatory prose may still name Lightroom Classic where
  the trick genuinely depends on it.
- **"RAW files are never changed. Fujify asks before updating a DNG in
  place."** The old wording, "Your originals are never changed", was false
  for DNG input.
- Status is one word — Done, Skipped, Failed — with the reason after it in
  secondary colour. The full explanation lives in the detail pane.
- Failure text names the tool, says what to do, and confirms the RAW file is
  untouched.

---

## 12. Verifying an output file

`tools/verify-dng.sh <file.dng> [target model]` asserts the four identity
tags against a target, defaulting to `X-T5`. It is the golden test for both
platforms and for any change to §3.

```sh
tools/verify-dng.sh ~/Pictures/Fujified/L5A06291.dng
tools/verify-dng.sh ~/Pictures/Fujified/L5A06291.dng X100VI
```

The real acceptance test is Lightroom: import the output and confirm the
Fujifilm simulations appear in the Profile picker, and that an X100VI target
offers Reala Ace.
