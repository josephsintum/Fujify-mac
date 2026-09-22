# Fujify for the web — design

**Date:** 2026-09-21
**Status:** Design agreed; not yet implemented. Implementation plan follows.
**Decision:** Build a browser-only Fujify — a static page, no server — that
accepts DNG files only and rewrites the camera identity in the user's
browser. It becomes the primary Fujify; the macOS app continues alongside it.
All three implementations (macOS, Windows, web) share
[`PIPELINE-CONTRACT.md`](../PIPELINE-CONTRACT.md).

---

## 1. Decisions from the design conversation

| Question | Decision |
|---|---|
| Who is it for | The eventual primary Fujify. Reach for parity with the Mac app wherever a browser allows. |
| Browser floor | Chromium (Chrome, Edge, Brave, Arc) is the full product. Safari and Firefox get a working degraded path: drop DNGs, download each result. No wall. |
| RAW input | DNG only. Lightroom Classic (Library › Convert Photo to DNG) does the conversion. Other RAW files are listed and skipped with that pointer. No converter, ever, in this app. |
| Stack | Svelte 5 + TypeScript + Vite. The DNG patcher itself is framework-free TypeScript with zero dependencies. |
| Repo | This repo becomes a monorepo: the Swift app moves to `mac/`, the web app lives in `web/`, `windows/` holds a coming-soon README. Shared assets stay at the root (§1.1). |
| Write strategy | Edit within the XMP packet's padding; append-and-repoint when it will not fit; never move existing bytes (see §4). |
| Hosting | GitHub Pages from this repo. No backend, no analytics, no secrets. |

### 1.1 Monorepo layout

The restructure is the first implementation task, in its own commit, before any web code.

```
Fujify/
  README.md            the family: what Fujify is, one section per platform, links
  LICENSE  .gitignore  .gitattributes
  docs/                PIPELINE-CONTRACT.md and plans/ — shared, unchanged location
  fixtures/            sample RAW/DNG files — shared, fetched, gitignored
  tools/               shared, platform-neutral:
    verify-dng.sh          the golden test for every implementation
    fetch-fixtures.sh
    exiftool-fujify.config the XMP-fujify namespace (moved from mac/Vendor so
                           Windows and the web tests read the same file)
  mac/                 everything Swift, moved as-is:
    project.yml  FujifyApp.swift  ContentView.swift  .swift-format
    Engine/  Models/  Views/  Tests/  Assets.xcassets/
    Vendor/                bundled exiftool + dnglab (gitignored) and LICENSES/
    tools/                 fetch-tools.sh, render-icon.swift — Mac-only scripts
  web/                 the Svelte app (§3)
  windows/             README.md: coming soon, linking to
                       docs/plans/2026-09-21-windows-port-prerequisites.md
```

Consequences of the move, all mechanical: `mac/project.yml` references `../tools/exiftool-fujify.config`; `mac/tools/fetch-tools.sh` resolves `Vendor/` relative to `mac/`; the contract's §3.2 path becomes `tools/exiftool-fujify.config`; the Mac build instructions in the README gain a `cd mac`. Git history is preserved with `git mv`.

### In scope for v1

- Drop DNGs or folders; list with make/model and embedded-preview thumbnail
- **Profile as** target picker: X-T5 and X100VI built in, **Add Camera…** for user targets, persisted
- **Save to**: Downloads (all browsers), Folder, In place (Chromium), with the contract §7 once-per-batch confirmation for in-place
- Already-tagged skip, Retry, Process Again, Done/Skipped/Failed filter, Retry All
- Inspector: what happened, the five injected tags highlighted, original identity, collapsed error detail with Copy
- Stash of the original identity in `XMP-fujify`, per contract §3.2
- Offline after first load (manifest + service worker) — last

### Deferred

- **Remove Fujify tags** (undo). The stash makes it possible; the Mac app does not have it yet either.
- Full metadata dump in the Inspector (needs a general TIFF/XMP reader; we only need five tags).
- Remembering the output folder between sessions (persisted File System Access handles + re-permission).
- RAW → DNG conversion in the browser (dnglab compiled to WebAssembly). Not assessed; not designed for. The seam is the contract's own step 1 → step 2 boundary, so nothing here forecloses it.

---

## 2. What the write actually is

