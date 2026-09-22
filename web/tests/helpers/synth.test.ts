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
