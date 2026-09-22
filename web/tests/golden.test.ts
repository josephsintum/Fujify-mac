import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import { beforeAll, describe, expect, it } from 'vitest';
import { applyPlan, isAlreadyTagged, planPatch } from '../src/dng/patch';
import { hasStash, readDng } from '../src/dng/identity';
import { TAG, readHeader, readIfd0, view } from '../src/dng/tiff';
import {
  exiftoolConfig,
  exiftoolJson,
  goldenReady,
  hasXmllint,
  sampleDng,
  skipReason,
  verifyScript,
} from './helpers/fixtures';

const XT5 = { make: 'FUJIFILM', model: 'X-T5', uniqueCameraModel: 'Fujifilm X-T5' };
const X100VI = { make: 'FUJIFILM', model: 'X100VI', uniqueCameraModel: 'Fujifilm X100VI' };

/** exiftool's own view of the offsets that must never move. */
const OFFSET_TAGS = ['IFD0:StripOffsets', 'SubIFD1:PreviewImageStart'] as const;

const warningsOf = (file: string) =>
  execFileSync('exiftool', ['-validate', '-warning', '-a', '-s3', file], { encoding: 'utf8' })
    .trim().split('\n').filter(Boolean).sort();

/**
 * Squeezes a real DNG's XMP packet down to its content: the trailer moves up against
 * </x:xmpmeta> and the entry's count shrinks to match, so the packet has no padding
 * left to absorb our block. sample.dng ships 6216 bytes of packet with room to spare,
 * which is why the suite otherwise only ever exercises the fit-in-place path.
 *
 * The bytes past the new count stay where they are and become unreferenced — this
 * helper is itself bound by the rule it is setting up a test for.
 */
function tightenXmp(src: Uint8Array): Uint8Array {
  const info = readDng(src);
  const entry = info.ifd.entries.get(TAG.XMP)!;
  const packet = info.xmpPacket!;
  const metaEnd = packet.lastIndexOf('</x:xmpmeta>') + '</x:xmpmeta>'.length;
  const trailerAt = packet.lastIndexOf('<?xpacket end');
  const tight = new TextEncoder().encode(`${packet.slice(0, metaEnd)}\n${packet.slice(trailerAt)}`);

  const out = new Uint8Array(src);
  out.fill(0, entry.dataOffset, entry.dataOffset + entry.byteLength);
  out.set(tight, entry.dataOffset);
  view(out).setUint32(entry.entryOffset + 4, tight.byteLength, info.header.littleEndian);
  return out;
}