Established by inspecting the Mac app's output on `fixtures/sample.dng` with exiftool. The whole of contract §3.1 and §3.2 reduces to two locations in the file:

1. **IFD0 tag `0xC614` UniqueCameraModel** — an ASCII TIFF tag. Set to `target.uniqueCameraModel`.
2. **IFD0 tag `0x02BC` XMP packet** — the four `CameraProfiles*` tags are XMP, not binary. exiftool flattens them into:

```xml
<photoshop:CameraProfiles>
  <rdf:Seq>
    <rdf:li rdf:parseType="Resource">
      <stCamera:CameraRawProfile>True</stCamera:CameraRawProfile>
      <stCamera:Make>FUJIFILM</stCamera:Make>
      <stCamera:Model>X-T5</stCamera:Model>
      <stCamera:UniqueCameraModel>Fujifilm X-T5</stCamera:UniqueCameraModel>
    </rdf:li>
  </rdf:Seq>
</photoshop:CameraProfiles>
```

   plus the stash elements `fujify:OriginalMake`, `OriginalModel`, `OriginalUniqueCameraModel`, `TargetModel`, `Version`.

Namespace URIs, which must match exiftool's exactly so both implementations read each other's files:

| Prefix | URI |
|---|---|
| `photoshop` | `http://ns.adobe.com/photoshop/1.0/` |
| `stCamera` | `http://ns.adobe.com/photoshop/1.0/camera-profile` |
| `fujify` | `https://josephsintum.dev/ns/fujify/1.0/` |

Adobe DNG Converter leaves whitespace padding in the XMP packet (4097 bytes on the fixture) terminated by `<?xpacket end='w'?>` — `w` meaning writable in place. Fujify's additions need roughly 600–800 bytes. So in the common case the packet can be edited without changing its byte length, and the output differs from the input by a few hundred bytes.

---

## 3. Architecture

```
web/
  src/
    dng/            framework-free TS, zero deps, runs in a Worker
      tiff.ts         header + IFD0 entry parsing, both byte orders
      xmp.ts          find and patch the XMP packet text
      identity.ts     read Make / Model / UniqueCameraModel / CameraProfiles / stash
      patch.ts        plan a Fujify write → PatchPlan
      worker.ts       message handler: read(file) / patch(file, target, opts)
    output/         "where does the DNG go", behind one interface
      sink.ts         interface OutputSink
      downloads.ts    Blob + <a download>            (all browsers)
      folder.ts       FSA directory handle, atomic temp + rename
      inplace.ts      FSA file handle, positioned writes only
    model/          Svelte 5 runes state, mirrors Models/ in the Mac app
      pipeline.svelte.ts   queue, serial batch runner, per-file state machine
      cameras.svelte.ts    built-in + user targets, localStorage
      settings.svelte.ts   save-to mode, skip toggle, don't-ask-again
    ui/             Svelte components: FileList, Inspector, TargetPicker,
                    SaveToPicker, Settings, ConfirmInPlace, AddCamera, EmptyState
  tests/            vitest: dng/* against ../../fixtures; output/* with fakes
  e2e/              Playwright: drop → download → tools/verify-dng.sh
```

Three hard boundaries:

- **`dng/` knows nothing about the DOM or file handles.** Input is an `ArrayBuffer`; output is a `PatchPlan`:

  ```ts
  interface PatchPlan {
    edits: { offset: number; bytes: Uint8Array }[];   // overwrite in place
    append?: Uint8Array;                               // bytes to add at EOF (word-aligned start)
    outputLength: number;
  }
  ```

  This is the unit the golden test exercises, and it is what makes true in-place writing possible: a sink applies edits; it does not understand them.

- **`output/` knows nothing about DNGs.** It takes a source `File`, a `PatchPlan` and a destination and produces a file. Chromium versus Safari is decided here, once, by which sinks exist.

- **`model/` mirrors the Mac app's `Pipeline`, `FileItem`, `TargetCamera`** so contract §7, §8 and §9 port almost name for name.

Parsing and planning run in a Web Worker so the list stays responsive. Metadata population on drop runs through the same worker with a concurrency bound of 8 (contract §5.3).

---

## 4. The patcher

### 4.1 Read (`identity.ts`)

