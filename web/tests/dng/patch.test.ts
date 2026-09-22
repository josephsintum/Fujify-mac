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
    const plan = planPatch(once, XT5);
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