describe.skipIf(!goldenReady)(`golden verification against a real DNG`, () => {
  let dir: string;
  let source: Uint8Array;
  let webOut: string;
  let exiftoolOut: string;
  let noXmpSource: string;
  let tightSource: string;

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

    // Fixtures for the two paths sample.dng cannot reach on its own. Both are derived
    // here rather than committed: fixtures/ is gitignored and exiftool is already a
    // precondition of this suite.
    noXmpSource = join(dir, 'no-xmp.dng');
    writeFileSync(noXmpSource, source);
    execFileSync('exiftool', ['-XMP:all=', '-overwrite_original', '-m', noXmpSource], { stdio: 'pipe' });

    tightSource = join(dir, 'tight-xmp.dng');
    writeFileSync(tightSource, tightenXmp(source));
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
    expect(warningsOf(webOut)).toEqual(warningsOf(sampleDng));
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
    // Every byte outside a declared edit must be identical, which is the strong form
    // patch.test.ts uses. Reporting the first offender rather than one expect() per
    // byte only keeps 7.5 million assertions out of the run; the claim is the same.
    let firstChanged = -1;
    for (let i = 0; i < source.byteLength; i++) {
      if (!touched.has(i) && out[i] !== source[i]) {
        firstChanged = i;
        break;
      }
    }
    expect(firstChanged, `byte ${firstChanged} changed but lies outside every declared edit`).toBe(-1);
    // StripOffsets and the preview pointers must still be where they were.
    expect(out.byteLength).toBe(plan.outputLength);
    const ours = exiftoolJson(webOut);
    const original = exiftoolJson(sampleDng);
    for (const tag of OFFSET_TAGS) expect(ours[tag], tag).toEqual(original[tag]);
  });

  it('reads back a file the macOS app wrote — the divergence that matters', () => {
    // Both directions of this suite otherwise compare our output and exiftool's
    // THROUGH exiftool, so the reader is never pointed at the Mac app's output. A
    // photographer who tagged on the Mac and re-tags on the web depends on this.
    const theirs = new Uint8Array(readFileSync(exiftoolOut));
    const info = readDng(theirs);

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
    expect(isAlreadyTagged(theirs, XT5)).toBe(true);
    expect(isAlreadyTagged(theirs, X100VI)).toBe(false);
  });

  it('relocates IFD0 on a real file with no XMP tag, moving no image data', () => {
    const src = new Uint8Array(readFileSync(noXmpSource));
    // If exiftool ever stops removing the tag outright, fail here rather than quietly
    // testing the fit-in-place path for a third time.
    expect(readDng(src).xmpPacket, 'the no-XMP fixture still carries an XMP tag').toBeNull();

    const plan = planPatch(src, XT5);
    expect(plan.relocatedIfd).toBe(true);

    const file = join(dir, 'relocated.dng');
    writeFileSync(file, applyPlan(src, plan));
    expect(execFileSync('sh', [verifyScript, file], { encoding: 'utf8' }))
      .toContain('carry the FUJIFILM X-T5 identity');

    const ours = exiftoolJson(file);
    const before = exiftoolJson(noXmpSource);
    for (const tag of OFFSET_TAGS) expect(ours[tag], tag).toEqual(before[tag]);
    expect(warningsOf(file)).toEqual(warningsOf(noXmpSource));
  });

  it('appends a fresh packet on a real file whose XMP has no padding left', () => {
    const src = new Uint8Array(readFileSync(tightSource));
    const plan = planPatch(src, XT5);
    expect(plan.relocatedIfd).toBe(false);
    // The tight packet cannot absorb our block, so a ~2 KB replacement goes to EOF.
    expect(plan.append!.byteLength).toBeGreaterThan(2000);

    const out = applyPlan(src, plan);
    const entry = readIfd0(out, readHeader(out)).entries.get(TAG.XMP)!;
    expect(entry.dataOffset).toBeGreaterThanOrEqual(src.byteLength);

    const file = join(dir, 'appended.dng');
    writeFileSync(file, out);
    expect(execFileSync('sh', [verifyScript, file], { encoding: 'utf8' }))
      .toContain('carry the FUJIFILM X-T5 identity');

    const ours = exiftoolJson(file);
    const before = exiftoolJson(tightSource);
    for (const tag of OFFSET_TAGS) expect(ours[tag], tag).toEqual(before[tag]);
    expect(warningsOf(file)).toEqual(warningsOf(tightSource));
  });

  it.skipIf(!hasXmllint)('writes an XMP packet a real XML parser accepts', () => {
    // assertBalanced in xmp.test.ts counts tag names only, so it cannot see a duplicate
    // attribute or an unbound prefix — exactly the two failure modes the quote-aware
    // open-tag scan and the per-element namespace check exist to prevent.
    // Built here rather than reused from another test, so this one stands alone.
    const second = join(dir, 'xmllint-x100vi.dng');
    writeFileSync(second, applyPlan(source, planPatch(source, X100VI)));

    for (const file of [webOut, second]) {
      const packet = join(dir, `${basename(file)}.xmp`);
      writeFileSync(packet, execFileSync('exiftool', ['-b', '-XMP', file], {
        encoding: 'buffer', maxBuffer: 64 * 1024 * 1024, stdio: ['pipe', 'pipe', 'ignore'],
      }));
      expect(() => execFileSync('xmllint', ['--noout', packet], { stdio: 'pipe' }), packet).not.toThrow();
    }
  });

  it.skipIf(hasXmllint)('would have checked the XMP with xmllint', () => {
    console.warn('xmllint is not on PATH — the XMP well-formedness check was skipped');
    expect(hasXmllint).toBe(false);
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