1. Header: `II` or `MM`, magic `42`, IFD0 offset. Anything else → `notADng`. BigTIFF (magic `43`) is rejected; DNG does not use it.
2. Walk IFD0 only. Read `0x010F Make`, `0x0110 Model`, `0xC614 UniqueCameraModel`, `0x02BC XMP` (offset + count), `0xC612 DNGVersion`. No `DNGVersion` → TIFF but not a DNG → `notADng`.
3. Decode the XMP packet as UTF-8. Extract with targeted patterns, not a full XML parser: the first `rdf:li` under `photoshop:CameraProfiles` (`stCamera:Make`, `Model`, `UniqueCameraModel`, `CameraRawProfile`) and the `fujify:*` elements. A missing value is `''`, matching contract §3.3.

### 4.2 Plan (`patch.ts`)

**UniqueCameraModel.** Encode `target.uniqueCameraModel + '\0'`.
- If the existing value is stored out of line and `newLength ≤ oldCount`: overwrite at the data offset, NUL-pad the remainder, set the entry's count to `newLength`.
- Otherwise (including the inline ≤ 4-byte case): append the bytes at EOF and repoint the entry's count and offset.

**XMP packet.** Build the new packet text from the old:
1. Ensure `xmlns:photoshop`, `xmlns:stCamera`, `xmlns:fujify` are declared on the first `rdf:Description`; add any that are missing.
2. Remove any existing `<photoshop:CameraProfiles>…</photoshop:CameraProfiles>` block and insert the one-`rdf:li` structure above, before `</rdf:Description>`.
3. Stash rule (contract §3.2): if `fujify:OriginalMake` already exists, leave the stash untouched. Otherwise write `OriginalMake`, `OriginalModel`, `OriginalUniqueCameraModel` from the values read in §4.1 and `Version = 1`. Always set `TargetModel` to the current target's model, replacing any existing element.
4. Re-pad so the new packet is exactly `oldCount` bytes, with `<?xpacket end='w'?>` as its final bytes. Padding follows Adobe's shape: lines of 100 spaces plus newline, remainder spaces.
5. If the content does not fit even with zero padding: build a packet with 2 KB of fresh padding, append it at EOF, repoint the entry's count and offset. The old packet stays in the file as dead bytes; it is unreferenced and harmless.

**No XMP tag at all** (some non-Adobe DNGs): the only structural case. Write a copy of IFD0 at EOF with one extra entry (`0x02BC`, sorted into tag order), pointing at a new packet also appended at EOF, and repoint the header's IFD0 offset (bytes 4–7). Existing entries hold absolute offsets, so they remain valid. The old IFD0 becomes dead bytes.

**Everything else** — SubIFDs, MakerNotes, previews, embedded originals, the SR2 block on Sony files — is untouched by construction, because no existing byte is ever moved.

### 4.3 Apply

A plan is a handful of edits plus an optional append. Downloads and Folder sinks apply it to a full in-memory copy; the In place sink issues each edit as a positioned write and the append as a write at EOF. Same plan, same result, one implementation to test.

### 4.4 Spike results (2026-09-21)

A 145-line throwaway Node script using only `DataView`, `Uint8Array` and `TextEncoder` — the APIs a browser Worker has — was run on `fixtures/sample.dng` (Sony ILCE-7S, 7.5 MB):

- 2 edits, 14 bytes appended. XMP edited inside the padding (needed about 800 bytes; had 4097). `UniqueCameraModel` took the append path — `"Fujifilm X-T5\0"` is one byte longer than `"Sony ILCE-7S\0"` — and read back correctly.
- `tools/verify-dng.sh` passes for X-T5, and for X100VI on a second pass over the already-tagged output.
- The second pass preserved the stash and replaced the profile block and `TargetModel`.
- `exiftool -validate`: six warnings before, the same six after.
- Full `exiftool -j` diff against the Mac app's exiftool-written output: identical on every tag except file offsets (exiftool relocated image data when it rebuilt the file; the patcher did not) and `XMPToolkit` (exiftool stamps its own; the patcher leaves Adobe's).
- macOS ImageIO decodes all outputs at full size. The exiftool-tagged and patcher-tagged files render pixel-identical to each other, and differently from the untagged original — ImageIO keys processing off the camera identity, which is the Fujify effect itself and is shared with the Mac app.

Not exercised by the spike: the XMP-overflow append path and the no-XMP IFD relocation path. Both use the same append primitive the UniqueCameraModel path proved; both need fixtures (§7). The spike script is not promoted into the codebase; `dng/` is written test-first.

