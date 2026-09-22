# Fujify web — patcher foundation implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the repo as a monorepo and build a dependency-free TypeScript module that rewrites a DNG's camera identity in the browser, verified by the same golden test the macOS app uses.

**Architecture:** `web/src/dng/` is four framework-free modules — TIFF/IFD0 parsing, identity reading, XMP packet rewriting, and patch planning. Nothing in it touches the DOM or the filesystem: input is an `ArrayBuffer`, output is a `PatchPlan` of byte edits plus an optional append. Existing bytes are never moved, so SubIFDs, MakerNotes and previews stay valid by construction.

**Tech Stack:** TypeScript, Vite, Svelte 5 (scaffolded here, used in plan 2), Vitest, Node 24. Zero runtime dependencies in `dng/`.

**Spec:** [`docs/plans/2026-09-21-web-app-design.md`](2026-09-21-web-app-design.md)

## Scope

This is **plan 1 of 2**. It delivers working, independently testable software: a verified DNG patcher, plus the monorepo layout the rest depends on. It covers spec §1.1, §2, §3 (the `dng/` boundary only), §4, and the unit/golden layers of §7.

**Plan 2 covers** spec §3 (`output/`, `model/`, `ui/`), §5, §6, §8 and the integration/E2E layers of §7 — the Worker, the three output sinks, the queue and state machine, the Svelte UI, GitHub Pages deployment and the contract edits. It is written after this plan lands, against a patcher whose real interfaces exist.

## Global Constraints

- **Node 24** (`node --version` → v24.x). No other runtime.
- **`web/src/dng/` has zero dependencies** — only `DataView`, `Uint8Array`, `TextEncoder`, `TextDecoder`, all present in a browser Worker. No Node built-ins, no npm packages. Tests may use Node built-ins; the module under test may not.
- **Namespace URIs, verbatim** — any deviation and exiftool reads different tags:
  - `photoshop` → `http://ns.adobe.com/photoshop/1.0/`
  - `stCamera` → `http://ns.adobe.com/photoshop/1.0/camera-profile`
  - `fujify` → `https://josephsintum.dev/ns/fujify/1.0/`
