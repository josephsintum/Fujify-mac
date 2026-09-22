import { describe, expect, it } from 'vitest';
import type { PatchEdit, PatchPlan } from '../../src/dng/patch';
import { applyPlan, isAlreadyTagged, planPatch, validatePlan } from '../../src/dng/patch';
import { hasStash, readDng } from '../../src/dng/identity';
import { NotADngError, TAG, readHeader, readIfd0, view } from '../../src/dng/tiff';
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

  it('word-aligns the appended value when the source file length is odd', () => {
    // trailingBytes: 33 makes buf.byteLength odd, exercising Appender's
    // start + (start & 1) branch: the first appended chunk must land one byte
    // past EOF (a leading zero gap byte), not at the odd EOF itself.
    const buf = synthDng({ trailingBytes: 33 });
    expect(buf.byteLength % 2).toBe(1);

    const plan = planPatch(buf, XT5);
    expect(plan.append).not.toBeNull(); // UniqueCameraModel always grows 13 -> 14 bytes here
    expect(plan.outputLength).toBe(buf.byteLength + plan.append!.byteLength);

    const out = applyPlan(buf, plan);
    expect(readDng(out).identity.uniqueCameraModel).toBe('Fujifilm X-T5');

    const header = readHeader(out);
    const ifd = readIfd0(out, header);
    for (const entry of ifd.entries.values()) {
      if (!entry.inline) expect(entry.dataOffset % 2).toBe(0);
    }
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

  it('leaves the appended packet with padding, so a later pass fits it in place', () => {
    const once = patched(synthDng({ xmp: xmpPacket(0) }));
    const xmpBefore = readIfd0(once, readHeader(once)).entries.get(TAG.XMP)!;
    const plan = planPatch(once, X100VI);
    // plan.append is NOT expected to be null here: pass 1 left UniqueCameraModel's
    // slot tight at exactly 14 bytes ('Fujifilm X-T5\0'), so retargeting to the
    // 16-byte 'Fujifilm X100VI\0' legitimately appends that string again. The
    // property under test is the XMP packet specifically: its padding, left over
    // from the fresh packet appended in pass 1, absorbs this pass's rewrite in
    // place rather than forcing another ~2 KB packet onto the file.
    const twice = applyPlan(once, plan);
    const xmpAfter = readIfd0(twice, readHeader(twice)).entries.get(TAG.XMP)!;

    expect(xmpAfter.dataOffset).toBe(xmpBefore.dataOffset);
    expect(xmpAfter.byteLength).toBe(xmpBefore.byteLength);
    expect(plan.append?.byteLength ?? 0).toBeLessThan(32);
    expect(readDng(twice).profiles.model).toBe('X100VI');
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

  it('carries the next-IFD pointer through relocation', () => {
    // A real DNG's next-IFD pointer is the classic TIFF slot for IFD1 (thumbnail /
    // sub-image). Relocation must not truncate that chain. The sentinel need not
    // point at a real IFD — nothing here follows it — it only has to prove the
    // value was carried over rather than silently zeroed.
    const sentinel = 0xdeadbeef;
    const buf = synthDng({ xmp: null, nextIfdOffset: sentinel });
    const plan = planPatch(buf, XT5);
    expect(plan.relocatedIfd).toBe(true);

    const out = applyPlan(buf, plan);
    const header = readHeader(out);
    const ifd = readIfd0(out, header);
    expect(view(out).getUint32(ifd.nextIfdPointerOffset, header.littleEndian)).toBe(sentinel);
  });
});

describe('planPatch — a UniqueCameraModel short enough to sit inside the IFD entry', () => {
  // TIFF stores a value of 4 bytes or fewer INSIDE the 12-byte entry, and every reader
  // — readIfd0 included — decides that from the count alone. Setting a short count
  // beside an offset makes the reader hand back the offset's bytes as the model name.
  // Contract §2 derives "Fujifilm " + model so this is unreachable today, but planPatch
  // is public and plan 2 feeds it targets out of localStorage.
  const ucmEntry = (out: Uint8Array) =>
    readIfd0(out, readHeader(out)).entries.get(TAG.UniqueCameraModel)!;
  const target = (uniqueCameraModel: string) => ({ make: 'FUJIFILM', model: 'M', uniqueCameraModel });

  // 1, 3 and 4 encoded bytes once the NUL terminator is counted.
  for (const ucm of ['', 'XT', 'X-T']) {
    it(`round-trips ${JSON.stringify(ucm)} (${ucm.length + 1} bytes) with no exiftool involved`, () => {
      const out = patched(synthDng(), target(ucm));
      const entry = ucmEntry(out);
      expect(entry.inline).toBe(true);
      expect(entry.dataOffset).toBe(entry.entryOffset + 8);
      expect(entry.count).toBe(ucm.length + 1);
      expect(readDng(out).identity.uniqueCameraModel).toBe(ucm);
    });
  }

  it('keeps a 5-byte value out of line — the other side of the boundary', () => {
    const out = patched(synthDng(), target('ABCD'));
    expect(ucmEntry(out).inline).toBe(false);
    expect(readDng(out).identity.uniqueCameraModel).toBe('ABCD');
  });

  it('goes inline even when the old out-of-line slot was big enough to reuse', () => {
    const buf = synthDng({ uniqueCameraModel: 'A very long original camera model name' });
    const out = patched(buf, target('X-T'));
    expect(ucmEntry(out).inline).toBe(true);
    expect(readDng(out).identity.uniqueCameraModel).toBe('X-T');
  });

  it('goes inline on the relocating path too', () => {
    const buf = synthDng({ uniqueCameraModel: null });
    const plan = planPatch(buf, target('X-T'));
    expect(plan.relocatedIfd).toBe(true);
    const out = applyPlan(buf, plan);
    expect(ucmEntry(out).inline).toBe(true);
    expect(readDng(out).identity.uniqueCameraModel).toBe('X-T');
  });
});

describe('validatePlan — never move a byte, enforced', () => {
  // The guarantee the whole module rests on. Without this check a regression in the
  // `bytes.byteLength <= existing.byteLength` guard would overwrite a neighbouring
  // tag's data and every other test here would still pass, because they all derive
  // what "untouched" means from plan.edits itself.
  const buf = synthDng();
  const plan = (edits: PatchEdit[], append: Uint8Array | null = null): PatchPlan => ({
    edits,
    append,
    outputLength: buf.byteLength + (append?.byteLength ?? 0),
    relocatedIfd: false,
  });
  const at = (offset: number, length: number) => ({ offset, bytes: new Uint8Array(length) });

  it('accepts what planPatch produces', () => {
    expect(() => validatePlan(buf, planPatch(buf, XT5))).not.toThrow();
  });

  it('accepts edits that abut without overlapping, in either order', () => {
    expect(() => validatePlan(buf, plan([at(100, 10), at(110, 10)]))).not.toThrow();
    expect(() => validatePlan(buf, plan([at(110, 10), at(100, 10)]))).not.toThrow();
  });

  it('rejects an edit that runs past the original EOF', () => {
    expect(() => validatePlan(buf, plan([at(buf.byteLength - 4, 8)]))).toThrow(/outside the original file/);
  });

  it('rejects an edit that starts past the original EOF', () => {
    expect(() => validatePlan(buf, plan([at(buf.byteLength + 8, 4)]))).toThrow(/outside the original file/);
  });

  it('rejects a negative offset', () => {
    expect(() => validatePlan(buf, plan([at(-1, 4)]))).toThrow(/outside the original file/);
  });

  it('rejects two edits that overlap', () => {
    expect(() => validatePlan(buf, plan([at(100, 10), at(105, 10)]))).toThrow(/overlap/);
    expect(() => validatePlan(buf, plan([at(105, 10), at(100, 10)]))).toThrow(/overlap/);
  });

  it('rejects an outputLength that does not account for the append', () => {
    const append = new Uint8Array(16);
    expect(() => validatePlan(buf, { edits: [], append, outputLength: buf.byteLength, relocatedIfd: false }))
      .toThrow(/outputLength/);
    expect(() => validatePlan(buf, { edits: [], append: null, outputLength: buf.byteLength + 1, relocatedIfd: false }))
      .toThrow(/outputLength/);
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