---

## 5. Output and the browser split

Detected once at startup: `const canPickFolder = 'showDirectoryPicker' in window`.

| Mode | Where | Requires | How the plan is applied |
|---|---|---|---|
| **Downloads** | browser download location | nothing | in-memory copy → `Blob` → `<a download="stem.dng">` |
| **Folder** | user-picked directory | Chromium | copy source to `.<uuid>.stem.dng` in the folder, apply edits via `createWritable()`, rename to `stem.dng` (contract §6.1) |
| **In place** | the source file | Chromium, and the file arrived as a handle (dropped or picked, not `<input type=file>`) | `createWritable({ keepExistingData: true })`, positioned writes per edit, append, `close()` |

Safari and Firefox see only Downloads, with one line under the picker: *"Saving to a folder or in place needs Chrome or Edge."*

**Permissions.** Write access to a folder or a dropped file's handle is requested at **Process**, not at drop, so browsing never prompts. Denied → the batch does not start; a clear message; nothing partial.

**Contract §7 confirmation.** Same trigger: In place, at least one pending DNG, "don't ask again" unset. Same three choices: **Update in Place**, **Choose Folder…** (opens the directory picker, switches mode, proceeds), **Cancel**. Copy is *"Update N DNGs in place?"* with a one-sentence explanation; the RAW clause drops out because every input is a DNG.

**Downloads and batches.** 200 files means 200 downloads; Chrome asks once to allow multiple downloads. No zip: a multi-gigabyte zip helps nobody, and the empty state explains the trade-off before anything is dropped.

**Stop** (contract §10). The worker is idle between files, so Stop prevents the next file from starting; the in-flight sub-second write completes. Folder mode deletes its temp file if cancelled between copy and rename. In-place writes are all-or-nothing at `close()`. Nothing half-written can be left.

---

## 6. State, persistence, UI

### 6.1 Per-file state (contract §8)

```ts
type Status =
  | { kind: 'pending' }
  | { kind: 'processing'; step: 'read' | 'writeTags' }
  | { kind: 'done'; outputName: string; wrote: 'downloads' | 'folder' | 'inplace' }
  | { kind: 'failed'; failure: Failure }
  | { kind: 'skipped'; reason: Skip };

interface Failure { step: 'read' | 'writeTags'; cause: FailureCause; detail: string }
type FailureCause = 'permissionDenied' | 'quotaOrDisk' | 'notADng' | 'other';
type Skip = { kind: 'alreadyTagged'; as: string } | { kind: 'notDng'; extension: string };
```

There is no `convert` step, no `toolMissing`, no `unsupportedCamera`, no `dngOnlyMode`. `detail` holds the browser's thrown message, shown collapsed with Copy, standing in for `toolOutput`.

Serial batch; files may be added mid-run; duplicates by `name + size + lastModified` (no absolute path in a browser). Retry, Process Again and the force flag as contract §8.3.

### 6.2 Persistence

`localStorage`, one versioned JSON key `fujify.v1`: selected target, user-added targets, save-to preference (falls back to Downloads if the browser cannot do the saved mode), already-tagged skip toggle, don't-ask-again. Not persisted: the file list, folder handles.

### 6.3 UI

The Mac window translated, using the wording contract §11 fixes:

- **Toolbar:** `+ Add`; **Profile as** menu (X-T5 · X100VI · user targets · Add Camera…); **Save to** menu (Downloads · Folder… · In place; the last two Chromium only); **Process / Stop** pill.
- **List:** thumbnail, name, camera (`NIKON CORPORATION` shown as `NIKON`, display only), one-word status with the reason in secondary colour. Click selects; ⌫ removes; ⌘I toggles the Inspector.
- **Inspector:** result card with the five tags highlighted, original identity (from file or stash), what happened and what to do, collapsed detail. Actions: **Retry**, **Choose Folder…**, **Process Again**.
- **Status bar:** `N done · M skipped · K failed` as filters after a batch; **Retry All**.
- **Add Camera sheet:** make + model, tag preview, "Fujify can't verify this name — Lightroom is the judge", link to Adobe's supported-cameras list.
- **Empty state:** DNG only; Lightroom converts; nothing is uploaded — files are processed in this browser.