- **The five identity values** written for every file, per contract §3.1 and §3.2: `CameraProfilesMake`, `CameraProfilesModel`, `CameraProfilesUniqueCameraModel`, `CameraProfilesCameraRawProfile=True`, `UniqueCameraModel`; plus the stash `fujify:OriginalMake`, `OriginalModel`, `OriginalUniqueCameraModel`, `TargetModel`, `Version=1`.
- **Never move an existing byte.** Overwrite in place, or append at EOF and repoint. The only structural exception is relocating IFD0 when a tag must be added (Task 6).
- **`fixtures/` is gitignored** and `fixtures/sample.dng` is built locally by `tools/fetch-fixtures.sh` (needs Adobe DNG Converter or dnglab). Never commit a fixture binary. Unit tests build synthetic DNGs in-test; fixture-dependent tests skip when the file is absent.
- **Commit style:** sentence-case description of the change, no `feat:`/`fix:` prefixes, **no `Co-Authored-By` footer** (repo owner's standing preference). Match existing history: `Fix the correctness bugs the review turned up`.
- **Built-in targets** (contract §2): `{make: 'FUJIFILM', model: 'X-T5', uniqueCameraModel: 'Fujifilm X-T5'}` and `{make: 'FUJIFILM', model: 'X100VI', uniqueCameraModel: 'Fujifilm X100VI'}`.

## File Structure

| Path | Responsibility |
|---|---|
| `mac/**` | The Swift app, moved verbatim from the repo root (Task 1) |
| `windows/README.md` | Coming-soon placeholder (Task 1) |
| `tools/exiftool-fujify.config` | The XMP-fujify namespace, shared by all implementations (Task 1) |
| `web/package.json`, `tsconfig.json`, `vite.config.ts` | Scaffold (Task 2) |
| `web/tests/helpers/synth.ts` | Builds synthetic DNGs for tests — the test backbone (Task 2) |
| `web/src/dng/tiff.ts` | TIFF header + IFD0 entry parsing, both byte orders. Knows nothing about cameras. |
| `web/src/dng/identity.ts` | Reads camera identity, profile tags and stash out of a DNG. Depends on `tiff.ts`. |
| `web/src/dng/xmp.ts` | Rewrites XMP packet *text*. Pure string work; knows nothing about TIFF. |
| `web/src/dng/patch.ts` | Assembles a `PatchPlan` from a buffer + target. Depends on all three above. |
| `web/tests/dng/*.test.ts` | Unit tests, one file per module |
| `web/tests/golden.test.ts` | Real fixture → exiftool + `tools/verify-dng.sh` (Task 7) |

---

### Task 1: Monorepo restructure

Moves the Swift app into `mac/`, creates `web/` and `windows/`, and lifts the exiftool config to shared `tools/`. No behaviour changes. Git history is preserved with `git mv`.

**Files:**
- Move: everything Swift → `mac/` (see step 1)
- Move: `Vendor/exiftool-fujify.config` → `tools/exiftool-fujify.config`
- Modify: `mac/project.yml` (source paths), `.gitignore`, `README.md`, `docs/PIPELINE-CONTRACT.md` (§3.2 path)
- Create: `windows/README.md`

**Interfaces:**
- Consumes: nothing
- Produces: the `mac/`, `web/`, `windows/` layout every later task assumes; `tools/exiftool-fujify.config` as the shared config path used by Task 7's golden test

- [ ] **Step 1: Move the Swift app into `mac/`**

The config comes out of `Vendor/` *before* `Vendor/` moves, so it lands in shared `tools/`.

```bash
cd /Users/josephsintum/code/Fujify
mkdir -p mac/tools windows
git mv Vendor/exiftool-fujify.config tools/exiftool-fujify.config
for p in project.yml FujifyApp.swift ContentView.swift .swift-format \
         Engine Models Views Tests Assets.xcassets Vendor; do
  git mv "$p" "mac/$p"
done
git mv tools/fetch-tools.sh mac/tools/fetch-tools.sh
git mv tools/render-icon.swift mac/tools/render-icon.swift
git status --short
```

Expected: `tools/` keeps only `verify-dng.sh`, `fetch-fixtures.sh` and `exiftool-fujify.config`; everything else is under `mac/`.

- [ ] **Step 2: Point `project.yml` at the shared config**

In `mac/project.yml`, replace the line `      - path: Vendor/exiftool-fujify.config` with:

```yaml
      # Shared with the Windows and web implementations; see
      # docs/PIPELINE-CONTRACT.md §3.2. Lives outside mac/ deliberately.
      - path: ../tools/exiftool-fujify.config
```

- [ ] **Step 3: Verify xcodegen accepts the out-of-tree path and the app still builds**

```bash
cd /Users/josephsintum/code/Fujify/mac && xcodegen generate && \
  xcodebuild -project Fujify.xcodeproj -scheme Fujify -destination 'platform=macOS' test 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, and the config present in the built bundle:

```bash
find ~/Library/Developer/Xcode/DerivedData -name exiftool-fujify.config -path '*Fujify.app*' | head -1
```

Expected: one path printed. If xcodegen rejects `../tools/...`, fall back: keep the file at `tools/exiftool-fujify.config`, and in `project.yml` use an explicit resource entry instead —

```yaml
      - path: ../tools/exiftool-fujify.config
        buildPhase: resources
```

If that also fails, stop and report; do not silently move the config back, because Task 7 and the Windows port both read the shared path.

- [ ] **Step 4: Update `.gitignore` for the new paths**

Change these three lines (currently at roughly 367, 401, 402):

```
Fujify.xcodeproj/        →  mac/Fujify.xcodeproj/
Vendor/exiftool/         →  mac/Vendor/exiftool/
Vendor/dnglab            →  mac/Vendor/dnglab
```

and append:

```
## Web app
web/node_modules/
web/dist/
web/.vite/
web/test-results/
web/playwright-report/
```

- [ ] **Step 5: Create the Windows placeholder**

Create `windows/README.md`:

```markdown
# Fujify for Windows

Not built yet.

The design is drafted and the shared pipeline contract is written, so the
port is a matter of implementation rather than discovery:

- [`docs/PIPELINE-CONTRACT.md`](../docs/PIPELINE-CONTRACT.md) — the normative
  spec every implementation follows. §3.4, §4.1 and §5.3 already record the
  Windows-specific differences.
- [`docs/plans/2026-09-21-windows-port-prerequisites.md`](../docs/plans/2026-09-21-windows-port-prerequisites.md)
  — what has to be verified on a real Windows install first.
- [`docs/plans/2026-09-21-design-first.md`](../docs/plans/2026-09-21-design-first.md)
  — the agreed Fluent design for every screen.

In the meantime, [Fujify for the web](../web/) runs in Edge and Chrome on
Windows and does everything except convert RAW files to DNG.
```

- [ ] **Step 6: Update the contract's config path and implementation list**

In `docs/PIPELINE-CONTRACT.md`, §3.2, change `Vendor/exiftool-fujify.config` to `tools/exiftool-fujify.config`. In §3.3's table, change `-config <cfg>` rows' surrounding prose only if it names the old path. In the preamble, change:

```
**Status:** normative. Both the macOS app and the Windows app implement this
document. Where they differ, the difference is stated here explicitly.
```

to:

```
**Status:** normative. The macOS, Windows and web apps implement this
document. Where they differ, the difference is stated here explicitly.
```

Verify nothing else references the old path:

```bash
cd /Users/josephsintum/code/Fujify && grep -rn "Vendor/exiftool-fujify" --include='*.md' --include='*.yml' --include='*.swift' --include='*.sh' . || echo "clean"
```

Expected: `clean`.

- [ ] **Step 7: Update the README for the new layout**

In `README.md`, retitle the top heading to `# Fujify` with a one-line description, add a platform table, and change the build instructions to `cd mac`. Replace the `### Repository layout` table's paths with the monorepo ones:

```markdown
| Path | What's in it |
|---|---|
| `mac/` | The macOS app (SwiftUI). `Engine/`, `Models/`, `Views/`, `Tests/`, and the bundled tools in `Vendor/`. |
| `web/` | The browser app (Svelte + TypeScript). DNG-only; patches files locally, nothing is uploaded. |
| `windows/` | Not built yet — see its README. |
| `docs/` | `PIPELINE-CONTRACT.md`, the normative spec all three implementations follow, plus design and planning docs. |
| `fixtures/` | Sample RAW/DNG files, fetched by `tools/fetch-fixtures.sh`. Gitignored. |
| `tools/` | Shared, platform-neutral: `verify-dng.sh` (the golden test), `fetch-fixtures.sh`, `exiftool-fujify.config`. |
```

In the "Build from source" block, change `cd Fujify-mac` to `cd Fujify-mac/mac`. The `tools/fetch-tools.sh` line needs no change — it now resolves to `mac/tools/`, and the script derives `Vendor/` from its own location, so it keeps working untouched. Add a line noting that test fixtures are fetched from the repo root with `../tools/fetch-fixtures.sh`.

- [ ] **Step 8: Verify the Mac build one more time from a clean generate, then commit**

```bash
cd /Users/josephsintum/code/Fujify/mac && rm -rf Fujify.xcodeproj && xcodegen generate && \
  xcodebuild -project Fujify.xcodeproj -scheme Fujify -destination 'platform=macOS' test 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`

```bash
cd /Users/josephsintum/code/Fujify
git add -A
git commit -m "Move the Swift app into mac/ and make room for web and windows"
```

---

### Task 2: Web scaffold and the synthetic DNG builder

Sets up `web/` and the test helper every later task depends on. The helper matters more than the scaffold: it builds valid DNGs in memory with any byte order, any padding, any tag missing — so every edge case in Tasks 3–6 is testable without a binary fixture.

**Files:**
- Create: `web/package.json`, `web/tsconfig.json`, `web/vite.config.ts`, `web/.gitignore`, `web/index.html`, `web/src/main.ts`, `web/src/App.svelte`
- Create: `web/tests/helpers/synth.ts`, `web/tests/helpers/synth.test.ts`

**Interfaces:**
- Consumes: Task 1's `web/` directory
- Produces:
  - `npm test` in `web/` runs Vitest
  - `synthDng(opts?: SynthOptions): Uint8Array`
  - `xmpPacket(padding: number, extra?: string): string`
  - `SynthOptions = { littleEndian?: boolean; make?: string; model?: string; uniqueCameraModel?: string | null; xmp?: string | null; trailingBytes?: number }` — `null` omits that tag entirely

- [ ] **Step 1: Create the scaffold files**

`web/package.json`:

```json
{
  "name": "fujify-web",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview",
    "check": "svelte-check --tsconfig ./tsconfig.json",
    "test": "vitest run",
    "test:watch": "vitest"
  }
}
```

`web/tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "lib": ["ES2022", "DOM", "DOM.Iterable"],
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "verbatimModuleSyntax": true,
    "isolatedModules": true,
    "skipLibCheck": true,
    "noEmit": true,
    "types": ["vite/client", "node"]
  },
  "include": ["src/**/*.ts", "src/**/*.svelte", "tests/**/*.ts"]
}
```

`web/vite.config.ts`:

```ts
// vitest/config, not vite — the `test` key below is not part of vite's own schema.
import { defineConfig } from 'vitest/config';
import { svelte } from '@sveltejs/vite-plugin-svelte';

export default defineConfig({
  plugins: [svelte()],
  // GitHub Pages serves this repo at /Fujify-mac/; overridden in CI if that changes.
  base: process.env.VITE_BASE ?? '/',
  test: {
    include: ['tests/**/*.test.ts'],
    environment: 'node',
  },
});
```

`web/index.html`:

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Fujify</title>
  </head>
  <body>
    <div id="app"></div>
    <script type="module" src="/src/main.ts"></script>
  </body>
</html>
```

`web/src/main.ts`:

```ts
import { mount } from 'svelte';
import App from './App.svelte';

const target = document.getElementById('app');
if (!target) throw new Error('#app not found');

export default mount(App, { target });
```

`web/src/App.svelte`:

```svelte
<main>
  <h1>Fujify</h1>
  <p>Fujifilm film simulation profiles for DNG files, in your browser.</p>
</main>
```

- [ ] **Step 2: Install dependencies**

Versions are resolved by npm rather than pinned here, so the plan does not go stale.

```bash
cd /Users/josephsintum/code/Fujify/web
npm install -D vite @sveltejs/vite-plugin-svelte svelte svelte-check typescript vitest @types/node
npm run build 2>&1 | tail -5
```

Expected: a `dist/` build with no errors.

- [ ] **Step 3: Write the synthetic DNG builder**

Create `web/tests/helpers/synth.ts`. It writes TIFF by hand rather than importing anything from `src/`, so a bug in the code under test cannot hide behind a matching bug in the fixture.

```ts
// Builds valid little- or big-endian DNGs in memory for tests. Deliberately
// independent of src/dng/ — nothing here imports the code under test.

export interface SynthOptions {
  littleEndian?: boolean;
  make?: string;
  model?: string;
  /** null omits the UniqueCameraModel tag entirely. */
  uniqueCameraModel?: string | null;
  /** null omits the XMP tag entirely. */
  xmp?: string | null;
  /** Extra zero bytes after the last value, to exercise odd file lengths. */
  trailingBytes?: number;
}

const TAG_MAKE = 0x010f;
const TAG_MODEL = 0x0110;
const TAG_XMP = 0x02bc;
const TAG_DNG_VERSION = 0xc612;
const TAG_UCM = 0xc614;

/** An XMP packet shaped like Adobe's: header, one rdf:Description, padding, writable trailer. */
export function xmpPacket(padding: number, extra = ''): string {
  const head =
    `<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>\n` +
    `<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Synth 1.0">\n` +
    ` <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n` +
    `  <rdf:Description rdf:about=""\n` +
    `    xmlns:tiff="http://ns.adobe.com/tiff/1.0/"\n` +
    `   tiff:Make="SONY">\n` +
    extra +
    `  </rdf:Description>\n` +
    ` </rdf:RDF>\n` +
    `</x:xmpmeta>\n`;
  return head + ' '.repeat(padding) + `<?xpacket end='w'?>`;
}

export function synthDng(opts: SynthOptions = {}): Uint8Array {
  const le = opts.littleEndian ?? true;
  const make = opts.make ?? 'SONY';
  const model = opts.model ?? 'ILCE-7S';
  const ucm = opts.uniqueCameraModel === undefined ? 'Sony ILCE-7S' : opts.uniqueCameraModel;
  const xmp = opts.xmp === undefined ? xmpPacket(4096) : opts.xmp;

  const enc = new TextEncoder();
  const fields: { tag: number; type: number; count: number; bytes: Uint8Array }[] = [];
  const ascii = (tag: number, s: string) => {
    const bytes = enc.encode(s + '\0');
    fields.push({ tag, type: 2, count: bytes.length, bytes });
  };

  ascii(TAG_MAKE, make);
  ascii(TAG_MODEL, model);
  fields.push({ tag: TAG_DNG_VERSION, type: 1, count: 4, bytes: new Uint8Array([1, 6, 0, 0]) });
  if (ucm !== null) ascii(TAG_UCM, ucm);
  if (xmp !== null) {
    const bytes = enc.encode(xmp);
    fields.push({ tag: TAG_XMP, type: 1, count: bytes.length, bytes });
  }
  fields.sort((a, b) => a.tag - b.tag);

  const ifdOffset = 8;
  let dataAt = ifdOffset + 2 + fields.length * 12 + 4;
  const placed = fields.map((f) => {
    if (f.bytes.length <= 4) return { f, at: -1 };
    const at = dataAt;
    dataAt += f.bytes.length + (f.bytes.length & 1);
    return { f, at };
  });

  const out = new Uint8Array(dataAt + (opts.trailingBytes ?? 0));
  const dv = new DataView(out.buffer);
  out[0] = out[1] = le ? 0x49 : 0x4d;
  dv.setUint16(2, 42, le);
  dv.setUint32(4, ifdOffset, le);
  dv.setUint16(ifdOffset, fields.length, le);

  placed.forEach(({ f, at }, i) => {
    const e = ifdOffset + 2 + i * 12;
    dv.setUint16(e, f.tag, le);
    dv.setUint16(e + 2, f.type, le);
    dv.setUint32(e + 4, f.count, le);
    if (at < 0) out.set(f.bytes, e + 8);
    else {
      dv.setUint32(e + 8, at, le);
      out.set(f.bytes, at);
    }
  });
  dv.setUint32(ifdOffset + 2 + fields.length * 12, 0, le);
  return out;
}
```

- [ ] **Step 4: Write the failing test for the builder**

The builder is test infrastructure, so it gets its own tests — a broken fixture would invalidate every later assertion.

Create `web/tests/helpers/synth.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { synthDng, xmpPacket } from './synth';

describe('synthDng', () => {
  it('writes a little-endian TIFF header with IFD0 at offset 8', () => {
    const buf = synthDng();
    expect(String.fromCharCode(buf[0]!, buf[1]!)).toBe('II');
    const dv = new DataView(buf.buffer);
    expect(dv.getUint16(2, true)).toBe(42);
    expect(dv.getUint32(4, true)).toBe(8);
  });

  it('writes a big-endian header when asked', () => {
    const buf = synthDng({ littleEndian: false });
    expect(String.fromCharCode(buf[0]!, buf[1]!)).toBe('MM');
    const dv = new DataView(buf.buffer);
    expect(dv.getUint16(2, false)).toBe(42);
  });

  it('writes entries in ascending tag order', () => {
    const buf = synthDng();
    const dv = new DataView(buf.buffer);
    const n = dv.getUint16(8, true);
    const tags = Array.from({ length: n }, (_, i) => dv.getUint16(10 + i * 12, true));
    expect(tags).toEqual([...tags].sort((a, b) => a - b));
    expect(tags).toContain(0xc612);
  });

  it('omits the XMP tag when xmp is null', () => {
    const buf = synthDng({ xmp: null });
    const dv = new DataView(buf.buffer);
    const n = dv.getUint16(8, true);
    const tags = Array.from({ length: n }, (_, i) => dv.getUint16(10 + i * 12, true));
    expect(tags).not.toContain(0x02bc);
  });

  it('round-trips the XMP packet bytes it was given', () => {
    const packet = xmpPacket(64);
    const buf = synthDng({ xmp: packet });
    const dv = new DataView(buf.buffer);
    const n = dv.getUint16(8, true);
    let found = '';
    for (let i = 0; i < n; i++) {
      const e = 10 + i * 12;
      if (dv.getUint16(e, true) !== 0x02bc) continue;
      const count = dv.getUint32(e + 4, true);
      const at = dv.getUint32(e + 8, true);
      found = new TextDecoder().decode(buf.subarray(at, at + count));
    }
    expect(found).toBe(packet);
    expect(found.endsWith("<?xpacket end='w'?>")).toBe(true);
  });
});
```

- [ ] **Step 5: Run the tests**

```bash
cd /Users/josephsintum/code/Fujify/web && npm test
```

Expected: 5 passed. If `synth.ts` has a bug, fix it here — everything downstream trusts this file.

- [ ] **Step 6: Commit**

```bash
cd /Users/josephsintum/code/Fujify
git add web .gitignore
git commit -m "Scaffold the web app and a synthetic DNG builder for its tests"
```

---

### Task 3: `dng/tiff.ts` — header and IFD0 parsing

**Files:**
- Create: `web/src/dng/tiff.ts`
- Test: `web/tests/dng/tiff.test.ts`

**Interfaces:**
- Consumes: `synthDng`, `xmpPacket` from Task 2
- Produces:

```ts
export const TAG: { Make: 0x010f; Model: 0x0110; XMP: 0x02bc; DNGVersion: 0xc612; UniqueCameraModel: 0xc614 };
export class NotADngError extends Error {}
export interface TiffHeader { littleEndian: boolean; ifd0Offset: number }
export interface IfdEntry { tag: number; type: number; count: number; entryOffset: number; dataOffset: number; byteLength: number; inline: boolean }
export interface Ifd { offset: number; count: number; entries: Map<number, IfdEntry>; nextIfdPointerOffset: number }
export function readHeader(buf: Uint8Array): TiffHeader;
export function readIfd0(buf: Uint8Array, header: TiffHeader): Ifd;
export function readAscii(buf: Uint8Array, entry: IfdEntry | undefined): string;
export function view(buf: Uint8Array): DataView;
```

- [ ] **Step 1: Write the failing tests**

Create `web/tests/dng/tiff.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { NotADngError, TAG, readAscii, readHeader, readIfd0 } from '../../src/dng/tiff';
import { synthDng, xmpPacket } from '../helpers/synth';

describe('readHeader', () => {
  it('reads a little-endian header', () => {
    expect(readHeader(synthDng())).toEqual({ littleEndian: true, ifd0Offset: 8 });
  });

  it('reads a big-endian header', () => {
    expect(readHeader(synthDng({ littleEndian: false }))).toEqual({ littleEndian: false, ifd0Offset: 8 });
  });

  it('rejects a file that is not TIFF', () => {
    expect(() => readHeader(new TextEncoder().encode('not a tiff at all'))).toThrow(NotADngError);
  });

  it('rejects BigTIFF', () => {
    const buf = synthDng();
    new DataView(buf.buffer).setUint16(2, 43, true);
    expect(() => readHeader(buf)).toThrow(/magic 43/);
  });

  it('rejects a truncated file', () => {
    expect(() => readHeader(new Uint8Array(4))).toThrow(NotADngError);
  });
});

describe('readIfd0', () => {
  it('finds every tag it was given, in either byte order', () => {
    for (const littleEndian of [true, false]) {
      const buf = synthDng({ littleEndian });
      const ifd = readIfd0(buf, readHeader(buf));
      expect(ifd.entries.has(TAG.Make)).toBe(true);
      expect(ifd.entries.has(TAG.Model)).toBe(true);
      expect(ifd.entries.has(TAG.DNGVersion)).toBe(true);
      expect(ifd.entries.has(TAG.UniqueCameraModel)).toBe(true);
      expect(ifd.entries.has(TAG.XMP)).toBe(true);
      expect(ifd.count).toBe(5);
    }
  });

  it('reports an out-of-line entry with its real data offset', () => {
    const buf = synthDng();
    const ifd = readIfd0(buf, readHeader(buf));
    const xmp = ifd.entries.get(TAG.XMP)!;
    expect(xmp.inline).toBe(false);
    expect(xmp.dataOffset).toBeGreaterThan(ifd.offset);
    expect(xmp.byteLength).toBe(xmp.count);
  });

  it('reports a 4-byte value as inline, stored in the entry itself', () => {
    const buf = synthDng();
    const ifd = readIfd0(buf, readHeader(buf));
    const version = ifd.entries.get(TAG.DNGVersion)!;
    expect(version.inline).toBe(true);
    expect(version.dataOffset).toBe(version.entryOffset + 8);
    expect(Array.from(buf.subarray(version.dataOffset, version.dataOffset + 4))).toEqual([1, 6, 0, 0]);
  });

  it('points at the next-IFD pointer just past the entries', () => {
    const buf = synthDng();
    const ifd = readIfd0(buf, readHeader(buf));
    expect(ifd.nextIfdPointerOffset).toBe(ifd.offset + 2 + ifd.count * 12);
  });

  it('rejects an IFD0 offset past the end of the file', () => {
    const buf = synthDng();
    new DataView(buf.buffer).setUint32(4, buf.length + 100, true);
    expect(() => readIfd0(buf, readHeader(buf))).toThrow(NotADngError);
  });
});

describe('readAscii', () => {
  it('reads a string and stops at the NUL', () => {
    const buf = synthDng({ make: 'NIKON CORPORATION' });
    const ifd = readIfd0(buf, readHeader(buf));
    expect(readAscii(buf, ifd.entries.get(TAG.Make))).toBe('NIKON CORPORATION');
  });

  it('returns an empty string for a missing entry', () => {
    const buf = synthDng({ uniqueCameraModel: null });
    const ifd = readIfd0(buf, readHeader(buf));
    expect(readAscii(buf, ifd.entries.get(TAG.UniqueCameraModel))).toBe('');
  });

  it('reads the XMP packet back byte for byte', () => {
    const packet = xmpPacket(128);
    const buf = synthDng({ xmp: packet });
    const ifd = readIfd0(buf, readHeader(buf));
    const e = ifd.entries.get(TAG.XMP)!;
    expect(new TextDecoder().decode(buf.subarray(e.dataOffset, e.dataOffset + e.byteLength))).toBe(packet);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/josephsintum/code/Fujify/web && npm test -- tests/dng/tiff.test.ts
```

Expected: FAIL — `Failed to resolve import "../../src/dng/tiff"`.

- [ ] **Step 3: Write the implementation**

Create `web/src/dng/tiff.ts`:

```ts
// TIFF/DNG structure reading. Knows about bytes and IFD entries, nothing about
// cameras. Browser-only APIs: DataView, Uint8Array, TextDecoder.

export const TAG = {
  Make: 0x010f,
  Model: 0x0110,
  XMP: 0x02bc,
  DNGVersion: 0xc612,
  UniqueCameraModel: 0xc614,
} as const;

/** The file is not something we can safely patch. Surfaced to the user as `notADng`. */
export class NotADngError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'NotADngError';
  }
}

export interface TiffHeader {
  littleEndian: boolean;
  ifd0Offset: number;
}

export interface IfdEntry {
  tag: number;
  type: number;
  /** Number of values of `type`, not bytes. For ASCII and BYTE these coincide. */
  count: number;
  /** Offset of the 12-byte entry record itself. */
  entryOffset: number;
  /** Where the value bytes live. For inline values this is `entryOffset + 8`. */
  dataOffset: number;
  byteLength: number;
  inline: boolean;
}

export interface Ifd {
  offset: number;
  count: number;
  entries: Map<number, IfdEntry>;
  nextIfdPointerOffset: number;
}

/** Bytes per value for each TIFF type, indexed by type code. Unknown types count as 1. */
const TYPE_SIZE: Record<number, number> = {
  1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2, 9: 4, 10: 8, 11: 4, 12: 8, 13: 4,
};

export function view(buf: Uint8Array): DataView {
  return new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
}

export function readHeader(buf: Uint8Array): TiffHeader {
  if (buf.byteLength < 8) throw new NotADngError('file is too small to be a DNG');
  const order = String.fromCharCode(buf[0]!, buf[1]!);
  if (order !== 'II' && order !== 'MM') throw new NotADngError('not a TIFF file');
  const littleEndian = order === 'II';
  const dv = view(buf);
  const magic = dv.getUint16(2, littleEndian);
  // DNG is TIFF 6, always magic 42. BigTIFF (43) is a different container.
  if (magic !== 42) throw new NotADngError(`not a classic TIFF file (magic ${magic})`);
  return { littleEndian, ifd0Offset: dv.getUint32(4, littleEndian) };
}

export function readIfd0(buf: Uint8Array, header: TiffHeader): Ifd {
  const { littleEndian: le, ifd0Offset: offset } = header;
  const dv = view(buf);
  if (offset + 2 > buf.byteLength) throw new NotADngError('IFD0 starts past the end of the file');
  const count = dv.getUint16(offset, le);
  const end = offset + 2 + count * 12 + 4;
  if (end > buf.byteLength) throw new NotADngError('IFD0 runs past the end of the file');

  const entries = new Map<number, IfdEntry>();
  for (let i = 0; i < count; i++) {
    const entryOffset = offset + 2 + i * 12;
    const tag = dv.getUint16(entryOffset, le);
    const type = dv.getUint16(entryOffset + 2, le);
    const valueCount = dv.getUint32(entryOffset + 4, le);
    const byteLength = (TYPE_SIZE[type] ?? 1) * valueCount;
    const inline = byteLength <= 4;
    const dataOffset = inline ? entryOffset + 8 : dv.getUint32(entryOffset + 8, le);
    if (!inline && dataOffset + byteLength > buf.byteLength) {
      throw new NotADngError(`tag 0x${tag.toString(16)} points past the end of the file`);
    }
    // Duplicate tags are malformed; the first wins, which is what exiftool does.
    if (!entries.has(tag)) {
      entries.set(tag, { tag, type, count: valueCount, entryOffset, dataOffset, byteLength, inline });
    }
  }

  return { offset, count, entries, nextIfdPointerOffset: offset + 2 + count * 12 };
}

export function readAscii(buf: Uint8Array, entry: IfdEntry | undefined): string {
  if (!entry) return '';
  let out = '';
  for (let i = 0; i < entry.byteLength; i++) {
    const c = buf[entry.dataOffset + i];
    if (c === undefined || c === 0) break;
    out += String.fromCharCode(c);
  }
  return out;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Users/josephsintum/code/Fujify/web && npm test -- tests/dng/tiff.test.ts
```

Expected: 13 passed.

- [ ] **Step 5: Commit**

```bash
cd /Users/josephsintum/code/Fujify
git add web/src/dng/tiff.ts web/tests/dng/tiff.test.ts
git commit -m "Read TIFF headers and IFD0 entries in both byte orders"
```

---

### Task 4: `dng/identity.ts` — reading a DNG's camera identity

Reads what contract §3.3 reads: the camera identity for the list column and the stash, the profile tags for the already-tagged skip, and the existing stash so a second pass does not overwrite it.

**Files:**
- Create: `web/src/dng/identity.ts`
- Test: `web/tests/dng/identity.test.ts`

**Interfaces:**
- Consumes: `readHeader`, `readIfd0`, `readAscii`, `TAG`, `NotADngError`, `Ifd`, `TiffHeader` from Task 3
- Produces:

```ts
export interface CameraIdentity { make: string; model: string; uniqueCameraModel: string }
export interface ProfileTags { make: string; model: string; uniqueCameraModel: string; cameraRawProfile: string }
export interface Stash { originalMake: string; originalModel: string; originalUniqueCameraModel: string; targetModel: string; version: string }
export interface DngInfo { header: TiffHeader; ifd: Ifd; identity: CameraIdentity; profiles: ProfileTags; stash: Stash; xmpPacket: string | null }
export function readDng(buf: Uint8Array): DngInfo;
export function readXmpProperty(xml: string, qname: string): string;
export function decodeEntities(s: string): string;
export function hasStash(info: DngInfo): boolean;
```

- [ ] **Step 1: Write the failing tests**

Create `web/tests/dng/identity.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { NotADngError } from '../../src/dng/tiff';
import { hasStash, readDng, readXmpProperty } from '../../src/dng/identity';
import { synthDng, xmpPacket } from '../helpers/synth';

const TAGGED = `   <photoshop:CameraProfiles>
    <rdf:Seq>
     <rdf:li rdf:parseType="Resource">
      <stCamera:CameraRawProfile>True</stCamera:CameraRawProfile>
      <stCamera:Make>FUJIFILM</stCamera:Make>
      <stCamera:Model>X-T5</stCamera:Model>
      <stCamera:UniqueCameraModel>Fujifilm X-T5</stCamera:UniqueCameraModel>
     </rdf:li>
    </rdf:Seq>
   </photoshop:CameraProfiles>
   <fujify:OriginalMake>SONY</fujify:OriginalMake>
   <fujify:OriginalModel>ILCE-7S</fujify:OriginalModel>
   <fujify:OriginalUniqueCameraModel>Sony ILCE-7S</fujify:OriginalUniqueCameraModel>
   <fujify:Version>1</fujify:Version>
   <fujify:TargetModel>X-T5</fujify:TargetModel>
`;

describe('readDng', () => {
  it('reads the camera identity from IFD0', () => {
    const info = readDng(synthDng());
    expect(info.identity).toEqual({ make: 'SONY', model: 'ILCE-7S', uniqueCameraModel: 'Sony ILCE-7S' });
  });

  it('reports empty profile tags and an empty stash for an untouched file', () => {
    const info = readDng(synthDng());
    expect(info.profiles).toEqual({ make: '', model: '', uniqueCameraModel: '', cameraRawProfile: '' });
    expect(info.stash.originalMake).toBe('');
    expect(hasStash(info)).toBe(false);
  });

  it('reads the profile tags and stash out of a file Fujify already tagged', () => {
    const info = readDng(synthDng({ xmp: xmpPacket(512, TAGGED), uniqueCameraModel: 'Fujifilm X-T5' }));
    expect(info.profiles).toEqual({
      make: 'FUJIFILM', model: 'X-T5', uniqueCameraModel: 'Fujifilm X-T5', cameraRawProfile: 'True',
    });
    expect(info.stash).toEqual({
      originalMake: 'SONY',
      originalModel: 'ILCE-7S',
      originalUniqueCameraModel: 'Sony ILCE-7S',
      targetModel: 'X-T5',
      version: '1',
    });
    expect(hasStash(info)).toBe(true);
  });

  it('reports a null packet when the file has no XMP', () => {
    const info = readDng(synthDng({ xmp: null }));
    expect(info.xmpPacket).toBeNull();
    expect(info.profiles.make).toBe('');
  });

  it('rejects a TIFF with no DNGVersion tag', () => {
    const buf = synthDng();
    // Turn the DNGVersion tag into an unknown one, leaving the file otherwise valid.
    const dv = new DataView(buf.buffer);
    for (let i = 0; i < dv.getUint16(8, true); i++) {
      const e = 10 + i * 12;
      if (dv.getUint16(e, true) === 0xc612) dv.setUint16(e, 0xdead, true);
    }
    expect(() => readDng(buf)).toThrow(/not a DNG/);
    expect(() => readDng(buf)).toThrow(NotADngError);
  });

  it('works in big-endian files', () => {
    const info = readDng(synthDng({ littleEndian: false, make: 'CANON', model: 'EOS R6' }));
    expect(info.identity.make).toBe('CANON');
    expect(info.identity.model).toBe('EOS R6');
  });
});

describe('readXmpProperty', () => {
  it('reads an element', () => {
    expect(readXmpProperty('<a:b>value</a:b>', 'a:b')).toBe('value');
  });

  it('reads a double-quoted attribute', () => {
    expect(readXmpProperty('<rdf:Description a:b="value">', 'a:b')).toBe('value');
  });

  it('reads a single-quoted attribute, which is what exiftool writes', () => {
    expect(readXmpProperty("<rdf:Description a:b='value'>", 'a:b')).toBe('value');
  });

  it('decodes XML entities', () => {
    expect(readXmpProperty('<a:b>M&amp;M &lt;x&gt;</a:b>', 'a:b')).toBe('M&M <x>');
  });

  it('returns an empty string when the property is absent', () => {
    expect(readXmpProperty('<a:other>value</a:other>', 'a:b')).toBe('');
  });

  it('does not match a property whose name merely ends with the one asked for', () => {
    expect(readXmpProperty('<x:NotMake>wrong</x:NotMake>', 'x:Make')).toBe('');
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/josephsintum/code/Fujify/web && npm test -- tests/dng/identity.test.ts
```

Expected: FAIL — cannot resolve `../../src/dng/identity`.

- [ ] **Step 3: Write the implementation**

Create `web/src/dng/identity.ts`:

```ts
// Reads a DNG's camera identity, the CameraProfiles tags Fujify writes, and the
// XMP-fujify stash. Mirrors PIPELINE-CONTRACT.md §3.3: a missing tag is an empty
// string, never an error.

import { type Ifd, type TiffHeader, NotADngError, TAG, readAscii, readHeader, readIfd0 } from './tiff';

export interface CameraIdentity {
  make: string;
  model: string;
  uniqueCameraModel: string;
}

export interface ProfileTags {
  make: string;
  model: string;
  uniqueCameraModel: string;
  cameraRawProfile: string;
}

export interface Stash {
  originalMake: string;
  originalModel: string;
  originalUniqueCameraModel: string;
  targetModel: string;
  version: string;
}

export interface DngInfo {
  header: TiffHeader;
  ifd: Ifd;
  identity: CameraIdentity;
  profiles: ProfileTags;
  stash: Stash;
  /** The raw XMP packet text, or null when the file carries no XMP tag. */
  xmpPacket: string | null;
}

export function decodeEntities(s: string): string {
  return s
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, '&');
}

/** Escapes a qname for use in a RegExp — the ':' is literal, but be safe about the rest. */
function escapeRe(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Reads one XMP property by qualified name, in either of the two forms XMP allows:
 * a child element, or an attribute on rdf:Description. Adobe prefers attributes for
 * simple values; exiftool writes elements. Both must read.
 *
 * Deliberately not a full XML parse: we need five values out of a packet whose exact
 * shape we do not control, and a regex that fails to match yields '' — the same as
 * an absent tag, which is what the contract asks for.
 */
export function readXmpProperty(xml: string, qname: string): string {
  const q = escapeRe(qname);
  const element = xml.match(new RegExp(`<${q}(?:\\s[^>]*)?>([\\s\\S]*?)</${q}>`));
  if (element?.[1] !== undefined) return decodeEntities(element[1].trim());
  // (?<![\w:-]) so stCamera:Make does not match a hypothetical x:stCamera:Make.
  const attr = xml.match(new RegExp(`(?<![\\w:-])${q}\\s*=\\s*("([^"]*)"|'([^']*)')`));
  const value = attr?.[2] ?? attr?.[3];
  return value === undefined ? '' : decodeEntities(value.trim());
}

/** The first rdf:li under photoshop:CameraProfiles, open tag included so attributes read too. */
function firstProfileItem(packet: string): string {
  const block = packet.match(/<photoshop:CameraProfiles>([\s\S]*?)<\/photoshop:CameraProfiles>/);
  if (!block?.[1]) return '';
  const li = block[1].match(/<rdf:li[\s\S]*?(?:\/>|<\/rdf:li>)/);
  return li?.[0] ?? '';
}

export function readDng(buf: Uint8Array): DngInfo {
  const header = readHeader(buf);
  const ifd = readIfd0(buf, header);
  if (!ifd.entries.has(TAG.DNGVersion)) {
    throw new NotADngError('this is a TIFF file but not a DNG (no DNGVersion tag)');
  }

  const xmpEntry = ifd.entries.get(TAG.XMP);
  const xmpPacket = xmpEntry
    ? new TextDecoder().decode(buf.subarray(xmpEntry.dataOffset, xmpEntry.dataOffset + xmpEntry.byteLength))
    : null;
  const packet = xmpPacket ?? '';
  const item = firstProfileItem(packet);

  return {
    header,
    ifd,
    identity: {
      make: readAscii(buf, ifd.entries.get(TAG.Make)),
      model: readAscii(buf, ifd.entries.get(TAG.Model)),
      uniqueCameraModel: readAscii(buf, ifd.entries.get(TAG.UniqueCameraModel)),
    },
    profiles: {
      make: readXmpProperty(item, 'stCamera:Make'),
      model: readXmpProperty(item, 'stCamera:Model'),
      uniqueCameraModel: readXmpProperty(item, 'stCamera:UniqueCameraModel'),
      cameraRawProfile: readXmpProperty(item, 'stCamera:CameraRawProfile'),
    },
    stash: {
      originalMake: readXmpProperty(packet, 'fujify:OriginalMake'),
      originalModel: readXmpProperty(packet, 'fujify:OriginalModel'),
      originalUniqueCameraModel: readXmpProperty(packet, 'fujify:OriginalUniqueCameraModel'),
      targetModel: readXmpProperty(packet, 'fujify:TargetModel'),
      version: readXmpProperty(packet, 'fujify:Version'),
    },
    xmpPacket,
  };
}

/** Contract §3.2: a file that already carries a stash keeps it, rather than having the faked identity stashed over it. */
export function hasStash(info: DngInfo): boolean {
  return info.stash.originalMake !== '';
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Users/josephsintum/code/Fujify/web && npm test -- tests/dng/identity.test.ts
```

Expected: 12 passed.

- [ ] **Step 5: Commit**

```bash
cd /Users/josephsintum/code/Fujify
git add web/src/dng/identity.ts web/tests/dng/identity.test.ts
git commit -m "Read camera identity, profile tags and the Fujify stash from a DNG"
```

---

### Task 5: `dng/xmp.ts` — rewriting the XMP packet

Pure string and byte work: takes the old packet text, returns the new packet's body and trailer, and fits it into an exact byte length using Adobe-shaped padding. No TIFF knowledge.

**Files:**
- Create: `web/src/dng/xmp.ts`
- Test: `web/tests/dng/xmp.test.ts`

**Interfaces:**
- Consumes: `CameraIdentity` from Task 4
- Produces:

```ts
export interface TargetCamera { make: string; model: string; uniqueCameraModel: string }
export const NS: { photoshop: string; stCamera: string; fujify: string };
export const EMPTY_PACKET: string;
export function encodeEntities(s: string): string;
export function rewriteXmp(oldPacket: string, target: TargetCamera, original: CameraIdentity, keepStash: boolean): { body: string; trailer: string };
export function fitPacket(body: string, trailer: string, exactLength: number): Uint8Array | null;
export function freshPacket(body: string, trailer: string, padBytes?: number): Uint8Array;
```

- [ ] **Step 1: Write the failing tests**

Create `web/tests/dng/xmp.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { EMPTY_PACKET, NS, fitPacket, freshPacket, rewriteXmp } from '../../src/dng/xmp';
import { readXmpProperty } from '../../src/dng/identity';
import { xmpPacket } from '../helpers/synth';

const XT5 = { make: 'FUJIFILM', model: 'X-T5', uniqueCameraModel: 'Fujifilm X-T5' };
const X100VI = { make: 'FUJIFILM', model: 'X100VI', uniqueCameraModel: 'Fujifilm X100VI' };
const SONY = { make: 'SONY', model: 'ILCE-7S', uniqueCameraModel: 'Sony ILCE-7S' };

describe('rewriteXmp', () => {
  it('writes the four profile values and the five stash values', () => {
    const { body } = rewriteXmp(xmpPacket(4096), XT5, SONY, false);
    expect(readXmpProperty(body, 'stCamera:Make')).toBe('FUJIFILM');
    expect(readXmpProperty(body, 'stCamera:Model')).toBe('X-T5');
    expect(readXmpProperty(body, 'stCamera:UniqueCameraModel')).toBe('Fujifilm X-T5');
    expect(readXmpProperty(body, 'stCamera:CameraRawProfile')).toBe('True');
    expect(readXmpProperty(body, 'fujify:OriginalMake')).toBe('SONY');
    expect(readXmpProperty(body, 'fujify:OriginalModel')).toBe('ILCE-7S');
    expect(readXmpProperty(body, 'fujify:OriginalUniqueCameraModel')).toBe('Sony ILCE-7S');
    expect(readXmpProperty(body, 'fujify:TargetModel')).toBe('X-T5');
    expect(readXmpProperty(body, 'fujify:Version')).toBe('1');
  });

  it('declares the three namespaces with the exact contract URIs', () => {
    const { body } = rewriteXmp(xmpPacket(4096), XT5, SONY, false);
    expect(body).toContain(`xmlns:photoshop="${NS.photoshop}"`);
    expect(body).toContain(`xmlns:stCamera="${NS.stCamera}"`);
    expect(body).toContain(`xmlns:fujify="${NS.fujify}"`);
    expect(NS.stCamera).toBe('http://ns.adobe.com/photoshop/1.0/camera-profile');
    expect(NS.fujify).toBe('https://josephsintum.dev/ns/fujify/1.0/');
  });

  it('does not declare a namespace the packet already declares', () => {
    const declared = xmpPacket(64).replace(
      'xmlns:tiff=',
      `xmlns:photoshop="${NS.photoshop}"\n    xmlns:tiff=`,
    );
    const { body } = rewriteXmp(declared, XT5, SONY, false);
    expect(body.match(/xmlns:photoshop=/g)).toHaveLength(1);
  });

  it('keeps the trailer, which declares the packet writable in place', () => {
    const { trailer } = rewriteXmp(xmpPacket(4096), XT5, SONY, false);
    expect(trailer).toBe("<?xpacket end='w'?>");
  });

  it('replaces an existing CameraProfiles block rather than adding a second', () => {
    const once = rewriteXmp(xmpPacket(4096), XT5, SONY, false);
    const twice = rewriteXmp(once.body, X100VI, SONY, true);
    expect(twice.body.match(/<photoshop:CameraProfiles>/g)).toHaveLength(1);
    expect(readXmpProperty(twice.body, 'stCamera:Model')).toBe('X100VI');
    expect(readXmpProperty(twice.body, 'stCamera:UniqueCameraModel')).toBe('Fujifilm X100VI');
  });

  it('keeps the original stash on a second pass and updates only TargetModel', () => {
    const once = rewriteXmp(xmpPacket(4096), XT5, SONY, false);
    // Second pass reads the already-faked identity, and must not stash it.
    const twice = rewriteXmp(once.body, X100VI, { make: 'FUJIFILM', model: 'X-T5', uniqueCameraModel: 'Fujifilm X-T5' }, true);
    expect(readXmpProperty(twice.body, 'fujify:OriginalMake')).toBe('SONY');
    expect(readXmpProperty(twice.body, 'fujify:OriginalUniqueCameraModel')).toBe('Sony ILCE-7S');
    expect(readXmpProperty(twice.body, 'fujify:TargetModel')).toBe('X100VI');
    expect(twice.body.match(/<fujify:TargetModel>/g)).toHaveLength(1);
    expect(twice.body.match(/<fujify:OriginalMake>/g)).toHaveLength(1);
  });

  it('escapes XML metacharacters in a user-added camera name', () => {
    const odd = { make: 'FUJIFILM', model: 'X&<T>5', uniqueCameraModel: 'Fujifilm X&<T>5' };
    const { body } = rewriteXmp(xmpPacket(4096), odd, SONY, false);
    expect(body).toContain('<stCamera:Model>X&amp;&lt;T&gt;5</stCamera:Model>');
    expect(readXmpProperty(body, 'stCamera:Model')).toBe('X&<T>5');
  });

  it('handles a self-closing rdf:Description', () => {
    const selfClosing =
      `<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>\n` +
      `<x:xmpmeta xmlns:x="adobe:ns:meta/">\n <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n` +
      `  <rdf:Description rdf:about=""/>\n </rdf:RDF>\n</x:xmpmeta>\n<?xpacket end='w'?>`;
    const { body } = rewriteXmp(selfClosing, XT5, SONY, false);
    expect(readXmpProperty(body, 'stCamera:Model')).toBe('X-T5');
    expect(body).toContain('</rdf:Description>');
  });

  it('builds a packet from EMPTY_PACKET when the file had none', () => {
    const { body, trailer } = rewriteXmp(EMPTY_PACKET, XT5, SONY, false);
    expect(readXmpProperty(body, 'stCamera:UniqueCameraModel')).toBe('Fujifilm X-T5');
    expect(trailer).toBe("<?xpacket end='w'?>");
  });

  it('rejects a packet with no x:xmpmeta', () => {
    expect(() => rewriteXmp('<not-xmp/>', XT5, SONY, false)).toThrow(/xmpmeta/);
  });
});

describe('fitPacket', () => {
  it('returns a buffer of exactly the requested length', () => {
    const { body, trailer } = rewriteXmp(xmpPacket(4096), XT5, SONY, false);
    const out = fitPacket(body, trailer, 4096 + 1000)!;
    expect(out).not.toBeNull();
    expect(out.byteLength).toBe(4096 + 1000);
  });

  it('ends with the trailer so readers see a terminated packet', () => {
    const { body, trailer } = rewriteXmp(xmpPacket(4096), XT5, SONY, false);
    const out = fitPacket(body, trailer, 6000)!;
    const text = new TextDecoder().decode(out);
    expect(text.endsWith(trailer)).toBe(true);
    expect(readXmpProperty(text, 'stCamera:Model')).toBe('X-T5');
  });

  it('pads with spaces and a newline every 101st byte, as Adobe does', () => {
    const out = fitPacket('<a/>', '<?xpacket end=\'w\'?>', 400)!;
    const text = new TextDecoder().decode(out);
    const pad = text.slice('<a/>'.length, 400 - "<?xpacket end='w'?>".length);
    expect(pad).toMatch(/^[ \n]+$/);
    expect(pad.split('\n').length).toBeGreaterThan(1);
  });

  it('returns null when the content cannot fit even with no padding', () => {
    const { body, trailer } = rewriteXmp(xmpPacket(4096), XT5, SONY, false);
    expect(fitPacket(body, trailer, 10)).toBeNull();
  });

  it('fits exactly when the length is body + trailer with no room to spare', () => {
    const body = '<a/>';
    const trailer = "<?xpacket end='w'?>";
    const exact = body.length + trailer.length;
    expect(fitPacket(body, trailer, exact)).not.toBeNull();
    expect(fitPacket(body, trailer, exact - 1)).toBeNull();
  });
});

describe('freshPacket', () => {
  it('adds its own padding so a later pass can edit in place', () => {
    const { body, trailer } = rewriteXmp(xmpPacket(0), XT5, SONY, false);
    const out = freshPacket(body, trailer);
    const text = new TextDecoder().decode(out);
    expect(out.byteLength).toBeGreaterThan(body.length + trailer.length + 2000);
    expect(text.endsWith(trailer)).toBe(true);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/josephsintum/code/Fujify/web && npm test -- tests/dng/xmp.test.ts
```

Expected: FAIL — cannot resolve `../../src/dng/xmp`.

- [ ] **Step 3: Write the implementation**

Create `web/src/dng/xmp.ts`:

```ts
// Rewrites XMP packet text to carry the Fujify camera identity, and fits the
// result into an exact byte length. Pure strings and bytes; no TIFF knowledge.
//
// The four CameraProfiles* tags of PIPELINE-CONTRACT.md §3.1 are not binary TIFF
// tags at all: exiftool flattens them into a photoshop:CameraProfiles structure
// here. The stash of §3.2 is a custom namespace in the same packet.

import type { CameraIdentity } from './identity';

export interface TargetCamera {
  make: string;
  model: string;
  uniqueCameraModel: string;
}

/** Exactly what exiftool writes. A different URI is a different tag. */
export const NS = {
  photoshop: 'http://ns.adobe.com/photoshop/1.0/',
  stCamera: 'http://ns.adobe.com/photoshop/1.0/camera-profile',
  fujify: 'https://josephsintum.dev/ns/fujify/1.0/',
} as const;

const TRAILER = "<?xpacket end='w'?>";

/** A minimal packet to build on when the DNG carries no XMP tag at all. */
export const EMPTY_PACKET =
  `<?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>\n` +
  `<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Fujify">\n` +
  ` <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n` +
  `  <rdf:Description rdf:about="">\n` +
  `  </rdf:Description>\n` +
  ` </rdf:RDF>\n` +
  `</x:xmpmeta>\n` +
  TRAILER;

export function encodeEntities(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

/**
 * Returns the new packet's body (everything up to and including </x:xmpmeta>) and
 * its trailer. Padding is not this function's business — see fitPacket/freshPacket.
 *
 * `keepStash` is the §3.2 rule: a file processed before keeps the identity it was
 * born with, rather than having the already-faked one stashed over it.
 */
export function rewriteXmp(
  oldPacket: string,
  target: TargetCamera,
  original: CameraIdentity,
  keepStash: boolean,
): { body: string; trailer: string } {
  const metaClose = '</x:xmpmeta>';
  const metaEnd = oldPacket.lastIndexOf(metaClose);
  if (metaEnd < 0) throw new Error('XMP packet has no </x:xmpmeta>');

  const trailerAt = oldPacket.lastIndexOf('<?xpacket end');
  const trailer = trailerAt > metaEnd ? oldPacket.slice(trailerAt) : TRAILER;
  let body = oldPacket.slice(0, metaEnd + metaClose.length);

  const descOpen = body.indexOf('<rdf:Description');
  if (descOpen < 0) throw new Error('XMP packet has no rdf:Description');

  // A self-closing Description has nowhere to put child elements; give it a body.
  const descOpenEnd = body.indexOf('>', descOpen);
  if (body[descOpenEnd - 1] === '/') {
    body = `${body.slice(0, descOpenEnd - 1)}>\n  </rdf:Description>${body.slice(descOpenEnd + 1)}`;
  }

  // Declare only what is missing, so we never duplicate Adobe's own declarations.
  let decls = '';
  for (const [prefix, uri] of Object.entries(NS)) {
    if (!new RegExp(`xmlns:${prefix}\\s*=`).test(body)) decls += `\n    xmlns:${prefix}="${uri}"`;
  }
  if (decls) {
    const at = descOpen + '<rdf:Description'.length;
    body = body.slice(0, at) + decls + body.slice(at);
  }

  // Drop the blocks we own before rewriting them, so a re-run replaces rather than repeats.
  body = body.replace(/[ \t]*<photoshop:CameraProfiles>[\s\S]*?<\/photoshop:CameraProfiles>[ \t]*\r?\n?/g, '');
  body = body.replace(/[ \t]*<fujify:TargetModel>[\s\S]*?<\/fujify:TargetModel>[ \t]*\r?\n?/g, '');

  const e = encodeEntities;
  const profiles =
    `   <photoshop:CameraProfiles>\n` +
    `    <rdf:Seq>\n` +
    `     <rdf:li rdf:parseType="Resource">\n` +
    `      <stCamera:CameraRawProfile>True</stCamera:CameraRawProfile>\n` +
    `      <stCamera:Make>${e(target.make)}</stCamera:Make>\n` +
    `      <stCamera:Model>${e(target.model)}</stCamera:Model>\n` +
    `      <stCamera:UniqueCameraModel>${e(target.uniqueCameraModel)}</stCamera:UniqueCameraModel>\n` +
    `     </rdf:li>\n` +
    `    </rdf:Seq>\n` +
    `   </photoshop:CameraProfiles>\n`;

  const stash = keepStash
    ? ''
    : `   <fujify:OriginalMake>${e(original.make)}</fujify:OriginalMake>\n` +
      `   <fujify:OriginalModel>${e(original.model)}</fujify:OriginalModel>\n` +
      `   <fujify:OriginalUniqueCameraModel>${e(original.uniqueCameraModel)}</fujify:OriginalUniqueCameraModel>\n` +
      `   <fujify:Version>1</fujify:Version>\n`;

  const targetModel = `   <fujify:TargetModel>${e(target.model)}</fujify:TargetModel>\n`;

  const descClose = body.indexOf('</rdf:Description>');
  if (descClose < 0) throw new Error('XMP packet has no </rdf:Description>');
  return { body: body.slice(0, descClose) + profiles + stash + targetModel + body.slice(descClose), trailer };
}

/** Adobe's padding shape: runs of 100 spaces separated by newlines. */
function padding(length: number): Uint8Array {
  const out = new Uint8Array(length).fill(0x20);
  for (let i = 100; i < length; i += 101) out[i] = 0x0a;
  return out;
}

/**
 * Encodes body + padding + trailer into exactly `exactLength` bytes, or returns null
 * when it cannot fit. Fitting exactly is what lets the packet be overwritten in place
 * without touching the IFD entry or moving a single other byte in the file.
 */
export function fitPacket(body: string, trailer: string, exactLength: number): Uint8Array | null {
  const enc = new TextEncoder();
  const bodyBytes = enc.encode(body);
  const trailerBytes = enc.encode(trailer);
  const room = exactLength - bodyBytes.byteLength - trailerBytes.byteLength;
  if (room < 0) return null;

  const out = new Uint8Array(exactLength);
  out.set(bodyBytes, 0);
  out.set(padding(room), bodyBytes.byteLength);
  out.set(trailerBytes, exactLength - trailerBytes.byteLength);
  return out;
}

/** A packet with room to spare, for when the old one cannot hold the new content. */
export function freshPacket(body: string, trailer: string, padBytes = 2048): Uint8Array {
  const enc = new TextEncoder();
  const length = enc.encode(body).byteLength + padBytes + enc.encode(trailer).byteLength;
  // fitPacket cannot fail here: the length was computed from the same strings.
  return fitPacket(body, trailer, length)!;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Users/josephsintum/code/Fujify/web && npm test -- tests/dng/xmp.test.ts
```

Expected: 16 passed.

- [ ] **Step 5: Commit**

```bash
cd /Users/josephsintum/code/Fujify
git add web/src/dng/xmp.ts web/tests/dng/xmp.test.ts
git commit -m "Rewrite the XMP packet inside its own padding"
```

---

### Task 6: `dng/patch.ts` — planning and applying the byte edits

The module everything else is for. Decides, per tag, whether the new value fits where the old one lived or has to be appended, and — only when a tag must be *added* — relocates IFD0 to the end of the file.

**Files:**
- Create: `web/src/dng/patch.ts`
- Test: `web/tests/dng/patch.test.ts`

**Interfaces:**
- Consumes: Tasks 3–5 (`readIfd0`, `readDng`, `hasStash`, `rewriteXmp`, `fitPacket`, `freshPacket`, `EMPTY_PACKET`, `TAG`, `view`)
- Produces:

```ts
export interface PatchEdit { offset: number; bytes: Uint8Array }
export interface PatchPlan { edits: PatchEdit[]; append: Uint8Array | null; outputLength: number; relocatedIfd: boolean }
export function planPatch(buf: Uint8Array, target: TargetCamera): PatchPlan;
export function applyPlan(buf: Uint8Array, plan: PatchPlan): Uint8Array;
export function isAlreadyTagged(buf: Uint8Array, target: TargetCamera): boolean;
```

`append` starts at exactly `buf.byteLength` — any word-alignment pad is baked in as leading zero bytes, so a sink writes it at the old EOF without arithmetic. `outputLength === buf.byteLength + (append?.byteLength ?? 0)`.

- [ ] **Step 1: Write the failing tests**

Create `web/tests/dng/patch.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { applyPlan, isAlreadyTagged, planPatch } from '../../src/dng/patch';
import { hasStash, readDng } from '../../src/dng/identity';
import { NotADngError, TAG, readHeader, readIfd0 } from '../../src/dng/tiff';
import { synthDng, xmpPacket } from '../helpers/synth';

const XT5 = { make: 'FUJIFILM', model: 'X-T5', uniqueCameraModel: 'Fujifilm X-T5' };
const X100VI = { make: 'FUJIFILM', model: 'X100VI', uniqueCameraModel: 'Fujifilm X100VI' };

const patched = (buf: Uint8Array, target = XT5) => applyPlan(buf, planPatch(buf, target));

describe('planPatch — the happy path', () => {
  it('writes the identity so it reads back', () => {
    const out = patched(synthDng());
    const info = readDng(out);
    expect(info.identity.uniqueCameraModel).toBe('Fujifilm X-T5');
    expect(info.profiles).toEqual({
      make: 'FUJIFILM', model: 'X-T5', uniqueCameraModel: 'Fujifilm X-T5', cameraRawProfile: 'True',
    });
  });

  it('stashes the identity the file was born with', () => {
    const out = patched(synthDng());
    expect(readDng(out).stash).toEqual({
      originalMake: 'SONY',
      originalModel: 'ILCE-7S',
      originalUniqueCameraModel: 'Sony ILCE-7S',
      targetModel: 'X-T5',
      version: '1',
    });
  });

  it('edits the XMP in place when the padding has room, appending only the longer string', () => {
    const buf = synthDng();                       // 4096 bytes of padding
    const plan = planPatch(buf, XT5);
    expect(plan.relocatedIfd).toBe(false);
    // 'Fujifilm X-T5\0' is longer than 'Sony ILCE-7S\0', so only that goes to EOF.
    expect(plan.append).not.toBeNull();
    expect(plan.append!.byteLength).toBeLessThan(64);
    expect(plan.outputLength).toBeLessThan(buf.byteLength + 64);
  });

  it('overwrites UniqueCameraModel in place when the new value is no longer', () => {
    const buf = synthDng({ uniqueCameraModel: 'A very long original camera model name' });
    const plan = planPatch(buf, XT5);
    expect(plan.append).toBeNull();
    expect(plan.outputLength).toBe(buf.byteLength);
    expect(readDng(applyPlan(buf, plan)).identity.uniqueCameraModel).toBe('Fujifilm X-T5');
  });

  it('leaves every byte outside the edits untouched', () => {
    const buf = synthDng({ trailingBytes: 32 });
    const plan = planPatch(buf, XT5);
    const out = applyPlan(buf, plan);
    const touched = new Set<number>();
    for (const e of plan.edits) for (let i = 0; i < e.bytes.byteLength; i++) touched.add(e.offset + i);
    for (let i = 0; i < buf.byteLength; i++) {
      if (!touched.has(i)) expect(out[i]).toBe(buf[i]);
    }
  });

  it('works in big-endian files', () => {
    const out = patched(synthDng({ littleEndian: false }));
    const info = readDng(out);
    expect(info.header.littleEndian).toBe(false);
    expect(info.identity.uniqueCameraModel).toBe('Fujifilm X-T5');
    expect(info.profiles.model).toBe('X-T5');
  });
});

describe('planPatch — the append fallback', () => {
  it('appends a fresh packet when the padding cannot hold the new content', () => {
    const buf = synthDng({ xmp: xmpPacket(0) });   // no padding at all
    const plan = planPatch(buf, XT5);
    expect(plan.append!.byteLength).toBeGreaterThan(1000);
    expect(plan.relocatedIfd).toBe(false);
    const out = applyPlan(buf, plan);
    expect(readDng(out).profiles.model).toBe('X-T5');
    expect(readDng(out).identity.uniqueCameraModel).toBe('Fujifilm X-T5');
  });

  it('repoints the XMP entry at the appended packet', () => {
    const buf = synthDng({ xmp: xmpPacket(0) });
    const out = patched(buf);
    const entry = readIfd0(out, readHeader(out)).entries.get(TAG.XMP)!;
    expect(entry.dataOffset).toBeGreaterThanOrEqual(buf.byteLength);
  });

  it('leaves the appended packet with padding, so a third pass fits in place', () => {
    const once = patched(synthDng({ xmp: xmpPacket(0) }));
    const plan = planPatch(once, X100VI);
    expect(plan.append).toBeNull();
    expect(plan.outputLength).toBe(once.byteLength);
  });
});

describe('planPatch — adding a missing tag', () => {
  it('relocates IFD0 when the file has no XMP tag', () => {
    const buf = synthDng({ xmp: null });
    const plan = planPatch(buf, XT5);
    expect(plan.relocatedIfd).toBe(true);
    const out = applyPlan(buf, plan);
    const ifd = readIfd0(out, readHeader(out));
    expect(ifd.offset).toBeGreaterThanOrEqual(buf.byteLength);
    expect(ifd.count).toBe(5);
    expect(readDng(out).profiles.model).toBe('X-T5');
    expect(readDng(out).identity.uniqueCameraModel).toBe('Fujifilm X-T5');
  });

  it('keeps every pre-existing entry valid after relocating', () => {
    const buf = synthDng({ xmp: null, make: 'NIKON CORPORATION', model: 'Z 6' });
    const out = patched(buf);
    const info = readDng(out);
    expect(info.identity.make).toBe('NIKON CORPORATION');
    expect(info.identity.model).toBe('Z 6');
    expect(info.ifd.entries.has(TAG.DNGVersion)).toBe(true);
  });

  it('keeps the relocated IFD0 in ascending tag order', () => {
    const out = patched(synthDng({ xmp: null }));
    const ifd = readIfd0(out, readHeader(out));
    const tags = [...ifd.entries.keys()];
    expect(tags).toEqual([...tags].sort((a, b) => a - b));
  });

  it('relocates when UniqueCameraModel is missing too', () => {
    const buf = synthDng({ uniqueCameraModel: null });
    const plan = planPatch(buf, XT5);
    expect(plan.relocatedIfd).toBe(true);
    expect(readDng(applyPlan(buf, plan)).identity.uniqueCameraModel).toBe('Fujifilm X-T5');
  });

  it('relocates once when both tags are missing', () => {
    const buf = synthDng({ uniqueCameraModel: null, xmp: null });
    const out = patched(buf);
    const ifd = readIfd0(out, readHeader(out));
    expect(ifd.count).toBe(5);
    const info = readDng(out);
    expect(info.identity.uniqueCameraModel).toBe('Fujifilm X-T5');
    expect(info.profiles.uniqueCameraModel).toBe('Fujifilm X-T5');
  });
});

describe('planPatch — second passes', () => {
  it('re-tagging to another target keeps the original stash', () => {
    const once = patched(synthDng(), XT5);
    const twice = patched(once, X100VI);
    const info = readDng(twice);
    expect(info.identity.uniqueCameraModel).toBe('Fujifilm X100VI');
    expect(info.profiles.model).toBe('X100VI');
    expect(info.stash.originalMake).toBe('SONY');
    expect(info.stash.originalUniqueCameraModel).toBe('Sony ILCE-7S');
    expect(info.stash.targetModel).toBe('X100VI');
    expect(hasStash(info)).toBe(true);
  });

  it('grows by at most one string per pass, never by a packet', () => {
    // Each pass shortens the UniqueCameraModel count to the exact string length, so
    // alternating a longer target with a shorter one appends the longer string again.
    // That is bounded and tiny; what must never happen is a fresh XMP packet (~2 KB)
    // being appended on every pass, which would mean the padding path had broken.
    let buf = synthDng();
    const before = buf.byteLength;
    for (let i = 0; i < 6; i++) buf = patched(buf, i % 2 ? XT5 : X100VI);
    expect(buf.byteLength - before).toBeLessThan(6 * 32);
  });
});

describe('isAlreadyTagged', () => {
  it('is false for an untouched file', () => {
    expect(isAlreadyTagged(synthDng(), XT5)).toBe(false);
  });

  it('is true when all three profile values match the target', () => {
    expect(isAlreadyTagged(patched(synthDng(), XT5), XT5)).toBe(true);
  });

  it('is false when the file carries a different target — contract §9', () => {
    expect(isAlreadyTagged(patched(synthDng(), XT5), X100VI)).toBe(false);
  });
});

describe('planPatch — rejections', () => {
  it('refuses a file that is not a DNG', () => {
    expect(() => planPatch(new TextEncoder().encode('hello world, not a dng'), XT5)).toThrow(NotADngError);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd /Users/josephsintum/code/Fujify/web && npm test -- tests/dng/patch.test.ts
```

Expected: FAIL — cannot resolve `../../src/dng/patch`.

- [ ] **Step 3: Write the implementation**

Create `web/src/dng/patch.ts`:

```ts
// Turns "tag this DNG as a Fujifilm X-T5" into a list of byte edits.
//
// The rule that makes this safe: no existing byte is ever moved. A value either
// fits where the old one lived, or it is appended at EOF and its IFD entry is
// repointed. SubIFDs, MakerNotes, previews and the embedded original all hold
// absolute offsets, and all of them stay valid because nothing shifts.
//
// The single exception is a tag that does not exist yet and so needs a new IFD0
// entry. IFD0 then has to grow, so a copy of it goes at EOF and the header's
// IFD0 pointer is repointed. Existing entries are copied verbatim, offsets and all.

import { type DngInfo, hasStash, readDng } from './identity';
import { TAG, view } from './tiff';
import { EMPTY_PACKET, type TargetCamera, fitPacket, freshPacket, rewriteXmp } from './xmp';

export interface PatchEdit {
  offset: number;
  bytes: Uint8Array;
}

export interface PatchPlan {
  /** Overwrites, all within the original file's length. */
  edits: PatchEdit[];
  /** Bytes to write at exactly the original EOF, or null. Alignment padding is included. */
  append: Uint8Array | null;
  outputLength: number;
  relocatedIfd: boolean;
}

/** What a tag's value should end up being, and where. */
interface Placement {
  tag: number;
  type: number;
  /** Value length in bytes, which for our ASCII and BYTE tags is also the TIFF count. */
  count: number;
  /** Absolute file offset of the value bytes once the plan is applied. */
  dataOffset: number;
}

class Appender {
  private readonly chunks: { at: number; bytes: Uint8Array }[] = [];
  private cursor: number;

  constructor(private readonly start: number) {
    // TIFF values are word-aligned by convention; keep that up for anything we add.
    this.cursor = start + (start & 1);
  }

  push(bytes: Uint8Array): number {
    const at = this.cursor;
    this.chunks.push({ at, bytes });
    this.cursor += bytes.byteLength + (bytes.byteLength & 1);
    return at;
  }

  /** One buffer starting at the original EOF, with alignment gaps as zero bytes. */
  build(): Uint8Array | null {
    if (this.chunks.length === 0) return null;
    const out = new Uint8Array(this.cursor - this.start);
    for (const { at, bytes } of this.chunks) out.set(bytes, at - this.start);
    return out;
  }
}

function u32(value: number, littleEndian: boolean): Uint8Array {
  const out = new Uint8Array(4);
  new DataView(out.buffer).setUint32(0, value, littleEndian);
  return out;
}

/** The new UniqueCameraModel value, and where it will live. */
function placeUniqueCameraModel(
  info: DngInfo,
  target: TargetCamera,
  appender: Appender,
  edits: PatchEdit[],
): Placement {
  const bytes = new TextEncoder().encode(`${target.uniqueCameraModel}\0`);
  const existing = info.ifd.entries.get(TAG.UniqueCameraModel);

  if (existing && !existing.inline && bytes.byteLength <= existing.byteLength) {
    // Fits where it is: overwrite and NUL-pad the rest, then shorten the count.
    const padded = new Uint8Array(existing.byteLength);
    padded.set(bytes);
    edits.push({ offset: existing.dataOffset, bytes: padded });
    return { tag: TAG.UniqueCameraModel, type: 2, count: bytes.byteLength, dataOffset: existing.dataOffset };
  }

  return { tag: TAG.UniqueCameraModel, type: 2, count: bytes.byteLength, dataOffset: appender.push(bytes) };
}

/** The new XMP packet, and where it will live. */
function placeXmp(
  info: DngInfo,
  target: TargetCamera,
  appender: Appender,
  edits: PatchEdit[],
): Placement {
  const { body, trailer } = rewriteXmp(
    info.xmpPacket ?? EMPTY_PACKET,
    target,
    info.identity,
    hasStash(info),
  );
  const existing = info.ifd.entries.get(TAG.XMP);

  if (existing && !existing.inline) {
    const fitted = fitPacket(body, trailer, existing.byteLength);
    if (fitted) {
      // The whole point: the packet's padding absorbs the change, so the file
      // differs from the original by a few hundred bytes in the middle and nothing else.
      edits.push({ offset: existing.dataOffset, bytes: fitted });
      return { tag: TAG.XMP, type: existing.type, count: existing.byteLength, dataOffset: existing.dataOffset };
    }
  }

  const packet = freshPacket(body, trailer);
  return { tag: TAG.XMP, type: 1, count: packet.byteLength, dataOffset: appender.push(packet) };
}

/**
 * Builds a replacement IFD0 at EOF with `placements` merged in, for the case where a
 * tag has to be added. Existing entries are copied byte for byte — their offsets are
 * absolute and the data they point at has not moved.
 *
 * Returns the absolute offset the new IFD0 landed at.
 */
function relocateIfd0(
  buf: Uint8Array,
  info: DngInfo,
  placements: Placement[],
  appender: Appender,
  littleEndian: boolean,
): number {
  const byTag = new Map<number, Uint8Array>();

  for (const entry of info.ifd.entries.values()) {
    byTag.set(entry.tag, buf.slice(entry.entryOffset, entry.entryOffset + 12));
  }

  for (const p of placements) {
    const record = new Uint8Array(12);
    const dv = new DataView(record.buffer);
    dv.setUint16(0, p.tag, littleEndian);
    dv.setUint16(2, p.type, littleEndian);
    dv.setUint32(4, p.count, littleEndian);
    dv.setUint32(8, p.dataOffset, littleEndian);
    byTag.set(p.tag, record);
  }

  const tags = [...byTag.keys()].sort((a, b) => a - b);
  const ifd = new Uint8Array(2 + tags.length * 12 + 4);
  const dv = new DataView(ifd.buffer);
  dv.setUint16(0, tags.length, littleEndian);
  tags.forEach((tag, i) => ifd.set(byTag.get(tag)!, 2 + i * 12));
  // Preserve the chain: whatever IFD0 pointed at next still lives where it did.
  const next = view(buf).getUint32(info.ifd.nextIfdPointerOffset, littleEndian);
  dv.setUint32(2 + tags.length * 12, next, littleEndian);

  return appender.push(ifd);
}

export function planPatch(buf: Uint8Array, target: TargetCamera): PatchPlan {
  const info = readDng(buf);
  const le = info.header.littleEndian;
  const edits: PatchEdit[] = [];
  const appender = new Appender(buf.byteLength);

  const placements = [
    placeUniqueCameraModel(info, target, appender, edits),
    placeXmp(info, target, appender, edits),
  ];

  const missing = placements.filter((p) => !info.ifd.entries.has(p.tag));

  if (missing.length > 0) {
    // IFD0 must grow. Rebuild it at EOF with every placement written fresh, since the
    // old IFD0 becomes dead bytes and editing it would have no effect.
    const ifdOffset = relocateIfd0(buf, info, placements, appender, le);
    const append = appender.build();
    edits.push({ offset: 4, bytes: u32(ifdOffset, le) });
    return {
      edits,
      append,
      outputLength: buf.byteLength + append!.byteLength,
      relocatedIfd: true,
    };
  }

  // Every tag already has an entry: update count and value offset in each one.
  for (const p of placements) {
    const entry = info.ifd.entries.get(p.tag)!;
    const record = new Uint8Array(8);
    const dv = new DataView(record.buffer);
    dv.setUint32(0, p.count, le);
    dv.setUint32(4, p.dataOffset, le);
    edits.push({ offset: entry.entryOffset + 4, bytes: record });
  }

  const append = appender.build();
  return {
    edits,
    append,
    outputLength: buf.byteLength + (append?.byteLength ?? 0),
    relocatedIfd: false,
  };
}

/** Applies a plan to a copy of the buffer. Used by tests and the in-memory output sinks. */
export function applyPlan(buf: Uint8Array, plan: PatchPlan): Uint8Array {
  const out = new Uint8Array(plan.outputLength);
  out.set(buf, 0);
  if (plan.append) out.set(plan.append, buf.byteLength);
  for (const { offset, bytes } of plan.edits) out.set(bytes, offset);
  return out;
}

/**
 * Contract §9: skip only when the file already carries *this* target's identity.
 * A file tagged X-T5 is not skipped when the target is X100VI — re-tagging a batch
 * to pick up Reala Ace is exactly why the target picker exists.
 */
export function isAlreadyTagged(buf: Uint8Array, target: TargetCamera): boolean {
  const { profiles } = readDng(buf);
  return (
    profiles.make === target.make &&
    profiles.model === target.model &&
    profiles.uniqueCameraModel === target.uniqueCameraModel
  );
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd /Users/josephsintum/code/Fujify/web && npm test
```

Expected: every suite green — 20 in `patch.test.ts` and the earlier 48 still passing (7 synth + 13 tiff + 12 identity + 16 xmp). If the relocation offset arithmetic in `planPatch` is off, the `relocates IFD0` test fails on `ifd.offset`; the appended IFD is the last chunk, so its offset is `outputLength - ifdByteLength`.

- [ ] **Step 5: Add a type check and commit**

```bash
cd /Users/josephsintum/code/Fujify/web && npx tsc --noEmit
```

Expected: no output.

```bash
cd /Users/josephsintum/code/Fujify
git add web/src/dng/patch.ts web/tests/dng/patch.test.ts
git commit -m "Plan and apply the byte edits that retag a DNG"
```

---

### Task 7: Golden verification against a real DNG

Everything so far is verified against synthetic files. This task proves the patcher on a real Adobe-written DNG, using the same `tools/verify-dng.sh` the macOS app is held to, and compares a full exiftool dump against an exiftool-written file.

**Files:**
- Create: `web/tests/golden.test.ts`
- Create: `web/tests/helpers/fixtures.ts`
- Modify: `web/package.json` (add `test:golden`)

**Interfaces:**
- Consumes: `planPatch`, `applyPlan` from Task 6; `fixtures/sample.dng`; `tools/verify-dng.sh`; `tools/exiftool-fujify.config` from Task 1
- Produces: nothing other tasks depend on — this is the acceptance gate

- [ ] **Step 1: Write the fixture helper**

Create `web/tests/helpers/fixtures.ts`:

```ts
// Locates the real-DNG fixture and the shared tools. Everything here is optional:
// fixtures/ is gitignored and sample.dng is built locally by tools/fetch-fixtures.sh,
// so tests that need them skip rather than fail on a fresh clone or in CI.

import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
export const repoRoot = resolve(here, '../../..');
export const sampleDng = resolve(repoRoot, 'fixtures/sample.dng');
export const verifyScript = resolve(repoRoot, 'tools/verify-dng.sh');
export const exiftoolConfig = resolve(repoRoot, 'tools/exiftool-fujify.config');

export const hasFixture = existsSync(sampleDng);

export const hasExiftool = (() => {
  try {
    execFileSync('exiftool', ['-ver'], { stdio: 'pipe' });
    return true;
  } catch {
    return false;
  }
})();

export const goldenReady = hasFixture && hasExiftool;

export const skipReason = !hasFixture
  ? 'fixtures/sample.dng is missing — run tools/fetch-fixtures.sh'
  : !hasExiftool
    ? 'exiftool is not on PATH — brew install exiftool'
    : '';

/** Reads tags as exiftool sees them, with the Fujify namespace config loaded. */
export function exiftoolJson(file: string): Record<string, unknown> {
  const out = execFileSync(
    'exiftool',
    ['-config', exiftoolConfig, '-j', '-G1', '-a', '-s', file],
    { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 },
  );
  return (JSON.parse(out) as Record<string, unknown>[])[0]!;
}
```

- [ ] **Step 2: Write the golden test**

Create `web/tests/golden.test.ts`:

```ts
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { beforeAll, describe, expect, it } from 'vitest';
import { applyPlan, planPatch } from '../src/dng/patch';
import { readDng } from '../src/dng/identity';
import { exiftoolConfig, exiftoolJson, goldenReady, sampleDng, skipReason, verifyScript } from './helpers/fixtures';

const XT5 = { make: 'FUJIFILM', model: 'X-T5', uniqueCameraModel: 'Fujifilm X-T5' };
const X100VI = { make: 'FUJIFILM', model: 'X100VI', uniqueCameraModel: 'Fujifilm X100VI' };

describe.skipIf(!goldenReady)(`golden verification against a real DNG`, () => {
  let dir: string;
  let source: Uint8Array;
  let webOut: string;
  let exiftoolOut: string;

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'fujify-golden-'));
    source = new Uint8Array(readFileSync(sampleDng));

    // Our output.
    webOut = join(dir, 'web.dng');
    writeFileSync(webOut, applyPlan(source, planPatch(source, XT5)));

    // The macOS app's output: the same five tags written by exiftool, per contract §3.1.
    exiftoolOut = join(dir, 'exiftool.dng');
    writeFileSync(exiftoolOut, source);
    execFileSync('exiftool', [
      '-config', exiftoolConfig,
      '-CameraProfilesMake=FUJIFILM',
      '-CameraProfilesModel=X-T5',
      '-CameraProfilesUniqueCameraModel=Fujifilm X-T5',
      '-CameraProfilesCameraRawProfile=True',
      '-UniqueCameraModel=Fujifilm X-T5',
      '-XMP-fujify:OriginalMake=SONY',
      '-XMP-fujify:OriginalModel=ILCE-7S',
      '-XMP-fujify:OriginalUniqueCameraModel=Sony ILCE-7S',
      '-XMP-fujify:TargetModel=X-T5',
      '-XMP-fujify:Version=1',
      '-overwrite_original',
      '-m',
      exiftoolOut,
    ], { stdio: 'pipe' });
  });

  it('passes tools/verify-dng.sh, the contract §12 golden test', () => {
    const out = execFileSync('sh', [verifyScript, webOut], { encoding: 'utf8' });
    expect(out).toContain('carry the FUJIFILM X-T5 identity');
  });

  it('passes verify-dng.sh for the X100VI target too', () => {
    const file = join(dir, 'web-x100vi.dng');
    writeFileSync(file, applyPlan(source, planPatch(source, X100VI)));
    const out = execFileSync('sh', [verifyScript, file, 'X100VI'], { encoding: 'utf8' });
    expect(out).toContain('carry the FUJIFILM X100VI identity');
  });

  it('reads back the same five identity values exiftool wrote', () => {
    const ours = exiftoolJson(webOut);
    const theirs = exiftoolJson(exiftoolOut);
    for (const key of [
      'XMP-photoshop:CameraProfilesMake',
      'XMP-photoshop:CameraProfilesModel',
      'XMP-photoshop:CameraProfilesUniqueCameraModel',
      'XMP-photoshop:CameraProfilesCameraRawProfile',
      'IFD0:UniqueCameraModel',
    ]) {
      expect(ours[key], key).toEqual(theirs[key]);
    }
  });

  it('reads back the same stash exiftool wrote', () => {
    const ours = exiftoolJson(webOut);
    const theirs = exiftoolJson(exiftoolOut);
    for (const key of [
      'XMP-fujify:OriginalMake',
      'XMP-fujify:OriginalModel',
      'XMP-fujify:OriginalUniqueCameraModel',
      'XMP-fujify:TargetModel',
      'XMP-fujify:Version',
    ]) {
      expect(String(ours[key]), key).toEqual(String(theirs[key]));
    }
  });

  it('introduces no new exiftool validation warnings', () => {
    const warnings = (file: string) =>
      execFileSync('exiftool', ['-validate', '-warning', '-a', '-s3', file], { encoding: 'utf8' })
        .trim().split('\n').filter(Boolean).sort();
    expect(warnings(webOut)).toEqual(warnings(sampleDng));
  });

  it('edits the XMP in place, so the file grows by only the longer model string', () => {
    const plan = planPatch(source, XT5);
    expect(plan.relocatedIfd).toBe(false);
    expect(plan.outputLength - source.byteLength).toBeLessThan(64);
  });

  it('leaves the image data untouched — only the two identity locations change', () => {
    const plan = planPatch(source, XT5);
    const out = applyPlan(source, plan);
    const touched = new Set<number>();
    for (const e of plan.edits) for (let i = 0; i < e.bytes.byteLength; i++) touched.add(e.offset + i);
    let differing = 0;
    for (let i = 0; i < source.byteLength; i++) if (out[i] !== source[i]) differing++;
    expect(differing).toBeLessThanOrEqual(touched.size);
    // StripOffsets and the preview pointers must still be where they were.
    expect(out.byteLength).toBe(plan.outputLength);
    const ours = exiftoolJson(webOut);
    const original = exiftoolJson(sampleDng);
    expect(ours['IFD0:StripOffsets']).toEqual(original['IFD0:StripOffsets']);
    expect(ours['SubIFD1:PreviewImageStart']).toEqual(original['SubIFD1:PreviewImageStart']);
  });

  it('survives a second pass to a different target with the stash intact', () => {
    const once = applyPlan(source, planPatch(source, XT5));
    const twice = applyPlan(once, planPatch(once, X100VI));
    const file = join(dir, 'web-twice.dng');
    writeFileSync(file, twice);
    const out = execFileSync('sh', [verifyScript, file, 'X100VI'], { encoding: 'utf8' });
    expect(out).toContain('carry the FUJIFILM X100VI identity');
    expect(readDng(twice).stash.originalUniqueCameraModel).toBe('Sony ILCE-7S');
  });
});

describe.skipIf(goldenReady)('golden verification', () => {
  it('is skipped', () => {
    expect(skipReason).not.toBe('');
    console.warn(`golden tests skipped: ${skipReason}`);
  });
});
```

- [ ] **Step 3: Run the golden test**

```bash
cd /Users/josephsintum/code/Fujify
ls fixtures/sample.dng >/dev/null 2>&1 || tools/fetch-fixtures.sh
cd web && npm test -- tests/golden.test.ts
```

Expected: 8 passed. If `fixtures/sample.dng` cannot be built (no Adobe DNG Converter and no dnglab), the suite skips with the reason printed — in that case say so rather than marking the task done.

- [ ] **Step 4: Run the whole suite and type check**

```bash
cd /Users/josephsintum/code/Fujify/web && npm test && npx tsc --noEmit
```

Expected: every suite green, no type errors.

- [ ] **Step 5: Commit**

```bash
cd /Users/josephsintum/code/Fujify
git add web/tests/golden.test.ts web/tests/helpers/fixtures.ts web/package.json
git commit -m "Hold the web patcher to the same golden test as the Mac app"
```

---

## Verification checklist

Run before declaring the plan complete:

```bash
cd /Users/josephsintum/code/Fujify/mac && xcodegen generate && \
  xcodebuild -project Fujify.xcodeproj -scheme Fujify -destination 'platform=macOS' test 2>&1 | tail -3
cd /Users/josephsintum/code/Fujify/web && npm test && npx tsc --noEmit && npm run build
cd /Users/josephsintum/code/Fujify && git status --short
```

Expected: `** TEST SUCCEEDED **`, all Vitest suites green including the golden ones, a clean build, and a clean working tree.

## What plan 2 picks up

- **Task 1: the UI design, on the shared design canvas, before any component is written.**
  Normative — see the spec's §9. Uses the `frontend-design` skill to make the visual
  decisions, draws a `Web*` row of 11 artboards on
  https://claude.ai/artifact/5aPDVzRTxN3kS2d7E115wL mirroring the existing `Mac*` and
  `Win*` rows, in shadcn-svelte's idiom (Bits UI + Tailwind v4) so canvas and build agree.
  `web-design-guidelines` runs afterwards, over the built UI, as a compliance review.
- `dng/worker.ts` and the Worker message protocol
- `output/` — the three sinks, atomic temp-then-rename, positioned in-place writes, capability detection
- `model/` — queue, serial batch runner, state machine, `localStorage` persistence
- `ui/` — the Svelte components, the §7 in-place confirmation, the Inspector
- Playwright E2E, the GitHub Pages workflow, the PWA shell
- The contract edits from spec §8 and the README's web section
