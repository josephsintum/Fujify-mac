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

  it('keeps every out-of-line value at an even offset, including an odd-length one', () => {
    // 'ODDLEN' + NUL terminator = 7 bytes: odd, and > 4 so it lands out-of-line
    // rather than inline in the entry. This exercises the padding arithmetic
    // that decides where the *next* out-of-line value starts.
    const ucm = 'ODDLEN';
    const buf = synthDng({ uniqueCameraModel: ucm });
    const dv = new DataView(buf.buffer);
    const n = dv.getUint16(8, true);

    let foundUcm: string | undefined;
    for (let i = 0; i < n; i++) {
      const e = 10 + i * 12;
      const tag = dv.getUint16(e, true);
      const count = dv.getUint32(e + 4, true);
      if (count <= 4) continue; // stored inline in the entry, not in the data area
      const at = dv.getUint32(e + 8, true);
      expect(at % 2).toBe(0);
      if (tag === 0xc614) {
        foundUcm = new TextDecoder().decode(buf.subarray(at, at + count - 1)); // drop NUL
      }
    }
    expect(foundUcm).toBe(ucm);
  });

  it('grows the buffer by exactly trailingBytes and still decodes every entry', () => {
    const base = synthDng();
    const withTrailing = synthDng({ trailingBytes: 37 });
    expect(withTrailing.length).toBe(base.length + 37);

    const dv = new DataView(withTrailing.buffer);
    const n = dv.getUint16(8, true);
    const decoded: Record<number, string> = {};
    for (let i = 0; i < n; i++) {
      const e = 10 + i * 12;
      const tag = dv.getUint16(e, true);
      const type = dv.getUint16(e + 2, true);
      const count = dv.getUint32(e + 4, true);
      const at = count <= 4 ? e + 8 : dv.getUint32(e + 8, true);
      if (type !== 2) continue; // only decode the ASCII fields here
      decoded[tag] = new TextDecoder().decode(withTrailing.subarray(at, at + count)).replace(/\0$/, '');
    }
    expect(decoded[0x010f]).toBe('SONY');
    expect(decoded[0x0110]).toBe('ILCE-7S');
    expect(decoded[0xc614]).toBe('Sony ILCE-7S');
  });
});