No "Open in Lightroom": there is no browser equivalent.

---

## 7. Testing and verification

**Unit — vitest, `web/tests/dng/*`, Node, against `../../fixtures`.** `dng/` is pure functions over `ArrayBuffer`; tests assert on the `PatchPlan`:
- `tiff.ts`: `II` and `MM` (an `MM` variant is made in a test helper by byte-swapping the header and IFD0 of `sample.dng`); rejects magic ≠ 42; rejects TIFF without `DNGVersion`.
- `identity.ts`: Sony identity from the fixture; Fuji identity and stash from a fixture the test patched; missing tags → `''`.
- `patch.ts`, the rule table: UCM fits → in place, count shrinks; UCM inline → append; XMP fits → same count, trailer intact as the final bytes, valid UTF-8; XMP overflows → append and repoint; existing stash preserved; existing `CameraProfiles` replaced, not duplicated; no XMP → IFD0 copy at EOF with n+1 entries, header repointed, every other entry byte-identical.
- Golden: apply the plan, write a temp file, run `exiftool -j`, assert the five values. Skipped with a clear message when exiftool is not on PATH.

**Fixtures to add:** `fixtures/no-xmp.dng` (`sample.dng` with the XMP tag removed via exiftool) and `fixtures/tight-padding.dng` (padding squeezed, or generated in-test). Same `.gitattributes` treatment as the existing fixtures.

**Integration — `output/`** against an in-memory fake of the File System Access handles (the four methods used). Folder sink writes temp-then-rename and cleans up on failure; In place sink issues exactly the plan's edits as positioned writes plus one append; Downloads sink emits one `Blob` of `outputLength` bytes.

**E2E — Playwright, Chromium:** drop `sample.dng` → Downloads → Process → capture the download → `tools/verify-dng.sh`. The Mac app's golden test, on a file a real browser produced. Safari and Firefox: the page loads and offers only Downloads.

**Acceptance, by hand, once:** a web-produced DNG imported into Lightroom Classic shows the Fujifilm simulations; an X100VI one shows Reala Ace. Recorded in the contract alongside the existing 2026-09-21 note.

---

## 8. Deployment and contract changes

**Hosting.** `.github/workflows/web.yml`: in `web/`, `npm ci`, `npm test`, `npm run build`; deploy `web/dist` to GitHub Pages on push to `main`. `base` set in `vite.config.ts`. No special headers: no `SharedArrayBuffer`, no COOP/COEP.

**Contract (`docs/PIPELINE-CONTRACT.md`) edits:**

| § | Change |
|---|---|
| Preamble | macOS, Windows and web implement this document. |
| §3.2 | The config path becomes `tools/exiftool-fujify.config`. |
| §3 | New §3.5 **Web implementation**: same five identity values and same stash, written by patching IFD0 `0xC614` and the XMP packet in place — padding-preserving, append-and-repoint fallback, IFD0 relocation only when no XMP tag exists. Never rebuilds the file. Output must pass §12 and read back identically under `exiftool -j`. |
| §4.4 | Row: **Web — DNG-only, always.** |
| §5.1 | Web accepts `.dng` only; the other 23 extensions are listed and skipped as `notDng`. |
| §5.3 | Web thumbnails: embedded preview from the DNG's SubIFD. |
| §6 | Add the **Downloads** destination; Folder and In place require the File System Access API. |
| §8.1 | Web failure causes: `permissionDenied`, `quotaOrDisk`, `notADng`, `other`. |
| §8.2 | Web skips: `alreadyTagged`, `notDng`. |
| §11 | The web page states in its empty state that files are processed locally and nothing is uploaded. |

**README.** A "Fujify on the web" section: what it does, DNG-only with Lightroom converting, the browser table, the link.

---

## 9. UI design happens on the canvas, before any UI is built

**Normative.** No Svelte component in `web/src/ui/` is written until the web
design exists on the shared design canvas and has been approved. The macOS and
Windows designs were settled this way during the design-first phase
([2026-09-21-design-first.md](2026-09-21-design-first.md)); the web design is
held to the same bar rather than being improvised in code.

Canvas: https://claude.ai/artifact/5aPDVzRTxN3kS2d7E115wL

It currently carries 28 artboards in two rows, `Mac*` (15) and `Win*` (13).
The web design is a third row, `Web*`, named to mirror them.

### This is plan 2's Task 1

**Before it:** invoke the `frontend-design` skill and make the visual decisions
with it — type, colour, density, the accent, how a browser chrome-less window
reads next to two native ones. The component system is **shadcn-svelte** (Bits UI +
Tailwind v4, chosen by the repo owner on 2026-09-21), so draw in that idiom: real
Tailwind tokens, real Bits UI component shapes, so the canvas and the eventual
build agree rather than diverging the moment code starts.

**Read `project/canvas.json` first**, then place the `Web*` row below the
existing rows, following the canvas's own spacing convention (80 px between
frames in a row, 120 px between rows) and adding a `title` note for the row.
Desktop artboards are 1280–1440 wide.

Artboards, one per state the spec already commits to:

| Artboard | What it shows | Spec |
|---|---|---|
| `WebEmpty.dc.html` | Empty state: DNG only, Lightroom converts, nothing is uploaded | §6.3 |
| `WebDone.dc.html` | Finished batch, status bar filtering Done / Skipped / Failed, Retry All | §6.3 |
| `WebTarget.dc.html` | **Profile as** menu — X-T5, X100VI, user targets, Add Camera… | §2, §6.3 |
| `WebSaveTo.dc.html` | **Save to** menu — Downloads / Folder… / In place, with the Chromium-only note | §5 |
| `WebAddCamera.dc.html` | Add Camera dialog: make + model, tag preview, the "Lightroom is the judge" line | §6.3 |
| `WebInPlace.dc.html` | The once-per-batch in-place confirmation, three choices | §5, contract §7 |
| `WebInspectorFailed.dc.html` | A failed file selected: cause, what to do, collapsed detail with Copy | §6.1, §6.3 |
| `WebInspectorSkipped.dc.html` | A skipped file: `alreadyTagged` and `notDng` | §6.1 |
| `WebDragOver.dc.html` | Files dragged over the window | §6.3 |
| `WebDark.dc.html` | Finished-with-inspector state in dark appearance | §6.3 |
| `WebBrowserLimited.dc.html` | **Web-only, no Mac/Win equivalent.** Safari or Firefox: Downloads is the only Save to option, with the one-line explanation | §5 |

`WebBrowserLimited` is the one that has no counterpart in the native designs and
therefore the one most likely to be skipped. It is the screen a Mac user lands
on first, so it is not optional.

No `WebIcon` artboard: the web app reuses the existing app icon as a favicon and
needs no new icon design.

### After the build

Once the UI is implemented, run the `web-design-guidelines` skill over
`web/src/ui/` — it is a review skill, not a design one, so it belongs after the
code exists, checking semantics, focus states, keyboard navigation, tap targets
and contrast. Findings from it are fixed before the UI is considered done.

---

## 10. Dependencies: what we build and what we import

Surveyed 2026-09-21, prompted by the fair question of why a metadata tool has no
metadata library. Recorded so it is not re-litigated from memory.

### The patcher stays hand-rolled

| Need | What exists | Why not |
|---|---|---|
| Surgical DNG byte patch | nothing | no library patches metadata in place without re-serialising |
| General metadata write | `@uswriting/exiftool` + `@6over3/zeroperl-ts` — real exiftool 13.42 on Perl-in-WASM, writes, browser-capable | **25.4 MB of WASM**, and exiftool *rebuilds the file* |
| TIFF re-encode | `utif`, `tiff` | decoders; re-serialising a DNG rewrites image data |
| XMP write | `piexifjs`, `xmp-js`, `@mtillmann/jpeg-xmp-writer` | all JPEG-only |
| XMP parse/build | `fast-xml-parser` | cannot preserve the exact-byte-length padding §4.2 depends on |

The decisive point is not bundle size, it is **file safety**. exiftool relocates
image data when it writes: the 2026-09-21 spike measured `StripOffsets` moving
226378 → 7358640 and `SubIFD1:PreviewImageStart` 357706 → 6037634 on the same
fixture, where the patcher left both untouched. Since §5 offers to rewrite DNGs
**in place** — photographers keep DNGs as masters — the guarantee that no
existing byte moves is worth more than the code it costs. Importing exiftool
would also reimport the `Error copying hidden data` failure class that makes
exiftool's `-m` flag mandatory in contract §3.1.

Cost of building it: `tiff.ts`, `identity.ts`, `xmp.ts` and `patch.ts`, roughly
400 lines, zero runtime dependencies, fully unit-tested and held to
`tools/verify-dng.sh`.

### `exifr` for the read-only work — adopt in plan 2

`exifr` 7.1.3: zero dependencies, 75 KB ESM bundle, explicitly read-only, strong
TIFF support, and a `thumbnail()` API for embedded previews.

§5.3's list thumbnails were specified as hand-rolled SubIFD preview extraction —
walking sub-IFDs, `NewSubfileType`, `JPEGInterchangeFormat`. That is fiddly,
purely read-only, and exactly what `exifr` already does well. **Plan 2 uses
`exifr` for thumbnail extraction rather than reimplementing it.**

It does *not* replace `identity.ts`: that reads the five identity values the
patcher writes, needs the same byte offsets the write path uses, and must agree
with `xmp.ts` on the `fujify` namespace. Splitting reads between two
implementations would be worse than either.

### Why not an XML parser for the XMP work — and when to revisit

Asked 2026-09-21, after two real bugs in the regex-based XMP handling:

- Task 4: `firstProfileItem`'s lazy terminator truncated at a nested `/>`, so
  present `stCamera:*` values read as absent.
- Task 5: the namespace-declaration check scanned the whole packet instead of
  the patched element's scope, emitting children under an unbound prefix.

Both are exactly the class of defect a real parser prevents — namespace scoping
in particular is something a parser does natively and a regex cannot. So the
question is fair, and the answer is "not yet", for three concrete reasons:

1. **`DOMParser`/`XMLSerializer` are `Window` APIs, absent from
   `WorkerGlobalScope`.** `dng/` runs in a Worker, so the zero-cost built-in
   parser is unavailable where it would be needed.
2. **`fast-xml-parser` (5.11.1) is 65–79 KB minified and has transitive
   dependencies** (`strnum`, `is-unsafe`), breaching §10's zero-dependency rule
   for `dng/`.
3. **An XMP packet is not a plain XML document.** It is
   `<?xpacket begin?>` + BOM + the `x:xmpmeta` document + whitespace padding +
   `<?xpacket end='w'?>`. The padding is the entire mechanism behind §4.2's
   in-place write. Parse-and-reserialise discards the wrapper and the padding and
   normalises attribute order, quote style and self-closing form. A parser
   therefore only ever covers the *inner* document; the wrapper and the
   byte-exact padding stay hand-rolled either way.

**The realistic option is a hybrid:** parse and rebuild the inner `x:xmpmeta`
with a parser, keep the wrapper and padding as byte work.

**Revisit after the golden test (§7) runs against real Adobe-written DNGs.**
Both known bugs are now fixed and regression-tested, including a structural
well-formedness check, so the marginal value of a swap has dropped; what remains
is unknown-unknowns on real-world packet shapes, and the golden test is what
would expose those. Deciding then means deciding with evidence, and with a
safety net for the change.

### The native apps are over-tooled for the write path

The macOS app bundles 18 MB across 229 files (Perl + exiftool). Contract §3
uses it for four things: writing the five identity tags, reading identity for
the skip rule and stash, the Inspector dump, and a version check — plus, on
Windows, embedded-preview extraction for thumbnails.

The web implementation is effectively a proof that the **write** needs none of
that: two byte-level edits, ~400 lines, no runtime dependency. The same approach
ports to Swift and C#.

Where exiftool genuinely earns its size is the **Inspector dump** (§3.3, `-j`
with every tag it knows). No alternative — exiv2, gexiv2, the Rust crates —
matches its tag coverage, and that is a user-facing feature.

So the honest split, if this is ever revisited: patch natively, and keep
exiftool only for the dump, where nothing else will do. **Not in scope for the
web app**, which needs neither.

### Optional: `@uswriting/exiftool` in CI only

§7 notes that CI cannot build `fixtures/sample.dng` and so cannot run the golden
test. WASM exiftool could close that gap, since 25 MB is irrelevant in CI. Worth
considering if the golden test's CI absence ever bites; not adopted now.

---

## 11. Out of scope, stated plainly

- No server, no upload, no accounts, no telemetry.
- No RAW conversion.
- No "Open in Lightroom".
- No undo in v1.
- No persisted folder handles in v1.
